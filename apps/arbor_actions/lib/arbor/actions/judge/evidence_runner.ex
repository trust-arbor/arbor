defmodule Arbor.Actions.Judge.EvidenceRunner do
  @moduledoc """
  Orchestrates all evidence producers for a given domain.

  Runs each registered producer against the subject and context,
  collecting evidence results. All producers run synchronously
  in Phase 1.
  """

  alias Arbor.Contracts.Judge.Evidence

  alias Arbor.Actions.Judge.Producers.{
    FormatCompliance,
    PerspectiveRelevance,
    ReferenceEngagement
  }

  @default_producers [FormatCompliance, PerspectiveRelevance, ReferenceEngagement]

  @doc """
  Run all evidence producers for the given subject and context.

  Returns a list of `Evidence` structs. Failed producers are logged
  and excluded from results (never fail the whole evaluation).

  ## Options

  - `:producers` — override the default producer list
  """
  @spec run(map(), map(), keyword()) :: [Evidence.t()]
  def run(subject, context, opts \\ []) do
    producers = Keyword.get(opts, :producers, @default_producers)

    Enum.flat_map(producers, fn producer ->
      case producer.produce(subject, context, opts) do
        {:ok, %Evidence{} = evidence} ->
          [evidence]

        {:error, reason} ->
          require Logger

          Logger.debug(
            "EvidenceRunner: producer #{inspect(producer)} failed: #{inspect(reason)}"
          )

          []
      end
    end)
  end

  @doc """
  Compute an aggregate evidence score from a list of evidence.

  Returns the mean score across all evidence items.
  """
  @spec aggregate_score([Evidence.t()]) :: float()
  def aggregate_score([]), do: 0.5

  def aggregate_score(evidence_list) do
    total = Enum.reduce(evidence_list, 0.0, fn e, acc -> acc + e.score end)
    Float.round(total / length(evidence_list), 3)
  end

  @doc """
  Summarize evidence as a map for prompt injection.

  Returns a JSON-serializable summary of evidence results.
  """
  @spec summarize([Evidence.t()]) :: map()
  def summarize(evidence_list) do
    %{
      "evidence_count" => length(evidence_list),
      "aggregate_score" => aggregate_score(evidence_list),
      "all_passed" => Enum.all?(evidence_list, & &1.passed),
      "checks" =>
        Enum.map(evidence_list, fn e ->
          %{
            "type" => to_string(e.type),
            "score" => e.score,
            "passed" => e.passed,
            "detail" => e.detail
          }
        end)
    }
  end
end
