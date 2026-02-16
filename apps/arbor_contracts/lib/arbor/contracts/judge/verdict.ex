defmodule Arbor.Contracts.Judge.Verdict do
  @moduledoc """
  Judge verdict — the result of evaluating a piece of output.

  Contains overall score, per-dimension scores, qualitative analysis,
  and a recommendation (keep/revise/reject).

  ## Fields

  - `overall_score` — weighted average across dimensions (0.0–1.0)
  - `dimension_scores` — map of `%{dimension_name => score}`
  - `strengths` — list of identified strengths
  - `weaknesses` — list of identified weaknesses
  - `recommendation` — `:keep`, `:revise`, or `:reject`
  - `mode` — `:verification` (evidence only) or `:critique` (evidence + LLM)
  - `meta` — judge metadata (model, confidence, rubric snapshot, etc.)
  """

  use TypedStruct

  @valid_recommendations [:keep, :revise, :reject]
  @valid_modes [:verification, :critique]

  typedstruct do
    @typedoc "A judge verdict with scores and recommendation"

    field(:overall_score, float(), enforce: true)
    field(:dimension_scores, %{atom() => float()}, default: %{})
    field(:strengths, [String.t()], default: [])
    field(:weaknesses, [String.t()], default: [])
    field(:recommendation, atom(), enforce: true)
    field(:mode, atom(), enforce: true)
    field(:meta, map(), default: %{})
  end

  @doc """
  Create a new verdict from attributes.

  Validates score ranges and recommendation/mode values.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_score(attrs),
         :ok <- validate_recommendation(attrs),
         :ok <- validate_mode(attrs) do
      verdict = %__MODULE__{
        overall_score: Map.fetch!(attrs, :overall_score),
        dimension_scores: Map.get(attrs, :dimension_scores, %{}),
        strengths: Map.get(attrs, :strengths, []),
        weaknesses: Map.get(attrs, :weaknesses, []),
        recommendation: Map.fetch!(attrs, :recommendation),
        mode: Map.fetch!(attrs, :mode),
        meta: Map.get(attrs, :meta, %{})
      }

      {:ok, verdict}
    end
  end

  @doc """
  Check if the verdict passed (recommendation is not :reject).
  """
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{recommendation: rec}), do: rec != :reject

  # Private validation

  defp validate_score(attrs) do
    case Map.get(attrs, :overall_score) do
      s when is_number(s) and s >= 0.0 and s <= 1.0 -> :ok
      nil -> {:error, {:missing_required_field, :overall_score}}
      s when is_number(s) -> {:error, {:invalid_field, :overall_score, "must be between 0.0 and 1.0"}}
      _ -> {:error, {:invalid_field, :overall_score, "must be a number"}}
    end
  end

  defp validate_recommendation(attrs) do
    case Map.get(attrs, :recommendation) do
      r when r in @valid_recommendations -> :ok
      nil -> {:error, {:missing_required_field, :recommendation}}
      r -> {:error, {:invalid_field, :recommendation, "must be one of #{inspect(@valid_recommendations)}, got #{inspect(r)}"}}
    end
  end

  defp validate_mode(attrs) do
    case Map.get(attrs, :mode) do
      m when m in @valid_modes -> :ok
      nil -> {:error, {:missing_required_field, :mode}}
      m -> {:error, {:invalid_field, :mode, "must be one of #{inspect(@valid_modes)}, got #{inspect(m)}"}}
    end
  end
end
