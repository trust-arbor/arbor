defmodule Arbor.Commands.Test.SessionLifecycleHelpers do
  @moduledoc """
  Shared setup for Session-starting Lifecycle tests that cannot live in
  `arbor_agent` (both apps are L7; Mix prunes undeclared sibling paths).
  """

  alias Arbor.Persistence.BufferedStore

  @profiles_store :arbor_agent_profiles

  @agent_support Path.expand("../../../arbor_agent/test/support", __DIR__)

  def require_agent_test_support! do
    for name <- ["trust_topology.ex", "runtime_admission_topology.ex"] do
      Code.require_file(Path.join(@agent_support, name))
    end

    :ok
  end

  def setup_security_flags! do
    prev =
      for key <- [:capability_signing_required, :strict_identity_mode, :identity_verification] do
        {key, Application.get_env(:arbor_security, key)}
      end

    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :identity_verification, false)

    prev
  end

  def restore_security_flags!(prev) do
    for {key, value} <- prev do
      if is_nil(value),
        do: Application.delete_env(:arbor_security, key),
        else: Application.put_env(:arbor_security, key, value)
    end
  end

  def start_runtime! do
    {:ok, _} = Application.ensure_all_started(:arbor_agent)
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)
    :ok = Arbor.Security.TestBootstrap.start!()
    :ok = Arbor.Historian.TestAuditRuntime.start_default_lane!()
    Arbor.Memory.TestBootstrap.start!()
    Arbor.Agent.Test.TrustTopology.ensure_owned!()
    start_security_topology()
    start_agent_children()
    start_profiles_store()
    provision_lifecycle_service_principals!()
    Arbor.Agent.Test.RuntimeAdmissionTopology.start_fixed_production!()
    :ok
  end

  def provision_lifecycle_service_principals! do
    unless Application.get_env(:arbor_agent, :activation_failure_principal_id) do
      {:ok, cleanup_identity} = Arbor.Security.generate_identity()
      :ok = Arbor.Security.register_identity_fixture(cleanup_identity)

      :ok =
        Arbor.Security.store_signing_key_fixture(
          cleanup_identity.agent_id,
          cleanup_identity.private_key
        )

      for resource <- ["arbor://security/identity/suspend/**", "arbor://security/revoke/**"] do
        {:ok, _} =
          Arbor.Security.grant_fixture(principal: cleanup_identity.agent_id, resource: resource)
      end

      Application.put_env(
        :arbor_agent,
        :activation_failure_principal_id,
        cleanup_identity.agent_id
      )
    end

    unless Application.get_env(:arbor_agent, :lease_grant_principal_id) do
      {:ok, lease_grant_identity} = Arbor.Security.generate_identity()
      :ok = Arbor.Security.register_identity_fixture(lease_grant_identity)

      :ok =
        Arbor.Security.store_signing_key_fixture(
          lease_grant_identity.agent_id,
          lease_grant_identity.private_key
        )

      for resource <- ["arbor://security/grant/**", "arbor://security/revoke/**"] do
        {:ok, _} =
          Arbor.Security.grant_fixture(
            principal: lease_grant_identity.agent_id,
            resource: resource
          )
      end

      Application.put_env(:arbor_agent, :lease_grant_principal_id, lease_grant_identity.agent_id)
    end

    :ok
  end

  def start_security_topology do
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
  end

  def start_agent_children do
    for child <- [
          {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
          Arbor.Agent.ProfileAuthorityOwner,
          Arbor.Agent.Orchestration.LeaseGrantOwner,
          Arbor.Agent.Registry,
          Arbor.Agent.SessionManager,
          Arbor.Agent.Supervisor
        ] do
      start_agent_child(child)
    end
  end

  def start_profiles_store do
    if Process.whereis(@profiles_store) == nil do
      start_agent_child(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles_store, backend: nil, write_mode: :sync},
          id: @profiles_store
        )
      )
    end
  end

  def create_agent(actor, name, opts) do
    Arbor.Agent.Lifecycle.create(name, Keyword.put(opts, :actor_authority, actor.authority))
  end

  def cleanup(agent_id, actor) do
    ExUnit.Callbacks.on_exit(fn -> Arbor.Agent.destroy_agent_fixture(agent_id, actor) end)
  end

  def umbrella_root_from(path) do
    expanded = Path.expand(path)

    cond do
      File.exists?(Path.join(expanded, "mix.exs")) and File.dir?(Path.join(expanded, "apps")) ->
        expanded

      Path.dirname(expanded) == expanded ->
        raise "could not locate umbrella root from #{path}"

      true ->
        umbrella_root_from(Path.dirname(expanded))
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

  defp start_agent_child(child) do
    case Supervisor.start_child(Arbor.Agent.AppSupervisor, child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      other -> other
    end
  end
end
