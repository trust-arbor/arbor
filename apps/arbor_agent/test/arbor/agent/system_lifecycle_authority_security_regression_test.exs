defmodule Arbor.Agent.SystemLifecycleAuthoritySecurityRegressionTest do
  @moduledoc """
  Decision D4: Bootstrap and the Reconciler start auto_start agents as a
  narrowly scoped system lifecycle principal.

  Since ddf05e470 `Lifecycle.start/2` needs an owner-process-bound
  `:actor_authority`, and these two callers have no human, so every auto-start
  failed closed. `Arbor.Agent.SystemLifecycleAuthority` holds a long-lived
  authority for its own principal, which holds no rights of its own: a human
  delegates per-agent rights by enabling auto_start
  (`Manager.set_auto_start/3`), and disabling revokes them.

  The human here is the shared lifecycle actor fixture. Starts use
  `start_session: false` with a test-owned TaskStore (a Session bootstrap needs
  the production-named one). The principal, Reconciler and Bootstrap run as the
  exact production children of `Arbor.Agent.AppSupervisor`.
  """
  use ExUnit.Case, async: false

  alias Arbor.Agent.{
    Bootstrap,
    BranchSupervisor,
    Lifecycle,
    Manager,
    ProfileStore,
    Reconciler,
    SystemLifecycleAuthority
  }

  alias Arbor.Agent.Test.{RuntimeAdmissionTopology, SystemLifecycleTopology, TrustTopology}
  alias Arbor.Contracts.Security.Identity

  @moduletag :security_regression

  setup_all do
    {:ok, human} = Arbor.Agent.open_lifecycle_actor_fixture()
    %{token: token, principal_id: principal_id} = SystemLifecycleTopology.start_owner!()

    on_exit(fn ->
      SystemLifecycleTopology.stop_child(Reconciler)
      SystemLifecycleTopology.stop_child(Bootstrap)
      SystemLifecycleTopology.stop_child(SystemLifecycleAuthority)
      _ = Arbor.Security.revoke_all_fixture(principal_id)
      Arbor.Agent.close_lifecycle_actor_fixture(human)
    end)

    {:ok, human_principal: human, token: token, principal_id: principal_id}
  end

  setup %{human_principal: human_principal} do
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
    {:ok, human} = Arbor.Agent.reopen_lifecycle_actor_fixture(human_principal)

    on_exit(fn ->
      SystemLifecycleTopology.stop_child(Reconciler)
      SystemLifecycleTopology.stop_child(Bootstrap)
    end)

    {:ok, human: human, store: store}
  end

  test "security regression: the principal refuses an agent whose auto_start flag was set without a human's delegation",
       %{human: human, store: store, token: token, principal_id: principal_id} do
    agent_id = create!(human)

    # Desired state written directly, as stale data or a direct store write
    # would: no human delegated anything.
    force_auto_start!(agent_id, true)
    SystemLifecycleTopology.start_reconciler!(token, start_opts(store))

    assert [%{action: :start}] = intents_for(Reconciler.reconcile_now(Reconciler), agent_id)
    assert BranchSupervisor.whereis(agent_id) == nil
    assert delegated(principal_id, agent_id) == []
  end

  test "security regression: after a human enables auto_start the Reconciler starts the agent as the principal",
       %{human: human, store: store, token: token, principal_id: principal_id} do
    agent_id = create!(human)

    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)
    assert {:ok, %{auto_start: true}} = ProfileStore.load_profile(agent_id)

    assert Enum.sort(delegated(principal_id, agent_id)) ==
             Enum.sort(SystemLifecycleAuthority.delegated_resources(agent_id))

    SystemLifecycleTopology.start_reconciler!(token, start_opts(store))

    assert [%{action: :start}] = intents_for(Reconciler.reconcile_now(Reconciler), agent_id)
    assert is_pid(BranchSupervisor.whereis(agent_id))
    assert {:ok, :active} = Arbor.Security.identity_status(agent_id)
  end

  test "security regression: an exact-policy agent starts as the principal without the global register right",
       %{human: human, store: store, token: token, principal_id: principal_id} do
    # Exact profiles re-register their identity strictly at activation. The
    # principal holds no `arbor://security/identity/register`, so this start
    # needs Lifecycle to skip registering an identity already registered with
    # the profile's key.
    {:ok, profile} =
      Lifecycle.create("System Exact Probe #{System.unique_integer([:positive])}",
        template: "pipeline_architect",
        actor_authority: human.authority
      )

    agent_id = profile.agent_id
    cleanup(agent_id, human)

    refute Enum.any?(principal_caps(principal_id), &(&1 == "arbor://security/identity/register"))
    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)
    SystemLifecycleTopology.start_reconciler!(token, start_opts(store))

    assert [%{action: :start}] = intents_for(Reconciler.reconcile_now(Reconciler), agent_id)
    assert is_pid(BranchSupervisor.whereis(agent_id))
  end

  test "security regression: the principal cannot mint capabilities: a drifted exact-policy agent fails closed",
       %{human: human, store: store, token: token, principal_id: principal_id} do
    # The principal holds no grant/revoke rights (Hysun, 2026-10-08), so an
    # exact-policy agent whose capabilities drifted is not re-synced on an
    # unattended start: activation fails closed and suspends it.
    {:ok, profile} =
      Lifecycle.create("System Drift Probe #{System.unique_integer([:positive])}",
        template: "pipeline_architect",
        actor_authority: human.authority
      )

    agent_id = profile.agent_id
    cleanup(agent_id, human)

    refute Enum.any?(
             principal_caps(principal_id),
             &String.starts_with?(&1, "arbor://security/grant")
           )

    refute Enum.any?(
             principal_caps(principal_id),
             &String.starts_with?(&1, "arbor://security/revoke")
           )

    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)

    # Drift: a human removes one of the agent's exact capabilities.
    assert {:ok, [dropped | _] = before} = Arbor.Security.list_capabilities(agent_id)
    assert :ok = Arbor.Security.revoke(dropped.id, actor_authority: human.authority)

    SystemLifecycleTopology.start_reconciler!(token, start_opts(store))
    _ = Reconciler.reconcile_now(Reconciler)

    assert BranchSupervisor.whereis(agent_id) == nil
    assert {:ok, after_caps} = Arbor.Security.list_capabilities(agent_id)
    refute Enum.any?(after_caps, &(&1.resource_uri == dropped.resource_uri))
    assert length(after_caps) == length(before) - 1
    assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
  end

  test "security regression: after disabling, the principal's delegation is gone and its start fails closed",
       %{human: human, store: store, token: token, principal_id: principal_id} do
    agent_id = create!(human)

    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)
    assert :ok = Manager.set_auto_start(agent_id, false, actor_authority: human.authority)

    assert {:ok, %{auto_start: false}} = ProfileStore.load_profile(agent_id)
    assert delegated(principal_id, agent_id) == []

    # Even with the flag forced back on, nothing authorizes the principal.
    force_auto_start!(agent_id, true)
    SystemLifecycleTopology.start_reconciler!(token, start_opts(store))

    assert [%{action: :start}] = intents_for(Reconciler.reconcile_now(Reconciler), agent_id)
    assert BranchSupervisor.whereis(agent_id) == nil
  end

  test "security regression: set_auto_start without a human authority fails closed and changes nothing",
       %{human: human, principal_id: principal_id} do
    agent_id = create!(human)

    assert {:error, :capability_mutation_unauthorized} = Manager.set_auto_start(agent_id, true)

    assert {:error, :capability_mutation_unauthorized} =
             Arbor.Agent.set_auto_start(agent_id, true)

    assert {:error, :capability_mutation_unauthorized} =
             Manager.set_auto_start(agent_id, true, [])

    assert {:ok, %{auto_start: false}} = ProfileStore.load_profile(agent_id)
    assert delegated(principal_id, agent_id) == []
  end

  test "security regression: a human cannot delegate start rights it does not hold over the agent",
       %{human: human, principal_id: principal_id} do
    agent_id = create!(human)

    # This human may grant to and revoke from the principal, but holds no
    # rights over the agent itself.
    narrow = open_narrow_human!(principal_id)

    assert {:error, :capability_mutation_unauthorized} =
             Manager.set_auto_start(agent_id, true, actor_authority: narrow)

    assert {:ok, %{auto_start: false}} = ProfileStore.load_profile(agent_id)
    assert delegated(principal_id, agent_id) == []
  end

  test "security regression: the principal holds only exact per-agent rights, never wildcard or global ones",
       %{human: human, principal_id: principal_id} do
    agent_id = create!(human)
    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)

    caps = principal_caps(principal_id)
    assert caps != []

    for uri <- caps do
      refute String.contains?(uri, "*"), "wildcard capability #{uri}"

      assert [_, target] =
               Regex.run(
                 ~r<^arbor://security/identity/(?:suspend|resume)/(agent_[0-9a-f]{64})$>,
                 uri
               ),
             "non-per-agent capability #{uri}"

      assert uri in SystemLifecycleAuthority.delegated_resources(target)
    end
  end

  test "security regression: an unpermitted process cannot drive the principal",
       %{human: human, store: store, token: token} do
    agent_id = create!(human)
    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)

    # Opted in and holding the right token: only caller admission stops these.
    assert {:error, :system_lifecycle_unauthorized} =
             SystemLifecycleAuthority.start_agent(agent_id, start_opts(store), token)

    # A process holding the Reconciler's registered name, but not the
    # supervised child of the application root.
    SystemLifecycleTopology.stop_child(Reconciler)

    impostor =
      Task.async(fn ->
        Process.register(self(), Reconciler)
        SystemLifecycleAuthority.start_agent(agent_id, start_opts(store), token)
      end)

    assert {:error, :system_lifecycle_unauthorized} = Task.await(impostor, 30_000)

    owner = Process.whereis(SystemLifecycleAuthority)

    assert {:error, :system_lifecycle_unauthorized} =
             GenServer.call(owner, {:start_agent, agent_id, start_opts(store), token})

    assert BranchSupervisor.whereis(agent_id) == nil
  end

  test "security regression: the Reconciler is refused without the startup token",
       %{human: human, store: store} do
    agent_id = create!(human)
    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)

    SystemLifecycleTopology.start_reconciler!(make_ref(), start_opts(store))

    assert [%{action: :start}] = intents_for(Reconciler.reconcile_now(Reconciler), agent_id)
    assert BranchSupervisor.whereis(agent_id) == nil
  end

  test "security regression: Bootstrap starts opted-in profiles as the principal and never creates seed agents",
       %{human: human, store: store, token: token} do
    agent_id = create!(human)
    assert :ok = Manager.set_auto_start(agent_id, true, actor_authority: human.authority)

    missing_seed = "missing-seed-#{System.unique_integer([:positive])}"
    put_env(:bootstrap_enabled, true)

    put_env(:auto_start_agents, [
      %{display_name: missing_seed, module: Arbor.Agent.APIAgent, template: "test_agent"}
    ])

    SystemLifecycleTopology.start_bootstrap!(token, start_opts(store))

    wait_until(fn -> bootstrap_status() == :ready end)
    assert is_pid(BranchSupervisor.whereis(agent_id))
    assert agent_id in Enum.map(Bootstrap.status().agents, & &1.agent_id)
    assert :not_found = Manager.find_existing_profile(missing_seed, nil)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp start_opts(store),
    do: [start_session: false, recover_session: false, task_store: store]

  defp create!(human) do
    assert {:ok, profile} =
             Lifecycle.create("System Lifecycle Probe #{System.unique_integer([:positive])}",
               template: "test_agent",
               actor_authority: human.authority
             )

    cleanup(profile.agent_id, human)
    profile.agent_id
  end

  defp cleanup(agent_id, human) do
    on_exit(fn ->
      _ = Lifecycle.stop(agent_id)
      Arbor.Agent.destroy_agent_fixture(agent_id, human)
    end)
  end

  defp force_auto_start!(agent_id, enabled) do
    {:ok, profile} = ProfileStore.load_profile(agent_id)
    :ok = ProfileStore.store_profile(%{profile | auto_start: enabled})
  end

  defp principal_caps(principal_id) do
    {:ok, caps} = Arbor.Security.list_capabilities(principal_id)
    Enum.map(caps, & &1.resource_uri)
  end

  defp delegated(principal_id, agent_id) do
    resources = SystemLifecycleAuthority.delegated_resources(agent_id)
    Enum.filter(principal_caps(principal_id), &(&1 in resources))
  end

  defp intents_for(intents, agent_id), do: Enum.filter(intents, &(&1.agent_id == agent_id))

  defp open_narrow_human!(principal_id) do
    {:ok, actor} = Identity.generate(name: "narrow-human-#{System.unique_integer([:positive])}")
    :ok = Arbor.Security.register_identity_fixture(Identity.public_only(actor))

    for operation <- [:grant, :revoke] do
      {:ok, _cap} =
        Arbor.Security.grant_fixture(
          principal: actor.agent_id,
          resource: "arbor://security/#{operation}/#{principal_id}"
        )
    end

    # The broker loads the key from the signing-key store when it opens.
    :ok = Arbor.Security.store_signing_key_fixture(actor.agent_id, actor.private_key)

    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        actor.agent_id,
        actor.private_key,
        purpose: :narrow_human_test,
        owner: self()
      )

    {:ok, authority} = Arbor.Security.open_signing_authority(proof)

    on_exit(fn ->
      _ = Arbor.Security.revoke_all_fixture(actor.agent_id)
      _ = Arbor.Security.delete_signing_key_fixture(actor.agent_id)
      _ = Arbor.Security.deregister_identity_fixture(actor.agent_id)
    end)

    authority
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:arbor_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbor_agent, key, old)
        :error -> Application.delete_env(:arbor_agent, key)
      end
    end)

    Application.put_env(:arbor_agent, key, value)
  end

  defp bootstrap_status do
    Bootstrap.status().status
  catch
    :exit, _ -> :busy
  end

  defp wait_until(fun, attempts \\ 300) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)
    end
  end
end
