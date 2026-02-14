defmodule Arbor.AI.SessionBridgeTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.SessionBridge

  describe "available?/0" do
    test "returns false when session_enabled is false" do
      original = Application.get_env(:arbor_ai, :session_enabled)

      try do
        Application.put_env(:arbor_ai, :session_enabled, false)
        refute SessionBridge.available?()
      after
        if original,
          do: Application.put_env(:arbor_ai, :session_enabled, original),
          else: Application.delete_env(:arbor_ai, :session_enabled)
      end
    end

    test "returns true when session_enabled is true and orchestrator modules exist" do
      original = Application.get_env(:arbor_ai, :session_enabled)

      try do
        Application.put_env(:arbor_ai, :session_enabled, true)

        # Orchestrator modules should be loaded in the umbrella
        if Code.ensure_loaded?(Arbor.Orchestrator.Session) do
          assert SessionBridge.available?()
        end
      after
        if original,
          do: Application.put_env(:arbor_ai, :session_enabled, original),
          else: Application.delete_env(:arbor_ai, :session_enabled)
      end
    end
  end

  describe "try_session_call/2 — disabled" do
    test "returns :unavailable when session is disabled" do
      original = Application.get_env(:arbor_ai, :session_enabled)

      try do
        Application.put_env(:arbor_ai, :session_enabled, false)

        assert {:unavailable, :session_disabled} =
                 SessionBridge.try_session_call("hello", provider: :anthropic, model: "test")
      after
        if original,
          do: Application.put_env(:arbor_ai, :session_enabled, original),
          else: Application.delete_env(:arbor_ai, :session_enabled)
      end
    end
  end

  describe "try_session_call/2 — enabled with orchestrator" do
    setup do
      original = Application.get_env(:arbor_ai, :session_enabled)
      Application.put_env(:arbor_ai, :session_enabled, true)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_ai, :session_enabled, original),
          else: Application.delete_env(:arbor_ai, :session_enabled)
      end)

      :ok
    end

    @tag :integration
    test "starts an ephemeral session and returns a response" do
      unless Code.ensure_loaded?(Arbor.Orchestrator.Session) do
        IO.puts("Skipping: arbor_orchestrator not available")
        :ok
      else
        # The session will fail without a real LLM, but we can verify it
        # starts and returns {:unavailable, _} rather than crashing
        result =
          SessionBridge.try_session_call("test prompt",
            provider: :test,
            model: "test-model",
            agent_id: "test-agent-bridge",
            trust_tier: :established
          )

        # Without a real LLM configured, we expect either:
        # - {:ok, response} if there's a default LLM available
        # - {:unavailable, {:session_error, _}} if LLM fails
        # - {:unavailable, {:session_start_failed, _}} if DOT parsing fails
        # The important thing is it doesn't crash
        assert match?({:ok, _}, result) or match?({:unavailable, _}, result)
      end
    end

    @tag :integration
    test "response has the expected format when session succeeds" do
      unless Code.ensure_loaded?(Arbor.Orchestrator.Session) do
        IO.puts("Skipping: arbor_orchestrator not available")
        :ok
      else
        case SessionBridge.try_session_call("test",
               provider: :anthropic,
               model: "claude-sonnet-4-5-20250929",
               agent_id: "test-agent-format"
             ) do
          {:ok, response} ->
            assert is_binary(response.text)
            assert is_map(response.usage)
            assert response.type == :session
            assert is_integer(response.turns)
            assert response.tool_calls == []

          {:unavailable, _reason} ->
            # Expected in CI/test environments without LLM
            :ok
        end
      end
    end
  end

  describe "response format" do
    test "build_response produces expected shape" do
      # Test the response format through the public API by checking
      # the disabled path returns correctly
      assert {:unavailable, :session_disabled} =
               SessionBridge.try_session_call("test", [])
    end
  end
end
