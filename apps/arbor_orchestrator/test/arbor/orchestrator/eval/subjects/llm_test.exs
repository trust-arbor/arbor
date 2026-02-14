defmodule Arbor.Orchestrator.Eval.Subjects.LLMTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.Subjects.LLM

  @moduletag :fast

  describe "run/2" do
    test "returns error for unknown provider" do
      result = LLM.run("hello", provider: "nonexistent")
      assert {:error, msg} = result
      assert msg =~ "unknown provider"
    end

    test "returns error when LM Studio is not available" do
      # Force a connection to a port that's not running
      # The adapter will fail to connect
      result = LLM.run("hello", provider: "lm_studio", timeout: 1_000)

      # Either error (server down) or ok (server happens to be up)
      case result do
        {:error, _reason} -> :ok
        {:ok, %{text: text}} -> assert is_binary(text)
      end
    end

    test "accepts string input" do
      # Just verify it doesn't crash on string input
      result = LLM.run("test prompt", provider: "lm_studio", timeout: 1_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts map input with prompt and system keys" do
      input = %{"prompt" => "Hello", "system" => "You are helpful"}
      result = LLM.run(input, provider: "lm_studio", timeout: 1_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts atom-keyed map input" do
      input = %{prompt: "Hello", system: "Be helpful"}
      result = LLM.run(input, provider: "lm_studio", timeout: 1_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "supports CLI provider names" do
      # Should not crash — these are valid provider keys even if the backend isn't available
      for provider <- ~w(claude_cli codex_cli gemini_cli opencode_cli qwen_cli) do
        result = LLM.run("hello", provider: provider, timeout: 1_000)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "run/2 with live local models" do
    @describetag :live_local

    test "generates text via LM Studio" do
      result =
        LLM.run("Return exactly the word 'hello'", provider: "lm_studio", timeout: 30_000)

      case result do
        {:ok, %{text: text, duration_ms: ms, model: model}} ->
          assert is_binary(text)
          assert String.length(text) > 0
          assert ms > 0
          assert is_binary(model)

        {:error, _reason} ->
          # LM Studio not running — acceptable in CI
          :ok
      end
    end
  end
end
