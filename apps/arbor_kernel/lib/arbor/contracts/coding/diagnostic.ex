defmodule Arbor.Contracts.Coding.Diagnostic do
  @moduledoc """
  Versioned, bounded, JSON-clean diagnostic evidence for coding gates.

  Diagnostics are descriptive data only. They contain no authority, secrets,
  prompts, or raw command output.
  """

  use TypedStruct

  @schema_version 1
  @phases ~w(preflight workspace worker_start worker_turn validation review commit adoption cleanup control)
  @decisions ~w(passed blocked degraded unavailable)
  @fields [
    :version,
    :gate_id,
    :phase,
    :decision,
    :code,
    :message,
    :remediation,
    :observed_at,
    :evidence_ref
  ]
  @required_fields [:version, :gate_id, :phase, :decision, :code, :observed_at]
  @max_fields length(@fields)
  @max_id_bytes 256
  @max_text_bytes 256
  @max_timestamp_bytes 64

  typedstruct enforce: true do
    @typedoc "A bounded coding-gate diagnostic."

    field(:version, pos_integer())
    field(:gate_id, String.t())
    field(:phase, String.t())
    field(:decision, String.t())
    field(:code, String.t())
    field(:message, String.t() | nil, default: nil)
    field(:remediation, String.t() | nil, default: nil)
    field(:observed_at, String.t())
    field(:evidence_ref, String.t() | nil, default: nil)
  end

  @doc "Return the accepted diagnostic schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Return the closed coding phases."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "Return the closed diagnostic decisions."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @doc "Construct and validate a closed diagnostic object."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         :ok <- require_fields(attrs),
         :ok <- validate_version(attrs.version),
         {:ok, gate_id} <- bounded_text(attrs.gate_id, :gate_id),
         {:ok, phase} <- normalize_enum(attrs.phase, @phases, :phase),
         {:ok, decision} <- normalize_enum(attrs.decision, @decisions, :decision),
         {:ok, code} <- bounded_text(attrs.code, :code),
         {:ok, message} <- optional_text(attrs, :message),
         {:ok, remediation} <- optional_text(attrs, :remediation),
         {:ok, observed_at} <- normalize_timestamp(attrs.observed_at, :observed_at),
         {:ok, evidence_ref} <- optional_text(attrs, :evidence_ref) do
      {:ok,
       %__MODULE__{
         version: @schema_version,
         gate_id: gate_id,
         phase: phase,
         decision: decision,
         code: code,
         message: message,
         remediation: remediation,
         observed_at: observed_at,
         evidence_ref: evidence_ref
       }}
    end
  rescue
    _ -> {:error, {:invalid_diagnostic, :malformed}}
  catch
    _, _ -> {:error, {:invalid_diagnostic, :malformed}}
  end

  @doc "Return the canonical string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = diagnostic) do
    %{
      "version" => diagnostic.version,
      "gate_id" => diagnostic.gate_id,
      "phase" => diagnostic.phase,
      "decision" => diagnostic.decision,
      "code" => diagnostic.code,
      "observed_at" => diagnostic.observed_at
    }
    |> maybe_put("message", diagnostic.message)
    |> maybe_put("remediation", diagnostic.remediation)
    |> maybe_put("evidence_ref", diagnostic.evidence_ref)
  end

  @doc "Normalize a diagnostic directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, diagnostic} <- new(attrs), do: {:ok, to_map(diagnostic)}
  end

  @doc "Return true only for a valid diagnostic object or struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = diagnostic), do: match?({:ok, _}, new(to_map(diagnostic)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  defp normalize_object(attrs) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {:invalid_diagnostic, :struct_not_allowed}}
      map_size(attrs) > @max_fields -> {:error, {:invalid_diagnostic, :object_too_large}}
      true -> normalize_entries(attrs)
    end
  end

  defp normalize_object(attrs) when is_list(attrs) do
    entries = Enum.take(attrs, @max_fields + 1)

    cond do
      length(entries) > @max_fields -> {:error, {:invalid_diagnostic, :object_too_large}}
      Enum.all?(entries, &match?({_, _}, &1)) -> normalize_entries(entries)
      true -> {:error, {:invalid_diagnostic, :object_required}}
    end
  end

  defp normalize_object(_attrs), do: {:error, {:invalid_diagnostic, :object_required}}

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case normalize_key(key) do
        {:ok, canonical} ->
          if Map.has_key?(normalized, canonical) do
            {:halt, {:error, {:duplicate_field, Atom.to_string(canonical)}}}
          else
            {:cont, {:ok, Map.put(normalized, canonical, value)}}
          end

        :error ->
          {:halt, {:error, {:unknown_field, printable_key(key)}}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key) do
    if key in @fields, do: {:ok, key}, else: :error
  end

  defp normalize_key(key) when is_binary(key) do
    Enum.find_value(@fields, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp normalize_key(_key), do: :error

  defp require_fields(attrs) do
    case Enum.find(@required_fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp validate_version(@schema_version), do: :ok
  defp validate_version(_version), do: {:error, {:invalid_field, "version"}}

  defp normalize_enum(value, allowed, field) do
    normalized = if is_atom(value), do: Atom.to_string(value), else: value

    if is_binary(normalized) and normalized in allowed,
      do: {:ok, normalized},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp bounded_text(value, field) when is_binary(value) do
    maximum = if field in [:gate_id, :code], do: @max_id_bytes, else: @max_text_bytes

    if safe_text?(value, maximum),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp bounded_text(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_text(attrs, field) do
    case Map.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> bounded_text(value, field)
    end
  end

  defp normalize_timestamp(value, field) when is_binary(value) do
    valid_text = safe_text?(value, @max_timestamp_bytes)

    with true <- valid_text,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, utc_datetime} <- DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, DateTime.to_iso8601(utc_datetime)}
    else
      _ -> {:error, {:invalid_field, Atom.to_string(field)}}
    end
  end

  defp normalize_timestamp(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp safe_text?(value, maximum) do
    String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= maximum and
      String.trim(value) != "" and not String.contains?(value, <<0>>) and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp printable_key(key) when is_binary(key), do: key
  defp printable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp printable_key(_key), do: "<non-string-key>"
end
