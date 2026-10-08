defmodule Arbor.Agent.LifecycleActorFixtureTest do
  @moduledoc """
  The shared test actor for `Lifecycle.create/2` and `Lifecycle.destroy/2`
  (both require `:actor_authority` since ddf05e470). Also the usage example for
  suites that create agents.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Test.TrustTopology

  @moduletag :fast

  # One actor for the module (see Arbor.Agent.LifecycleActorFixture); tests
  # reopen it in their own process.
  setup_all do
    {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()
    on_exit(fn -> Arbor.Agent.close_lifecycle_actor_fixture(principal) end)

    {:ok, lifecycle_principal: principal}
  end

  # The test_agent template applies a trust preset (needs Arbor.Trust.Store),
  # and creation persists the profile (needs the profiles BufferedStore).
  setup do
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

    :ok
  end

  test "Lifecycle.create/2 fails closed without an actor authority" do
    assert {:error, :capability_mutation_unauthorized} =
             Lifecycle.create("Unauthorized Probe #{System.unique_integer([:positive])}",
               template: "test_agent"
             )
  end

  test "an actor reopened in the test process can create and completely destroy an agent",
       %{lifecycle_principal: principal} do
    assert {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)
    agent_id = create!(actor)

    log =
      capture_log(fn ->
        assert :ok = Lifecycle.destroy(agent_id, actor_authority: actor.authority)
      end)

    # destroy/2 returns :ok even when cleanup is incomplete; assert it was not.
    refute log =~ "destroy cleanup was incomplete"
    assert_destroyed!(agent_id)
  end

  test "reopening records no security mutation", %{lifecycle_principal: principal} do
    # Every grant is an audit-journal operation. Reopening must not record any,
    # or sharing one actor per module saves nothing.
    before = admitted_operations()

    assert {:ok, actor} =
             in_other_process(fn -> Arbor.Agent.reopen_lifecycle_actor_fixture(principal) end)

    assert admitted_operations() == before
    assert actor.actor_id == principal.actor_id
  end

  test "destroy_agent_fixture/2 destroys from another process and keeps the shared actor",
       %{lifecycle_principal: principal} do
    assert {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)
    agent_id = create!(actor)

    # Stands in for an on_exit callback, which runs after the test process (and
    # its authority) is gone.
    {result, log} =
      with_log(fn ->
        in_other_process(fn -> Arbor.Agent.destroy_agent_fixture(agent_id, actor) end)
      end)

    assert result == :ok
    refute log =~ "destroy cleanup was incomplete"
    assert_destroyed!(agent_id)

    # Closing a reopened handle, there or here, leaves the actor's rights.
    assert :ok = Arbor.Agent.close_lifecycle_actor_fixture(actor)
    assert {:ok, caps} = Arbor.Security.list_capabilities(principal.actor_id)
    assert length(caps) == length(principal.capability_ids)
    assert {:ok, _actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)
  end

  test "close/1 on an opened actor removes its rights" do
    assert {:ok, actor} = Arbor.Agent.open_lifecycle_actor_fixture()
    assert {:ok, caps} = Arbor.Security.list_capabilities(actor.actor_id)
    assert length(caps) == length(actor.capability_ids)

    assert :ok = Arbor.Agent.close_lifecycle_actor_fixture(actor)

    assert {:ok, []} = Arbor.Security.list_capabilities(actor.actor_id)
  end

  defp create!(actor) do
    assert {:ok, profile} =
             Lifecycle.create("Fixture Probe #{System.unique_integer([:positive])}",
               template: "test_agent",
               actor_authority: actor.authority
             )

    profile.agent_id
  end

  defp in_other_process(fun), do: fun |> Task.async() |> Task.await(10_000)

  # Every operation the journal has admitted: retirement moves operations from
  # retained to retired, so the sum only grows, by one per operation.
  defp admitted_operations do
    assert {:ok, status} = Arbor.Security.audit_journal_status()
    capacity = status["capacity"]
    capacity["retained_operation_count"] + capacity["retired_operation_total"]
  end

  defp assert_destroyed!(agent_id) do
    assert {:error, _} = Arbor.Security.lookup_public_key(agent_id)
    assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
  end
end
