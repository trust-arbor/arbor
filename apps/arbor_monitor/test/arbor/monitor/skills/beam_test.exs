defmodule Arbor.Monitor.Skills.BeamTest do
  use ExUnit.Case, async: true

  alias Arbor.Monitor.Skills.Beam

  describe "collect/0" do
    test "returns expected keys" do
      assert {:ok, metrics} = Beam.collect()

      assert is_integer(metrics.process_count)
      assert is_integer(metrics.process_limit)
      assert is_float(metrics.process_count_ratio)
      assert is_integer(metrics.atom_count)
      assert is_integer(metrics.atom_limit)
      assert is_integer(metrics.scheduler_count)
      assert is_number(metrics.scheduler_utilization)
      assert is_integer(metrics.reductions)

      assert metrics.process_count > 0
      assert metrics.process_limit > metrics.process_count
      assert metrics.scheduler_count > 0
    end
  end

  describe "check/1" do
    test "returns :normal for healthy metrics" do
      metrics = %{
        scheduler_utilization: 0.10,
        process_count_ratio: 0.05
      }

      assert :normal = Beam.check(metrics)
    end

    test "detects high scheduler utilization" do
      metrics = %{
        scheduler_utilization: 0.95,
        process_count_ratio: 0.05
      }

      assert {:anomaly, :critical, details} = Beam.check(metrics)
      assert details.metric == :scheduler_utilization
    end

    test "detects high process count ratio" do
      metrics = %{
        scheduler_utilization: 0.10,
        process_count_ratio: 0.90
      }

      assert {:anomaly, :warning, details} = Beam.check(metrics)
      assert details.metric == :process_count_ratio
    end
  end

  describe "name/0" do
    test "returns :beam" do
      assert Beam.name() == :beam
    end
  end
end
