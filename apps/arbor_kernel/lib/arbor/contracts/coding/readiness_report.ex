defmodule Arbor.Contracts.Coding.ReadinessReport do
  @moduledoc "Versioned, bounded readiness evidence for a coding plan."

  use TypedStruct

  alias Arbor.Contracts.Coding.Diagnostic

  @schema_version 1
  @statuses ~w(ready degraded blocked)
  @fields [:version, :status, :plan_digest, :observed_at, :diagnostics, :expires_at]
  @required_fields [:version, :status, :plan_digest, :observed_at, :diagnostics]
  @max_fields length(@fields)
  @max_text_bytes 512
  @max_timestamp_bytes 64
  @max_diagnostics 256
  @max_report_bytes 256_000

  typedstruct enforce: true do
    @typedoc "Bounded coding-plan readiness evidence."

    field(:version, pos_integer())
    field(:status, String.t())
    field(:plan_digest, String.t())
    field(:observed_at, String.t())
    field(:diagnostics, [map()])
    field(:expires_at, String.t() | nil, default: nil)
  end

  @doc "Return the accepted readiness-report schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Return the closed readiness statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Construct and validate a closed readiness report."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         :ok <- require_fields(attrs),
         :ok <- validate_version(attrs.version),
         {:ok, status} <- normalize_enum(attrs.status, @statuses, :status),
         {:ok, plan_digest} <- bounded_text(attrs.plan_digest, :plan_digest),
         {:ok, observed_at, observed_datetime} <-
           normalize_timestamp(attrs.observed_at, :observed_at),
         {:ok, diagnostics} <- normalize_diagnostics(attrs.diagnostics),
         {:ok, expires_at, expires_datetime} <- optional_timestamp(attrs, :expires_at),
         :ok <- validate_time_order(observed_datetime, expires_datetime) do
      report = %__MODULE__{
        version: @schema_version,
        status: status,
        plan_digest: plan_digest,
        observed_at: observed_at,
        diagnostics: diagnostics,
        expires_at: expires_at
      }

      if json_size(report) <= @max_report_bytes,
        do: {:ok, report},
        else: {:error, {:invalid_readiness_report, :too_large}}
    end
  rescue
    _ -> {:error, {:invalid_readiness_report, :malformed}}
  catch
    _, _ -> {:error, {:invalid_readiness_report, :malformed}}
  end

  @doc "Return the canonical string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = report) do
    %{
      "version" => report.version,
      "status" => report.status,
      "plan_digest" => report.plan_digest,
      "observed_at" => report.observed_at,
      "diagnostics" => report.diagnostics
    }
    |> maybe_put("expires_at", report.expires_at)
  end

  @doc "Normalize a readiness report directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, report} <- new(attrs), do: {:ok, to_map(report)}
  end

  @doc "Return true only for a valid readiness report object or struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = report), do: match?({:ok, _}, new(to_map(report)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  defp normalize_object(attrs) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {:invalid_readiness_report, :struct_not_allowed}}
      map_size(attrs) > @max_fields -> {:error, {:invalid_readiness_report, :object_too_large}}
      true -> normalize_entries(attrs)
    end
  end

  defp normalize_object(attrs) when is_list(attrs) do
    entries = Enum.take(attrs, @max_fields + 1)

    cond do
      length(entries) > @max_fields -> {:error, {:invalid_readiness_report, :object_too_large}}
      Enum.all?(entries, &match?({_, _}, &1)) -> normalize_entries(entries)
      true -> {:error, {:invalid_readiness_report, :object_required}}
    end
  end

  defp normalize_object(_attrs), do: {:error, {:invalid_readiness_report, :object_required}}

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
    if safe_text?(value, @max_text_bytes),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp bounded_text(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp normalize_diagnostics(value) when is_list(value) do
    entries = Enum.take(value, @max_diagnostics + 1)

    cond do
      length(entries) > @max_diagnostics ->
        {:error, {:invalid_field, "diagnostics"}}

      true ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, diagnostics} ->
          case Diagnostic.new(entry) do
            {:ok, diagnostic} -> {:cont, {:ok, [Diagnostic.to_map(diagnostic) | diagnostics]}}
            {:error, _reason} -> {:halt, {:error, {:invalid_field, "diagnostics"}}}
          end
        end)
        |> reverse_ok()
    end
  end

  defp normalize_diagnostics(_value), do: {:error, {:invalid_field, "diagnostics"}}

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp optional_timestamp(attrs, field) do
    case Map.fetch(attrs, field) do
      :error ->
        {:ok, nil, nil}

      {:ok, nil} ->
        {:ok, nil, nil}

      {:ok, value} ->
        case normalize_timestamp(value, field) do
          {:ok, timestamp, datetime} -> {:ok, timestamp, datetime}
          {:error, _reason} = error -> error
        end
    end
  end

  defp normalize_timestamp(value, field) when is_binary(value) do
    with true <- safe_text?(value, @max_timestamp_bytes),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, utc_datetime} <- DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, DateTime.to_iso8601(utc_datetime), utc_datetime}
    else
      _ -> {:error, {:invalid_field, Atom.to_string(field)}}
    end
  end

  defp normalize_timestamp(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp validate_time_order(_observed, nil), do: :ok

  defp validate_time_order(observed, expires) do
    if DateTime.compare(expires, observed) == :gt,
      do: :ok,
      else: {:error, {:invalid_field, "expires_at"}}
  end

  defp json_size(report), do: report |> to_map() |> Jason.encode!() |> byte_size()

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
