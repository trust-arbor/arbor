defmodule Arbor.Monitor.RejectionTrackerTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.{Fingerprint, RejectionTracker}

  # Use short timeouts for testing
  @test_opts [
    max_rejections: 3,
    rejection_window_ms: 200,
    suppression_ttl_minutes: 1,
    cleanup_interval_ms: 50
  ]

  setup do
    start_supervised!({RejectionTracker, @test_opts})
    RejectionTracker.clear_all()
    :ok
  end

  defp make_fingerprint(skill \\ :memory, metric \\ :total_bytes) do
    Fingerprint.new(skill, metric, :above)
  end

  describe "record_rejection/3" do
    test "first rejection returns retry_with_context strategy" do
      fp = make_fingerprint()

      result = RejectionTracker.record_rejection(fp, "prop_001", "Insufficient evidence")

      assert result.strategy == :retry_with_context
      assert result.rejection_count == 1
      refute result.should_suppress
      assert String.contains?(result.message, "retry")
    end

    test "second rejection returns reduce_scope strategy" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "First rejection")
      result = RejectionTracker.record_rejection(fp, "prop_002", "Second rejection")

      assert result.strategy == :reduce_scope
      assert result.rejection_count == 2
      refute result.should_suppress
      assert String.contains?(result.message, "conservative")
    end

    test "third rejection returns escalate_to_human strategy" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "First rejection")
      RejectionTracker.record_rejection(fp, "prop_002", "Second rejection")
      result = RejectionTracker.record_rejection(fp, "prop_003", "Third rejection")

      assert result.strategy == :escalate_to_human
      assert result.rejection_count == 3
      assert result.should_suppress
      assert String.contains?(result.message, "Escalating")
    end

    test "fourth+ rejection continues escalate_to_human" do
      fp = make_fingerprint()

      for i <- 1..4 do
        RejectionTracker.record_rejection(fp, "prop_#{i}", "Rejection #{i}")
      end

      result = RejectionTracker.record_rejection(fp, "prop_005", "Fifth rejection")

      assert result.strategy == :escalate_to_human
      assert result.rejection_count == 5
      assert result.should_suppress
    end

    test "tracks rejections by fingerprint family" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      RejectionTracker.record_rejection(fp1, "prop_001", "Reason 1")
      RejectionTracker.record_rejection(fp1, "prop_002", "Reason 2")
      RejectionTracker.record_rejection(fp2, "prop_003", "Reason 3")

      assert RejectionTracker.rejection_count(fp1) == 2
      assert RejectionTracker.rejection_count(fp2) == 1
    end

    test "direction doesn't matter for family tracking" do
      fp_above = Fingerprint.new(:memory, :heap, :above)
      fp_below = Fingerprint.new(:memory, :heap, :below)

      RejectionTracker.record_rejection(fp_above, "prop_001", "Reason 1")
      RejectionTracker.record_rejection(fp_below, "prop_002", "Reason 2")

      # Both should count toward same family
      assert RejectionTracker.rejection_count(fp_above) == 2
      assert RejectionTracker.rejection_count(fp_below) == 2
    end

    test "rejection window resets count after expiry" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "First rejection")
      assert RejectionTracker.rejection_count(fp) == 1

      # Wait for window to expire (200ms + buffer)
      Process.sleep(250)

      result = RejectionTracker.record_rejection(fp, "prop_002", "After window")

      # Should reset to 1, not 2
      assert result.rejection_count == 1
      assert result.strategy == :retry_with_context
    end
  end

  describe "rejection_count/1" do
    test "returns 0 for unknown fingerprint" do
      fp = make_fingerprint(:unknown, :metric)
      assert RejectionTracker.rejection_count(fp) == 0
    end

    test "returns correct count" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "Reason")
      assert RejectionTracker.rejection_count(fp) == 1

      RejectionTracker.record_rejection(fp, "prop_002", "Reason")
      assert RejectionTracker.rejection_count(fp) == 2
    end
  end

  describe "get_record/1" do
    test "returns nil for unknown fingerprint" do
      fp = make_fingerprint(:unknown, :metric)
      assert RejectionTracker.get_record(fp) == nil
    end

    test "returns full record with reasons and proposal_ids" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "First reason")
      RejectionTracker.record_rejection(fp, "prop_002", "Second reason")

      record = RejectionTracker.get_record(fp)

      assert record.count == 2
      assert "First reason" in record.reasons
      assert "Second reason" in record.reasons
      assert "prop_001" in record.proposal_ids
      assert "prop_002" in record.proposal_ids
    end
  end

  describe "clear_rejections/1" do
    test "removes rejection history for fingerprint" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "Reason")
      assert RejectionTracker.rejection_count(fp) == 1

      RejectionTracker.clear_rejections(fp)

      assert RejectionTracker.rejection_count(fp) == 0
    end

    test "only clears specified fingerprint" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      RejectionTracker.record_rejection(fp1, "prop_001", "Reason 1")
      RejectionTracker.record_rejection(fp2, "prop_002", "Reason 2")

      RejectionTracker.clear_rejections(fp1)

      assert RejectionTracker.rejection_count(fp1) == 0
      assert RejectionTracker.rejection_count(fp2) == 1
    end
  end

  describe "list_rejected/0" do
    test "returns empty list when no rejections" do
      assert RejectionTracker.list_rejected() == []
    end

    test "returns all rejection records" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      RejectionTracker.record_rejection(fp1, "prop_001", "Reason 1")
      RejectionTracker.record_rejection(fp2, "prop_002", "Reason 2")

      records = RejectionTracker.list_rejected()
      assert length(records) == 2
    end

    test "returns records sorted by most recent first" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      RejectionTracker.record_rejection(fp1, "prop_001", "Reason 1")
      Process.sleep(10)
      RejectionTracker.record_rejection(fp2, "prop_002", "Reason 2")

      [first | _] = RejectionTracker.list_rejected()
      # Most recent should be fp2
      assert Fingerprint.family_hash(fp2) == first.family_hash
    end
  end

  describe "stats/0" do
    test "returns correct statistics" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)
      fp3 = make_fingerprint(:beam, :process_count)

      # fp1: 1 rejection
      RejectionTracker.record_rejection(fp1, "prop_001", "Reason")

      # fp2: 2 rejections
      RejectionTracker.record_rejection(fp2, "prop_002", "Reason")
      RejectionTracker.record_rejection(fp2, "prop_003", "Reason")

      # fp3: 3 rejections
      RejectionTracker.record_rejection(fp3, "prop_004", "Reason")
      RejectionTracker.record_rejection(fp3, "prop_005", "Reason")
      RejectionTracker.record_rejection(fp3, "prop_006", "Reason")

      stats = RejectionTracker.stats()

      assert stats.total_families == 3
      assert stats.strike_1 == 1
      assert stats.strike_2 == 1
      assert stats.strike_3_plus == 1
      assert stats.total_rejections == 6
    end
  end

  describe "signal emission" do
    test "emits healing_blocked signal on third rejection" do
      test_pid = self()

      callback = fn category, event, payload ->
        send(test_pid, {:signal, category, event, payload})
      end

      stop_supervised!(RejectionTracker)

      start_supervised!(
        {RejectionTracker,
         [
           max_rejections: 3,
           rejection_window_ms: 1000,
           signal_callback: callback
         ]}
      )

      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "First")
      refute_receive {:signal, _, _, _}, 10

      RejectionTracker.record_rejection(fp, "prop_002", "Second")
      refute_receive {:signal, _, _, _}, 10

      RejectionTracker.record_rejection(fp, "prop_003", "Third")
      assert_receive {:signal, :healing, :healing_blocked, payload}, 100

      assert payload.rejection_count == 3
      assert length(payload.reasons) == 3
      assert length(payload.proposal_ids) == 3
    end
  end

  describe "cleanup" do
    test "removes old rejections after window expires" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "Reason")
      assert RejectionTracker.rejection_count(fp) == 1

      # Wait for cleanup (window: 200ms, cleanup interval: 50ms)
      Process.sleep(300)

      assert RejectionTracker.rejection_count(fp) == 0
    end
  end
end
