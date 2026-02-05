defmodule Arbor.MonitorTest do
  use ExUnit.Case, async: true

  describe "status/0" do
    test "returns health summary" do
      status = Arbor.Monitor.status()

      assert is_map(status)
      assert status.status in [:healthy, :warning, :critical, :emergency]
      assert is_integer(status.anomaly_count)
      assert is_list(status.skills)
      assert is_list(status.metrics_available)
    end
  end

  describe "collect/0" do
    test "runs all skills and returns results map" do
      results = Arbor.Monitor.collect()

      assert is_map(results)
      assert Map.has_key?(results, :beam)
      assert Map.has_key?(results, :memory)
      assert Map.has_key?(results, :ets)
      assert Map.has_key?(results, :processes)
      assert Map.has_key?(results, :system)

      Enum.each(results, fn {_name, result} ->
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end)
    end
  end

  describe "collect/1" do
    test "runs a specific skill" do
      assert {:ok, metrics} = Arbor.Monitor.collect(:beam)
      assert is_map(metrics)
      assert Map.has_key?(metrics, :process_count)
    end

    test "returns error for unknown skill" do
      assert {:error, :unknown_skill} = Arbor.Monitor.collect(:nonexistent)
    end
  end

  describe "metrics/0" do
    test "reads stored metrics from ETS" do
      # Trigger a collect to populate
      Arbor.Monitor.collect()
      metrics = Arbor.Monitor.metrics()
      assert is_map(metrics)
    end
  end

  describe "skills/0" do
    test "lists available skill names" do
      skills = Arbor.Monitor.skills()
      assert is_list(skills)
      assert :beam in skills
      assert :memory in skills
      assert :ets in skills
      assert :processes in skills
      assert :system in skills
    end
  end
end
