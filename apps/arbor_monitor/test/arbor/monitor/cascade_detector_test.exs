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
    test "tracks anomaly count" do
      assert CascadeDetector.current_rate() == 0

      CascadeDetector.record_anomaly(make_anomaly())
      assert CascadeDetector.current_rate() == 1

      CascadeDetector.record_anomaly(make_anomaly())
      assert CascadeDetector.current_rate() == 2
    end

    test "rate resets after window expires" do
      CascadeDetector.record_anomaly(make_anomaly())
      CascadeDetector.record_anomaly(make_anomaly())
      assert CascadeDetector.current_rate() == 2

      # Wait for window to expire (100ms + buffer)
      Process.sleep(150)

      assert CascadeDetector.current_rate() == 0
    end
  end

  describe "cascade detection" do
    test "enters cascade mode when threshold exceeded" do
      refute CascadeDetector.in_cascade?()

      # Add anomalies up to threshold
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()
    end

    test "stays below cascade when under threshold" do
      CascadeDetector.record_anomaly(make_anomaly())
      CascadeDetector.record_anomaly(make_anomaly())

      refute CascadeDetector.in_cascade?()
    end

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

  describe "settling" do
    test "should_settle? returns true immediately after entering cascade" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.should_settle?()
    end

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

    test "should_settle? returns false when not in cascade" do
      refute CascadeDetector.should_settle?()
    end
  end

  describe "max_concurrent_proposals/0" do
    test "returns configured limit during cascade" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.max_concurrent_proposals() == 2
    end

    test "returns high number when not in cascade" do
      assert CascadeDetector.max_concurrent_proposals() == 999
    end
  end

  describe "dedup_multiplier/0" do
    test "returns reduced multiplier during cascade" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      # During cascade, dedup window is shortened
      assert CascadeDetector.dedup_multiplier() == 0.2
    end

    test "returns 1.0 when not in cascade" do
      assert CascadeDetector.dedup_multiplier() == 1.0
    end
  end

  describe "status/0" do
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

    test "tracks total anomalies" do
      for _ <- 1..5 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      status = CascadeDetector.status()
      assert status.total_anomalies == 5
    end
  end

  describe "reset/0" do
    test "clears all state" do
      for _ <- 1..3 do
        CascadeDetector.record_anomaly(make_anomaly())
      end

      assert CascadeDetector.in_cascade?()

      CascadeDetector.reset()

      refute CascadeDetector.in_cascade?()
      assert CascadeDetector.current_rate() == 0
    end
  end

  describe "signal emission" do
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
  end
end
