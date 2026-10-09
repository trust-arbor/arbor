defmodule Arbor.Agent.LifecycleStartSessionFalseTest do
  @moduledoc """
  Phase 6 runtime regression: `Lifecycle.start(agent_id, start_session: false)`
  must start neither Session nor HeartbeatService, even when `start_heartbeat`
  is omitted or true.

  Root cause: session_enabled gated authority bootstrap issuance, but
  build_branch_session_opts still produced session opts whenever
  session_execution_mode was :session/:graph. build_heartbeat_opts then
  emitted heartbeat opts without a heartbeat signing-authority bootstrap.
  BranchSupervisor skips Session when start_session is false, but still
  starts HeartbeatService whenever heartbeat_opts is non-nil.

  Topology: this suite does not supervise production Agent children, so it
  owns unique ready RuntimeAdmission.Supervisor / Task.Supervisor / TaskStore
  processes per test via `Arbor.Agent.Test.RuntimeAdmissionTopology` and routes
  both Lifecycle.start calls through the test-only task_store seam. The Registry
  remains the fixed production name `Arbor.Agent.RuntimeAdmissionRegistry`
  (IntentOwner hardcodes it); tests only ensure it exists, never invent a unique
  registry name.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arbor.Agent.{BranchSupervisor, Lifecycle}
  alias Arbor.Agent.Test.{RuntimeAdmissionTopology, TrustTopology}
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security.SigningAuthorityBroker

  @profiles_store :arbor_agent_profiles

  setup_all do
    prev_security =
      for key <- [:capability_signing_required, :strict_identity_mode, :identity_verification] do
        {key, Application.get_env(:arbor_security, key)}
      end

    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :identity_verification, false)

    on_exit(fn ->
      for {key, value} <- prev_security do
        if is_nil(value),
          do: Application.delete_env(:arbor_security, key),
          else: Application.put_env(:arbor_security, key, value)
      end
    end)

    # Lifecycle.create needs Trust Store. Keep the process under its application
    # owner so this module composes with earlier umbrella test helpers.
    TrustTopology.ensure_owned!()

    security_backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      start_security_child(
        Supervisor.child_spec(
          {BufferedStore,
           name: name, backend: security_backend, write_mode: :sync, collection: collection},
          id: name
        )
      )
    end

    signing_authority_owner_token = make_ref()

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.SigningAuthorityStateOwner,
           broker_token: signing_authority_owner_token},
          {Arbor.Security.SigningAuthorityBroker,
           state_owner_token: signing_authority_owner_token},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      start_security_child(child)
    end

    if Process.whereis(@profiles_store) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles_store, backend: nil, write_mode: :sync},
          id: @profiles_store
        )
      )
    end

    :ok
  end

  # Own unique RA supervisor / Task.Supervisor / TaskStore per test so
  # Lifecycle.start does not poll a global TaskStore left by order (or absent).
  setup do
    Process.put(
      :agent_test_actor_authority,
      Arbor.Agent.Test.ActorAuthority.open!(:lifecycle_start_session)
    )

    RuntimeAdmissionTopology.start_owned!()
  end

  test "start_session: false starts host/executor without Session or HeartbeatService", %{
    store: store
  } do
    assert {:ok, profile} = create!("Start Session False Probe", template: "test_agent")

    agent_id = profile.agent_id
    cleanup(agent_id)

    assert principal_bootstraps(agent_id) == []

    # Intentionally omit start_heartbeat (defaults true) to prove start_session:false
    # alone is authoritative for suppressing the session-dependent heartbeat.
    assert {:ok, sup_pid} =
             Lifecycle.start(agent_id,
               start_session: false,
               recover_session: false,
               task_store: store
             )

    assert is_pid(sup_pid)
    assert Process.alive?(sup_pid)

    children = Supervisor.which_children(sup_pid)
    child_ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

    pids = BranchSupervisor.child_pids(agent_id)
    assert is_pid(pids.host)
    assert is_pid(pids.executor)
    assert is_nil(pids.session)
    refute :session in child_ids
    refute :heartbeat_service in child_ids

    # No session/heartbeat restart slots — only host/executor branch is live.
    bootstrap_purposes =
      agent_id
      |> principal_bootstraps()
      |> Enum.map(& &1.purpose)
      |> Enum.sort()

    refute :session in bootstrap_purposes
    refute :heartbeat in bootstrap_purposes

    assert :ok = Lifecycle.stop(agent_id)
  end

  test "security regression: exact branch admission failure suspends identity and revokes grants",
       %{store: store} do
    if Process.whereis(Arbor.Agent.UserSupervisor) == nil,
      do: start_supervised!(Arbor.Agent.UserSupervisor)

    previous_quota = Application.fetch_env(:arbor_agent, :max_agents_per_user)

    previous_cleanup_principal =
      Application.fetch_env(:arbor_agent, :activation_failure_principal_id)

    {:ok, cleanup_identity} = Arbor.Security.generate_identity()
    :ok = Arbor.Security.register_identity_fixture(cleanup_identity)

    :ok =
      Arbor.Security.store_signing_key_fixture(
        cleanup_identity.agent_id,
        cleanup_identity.private_key
      )

    for resource <- [
          "arbor://security/identity/suspend/**",
          "arbor://security/revoke/**"
        ] do
      assert {:ok, _} =
               Arbor.Security.grant_fixture(
                 principal: cleanup_identity.agent_id,
                 resource: resource
               )
    end

    Application.put_env(:arbor_agent, :max_agents_per_user, 0)

    Application.put_env(
      :arbor_agent,
      :activation_failure_principal_id,
      cleanup_identity.agent_id
    )

    on_exit(fn ->
      case previous_cleanup_principal do
        {:ok, value} -> Application.put_env(:arbor_agent, :activation_failure_principal_id, value)
        :error -> Application.delete_env(:arbor_agent, :activation_failure_principal_id)
      end

      case previous_quota do
        {:ok, value} -> Application.put_env(:arbor_agent, :max_agents_per_user, value)
        :error -> Application.delete_env(:arbor_agent, :max_agents_per_user)
      end

      _ = Arbor.Security.revoke_all_fixture(cleanup_identity.agent_id)
      _ = Arbor.Security.delete_signing_key_fixture(cleanup_identity.agent_id)
      _ = Arbor.Security.deregister_identity_fixture(cleanup_identity.agent_id)
    end)

    assert {:ok, profile} =
             create!("Exact failed branch probe",
               template: "pipeline_architect",
               repo_root: File.cwd!()
             )

    agent_id = profile.agent_id
    cleanup(agent_id)

    assert {:error, _reason} =
             Lifecycle.start(agent_id,
               principal_id: "human_exact_branch_failure",
               start_session: false,
               recover_session: false,
               task_store: store
             )

    assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
    assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
  end

  test "security regression: exact creation requires provisioned cleanup authority" do
    previous = Application.fetch_env(:arbor_agent, :activation_failure_principal_id)
    Application.delete_env(:arbor_agent, :activation_failure_principal_id)

    on_exit(fn ->
      case previous do
        {:ok, principal} ->
          Application.put_env(:arbor_agent, :activation_failure_principal_id, principal)

        :error ->
          Application.delete_env(:arbor_agent, :activation_failure_principal_id)
      end
    end)

    assert {:error, :activation_failure_authority_unavailable} =
             create!("Exact cleanup preflight probe",
               template: "pipeline_architect",
               repo_root: File.cwd!()
             )
  end

  # arbor_agent does not depend on arbor_orchestrator (both L7); per-app,
  # BranchSupervisor skips the Session child by design. Runs from the root.
  @tag skip:
         if(Code.ensure_loaded?(Arbor.Orchestrator.Session),
           do: false,
           else: "needs arbor_orchestrator loaded — run from the umbrella root"
         )
  test "start_session: true with start_heartbeat: false still starts Session only", %{
    store: store
  } do
    assert {:ok, profile} = create!("Start Heartbeat False Probe", template: "test_agent")

    agent_id = profile.agent_id
    cleanup(agent_id)

    assert {:ok, sup_pid} =
             Lifecycle.start(agent_id,
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

  defp principal_bootstraps(agent_id) do
    case Process.whereis(SigningAuthorityBroker) do
      pid when is_pid(pid) ->
        SigningAuthorityBroker.debug_state().bootstrap_entries
        |> Enum.filter(&(&1.principal_id == agent_id))

      _ ->
        []
    end
  end

  defp start_security_child(child) do
    case Supervisor.start_child(Arbor.Security.Supervisor, child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, _} -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp create!(name, opts \\ []) do
    Lifecycle.create(
      name,
      Keyword.put(opts, :actor_authority, Process.get(:agent_test_actor_authority))
    )
  end

  defp cleanup(agent_id) do
    on_exit(fn ->
      try do
        Lifecycle.destroy(agent_id)
      catch
        _, _ -> :ok
      end
    end)
  end
end
