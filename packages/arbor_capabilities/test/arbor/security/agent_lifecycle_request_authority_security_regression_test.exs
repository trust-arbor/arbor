defmodule Arbor.Security.AgentLifecycleRequestAuthoritySecurityRegressionTest do
  @moduledoc """
  Decision 2026-10-08 D2: `verify_request_and_open_agent_lifecycle_authority/2`
  verifies one inbound signed request and opens the signer's `:agent_lifecycle`
  authority in the same broker step, because verification consumes the
  request's single-use nonce.

  Every test goes through the public facade. The "operation" an opened
  authority performs is a security mutation (a capability grant) that only an
  authority owned by the calling process and held by an authorized principal
  may perform.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.OIDCTestHelper

  @payload "POST\n/api/chat/agents/agent_probe/start\n{}"

  setup do
    human = registered_human_with_key!()
    grantee = registered_agent!("lifecycle-request-grantee")

    assert {:ok, cap} =
             Security.grant_fixture(principal: human.agent_id, resource: grant_resource(grantee))

    on_exit(fn -> Security.revoke_fixture(cap.id) end)
    %{human: human, grantee: grantee}
  end

  test "a valid human request opens a caller-bound authority that performs the operation until closed",
       %{human: human, grantee: grantee} do
    request = sign!(human, @payload)

    assert {:ok, principal_id, authority} =
             Security.verify_request_and_open_agent_lifecycle_authority(request, @payload)

    assert principal_id == human.agent_id
    assert authority.principal_id == human.agent_id
    assert authority.purpose == :agent_lifecycle
    assert {:ok, ^principal_id} = Security.signing_authority_principal(authority)

    # Bound to the opening process: another process can neither see nor use it.
    other =
      Task.async(fn ->
        {Security.signing_authority_principal(authority), grant(grantee, authority)}
      end)

    assert {{:error, _}, {:error, _}} = Task.await(other)

    # The owner can perform the security mutation the authority was opened for.
    assert {:ok, capability} = grant(grantee, authority)
    assert capability.principal_id == grantee.agent_id

    assert :ok = Security.close_signing_authority(authority)
    assert {:error, _} = Security.signing_authority_principal(authority)
    assert {:error, _} = grant(grantee, authority)
  end

  test "security regression: a replayed request, or one already verified elsewhere, opens nothing",
       %{human: human} do
    request = sign!(human, @payload)

    assert {:ok, _principal, authority} =
             Security.verify_request_and_open_agent_lifecycle_authority(request, @payload)

    on_exit(fn -> Security.close_signing_authority(authority) end)

    assert {:error, :replayed_nonce} =
             Security.verify_request_and_open_agent_lifecycle_authority(request, @payload)

    # Verify-then-open is a replay: the authority can only come from the same step.
    verified = sign!(human, @payload)
    assert {:ok, _} = Security.verify_request(verified)

    assert {:error, :replayed_nonce} =
             Security.verify_request_and_open_agent_lifecycle_authority(verified, @payload)
  end

  test "security regression: a bad signature opens nothing", %{human: human} do
    other_human = registered_human_with_key!()
    request = sign!(human, @payload)
    <<first, rest::binary>> = request.signature

    for forged <- [
          %{request | signature: <<Bitwise.bxor(first, 1), rest::binary>>},
          # The same signature claimed by another human with a server-held key.
          %{request | agent_id: other_human.agent_id},
          # Signed by one human, presented with another human's claim.
          %{sign!(other_human, @payload) | agent_id: human.agent_id}
        ] do
      assert {:error, :invalid_signature} =
               Security.verify_request_and_open_agent_lifecycle_authority(forged, @payload)
    end
  end

  test "security regression: a request signed for a different operation opens nothing and keeps its nonce",
       %{human: human} do
    request = sign!(human, "POST\n/api/chat/agents/agent_other/start\n{}")

    for expected <- [
          @payload,
          "POST\n/api/chat/agents/agent_other/stop\n{}",
          "POST\n/api/chat/agents/agent_other/start\n{\"changed\":true}"
        ] do
      assert {:error, :payload_mismatch} =
               Security.verify_request_and_open_agent_lifecycle_authority(request, expected)
    end

    # Refused before verification: the request was not consumed by the refusals.
    assert {:ok, _} = Security.verify_request(request)
  end

  test "security regression: a non-human signer is refused before its nonce is consumed" do
    agent = registered_agent!("lifecycle-request-agent")
    assert :ok = Security.store_signing_key_fixture(agent.agent_id, agent.private_key)
    on_exit(fn -> Security.delete_signing_key_fixture(agent.agent_id) end)
    request = sign!(agent, @payload)

    assert {:error, :human_principal_required} =
             Security.verify_request_and_open_agent_lifecycle_authority(request, @payload)

    assert {:ok, agent_id} = Security.verify_request(request)
    assert agent_id == agent.agent_id
  end

  test "security regression: suspended, revoked, unknown or keyless humans open nothing" do
    suspended = registered_human_with_key!()
    assert :ok = Security.suspend_identity_fixture(suspended.agent_id, "lifecycle probe")
    request = sign!(suspended, @payload)

    assert {:error, :identity_suspended} =
             Security.verify_request_and_open_agent_lifecycle_authority(request, @payload)

    revoked = registered_human_with_key!()
    assert :ok = Security.revoke_identity_fixture(revoked.agent_id, "lifecycle probe")

    assert {:error, :identity_revoked} =
             Security.verify_request_and_open_agent_lifecycle_authority(
               sign!(revoked, @payload),
               @payload
             )

    {:ok, unknown} = Identity.generate(name: "unregistered human")
    unknown = %{unknown | agent_id: "human_" <> String.duplicate("a", 40)}

    assert {:error, :identity_not_found} =
             Security.verify_request_and_open_agent_lifecycle_authority(
               sign!(unknown, @payload),
               @payload
             )

    keyless = registered_human!()

    assert {:error, _no_key} =
             Security.verify_request_and_open_agent_lifecycle_authority(
               sign!(keyless, @payload),
               @payload
             )
  end

  test "security regression: malformed proofs and payloads are refused", %{human: human} do
    request = sign!(human, @payload)

    for {proof, expected} <- [
          {%{request | agent_id: nil}, @payload},
          {request, ""},
          {request, nil},
          {:not_a_request, @payload}
        ] do
      assert {:error, _} =
               Security.verify_request_and_open_agent_lifecycle_authority(proof, expected)
    end

    assert {:ok, _} = Security.verify_request(request)
  end

  defp grant(grantee, authority) do
    Security.grant(
      principal: grantee.agent_id,
      resource: "arbor://fs/read/lifecycle-request-proof",
      actor_authority: authority
    )
  end

  defp grant_resource(grantee), do: "arbor://security/grant/" <> grantee.agent_id

  defp sign!(%{agent_id: agent_id, private_key: private_key}, payload) do
    {:ok, request} = SignedRequest.sign(payload, agent_id, private_key)
    request
  end

  defp registered_human! do
    oidc = OIDCTestHelper.issue_identity()
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.deregister_identity_fixture(oidc.identity.agent_id)
    end)

    oidc.identity
  end

  defp registered_human_with_key! do
    human = registered_human!()
    assert :ok = Security.store_signing_key_fixture(human.agent_id, human.private_key)
    on_exit(fn -> Security.delete_signing_key_fixture(human.agent_id) end)
    human
  end

  defp registered_agent!(name) do
    {:ok, identity} = Identity.generate(name: name)
    assert :ok = Registry.register_fixture(identity)
    on_exit(fn -> Security.deregister_identity_fixture(identity.agent_id) end)
    identity
  end
end
