defmodule Arbor.Security.CallerHeldLifecycleAuthoritySecurityRegressionTest do
  @moduledoc """
  `verify_request_and_open_agent_lifecycle_authority/2` for a human whose key
  the server does not hold (the local operator from `mix arbor.user.init`).

  It used to refuse such a human with `:no_signing_key`, so no lifecycle
  operation could ever run as the local operator. It now opens a caller-held
  authority from the same verified request: owner-bound, accepted as the actor
  of security mutations, unable to sign. Everything else about the request is
  checked exactly as before.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security

  @payload "arbor.test.lifecycle.v1\nstart conversationalist as river"

  setup do
    previous_flag =
      Application.get_env(:arbor_capabilities, :allow_local_human_identity, :__absent__)

    previous_oidc = Application.get_env(:arbor_capabilities, :oidc, :__absent__)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)
    Application.delete_env(:arbor_capabilities, :oidc)
    assert {:ok, _revoked} = Security.reopen_local_genesis_fixture()

    on_exit(fn ->
      restore_env(:allow_local_human_identity, previous_flag)
      restore_env(:oidc, previous_oidc)
      _ = Security.reopen_local_genesis_fixture()
    end)

    :ok
  end

  test "security regression: a caller-held human gets an owner-bound authority that cannot sign" do
    operator = registered_operator("owner")
    grantee = registered_agent()

    assert {:ok, principal, authority} = open(operator, sign(operator, @payload))
    assert principal == operator.principal
    assert {:ok, ^principal} = Security.signing_authority_principal(authority)

    assert {:error, :caller_held_authority} =
             Security.sign_with_authority(authority, "arbor://fs/read/x")

    assert {:error, :no_signing_key} = Security.signing_key_status(operator.principal)

    # Genesis makes the operator an administrator; the authority then acts for it.
    assert {:ok, _cap} = Security.complete_local_genesis(genesis_proof(operator))

    assert {:ok, granted} =
             Security.grant(
               principal: grantee.agent_id,
               resource: "arbor://fs/read/caller-held",
               actor_authority: authority
             )

    assert granted.principal_id == grantee.agent_id

    # Owner-bound: another process holding a copy cannot use it.
    assert {:error, _} =
             Task.async(fn ->
               Security.grant(
                 principal: grantee.agent_id,
                 resource: "arbor://fs/read/copied",
                 actor_authority: authority
               )
             end)
             |> Task.await()

    assert :ok = Security.close_signing_authority(authority)

    assert {:error, _} =
             Security.grant(
               principal: grantee.agent_id,
               resource: "arbor://fs/read/after-close",
               actor_authority: authority
             )
  end

  test "security regression: a request for another payload or purpose opens nothing" do
    operator = registered_operator("purpose")
    {:ok, genesis} = Security.local_genesis_request_payload(operator.principal)

    for payload <- [@payload <> "x", genesis, "POST\n/api/chat/agents\n{}"] do
      assert {:error, :payload_mismatch} = open(operator, sign(operator, payload))
    end
  end

  test "security regression: a replayed, stale or foreign-key request opens nothing" do
    operator = registered_operator("replay")
    attacker = local_operator("attacker")

    stale = resign(%{sign(operator, @payload) | timestamp: ago(3_600)}, operator.private_key)
    assert {:error, :expired_timestamp} = open(operator, stale)

    {:ok, forged} = SignedRequest.sign(@payload, operator.principal, attacker.private_key)
    assert {:error, :invalid_signature} = open(operator, forged)

    once = sign(operator, @payload)
    assert {:ok, _principal, authority} = open(operator, once)
    :ok = Security.close_signing_authority(authority)
    assert {:error, :replayed_nonce} = open(operator, once)
  end

  test "security regression: an unregistered, non-human or gated-off principal opens nothing" do
    unregistered = local_operator("unregistered")
    assert {:error, :identity_not_found} = open(unregistered, sign(unregistered, @payload))

    agent = registered_agent()
    {:ok, by_agent} = SignedRequest.sign(@payload, agent.agent_id, agent.private_key)
    assert {:error, :human_principal_required} = open(agent, by_agent)

    operator = registered_operator("gated")
    signed = sign(operator, @payload)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, false)
    assert {:error, :identity_not_found} = open(operator, signed)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)

    # Refused before verification, so the nonce was not consumed.
    assert {:ok, _principal, authority} = open(operator, signed)
    :ok = Security.close_signing_authority(authority)
  end

  test "security regression: a server-held key keeps its signing authority, and a bad one is refused" do
    keyed = registered_operator("keyed")
    assert :ok = Security.store_signing_key_fixture(keyed.principal, keyed.private_key)
    on_exit(fn -> Security.delete_signing_key_fixture(keyed.principal) end)

    assert {:ok, _principal, authority} = open(keyed, sign(keyed, @payload))
    assert {:ok, %SignedRequest{}} = Security.sign_with_authority(authority, "arbor://fs/read/x")
    :ok = Security.close_signing_authority(authority)

    # A present but wrong key is not silently downgraded to caller-held.
    wrong = registered_operator("wrong-key")
    {_public, other_private} = :crypto.generate_key(:eddsa, :ed25519)
    assert :ok = Security.store_signing_key_fixture(wrong.principal, other_private)
    on_exit(fn -> Security.delete_signing_key_fixture(wrong.principal) end)

    assert {:error, :signing_key_mismatch} = open(wrong, sign(wrong, @payload))
  end

  # -- helpers ---------------------------------------------------------------

  defp open(_who, signed),
    do: Security.verify_request_and_open_agent_lifecycle_authority(signed, @payload)

  defp sign(%{principal: principal, private_key: private_key}, payload) do
    {:ok, signed} = SignedRequest.sign(payload, principal, private_key)
    signed
  end

  defp resign(%SignedRequest{} = request, private_key) do
    message = SignedRequest.signing_payload(request)
    %{request | signature: :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)

  defp genesis_proof(operator) do
    {:ok, payload} = Security.local_genesis_request_payload(operator.principal)
    sign(operator, payload)
  end

  defp local_operator(tag) do
    opts = [user: "caller-held-life-#{tag}-#{System.unique_integer([:positive])}", host: "t.test"]
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      opts: opts,
      principal: Security.local_human_principal_id(opts),
      public_key: public_key,
      private_key: private_key
    }
  end

  # Registered the way `mix arbor.user.init` registers it: only the public key.
  defp registered_operator(tag) do
    operator = local_operator(tag)

    {:ok, payload} =
      Security.local_human_registration_request_payload(operator.principal, operator.public_key)

    assert {:ok, _identity, :created} =
             Security.register_local_human_identity(
               operator.public_key,
               sign(operator, payload),
               operator.opts
             )

    operator
  end

  defp registered_agent do
    {:ok, identity} = Identity.generate(name: "caller-held grantee")
    assert :ok = Security.register_identity_fixture(identity)
    Map.put(identity, :principal, identity.agent_id)
  end

  defp restore_env(key, :__absent__), do: Application.delete_env(:arbor_capabilities, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_capabilities, key, value)
end
