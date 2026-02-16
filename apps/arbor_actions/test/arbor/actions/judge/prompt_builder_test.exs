defmodule Arbor.Actions.Judge.PromptBuilderTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Judge.{PromptBuilder, Rubrics}

  @rubric Rubrics.advisory()
  @evidence_summary %{
    "evidence_count" => 3,
    "aggregate_score" => 0.7,
    "all_passed" => true,
    "checks" => [
      %{"type" => "format_compliance", "score" => 0.8, "passed" => true, "detail" => "Valid JSON"}
    ]
  }

  describe "build/5" do
    test "returns system and user prompts" do
      subject = %{content: "test content"}
      {system, user} = PromptBuilder.build(subject, @rubric, @evidence_summary, :critique)

      assert is_binary(system)
      assert is_binary(user)
      assert String.contains?(system, "expert evaluator")
      assert String.contains?(system, "advisory")
      assert String.contains?(user, "test content")
    end

    test "includes evidence in system prompt" do
      subject = %{content: "test"}
      {system, _user} = PromptBuilder.build(subject, @rubric, @evidence_summary, :critique)

      assert String.contains?(system, "format_compliance")
      assert String.contains?(system, "0.7")
    end

    test "includes intent in user prompt when provided" do
      subject = %{content: "test"}

      {_system, user} =
        PromptBuilder.build(subject, @rubric, @evidence_summary, :critique,
          intent: "Review security"
        )

      assert String.contains?(user, "Review security")
    end

    test "includes rubric dimensions in system prompt" do
      subject = %{content: "test"}
      {system, _user} = PromptBuilder.build(subject, @rubric, @evidence_summary, :critique)

      assert String.contains?(system, "depth")
      assert String.contains?(system, "actionability")
      assert String.contains?(system, "0.2")
    end
  end

  describe "parse_response/3" do
    test "parses valid JSON response" do
      response =
        Jason.encode!(%{
          overall_score: 0.75,
          dimension_scores: %{depth: 0.8, actionability: 0.7},
          strengths: ["Good analysis"],
          weaknesses: ["Needs more detail"],
          recommendation: "keep",
          confidence: 0.85
        })

      assert {:ok, verdict} = PromptBuilder.parse_response(response, @rubric, :critique)
      assert verdict.overall_score == 0.75
      assert verdict.recommendation == :keep
      assert verdict.mode == :critique
      assert "Good analysis" in verdict.strengths
    end

    test "parses JSON wrapped in markdown fences" do
      response = """
      ```json
      {"overall_score": 0.6, "recommendation": "revise", "confidence": 0.7, "strengths": [], "weaknesses": ["weak"], "dimension_scores": {}}
      ```
      """

      assert {:ok, verdict} = PromptBuilder.parse_response(response, @rubric, :critique)
      assert verdict.overall_score == 0.6
      assert verdict.recommendation == :revise
    end

    test "rejects invalid JSON" do
      assert {:error, {:invalid_json, _}} =
               PromptBuilder.parse_response("not json", @rubric, :critique)
    end

    test "clamps scores to 0-1 range" do
      response =
        Jason.encode!(%{
          overall_score: 1.5,
          recommendation: "keep",
          confidence: 0.5,
          strengths: [],
          weaknesses: [],
          dimension_scores: %{}
        })

      assert {:ok, verdict} = PromptBuilder.parse_response(response, @rubric, :critique)
      assert verdict.overall_score == 1.0
    end
  end
end
