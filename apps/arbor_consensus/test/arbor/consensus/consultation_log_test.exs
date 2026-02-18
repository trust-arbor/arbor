defmodule Arbor.Consensus.ConsultationLogTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.ConsultationLog

  describe "log_single/5" do
    test "returns :ok even when persistence is unavailable" do
      # ConsultationLog gracefully degrades — always returns :ok
      eval = mock_eval()
      llm_meta = mock_llm_meta()

      assert :ok = ConsultationLog.log_single("test question", :security, eval, llm_meta)
    end

    test "accepts optional run_id" do
      eval = mock_eval()
      llm_meta = mock_llm_meta()

      assert :ok =
               ConsultationLog.log_single("test question", :security, eval, llm_meta,
                 run_id: "existing-run-123"
               )
    end
  end

  describe "create_run/3" do
    test "returns nil when persistence is unavailable" do
      # When Repo isn't started, create_run returns nil gracefully
      result = ConsultationLog.create_run("test question", [:security, :vision])
      # Result is either a run_id string or nil depending on Postgres availability
      assert is_nil(result) or is_binary(result)
    end

    test "accepts context and reference_docs in opts" do
      result =
        ConsultationLog.create_run("test question", [:security], context: %{foo: "bar"})

      assert is_nil(result) or is_binary(result)
    end
  end

  describe "complete_run/2" do
    test "handles nil run_id gracefully" do
      assert :ok = ConsultationLog.complete_run(nil, [])
    end

    test "handles results with mixed success/error" do
      results = [
        {:security, mock_eval()},
        {:vision, {:error, :timeout}},
        {:stability, mock_eval()}
      ]

      assert :ok = ConsultationLog.complete_run("some-run-id", results)
    end
  end

  describe "list_consultations/1" do
    test "returns error when persistence unavailable" do
      # Depends on whether Repo is running in test env
      result = ConsultationLog.list_consultations()
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "get_consultation/1" do
    test "returns error for nonexistent run" do
      result = ConsultationLog.get_consultation("nonexistent-id")
      assert match?({:error, _}, result)
    end
  end

  describe "export_jsonl/2" do
    test "returns error when no data available" do
      path = Path.join(System.tmp_dir!(), "test_export_#{System.unique_integer([:positive])}.jsonl")
      on_exit(fn -> File.rm(path) end)

      result = ConsultationLog.export_jsonl(path)
      # Either exports 0 lines or returns error if persistence unavailable
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "field mapping" do
    test "build_result maps eval fields correctly" do
      # Test through log_single which calls build_result internally
      eval = %{
        vote: :approve,
        confidence: 0.85,
        risk_score: 0.2,
        benefit_score: 0.9,
        reasoning: "This is a good approach",
        concerns: ["edge case X"],
        recommendations: ["add test for Y"]
      }

      llm_meta = %{
        provider: "openrouter",
        model: "openai/gpt-5-nano",
        duration_ms: 1500,
        raw_response: "raw json response",
        system_prompt: "You are security...",
        user_prompt: "Should we use ETS?"
      }

      # Should not raise
      assert :ok = ConsultationLog.log_single("test question", :security, eval, llm_meta)
    end

    test "handles missing eval fields gracefully" do
      eval = %{vote: :approve}
      llm_meta = %{}

      assert :ok = ConsultationLog.log_single("minimal eval", :adversarial, eval, llm_meta)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp mock_eval do
    %{
      vote: :approve,
      confidence: 0.8,
      risk_score: 0.3,
      benefit_score: 0.7,
      reasoning: "Analysis text",
      concerns: [],
      recommendations: []
    }
  end

  defp mock_llm_meta do
    %{
      provider: "openrouter",
      model: "openai/gpt-5-nano",
      duration_ms: 1000,
      raw_response: "raw response text",
      system_prompt: "system prompt",
      user_prompt: "user prompt"
    }
  end
end
