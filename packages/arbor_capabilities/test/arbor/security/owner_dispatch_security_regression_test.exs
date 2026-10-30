defmodule Arbor.Security.OwnerDispatchSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-001,SSEC-004"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.IssuerRegistry

  @tag spec: "SSEC-001,SSEC-004"
  test "security regression: a CapabilityStore name squatter cannot forge authorization or grants" do
    {:ok, actor} = Identity.generate(name: "store-dispatch-actor")
    {:ok, target} = Identity.generate(name: "store-dispatch-target")
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)

    protected_resource = "arbor://fs/read/store-dispatch"
    mutation_resource = "arbor://security/grant/#{target.agent_id}"

    {:ok, stale_authorizing} =
      Security.grant_fixture(principal: target.agent_id, resource: protected_resource)

    {:ok, stale_mutation} =
      Security.grant_fixture(principal: actor.agent_id, resource: mutation_resource)

    :ok = Security.revoke_fixture(stale_authorizing.id)
    :ok = Security.revoke_fixture(stale_mutation.id)
    {:ok, authority} = open_authority(actor)

    on_exit(fn ->
      Security.close_signing_authority(authority)
      Security.deregister_identity_fixture(actor.agent_id)
      Security.deregister_identity_fixture(target.agent_id)
    end)

    forged_resource = "arbor://fs/read/store-dispatch-forged"

    with_name_squatter(
      CapabilityStore,
      fn
        {:find_authorizing, _principal, _resource} -> {:ok, stale_authorizing}
        {:list_for_principal, _principal, _opts} -> {:ok, [stale_mutation]}
        _request -> {:ok, stale_authorizing}
      end,
      fn ->
        assert {:error, _reason} =
                 Security.authorize(target.agent_id, protected_resource, nil,
                   verify_identity: false
                 )

        assert {:error, _reason} =
                 Security.grant(
                   principal: target.agent_id,
                   resource: forged_resource,
                   actor_authority: authority
                 )

        refute_receive {:owner_dispatch_squatter_called, CapabilityStore, _request}, 50
      end
    )

    assert {:error, :not_found} =
             CapabilityStore.find_authorizing(target.agent_id, forged_resource)
  end

  test "security regression: identity and issuer lookups ignore registered-name squatters" do
    unknown_identity = "agent_" <> String.duplicate("9", 64)
    unknown_issuer = "agent_" <> String.duplicate("8", 64)

    with_name_squatter(
      Registry,
      fn _request -> {:ok, <<7::256>>} end,
      fn ->
        assert {:error, :not_found} = Security.lookup_public_key(unknown_identity)
        refute_receive {:owner_dispatch_squatter_called, Registry, _request}, 50
      end
    )

    with_name_squatter(
      IssuerRegistry,
      fn _request -> {:ok, %{public_key: <<6::256>>, max_envelope_caps: []}} end,
      fn ->
        assert {:error, :not_found} = IssuerRegistry.lookup(unknown_issuer)
        refute_receive {:owner_dispatch_squatter_called, IssuerRegistry, _request}, 50
      end
    )
  end

  defp open_authority(identity) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :owner_dispatch_security_regression
           ) do
      Security.open_ephemeral_signing_authority(proof, identity.private_key)
    end
  end

  defp with_name_squatter(name, reply, assertion) do
    original = Process.whereis(name)
    assert is_pid(original)
    assert Process.unregister(name)
    parent = self()

    squatter =
      spawn(fn ->
        true = Process.register(self(), name)
        send(parent, {:owner_dispatch_squatter_ready, name, self()})
        squatter_loop(parent, name, reply)
      end)

    assert_receive {:owner_dispatch_squatter_ready, ^name, ^squatter}

    try do
      assertion.()
    after
      if Process.whereis(name) == squatter, do: Process.unregister(name)
      if Process.alive?(squatter), do: Process.exit(squatter, :kill)
      if Process.alive?(original), do: Process.register(original, name)
    end
  end

  defp squatter_loop(parent, name, reply) do
    receive do
      {:"$gen_call", {from, tag}, request} ->
        send(parent, {:owner_dispatch_squatter_called, name, request})
        send(from, {tag, reply.(request)})
        squatter_loop(parent, name, reply)

      _message ->
        squatter_loop(parent, name, reply)
    end
  end
end
