defmodule Arbor.AI.Eval.Graders.IntentConformanceTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.Eval.Graders.IntentConformance

  test "parses fenced judge JSON and returns JSON-clean output" do
    judge_fn = fn provider, model, system_prompt, user_prompt, timeout ->
      send(self(), {:judge, provider, model, system_prompt, user_prompt, timeout})

      {:ok,
       """
       <think>private reasoning</think>
       ```json
       {
         "phase_coverage": 0.9,
         "decision_fidelity": 0.8,
         "loop_correctness": 0.7,
         "error_handling": 0.6,
         "handler_types": 0.9,
         "prompt_relevance": 0.8,
         "overall": 0.82,
         "brief_rationale": "The graph covers the workflow."
       }
       ```
       """}
    end

    result =
      IntentConformance.grade("digraph { start -> done }", nil,
        sample_input: %{"prompt" => "Build a two-phase workflow"},
        judge_provider: "test-provider",
        judge_model: "test-model",
        judge_timeout: 789,
        judge_fn: judge_fn
      )

    assert_receive {:judge, "test-provider", "test-model", system_prompt, user_prompt, 789}
    assert system_prompt =~ "phase_coverage"
    assert user_prompt =~ "Build a two-phase workflow"
    assert user_prompt =~ "digraph { start -> done }"
    assert result.score == 0.82
    assert result.passed
    assert result.detail =~ "phase=0.9"
    assert result.detail =~ "The graph covers the workflow."
    assert {:ok, _json} = Jason.encode(result)
  end

  test "computes the weighted score when overall is malformed" do
    response =
      Jason.encode!(%{
        "phase_coverage" => 1.0,
        "decision_fidelity" => 0.8,
        "loop_correctness" => 0.6,
        "error_handling" => 0.4,
        "handler_types" => 0.9,
        "prompt_relevance" => 0.7,
        "overall" => 5
      })

    result =
      IntentConformance.grade("digraph {}", nil,
        sample_input: "A workflow",
        judge_fn: fn _, _, _, _, _ -> {:ok, response} end
      )

    assert result.score == 0.79
    assert result.passed
  end

  test "fails closed on empty or malformed input without calling the judge" do
    judge_fn = fn _, _, _, _, _ ->
      flunk("judge should not be called")
    end

    assert IntentConformance.grade("", nil,
             sample_input: "A workflow",
             judge_fn: judge_fn
           ) == %{score: 0.0, passed: false, detail: "Empty DOT output"}

    assert IntentConformance.grade("digraph {}", nil,
             sample_input: %{},
             judge_fn: judge_fn
           ) == %{score: 0.0, passed: false, detail: "Empty skill input"}

    assert IntentConformance.grade(%{}, nil,
             sample_input: "A workflow",
             judge_fn: judge_fn
           ).detail =~ "dot_text_required"
  end

  test "shapes judge transport and malformed JSON errors" do
    transport_error =
      IntentConformance.grade("digraph {}", nil,
        sample_input: "A workflow",
        judge_fn: fn _, _, _, _, _ -> {:error, :offline} end
      )

    assert transport_error == %{score: 0.0, passed: false, detail: "Judge error: :offline"}

    parse_error =
      IntentConformance.grade("digraph {}", nil,
        sample_input: "A workflow",
        judge_fn: fn _, _, _, _, _ -> {:ok, "not-json"} end
      )

    assert parse_error.score == 0.0
    refute parse_error.passed
    assert parse_error.detail == "JSON parse error: not-json"
    assert {:ok, _json} = Jason.encode(parse_error)
  end
end
