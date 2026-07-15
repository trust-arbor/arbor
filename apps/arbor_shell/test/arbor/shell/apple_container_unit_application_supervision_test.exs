defmodule Arbor.Shell.AppleContainerUnitApplicationSupervisionTest do
  @moduledoc false

  # Shared Shell supervisor is used only for the production wiring / disabled-
  # journal liveness checks. Deliberate rest_for_one crash topology runs under an
  # isolated supervisor so global Shell owners stay available for other suites.
  use ExUnit.Case, async: false

  alias Arbor.Shell.AppleContainerUnitDrainCoordinator, as: Coordinator
  alias Arbor.Shell.AppleContainerUnitJournal, as: Journal
  alias Arbor.Shell.AppleContainerUnitRecoveryReconciler, as: Reconciler
  alias Arbor.Shell.AppleContainerUnitRecoverySupervisor, as: RecoverySupervisor
  alias Arbor.Shell.AppleContainerUnitSupervisor, as: UnitSupervisor
  alias Arbor.Shell.PortSessionSupervisor

  describe "production child order" do
    test "places journal, recovery, unit supervisor, then drain coordinator after PortSession" do
      boot_epoch = make_ref()
      children = Arbor.Shell.Application.production_children([startup_path: "/bin"], boot_epoch)
      modules = Enum.map(children, &child_module/1)

      assert modules == [
               Arbor.Shell.ExecutablePolicy,
               Arbor.Shell.AppleContainerControlPlaneAuthority,
               Arbor.Shell.LinuxDependencyBaselineAuthority,
               Arbor.Shell.AppleContainerImagePolicyAuthority,
               Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor,
               Arbor.Shell.ExecutionRegistry,
               DynamicSupervisor,
               Journal,
               RecoverySupervisor,
               UnitSupervisor,
               Coordinator
             ]

      assert Arbor.Shell.Application.supervisor_options() ==
               [strategy: :rest_for_one, name: Arbor.Shell.Supervisor]

      journal_spec = Supervisor.child_spec(Enum.at(children, 7), [])
      recovery_spec = Supervisor.child_spec(Enum.at(children, 8), [])
      unit_spec = Supervisor.child_spec(Enum.at(children, 9), [])
      coord_spec = Supervisor.child_spec(Enum.at(children, 10), [])

      assert match?(%{id: Journal, restart: :permanent}, journal_spec)
      assert match?(%{id: RecoverySupervisor, shutdown: :infinity}, recovery_spec)
      assert match?(%{id: UnitSupervisor, shutdown: :infinity}, unit_spec)
      assert match?(%{id: Coordinator, shutdown: :infinity}, coord_spec)
    end
  end

  describe "shared topology with missing journal config" do
    test "starts disabled journal; reconciler and coordinator remain closed/retrying" do
      assert Application.get_env(:arbor_shell, :apple_container_unit_journal_path) in [nil, ""]

      assert is_pid(Process.whereis(Journal))
      assert is_pid(Process.whereis(RecoverySupervisor))
      assert is_pid(Process.whereis(Reconciler))
      assert is_pid(Process.whereis(UnitSupervisor))
      assert is_pid(Process.whereis(Coordinator))
      assert is_pid(Process.whereis(PortSessionSupervisor))

      status = Journal.status()
      assert status["status"] == "disabled"
      assert is_binary(status["reason"])

      recon = Reconciler.status()
      assert recon["phase"] in ["closed", "startup"]
      assert recon["phase"] != "ready"
      assert recon["awaiting_journal"] == true

      # Coordinator stays closed while journal is disabled: admission fails closed.
      assert {:error, :unit_start_unavailable} =
               Coordinator.start_unit(%{}, :not_an_executable, "exec-1", make_ref())
    end
  end

  describe "rest_for_one restart topology" do
    setup do
      # Isolate crash topology from the shared Shell.Supervisor so deliberate
      # kills cannot poison the suite-wide PortSession/Journal/Recovery owners.
      detach_shared_unit_topology!()

      on_exit(fn ->
        restore_shared_unit_topology!()
      end)

      {:ok, sup} =
        Supervisor.start_link(unit_topology_children(),
          strategy: :rest_for_one,
          max_restarts: 50,
          max_seconds: 5
        )

      on_exit(fn ->
        # Hard-kill the isolated tree. Do not orderly-terminate the coordinator
        # here: its planned drain uses shutdown: :infinity and is covered by the
        # dedicated terminate test; teardown must not hang the suite.
        if Process.alive?(sup), do: Process.exit(sup, :kill)

        wait_until_unregistered([
          Coordinator,
          UnitSupervisor,
          RecoverySupervisor,
          Reconciler,
          RecoverySupervisor.worker_supervisor_name(),
          Journal,
          PortSessionSupervisor
        ])
      end)

      assert eventually?(fn -> topology_ready?() end)

      %{sup: sup}
    end

    test "coordinator failure restarts only the coordinator", %{sup: _sup} do
      snaps = topology_pids!()

      kill_and_await_down!(snaps.coordinator)

      assert eventually?(fn ->
               new_coord = Process.whereis(Coordinator)
               is_pid(new_coord) and new_coord != snaps.coordinator
             end)

      assert Process.whereis(PortSessionSupervisor) == snaps.port_session
      assert Process.whereis(Journal) == snaps.journal
      assert Process.whereis(RecoverySupervisor) == snaps.recovery
      assert Process.whereis(Reconciler) == snaps.reconciler
      assert Process.whereis(UnitSupervisor) == snaps.unit_supervisor
      refute Process.whereis(Coordinator) == snaps.coordinator
    end

    test "unit supervisor failure turns over unit supervisor and coordinator only", %{sup: _sup} do
      snaps = topology_pids!()

      kill_and_await_down!(snaps.unit_supervisor)

      assert eventually?(fn ->
               new_unit = Process.whereis(UnitSupervisor)
               new_coord = Process.whereis(Coordinator)

               is_pid(new_unit) and new_unit != snaps.unit_supervisor and
                 is_pid(new_coord) and new_coord != snaps.coordinator
             end)

      assert Process.whereis(PortSessionSupervisor) == snaps.port_session
      assert Process.whereis(Journal) == snaps.journal
      assert Process.whereis(RecoverySupervisor) == snaps.recovery
      assert Process.whereis(Reconciler) == snaps.reconciler
      refute Process.whereis(UnitSupervisor) == snaps.unit_supervisor
      refute Process.whereis(Coordinator) == snaps.coordinator
    end

    test "recovery composite failure turns over recovery, unit supervisor, and coordinator", %{
      sup: _sup
    } do
      snaps = topology_pids!()

      # Kill the permanent reconciler so the one_for_all recovery composite
      # (max_restarts: 0) shuts down cleanly and frees child names before the
      # rest_for_one parent restarts the composite under a new PID.
      kill_and_await_down!(snaps.reconciler)

      assert eventually?(fn ->
               new_recovery = Process.whereis(RecoverySupervisor)
               new_reconciler = Process.whereis(Reconciler)
               new_unit = Process.whereis(UnitSupervisor)
               new_coord = Process.whereis(Coordinator)

               is_pid(new_recovery) and new_recovery != snaps.recovery and
                 is_pid(new_reconciler) and new_reconciler != snaps.reconciler and
                 is_pid(new_unit) and new_unit != snaps.unit_supervisor and
                 is_pid(new_coord) and new_coord != snaps.coordinator
             end)

      assert Process.whereis(PortSessionSupervisor) == snaps.port_session
      assert Process.whereis(Journal) == snaps.journal
      refute Process.whereis(RecoverySupervisor) == snaps.recovery
      refute Process.whereis(Reconciler) == snaps.reconciler
      refute Process.whereis(UnitSupervisor) == snaps.unit_supervisor
      refute Process.whereis(Coordinator) == snaps.coordinator
    end

    test "journal failure turns over journal, recovery, unit supervisor, and coordinator", %{
      sup: _sup
    } do
      snaps = topology_pids!()

      kill_and_await_down!(snaps.journal)

      assert eventually?(fn ->
               new_journal = Process.whereis(Journal)
               new_recovery = Process.whereis(RecoverySupervisor)
               new_reconciler = Process.whereis(Reconciler)
               new_unit = Process.whereis(UnitSupervisor)
               new_coord = Process.whereis(Coordinator)

               is_pid(new_journal) and new_journal != snaps.journal and
                 is_pid(new_recovery) and new_recovery != snaps.recovery and
                 is_pid(new_reconciler) and new_reconciler != snaps.reconciler and
                 is_pid(new_unit) and new_unit != snaps.unit_supervisor and
                 is_pid(new_coord) and new_coord != snaps.coordinator
             end)

      assert Process.whereis(PortSessionSupervisor) == snaps.port_session
      refute Process.whereis(Journal) == snaps.journal
      refute Process.whereis(RecoverySupervisor) == snaps.recovery
      refute Process.whereis(UnitSupervisor) == snaps.unit_supervisor
      refute Process.whereis(Coordinator) == snaps.coordinator

      # Replacement journal remains disabled under missing config.
      assert Journal.status()["status"] == "disabled"
    end

    test "planned coordinator terminate leaves unit, recovery, journal, and port session live", %{
      sup: sup
    } do
      snaps = topology_pids!()

      # terminate/2 is bounded (no planned barrier wait). rest_for_one can stop
      # the coordinator while earlier siblings remain alive.
      assert :ok = Supervisor.terminate_child(sup, Coordinator)
      refute is_pid(Process.whereis(Coordinator))

      assert Process.whereis(UnitSupervisor) == snaps.unit_supervisor
      assert Process.whereis(RecoverySupervisor) == snaps.recovery
      assert Process.whereis(Reconciler) == snaps.reconciler
      assert Process.whereis(Journal) == snaps.journal
      assert Process.whereis(PortSessionSupervisor) == snaps.port_session

      assert {:ok, _pid} = Supervisor.restart_child(sup, Coordinator)
      assert eventually?(fn -> is_pid(Process.whereis(Coordinator)) end)
    end

    test "journal crash while unit topology is live cannot deadlock rest_for_one turnover", %{
      sup: _sup
    } do
      # Security / lifecycle regression: coordinator terminate must not wait on
      # earlier siblings. If it did, Journal restart would hang indefinitely.
      snaps = topology_pids!()
      started = System.monotonic_time(:millisecond)

      kill_and_await_down!(snaps.journal)

      assert eventually?(fn ->
               new_journal = Process.whereis(Journal)
               new_coord = Process.whereis(Coordinator)

               is_pid(new_journal) and new_journal != snaps.journal and
                 is_pid(new_coord) and new_coord != snaps.coordinator
             end)

      elapsed = System.monotonic_time(:millisecond) - started
      # Bounded rest_for_one turnover (not absence-proof budget).
      assert elapsed < 2_000
    end

    test "recovery crash while unit topology is live cannot deadlock rest_for_one turnover", %{
      sup: _sup
    } do
      snaps = topology_pids!()
      started = System.monotonic_time(:millisecond)

      kill_and_await_down!(snaps.reconciler)

      assert eventually?(fn ->
               new_recovery = Process.whereis(RecoverySupervisor)
               new_coord = Process.whereis(Coordinator)

               is_pid(new_recovery) and new_recovery != snaps.recovery and
                 is_pid(new_coord) and new_coord != snaps.coordinator
             end)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 2_000
    end

    test "port session crash while unit topology is live cannot deadlock rest_for_one turnover",
         %{
           sup: _sup
         } do
      snaps = topology_pids!()
      started = System.monotonic_time(:millisecond)

      kill_and_await_down!(snaps.port_session)

      assert eventually?(fn ->
               new_port = Process.whereis(PortSessionSupervisor)
               new_coord = Process.whereis(Coordinator)

               is_pid(new_port) and new_port != snaps.port_session and
                 is_pid(new_coord) and new_coord != snaps.coordinator
             end)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 2_000
    end
  end

  describe "Application.prep_stop durable barrier" do
    setup do
      detach_shared_unit_topology!()

      on_exit(fn ->
        restore_shared_unit_topology!()
      end)

      {:ok, sup} =
        Supervisor.start_link(unit_topology_children(),
          strategy: :rest_for_one,
          max_restarts: 50,
          max_seconds: 5
        )

      on_exit(fn ->
        if Process.alive?(sup), do: Process.exit(sup, :kill)

        wait_until_unregistered([
          Coordinator,
          UnitSupervisor,
          RecoverySupervisor,
          Reconciler,
          RecoverySupervisor.worker_supervisor_name(),
          Journal,
          PortSessionSupervisor
        ])
      end)

      assert eventually?(fn -> topology_ready?() end)
      %{sup: sup}
    end

    test "prep_stop completes durable barrier before returning and preserves state", %{sup: _sup} do
      # Immutable children_started?: true — barrier runs even if config is flipped
      # to false after start. Disabled journal + empty UnitSupervisor succeeds.
      prev = Application.get_env(:arbor_shell, :start_children, false)
      Application.put_env(:arbor_shell, :start_children, false)

      on_exit(fn ->
        Application.put_env(:arbor_shell, :start_children, prev)
      end)

      app_state = %{
        startup_epoch: make_ref(),
        children_started?: true,
        probe: :preserved
      }

      returned = Arbor.Shell.Application.prep_stop(app_state)
      assert returned == app_state
      assert returned.probe == :preserved
      assert is_pid(Process.whereis(Coordinator))
    end

    test "prep_stop skips barrier for intentionally childless state", %{sup: sup} do
      # Kill entire unit topology so any barrier attempt would block forever.
      for id <- [Coordinator, UnitSupervisor, RecoverySupervisor, Journal, PortSessionSupervisor] do
        _ = Supervisor.terminate_child(sup, id)
        _ = Supervisor.delete_child(sup, id)
      end

      wait_until_unregistered([
        Coordinator,
        UnitSupervisor,
        RecoverySupervisor,
        Reconciler,
        RecoverySupervisor.worker_supervisor_name(),
        Journal,
        PortSessionSupervisor
      ])

      prev = Application.get_env(:arbor_shell, :start_children, false)
      # Config claims children should start — state says they did not.
      Application.put_env(:arbor_shell, :start_children, true)

      on_exit(fn ->
        Application.put_env(:arbor_shell, :start_children, prev)
      end)

      app_state = %{startup_epoch: make_ref(), children_started?: false, probe: :childless}

      # Must return immediately without waiting for a coordinator that will never appear.
      task =
        Task.async(fn ->
          Arbor.Shell.Application.prep_stop(app_state)
        end)

      assert Task.await(task, 500) == app_state
    end

    test "prep_stop remains blocked while coordinator is absent then completes after restart", %{
      sup: sup
    } do
      # Terminate coordinator and prevent restart until we re-add it.
      assert :ok = Supervisor.terminate_child(sup, Coordinator)
      assert :ok = Supervisor.delete_child(sup, Coordinator)
      refute is_pid(Process.whereis(Coordinator))

      parent = self()

      task =
        Task.async(fn ->
          send(parent, :prep_started)

          Arbor.Shell.Application.prep_stop(%{
            startup_epoch: make_ref(),
            children_started?: true
          })
        end)

      assert_receive :prep_started, 1_000
      Process.sleep(150)
      # Still blocked — coordinator absent and children_started? requires barrier.
      assert Process.alive?(task.pid)

      assert {:ok, _pid} = Supervisor.start_child(sup, Coordinator)
      assert eventually?(fn -> is_pid(Process.whereis(Coordinator)) end)

      result = Task.await(task, 5_000)
      assert is_map(result)
      assert result.children_started? == true
    end

    test "prep_stop composes with durable empty-journal barrier on live topology", %{sup: _sup} do
      # Live disabled Journal + empty UnitSupervisor is the production test-env
      # path; callback must invoke prepare_durable_shutdown and return only after
      # positive empty evidence.
      app_state = %{startup_epoch: make_ref(), children_started?: true}

      returned = Arbor.Shell.Application.prep_stop(app_state)
      assert returned == app_state
      assert is_pid(Process.whereis(Coordinator))
      assert Journal.status()["status"] == "disabled"
    end
  end

  defp unit_topology_children do
    [
      {DynamicSupervisor, name: PortSessionSupervisor, strategy: :one_for_one},
      Journal,
      RecoverySupervisor,
      Arbor.Shell.AppleContainerUnitWorker.supervisor_child_spec(),
      Coordinator
    ]
  end

  defp topology_pids! do
    %{
      port_session: must_pid!(PortSessionSupervisor),
      journal: must_pid!(Journal),
      recovery: must_pid!(RecoverySupervisor),
      reconciler: must_pid!(Reconciler),
      unit_supervisor: must_pid!(UnitSupervisor),
      coordinator: must_pid!(Coordinator)
    }
  end

  defp topology_ready? do
    is_pid(Process.whereis(PortSessionSupervisor)) and
      is_pid(Process.whereis(Journal)) and
      is_pid(Process.whereis(RecoverySupervisor)) and
      is_pid(Process.whereis(Reconciler)) and
      is_pid(Process.whereis(UnitSupervisor)) and
      is_pid(Process.whereis(Coordinator))
  end

  defp must_pid!(name) do
    pid = Process.whereis(name)
    assert is_pid(pid), "expected #{inspect(name)} to be registered"
    pid
  end

  defp kill_and_await_down!(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  defp detach_shared_unit_topology! do
    shell = Process.whereis(Arbor.Shell.Supervisor)

    if is_pid(shell) do
      for id <- [
            Coordinator,
            UnitSupervisor,
            RecoverySupervisor,
            Journal,
            PortSessionSupervisor
          ] do
        _ = Supervisor.terminate_child(shell, id)
        _ = Supervisor.delete_child(shell, id)
      end
    end

    wait_until_unregistered([
      Coordinator,
      UnitSupervisor,
      RecoverySupervisor,
      Reconciler,
      RecoverySupervisor.worker_supervisor_name(),
      Journal,
      PortSessionSupervisor
    ])
  end

  defp restore_shared_unit_topology! do
    shell = Process.whereis(Arbor.Shell.Supervisor)

    if is_pid(shell) do
      for child <- unit_topology_children() do
        case Supervisor.start_child(shell, child) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :already_present} -> :ok
          {:error, {:already_present, _}} -> :ok
          _other -> :ok
        end
      end

      assert eventually?(fn -> topology_ready?() end)
    end
  end

  defp wait_until_unregistered(names) when is_list(names) do
    assert eventually?(fn ->
             Enum.all?(names, fn name -> is_nil(Process.whereis(name)) end)
           end)
  end

  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(%{id: id}) when is_atom(id), do: id
  defp child_module(module) when is_atom(module), do: module

  defp eventually?(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(fun, deadline)
      else
        false
      end
    end
  end
end
