defmodule Arbor.Monitor.AnomalyDetectorTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.AnomalyDetector

  setup do
    AnomalyDetector.init()
    AnomalyDetector.reset_all()
    :ok
  end

  describe "update/3" do
    test "tracks running average correctly" do
      # Feed 20 values around 100
      for _ <- 1..20 do
        AnomalyDetector.update(:test, :metric_a, 100.0)
      end

      # Check that EWMA is near 100
      [{_key, stats}] = :ets.lookup(AnomalyDetector.stats_table(), {:test, :metric_a})
      assert_in_delta stats.ewma, 100.0, 1.0
      assert_in_delta stats.mean, 100.0, 1.0
    end

    test "returns :normal for values within bounds" do
      # Build baseline with natural variance
      for i <- 1..20 do
        value = 50.0 + :math.sin(i) * 5.0
        AnomalyDetector.update(:test, :metric_b, value)
      end

      # Value close to baseline should be normal
      assert :normal = AnomalyDetector.update(:test, :metric_b, 52.0)
    end

    test "detects anomaly when value exceeds threshold stddevs from mean" do
      # Build a stable baseline with some variance
      for i <- 1..30 do
        AnomalyDetector.update(:test, :metric_c, 100.0 + rem(i, 3))
      end

      # Huge spike should be detected
      result = AnomalyDetector.update(:test, :metric_c, 500.0)
      assert {:anomaly, severity, details} = result
      assert severity in [:warning, :critical]
      assert details.metric == :metric_c
      assert details.value == 500.0
    end

    test "needs at least 10 observations before detecting" do
      for _ <- 1..9 do
        assert :normal = AnomalyDetector.update(:test, :metric_d, 100.0)
      end

      # Even a wild value should be :normal before 10 observations
      assert :normal = AnomalyDetector.update(:test, :metric_d, 100.0)
    end

    test "handles non-numeric values gracefully" do
      assert :normal = AnomalyDetector.update(:test, :metric_e, "not_a_number")
    end
  end

  describe "reset/2" do
    test "clears stats for a specific metric" do
      AnomalyDetector.update(:test, :metric_f, 100.0)
      AnomalyDetector.reset(:test, :metric_f)

      assert [] = :ets.lookup(AnomalyDetector.stats_table(), {:test, :metric_f})
    end
  end
end
