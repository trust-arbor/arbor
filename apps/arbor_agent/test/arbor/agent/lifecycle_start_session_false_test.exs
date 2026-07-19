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
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.{BranchSupervisor, Lifecycle}
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Trust.Store, as: TrustStore

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

    # Trust Store is required by Lifecycle.create for template trust presets.
    start_supervised!(%{
      id: :lifecycle_start_session_false_trust_sup,
      start:
        {Supervisor, :start_link,
         [
           [
             {TrustStore, []},
             {Arbor.Trust.Manager, [circuit_breaker: false, decay: false, event_store: false]}
           ],
           [strategy: :one_for_one]
         ]},
      type: :supervisor
    })

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

  test "start_session: false starts host/executor without Session or HeartbeatService" do
    assert {:ok, profile} =
             Lifecycle.create("Start Session False Probe", template: "test_agent")

    agent_id = profile.agent_id
    cleanup(agent_id)

    assert principal_bootstraps(agent_id) == []

    # Intentionally omit start_heartbeat (defaults true) to prove start_session:false
    # alone is authoritative for suppressing the session-dependent heartbeat.
    assert {:ok, sup_pid} =
             Lifecycle.start(agent_id, start_session: false, recover_session: false)

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

  test "start_session: true with start_heartbeat: false still starts Session only" do
    assert {:ok, profile} =
             Lifecycle.create("Start Heartbeat False Probe", template: "test_agent")

    agent_id = profile.agent_id
    cleanup(agent_id)

    assert {:ok, sup_pid} =
             Lifecycle.start(agent_id, start_heartbeat: false, recover_session: false)

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
