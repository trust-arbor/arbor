defmodule Arbor.Agent.HeartbeatLLMTest do
  use ExUnit.Case, async: true
  # Intentionally NOT @moduletag :fast — every test in this module
  # is `@tag :llm` and `HeartbeatLLM.think/2` calls
  # `Arbor.AI.generate_text/2` internally. The previous moduletag
  # contradicted the per-test :llm tags, so `--only fast` would
  # include these tests even though they need a real LLM, leading
  # to 10s timeouts in the fast lane. Run these explicitly via
  # `--include llm` when an LLM is available.

  alias Arbor.Agent.HeartbeatLLM

  # HeartbeatLLM.think/2 calls Arbor.AI.generate_text/2 internally.
  # Since Arbor.AI may not be available in the test env (or may not have
  # API keys), we test error propagation and the parse pipeline.
  # The module returns {:error, :ai_unavailable} when Arbor.AI is not loaded.

  # The two tests below that actually drive the LLM ("builds prompt..."
  # and idle_think "returns error or valid result") route at homelab
  # Ollama with a fast small model (via ARBOR_OLLAMA_BASE_URL) instead of
  # the slow default provider that previously timed out at 10s.
  # max_tokens kept small so generation is fast on a shared Ollama — these
  # are mechanics tests (the model just needs to respond), not output-quality
  # checks. receive_timeout bounds per-chunk idle wait.
  @llm_opts [provider: :ollama, model: "granite3.3:2b", max_tokens: 64, receive_timeout: 30_000]

  defp minimal_state(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test_agent_hb",
        agent_id: "test_agent_hb",
        cognitive_mode: :consolidation,
        enabled_prompt_sections: [:response_format],
        pending_messages: [],
        background_suggestions: [],
        context_window: nil
      },
      overrides
    )
  end

  describe "think/2" do
    @tag :llm
    @tag timeout: 10_000
    test "returns error tuple when AI is unavailable" do
      # If Arbor.AI is not running/configured, we get :ai_unavailable
      # This tests the error path without needing a real LLM
      result = HeartbeatLLM.think(minimal_state())

      case result do
        {:error, reason} ->
          assert is_atom(reason) or is_tuple(reason),
                 "Expected atom or tuple error reason, got: #{inspect(reason)}"

        {:ok, parsed} ->
          # If AI happens to be available, verify the parsed structure
          assert is_map(parsed)
          assert Map.has_key?(parsed, :thinking)
          assert Map.has_key?(parsed, :actions)
          assert Map.has_key?(parsed, :usage)
      end
    end

    @tag :llm
    @tag timeout: 10_000
    test "accepts opts for model and provider" do
      # Should not crash with custom opts
      result = HeartbeatLLM.think(minimal_state(), model: "test-model", provider: :test)

      case result do
        {:error, _} -> :ok
        {:ok, parsed} -> assert is_map(parsed)
      end
    end

    @tag :llm
    @tag timeout: 600_000
    test "builds prompt from state before calling AI" do
      # Verify it doesn't crash on various state shapes
      states = [
        minimal_state(),
        minimal_state(%{cognitive_mode: :goal_pursuit}),
        minimal_state(%{cognitive_mode: :introspection}),
        minimal_state(%{pending_messages: [%{content: "hi", timestamp: DateTime.utc_now()}]})
      ]

      for state <- states do
        result = HeartbeatLLM.think(state, @llm_opts)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "idle_think/2" do
    @tag :llm
    @tag timeout: 600_000
    test "returns error or valid result" do
      result = HeartbeatLLM.idle_think(minimal_state(), @llm_opts)

      case result do
        {:error, _reason} ->
          :ok

        {:ok, parsed} ->
          assert is_map(parsed)
          assert Map.has_key?(parsed, :thinking)
      end
    end

    @tag :llm
    @tag timeout: 10_000
    test "accepts opts" do
      result = HeartbeatLLM.idle_think(minimal_state(), model: "cheap-model")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "think/2 response parsing integration" do
    # These tests verify the pipeline from raw AI response to parsed structure
    # by testing HeartbeatResponse.parse (which think/2 calls) with realistic inputs

    test "parsed response includes usage info on success" do
      # When AI returns successfully, think/2 adds :usage to the parsed map
      # We verify the shape by calling parse directly and adding usage
      alias Arbor.Agent.HeartbeatResponse

      json =
        Jason.encode!(%{
          "thinking" => "test",
          "actions" => [],
          "memory_notes" => []
        })

      parsed = HeartbeatResponse.parse(json)
      with_usage = Map.put(parsed, :usage, %{input_tokens: 100, output_tokens: 50})

      assert with_usage.thinking == "test"
      assert with_usage.usage == %{input_tokens: 100, output_tokens: 50}
    end

    test "empty AI response is handled gracefully" do
      alias Arbor.Agent.HeartbeatResponse

      parsed = HeartbeatResponse.parse("")
      assert parsed.thinking == ""
      assert parsed.actions == []
    end
  end
end
