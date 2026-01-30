defmodule Arbor.Security.Constraint.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Constraint.RateLimiter

  setup do
    principal = "agent_rl_#{:erlang.unique_integer([:positive])}"
    resource = "arbor://fs/read/rl_test_#{:erlang.unique_integer([:positive])}"
    {:ok, principal: principal, resource: resource}
  end

  describe "consume/3" do
    test "succeeds under limit", %{principal: p, resource: r} do
      assert :ok = RateLimiter.consume(p, r, 5)
    end

    test "fails when tokens exhausted", %{principal: p, resource: r} do
      max = 3
      assert :ok = RateLimiter.consume(p, r, max)
      assert :ok = RateLimiter.consume(p, r, max)
      assert :ok = RateLimiter.consume(p, r, max)
      assert {:error, :rate_limited} = RateLimiter.consume(p, r, max)
    end

    test "different bucket keys are independent" do
      p1 = "agent_rl_indep_1_#{:erlang.unique_integer([:positive])}"
      p2 = "agent_rl_indep_2_#{:erlang.unique_integer([:positive])}"
      r = "arbor://fs/read/rl_indep_#{:erlang.unique_integer([:positive])}"

      # Exhaust p1's tokens
      assert :ok = RateLimiter.consume(p1, r, 1)
      assert {:error, :rate_limited} = RateLimiter.consume(p1, r, 1)

      # p2 should still have tokens
      assert :ok = RateLimiter.consume(p2, r, 1)
    end
  end

  describe "remaining/3" do
    test "returns correct count without consuming", %{principal: p, resource: r} do
      max = 5
      assert RateLimiter.remaining(p, r, max) == 5

      :ok = RateLimiter.consume(p, r, max)
      assert RateLimiter.remaining(p, r, max) == 4

      :ok = RateLimiter.consume(p, r, max)
      assert RateLimiter.remaining(p, r, max) == 3
    end
  end

  describe "reset/2" do
    test "restores full tokens on next consume", %{principal: p, resource: r} do
      max = 2
      :ok = RateLimiter.consume(p, r, max)
      :ok = RateLimiter.consume(p, r, max)
      assert {:error, :rate_limited} = RateLimiter.consume(p, r, max)

      :ok = RateLimiter.reset(p, r)

      # After reset, bucket is removed — next consume creates fresh bucket
      assert :ok = RateLimiter.consume(p, r, max)
    end
  end

  describe "stats/0" do
    test "returns bucket count", %{principal: p, resource: r} do
      _stats_before = RateLimiter.stats()

      :ok = RateLimiter.consume(p, r, 10)
      stats = RateLimiter.stats()

      assert is_integer(stats.bucket_count)
      assert stats.bucket_count >= 1
      assert is_map(stats.buckets)
    end
  end

  describe "token refill" do
    test "tokens refill over time", %{principal: p, resource: r} do
      # Use a very short refill period for testing
      prev_refill = Application.get_env(:arbor_security, :rate_limit_refill_period_seconds)
      Application.put_env(:arbor_security, :rate_limit_refill_period_seconds, 1)

      on_exit(fn ->
        if prev_refill,
          do: Application.put_env(:arbor_security, :rate_limit_refill_period_seconds, prev_refill),
          else: Application.delete_env(:arbor_security, :rate_limit_refill_period_seconds)
      end)

      max = 2
      :ok = RateLimiter.consume(p, r, max)
      :ok = RateLimiter.consume(p, r, max)
      assert {:error, :rate_limited} = RateLimiter.consume(p, r, max)

      # Wait for refill (1 second refill period means full refill after 1 second)
      :timer.sleep(1100)

      assert :ok = RateLimiter.consume(p, r, max)
    end
  end

  describe "cleanup" do
    test "stale buckets are cleaned up" do
      # This test verifies the cleanup message handler works
      # Use a very short TTL
      prev_ttl = Application.get_env(:arbor_security, :rate_limit_bucket_ttl_seconds)
      Application.put_env(:arbor_security, :rate_limit_bucket_ttl_seconds, 0)

      on_exit(fn ->
        if prev_ttl,
          do: Application.put_env(:arbor_security, :rate_limit_bucket_ttl_seconds, prev_ttl),
          else: Application.delete_env(:arbor_security, :rate_limit_bucket_ttl_seconds)
      end)

      p = "agent_cleanup_#{:erlang.unique_integer([:positive])}"
      r = "arbor://fs/read/cleanup_#{:erlang.unique_integer([:positive])}"

      :ok = RateLimiter.consume(p, r, 10)

      # Trigger cleanup by sending the message directly
      send(Process.whereis(RateLimiter), :cleanup)
      # Give GenServer time to process
      :timer.sleep(50)

      stats = RateLimiter.stats()
      # The bucket should have been cleaned up (TTL = 0 seconds)
      refute Map.has_key?(stats.buckets, {p, r})
    end
  end
end
