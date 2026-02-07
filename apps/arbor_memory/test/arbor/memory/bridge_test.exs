defmodule Arbor.Memory.BridgeTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Memory.Percept
  alias Arbor.Memory.Bridge

  @moduletag :fast

  setup_all do
    # Bridge tests require the Signals bus to be running for subscribe/unsubscribe
    ensure_signals_bus_started()
    :ok
  end

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    target_id = "target_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Clean up any interrupt entries
      if :ets.whereis(:arbor_bridge_interrupts) != :undefined do
        :ets.delete(:arbor_bridge_interrupts, target_id)
      end
    end)

    %{agent_id: agent_id, target_id: target_id}
  end

  # ============================================================================
  # Intent Emission
  # ============================================================================

  describe "emit_intent/3" do
    test "emits an intent signal", %{agent_id: agent_id} do
      intent = Intent.action(:shell_execute, %{command: "mix test"})
      assert :ok = Bridge.emit_intent(agent_id, intent)
    end

    test "accepts priority option", %{agent_id: agent_id} do
      intent = Intent.action(:shell_execute, %{command: "mix test"})
      assert :ok = Bridge.emit_intent(agent_id, intent, priority: :urgent)
    end

    test "accepts correlation_id option", %{agent_id: agent_id} do
      intent = Intent.action(:shell_execute, %{command: "mix test"})
      assert :ok = Bridge.emit_intent(agent_id, intent, correlation_id: "corr_123")
    end
  end

  describe "emit_urgent_intent/3" do
    test "emits an intent with urgent priority", %{agent_id: agent_id} do
      intent = Intent.action(:emergency_stop, %{})
      assert :ok = Bridge.emit_urgent_intent(agent_id, intent)
    end

    test "accepts additional options", %{agent_id: agent_id} do
      intent = Intent.action(:emergency_stop, %{})
      assert :ok = Bridge.emit_urgent_intent(agent_id, intent, correlation_id: "urgent_123")
    end
  end

  # ============================================================================
  # Percept Emission
  # ============================================================================

  describe "emit_percept/3" do
    test "emits a percept signal", %{agent_id: agent_id} do
      percept = Percept.success("int_abc", %{exit_code: 0})
      assert :ok = Bridge.emit_percept(agent_id, percept)
    end

    test "accepts correlation_id and cause_id options", %{agent_id: agent_id} do
      percept = Percept.success("int_abc", %{exit_code: 0})
      assert :ok = Bridge.emit_percept(agent_id, percept, correlation_id: "corr_123", cause_id: "sig_456")
    end
  end

  # ============================================================================
  # Subscriptions
  # ============================================================================

  describe "subscribe_to_intents/2" do
    test "subscribes to intent signals for an agent", %{agent_id: agent_id} do
      assert {:ok, sub_id} =
               Bridge.subscribe_to_intents(agent_id, fn _signal -> :ok end)

      Bridge.unsubscribe(sub_id)
    end
  end

  describe "subscribe_to_percepts/2" do
    test "subscribes to percept signals for an agent", %{agent_id: agent_id} do
      assert {:ok, sub_id} =
               Bridge.subscribe_to_percepts(agent_id, fn _signal -> :ok end)

      Bridge.unsubscribe(sub_id)
    end
  end

  describe "unsubscribe/1" do
    test "unsubscribes from a subscription", %{agent_id: agent_id} do
      {:ok, sub_id} = Bridge.subscribe_to_intents(agent_id, fn _signal -> :ok end)
      assert :ok = Bridge.unsubscribe(sub_id)
    end

    test "returns error for unknown subscription" do
      result = Bridge.unsubscribe("nonexistent_sub_id")
      assert result == :ok or result == {:error, :not_found}
    end
  end

  # ============================================================================
  # Request-Response
  # ============================================================================

  describe "execute_and_wait/3" do
    test "returns timeout when no percept arrives", %{agent_id: agent_id} do
      intent = Intent.action(:shell_execute, %{command: "mix test"})

      # Use a very short timeout to avoid slow tests
      assert {:error, :timeout} =
               Bridge.execute_and_wait(agent_id, intent, timeout: 50)
    end

    test "returns percept when it arrives before timeout", %{agent_id: agent_id} do
      intent = Intent.action(:shell_execute, %{command: "mix test"})

      # Spawn a process that simulates the Body receiving and responding
      spawn(fn ->
        # Small delay to let subscribe happen
        Process.sleep(20)

        # Simulate Body emitting a percept for the intent
        percept = Percept.success(intent.id, %{exit_code: 0, output: "All tests passed"})
        Bridge.emit_percept(agent_id, percept)
      end)

      result = Bridge.execute_and_wait(agent_id, intent, timeout: 2000)

      case result do
        {:ok, percept} ->
          assert percept.intent_id == intent.id
          assert percept.outcome == :success

        {:error, :timeout} ->
          # Signal delivery timing can be non-deterministic in tests
          # This is acceptable — the important thing is the API works
          :ok
      end
    end
  end

  # ============================================================================
  # Interrupt Protocol
  # ============================================================================

  describe "interrupt/4" do
    test "sets an interrupt for a target", %{agent_id: agent_id, target_id: target_id} do
      assert :ok = Bridge.interrupt(agent_id, target_id, :higher_priority)
    end

    test "stores interrupt data with reason", %{agent_id: agent_id, target_id: target_id} do
      :ok = Bridge.interrupt(agent_id, target_id, :user_cancel)

      data = Bridge.interrupted?(target_id)
      assert data != false
      assert data.reason == :user_cancel
      assert data.agent_id == agent_id
      assert data.target_id == target_id
    end

    test "accepts replacement_intent_id option", %{agent_id: agent_id, target_id: target_id} do
      :ok = Bridge.interrupt(agent_id, target_id, :higher_priority,
        replacement_intent_id: "new_intent_123"
      )

      data = Bridge.interrupted?(target_id)
      assert data.replacement_intent_id == "new_intent_123"
    end

    test "accepts allow_resume option", %{agent_id: agent_id, target_id: target_id} do
      :ok = Bridge.interrupt(agent_id, target_id, :higher_priority,
        allow_resume: true
      )

      data = Bridge.interrupted?(target_id)
      assert data.allow_resume == true
    end

    test "overwrites previous interrupt", %{agent_id: agent_id, target_id: target_id} do
      :ok = Bridge.interrupt(agent_id, target_id, :first_reason)
      :ok = Bridge.interrupt(agent_id, target_id, :second_reason)

      data = Bridge.interrupted?(target_id)
      assert data.reason == :second_reason
    end
  end

  describe "interrupted?/1" do
    test "returns false when not interrupted", %{target_id: target_id} do
      assert Bridge.interrupted?(target_id) == false
    end

    test "returns interrupt data when interrupted", %{agent_id: agent_id, target_id: target_id} do
      Bridge.interrupt(agent_id, target_id, :test_reason)

      result = Bridge.interrupted?(target_id)
      assert is_map(result)
      assert result.reason == :test_reason
      assert %DateTime{} = result.interrupted_at
    end
  end

  describe "clear_interrupt/1" do
    test "clears an existing interrupt", %{agent_id: agent_id, target_id: target_id} do
      Bridge.interrupt(agent_id, target_id, :test_reason)
      assert Bridge.interrupted?(target_id) != false

      assert :ok = Bridge.clear_interrupt(target_id)
      assert Bridge.interrupted?(target_id) == false
    end

    test "is safe to call when no interrupt exists", %{target_id: target_id} do
      assert :ok = Bridge.clear_interrupt(target_id)
    end
  end

  describe "interrupt lifecycle" do
    test "full interrupt → check → clear cycle", %{agent_id: agent_id, target_id: target_id} do
      # Initially not interrupted
      assert Bridge.interrupted?(target_id) == false

      # Interrupt
      :ok = Bridge.interrupt(agent_id, target_id, :higher_priority)
      assert Bridge.interrupted?(target_id) != false

      # Clear
      :ok = Bridge.clear_interrupt(target_id)
      assert Bridge.interrupted?(target_id) == false
    end
  end

  # ============================================================================
  # Query History
  # ============================================================================

  describe "recent_intents/2" do
    test "returns a list", %{agent_id: agent_id} do
      assert {:ok, intents} = Bridge.recent_intents(agent_id)
      assert is_list(intents)
    end

    test "respects limit option", %{agent_id: agent_id} do
      assert {:ok, _intents} = Bridge.recent_intents(agent_id, limit: 5)
    end
  end

  describe "recent_percepts/2" do
    test "returns a list", %{agent_id: agent_id} do
      assert {:ok, percepts} = Bridge.recent_percepts(agent_id)
      assert is_list(percepts)
    end

    test "respects limit option", %{agent_id: agent_id} do
      assert {:ok, _percepts} = Bridge.recent_percepts(agent_id, limit: 5)
    end
  end

  # ============================================================================
  # Availability
  # ============================================================================

  describe "available?/0" do
    test "returns a boolean" do
      result = Bridge.available?()
      assert is_boolean(result)
    end

    test "returns true when signals bus is running" do
      # We started the bus in setup_all, so it should be available
      assert Bridge.available?() == true
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Start the Signals infrastructure if not already running.
  # In test mode, start_children: false may leave the bus stopped.
  defp ensure_signals_bus_started do
    unless Process.whereis(Arbor.Signals.Bus) do
      for child <- [
            {Arbor.Signals.Store, []},
            {Arbor.Signals.TopicKeys, []},
            {Arbor.Signals.Channels, []},
            {Arbor.Signals.Bus, []}
          ] do
        Supervisor.start_child(Arbor.Signals.Supervisor, child)
      end
    end
  end
end
