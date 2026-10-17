defmodule Arbor.Orchestrator.Session.BuildersUserWaitingTest do
  @moduledoc """
  User-initiated turns must set `session.user_waiting` so ModeSelect
  chooses conversation instead of reflection / plan_execution.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Actions.Session, as: SessionActions
  alias Arbor.Orchestrator.Session.Builders

  defp minimal_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "sess_user_waiting",
        agent_id: "agent_test",
        trust_tier: :established,
        session_type: :primary,
        trace_id: nil,
        signal_topic: "session:test",
        tenant_context: nil,
        turn_count: 1,
        working_memory: %{},
        goals: [],
        cognitive_mode: :reflection,
        phase: :idle,
        messages: [],
        compactor: nil,
        discovered_tools: MapSet.new(),
        config: %{}
      },
      overrides
    )
  end

  describe "build_turn_values/2 — user-initiated turns" do
    test "sets user_waiting so ordinary turns select conversation, not reflection" do
      values = Builders.build_turn_values(minimal_state(), "What is OTP?")

      assert values["session.user_waiting"] == true

      assert {:ok, %{cognitive_mode: "conversation"}} =
               SessionActions.ModeSelect.run(values, %{})
    end

    test "sets user_waiting so a turn with goals selects conversation, not plan_execution" do
      state = minimal_state(%{goals: [%{"id" => "g1", "description" => "learn Elixir"}]})
      values = Builders.build_turn_values(state, "How do I start?")

      assert values["session.user_waiting"] == true

      assert {:ok, %{cognitive_mode: "conversation"}} =
               SessionActions.ModeSelect.run(values, %{})
    end
  end

  describe "build_heartbeat_values/1 — autonomous beats" do
    test "does not mark the user as waiting" do
      values = Builders.build_heartbeat_values(minimal_state())

      assert values["session.user_waiting"] == false
      assert values["session.is_heartbeat"] == true

      assert {:ok, %{cognitive_mode: "reflection"}} =
               SessionActions.ModeSelect.run(values, %{})
    end
  end
end
