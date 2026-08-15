defmodule Arbor.Monitor.AnomalyQueueTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.AnomalyQueue
  alias Arbor.Monitor.Fingerprint

  # Use short timeouts for testing
  @test_opts [
    dedup_window_ms: 100,
    lease_timeout_ms: 50,
    check_interval_ms: 25,
    max_attempts: 3
  ]

  setup do
    # Start a fresh queue for each test
    start_supervised!({AnomalyQueue, @test_opts})
    AnomalyQueue.clear_all()
    :ok
  end

  defp make_anomaly(skill, metric, value, ewma) do
    %{
      id: System.unique_integer([:positive]),
      skill: skill,
      severity: :warning,
      details: %{
        metric: metric,
        value: value,
        ewma: ewma,
        stddev: abs(ewma - value) / 3
      },
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  describe "enqueue/1" do
    test "enqueues valid anomaly" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)

      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)
      assert AnomalyQueue.size() == 1
    end

    test "deduplicates anomalies with same fingerprint within window" do
      anomaly1 = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      anomaly2 = make_anomaly(:memory, :total_bytes, 1_100_000, 800_000)

      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly1)
      assert {:ok, :deduplicated} = AnomalyQueue.enqueue(anomaly2)
      assert AnomalyQueue.size() == 1
    end

    test "enqueues different fingerprints separately" do
      anomaly1 = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      anomaly2 = make_anomaly(:ets, :table_count, 200, 150)

      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly1)
      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly2)
      assert AnomalyQueue.size() == 2
    end

    test "enqueues same metric with different direction" do
      # above
      anomaly1 = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      # below
      anomaly2 = make_anomaly(:memory, :total_bytes, 600_000, 800_000)

      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly1)
      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly2)
      assert AnomalyQueue.size() == 2
    end

    test "returns error for invalid anomaly" do
      assert {:error, {:invalid_anomaly, _}} = AnomalyQueue.enqueue(%{})
    end

    test "dedup window expires and allows new enqueue" do
      anomaly1 = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      anomaly2 = make_anomaly(:memory, :total_bytes, 1_100_000, 800_000)

      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly1)

      # Wait for dedup window to expire (100ms + buffer)
      Process.sleep(150)

      # Should now enqueue as new since window expired
      assert {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly2)
      assert AnomalyQueue.size() == 2
    end
  end

  describe "claim_next/1" do
    test "claims oldest pending anomaly" do
      anomaly1 = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      anomaly2 = make_anomaly(:ets, :table_count, 200, 150)

      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly1)
      Process.sleep(10)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly2)

      assert {:ok, {lease, claimed}} = AnomalyQueue.claim_next("agent_1")
      assert claimed.skill == :memory
      assert is_tuple(lease)
    end

    test "returns error when queue is empty" do
      assert {:error, :empty} = AnomalyQueue.claim_next("agent_1")
    end

    test "claimed anomaly is not available to other agents" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      assert {:ok, _} = AnomalyQueue.claim_next("agent_1")
      assert {:error, :empty} = AnomalyQueue.claim_next("agent_2")
    end

    test "lease expires and anomaly becomes available again" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      assert {:ok, _} = AnomalyQueue.claim_next("agent_1")
      assert {:error, :empty} = AnomalyQueue.claim_next("agent_2")

      # Wait for lease to expire (50ms) + check interval (25ms) + buffer
      Process.sleep(100)

      # Should be claimable again
      assert {:ok, _} = AnomalyQueue.claim_next("agent_2")
    end
  end

  describe "release/1" do
    test "releases claimed anomaly back to pending" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      {:ok, {lease, _}} = AnomalyQueue.claim_next("agent_1")
      assert :ok = AnomalyQueue.release(lease)

      # Should be claimable by another agent immediately
      assert {:ok, _} = AnomalyQueue.claim_next("agent_2")
    end

    test "returns error for invalid lease" do
      invalid_lease = {999, "fake_agent", System.monotonic_time(:millisecond)}
      assert {:error, :invalid_lease} = AnomalyQueue.release(invalid_lease)
    end
  end

  describe "complete/2 with :fixed" do
    test "moves anomaly to verifying state" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      {:ok, {lease, _}} = AnomalyQueue.claim_next("agent_1")
      assert :ok = AnomalyQueue.complete(lease, :fixed)

      verifying = AnomalyQueue.list_by_state(:verifying)
      assert length(verifying) == 1
    end
  end

  describe "complete/2 with :escalated" do
    test "moves anomaly to escalated state and suppresses fingerprint" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      {:ok, {lease, _}} = AnomalyQueue.claim_next("agent_1")
      assert :ok = AnomalyQueue.complete(lease, :escalated)

      escalated = AnomalyQueue.list_by_state(:escalated)
      assert length(escalated) == 1

      # Fingerprint should be suppressed
      fp = Fingerprint.new(:memory, :total_bytes, :above)
      assert AnomalyQueue.suppressed?(fp)
    end
  end

  describe "complete/2 with {:retry, reason}" do
    test "returns anomaly to pending for retry" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      {:ok, {lease, _}} = AnomalyQueue.claim_next("agent_1")
      assert :ok = AnomalyQueue.complete(lease, {:retry, "need more context"})

      pending = AnomalyQueue.list_pending()
      assert length(pending) == 1
    end

    test "escalates after max attempts" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      # Attempt 1
      {:ok, {lease1, _}} = AnomalyQueue.claim_next("agent_1")
      AnomalyQueue.complete(lease1, {:retry, "attempt 1"})

      # Attempt 2
      {:ok, {lease2, _}} = AnomalyQueue.claim_next("agent_1")
      AnomalyQueue.complete(lease2, {:retry, "attempt 2"})

      # Attempt 3 (max_attempts = 3)
      {:ok, {lease3, _}} = AnomalyQueue.claim_next("agent_1")
      AnomalyQueue.complete(lease3, {:retry, "attempt 3"})

      # Should now be escalated
      assert AnomalyQueue.list_pending() == []
      escalated = AnomalyQueue.list_by_state(:escalated)
      assert length(escalated) == 1
    end
  end

  describe "complete/2 with {:ineffective, reason}" do
    test "moves anomaly to ineffective state" do
      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly)

      {:ok, {lease, _}} = AnomalyQueue.claim_next("agent_1")
      assert :ok = AnomalyQueue.complete(lease, {:ineffective, "recurrence detected"})

      ineffective = AnomalyQueue.list_by_state(:ineffective)
      assert length(ineffective) == 1
    end
  end

  describe "suppressed?/1" do
    test "returns false for non-suppressed fingerprint" do
      fp = Fingerprint.new(:beam, :process_count, :above)
      refute AnomalyQueue.suppressed?(fp)
    end

    test "returns true for manually suppressed fingerprint" do
      fp = Fingerprint.new(:beam, :process_count, :above)
      AnomalyQueue.suppress(fp, "manual suppression", 1)
      assert AnomalyQueue.suppressed?(fp)
    end

    test "suppression applies to family (both directions)" do
      fp_above = Fingerprint.new(:beam, :process_count, :above)
      fp_below = Fingerprint.new(:beam, :process_count, :below)

      AnomalyQueue.suppress(fp_above, "test", 1)

      assert AnomalyQueue.suppressed?(fp_above)
      assert AnomalyQueue.suppressed?(fp_below)
    end

    test "suppressed anomalies are deduplicated on enqueue" do
      fp = Fingerprint.new(:memory, :total_bytes, :above)
      AnomalyQueue.suppress(fp, "test", 1)

      anomaly = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      assert {:ok, :deduplicated} = AnomalyQueue.enqueue(anomaly)
      assert AnomalyQueue.size() == 0
    end
  end

  describe "stats/0" do
    test "returns correct statistics" do
      anomaly1 = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      anomaly2 = make_anomaly(:ets, :table_count, 200, 150)
      anomaly3 = make_anomaly(:beam, :process_count, 500, 400)

      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly1)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly2)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly3)

      {:ok, {lease1, _}} = AnomalyQueue.claim_next("agent_1")
      {:ok, {lease2, _}} = AnomalyQueue.claim_next("agent_2")

      AnomalyQueue.complete(lease1, :fixed)

      stats = AnomalyQueue.stats()

      assert stats.pending == 1
      assert stats.claimed == 1
      assert stats.verifying == 1
    end
  end

  describe "list_pending/0" do
    test "returns pending anomalies sorted by enqueue time" do
      anomaly1 = make_anomaly(:memory, :total_bytes, 1_000_000, 800_000)
      anomaly2 = make_anomaly(:ets, :table_count, 200, 150)

      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly1)
      Process.sleep(10)
      {:ok, :enqueued} = AnomalyQueue.enqueue(anomaly2)

      pending = AnomalyQueue.list_pending()
      assert length(pending) == 2
      assert hd(pending).anomaly.skill == :memory
    end
  end
end
