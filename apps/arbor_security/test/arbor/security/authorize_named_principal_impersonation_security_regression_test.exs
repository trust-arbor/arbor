defmodule Arbor.Security.AuthorizeNamedPrincipalImpersonationSecurityRegressionTest do
  @moduledoc """
  Security regression: merely naming a principal whose key sits in
  SigningKeyStore is not proof of that principal.

  The rejected `authorize_as_stored_principal/4` design loaded the named
  principal's stored private key and signed on its behalf. This test stores
  the victim's key, grants `arbor://identity/alias/manage`, then calls
  `authorize/4` with `verify_identity: true` and no caller-produced
  SignedRequest. A server-signs-for-you implementation would return
  `{:ok, :authorized}`.
  """

  use ExUnit.Case, async: false

  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression

  @manage_resource "arbor://identity/alias/manage"

  test "security regression: naming a stored-key principal cannot exercise its capability" do
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity(identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    {:ok, cap} =
      Security.grant(
        principal: identity.agent_id,
        resource: @manage_resource
      )

    result =
      try do
        Security.authorize(identity.agent_id, @manage_resource, :write, verify_identity: true)
      after
        _ = Security.revoke(cap.id)
        _ = Security.delete_signing_key(identity.agent_id)
        _ = Security.deregister_identity(identity.agent_id)
      end

    assert {:error, :missing_signed_request} = result,
           "authorize/4 must not sign for a caller-named stored principal. Got: #{inspect(result)}"
  end

  test "security regression: a caller-produced SignedRequest still authorizes the stored-key principal" do
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity(identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    {:ok, cap} =
      Security.grant(
        principal: identity.agent_id,
        resource: @manage_resource
      )

    {:ok, signed} =
      Arbor.Contracts.Security.SignedRequest.sign(
        @manage_resource,
        identity.agent_id,
        identity.private_key
      )

    result =
      try do
        Security.authorize(identity.agent_id, @manage_resource, :write,
          signed_request: signed,
          expected_resource: @manage_resource,
          verify_identity: true
        )
      after
        _ = Security.revoke(cap.id)
        _ = Security.delete_signing_key(identity.agent_id)
        _ = Security.deregister_identity(identity.agent_id)
      end

    assert {:ok, :authorized} = result
  end
end
