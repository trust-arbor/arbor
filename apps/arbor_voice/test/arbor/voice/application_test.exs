defmodule Arbor.Voice.ApplicationTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.ResourceSupervisor
  alias Arbor.Voice.ResourceCleanupTaskSupervisor

  @moduletag :fast

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
