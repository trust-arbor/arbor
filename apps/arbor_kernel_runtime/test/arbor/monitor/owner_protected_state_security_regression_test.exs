defmodule Arbor.Monitor.OwnerProtectedStateSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-019"

  @moduletag :fast

  @tables [
    :arbor_monitor_metrics,
    :arbor_monitor_anomalies,
    :arbor_monitor_stats,
    :arbor_healing_queue,
    :arbor_healing_fingerprints,
    :arbor_healing_suppressed,
    :arbor_healing_rejections,
    :arbor_healing_verifying,
    :arbor_agent_telemetry,
    :arbor_skill_library,
    :arbor_node_registry,
    :capability_index,
    :capability_index_tokens
  ]

  setup do
    for module <- [
          Arbor.Monitor.AnomalyQueue,
          Arbor.Monitor.RejectionTracker,
          Arbor.Monitor.Verification,
          Arbor.Common.AgentTelemetry.Store,
          Arbor.Common.SkillLibrary,
          Arbor.Common.NodeRegistry,
          Arbor.Common.CapabilityIndex
        ] do
      if Process.whereis(module) == nil do
        start_supervised!({module, []})
      end
    end

    :ok
  end

  @tag spec: "KSEC-019"
  test "security regression: runtime state tables reject non-owner mutation" do
    Enum.each(@tables, fn table ->
      assert wait_for_table(table), "expected #{inspect(table)} to be supervised"
      assert :protected == :ets.info(table, :protection)

      assert_raise ArgumentError, fn ->
        :ets.insert(table, {{:forged, make_ref()}, :attacker_controlled})
      end
    end)

    assert :ok = Arbor.Monitor.MetricsStore.put(:owner_api_probe, %{value: 1})
    assert {:ok, %{value: 1}, _timestamp} = Arbor.Monitor.MetricsStore.get(:owner_api_probe)

    telemetry = Arbor.Common.AgentTelemetry.new("agent_owner_api_probe")
    assert :ok = Arbor.Common.AgentTelemetry.Store.put("agent_owner_api_probe", telemetry)

    assert %Arbor.Contracts.Agent.Telemetry{} =
             Arbor.Common.AgentTelemetry.Store.get("agent_owner_api_probe")
  end

  defp wait_for_table(table, attempts \\ 40)
  defp wait_for_table(table, 0), do: :ets.whereis(table) != :undefined

  defp wait_for_table(table, attempts) do
    if :ets.whereis(table) == :undefined do
      Process.sleep(25)
      wait_for_table(table, attempts - 1)
    else
      true
    end
  end
end
