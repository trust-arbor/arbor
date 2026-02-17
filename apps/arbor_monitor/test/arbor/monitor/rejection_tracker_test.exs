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
    @tag :fast
    test "first rejection returns retry_with_context strategy" do
      fp = make_fingerprint()

      result = RejectionTracker.record_rejection(fp, "prop_001", "Insufficient evidence")

      assert result.strategy == :retry_with_context
      assert result.rejection_count == 1
      refute result.should_suppress
      assert String.contains?(result.message, "retry")
    end

    @tag :fast
    test "second rejection returns reduce_scope strategy" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "First rejection")
      result = RejectionTracker.record_rejection(fp, "prop_002", "Second rejection")

      assert result.strategy == :reduce_scope
      assert result.rejection_count == 2
      refute result.should_suppress
      assert String.contains?(result.message, "conservative")
    end

    @tag :fast
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

    @tag :fast
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

    @tag :fast
    test "tracks rejections by fingerprint family" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      RejectionTracker.record_rejection(fp1, "prop_001", "Reason 1")
      RejectionTracker.record_rejection(fp1, "prop_002", "Reason 2")
      RejectionTracker.record_rejection(fp2, "prop_003", "Reason 3")

      assert RejectionTracker.rejection_count(fp1) == 2
      assert RejectionTracker.rejection_count(fp2) == 1
    end

    @tag :fast
    test "direction doesn't matter for family tracking" do
      fp_above = Fingerprint.new(:memory, :heap, :above)
      fp_below = Fingerprint.new(:memory, :heap, :below)

      RejectionTracker.record_rejection(fp_above, "prop_001", "Reason 1")
      RejectionTracker.record_rejection(fp_below, "prop_002", "Reason 2")

      # Both should count toward same family
      assert RejectionTracker.rejection_count(fp_above) == 2
      assert RejectionTracker.rejection_count(fp_below) == 2
    end

    @tag :fast
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

  describe "three-strike escalation logic" do
    @tag :fast
    test "strategies map correctly to strike numbers" do
      fp = make_fingerprint()

      r1 = RejectionTracker.record_rejection(fp, "p1", "reason 1")
      assert r1.strategy == :retry_with_context
      assert r1.rejection_count == 1

      r2 = RejectionTracker.record_rejection(fp, "p2", "reason 2")
      assert r2.strategy == :reduce_scope
      assert r2.rejection_count == 2

      r3 = RejectionTracker.record_rejection(fp, "p3", "reason 3")
      assert r3.strategy == :escalate_to_human
      assert r3.rejection_count == 3
    end

    @tag :fast
    test "should_suppress only true at and beyond max_rejections" do
      fp = make_fingerprint()

      r1 = RejectionTracker.record_rejection(fp, "p1", "r1")
      refute r1.should_suppress

      r2 = RejectionTracker.record_rejection(fp, "p2", "r2")
      refute r2.should_suppress

      r3 = RejectionTracker.record_rejection(fp, "p3", "r3")
      assert r3.should_suppress

      r4 = RejectionTracker.record_rejection(fp, "p4", "r4")
      assert r4.should_suppress
    end

    @tag :fast
    test "strategy messages contain appropriate guidance" do
      fp = make_fingerprint()

      r1 = RejectionTracker.record_rejection(fp, "p1", "reason")
      assert r1.message =~ "retry"
      assert r1.message =~ "context"

      r2 = RejectionTracker.record_rejection(fp, "p2", "reason")
      assert r2.message =~ "conservative"

      r3 = RejectionTracker.record_rejection(fp, "p3", "reason")
      assert r3.message =~ "Escalating"
      assert r3.message =~ "3"
    end

    @tag :fast
    test "escalation message includes actual rejection count beyond 3" do
      fp = make_fingerprint()

      for i <- 1..5 do
        RejectionTracker.record_rejection(fp, "p#{i}", "reason #{i}")
      end

      r6 = RejectionTracker.record_rejection(fp, "p6", "reason 6")
      assert r6.message =~ "6"
      assert r6.message =~ "Escalating"
    end

    @tag :fast
    test "independent fingerprints have independent strike counts" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)
      fp3 = make_fingerprint(:beam, :process_count)

      # fp1 gets 2 strikes
      RejectionTracker.record_rejection(fp1, "p1", "r1")
      r1_2 = RejectionTracker.record_rejection(fp1, "p2", "r2")
      assert r1_2.strategy == :reduce_scope

      # fp2 gets 1 strike
      r2_1 = RejectionTracker.record_rejection(fp2, "p3", "r3")
      assert r2_1.strategy == :retry_with_context

      # fp3 gets 3 strikes
      RejectionTracker.record_rejection(fp3, "p4", "r4")
      RejectionTracker.record_rejection(fp3, "p5", "r5")
      r3_3 = RejectionTracker.record_rejection(fp3, "p6", "r6")
      assert r3_3.strategy == :escalate_to_human

      # fp1's next should still be strike 3
      r1_3 = RejectionTracker.record_rejection(fp1, "p7", "r7")
      assert r1_3.strategy == :escalate_to_human
    end

    @tag :fast
    test "clearing rejections resets strike count for that fingerprint" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "p1", "r1")
      RejectionTracker.record_rejection(fp, "p2", "r2")
      assert RejectionTracker.rejection_count(fp) == 2

      RejectionTracker.clear_rejections(fp)
      assert RejectionTracker.rejection_count(fp) == 0

      # Next rejection should be strike 1 again
      result = RejectionTracker.record_rejection(fp, "p3", "r3")
      assert result.strategy == :retry_with_context
      assert result.rejection_count == 1
    end
  end

  describe "reasons and proposal_ids accumulation" do
    @tag :fast
    test "reasons are accumulated in reverse chronological order" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "p1", "first_reason")
      RejectionTracker.record_rejection(fp, "p2", "second_reason")
      RejectionTracker.record_rejection(fp, "p3", "third_reason")

      record = RejectionTracker.get_record(fp)
      assert length(record.reasons) == 3

      # Most recent should be first (prepended)
      assert hd(record.reasons) == "third_reason"
    end

    @tag :fast
    test "proposal_ids are accumulated in reverse chronological order" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_AAA", "r1")
      RejectionTracker.record_rejection(fp, "prop_BBB", "r2")
      RejectionTracker.record_rejection(fp, "prop_CCC", "r3")

      record = RejectionTracker.get_record(fp)
      assert length(record.proposal_ids) == 3
      assert hd(record.proposal_ids) == "prop_CCC"
    end

    @tag :fast
    test "reasons list is truncated at 10 items" do
      fp = make_fingerprint()

      for i <- 1..15 do
        RejectionTracker.record_rejection(fp, "p#{i}", "reason_#{i}")
      end

      record = RejectionTracker.get_record(fp)
      assert length(record.reasons) == 10
      # Most recent should be first
      assert hd(record.reasons) == "reason_15"
    end

    @tag :fast
    test "proposal_ids list is truncated at 10 items" do
      fp = make_fingerprint()

      for i <- 1..15 do
        RejectionTracker.record_rejection(fp, "prop_#{i}", "r#{i}")
      end

      record = RejectionTracker.get_record(fp)
      assert length(record.proposal_ids) == 10
      assert hd(record.proposal_ids) == "prop_15"
    end
  end

  describe "rejection_count/1" do
    @tag :fast
    test "returns 0 for unknown fingerprint" do
      fp = make_fingerprint(:unknown, :metric)
      assert RejectionTracker.rejection_count(fp) == 0
    end

    @tag :fast
    test "returns correct count" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "Reason")
      assert RejectionTracker.rejection_count(fp) == 1

      RejectionTracker.record_rejection(fp, "prop_002", "Reason")
      assert RejectionTracker.rejection_count(fp) == 2
    end
  end

  describe "get_record/1" do
    @tag :fast
    test "returns nil for unknown fingerprint" do
      fp = make_fingerprint(:unknown, :metric)
      assert RejectionTracker.get_record(fp) == nil
    end

    @tag :fast
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

    @tag :fast
    test "record contains family_hash and last_rejection_at" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "Reason")

      record = RejectionTracker.get_record(fp)
      assert is_integer(record.family_hash)
      assert is_integer(record.last_rejection_at)
      assert record.family_hash == Fingerprint.family_hash(fp)
    end
  end

  describe "clear_rejections/1" do
    @tag :fast
    test "removes rejection history for fingerprint" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "Reason")
      assert RejectionTracker.rejection_count(fp) == 1

      RejectionTracker.clear_rejections(fp)

      assert RejectionTracker.rejection_count(fp) == 0
    end

    @tag :fast
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
    @tag :fast
    test "returns empty list when no rejections" do
      assert RejectionTracker.list_rejected() == []
    end

    @tag :fast
    test "returns all rejection records" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      RejectionTracker.record_rejection(fp1, "prop_001", "Reason 1")
      RejectionTracker.record_rejection(fp2, "prop_002", "Reason 2")

      records = RejectionTracker.list_rejected()
      assert length(records) == 2
    end

    @tag :fast
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
    @tag :fast
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

    @tag :fast
    test "stats reflect zero state after clear_all" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "p1", "r1")
      RejectionTracker.record_rejection(fp, "p2", "r2")

      RejectionTracker.clear_all()

      stats = RejectionTracker.stats()
      assert stats.total_families == 0
      assert stats.strike_1 == 0
      assert stats.strike_2 == 0
      assert stats.strike_3_plus == 0
      assert stats.total_rejections == 0
    end

    @tag :fast
    test "stats count multiple strike_3_plus families" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      for i <- 1..3 do
        RejectionTracker.record_rejection(fp1, "p1_#{i}", "r")
        RejectionTracker.record_rejection(fp2, "p2_#{i}", "r")
      end

      stats = RejectionTracker.stats()
      assert stats.strike_3_plus == 2
      assert stats.total_rejections == 6
    end
  end

  describe "signal emission" do
    @tag :fast
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

    @tag :fast
    test "emits healing_blocked on every rejection at or beyond max" do
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

      # Get to strike 3
      for i <- 1..3 do
        RejectionTracker.record_rejection(fp, "p#{i}", "r#{i}")
      end

      assert_receive {:signal, :healing, :healing_blocked, _}, 100

      # Strike 4 should also emit
      RejectionTracker.record_rejection(fp, "p4", "r4")
      assert_receive {:signal, :healing, :healing_blocked, payload}, 100
      assert payload.rejection_count == 4
    end

    @tag :fast
    test "signal payload includes suppression_ttl_minutes" do
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
           suppression_ttl_minutes: 45,
           signal_callback: callback
         ]}
      )

      fp = make_fingerprint()

      for i <- 1..3 do
        RejectionTracker.record_rejection(fp, "p#{i}", "r#{i}")
      end

      assert_receive {:signal, :healing, :healing_blocked, payload}, 100
      assert payload.suppression_ttl_minutes == 45
    end

    @tag :fast
    test "signal callback failure does not crash tracker" do
      stop_supervised!(RejectionTracker)

      bad_callback = fn _category, _event, _payload ->
        raise "callback explosion"
      end

      start_supervised!(
        {RejectionTracker,
         [
           max_rejections: 3,
           rejection_window_ms: 1000,
           signal_callback: bad_callback
         ]}
      )

      fp = make_fingerprint()

      # Should not crash even with bad callback
      for i <- 1..3 do
        RejectionTracker.record_rejection(fp, "p#{i}", "r#{i}")
      end

      # Tracker should still be alive and functional
      assert RejectionTracker.rejection_count(fp) == 3
    end
  end

  describe "cleanup" do
    @tag :fast
    test "removes old rejections after window expires" do
      fp = make_fingerprint()

      RejectionTracker.record_rejection(fp, "prop_001", "Reason")
      assert RejectionTracker.rejection_count(fp) == 1

      # Wait for cleanup (window: 200ms, cleanup interval: 50ms)
      Process.sleep(300)

      assert RejectionTracker.rejection_count(fp) == 0
    end

    @tag :fast
    test "recent rejections survive cleanup" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      RejectionTracker.record_rejection(fp1, "p1", "old reason")

      # Wait near the window boundary
      Process.sleep(150)

      # Add fp2 rejection - should be recent enough to survive
      RejectionTracker.record_rejection(fp2, "p2", "new reason")

      # Wait for cleanup to run
      Process.sleep(150)

      # fp1 should be cleaned up, fp2 should survive
      assert RejectionTracker.rejection_count(fp1) == 0
      assert RejectionTracker.rejection_count(fp2) == 1
    end
  end

  describe "custom max_rejections configuration" do
    @tag :fast
    test "escalation threshold respects custom max_rejections" do
      stop_supervised!(RejectionTracker)

      start_supervised!(
        {RejectionTracker,
         [
           max_rejections: 2,
           rejection_window_ms: 1000
         ]}
      )

      fp = make_fingerprint()

      r1 = RejectionTracker.record_rejection(fp, "p1", "r1")
      assert r1.strategy == :retry_with_context
      refute r1.should_suppress

      # With max_rejections=2, second rejection should escalate
      r2 = RejectionTracker.record_rejection(fp, "p2", "r2")
      assert r2.strategy == :reduce_scope
      assert r2.should_suppress
    end
  end
end
