defmodule Arbor.Contracts.Judge.Evidence do
  @moduledoc """
  A single piece of evidence produced by an evidence producer.

  Evidence is a deterministic, non-LLM check of output quality
  (format compliance, keyword relevance, reference engagement, etc.).

  ## Fields

  - `type` — evidence type identifier (e.g., `:format_compliance`)
  - `score` — normalized score (0.0–1.0)
  - `passed` — boolean pass/fail for this check
  - `detail` — human-readable explanation
  - `producer` — module that produced this evidence
  - `duration_ms` — time to produce
  """

  use TypedStruct

  typedstruct do
    @typedoc "A piece of evaluation evidence"

    field(:type, atom(), enforce: true)
    field(:score, float(), enforce: true)
    field(:passed, boolean(), enforce: true)
    field(:detail, String.t(), default: "")
    field(:producer, module() | nil)
    field(:duration_ms, non_neg_integer(), default: 0)
  end

  @doc """
  Create a new evidence struct from attributes.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_type(attrs),
         :ok <- validate_score(attrs),
         :ok <- validate_passed(attrs) do
      evidence = %__MODULE__{
        type: Map.fetch!(attrs, :type),
        score: Map.fetch!(attrs, :score),
        passed: Map.fetch!(attrs, :passed),
        detail: Map.get(attrs, :detail, ""),
        producer: Map.get(attrs, :producer),
        duration_ms: Map.get(attrs, :duration_ms, 0)
      }

      {:ok, evidence}
    end
  end

  # Private validation

  defp validate_type(attrs) do
    case Map.get(attrs, :type) do
      t when is_atom(t) and not is_nil(t) -> :ok
      nil -> {:error, {:missing_required_field, :type}}
      _ -> {:error, {:invalid_field, :type, "must be an atom"}}
    end
  end

  defp validate_score(attrs) do
    case Map.get(attrs, :score) do
      s when is_number(s) and s >= 0.0 and s <= 1.0 -> :ok
      nil -> {:error, {:missing_required_field, :score}}
      s when is_number(s) -> {:error, {:invalid_field, :score, "must be between 0.0 and 1.0"}}
      _ -> {:error, {:invalid_field, :score, "must be a number"}}
    end
  end

  defp validate_passed(attrs) do
    case Map.get(attrs, :passed) do
      p when is_boolean(p) -> :ok
      nil -> {:error, {:missing_required_field, :passed}}
      _ -> {:error, {:invalid_field, :passed, "must be a boolean"}}
    end
  end
end
