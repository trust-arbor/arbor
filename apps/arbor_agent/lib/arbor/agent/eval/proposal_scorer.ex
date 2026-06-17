defmodule Arbor.Agent.Eval.ProposalScorer do
  @moduledoc """
  Scores agent proposals against ground truth from a BugCase.

  Uses keyword matching to determine how close the agent's fix proposal
  is to the actual root cause and fix. Optionally submits to the advisory
  council for deeper evaluation.
  """

  alias Arbor.Agent.Eval.BugCase
  alias Arbor.Contracts.Judge.Verdict

  @type score :: %{
          file_match: float(),
          function_match: float(),
          cause_match: float(),
          fix_match: float(),
          overall: float()
        }

  @doc """
  Score a proposal (or list of proposals) against a bug case.

  Returns the best score if multiple proposals are given.
  """
  @spec score(String.t() | [String.t()], BugCase.t()) :: score()
  def score(proposals, bug_case) when is_list(proposals) do
    proposals
    |> Enum.map(&score_one(&1, bug_case))
    |> Enum.max_by(& &1.overall, fn -> empty_score() end)
  end

  def score(proposal, bug_case) when is_binary(proposal) do
    score_one(proposal, bug_case)
  end

  def score(%{content: content}, bug_case) when is_binary(content) do
    score_one(content, bug_case)
  end

  def score(_, _bug_case), do: empty_score()

  @doc """
  Submit a proposal to the advisory council for evaluation.

  Returns `{:ok, verdict}` or `{:error, reason}`.
  This is expensive (LLM calls) — use sparingly.
  """
  @spec council_evaluate(String.t(), BugCase.t()) :: {:ok, map()} | {:error, term()}
  def council_evaluate(proposal_text, bug_case) do
    question = """
    An AI agent was asked to find and fix this bug:

    BUG: #{bug_case.name}
    SYMPTOM: #{bug_case.symptom}
    ACTUAL ROOT CAUSE: #{bug_case.root_cause}
    ACTUAL FIX: #{bug_case.fix_description}

    The agent proposed:
    #{proposal_text}

    Does this proposal correctly identify the root cause and propose a valid fix?
    Rate: approve (correct), reject (wrong), or defer (partially correct).
    """

    Arbor.Consensus.decide(question, timeout: 120_000)
  rescue
    e -> {:error, {:council_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:council_exit, reason}}
  end

  @doc """
  Score a proposal with the LLM-as-judge (`Arbor.Actions.Judge.Evaluate`) against
  the bug's ground truth, returning a `Judge.Verdict` with per-dimension scores.

  This is the rubric-scored alternative to the deterministic keyword `score/2`:
  it gives the Judge subsystem a real job (a purpose-built "fix proposal" rubric +
  critique mode) and produces the shared `Verdict` contract — so council, judge,
  and security verifications all speak the same result language. Like
  `council_evaluate/2` it's LLM-backed (expensive) and runtime-bridged so a
  minimal build without `arbor_actions` degrades gracefully rather than failing
  to compile-link.

  Pass `:llm_fn` in `opts` to inject the judge's LLM call (used in tests).
  Returns `{:ok, Verdict.t()}` or `{:error, reason}`.
  """
  @spec judge_score(String.t(), BugCase.t(), keyword()) :: {:ok, Verdict.t()} | {:error, term()}
  def judge_score(proposal_text, %BugCase{} = bug, opts \\ []) when is_binary(proposal_text) do
    judge = Arbor.Actions.Judge.Evaluate

    if Code.ensure_loaded?(judge) and function_exported?(judge, :run, 2) do
      params =
        %{
          content: proposal_text,
          mode: :critique,
          question: "Does this proposal correctly identify the root cause and fix the bug?",
          intent: ground_truth_intent(bug),
          rubric: fix_proposal_rubric()
        }
        |> maybe_put(:llm_fn, opts[:llm_fn])

      case apply(judge, :run, [params, %{}]) do
        {:ok, %{verdict: %Verdict{} = verdict}} -> {:ok, verdict}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_judge_result, other}}
      end
    else
      {:error, :judge_unavailable}
    end
  rescue
    e -> {:error, {:judge_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:judge_exit, reason}}
  end

  # -- Private --

  # A purpose-built rubric for grading a bug-fix proposal against ground truth.
  # Weights sum to 1.0 (Rubric.new enforces this).
  defp fix_proposal_rubric do
    %{
      domain: "fix_proposal",
      dimensions: [
        %{
          name: :root_cause,
          weight: 0.35,
          description: "Correctly identifies the true root cause"
        },
        %{
          name: :fix_validity,
          weight: 0.35,
          description: "The proposed fix would resolve the bug"
        },
        %{
          name: :target_accuracy,
          weight: 0.20,
          description: "Names the correct file and function"
        },
        %{name: :clarity, weight: 0.10, description: "Explanation is specific and unambiguous"}
      ]
    }
  end

  defp ground_truth_intent(%BugCase{} = bug) do
    """
    Grade the proposal against this known-correct answer (the agent did NOT see it):
      BUG: #{bug.name}
      SYMPTOM: #{bug.symptom}
      ACTUAL ROOT CAUSE: #{bug.root_cause}
      ACTUAL FIX: #{bug.fix_description}
    Score higher only when the proposal genuinely matches the real root cause and fix.
    """
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp score_one(text, %BugCase{scoring: scoring}) when is_binary(text) do
    text_lower = String.downcase(text)

    file_match = if match_keyword?(text_lower, scoring.target_file), do: 1.0, else: 0.0

    function_match =
      if match_keyword?(text_lower, scoring.target_function), do: 1.0, else: 0.0

    cause_match = keyword_fraction(text_lower, scoring.root_cause_keywords)
    fix_match = keyword_fraction(text_lower, scoring.fix_keywords)

    overall =
      Float.round(
        0.15 * file_match + 0.15 * function_match + 0.30 * cause_match + 0.40 * fix_match,
        3
      )

    %{
      file_match: file_match,
      function_match: function_match,
      cause_match: Float.round(cause_match, 3),
      fix_match: Float.round(fix_match, 3),
      overall: overall
    }
  end

  defp match_keyword?(text, keyword) do
    String.contains?(text, String.downcase(keyword))
  end

  defp keyword_fraction(_text, []), do: 0.0

  defp keyword_fraction(text, keywords) do
    matches = Enum.count(keywords, &match_keyword?(text, &1))
    matches / length(keywords)
  end

  defp empty_score do
    %{file_match: 0.0, function_match: 0.0, cause_match: 0.0, fix_match: 0.0, overall: 0.0}
  end
end
