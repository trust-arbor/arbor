defmodule Arbor.Security.AuthorityStoreMutationAuthenticationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-001,SSEC-004"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
  alias Arbor.Security.{AuthorityStore, CapabilityStore, IssuerRegistry}
  alias Arbor.Security.Identity.Registry

  @stores [
    {:arbor_security_capabilities, CapabilityStore},
    {:arbor_security_identities, Registry},
    {:arbor_security_issuers, IssuerRegistry},
    {:arbor_security_signing_keys, Arbor.Security.SigningKeyStore.Owner}
  ]

  @tag spec: "SSEC-001,SSEC-004"
  test "security regression: low-level and raw forged store mutations are denied" do
    Enum.each(@stores, fn {store_name, mutation_owner} ->
      key = "raw_store_mutation_#{store_name}_#{System.unique_integer([:positive])}"
      record = Record.new(key, %{"forged" => true})
      store = Process.whereis(store_name)
      owner = Process.whereis(mutation_owner)

      assert is_pid(store)
      assert is_pid(owner)

      assert {:error, :store_mutation_unauthorized} =
               AuthorityStore.acknowledged_put(key, record, name: store_name)

      assert {:error, :store_mutation_unauthorized} =
               forged_call(store, owner, {:acknowledged_put, key, record})

      assert {:error, :not_found} = AuthorityStore.authoritative_get(key, name: store_name)
    end)
  end

  test "security regression: supervised capability, identity and issuer facades still persist" do
    {:ok, identity} = Identity.generate(name: "authority-store-owner-positive")
    :ok = Registry.register_fixture(identity)

    on_exit(fn ->
      _ = IssuerRegistry.revoke_fixture(identity.agent_id, "security regression cleanup")
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    {:ok, envelope} =
      Capability.new(
        principal_id: identity.agent_id,
        resource_uri: "arbor://fs/read/authority-store-owner-positive/**"
      )

    assert :ok = IssuerRegistry.register_fixture(identity.agent_id, [envelope])

    assert {:ok, granted} =
             Security.grant_fixture(
               principal: identity.agent_id,
               resource: "arbor://fs/read/authority-store-owner-positive/file"
             )

    on_exit(fn -> Security.revoke_fixture(granted.id) end)

    assert {:ok, %Record{}} =
             AuthorityStore.authoritative_get(identity.agent_id,
               name: :arbor_security_identities
             )

    assert {:ok, %Record{}} =
             AuthorityStore.authoritative_get(identity.agent_id, name: :arbor_security_issuers)

    assert {:ok, %Record{}} =
             AuthorityStore.authoritative_get(granted.id, name: :arbor_security_capabilities)

    assert :ok = Security.revoke_fixture(granted.id)
    assert :ok = IssuerRegistry.revoke_fixture(identity.agent_id, "security regression cleanup")
    assert :ok = Security.deregister_identity_fixture(identity.agent_id)
  end

  defp forged_call(server, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged AuthorityStore call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end
end
