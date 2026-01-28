defmodule Arbor.Trust.EventHandlerTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust.EventHandler

  import Arbor.Trust.TestHelpers, only: [safe_stop: 1]

  @moduletag :fast

  # We test the EventHandler GenServer callbacks directly where possible,
  # since the full PubSub and Manager dependencies may not be running.
  # For handle_info tests, we call the callbacks directly on the state struct.

  describe "start_link/1 and init/1" do
    test "starts with enabled: false" do
      {:ok, pid} = EventHandler.start_link(enabled: false)
      assert Process.alive?(pid)

      # Clean up - stop with a unique ref to avoid name conflicts
      GenServer.stop(pid)
    end

    test "initializes state with enabled flag" do
      # Test init directly
      assert {:ok, %EventHandler{enabled: false, subscriptions: []}} =
               EventHandler.init(enabled: false)
    end

    test "defaults to enabled: true" do
      # When PubSub is not running, init still succeeds (subscribe_to_topics rescues)
      assert {:ok, %EventHandler{enabled: true, subscriptions: []}} = EventHandler.init([])
    end

    test "init with enabled: true attempts PubSub subscription without crashing" do
      # PubSub is not running, but subscribe_to_topics rescues errors
      assert {:ok, %EventHandler{enabled: true}} = EventHandler.init(enabled: true)
    end
  end

  describe "handle_call :enable/:disable/:enabled?" do
    test "enable sets enabled to true" do
      state = %EventHandler{enabled: false, subscriptions: []}
      assert {:reply, :ok, %EventHandler{enabled: true}} =
               EventHandler.handle_call(:enable, self(), state)
    end

    test "disable sets enabled to false" do
      state = %EventHandler{enabled: true, subscriptions: []}
      assert {:reply, :ok, %EventHandler{enabled: false}} =
               EventHandler.handle_call(:disable, self(), state)
    end

    test "enabled? returns current enabled status" do
      state_enabled = %EventHandler{enabled: true, subscriptions: []}
      state_disabled = %EventHandler{enabled: false, subscriptions: []}

      assert {:reply, true, ^state_enabled} =
               EventHandler.handle_call(:enabled?, self(), state_enabled)

      assert {:reply, false, ^state_disabled} =
               EventHandler.handle_call(:enabled?, self(), state_disabled)
    end
  end

  describe "handle_info - action events" do
    test "handles :action_executed with success status when enabled" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", status: :success, action: :read, duration_ms: 100}

      # Manager is not running so record_trust_event will be a cast that goes nowhere,
      # but the handler should not crash
      assert {:noreply, ^state} =
               EventHandler.handle_info({:action_executed, event}, state)
    end

    test "handles :action_executed with failure status when enabled" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", status: :failure, action: :write, error: :timeout}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:action_executed, event}, state)
    end

    test "ignores :action_executed when disabled" do
      state = %EventHandler{enabled: false, subscriptions: []}
      event = %{agent_id: "agent_test", status: :success, action: :read}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:action_executed, event}, state)
    end

    test "handles :action_executed without agent_id gracefully" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{status: :success}

      # Missing agent_id - the private handle_action_event/1 catch-all returns :ok
      assert {:noreply, ^state} =
               EventHandler.handle_info({:action_executed, event}, state)
    end
  end

  describe "handle_info - cluster events" do
    test "handles :cluster_event :agent_started" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_cluster", action: :start}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:cluster_event, :agent_started, event}, state)
    end

    test "handles :cluster_event :agent_failed" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_cluster", error: :crash}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:cluster_event, :agent_failed, event}, state)
    end

    test "ignores cluster events when disabled" do
      state = %EventHandler{enabled: false, subscriptions: []}
      event = %{agent_id: "agent_cluster"}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:cluster_event, :agent_started, event}, state)

      assert {:noreply, ^state} =
               EventHandler.handle_info({:cluster_event, :agent_failed, event}, state)
    end
  end

  describe "handle_info - self-test events" do
    test "handles :self_test_completed with passed result" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", result: :passed, test_name: "unit_test", duration_ms: 50}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:self_test_completed, event}, state)
    end

    test "handles :self_test_completed with failed result" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", result: :failed, test_name: "integration_test", error: :assertion}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:self_test_completed, event}, state)
    end

    test "handles :self_test_passed event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", test_name: "smoke_test"}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:self_test_passed, event}, state)
    end

    test "handles :self_test_failed event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", test_name: "smoke_test", error: :timeout}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:self_test_failed, event}, state)
    end

    test "ignores test events when disabled" do
      state = %EventHandler{enabled: false, subscriptions: []}
      event = %{agent_id: "agent_test", result: :passed}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:self_test_completed, event}, state)
    end
  end

  describe "handle_info - improvement events" do
    test "handles :rollback_executed event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", commit: "abc123", reason: :test_failure, reverted_to: "def456"}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:rollback_executed, event}, state)
    end

    test "handles :improvement_applied event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", improvement_type: :refactor, commit: "abc123", changes: 5}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:improvement_applied, event}, state)
    end

    test "handles :reload_succeeded event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", module: SomeModule}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:reload_succeeded, event}, state)
    end

    test "handles :reload_failed event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", module: SomeModule, error: :compilation_error}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:reload_failed, event}, state)
    end

    test "handles :compilation_succeeded event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test"}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:compilation_succeeded, event}, state)
    end

    test "handles :compilation_failed event" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_test", error: :syntax_error}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:compilation_failed, event}, state)
    end

    test "ignores improvement events when disabled" do
      state = %EventHandler{enabled: false, subscriptions: []}

      assert {:noreply, ^state} =
               EventHandler.handle_info(
                 {:rollback_executed, %{agent_id: "agent_test"}},
                 state
               )

      assert {:noreply, ^state} =
               EventHandler.handle_info(
                 {:improvement_applied, %{agent_id: "agent_test"}},
                 state
               )
    end

    test "handles rollback event without agent_id gracefully" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{commit: "abc123"}

      # Missing agent_id - handle_rollback_event catch-all returns :ok
      assert {:noreply, ^state} =
               EventHandler.handle_info({:rollback_executed, event}, state)
    end

    test "handles improvement event without agent_id gracefully" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{improvement_type: :refactor}

      assert {:noreply, ^state} =
               EventHandler.handle_info({:improvement_applied, event}, state)
    end
  end

  describe "handle_info - security events" do
    test "handles :authorization_denied with policy_violation reason" do
      state = %EventHandler{enabled: true, subscriptions: []}

      event = %{
        principal_id: "agent_test",
        reason: :policy_violation,
        resource_uri: "arbor://code/write/forbidden",
        operation: :write,
        policy: :security_boundary
      }

      assert {:noreply, ^state} =
               EventHandler.handle_info({:authorization_denied, event}, state)
    end

    test "ignores :authorization_denied without policy_violation reason" do
      state = %EventHandler{enabled: true, subscriptions: []}

      event = %{
        principal_id: "agent_test",
        reason: :expired_capability,
        resource_uri: "arbor://code/read/data"
      }

      # Non-policy_violation reasons are ignored by the catch-all
      assert {:noreply, ^state} =
               EventHandler.handle_info({:authorization_denied, event}, state)
    end

    test "handles :policy_violation event" do
      state = %EventHandler{enabled: true, subscriptions: []}

      event = %{
        principal_id: "agent_test",
        resource_uri: "arbor://code/write/protected",
        operation: :write,
        violation_type: :boundary_violation
      }

      assert {:noreply, ^state} =
               EventHandler.handle_info({:policy_violation, event}, state)
    end

    test "handles :policy_violation without principal_id gracefully" do
      state = %EventHandler{enabled: true, subscriptions: []}

      event = %{
        resource_uri: "arbor://code/write/protected",
        violation_type: :boundary_violation
      }

      assert {:noreply, ^state} =
               EventHandler.handle_info({:policy_violation, event}, state)
    end

    test "ignores security events when disabled" do
      state = %EventHandler{enabled: false, subscriptions: []}

      assert {:noreply, ^state} =
               EventHandler.handle_info(
                 {:authorization_denied,
                  %{principal_id: "agent_test", reason: :policy_violation}},
                 state
               )

      assert {:noreply, ^state} =
               EventHandler.handle_info(
                 {:policy_violation,
                  %{principal_id: "agent_test", violation_type: :test}},
                 state
               )
    end
  end

  describe "handle_info - catch-all" do
    test "unknown messages are handled without crashing" do
      state = %EventHandler{enabled: true, subscriptions: []}

      assert {:noreply, ^state} =
               EventHandler.handle_info(:random_message, state)

      assert {:noreply, ^state} =
               EventHandler.handle_info({:unknown_tuple, %{}}, state)

      assert {:noreply, ^state} =
               EventHandler.handle_info("string_message", state)
    end
  end

  describe "struct" do
    test "has expected fields" do
      handler = %EventHandler{}
      assert Map.has_key?(handler, :subscriptions)
      assert Map.has_key?(handler, :enabled)
    end

    test "default values are nil" do
      handler = %EventHandler{}
      assert handler.subscriptions == nil
      assert handler.enabled == nil
    end
  end

  describe "enable/disable lifecycle (via GenServer process)" do
    setup do
      # Start the EventHandler with a unique name would be ideal,
      # but it uses __MODULE__ as name. We start with enabled: false
      # to avoid PubSub dependency.
      {:ok, pid} = EventHandler.start_link(enabled: false)
      on_exit(fn -> safe_stop(pid) end)
      %{pid: pid}
    end

    test "starts disabled and can be enabled", %{pid: _pid} do
      refute EventHandler.enabled?()

      assert :ok = EventHandler.enable()
      assert EventHandler.enabled?()
    end

    test "can be disabled after enabling", %{pid: _pid} do
      EventHandler.enable()
      assert EventHandler.enabled?()

      assert :ok = EventHandler.disable()
      refute EventHandler.enabled?()
    end

    test "enable is idempotent", %{pid: _pid} do
      EventHandler.enable()
      assert :ok = EventHandler.enable()
      assert EventHandler.enabled?()
    end

    test "disable is idempotent", %{pid: _pid} do
      assert :ok = EventHandler.disable()
      refute EventHandler.enabled?()
    end
  end

  describe "event translation mapping" do
    # These tests verify the event translation logic documented in the moduledoc.
    # Since Manager may not be running, we test that the GenServer handles
    # each event type without crashing.

    test "action_executed success maps to action_success" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_x", status: :success, action: :deploy}

      # Should not crash; Manager.record_trust_event is a cast
      assert {:noreply, _state} =
               EventHandler.handle_info({:action_executed, event}, state)
    end

    test "action_executed failure maps to action_failure" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_x", status: :failure, action: :deploy, error: :crash}

      assert {:noreply, _state} =
               EventHandler.handle_info({:action_executed, event}, state)
    end

    test "self_test_completed with passed result maps to test_passed" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_x", result: :passed, test_name: "unit"}

      assert {:noreply, _state} =
               EventHandler.handle_info({:self_test_completed, event}, state)
    end

    test "self_test_completed with failed result maps to test_failed" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_x", result: :failed, test_name: "unit", error: :assertion}

      assert {:noreply, _state} =
               EventHandler.handle_info({:self_test_completed, event}, state)
    end

    test "rollback_executed maps to rollback_executed" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_x", commit: "abc", reason: :test_fail}

      assert {:noreply, _state} =
               EventHandler.handle_info({:rollback_executed, event}, state)
    end

    test "improvement_applied maps to improvement_applied" do
      state = %EventHandler{enabled: true, subscriptions: []}
      event = %{agent_id: "agent_x", improvement_type: :optimization, commit: "def"}

      assert {:noreply, _state} =
               EventHandler.handle_info({:improvement_applied, event}, state)
    end

    test "authorization_denied with policy_violation maps to security_violation" do
      state = %EventHandler{enabled: true, subscriptions: []}

      event = %{
        principal_id: "agent_x",
        reason: :policy_violation,
        resource_uri: "arbor://protected",
        operation: :write,
        policy: :boundary
      }

      assert {:noreply, _state} =
               EventHandler.handle_info({:authorization_denied, event}, state)
    end
  end
end
