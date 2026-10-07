defmodule Arbor.Security.AuthorityStoreOwnerTakeoverSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-001,SSEC-011"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.SupervisedOwner
  alias Arbor.Security.TestBootstrap

  @supervisor Arbor.Security.Supervisor
  @identity_store :arbor_security_identities
  @issuer_store :arbor_security_issuers
  @capability_store :arbor_security_capabilities

  setup do
    Process.flag(:trap_exit, true)
    on_exit(&TestBootstrap.restore_supervised_tree!/0)
    :ok
  end

  @tag spec: "SSEC-001,SSEC-011"
  test "security regression: identity and issuer reads reject registered-name impostors" do
    {:ok, identity} = Identity.generate(name: "authority-store-owner-takeover")
    :ok = Registry.register_fixture(identity)
    registry_spec = supervised_child_spec!(Registry)
    registration_token = child_start_opt!(registry_spec, :system_authority_registration_token)

    {:ok, envelope} =
      Capability.new(
        resource_uri: "arbor://fs/read/authority-store-owner-takeover",
        principal_id: identity.agent_id
      )

    :ok = IssuerRegistry.register_fixture(identity.agent_id, envelope)

    {:ok, identity_record} =
      AuthorityStore.authoritative_get(identity.agent_id, name: @identity_store)

    {:ok, issuer_record} =
      AuthorityStore.authoritative_get(identity.agent_id, name: @issuer_store)

    try do
      with_name_takeover(@identity_store, {:ok, identity_record}, fn ->
        assert :ok = Supervisor.terminate_child(@supervisor, Registry)
        assert :ok = Supervisor.delete_child(@supervisor, Registry)

        probe_spec = Map.put(registry_spec, :restart, :temporary)
        {:ok, pid} = Supervisor.start_child(@supervisor, probe_spec)
        monitor = Process.monitor(pid)

        assert {:error, :registration_unavailable} =
                 Registry.complete_startup(security_supervisor_pid!(), registration_token)

        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000

        assert catch_exit(Security.lookup(identity.agent_id))
      end)

      restart_child_from_spec(@supervisor, registry_spec)
      assert :ok = Registry.complete_startup(security_supervisor_pid!(), registration_token)
      await_supervised_child(Registry, 300)

      with_name_takeover(@issuer_store, {:ok, issuer_record}, fn ->
        assert {:error, _reason} = Security.lookup_issuer(identity.agent_id)
      end)
    after
      :ok = TestBootstrap.restore_supervised_tree!()
      await_supervised_child(Registry, 300)
      await_supervised_child(IssuerRegistry, 300)
      _ = IssuerRegistry.revoke_fixture(identity.agent_id, "test cleanup")
      Security.deregister_identity_fixture(identity.agent_id)
    end
  end

  test "security regression: capability reads and hydration reject a store name impostor" do
    {:ok, actor} = Identity.generate(name: "authority-store-takeover-actor")
    {:ok, target} = Identity.generate(name: "authority-store-takeover-target")
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)

    {:ok, permission} =
      Security.grant_fixture(
        principal: actor.agent_id,
        resource: "arbor://security/revoke/#{target.agent_id}"
      )

    {:ok, capability} =
      Security.grant_fixture(
        principal: target.agent_id,
        resource: "arbor://fs/read/authority-store-takeover"
      )

    {:ok, record} =
      AuthorityStore.authoritative_get(capability.id, name: @capability_store)

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        actor.agent_id,
        actor.private_key,
        purpose: :authority_store_owner_takeover_security_regression
      )

    {:ok, authority} = Security.open_ephemeral_signing_authority(proof, actor.private_key)

    try do
      with_name_takeover(@capability_store, {:ok, record}, fn ->
        assert {:error, _reason} =
                 Security.revoke(capability.id, actor_authority: authority)

        assert :ok = Supervisor.terminate_child(@supervisor, CapabilityStore)

        {:ok, hydration_pid} = CapabilityStore.start_link(test_isolated_owner: true)
        monitor = Process.monitor(hydration_pid)

        assert_receive {:DOWN, ^monitor, :process, ^hydration_pid, _reason}, 2_000

        assert {:error, _reason} =
                 Security.authorize(
                   target.agent_id,
                   "arbor://fs/read/authority-store-takeover",
                   :read
                 )
      end)
    after
      Security.close_signing_authority(authority)
      Security.revoke_fixture(capability.id)
      Security.revoke_fixture(permission.id)
      Security.deregister_identity_fixture(target.agent_id)
      Security.deregister_identity_fixture(actor.agent_id)
    end
  end

  defp with_name_takeover(store_name, forged_reply, assertion) do
    {:ok, root} = SupervisedOwner.application_root(:arbor_security)
    real = SupervisedOwner.registered_child(store_name, :arbor_security, [store_name])
    assert is_pid(real)
    assert :ok = Supervisor.terminate_child(root, store_name)
    refute Process.alive?(real)

    parent = self()

    squatter =
      spawn(fn ->
        true = Process.register(self(), store_name)
        send(parent, {:store_squatter_ready, self()})
        squatter_loop(parent, forged_reply)
      end)

    assert_receive {:store_squatter_ready, ^squatter}

    try do
      assertion.()
      refute_receive {:store_squatter_called, _message}, 100
    after
      monitor = Process.monitor(squatter)
      if Process.whereis(store_name) == squatter, do: Process.unregister(store_name)
      if Process.alive?(squatter), do: Process.exit(squatter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^squatter, _reason}, 1_000
      restart_child(root, store_name)

      if store_name == @capability_store do
        restart_child(root, CapabilityStore)
      end
    end
  end

  defp squatter_loop(parent, forged_reply) do
    receive do
      {:"$gen_call", {from, tag}, message} ->
        send(parent, {:store_squatter_called, message})
        send(from, {tag, forged_reply})
        squatter_loop(parent, forged_reply)

      message ->
        send(parent, {:store_squatter_called, message})
        squatter_loop(parent, forged_reply)
    end
  end

  defp restart_child(root, child_id) do
    case Supervisor.restart_child(root, child_id) do
      {:ok, pid} when is_pid(pid) -> await_registered(child_id, pid, 200)
      {:ok, pid, _info} when is_pid(pid) -> await_registered(child_id, pid, 200)
      {:error, :running} -> :ok
      {:error, reason} -> flunk("failed to restart #{inspect(child_id)}: #{inspect(reason)}")
    end
  end

  defp restart_child_from_spec(root, spec) do
    case Supervisor.start_child(root, spec) do
      {:ok, pid} when is_pid(pid) ->
        await_registered(spec.id, pid, 200)

      {:ok, pid, _info} when is_pid(pid) ->
        await_registered(spec.id, pid, 200)

      {:error, {:already_started, pid}} when is_pid(pid) ->
        await_registered(spec.id, pid, 200)

      {:error, :already_present} ->
        assert :ok = Supervisor.delete_child(root, spec.id)
        restart_child_from_spec(root, spec)

      {:error, reason} ->
        flunk("failed to restore #{inspect(spec.id)}: #{inspect(reason)}")
    end
  end

  defp supervised_child_spec!(child_id) do
    case :supervisor.get_childspec(@supervisor, child_id) do
      {:ok, spec} -> spec
      {:error, reason} -> flunk("failed to read #{inspect(child_id)} spec: #{inspect(reason)}")
    end
  end

  defp child_start_opt!(%{start: {_module, :start_link, [opts]}}, key) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> flunk("missing #{inspect(key)} in supervised child spec")
    end
  end

  defp security_supervisor_pid! do
    case Process.whereis(@supervisor) do
      pid when is_pid(pid) -> pid
      nil -> flunk("Security supervisor is unavailable")
    end
  end

  defp await_registered(_name, _pid, 0), do: flunk("restarted child did not register")

  defp await_registered(name, pid, attempts) do
    if Process.whereis(name) == pid do
      :ok
    else
      Process.sleep(10)
      await_registered(name, pid, attempts - 1)
    end
  end

  defp await_supervised_child(_child_id, 0), do: flunk("supervised child did not recover")

  defp await_supervised_child(child_id, attempts) do
    case SupervisedOwner.registered_child(child_id, :arbor_security, [child_id]) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        Process.sleep(10)
        await_supervised_child(child_id, attempts - 1)
    end
  end
end
