defmodule Arbor.Consensus.EvaluatorBackend.LLMTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Config
  alias Arbor.Consensus.EvaluatorBackend.LLM
  alias Arbor.Contracts.Consensus.Evaluation
  alias Arbor.Contracts.Consensus.Proposal

  # Mock AI module for testing
  defmodule MockAI do
    @behaviour Arbor.Contracts.API.AI

    @impl true
    def generate_text(prompt, opts) do
      # Check if we're testing timeout
      if String.contains?(prompt, "TIMEOUT_TEST") do
        Process.sleep(10_000)
        {:ok, %{text: "never reached", usage: %{}, model: "test", provider: :mock}}
      else
        system_prompt = Keyword.get(opts, :system_prompt, "")
        response = generate_mock_response(prompt, system_prompt)
        {:ok, response}
      end
    end

    defp generate_mock_response(prompt, system_prompt) do
      cond do
        # Check prompt-based triggers first (for test control)
        String.contains?(prompt, "ERROR_TEST") ->
          %{
            text: "This is not valid JSON at all - no approve or reject",
            usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
            model: "test-model",
            provider: :mock
          }

        String.contains?(prompt, "APPROVE_TEXT") ->
          %{
            text: "I approve this change because it looks good",
            usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
            model: "test-model",
            provider: :mock
          }

        # Then check system prompt for perspective-specific responses
        String.contains?(system_prompt, "security") ->
          %{
            text: ~s({"vote": "approve", "reasoning": "No security issues found", "concerns": []}),
            usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
            model: "test-model",
            provider: :mock
          }

        String.contains?(system_prompt, "architecture") ->
          %{
            text:
              ~s({"vote": "reject", "reasoning": "Coupling issues detected", "suggestions": ["Consider DI"]}),
            usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
            model: "test-model",
            provider: :mock
          }

        true ->
          %{
            text: ~s({"vote": "approve", "reasoning": "Default approval"}),
            usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
            model: "test-model",
            provider: :mock
          }
      end
    end
  end

  defmodule ErrorAI do
    @behaviour Arbor.Contracts.API.AI

    @impl true
    def generate_text(_prompt, _opts) do
      {:error, :api_error}
    end
  end

  setup do
    {:ok, proposal} =
      Proposal.new(%{
        proposer: "test_agent",
        change_type: :code_modification,
        description: "Test proposal for LLM evaluation",
        code_diff: "- old_code\n+ new_code",
        new_code: "defmodule Test do\n  def hello, do: :world\nend",
        metadata: %{}
      })

    {:ok, proposal: proposal}
  end

  describe "supported_perspectives/0" do
    test "returns all supported LLM perspectives" do
      perspectives = LLM.supported_perspectives()

      assert :security_llm in perspectives
      assert :architecture_llm in perspectives
      assert :code_quality_llm in perspectives
      assert :performance_llm in perspectives
    end
  end

  describe "evaluate/3 with security perspective" do
    test "returns approval with structured JSON response", %{proposal: proposal} do
      {:ok, evaluation} =
        LLM.evaluate(proposal, :security_llm, ai_module: MockAI)

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :security_llm
      assert evaluation.vote == :approve
      assert evaluation.reasoning == "No security issues found"
      assert evaluation.concerns == []
      assert evaluation.sealed == true
      assert evaluation.confidence > 0
    end
  end

  describe "evaluate/3 with architecture perspective" do
    test "returns rejection with suggestions", %{proposal: proposal} do
      {:ok, evaluation} =
        LLM.evaluate(proposal, :architecture_llm, ai_module: MockAI)

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :architecture_llm
      assert evaluation.vote == :reject
      assert evaluation.reasoning =~ "Coupling"
      assert evaluation.recommendations == ["Consider DI"]
      assert evaluation.sealed == true
    end
  end

  describe "evaluate/3 with invalid JSON response" do
    test "falls back to text detection" do
      # Create proposal to trigger error response
      {:ok, error_proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "ERROR_TEST proposal"
        })

      {:ok, evaluation} =
        LLM.evaluate(error_proposal, :security_llm, ai_module: MockAI)

      assert %Evaluation{} = evaluation
      # Can't detect vote from "This is not valid JSON at all - no approve or reject"
      assert evaluation.vote == :abstain
      assert evaluation.sealed == true
    end

    test "detects approve from text when JSON fails" do
      {:ok, approve_proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "APPROVE_TEXT proposal"
        })

      {:ok, evaluation} =
        LLM.evaluate(approve_proposal, :security_llm, ai_module: MockAI)

      assert %Evaluation{} = evaluation
      assert evaluation.vote == :approve
    end
  end

  describe "evaluate/3 with AI error" do
    test "returns abstain on LLM error", %{proposal: proposal} do
      {:ok, evaluation} =
        LLM.evaluate(proposal, :security_llm, ai_module: ErrorAI)

      assert %Evaluation{} = evaluation
      assert evaluation.vote == :abstain
      assert evaluation.reasoning =~ "LLM error"
      assert evaluation.confidence == 0.0
      assert evaluation.sealed == true
    end
  end

  describe "evaluate/3 with timeout" do
    @tag :slow
    test "returns abstain on timeout" do
      {:ok, timeout_proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "TIMEOUT_TEST proposal"
        })

      {:ok, evaluation} =
        LLM.evaluate(timeout_proposal, :security_llm,
          ai_module: MockAI,
          timeout: 100
        )

      assert %Evaluation{} = evaluation
      assert evaluation.vote == :abstain
      assert evaluation.reasoning =~ "timeout"
      assert evaluation.sealed == true
    end
  end

  describe "evaluate/3 with unsupported perspective" do
    test "returns abstain for unsupported perspective", %{proposal: proposal} do
      {:ok, evaluation} =
        LLM.evaluate(proposal, :unknown_perspective, ai_module: MockAI)

      assert %Evaluation{} = evaluation
      assert evaluation.vote == :abstain
      assert evaluation.reasoning =~ "Unsupported LLM perspective"
      assert evaluation.sealed == true
    end
  end

  describe "Config integration" do
    test "llm_evaluator_timeout/0 returns positive integer" do
      assert Config.llm_evaluator_timeout() > 0
    end

    test "llm_perspectives/0 returns LLM perspective list" do
      perspectives = Config.llm_perspectives()
      assert is_list(perspectives)
      assert :security_llm in perspectives
    end

    test "llm_evaluators_enabled?/0 returns boolean" do
      assert is_boolean(Config.llm_evaluators_enabled?())
    end
  end
end
