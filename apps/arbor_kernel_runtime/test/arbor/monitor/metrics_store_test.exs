defmodule Arbor.Monitor.MetricsStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.MetricsStore

  setup do
    # MetricsStore owns its ETS tables in `init/1`, so the tables die with the
    # process. Several tests in this app legitimately stop and restart
    # :arbor_kernel_runtime (application_test, boot_profile_binding_*,
    # provider_gate_lifecycle_*), and the Monitor tree comes back
    # ASYNCHRONOUSLY. Calling clear_all/0 in that window raised
    # `ArgumentError ... table identifier does not refer to an existing ETS
    # table` and took all 7 tests here with it — intermittently, which is why it
    # read as seed-dependent. Wait for readiness instead of assuming it.
    assert wait_for_store(2_000), "MetricsStore tables never became available"
    MetricsStore.clear_all()
    :ok
  end

  defp wait_for_store(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_store(deadline)
  end

  defp do_wait_for_store(deadline) do
    if store_ready?() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(25)
        do_wait_for_store(deadline)
      end
    end
  end

  defp store_ready? do
    is_pid(Process.whereis(MetricsStore)) and
      :ets.whereis(MetricsStore.metrics_table()) != :undefined and
      :ets.whereis(MetricsStore.anomaly_table()) != :undefined
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
