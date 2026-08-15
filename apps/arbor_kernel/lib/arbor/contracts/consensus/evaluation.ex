defmodule Arbor.Contracts.Consensus.Evaluation do
  @moduledoc """
  Data structure for evaluator assessments.

  Each evaluator produces an evaluation with their vote,
  reasoning, and confidence level.
  """

  use TypedStruct

  alias Arbor.Contracts.Consensus.Protocol

  @type vote :: :approve | :reject | :abstain
  @type perspective :: Protocol.evaluator_perspective()

  typedstruct enforce: true do
    @typedoc "An evaluator's assessment of a proposal"

    field(:id, String.t())
    field(:proposal_id, String.t())
    field(:evaluator_id, String.t())
    field(:perspective, perspective())
    field(:vote, vote())
    field(:reasoning, String.t())
    field(:confidence, float())
    field(:concerns, [String.t()], default: [])
    field(:recommendations, [String.t()], default: [])
    field(:risk_score, float(), default: 0.0)
    field(:benefit_score, float(), default: 0.0)
    field(:sealed, boolean(), default: false)
    field(:seal_hash, String.t() | nil, enforce: false)
    field(:created_at, DateTime.t())
  end

  @doc """
  Create a new evaluation.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = attrs[:id] || generate_id()

    evaluation = %__MODULE__{
      id: id,
      proposal_id: Map.fetch!(attrs, :proposal_id),
      evaluator_id: Map.fetch!(attrs, :evaluator_id),
      perspective: Map.fetch!(attrs, :perspective),
      vote: Map.fetch!(attrs, :vote),
      reasoning: Map.fetch!(attrs, :reasoning),
      confidence: Map.get(attrs, :confidence, 0.5),
      concerns: Map.get(attrs, :concerns, []),
      recommendations: Map.get(attrs, :recommendations, []),
      risk_score: Map.get(attrs, :risk_score, 0.0),
      benefit_score: Map.get(attrs, :benefit_score, 0.0),
      sealed: false,
      seal_hash: nil,
      created_at: now
    }

    {:ok, evaluation}
  rescue
    e in KeyError ->
      {:error, {:missing_required_field, e.key}}
  end

  @doc """
  Seal an evaluation to prevent tampering.

  Once sealed, the evaluation cannot be modified. The seal
  is a hash of the evaluation contents that can be verified.
  """
  @spec seal(t()) :: t()
  def seal(%__MODULE__{sealed: true} = evaluation), do: evaluation

  def seal(%__MODULE__{} = evaluation) do
    hash = compute_seal_hash(evaluation)
    %{evaluation | sealed: true, seal_hash: hash}
  end

  @doc """
  Verify that a sealed evaluation has not been tampered with.
  """
  @spec verify_seal(t()) :: :ok | {:error, :invalid_seal | :not_sealed}
  def verify_seal(%__MODULE__{sealed: false}), do: {:error, :not_sealed}

  def verify_seal(%__MODULE__{sealed: true, seal_hash: stored_hash} = evaluation) do
    computed_hash = compute_seal_hash(evaluation)

    if computed_hash == stored_hash do
      :ok
    else
      {:error, :invalid_seal}
    end
  end

  @doc """
  Check if vote is positive.
  """
  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{vote: :approve}), do: true
  def positive?(_), do: false

  @doc """
  Check if vote is negative.
  """
  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{vote: :reject}), do: true
  def negative?(_), do: false

  @doc """
  Get a summary of the evaluation.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = eval) do
    %{
      perspective: eval.perspective,
      vote: eval.vote,
      confidence: eval.confidence,
      risk: eval.risk_score,
      benefit: eval.benefit_score,
      concern_count: length(eval.concerns)
    }
  end

  # Private functions

  defp generate_id do
    "eval_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp compute_seal_hash(%__MODULE__{} = evaluation) do
    # Hash the important fields (excluding seal-related fields)
    data =
      :erlang.term_to_binary({
        evaluation.proposal_id,
        evaluation.evaluator_id,
        evaluation.perspective,
        evaluation.vote,
        evaluation.reasoning,
        evaluation.confidence,
        evaluation.concerns,
        evaluation.risk_score,
        evaluation.benefit_score,
        evaluation.created_at
      })

    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
