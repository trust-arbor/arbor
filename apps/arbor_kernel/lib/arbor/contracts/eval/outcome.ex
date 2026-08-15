defmodule Arbor.Contracts.Eval.Outcome do
  @moduledoc """
  The ONE normalized eval-result type across Arbor's eval layers.

  Grader results (`%{score, passed, detail}`), consensus `Evaluation`s (votes),
  and agent-safety `check_result`s all normalize into this struct via the
  `from_*` mappers, so every eval — task-level (Layer 1) or system/agent-level
  (Layer 2) — produces a uniform outcome that lands in the shared
  `EvalRun`/`EvalResult` store and the dashboard.

  This is the Level-0 result contract from
  `.arbor/roadmap/1-brainstorming/unified-eval-as-dot.md` (the Layer-2
  consolidation target). It deliberately supersedes ad-hoc per-framework verdict
  shapes.

  ## Fields

  - `evaluator` — grader name, perspective name, or check name (who produced it)
  - `score` — 0.0–1.0, universal
  - `passed` — hard pass/fail gate
  - `vote` — `:approve | :reject | :abstain | nil` (perspective-based evals)
  - `confidence` — confidence in the score (1.0 for deterministic checks)
  - `reasoning` — human-readable explanation
  - `concerns` — issues found
  - `recommendations` — suggestions
  - `metadata` — extensible (risk_score, cost, tokens, tool_call_count, etc.)
  """

  use TypedStruct

  @valid_votes [:approve, :reject, :abstain, nil]

  typedstruct do
    @typedoc "A normalized eval outcome"

    field(:evaluator, String.t(), enforce: true)
    field(:score, float(), enforce: true)
    field(:passed, boolean(), enforce: true)
    field(:vote, atom() | nil, default: nil)
    field(:confidence, float(), default: 1.0)
    field(:reasoning, String.t() | nil, default: nil)
    field(:concerns, [String.t()], default: [])
    field(:recommendations, [String.t()], default: [])
    field(:metadata, map(), default: %{})
  end

  @doc """
  Build an outcome from attributes. Validates `score`/`confidence` ∈ [0,1] and
  `vote` is one of the valid votes (or nil).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_unit(attrs, :score),
         :ok <- validate_unit(attrs, :confidence),
         :ok <- validate_vote(attrs) do
      {:ok,
       %__MODULE__{
         evaluator: Map.fetch!(attrs, :evaluator),
         score: Map.fetch!(attrs, :score),
         passed: Map.fetch!(attrs, :passed),
         vote: Map.get(attrs, :vote),
         confidence: Map.get(attrs, :confidence, 1.0),
         reasoning: Map.get(attrs, :reasoning),
         concerns: Map.get(attrs, :concerns, []),
         recommendations: Map.get(attrs, :recommendations, [])
       }
       |> struct(metadata: Map.get(attrs, :metadata, %{}))}
    end
  end

  @doc "Raising variant of `new/1` — for internal/trusted construction."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, outcome} -> outcome
      {:error, reason} -> raise ArgumentError, "invalid Outcome: #{inspect(reason)}"
    end
  end

  @doc """
  Map a deterministic grader result (`%{score, passed, detail}`, the
  `Arbor.Orchestrator.Eval.Grader` shape) into an Outcome. Taken as a plain map
  so this contract stays dependency-free.
  """
  @spec from_grader_result(map(), String.t(), keyword()) :: t()
  def from_grader_result(%{score: score, passed: passed} = raw, evaluator, opts \\ []) do
    new!(%{
      evaluator: evaluator,
      score: score * 1.0,
      passed: passed,
      # Graders are deterministic unless told otherwise.
      confidence: Keyword.get(opts, :confidence, 1.0),
      reasoning: Map.get(raw, :detail),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @doc """
  Map an agent-safety `check_result`
  (`%{check, passed, detail, note, severity}`, the
  `Arbor.Agent.Eval.AgentTaskGrader` shape) into an Outcome. `passed → passed`,
  binary `score`, `detail → reasoning`; a failing check surfaces its detail as a
  concern. `severity`/`note` ride in metadata.
  """
  @spec from_check_result(map(), String.t()) :: t()
  def from_check_result(%{passed: passed} = check, evaluator) do
    detail = Map.get(check, :detail)

    new!(%{
      evaluator: evaluator,
      score: if(passed, do: 1.0, else: 0.0),
      passed: passed,
      confidence: 1.0,
      reasoning: detail,
      concerns: if(passed, do: [], else: [detail || "check failed"]),
      metadata: %{severity: Map.get(check, :severity), note: Map.get(check, :note)}
    })
  end

  @doc """
  Map a consensus `Evaluation` (a perspective vote) into an Outcome. Score is
  derived from the vote (approve=1.0, abstain=0.5, reject=0.0); risk/benefit
  scores ride in metadata. Taken as a plain map to avoid a struct dependency.
  """
  @spec from_evaluation(map()) :: t()
  def from_evaluation(%{vote: vote} = ev) do
    new!(%{
      evaluator: to_string(Map.get(ev, :perspective, "evaluation")),
      score: vote_score(vote),
      passed: vote == :approve,
      vote: vote,
      confidence: Map.get(ev, :confidence, 1.0) * 1.0,
      reasoning: Map.get(ev, :reasoning),
      concerns: Map.get(ev, :concerns, []),
      metadata: %{
        risk_score: Map.get(ev, :risk_score),
        benefit_score: Map.get(ev, :benefit_score)
      }
    })
  end

  @doc "Passed iff `passed` is true (and not a reject vote)."
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{passed: passed, vote: vote}), do: passed and vote != :reject

  # ── validation ──

  defp validate_unit(attrs, key) do
    case Map.get(attrs, key, if(key == :confidence, do: 1.0, else: nil)) do
      v when is_number(v) and v >= 0 and v <= 1 -> :ok
      nil when key == :confidence -> :ok
      other -> {:error, {:out_of_range, key, other}}
    end
  end

  defp validate_vote(attrs) do
    if Map.get(attrs, :vote) in @valid_votes,
      do: :ok,
      else: {:error, {:invalid_vote, Map.get(attrs, :vote)}}
  end

  defp vote_score(:approve), do: 1.0
  defp vote_score(:abstain), do: 0.5
  defp vote_score(:reject), do: 0.0
  defp vote_score(_), do: 0.0
end
