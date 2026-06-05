defmodule Arbor.Orchestrator.Session.BuildersRuntimeTest do
  @moduledoc """
  Pin the runtime-axis end of the heartbeat path: that
  `Builders.build_heartbeat_values/1` inherits `session.llm_runtime`
  from `state.config["llm_runtime"]` via `ContextBuilder.session_base_values/1`.

  `ContextBuilderRuntimeTest` already covers the Builder hop; this
  closes the gap between that hop and the heartbeat-specific values
  the engine actually receives — making the heartbeat-runtime
  guarantee explicit at the layer that builds the heartbeat context.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Session.Builders

  defp minimal_state(opts \\ []) do
    %{
      session_id: "sess_test",
      agent_id: "agent_test",
      trust_tier: :established,
      session_type: :primary,
      trace_id: nil,
      signal_topic: "session:test",
      tenant_context: nil,
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

  describe "build_heartbeat_values/1 — runtime axis inheritance" do
    test "inherits llm_runtime :acp from session config" do
      values = Builders.build_heartbeat_values(minimal_state(config: %{"llm_runtime" => :acp}))

      assert values["session.llm_runtime"] == :acp
      # Heartbeat-specific marker is also present so we know the heartbeat
      # branch ran, not just session_base_values.
      assert values["session.is_heartbeat"] == true
    end

    test "defaults llm_runtime to :arbor when not set" do
      values = Builders.build_heartbeat_values(minimal_state())

      assert values["session.llm_runtime"] == :arbor
      assert values["session.is_heartbeat"] == true
    end

    test "messages stay empty in heartbeat values regardless of runtime" do
      values = Builders.build_heartbeat_values(minimal_state(config: %{"llm_runtime" => :acp}))

      assert values["session.messages"] == []
    end
  end
end
