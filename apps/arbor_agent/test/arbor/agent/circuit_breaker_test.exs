defmodule Arbor.Agent.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.CircuitBreaker

  setup do
    # Start a unique circuit breaker for each test
    name = {:global, {CircuitBreaker, make_ref()}}
    {:ok, pid} = CircuitBreaker.start_link(name: name, failure_threshold: 3, cooldown_ms: 100)
    {:ok, breaker: pid}
  end

  describe "can_attempt?/2" do
    test "allows attempts when circuit is closed", %{breaker: breaker} do
      assert CircuitBreaker.can_attempt?(breaker, :test_key)
    end

    test "blocks attempts when circuit is open", %{breaker: breaker} do
      key = :test_key

      # Record failures to open circuit
      CircuitBreaker.record_failure(breaker, key)
      CircuitBreaker.record_failure(breaker, key)
      CircuitBreaker.record_failure(breaker, key)

      # Wait for cast to be processed
      Process.sleep(10)

      # Circuit should be open now
      refute CircuitBreaker.can_attempt?(breaker, key)
    end

    test "allows one attempt when circuit is half-open after cooldown", %{breaker: breaker} do
      key = :test_key

      # Open the circuit
      for _ <- 1..3, do: CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      # Wait for cooldown (100ms)
      Process.sleep(110)

      # Should allow one attempt (half-open)
      assert CircuitBreaker.can_attempt?(breaker, key)

      # But not a second one
      refute CircuitBreaker.can_attempt?(breaker, key)
    end
  end

  describe "record_success/2" do
    test "closes circuit and resets failure count", %{breaker: breaker} do
      key = :test_key

      # Open the circuit
      for _ <- 1..3, do: CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      {state, failures, _} = CircuitBreaker.get_state(breaker, key)
      assert state == :open
      assert failures == 3

      # Wait for cooldown and allow half-open attempt
      Process.sleep(110)
      CircuitBreaker.can_attempt?(breaker, key)

      # Record success
      CircuitBreaker.record_success(breaker, key)
      Process.sleep(10)

      # Should be closed now
      {state, failures, _} = CircuitBreaker.get_state(breaker, key)
      assert state == :closed
      assert failures == 0
    end
  end

  describe "record_failure/2" do
    test "increments failure count", %{breaker: breaker} do
      key = :test_key

      CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      {state, failures, _} = CircuitBreaker.get_state(breaker, key)
      assert state == :closed
      assert failures == 1
    end

    test "opens circuit at threshold", %{breaker: breaker} do
      key = :test_key

      CircuitBreaker.record_failure(breaker, key)
      CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      {state, _, _} = CircuitBreaker.get_state(breaker, key)
      assert state == :closed

      CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      {state, _, _} = CircuitBreaker.get_state(breaker, key)
      assert state == :open
    end
  end

  describe "get_state/2" do
    test "returns default state for unknown key", %{breaker: breaker} do
      {state, failures, last_failure} = CircuitBreaker.get_state(breaker, :unknown_key)
      assert state == :closed
      assert failures == 0
      assert last_failure == nil
    end

    test "tracks last failure time", %{breaker: breaker} do
      key = :test_key
      CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      {_, _, last_failure} = CircuitBreaker.get_state(breaker, key)
      assert %DateTime{} = last_failure
    end
  end

  describe "reset/2" do
    test "clears circuit state for key", %{breaker: breaker} do
      key = :test_key

      for _ <- 1..3, do: CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      {state, _, _} = CircuitBreaker.get_state(breaker, key)
      assert state == :open

      CircuitBreaker.reset(breaker, key)
      Process.sleep(10)

      {state, failures, _} = CircuitBreaker.get_state(breaker, key)
      assert state == :closed
      assert failures == 0
    end
  end

  describe "reset_all/1" do
    test "clears all circuit states", %{breaker: breaker} do
      # Create multiple circuits
      for key <- [:key1, :key2, :key3] do
        for _ <- 1..3, do: CircuitBreaker.record_failure(breaker, key)
      end

      Process.sleep(10)

      # All should be open
      for key <- [:key1, :key2, :key3] do
        {state, _, _} = CircuitBreaker.get_state(breaker, key)
        assert state == :open
      end

      CircuitBreaker.reset_all(breaker)
      Process.sleep(10)

      # All should be closed (default)
      for key <- [:key1, :key2, :key3] do
        {state, failures, _} = CircuitBreaker.get_state(breaker, key)
        assert state == :closed
        assert failures == 0
      end
    end
  end

  describe "stats/1" do
    test "returns statistics", %{breaker: breaker} do
      stats = CircuitBreaker.stats(breaker)

      assert is_integer(stats.total_attempts)
      assert is_integer(stats.blocked_attempts)
      assert is_integer(stats.successful_attempts)
      assert is_integer(stats.failed_attempts)
      assert is_integer(stats.total_circuits)
      assert is_integer(stats.open_circuits)
      assert is_integer(stats.closed_circuits)
      assert is_integer(stats.half_open_circuits)
    end

    test "tracks blocked attempts", %{breaker: breaker} do
      key = :test_key

      # Open circuit
      for _ <- 1..3, do: CircuitBreaker.record_failure(breaker, key)
      Process.sleep(10)

      # Try to use when blocked
      CircuitBreaker.can_attempt?(breaker, key)

      stats = CircuitBreaker.stats(breaker)
      assert stats.blocked_attempts >= 1
    end
  end

  describe "independent keys" do
    test "different keys have independent circuits", %{breaker: breaker} do
      key1 = :key1
      key2 = :key2

      # Open circuit for key1
      for _ <- 1..3, do: CircuitBreaker.record_failure(breaker, key1)
      Process.sleep(10)

      # key1 should be blocked
      refute CircuitBreaker.can_attempt?(breaker, key1)

      # key2 should still be allowed
      assert CircuitBreaker.can_attempt?(breaker, key2)
    end
  end
end
