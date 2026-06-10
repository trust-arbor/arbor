defmodule Arbor.Agent.Eval.ProposalScorerJudgeTest do
  @moduledoc """
  Tests `ProposalScorer.judge_score/3` — the Phase 3 "lean Judge in" integration
  that runs a bug-fix proposal through the real `Judge.Evaluate` (critique mode,
  purpose-built fix-proposal rubric) and returns a shared `Judge.Verdict`. The
  judge's LLM call is injected via `:llm_fn`, so no real model is needed.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.{BugCase, ProposalScorer}
  alias Arbor.Contracts.Judge.Verdict

  defp bug do
    %BugCase{
      id: "test_bug",
      name: "Glob wildcard over-grant",
      fix_commit: "abc123",
      pre_fix_commit: "def456",
      file: "capability_store.ex",
      function: "match_uri/2",
      symptom: "A capability for arbor://fs/read/ matched arbor://shell/exec/",
      root_cause: "match_uri/2 treated ** as matching across URI segments",
      fix_description: "Bound ** to a single namespace; added a segment guard"
    }
  end

  # Judge.Evaluate's llm_fn contract: fn system, user -> {:ok, json, meta}.
  defp mock_llm(_system, _user) do
    json =
      Jason.encode!(%{
        overall_score: 0.82,
        dimension_scores: %{
          root_cause: 0.9,
          fix_validity: 0.85,
          target_accuracy: 0.8,
          clarity: 0.7
        },
        strengths: ["Identifies the segment-matching root cause"],
        weaknesses: ["Could name the exact guard"],
        recommendation: "keep",
        confidence: 0.8
      })

    {:ok, json, %{model: "test-model", provider: "test"}}
  end

  test "returns a Judge.Verdict for a strong proposal" do
    proposal =
      "The root cause is match_uri/2 letting ** span URI segments; fix by bounding " <>
        "** to one namespace with a segment guard."

    assert {:ok, %Verdict{} = verdict} =
             ProposalScorer.judge_score(proposal, bug(), llm_fn: &mock_llm/2)

    assert verdict.mode == :critique
    assert verdict.overall_score == 0.82
    assert verdict.recommendation == :keep
    assert Verdict.passed?(verdict)
    # the purpose-built rubric's dimensions came through
    assert Map.has_key?(verdict.dimension_scores, :root_cause)
    assert Map.has_key?(verdict.dimension_scores, :fix_validity)
  end

  test "surfaces judge errors as {:error, _} (does not raise)" do
    fail_fn = fn _sys, _user -> {:error, :llm_timeout} end

    assert {:error, _} = ProposalScorer.judge_score("anything", bug(), llm_fn: fail_fn)
  end
end
