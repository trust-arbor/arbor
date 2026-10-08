defmodule Arbor.Agent.LifecycleActorFixtureTest do
  @moduledoc """
  The shared test actor for `Lifecycle.create/2` (required `:actor_authority`
  since ddf05e470). Also the usage example for suites that create agents.
  """

  use ExUnit.Case, async: false

  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Test.TrustTopology

  @moduletag :fast

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

  test "an opened lifecycle actor can create an agent" do
    assert {:ok, actor} = Arbor.Agent.open_lifecycle_actor_fixture()
    on_exit(fn -> Arbor.Agent.close_lifecycle_actor_fixture(actor) end)

    assert {:ok, profile} =
             Lifecycle.create("Fixture Probe #{System.unique_integer([:positive])}",
               template: "test_agent",
               actor_authority: actor.authority
             )

    assert is_binary(profile.agent_id)

    # The authority is owned by this test process, so tear down here, not in
    # on_exit (which runs after this process has exited).
    assert :ok = Lifecycle.destroy(profile.agent_id, actor_authority: actor.authority)
  end

  test "close/1 removes the actor's creation rights" do
    assert {:ok, actor} = Arbor.Agent.open_lifecycle_actor_fixture()
    assert {:ok, caps} = Arbor.Security.list_capabilities(actor.actor_id)
    assert length(caps) == length(actor.capability_ids)

    assert :ok = Arbor.Agent.close_lifecycle_actor_fixture(actor)

    assert {:ok, []} = Arbor.Security.list_capabilities(actor.actor_id)
  end
end
