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
    test "injects a known fault type", %{injector: injector} do
      assert {:ok, :message_queue_flood} =
               FaultInjector.inject_fault(injector, :message_queue_flood)
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

  describe "clear_fault/2" do
    test "clears an active fault", %{injector: injector} do
      {:ok, _} = FaultInjector.inject_fault(injector, :message_queue_flood)
      assert :ok = FaultInjector.clear_fault(injector, :message_queue_flood)
    end

    test "returns error when fault not active", %{injector: injector} do
      assert {:error, :not_active} =
               FaultInjector.clear_fault(injector, :message_queue_flood)
    end
  end

  describe "clear_all/1" do
    test "clears all active faults", %{injector: injector} do
      {:ok, _} = FaultInjector.inject_fault(injector, :message_queue_flood)
      {:ok, _} = FaultInjector.inject_fault(injector, :process_leak)

      assert {:ok, 2} = FaultInjector.clear_all(injector)
      assert %{} == FaultInjector.active_faults(injector)
    end

    test "returns zero when no faults active", %{injector: injector} do
      assert {:ok, 0} = FaultInjector.clear_all(injector)
    end
  end

  describe "active_faults/1" do
    test "returns empty map when no faults", %{injector: injector} do
      assert %{} == FaultInjector.active_faults(injector)
    end

    test "returns metadata for active faults", %{injector: injector} do
      {:ok, _} = FaultInjector.inject_fault(injector, :message_queue_flood)
      faults = FaultInjector.active_faults(injector)

      assert Map.has_key?(faults, :message_queue_flood)
      info = faults[:message_queue_flood]
      assert info.type == :message_queue_flood
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
      {:ok, _} = FaultInjector.inject_fault(injector, :message_queue_flood)
      status = FaultInjector.fault_status(injector, :message_queue_flood)

      assert status.status == :active
      assert is_integer(status.injected_at)
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
