defmodule Arbor.Orchestrator.Session.ContextBuilderRuntimeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Session.ContextBuilder

  # Minimal state shape that session_base_values/1 can chew on. Real
  # Session state is much richer; we only populate what the function reads.
  defp minimal_state(opts \\ []) do
    %{
      session_id: "sess_test",
      agent_id: "agent_test",
      trust_tier: :established,
      session_type: :primary,
      trace_id: nil,
      signal_topic: "session:test",
      tenant_context: nil,
      # session_state values (turn_count, working_memory, goals, etc.) are
      # read through get_*/1 with state.* fallbacks; provide top-level
      # defaults so neither branch crashes.
      turn_count: 0,
      working_memory: %{},
      goals: [],
      cognitive_mode: :pursuit,
      phase: :idle,
      messages: [],
      compactor: nil,
      discovered_tools: MapSet.new(),
      config: Keyword.get(opts, :config, %{})
    }
  end

  describe "session_base_values/1 — runtime axis (Phase 2d)" do
    test "defaults llm_runtime to :arbor when not set in config" do
      values = ContextBuilder.session_base_values(minimal_state())
      assert values["session.llm_runtime"] == :arbor
    end

    test "propagates llm_runtime from config map string key" do
      values =
        ContextBuilder.session_base_values(minimal_state(config: %{"llm_runtime" => :acp}))

      assert values["session.llm_runtime"] == :acp
    end

    test "propagates llm_runtime from config map atom key (legacy callers)" do
      values =
        ContextBuilder.session_base_values(minimal_state(config: %{llm_runtime: :acp}))

      assert values["session.llm_runtime"] == :acp
    end

    test "still publishes llm_provider and llm_model alongside llm_runtime" do
      values =
        ContextBuilder.session_base_values(
          minimal_state(
            config: %{
              "llm_provider" => "anthropic",
              "llm_model" => "claude-opus-4-6",
              "llm_runtime" => :acp
            }
          )
        )

      assert values["session.llm_provider"] == "anthropic"
      assert values["session.llm_model"] == "claude-opus-4-6"
      assert values["session.llm_runtime"] == :acp
    end
  end

  describe "session_base_values/1 — fallback chain (Phase 4+ B3)" do
    test "defaults llm_fallback_chain to [] when not set in config" do
      values = ContextBuilder.session_base_values(minimal_state())
      assert values["session.llm_fallback_chain"] == []
    end

    test "propagates llm_fallback_chain from config map string key" do
      chain = [%{runtime: :acp}, %{model: "claude-sonnet-4-6"}]

      values =
        ContextBuilder.session_base_values(
          minimal_state(config: %{"llm_fallback_chain" => chain})
        )

      assert values["session.llm_fallback_chain"] == chain
    end

    test "propagates llm_fallback_chain from config map atom key" do
      chain = [%{provider: :openai}]

      values =
        ContextBuilder.session_base_values(minimal_state(config: %{llm_fallback_chain: chain}))

      assert values["session.llm_fallback_chain"] == chain
    end
  end
end
