defmodule Arbor.Agent.LifecycleStartAuthoritySecurityRegressionTest do
  @moduledoc """
  `Lifecycle.start/2` activates authority in the calling process; the admitted
  start worker only verifies it.

  Since ddf05e470 every ordinary start failed closed: the worker activated the
  agent's authority and needed an owner-process-bound `:actor_authority`, which
  admission could not carry (passing one was `:invalid_start_opts`). The fix
  (2026-10-07, option 1 of the inbox item
  `lifecycle-start-cannot-activate-after-ddf05e470`) activates in the caller and
  verifies in the worker, so the authority never leaves its owner process.

  The start here uses `start_session: false`: a Session's signing-authority
  bootstrap is issued only to a worker bound in the production-named TaskStore,
  and these tests own their TaskStore.
  """
  use ExUnit.Case, async: false

  alias Arbor.Agent.{BranchSupervisor, Lifecycle}
  alias Arbor.Agent.Test.{RuntimeAdmissionTopology, TrustTopology}

  @moduletag :security_regression
  @moduletag :fast

  # One actor for the module (see Arbor.Agent.LifecycleActorFixture).
  setup_all do
    {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()
    on_exit(fn -> Arbor.Agent.close_lifecycle_actor_fixture(principal) end)

    {:ok, lifecycle_principal: principal}
  end

  setup %{lifecycle_principal: principal} do
    TrustTopology.ensure_owned!()

    if Process.whereis(:arbor_agent_profiles) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
          id: :arbor_agent_profiles
        )
      )
    end

    %{store: store} = RuntimeAdmissionTopology.start_owned!()
    {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)

    {:ok, actor: actor, store: store}
  end

  test "start activates with the caller's authority and starts the branch", %{
    actor: actor,
    store: store
  } do
    agent_id = create!(actor)

    assert {:ok, pid} =
             Lifecycle.start(agent_id, [actor_authority: actor.authority] ++ start_opts(store))

    assert BranchSupervisor.whereis(agent_id) == pid
    assert {:ok, :active} = Arbor.Security.identity_status(agent_id)
  end

  test "security regression: start without an actor authority fails closed and starts nothing",
       %{actor: actor, store: store} do
    agent_id = create!(actor)

    assert {:error, :capability_mutation_unauthorized} =
             Lifecycle.start(agent_id, start_opts(store))

    assert BranchSupervisor.whereis(agent_id) == nil
  end

  test "security regression: start opts admission would refuse are refused before activation",
       %{actor: actor, store: store} do
    agent_id = create!(actor)

    # Activation re-grants a legacy profile's missing capabilities, so an
    # emptied set shows whether it ran.
    _ = Arbor.Security.revoke_all_fixture(agent_id)
    assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)

    assert {:error, :invalid_start_opts} =
             Lifecycle.start(
               agent_id,
               [actor_authority: actor.authority, name: :public_name_is_refused] ++
                 start_opts(store)
             )

    assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
    assert BranchSupervisor.whereis(agent_id) == nil
  end

  test "security regression: the worker verifies, never mutates: a suspension after activation fails the start closed",
       %{actor: actor, store: store, lifecycle_principal: principal} do
    agent_id = create!(actor)

    # Hold the admitted worker after release, between the caller's activation
    # and the worker's verification.
    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 1_500})
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    start =
      Task.async(fn ->
        {:ok, caller} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)

        Lifecycle.start(agent_id, [actor_authority: caller.authority] ++ start_opts(store))
      end)

    # The intent is admitted only after the caller's activation finished.
    wait_until(fn -> admitted?(store, agent_id) end)

    assert :ok =
             Arbor.Security.suspend_identity(agent_id,
               reason: "lifecycle start verification probe",
               actor_authority: actor.authority
             )

    assert {:error, :authority_not_activated} = Task.await(start, 15_000)
    assert BranchSupervisor.whereis(agent_id) == nil
    # The worker did not resume it: verification has no authority to.
    assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
  end

  defp start_opts(store),
    do: [start_session: false, recover_session: false, task_store: store]

  defp create!(actor) do
    assert {:ok, profile} =
             Lifecycle.create("Start Authority Probe #{System.unique_integer([:positive])}",
               template: "test_agent",
               actor_authority: actor.authority
             )

    agent_id = profile.agent_id
    on_exit(fn -> Arbor.Agent.destroy_agent_fixture(agent_id, actor) end)
    agent_id
  end

  defp admitted?(store, agent_id) do
    %{runtime_admission_intents: intents} = :sys.get_state(store)
    Map.has_key?(intents, agent_id)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
