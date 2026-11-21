defmodule Arbor.Contracts.Consensus.CouncilDecision do
  @moduledoc """
  Data structure for council decisions.

  A council decision aggregates all evaluator votes and
  determines the final outcome of a proposal.

  ## Modes

  - `:decision` - Formal approve/reject/deadlock with quorum enforcement
  - `:advisory` - Perspectives collected for advisory input (vote is irrelevant)
  """

  use TypedStruct

  alias Arbor.Contracts.Consensus.{Evaluation, Proposal, Protocol}
  alias Arbor.Contracts.Judge.Verdict

  @type decision :: :approved | :rejected | :deadlock
  @type mode :: :decision | :advisory

  typedstruct enforce: true do
    @typedoc "The council's final decision on a proposal"

    field(:id, String.t())
    field(:proposal_id, String.t())
    field(:decision, decision())
    field(:mode, mode(), default: :decision)
    field(:required_quorum, pos_integer())
    field(:quorum_met, boolean())

    # Vote counts
    field(:approve_count, non_neg_integer(), default: 0)
    field(:reject_count, non_neg_integer(), default: 0)
    field(:abstain_count, non_neg_integer(), default: 0)

    # Evaluations
    field(:evaluations, [Evaluation.t()], default: [])
    field(:evaluation_ids, [String.t()], default: [])

    # Analysis
    field(:primary_concerns, [String.t()], default: [])
    field(:average_confidence, float(), default: 0.0)
    field(:average_risk, float(), default: 0.0)
    field(:average_benefit, float(), default: 0.0)

    # Timestamps
    field(:created_at, DateTime.t())
    field(:decided_at, DateTime.t())
  end

  @doc """
  Create a decision from a proposal and its evaluations.

  ## Options

    * `:quorum` - Override the required quorum (default: from Proposal)
  """
  @spec from_evaluations(Proposal.t(), [Evaluation.t()], keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_evaluations(proposal, evaluations, opts \\ [])

  def from_evaluations(proposal, evaluations, opts)
      when is_struct(proposal, Proposal) and is_list(evaluations) do
    now = DateTime.utc_now()
    id = "decision_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    # Verify all evaluations are sealed
    case verify_all_sealed(evaluations) do
      :ok ->
        counts = count_votes(evaluations)
        # Use provided quorum or fall back to Proposal default
        required_quorum = Keyword.get(opts, :quorum) || Proposal.required_quorum(proposal)
        quorum_met = counts.approve >= required_quorum

        decision = determine_decision(counts, required_quorum)

        council_decision = %__MODULE__{
          id: id,
          proposal_id: proposal.id,
          decision: decision,
          mode: Map.get(proposal, :mode, :decision),
          required_quorum: required_quorum,
          quorum_met: quorum_met,
          approve_count: counts.approve,
          reject_count: counts.reject,
          abstain_count: counts.abstain,
          evaluations: evaluations,
          evaluation_ids: Enum.map(evaluations, & &1.id),
          primary_concerns: aggregate_concerns(evaluations),
          average_confidence: average_field(evaluations, :confidence),
          average_risk: average_field(evaluations, :risk_score),
          average_benefit: average_field(evaluations, :benefit_score),
          created_at: now,
          decided_at: now
        }

        {:ok, council_decision}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Check if the decision is final (not deadlock).
  """
  @spec final?(t()) :: boolean()
  def final?(%__MODULE__{decision: :deadlock}), do: false
  def final?(_), do: true

  @doc """
  Check if the proposal was approved.
  """
  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{decision: :approved}), do: true
  def approved?(_), do: false

  @doc """
  Check if this was an advisory (non-binding) decision.
  """
  @spec advisory?(t()) :: boolean()
  def advisory?(%__MODULE__{mode: :advisory}), do: true
  def advisory?(_), do: false

  @doc """
  Get a summary of the decision.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = decision) do
    %{
      decision: decision.decision,
      votes: %{
        approve: decision.approve_count,
        reject: decision.reject_count,
        abstain: decision.abstain_count
      },
      quorum: %{
        required: decision.required_quorum,
        met: decision.quorum_met
      },
      confidence: Float.round(decision.average_confidence, 2),
      risk: Float.round(decision.average_risk, 2),
      benefit: Float.round(decision.average_benefit, 2),
      concern_count: length(decision.primary_concerns)
    }
  end

  @doc """
  Project a council decision onto the shared `Arbor.Contracts.Judge.Verdict`
  contract — the lingua franca for queryable opinion results across the
  consensus / judge / verify-finding systems.

  This is **additive**: a `CouncilDecision` keeps its richer vote/quorum
  semantics; `to_verdict/1` is a lossy projection for uniform querying and
  persistence, not a replacement.

  Mapping:
    * `overall_score`  — approval strength = approve / (approve+reject+abstain)
    * `recommendation` — :approved → :keep, :rejected → :reject, :deadlock → :revise
    * `mode`           — council :decision → :verification (binding),
                         :advisory → :critique (opinion)
    * `dimension_scores` — the three averaged signals the council already tracks:
                         `%{confidence:, risk:, benefit:}`
    * `weaknesses`     — the aggregated `primary_concerns`
    * `meta`           — provenance + the vote/quorum detail a flat Verdict can't hold

  Always succeeds — the projected attrs are within `Verdict`'s validation bounds.
  """
  @spec to_verdict(t()) :: Verdict.t()
  def to_verdict(%__MODULE__{} = d) do
    total = d.approve_count + d.reject_count + d.abstain_count

    score =
      if total > 0 do
        Float.round(d.approve_count / total, 4)
      else
        0.0
      end

    {:ok, verdict} =
      Verdict.new(%{
        overall_score: score,
        dimension_scores: %{
          confidence: Float.round(d.average_confidence, 4),
          risk: Float.round(d.average_risk, 4),
          benefit: Float.round(d.average_benefit, 4)
        },
        weaknesses: d.primary_concerns,
        recommendation: decision_to_recommendation(d.decision),
        mode: council_mode_to_verdict_mode(d.mode),
        meta: %{
          source: "council",
          decision: d.decision,
          council_mode: d.mode,
          proposal_id: d.proposal_id,
          quorum_met: d.quorum_met,
          required_quorum: d.required_quorum,
          approve_count: d.approve_count,
          reject_count: d.reject_count,
          abstain_count: d.abstain_count
        }
      })

    verdict
  end

  defp decision_to_recommendation(:approved), do: :keep
  defp decision_to_recommendation(:rejected), do: :reject
  defp decision_to_recommendation(:deadlock), do: :revise

  defp council_mode_to_verdict_mode(:advisory), do: :critique
  defp council_mode_to_verdict_mode(_), do: :verification

  @doc """
  Get evaluations by vote type.
  """
  @spec evaluations_by_vote(t(), Evaluation.vote()) :: [Evaluation.t()]
  def evaluations_by_vote(%__MODULE__{evaluations: evals}, vote) do
    Enum.filter(evals, &(&1.vote == vote))
  end

  @doc """
  Get evaluations by perspective.
  """
  @spec evaluations_by_perspective(t(), Protocol.evaluator_perspective()) :: [Evaluation.t()]
  def evaluations_by_perspective(%__MODULE__{evaluations: evals}, perspective) do
    Enum.filter(evals, &(&1.perspective == perspective))
  end

  # Private functions

  defp verify_all_sealed(evaluations) do
    unsealed = Enum.reject(evaluations, & &1.sealed)

    if Enum.empty?(unsealed) do
      :ok
    else
      {:error, {:unsealed_evaluations, Enum.map(unsealed, & &1.id)}}
    end
  end

  defp count_votes(evaluations) do
    Enum.reduce(evaluations, %{approve: 0, reject: 0, abstain: 0}, fn eval, acc ->
      Map.update!(acc, eval.vote, &(&1 + 1))
    end)
  end

  defp determine_decision(counts, required_quorum) do
    cond do
      counts.approve >= required_quorum -> :approved
      counts.reject >= required_quorum -> :rejected
      true -> :deadlock
    end
  end

  defp aggregate_concerns(evaluations) do
    evaluations
    |> Enum.flat_map(& &1.concerns)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_concern, count} -> -count end)
    |> Enum.take(5)
    |> Enum.map(fn {concern, _count} -> concern end)
  end

  defp average_field(evaluations, field) do
    case evaluations do
      [] ->
        0.0

      evals ->
        sum = Enum.reduce(evals, 0.0, fn eval, acc -> acc + Map.get(eval, field, 0.0) end)
        sum / length(evals)
    end
  end
end
