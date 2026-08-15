defmodule Arbor.Monitor.MetricsStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.MetricsStore

  setup do
    MetricsStore.clear_all()
    :ok
  end

  describe "put/2 and get/1" do
    test "round-trip stores and retrieves metrics" do
      metrics = %{foo: 42, bar: "hello"}
      assert :ok = MetricsStore.put(:test_skill, metrics)

      assert {:ok, stored, _ts} = MetricsStore.get(:test_skill)
      assert stored.foo == 42
      assert stored.bar == "hello"
    end

    test "returns :not_found for missing skill" do
      assert :not_found = MetricsStore.get(:nonexistent)
    end

    test "overwrites previous value for same skill" do
      MetricsStore.put(:test_skill, %{value: 1})
      MetricsStore.put(:test_skill, %{value: 2})

      assert {:ok, stored, _ts} = MetricsStore.get(:test_skill)
      assert stored.value == 2
    end
  end

  describe "all/0" do
    test "returns all stored metrics" do
      MetricsStore.put(:skill_a, %{a: 1})
      MetricsStore.put(:skill_b, %{b: 2})

      all = MetricsStore.all()
      assert map_size(all) >= 2
      assert {%{a: 1}, _} = all[:skill_a]
      assert {%{b: 2}, _} = all[:skill_b]
    end
  end

  describe "anomaly storage" do
    test "put_anomaly and get_anomalies round-trip" do
      MetricsStore.clear_anomalies()

      MetricsStore.put_anomaly(:beam, :warning, %{metric: :scheduler})
      MetricsStore.put_anomaly(:memory, :critical, %{metric: :total})

      anomalies = MetricsStore.get_anomalies()
      assert length(anomalies) >= 2

      skills = Enum.map(anomalies, & &1.skill)
      assert :beam in skills
      assert :memory in skills
    end

    test "clear_anomalies empties the table" do
      MetricsStore.put_anomaly(:test, :warning, %{})
      MetricsStore.clear_anomalies()

      assert [] = MetricsStore.get_anomalies()
    end
  end

  describe "clear_all/0" do
    test "clears both metrics and anomalies" do
      MetricsStore.put(:test_skill, %{v: 1})
      MetricsStore.put_anomaly(:test, :warning, %{})

      MetricsStore.clear_all()

      assert :not_found = MetricsStore.get(:test_skill)
      assert [] = MetricsStore.get_anomalies()
    end
  end
end
