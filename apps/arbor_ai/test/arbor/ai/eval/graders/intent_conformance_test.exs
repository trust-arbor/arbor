defmodule Arbor.AI.Eval.Graders.IntentConformanceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Eval.Graders.IntentConformance
  alias Arbor.LLM.{Client, Request, Response}

  defmodule DefaultJudgeAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "intent-test"

    @impl true
    def complete(%Request{} = request, _opts) do
      response = %{
        "phase_coverage" => 1.0,
        "decision_fidelity" => 1.0,
        "loop_correctness" => 1.0,
        "error_handling" => 1.0,
        "handler_types" => 1.0,
        "prompt_relevance" => 1.0,
        "overall" => 1.0,
        "brief_rationale" => "max_tokens=#{inspect(request.max_tokens)}"
      }

      {:ok, %Response{text: Jason.encode!(response), raw: %{}}}
    end
  end

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

  test "security regression: malformed overall fails the whole grade" do
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

    assert result.score == 0.0
    refute result.passed
    assert result.detail =~ "exact_unit_score_required"
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

  test "security regression: DOT, sample, and combined judge prompts are byte bounded" do
    judge_fn = fn _, _, _, _, _ -> flunk("judge should not be called") end
    oversized_invalid = String.duplicate("x", 1_048_576) <> <<255>>

    dot_result =
      IntentConformance.grade(oversized_invalid, nil,
        sample_input: "workflow",
        judge_fn: judge_fn
      )

    assert dot_result.score == 0.0
    assert dot_result.detail =~ "{:dot, :byte_size_exceeded, 1048576}"
    assert byte_size(dot_result.detail) <= 1_024

    sample_result =
      IntentConformance.grade("digraph {}", nil,
        sample_input: oversized_invalid,
        judge_fn: judge_fn
      )

    assert sample_result.score == 0.0
    assert sample_result.detail =~ "{:skill, :byte_size_exceeded, 1048576}"

    total_result =
      IntentConformance.grade(String.duplicate("d", 800_000), nil,
        sample_input: String.duplicate("s", 800_000),
        judge_fn: judge_fn
      )

    assert total_result.score == 0.0
    assert total_result.detail =~ "judge_prompt_bytes_exceeded"
    assert byte_size(total_result.detail) <= 1_024
  end

  test "security regression: huge judge callback reasons are bounded" do
    huge_reason = {:provider_error, List.duplicate(String.duplicate("e", 2_000), 100_000)}

    result =
      IntentConformance.grade("digraph {}", nil,
        sample_input: "workflow",
        judge_fn: fn _, _, _, _, _ -> {:error, huge_reason} end
      )

    assert result.score == 0.0
    assert byte_size(result.detail) <= 1_024
    assert String.valid?(result.detail)
    assert result.detail =~ "provider_error"
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

  test "default judge leaves max_tokens unset and forwards an explicit positive value" do
    client = Client.new() |> Client.register_adapter(DefaultJudgeAdapter)
    Client.set_default_client(client)
    on_exit(fn -> Client.clear_default_client() end)

    base_opts = [
      sample_input: "A workflow",
      judge_provider: "intent-test",
      judge_model: "judge-model"
    ]

    unset = IntentConformance.grade("digraph {}", nil, base_opts)
    assert unset.detail =~ "max_tokens=nil"

    explicit =
      IntentConformance.grade(
        "digraph {}",
        nil,
        Keyword.put(base_opts, :max_tokens, 1_000_000)
      )

    assert explicit.detail =~ "max_tokens=1000000"

    invalid =
      IntentConformance.grade(
        "digraph {}",
        nil,
        Keyword.put(base_opts, :max_tokens, 0)
      )

    assert invalid.score == 0.0
    assert invalid.detail =~ "positive_integer_required"
  end

  test "security regression: judge rationale and detail have hard UTF-8 byte ceilings" do
    combining_rationale = "a" <> String.duplicate("\u0301", 10_000)

    response =
      Jason.encode!(%{
        "phase_coverage" => 1.0,
        "decision_fidelity" => 1.0,
        "loop_correctness" => 1.0,
        "error_handling" => 1.0,
        "handler_types" => 1.0,
        "prompt_relevance" => 1.0,
        "overall" => 1.0,
        "brief_rationale" => combining_rationale
      })

    result =
      IntentConformance.grade("digraph {}", nil,
        sample_input: "A workflow",
        judge_fn: fn _, _, _, _, _ -> {:ok, response} end
      )

    assert byte_size(result.detail) <= 1_024
    refute result.detail =~ combining_rationale
    assert {:ok, _json} = Jason.encode(result)

    malformed =
      IntentConformance.grade("digraph {}", nil,
        sample_input: "A workflow",
        judge_fn: fn _, _, _, _, _ -> {:ok, <<"not-json", 255>>} end
      )

    assert byte_size(malformed.detail) <= 1_024
    assert {:ok, _json} = Jason.encode(malformed)
  end

  test "security regression: out-of-range judge scores never clamp into success" do
    huge_integer = String.duplicate("9", 1_000)

    response =
      """
      {
        "phase_coverage": 9,
        "decision_fidelity": 9,
        "loop_correctness": 9,
        "error_handling": 9,
        "handler_types": 9,
        "prompt_relevance": 9,
        "overall": 9,
        "brief_rationale": "#{huge_integer}"
      }
      """

    result =
      IntentConformance.grade("digraph {}", nil,
        sample_input: "A workflow",
        judge_fn: fn _, _, _, _, _ -> {:ok, response} end
      )

    assert result.score == 0.0
    refute result.passed
    assert result.detail =~ "exact_unit_score_required"
  end
end
