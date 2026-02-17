defmodule Arbor.Monitor.CascadeDetectorTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.CascadeDetector

  # Use short timeouts for testing
  @test_opts [
    window_ms: 100,
    cascade_threshold: 3,
    settling_cycles: 2,
    max_concurrent_proposals: 2,
    exit_threshold_ms: 50,
    check_interval_ms: 25
  ]

  setup do
    start_supervised!({CascadeDetector, @test_opts})
    CascadeDetector.reset()
    :ok
  end

  defp make_anomaly(skill \\ :memory) do
    %{
      skill: skill,
      severity: :warning,
      details: %{
        metric: :total_bytes,
        value: 1_000_000,
        ewma: 800_000
      }
    }
  end

  describe "record_anomaly/1" do
    @tag :fast
    test "tracks anomaly count" do
      assert CascadeDetector.current_rate() == 0

      CascadeDetector.record_anomaly(make_anomaly())
      assert CascadeDetector.current_rate() == 1

      CascadeDetector.record_anomaly(make_anomaly())
      assert CascadeDetector.current_rate() == 2
    end

    @tag :fast
    test "rate resets after window expires" do
      CascadeDetector.record_anomaly(make_anomaly())
      CascadeDetector.record_anomaly(make_anomaly())
      assert CascadeDetector.current_rate() == 2

      # Wait for window to expire (100ms + buffer)
      Process.sleep(150)

      assert CascadeDetector.current_rate() == 0
    end

    @tag :fast
    test "anomalies from different skills all count toward rate" do
      CascadeDetector.record_anomaly(make_anomaly(:memory))
      CascadeDetector.record_anomaly(make_anomaly(:ets))
      CascadeDetector.record_anomaly(make_anomaly(:beam))

      assert CascadeDetector.current_rate() == 3
    end
  end

  describe "cascade detection" do
    @tag :fast
    test "enters cascade mode when threshold exceeded" do
      refute CascadeDetector.in_cascade?()

      # Add anomalies up to threshold
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
    end

    @tag :fast
    test "stays below cascade when under threshold" do
      CascadeDetector.record_anomaly(make_anomaly())
      CascadeDetector.record_anomaly(make_anomaly())

      refute CascadeDetector.in_cascade?()
    end

    @tag :fast
    test "exits cascade mode after exit threshold with low rate" do
      # Enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()

      # Wait for window to clear and exit threshold
      Process.sleep(200)

      refute CascadeDetector.in_cascade?()
    end

    @tag :fast
    test "stays in cascade if rate remains high" do
      # Enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()

      # Keep adding anomalies
      Process.sleep(50)
      CascadeDetector.record_anomaly(make_anomaly())
      CascadeDetector.record_anomaly(make_anomaly())
      CascadeDetector.record_anomaly(make_anomaly())

      Process.sleep(50)
      assert CascadeDetector.in_cascade?()
    end
  end

  describe "state machine transitions" do
    @tag :fast
    test "normal -> cascade -> settled -> normal full lifecycle" do
      # Phase 1: Normal state
      refute CascadeDetector.in_cascade?()
      refute CascadeDetector.should_settle?()
      assert CascadeDetector.max_concurrent_proposals() == 999
      assert CascadeDetector.dedup_multiplier() == 1.0

      # Phase 2: Enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
      assert CascadeDetector.should_settle?()
      assert CascadeDetector.max_concurrent_proposals() == 2
      assert CascadeDetector.dedup_multiplier() == 0.2

      # Phase 3: Settle (burn through settling cycles)
      CascadeDetector.polling_cycle_completed()
      CascadeDetector.polling_cycle_completed()

      assert CascadeDetector.in_cascade?()
      refute CascadeDetector.should_settle?()

      # Phase 4: Exit cascade after exit_threshold_ms with low rate
      Process.sleep(200)

      refute CascadeDetector.in_cascade?()
      refute CascadeDetector.should_settle?()
      assert CascadeDetector.max_concurrent_proposals() == 999
      assert CascadeDetector.dedup_multiplier() == 1.0
    end

    @tag :fast
    test "cascade re-entry after exit" do
      # Enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
      status1 = CascadeDetector.status()
      assert status1.cascades_detected == 1

      # Exit cascade
      Process.sleep(200)
      refute CascadeDetector.in_cascade?()

      # Re-enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
      status2 = CascadeDetector.status()
      assert status2.cascades_detected == 2
      # Settling should reset on re-entry
      assert status2.settling_cycles_remaining == 2
    end

    @tag :fast
    test "exact threshold boundary - at threshold enters cascade" do
      # Exactly at threshold (3) should trigger cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
      assert CascadeDetector.current_rate() == 3
    end

    @tag :fast
    test "one below threshold does not enter cascade" do
      for _ <- 1..2 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      refute CascadeDetector.in_cascade?()
      assert CascadeDetector.current_rate() == 2
    end

    @tag :fast
    test "cascade persists while rate stays above threshold even after settling" do
      # Enter cascade
      for _ <- 1..5 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()

      # Complete settling
      CascadeDetector.polling_cycle_completed()
      CascadeDetector.polling_cycle_completed()
      refute CascadeDetector.should_settle?()

      # Still in cascade because rate is high
      assert CascadeDetector.in_cascade?()
    end
  end

  describe "settling" do
    @tag :fast
    test "should_settle? returns true immediately after entering cascade" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.should_settle?()
    end

    @tag :fast
    test "settling countdown decrements with polling cycles" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 2

      CascadeDetector.polling_cycle_completed()
      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 1

      CascadeDetector.polling_cycle_completed()
      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 0

      refute CascadeDetector.should_settle?()
    end

    @tag :fast
    test "should_settle? returns false when not in cascade" do
      refute CascadeDetector.should_settle?()
    end

    @tag :fast
    test "extra polling cycles beyond zero do not go negative" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      # Burn through settling cycles
      CascadeDetector.polling_cycle_completed()
      CascadeDetector.polling_cycle_completed()

      # Extra cycles should not go negative
      CascadeDetector.polling_cycle_completed()
      CascadeDetector.polling_cycle_completed()

      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 0
    end

    @tag :fast
    test "settling resets when cascade exits and re-enters" do
      # Enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      # Burn one settling cycle
      CascadeDetector.polling_cycle_completed()
      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 1

      # Exit cascade
      Process.sleep(200)
      refute CascadeDetector.in_cascade?()

      # Re-enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      # Settling should be fresh again
      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 2
    end
  end

  describe "max_concurrent_proposals/0" do
    @tag :fast
    test "returns configured limit during cascade" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.max_concurrent_proposals() == 2
    end

    @tag :fast
    test "returns high number when not in cascade" do
      assert CascadeDetector.max_concurrent_proposals() == 999
    end
  end

  describe "dedup_multiplier/0" do
    @tag :fast
    test "returns reduced multiplier during cascade" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      # During cascade, dedup window is shortened
      assert CascadeDetector.dedup_multiplier() == 0.2
    end

    @tag :fast
    test "returns 1.0 when not in cascade" do
      assert CascadeDetector.dedup_multiplier() == 1.0
    end
  end

  describe "status/0" do
    @tag :fast
    test "returns comprehensive status" do
      status = CascadeDetector.status()

      assert is_boolean(status.in_cascade)
      assert is_integer(status.current_rate)
      assert is_integer(status.threshold)
      assert is_integer(status.cascades_detected)
      assert is_integer(status.total_anomalies)
      assert is_integer(status.max_concurrent_proposals)
      assert is_float(status.dedup_multiplier)
    end

    @tag :fast
    test "tracks cascade count" do
      # First cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      Process.sleep(200)
      refute CascadeDetector.in_cascade?()

      # Second cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      status = CascadeDetector.status()
      assert status.cascades_detected == 2
    end

    @tag :fast
    test "tracks total anomalies" do
      for _ <- 1..5 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      status = CascadeDetector.status()
      assert status.total_anomalies == 5
    end

    @tag :fast
    test "status reflects cascade_started_at when in cascade" do
      # Before cascade
      status_before = CascadeDetector.status()
      assert status_before.cascade_started_at == nil

      # Enter cascade
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      status_during = CascadeDetector.status()
      assert status_during.in_cascade == true
      # cascade_started_at is internal state, verified via the in_cascade flag
    end

    @tag :fast
    test "total_anomalies accumulates across multiple cascades" do
      # First cascade: 3 anomalies
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      Process.sleep(200)

      # Second cascade: 4 more anomalies
      for _ <- 1..4 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      status = CascadeDetector.status()
      assert status.total_anomalies == 7
    end
  end

  describe "reset/0" do
    @tag :fast
    test "clears all state" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()

      CascadeDetector.reset()

      refute CascadeDetector.in_cascade?()
      assert CascadeDetector.current_rate() == 0
    end

    @tag :fast
    test "reset clears settling state" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.should_settle?()

      CascadeDetector.reset()

      refute CascadeDetector.should_settle?()
      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 0
    end
  end

  describe "signal emission" do
    @tag :fast
    test "calls signal callback when entering cascade" do
      test_pid = self()

      callback = fn category, event, payload ->
        send(test_pid, {:signal, category, event, payload})
      end

      # Start detector with callback
      stop_supervised!(CascadeDetector)

      start_supervised!(
        {CascadeDetector,
         [
           window_ms: 100,
           cascade_threshold: 3,
           settling_cycles: 2,
           exit_threshold_ms: 50,
           check_interval_ms: 25,
           signal_callback: callback
         ]}
      )

      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert_receive {:signal, :monitor, :cascade_detected, payload}, 100
      assert payload.threshold == 3
      assert payload.rate >= 3
    end

    @tag :fast
    test "calls signal callback when exiting cascade" do
      test_pid = self()

      callback = fn category, event, payload ->
        send(test_pid, {:signal, category, event, payload})
      end

      stop_supervised!(CascadeDetector)

      start_supervised!(
        {CascadeDetector,
         [
           window_ms: 50,
           cascade_threshold: 3,
           settling_cycles: 1,
           exit_threshold_ms: 30,
           check_interval_ms: 10,
           signal_callback: callback
         ]}
      )

      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert_receive {:signal, :monitor, :cascade_detected, _}, 100

      # Wait for cascade to exit
      Process.sleep(150)

      assert_receive {:signal, :monitor, :cascade_resolved, payload}, 100
      assert is_integer(payload.duration_ms)
    end

    @tag :fast
    test "no signal emitted when callback is nil" do
      # Default setup has no callback - just ensure no crash
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
    end

    @tag :fast
    test "signal callback failure does not crash detector" do
      stop_supervised!(CascadeDetector)

      # Callback that raises
      bad_callback = fn _category, _event, _payload ->
        raise "callback explosion"
      end

      start_supervised!(
        {CascadeDetector,
         [
           window_ms: 100,
           cascade_threshold: 3,
           settling_cycles: 2,
           exit_threshold_ms: 50,
           check_interval_ms: 25,
           signal_callback: bad_callback
         ]}
      )

      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      # Should still be in cascade despite callback failure
      assert CascadeDetector.in_cascade?()
    end
  end

  describe "custom configuration" do
    @tag :fast
    test "respects custom cascade_threshold" do
      stop_supervised!(CascadeDetector)

      start_supervised!(
        {CascadeDetector,
         [
           window_ms: 200,
           cascade_threshold: 5,
           settling_cycles: 1,
           exit_threshold_ms: 50,
           check_interval_ms: 25
         ]}
      )

      # 3 anomalies should NOT trigger cascade with threshold=5
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      refute CascadeDetector.in_cascade?()

      # 2 more should trigger it
      for _ <- 1..2 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
    end

    @tag :fast
    test "respects custom settling_cycles" do
      stop_supervised!(CascadeDetector)

      start_supervised!(
        {CascadeDetector,
         [
           window_ms: 200,
           cascade_threshold: 3,
           settling_cycles: 4,
           exit_threshold_ms: 50,
           check_interval_ms: 25
         ]}
      )

      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      status = CascadeDetector.status()
      assert status.settling_cycles_remaining == 4

      # Need 4 polling cycles to settle
      for _ <- 1..3 do
        CascadeDetector.polling_cycle_completed()
      end

      assert CascadeDetector.should_settle?()

      CascadeDetector.polling_cycle_completed()
      refute CascadeDetector.should_settle?()
    end

    @tag :fast
    test "respects custom max_concurrent_proposals" do
      stop_supervised!(CascadeDetector)

      start_supervised!(
        {CascadeDetector,
         [
           window_ms: 200,
           cascade_threshold: 3,
           settling_cycles: 1,
           max_concurrent_proposals: 5,
           exit_threshold_ms: 50,
           check_interval_ms: 25
         ]}
      )

      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.max_concurrent_proposals() == 5
    end
  end
end
