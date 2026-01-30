defmodule Arbor.Trust.CircuitBreakerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.CircuitBreaker
  alias Arbor.Trust.Manager
  alias Arbor.Trust.Store

  # Use short windows so tests run quickly
  @test_config %{
    rapid_failure_threshold: 5,
    rapid_failure_window_seconds: 60,
    security_violation_threshold: 3,
    security_violation_window_seconds: 3600,
    rollback_threshold: 3,
    rollback_window_seconds: 3600,
    test_failure_threshold: 5,
    test_failure_window_seconds: 300,
    freeze_duration_seconds: 1,
    half_open_duration_seconds: 1
  }

  setup do
    # Ensure the Manager and Store are running so freeze/unfreeze calls don't crash
    ensure_manager_started()

    # Start CircuitBreaker with test config
    start_supervised!({CircuitBreaker, config: @test_config})

    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    # Create a trust profile for the agent so Manager operations succeed
    ensure_profile_exists(agent_id)

    {:ok, agent_id: agent_id}
  end

  describe "start_link/1" do
    test "starts the circuit breaker GenServer" do
      # Already started in setup; verify it is alive
      assert Process.whereis(CircuitBreaker) != nil
    end
  end

  describe "get_state/1" do
    test "returns :closed for unknown agent", %{agent_id: _agent_id} do
      assert CircuitBreaker.get_state("unknown_agent") == :closed
    end

    test "returns :closed for agent with no events", %{agent_id: agent_id} do
      assert CircuitBreaker.get_state(agent_id) == :closed
    end
  end

  describe "check/1" do
    test "returns :ok for agent in closed state", %{agent_id: agent_id} do
      assert CircuitBreaker.check(agent_id) == :ok
    end

    test "returns :ok for unknown agent" do
      assert CircuitBreaker.check("totally_unknown") == :ok
    end
  end

  describe "record_event/2 - rapid failures" do
    test "does not trip circuit below threshold", %{agent_id: agent_id} do
      # Record 4 failures (threshold is 5)
      for _ <- 1..4 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      # Give the GenServer time to process casts
      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :closed
      assert CircuitBreaker.check(agent_id) == :ok
    end

    test "trips circuit when rapid failure threshold is reached", %{agent_id: agent_id} do
      # Record 5 failures (meets threshold)
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :open
      assert CircuitBreaker.check(agent_id) == {:error, :circuit_open}
    end

    test "trips circuit when failures exceed threshold", %{agent_id: agent_id} do
      for _ <- 1..7 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :open
    end
  end

  describe "record_event/2 - security violations" do
    test "does not trip circuit below security violation threshold", %{agent_id: agent_id} do
      for _ <- 1..2 do
        CircuitBreaker.record_event(agent_id, :security_violation)
      end

      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :closed
    end

    test "trips circuit when security violation threshold is reached", %{agent_id: agent_id} do
      for _ <- 1..3 do
        CircuitBreaker.record_event(agent_id, :security_violation)
      end

      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :open
      assert CircuitBreaker.check(agent_id) == {:error, :circuit_open}
    end
  end

  describe "record_event/2 - test failures" do
    test "does not trip circuit below test failure threshold", %{agent_id: agent_id} do
      for _ <- 1..4 do
        CircuitBreaker.record_event(agent_id, :test_failed)
      end

      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :closed
    end

    test "trips circuit when test failure threshold is reached", %{agent_id: agent_id} do
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :test_failed)
      end

      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :open
    end
  end

  describe "record_event/2 - rollback spike" do
    test "does not trip circuit on rollback spike (only logs warning)", %{agent_id: agent_id} do
      # Rollback spikes are handled differently - they don't freeze, just log
      for _ <- 1..3 do
        CircuitBreaker.record_event(agent_id, :rollback_executed)
      end

      Process.sleep(50)

      # Rollback spikes do NOT trip the circuit breaker in the CB module itself
      # The Manager handles tier demotion separately
      assert CircuitBreaker.get_state(agent_id) == :closed
      assert CircuitBreaker.check(agent_id) == :ok
    end
  end

  describe "record_event/2 - metadata" do
    test "accepts metadata with events", %{agent_id: agent_id} do
      CircuitBreaker.record_event(agent_id, :action_failure, %{action: "deploy", reason: "timeout"})
      Process.sleep(50)

      # Should not crash and state should still be valid
      assert CircuitBreaker.get_state(agent_id) == :closed
    end
  end

  describe "reset/1" do
    test "resets an open circuit back to closed", %{agent_id: agent_id} do
      # Trip the circuit
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)
      assert CircuitBreaker.get_state(agent_id) == :open

      # Reset the circuit
      assert CircuitBreaker.reset(agent_id) == :ok
      assert CircuitBreaker.get_state(agent_id) == :closed
      assert CircuitBreaker.check(agent_id) == :ok
    end

    test "reset is idempotent for closed circuits", %{agent_id: agent_id} do
      assert CircuitBreaker.get_state(agent_id) == :closed
      assert CircuitBreaker.reset(agent_id) == :ok
      assert CircuitBreaker.get_state(agent_id) == :closed
    end
  end

  describe "freeze/unfreeze cycle" do
    test "circuit transitions from open to half_open after freeze duration", %{agent_id: agent_id} do
      # Trip the circuit with rapid failures
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)
      assert CircuitBreaker.get_state(agent_id) == :open

      # Wait for freeze_duration_seconds (1 second in test config) + buffer
      Process.sleep(1200)

      assert CircuitBreaker.get_state(agent_id) == :half_open
    end

    test "half_open circuit still blocks checks", %{agent_id: agent_id} do
      # Trip the circuit
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)
      assert CircuitBreaker.get_state(agent_id) == :open

      # Wait for half-open transition
      Process.sleep(1200)
      assert CircuitBreaker.get_state(agent_id) == :half_open

      # half_open also returns circuit_open
      assert CircuitBreaker.check(agent_id) == {:error, :circuit_open}
    end
  end

  describe "get_config/0" do
    test "returns the current configuration" do
      config = CircuitBreaker.get_config()

      assert is_map(config)
      assert config.rapid_failure_threshold == 5
      assert config.security_violation_threshold == 3
      assert config.rollback_threshold == 3
      assert config.test_failure_threshold == 5
    end
  end

  describe "multiple agents" do
    test "circuit states are independent per agent", %{agent_id: agent_id} do
      other_agent = "other_agent_#{System.unique_integer([:positive])}"
      ensure_profile_exists(other_agent)

      # Trip circuit for agent_id
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :open
      assert CircuitBreaker.get_state(other_agent) == :closed
    end
  end

  describe "cleanup" do
    test "cleanup message does not crash the GenServer" do
      # Manually send cleanup message
      send(Process.whereis(CircuitBreaker), :cleanup)
      Process.sleep(50)

      # GenServer should still be alive
      assert Process.alive?(Process.whereis(CircuitBreaker))
    end

    test "cleanup removes old events and retains recent ones", %{agent_id: agent_id} do
      # Record some events
      for _ <- 1..3 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)

      # Trigger cleanup
      send(Process.whereis(CircuitBreaker), :cleanup)
      Process.sleep(50)

      # GenServer should still be alive with recent events retained
      assert Process.alive?(Process.whereis(CircuitBreaker))
      assert CircuitBreaker.get_state(agent_id) == :closed
    end
  end

  describe "auto_close transition" do
    test "auto_close from half_open transitions to closed", %{agent_id: agent_id} do
      # Trip the circuit first
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)
      assert CircuitBreaker.get_state(agent_id) == :open

      # Wait for half-open transition
      Process.sleep(1200)
      assert CircuitBreaker.get_state(agent_id) == :half_open

      # Send auto_close message
      send(Process.whereis(CircuitBreaker), {:auto_close, agent_id})
      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :closed
    end

    test "auto_close on closed circuit is a no-op", %{agent_id: agent_id} do
      assert CircuitBreaker.get_state(agent_id) == :closed

      send(Process.whereis(CircuitBreaker), {:auto_close, agent_id})
      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :closed
    end

    test "auto_close on open circuit is a no-op", %{agent_id: agent_id} do
      # Trip the circuit
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)
      assert CircuitBreaker.get_state(agent_id) == :open

      # Send auto_close while still :open (not yet half_open)
      send(Process.whereis(CircuitBreaker), {:auto_close, agent_id})
      Process.sleep(50)

      # Should still be :open since auto_close only works from :half_open
      assert CircuitBreaker.get_state(agent_id) == :open
    end
  end

  describe "half_open transition edge cases" do
    test "half_open message on closed circuit is a no-op", %{agent_id: agent_id} do
      assert CircuitBreaker.get_state(agent_id) == :closed

      send(Process.whereis(CircuitBreaker), {:half_open, agent_id})
      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :closed
    end

    test "half_open message on already half_open circuit stays half_open", %{agent_id: agent_id} do
      # Trip the circuit
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :action_failure)
      end

      Process.sleep(50)
      assert CircuitBreaker.get_state(agent_id) == :open

      # Wait for half-open
      Process.sleep(1200)
      assert CircuitBreaker.get_state(agent_id) == :half_open

      # Send another half_open - should be no-op (not :open)
      send(Process.whereis(CircuitBreaker), {:half_open, agent_id})
      Process.sleep(50)

      assert CircuitBreaker.get_state(agent_id) == :half_open
    end
  end

  describe "rollback spike handling" do
    test "rollback spike logs warning but does not freeze", %{agent_id: agent_id} do
      # Record 5 rollbacks (exceeds threshold of 3)
      for _ <- 1..5 do
        CircuitBreaker.record_event(agent_id, :rollback_executed)
      end

      Process.sleep(50)

      # Rollback spikes do NOT trip the circuit
      assert CircuitBreaker.get_state(agent_id) == :closed
      assert CircuitBreaker.check(agent_id) == :ok
    end
  end

  # Helpers

  defp ensure_manager_started do
    case Process.whereis(Store) do
      nil -> start_supervised!(Store)
      _pid -> :ok
    end

    case Process.whereis(Manager) do
      nil ->
        start_supervised!(
          {Manager, circuit_breaker: false, decay: false, event_store: false}
        )

      _pid ->
        :ok
    end
  end

  defp ensure_profile_exists(agent_id) do
    case Manager.get_trust_profile(agent_id) do
      {:ok, _profile} -> :ok
      {:error, :not_found} -> Manager.create_trust_profile(agent_id)
    end
  end
end
