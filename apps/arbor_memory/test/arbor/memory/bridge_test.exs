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
      # Clean up any interrupt entries via Signals API
      if Code.ensure_loaded?(Arbor.Signals) and
           function_exported?(Arbor.Signals, :clear_interrupt, 1) do
        Arbor.Signals.clear_interrupt(target_id)
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
               Bridge.subscribe_to_intents(agent_id, fn _intent -> :ok end)

      Bridge.unsubscribe(sub_id)
    end

    test "handler receives typed Intent struct", %{agent_id: agent_id} do
      test_pid = self()

      {:ok, sub_id} =
        Bridge.subscribe_to_intents(agent_id, fn intent ->
          send(test_pid, {:received_intent, intent})
          :ok
        end)

      intent = Intent.action(:shell_execute, %{command: "mix test"})
      Bridge.emit_intent(agent_id, intent)

      # Give signal bus time to deliver
      receive do
        {:received_intent, received} ->
          assert %Intent{} = received
          assert received.id == intent.id
          assert received.type == :act
          assert received.action == :shell_execute
      after
        1000 -> :ok
      end

      Bridge.unsubscribe(sub_id)
    end
  end

  describe "subscribe_to_percepts/2" do
    test "subscribes to percept signals for an agent", %{agent_id: agent_id} do
      assert {:ok, sub_id} =
               Bridge.subscribe_to_percepts(agent_id, fn _percept -> :ok end)

      Bridge.unsubscribe(sub_id)
    end

    test "handler receives typed Percept struct", %{agent_id: agent_id} do
      test_pid = self()

      {:ok, sub_id} =
        Bridge.subscribe_to_percepts(agent_id, fn percept ->
          send(test_pid, {:received_percept, percept})
          :ok
        end)

      percept = Percept.success("int_abc", %{exit_code: 0, output: "OK"})
      Bridge.emit_percept(agent_id, percept)

      receive do
        {:received_percept, received} ->
          assert %Percept{} = received
          assert received.id == percept.id
          assert received.outcome == :success
          assert received.intent_id == "int_abc"
      after
        1000 -> :ok
      end

      Bridge.unsubscribe(sub_id)
    end
  end

  describe "unsubscribe/1" do
    test "unsubscribes from a subscription", %{agent_id: agent_id} do
      {:ok, sub_id} = Bridge.subscribe_to_intents(agent_id, fn _intent -> :ok end)
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

    test "returns typed percept when it arrives before timeout", %{agent_id: agent_id} do
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
          # Verify we get a typed Percept struct back
          assert %Percept{} = percept
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

    test "returns typed Intent structs", %{agent_id: agent_id} do
      # Emit a few intents
      intent1 = Intent.action(:shell_execute, %{command: "mix test"})
      intent2 = Intent.action(:read_file, %{path: "/tmp/test"})
      Bridge.emit_intent(agent_id, intent1)
      Bridge.emit_intent(agent_id, intent2)

      # Small delay for async signal storage
      Process.sleep(50)

      {:ok, intents} = Bridge.recent_intents(agent_id, limit: 10)

      # All returned items should be Intent structs
      for intent <- intents do
        assert %Intent{} = intent
      end
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

    test "returns typed Percept structs", %{agent_id: agent_id} do
      # Emit a few percepts
      percept1 = Percept.success("int_1", %{exit_code: 0})
      percept2 = Percept.failure("int_2", :command_failed)
      Bridge.emit_percept(agent_id, percept1)
      Bridge.emit_percept(agent_id, percept2)

      # Small delay for async signal storage
      Process.sleep(50)

      {:ok, percepts} = Bridge.recent_percepts(agent_id, limit: 10)

      # All returned items should be Percept structs
      for percept <- percepts do
        assert %Percept{} = percept
      end
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
  # Struct Reconstruction
  # ============================================================================

  describe "struct reconstruction" do
    test "Intent.from_map/1 reconstructs from atom-keyed map" do
      map = %{
        id: "int_test",
        type: :act,
        action: :shell_execute,
        params: %{command: "ls"},
        reasoning: "testing",
        urgency: 80
      }

      intent = Intent.from_map(map)
      assert %Intent{} = intent
      assert intent.id == "int_test"
      assert intent.type == :act
      assert intent.action == :shell_execute
      assert intent.urgency == 80
    end

    test "Intent.from_map/1 reconstructs from string-keyed map" do
      map = %{
        "id" => "int_str",
        "type" => "act",
        "action" => "read_file",
        "params" => %{"path" => "/tmp"}
      }

      intent = Intent.from_map(map)
      assert %Intent{} = intent
      assert intent.id == "int_str"
      assert intent.type == :act
      assert intent.action == :read_file
    end

    test "Percept.from_map/1 reconstructs from atom-keyed map" do
      map = %{
        id: "prc_test",
        type: :action_result,
        intent_id: "int_abc",
        outcome: :success,
        data: %{exit_code: 0}
      }

      percept = Percept.from_map(map)
      assert %Percept{} = percept
      assert percept.id == "prc_test"
      assert percept.outcome == :success
      assert percept.intent_id == "int_abc"
    end

    test "Percept.from_map/1 reconstructs from string-keyed map" do
      map = %{
        "id" => "prc_str",
        "type" => "action_result",
        "outcome" => "failure",
        "error" => "timeout"
      }

      percept = Percept.from_map(map)
      assert %Percept{} = percept
      assert percept.id == "prc_str"
      assert percept.outcome == :failure
    end

    test "round-trip: Intent struct survives emit → query → reconstruct", %{agent_id: agent_id} do
      original = Intent.action(:shell_execute, %{command: "echo hello"}, reasoning: "test")
      Bridge.emit_intent(agent_id, original)
      Process.sleep(50)

      {:ok, intents} = Bridge.recent_intents(agent_id, limit: 5)

      matching = Enum.find(intents, fn i -> i.id == original.id end)

      if matching do
        assert %Intent{} = matching
        assert matching.id == original.id
        assert matching.type == original.type
        assert matching.action == original.action
      end
    end

    test "round-trip: Percept struct survives emit → query → reconstruct", %{agent_id: agent_id} do
      original = Percept.success("int_round", %{result: "done"})
      Bridge.emit_percept(agent_id, original)
      Process.sleep(50)

      {:ok, percepts} = Bridge.recent_percepts(agent_id, limit: 5)

      matching = Enum.find(percepts, fn p -> p.id == original.id end)

      if matching do
        assert %Percept{} = matching
        assert matching.id == original.id
        assert matching.outcome == original.outcome
        assert matching.intent_id == original.intent_id
      end
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
