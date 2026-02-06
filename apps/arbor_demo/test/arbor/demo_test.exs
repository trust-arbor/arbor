defmodule Arbor.DemoTest do
  use ExUnit.Case, async: true

  alias Arbor.Demo.FaultInjector

  setup do
    supervisor = start_supervised!({Arbor.Demo.Supervisor, name: nil})

    injector =
      start_supervised!(
        {FaultInjector,
         name: nil,
         supervisor: supervisor,
         fault_modules: %{
           message_queue_flood: Arbor.Demo.Faults.MessageQueueFlood,
           process_leak: Arbor.Demo.Faults.ProcessLeak,
           supervisor_crash: Arbor.Demo.Faults.SupervisorCrash
         }}
      )

    Application.put_env(:arbor_demo, :signal_emission_enabled, false)

    %{injector: injector}
  end

  describe "inject_fault/3" do
    test "injects a known fault type and returns correlation_id", %{injector: injector} do
      assert {:ok, correlation_id} =
               FaultInjector.inject_fault(injector, :message_queue_flood)

      assert is_binary(correlation_id)
      assert String.starts_with?(correlation_id, "fault_mqf_")
    end

    test "returns error for unknown fault type", %{injector: injector} do
      assert {:error, :unknown_fault_type} =
               FaultInjector.inject_fault(injector, :nonexistent)
    end

    test "returns error when fault already active", %{injector: injector} do
      {:ok, _} = FaultInjector.inject_fault(injector, :message_queue_flood)

      assert {:error, :already_active} =
               FaultInjector.inject_fault(injector, :message_queue_flood)
    end
  end

  describe "stop_fault/2" do
    test "stops an active fault by type", %{injector: injector} do
      {:ok, _correlation_id} = FaultInjector.inject_fault(injector, :message_queue_flood)
      assert :ok = FaultInjector.stop_fault(injector, :message_queue_flood)
    end

    test "stops an active fault by correlation_id", %{injector: injector} do
      {:ok, correlation_id} = FaultInjector.inject_fault(injector, :message_queue_flood)
      assert :ok = FaultInjector.stop_fault(injector, correlation_id)
    end

    test "returns error when fault not active", %{injector: injector} do
      assert {:error, :not_active} =
               FaultInjector.stop_fault(injector, :message_queue_flood)
    end
  end

  describe "stop_all/1" do
    test "stops all active faults", %{injector: injector} do
      {:ok, _} = FaultInjector.inject_fault(injector, :message_queue_flood)
      {:ok, _} = FaultInjector.inject_fault(injector, :process_leak)

      assert {:ok, 2} = FaultInjector.stop_all(injector)
      assert %{} == FaultInjector.active_faults(injector)
    end

    test "returns zero when no faults active", %{injector: injector} do
      assert {:ok, 0} = FaultInjector.stop_all(injector)
    end
  end

  describe "active_faults/1" do
    test "returns empty map when no faults", %{injector: injector} do
      assert %{} == FaultInjector.active_faults(injector)
    end

    test "returns metadata for active faults keyed by correlation_id", %{injector: injector} do
      {:ok, correlation_id} = FaultInjector.inject_fault(injector, :message_queue_flood)
      faults = FaultInjector.active_faults(injector)

      assert Map.has_key?(faults, correlation_id)
      info = faults[correlation_id]
      assert info.type == :message_queue_flood
      assert info.correlation_id == correlation_id
      assert is_binary(info.description)
      assert is_integer(info.injected_at)
      assert is_list(info.detectable_by)
    end
  end

  describe "fault_status/2" do
    test "returns :inactive for non-active faults", %{injector: injector} do
      assert :inactive == FaultInjector.fault_status(injector, :message_queue_flood)
    end

    test "returns status map for active faults", %{injector: injector} do
      {:ok, correlation_id} = FaultInjector.inject_fault(injector, :message_queue_flood)
      status = FaultInjector.fault_status(injector, :message_queue_flood)

      assert status.status == :active
      assert status.correlation_id == correlation_id
      assert is_integer(status.injected_at)
    end
  end

  describe "get_correlation_id/2" do
    test "returns correlation_id for active fault", %{injector: injector} do
      {:ok, correlation_id} = FaultInjector.inject_fault(injector, :message_queue_flood)
      assert correlation_id == FaultInjector.get_correlation_id(injector, :message_queue_flood)
    end

    test "returns nil for inactive fault", %{injector: injector} do
      assert nil == FaultInjector.get_correlation_id(injector, :message_queue_flood)
    end
  end

  describe "available_faults/1" do
    test "lists all registered fault types", %{injector: injector} do
      faults = FaultInjector.available_faults(injector)
      types = Enum.map(faults, & &1.type) |> Enum.sort()

      assert :message_queue_flood in types
      assert :process_leak in types
      assert :supervisor_crash in types
    end
  end
end
