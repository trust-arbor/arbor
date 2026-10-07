defmodule Arbor.Security.FacadeIdIssuanceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry

  setup do
    {:ok, identity} = Identity.generate(name: "facade-id-issuance")
    :ok = Registry.register_fixture(identity)

    {:ok, mutation_cap} =
      Security.grant_fixture(
        principal: identity.agent_id,
        resource: "arbor://security/grant/#{identity.agent_id}"
      )

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :facade_id_issuance_test
      )

    {:ok, actor_authority} =
      Security.open_ephemeral_signing_authority(proof, identity.private_key)

    on_exit(fn ->
      Security.close_signing_authority(actor_authority)
      Security.revoke_fixture(mutation_cap.id)
      Security.deregister_identity_fixture(identity.agent_id)
    end)

    {:ok, agent_id: identity.agent_id, actor_authority: actor_authority}
  end

  test "ordinary grant id wrapper retains the capability inside Security", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    assert {:ok, capability_id} =
             Security.grant_capability_id(
               principal: agent_id,
               resource: "arbor://fs/read/facade-id",
               actor_authority: actor_authority
             )

    on_exit(fn -> Security.revoke_fixture(capability_id) end)

    assert "cap_" <> _ = capability_id
    assert {:ok, capability} = CapabilityStore.get(capability_id)
    assert capability.id == capability_id
  end

  test "disclosure issuance id wrapper retains the capability inside Security", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    assert {:ok, capability_id} =
             Security.issue_disclosure_capability_id(
               principal_id: agent_id,
               session_id: "session_facade_id",
               task_id: "turn_facade_id",
               principal_scope: "human_facade_id",
               destination: "api.x.ai",
               provider: "xai",
               runtime: "arbor",
               model: "grok-voice-latest",
               actor_authority: actor_authority
             )

    on_exit(fn -> Security.revoke_fixture(capability_id) end)

    assert "cap_" <> _ = capability_id
    assert {:ok, capability} = CapabilityStore.get(capability_id)
    assert capability.id == capability_id
  end
end
