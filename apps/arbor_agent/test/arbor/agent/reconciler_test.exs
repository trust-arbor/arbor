defmodule Arbor.Agent.ReconcilerTest do
  @moduledoc """
  Integration tests for `Arbor.Agent.Reconciler` — the imperative shell that
  snapshots desired (profiles) vs actual (live registry) state, asks
  `Arbor.Agent.LifecycleCore.reconcile/3`, and applies the intents.

  Driven synchronously via `reconcile_now/0` (never the timer). The zombie-reap
  test is the regression guard for orphan class **G2** (a live agent whose
  identity has been removed must be reaped), and the fail-safe test guards the
  security invariant that a present identity is never reaped.

  ## Test-env setup notes

  In the isolated `arbor_agent` suite `config :arbor_security, start_children:
  false`, so the Identity Registry that `identity_present?/1` consults is NOT
  running. We start just `Arbor.Security.Identity.Registry` here (it degrades
  gracefully without its BufferedStore) so identity status is real: present after
  `register_identity/1`, gone after `deregister_identity/1`.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arbor.Agent.{Reconciler, Registry, ProfileStore, Profile, Character}
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security

  @profiles_store :arbor_agent_profiles

  # Minimal live agent — stands in for a real branch without the heavy deps.
  defmodule FakeAgent do
    @moduledoc false
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, Map.new(opts)}
  end

  setup do
    # Identity Registry — required for identity_present?/1 to return real status.
    if Process.whereis(Arbor.Security.Identity.Registry) == nil do
      start_supervised!({Arbor.Security.Identity.Registry, []})
    end

    # Profiles store — needed for the DESIRED snapshot (G1). Matches ManagerTest.
    if Process.whereis(@profiles_store) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles_store, backend: nil, write_mode: :sync},
          id: @profiles_store
        )
      )
    end

    # Reconciler under test — disabled timer, we drive it via reconcile_now/1.
    server =
      start_supervised!(
        {Reconciler, name: :reconciler_under_test, enabled: false, g1_policy: :start}
      )

    {:ok, server: server}
  end

  # Register a real identity and a live registered agent sharing its agent_id.
  defp live_agent_with_identity do
    {:ok, identity} = Security.generate_identity()
    agent_id = identity.agent_id
    :ok = Security.register_identity(identity)

    {:ok, pid} =
      Arbor.Agent.Supervisor.start_child(
        agent_id: agent_id,
        module: FakeAgent,
        start_opts: [],
        metadata: %{}
      )

    on_exit(fn ->
      try do
        Arbor.Agent.Manager.stop_agent(agent_id)
      catch
        _, _ -> :ok
      end

      Security.deregister_identity(agent_id)
    end)

    %{agent_id: agent_id, pid: pid}
  end

  defp intents_for(intents, agent_id), do: Enum.filter(intents, &(&1.agent_id == agent_id))

  describe "G2 — reap identity-gone zombie (regression guard)" do
    test "reaps a live agent whose identity was removed", %{server: server} do
      %{agent_id: agent_id, pid: pid} = live_agent_with_identity()

      # Precondition: identity present and agent alive/registered.
      assert {:ok, _status} = Security.identity_status(agent_id)
      assert {:ok, ^pid} = Registry.whereis(agent_id)

      # Remove the identity → the agent is now an identity-gone zombie.
      :ok = Security.deregister_identity(agent_id)
      assert {:error, :not_found} = Security.identity_status(agent_id)

      intents = Reconciler.reconcile_now(server)

      # The core decided :reap for our agent...
      mine = intents_for(intents, agent_id)
      assert [%{action: :reap, reason: :identity_gone}] = mine

      # ...and the shell actually applied it — the branch/process is gone.
      assert {:error, :not_found} = Registry.whereis(agent_id)
      refute Process.alive?(pid)
    end
  end

  describe "fail-safe — never reap while identity is present" do
    test "does NOT reap an agent whose identity is present", %{server: server} do
      %{agent_id: agent_id, pid: pid} = live_agent_with_identity()

      assert {:ok, _status} = Security.identity_status(agent_id)

      intents = Reconciler.reconcile_now(server)

      # No reap intent for our agent, and it is still alive/registered.
      assert intents_for(intents, agent_id) == []
      assert Process.alive?(pid)
      assert {:ok, ^pid} = Registry.whereis(agent_id)
    end
  end

  describe "G1 — start desired-but-absent auto_start agent" do
    test "produces a :start intent for an auto_start profile with no live process",
         %{server: server} do
      # An auto_start profile whose agent_id is NOT in the live registry.
      agent_id = "reconciler-g1-#{System.unique_integer([:positive])}"

      profile = %Profile{
        agent_id: agent_id,
        display_name: "G1 Test",
        character: Character.new(name: "G1 Test"),
        auto_start: true,
        metadata: %{},
        created_at: DateTime.utc_now(),
        version: 1
      }

      :ok = ProfileStore.store_profile(profile)

      on_exit(fn ->
        try do
          Arbor.Agent.Manager.stop_agent(agent_id)
        catch
          _, _ -> :ok
        end
      end)

      intents = Reconciler.reconcile_now(server)

      # We assert the reconcile pass PRODUCES the :start intent. We do not assert a
      # real process starts: the full resume/start path needs orchestrator + memory
      # infrastructure that is not booted in the isolated arbor_agent test env
      # (the shell's Manager.resume_agent call is best-effort and wrapped).
      mine = intents_for(intents, agent_id)
      assert [%{action: :start, reason: :desired_running_but_absent}] = mine
    end
  end
end
