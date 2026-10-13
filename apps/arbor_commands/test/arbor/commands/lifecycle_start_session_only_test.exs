defmodule Arbor.Commands.LifecycleStartSessionOnlyTest do
  @moduledoc """
  Moved from `arbor_agent` `lifecycle_start_session_false_test.exs`.

  `arbor_agent` cannot depend on `arbor_orchestrator` (both L7), so the
  Session-starting assertion was skip-tagged and never ran. This L8 app
  depends on both and can load Session.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Agent.{BranchSupervisor, Lifecycle}
  alias Arbor.Agent.Test.RuntimeAdmissionTopology
  alias Arbor.Commands.Test.SessionLifecycleHelpers, as: Helpers

  setup_all do
    Helpers.require_agent_test_support!()
    prev = Helpers.setup_security_flags!()
    Helpers.start_runtime!()

    {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()

    on_exit(fn ->
      Arbor.Agent.close_lifecycle_actor_fixture(principal)
      Helpers.restore_security_flags!(prev)
    end)

    {:ok, lifecycle_principal: principal}
  end

  setup %{lifecycle_principal: principal} do
    Helpers.start_runtime!()
    {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)
    %{lifecycle_actor: actor}
  end

  test "start_session: true with start_heartbeat: false still starts Session only", %{
    lifecycle_actor: actor
  } do
    %{store: store} = RuntimeAdmissionTopology.start_fixed_production!()

    assert {:ok, profile} =
             Lifecycle.create("Start Heartbeat False Probe",
               template: "test_agent",
               actor_authority: actor.authority
             )

    agent_id = profile.agent_id
    Helpers.cleanup(agent_id, actor)

    assert {:ok, sup_pid} =
             Lifecycle.start(agent_id,
               actor_authority: actor.authority,
               start_heartbeat: false,
               recover_session: false,
               task_store: store
             )

    children = Supervisor.which_children(sup_pid)
    child_ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

    pids = BranchSupervisor.child_pids(agent_id)
    assert is_pid(pids.host)
    assert is_pid(pids.executor)
    assert is_pid(pids.session)
    assert :session in child_ids
    refute :heartbeat_service in child_ids

    assert :ok = Lifecycle.stop(agent_id)
  end
end
