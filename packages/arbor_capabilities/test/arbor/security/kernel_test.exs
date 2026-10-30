defmodule Arbor.Security.KernelTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Kernel
  alias Arbor.Security.SystemAuthority

  setup do
    {:ok, identity} = Identity.generate(name: "kernel-test")
    :ok = Registry.register_fixture(identity)

    {:ok, _grant_cap} =
      Security.grant_fixture(
        principal: identity.agent_id,
        resource: "arbor://security/grant/#{identity.agent_id}"
      )

    {:ok, _revoke_cap} =
      Security.grant_fixture(
        principal: identity.agent_id,
        resource: "arbor://security/revoke/#{identity.agent_id}"
      )

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :kernel_test
      )

    {:ok, actor_authority} =
      Security.open_ephemeral_signing_authority(proof, identity.private_key)

    on_exit(fn ->
      Security.close_signing_authority(actor_authority)
      CapabilityStore.revoke_all_fixture(identity.agent_id)
      Security.deregister_identity_fixture(identity.agent_id)
    end)

    {:ok, agent_id: identity.agent_id, actor_authority: actor_authority}
  end

  describe "grant_capability/1" do
    test "grants capability with minimal options", ctx do
      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: ctx.agent_id,
          resource_uri: "arbor://fs/read/workspace",
          actor_authority: ctx.actor_authority
        )

      assert %Capability{} = cap
      assert cap.principal_id == ctx.agent_id
      assert cap.resource_uri == "arbor://fs/read/workspace"
    end

    test "grants capability with all options", ctx do
      expires = DateTime.add(DateTime.utc_now(), 3600)

      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: ctx.agent_id,
          resource_uri: "arbor://fs/write/data",
          actor_authority: ctx.actor_authority,
          constraints: %{rate_limit: 10},
          metadata: %{purpose: "testing"},
          expires_at: expires
        )

      assert cap.principal_id == ctx.agent_id
      assert cap.resource_uri == "arbor://fs/write/data"
      assert cap.constraints == %{rate_limit: 10}
      assert cap.metadata[:purpose] == "testing"
      assert cap.metadata["granter_id"] == ctx.agent_id
      assert cap.expires_at == expires
    end

    test "stores capability in CapabilityStore", ctx do
      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: ctx.agent_id,
          resource_uri: "arbor://fs/read/stored",
          actor_authority: ctx.actor_authority
        )

      assert {:ok, retrieved} = CapabilityStore.get(cap.id)
      assert retrieved.id == cap.id
      assert retrieved.principal_id == ctx.agent_id
    end

    test "fails closed on missing principal_id", ctx do
      assert {:error, :capability_mutation_unauthorized} =
               Kernel.grant_capability(
                 resource_uri: "arbor://fs/read/docs",
                 actor_authority: ctx.actor_authority
               )
    end

    test "fails closed on missing resource_uri", ctx do
      assert {:error, :capability_mutation_unauthorized} =
               Kernel.grant_capability(
                 principal_id: ctx.agent_id,
                 actor_authority: ctx.actor_authority
               )
    end

    test "security regression (H15): produces a SystemAuthority-signed capability that verifies",
         ctx do
      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: ctx.agent_id,
          resource_uri: "arbor://fs/read/h15_signed",
          actor_authority: ctx.actor_authority
        )

      assert Capability.signed?(cap),
             "Granted capability missing issuer signature — H15 regression: " <>
               "Kernel.grant_capability bypassed SystemAuthority.sign_capability"

      assert :ok == SystemAuthority.verify_capability_signature(cap),
             "Granted capability signature does not verify — H15 regression"

      # The store must hold the signed form, not the unsigned original
      {:ok, stored} = CapabilityStore.get(cap.id)

      assert Capability.signed?(stored),
             "CapabilityStore holds unsigned capability — H15 regression"
    end
  end

  describe "revoke_capability/1" do
    test "revokes an existing capability", ctx do
      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: ctx.agent_id,
          resource_uri: "arbor://fs/read/revokable",
          actor_authority: ctx.actor_authority
        )

      assert {:ok, _} = CapabilityStore.get(cap.id)

      assert :ok =
               Kernel.revoke_capability(
                 capability_id: cap.id,
                 actor_authority: ctx.actor_authority
               )

      assert {:error, :not_found} = CapabilityStore.get(cap.id)
    end

    test "returns error for non-existent capability", ctx do
      assert {:error, :not_found} =
               Kernel.revoke_capability(
                 capability_id: "cap_nonexistent_#{:erlang.unique_integer([:positive])}",
                 actor_authority: ctx.actor_authority
               )
    end

    test "fails closed on missing capability_id", ctx do
      assert {:error, :capability_mutation_unauthorized} =
               Kernel.revoke_capability(actor_authority: ctx.actor_authority)
    end
  end
end
