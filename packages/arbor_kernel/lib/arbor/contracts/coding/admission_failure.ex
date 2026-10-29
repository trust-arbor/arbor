defmodule Arbor.Contracts.Coding.AdmissionFailure do
  @moduledoc """
  Closed, bounded terminal evidence for a rejected coding-plan admission.

  The diagnostic must describe a blocked preflight gate, and the outcome must
  be the exact registered `coding_admission_failed` outcome. The object carries
  evidence only; it contains no raw failure term, authority, or retry command.
  """

  use TypedStruct

  alias Arbor.Contracts.Coding.{Diagnostic, TaskOutcome}

  @status "coding_admission_failed"
  @fields [:status, :diagnostic, :outcome]
  @max_fields length(@fields)
  @max_json_bytes 16_384

  typedstruct enforce: true do
    @typedoc "Canonical coding-plan admission failure evidence."

    field(:status, String.t())
    field(:diagnostic, map())
    field(:outcome, map())
  end

  @doc "Construct and validate a closed admission-failure object."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         :ok <- require_fields(attrs),
         @status <- attrs.status,
         {:ok, diagnostic} <- Diagnostic.normalize(attrs.diagnostic),
         :ok <- validate_diagnostic_semantics(diagnostic),
         {:ok, outcome} <- normalize_outcome(attrs.outcome),
         failure = %__MODULE__{
           status: @status,
           diagnostic: diagnostic,
           outcome: outcome
         },
         true <- json_size(failure) <= @max_json_bytes do
      {:ok, failure}
    else
      false -> {:error, {:invalid_admission_failure, :too_large}}
      _ -> {:error, {:invalid_admission_failure, :invalid}}
    end
  rescue
    _ -> {:error, {:invalid_admission_failure, :malformed}}
  catch
    _, _ -> {:error, {:invalid_admission_failure, :malformed}}
  end

  @doc "Return the canonical closed string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = failure) do
    %{
      "status" => failure.status,
      "diagnostic" => failure.diagnostic,
      "outcome" => failure.outcome
    }
  end

  @doc "Normalize admission evidence directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, failure} <- new(attrs), do: {:ok, to_map(failure)}
  end

  @doc "Return true only for valid admission-failure evidence."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = failure), do: match?({:ok, _}, new(to_map(failure)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  defp normalize_object(attrs) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {:invalid_admission_failure, :struct_not_allowed}}
      map_size(attrs) > @max_fields -> {:error, {:invalid_admission_failure, :object_too_large}}
      true -> normalize_entries(attrs)
    end
  end

  defp normalize_object(attrs) when is_list(attrs) do
    entries = Enum.take(attrs, @max_fields + 1)

    cond do
      length(entries) > @max_fields ->
        {:error, {:invalid_admission_failure, :object_too_large}}

      Enum.all?(entries, &match?({_, _}, &1)) ->
        normalize_entries(entries)

      true ->
        {:error, {:invalid_admission_failure, :object_required}}
    end
  end

  defp normalize_object(_attrs),
    do: {:error, {:invalid_admission_failure, :object_required}}

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
          {:halt, {:error, {:invalid_admission_failure, :unknown_field}}}
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
    case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      _field -> {:error, {:invalid_admission_failure, :missing_field}}
    end
  end

  defp validate_diagnostic_semantics(%{
         "phase" => "preflight",
         "decision" => "blocked"
       }),
       do: :ok

  defp validate_diagnostic_semantics(_diagnostic),
    do: {:error, {:invalid_admission_failure, :diagnostic_semantics}}

  defp normalize_outcome(outcome) do
    with {:ok, typed} <- TaskOutcome.validate_registered(outcome),
         canonical = TaskOutcome.to_map(typed),
         {:ok, expected} <- TaskOutcome.from_code(@status),
         expected = TaskOutcome.to_map(expected),
         true <- canonical == expected do
      {:ok, canonical}
    else
      _ -> {:error, {:invalid_admission_failure, :outcome_semantics}}
    end
  end

  defp json_size(failure) do
    case Jason.encode(to_map(failure)) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> @max_json_bytes + 1
    end
  end
end
