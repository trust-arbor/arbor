defmodule Arbor.Voice.ApplicationTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.BackendWorkerSupervisor
  alias Arbor.Voice.CleanupLease
  alias Arbor.Voice.CleanupLeaseSupervisor
  alias Arbor.Voice.ResourceSupervisor
  alias Arbor.Voice.ResourceCleanupTaskSupervisor
  alias Arbor.Voice.Test.FakeBackend

  @moduletag :fast

  @startup_child_ids [
    Arbor.Voice.Registry,
    Arbor.Voice.ResourceCleanupTaskSupervisor,
    Arbor.Voice.CleanupLeaseSupervisor,
    Arbor.Voice.BackendWorkerSupervisor,
    Arbor.Voice.SpeechOutputTaskSupervisor,
    Arbor.Voice.ToolTaskSupervisor,
    Arbor.Voice.ResourceSupervisor,
    Arbor.Voice.SessionSupervisor
  ]

  test "the application supervisor is running" do
    pid = Process.whereis(Arbor.Voice.Supervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "the Registry starts under the app supervisor and is usable" do
    assert Process.whereis(Arbor.Voice.Registry) |> is_pid()

    {:ok, _owner} = Registry.register(Arbor.Voice.Registry, :application_test_probe, :ok)
    assert Registry.lookup(Arbor.Voice.Registry, :application_test_probe) != []
  end

  test "application children have the complete cleanup-safe startup order" do
    returned_ids =
      Arbor.Voice.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    # OTP reports these one_for_one children in reverse startup order.
    assert returned_ids == Enum.reverse(@startup_child_ids)
    assert Enum.reverse(returned_ids) == @startup_child_ids
  end

  test "cleanup lease and backend worker supervisors are named, alive, and usable" do
    children = Supervisor.which_children(Arbor.Voice.Supervisor)

    assert {CleanupLeaseSupervisor, cleanup_supervisor, :supervisor, _modules} =
             Enum.find(children, &(elem(&1, 0) == CleanupLeaseSupervisor))

    assert Process.whereis(CleanupLeaseSupervisor) == cleanup_supervisor
    assert Process.alive?(cleanup_supervisor)

    assert {BackendWorkerSupervisor, backend_supervisor, :supervisor, _modules} =
             Enum.find(children, &(elem(&1, 0) == BackendWorkerSupervisor))

    assert Process.whereis(BackendWorkerSupervisor) == backend_supervisor
    assert Process.alive?(backend_supervisor)

    assert {:ok, lease, credential} = CleanupLease.start(self())
    lease_ref = Process.monitor(lease)
    assert {:ok, %{mode: :holding, cleanup_count: 0}} = CleanupLease.status(credential)
    assert :ok = DynamicSupervisor.terminate_child(CleanupLeaseSupervisor, lease)
    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :shutdown}, 500

    previous_trap_exit = Process.flag(:trap_exit, true)
    generation = make_ref()

    assert {:ok, worker, worker_credential} =
             BackendWorkerSupervisor.start_worker(
               BackendWorkerSupervisor,
               self(),
               generation,
               FakeBackend,
               [],
               :none
             )

    worker_ref = Process.monitor(worker)
    assert Process.alive?(worker)
    assert inspect(worker_credential) =~ "generation=redacted"
    assert :ok = DynamicSupervisor.terminate_child(BackendWorkerSupervisor, worker)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 500
    assert_receive {:EXIT, ^worker, :killed}, 500
    Process.flag(:trap_exit, previous_trap_exit)
  end

  @tag spec: "VOICE-7"
  test "ResourceCleanupTaskSupervisor starts before ResourceSupervisor under the app supervisor" do
    supervisor = Arbor.Voice.Supervisor
    children = Supervisor.which_children(supervisor)

    cleanup_entry =
      Enum.find(children, fn {id, _, _, _} -> id == ResourceCleanupTaskSupervisor end)

    assert {ResourceCleanupTaskSupervisor, cleanup_pid, :supervisor, [Task.Supervisor]} =
             cleanup_entry

    assert is_pid(cleanup_pid)
    assert Process.alive?(cleanup_pid)

    resource_entry = Enum.find(children, fn {id, _, _, _} -> id == ResourceSupervisor end)
    assert {ResourceSupervisor, resource_pid, :supervisor, [DynamicSupervisor]} = resource_entry
    assert is_pid(resource_pid)
    assert Process.alive?(resource_pid)
  end

  @tag spec: "VOICE-7"
  test "SessionSupervisor is supervised under the app supervisor" do
    children = Supervisor.which_children(Arbor.Voice.Supervisor)

    entry =
      Enum.find(children, fn {id, _, _, _} -> id == Arbor.Voice.SessionSupervisor end)

    assert {Arbor.Voice.SessionSupervisor, pid, :supervisor, [DynamicSupervisor]} = entry
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  @tag spec: "VOICE-13"
  test "SpeechOutputTaskSupervisor is a dedicated alive Task.Supervisor under the app" do
    supervisor = Arbor.Voice.Supervisor
    children = Supervisor.which_children(supervisor)

    entry =
      Enum.find(children, fn {id, _, _, _} ->
        id == Arbor.Voice.SpeechOutputTaskSupervisor
      end)

    assert {Arbor.Voice.SpeechOutputTaskSupervisor, pid, :supervisor, [Task.Supervisor]} = entry
    assert is_pid(pid)
    assert Process.alive?(pid)
    assert Process.whereis(Arbor.Voice.SpeechOutputTaskSupervisor) == pid

    # Distinct from ResourceOwner cleanup supervisor — separate ownership.
    cleanup = Process.whereis(ResourceCleanupTaskSupervisor)
    assert is_pid(cleanup)
    refute pid == cleanup
  end

  @tag spec: "VOICE-8"
  test "ToolTaskSupervisor is a direct named Task.Supervisor distinct from speech/cleanup" do
    children = Supervisor.which_children(Arbor.Voice.Supervisor)

    entry =
      Enum.find(children, fn {id, _, _, _} ->
        id == Arbor.Voice.ToolTaskSupervisor
      end)

    # Direct Supervisor.child_spec in Application — not a wrapper module child_spec.
    assert {Arbor.Voice.ToolTaskSupervisor, pid, :supervisor, [Task.Supervisor]} = entry
    assert is_pid(pid)
    assert Process.alive?(pid)
    assert Process.whereis(Arbor.Voice.ToolTaskSupervisor) == pid

    speech = Process.whereis(Arbor.Voice.SpeechOutputTaskSupervisor)
    cleanup = Process.whereis(ResourceCleanupTaskSupervisor)
    refute pid == speech
    refute pid == cleanup
  end
end
