defmodule Arbor.Commands.J0AuthenticatedBaseline.Identities do
  @moduledoc false

  # Auth setup reused from message_tool_taint: real Identity.generate,
  # OIDC human registration, SessionToken, Security.grant. Proof subject
  # is never the canonical owner. JWKS cache table/tuple/expiry matches
  # Arbor.Agent.MessageToolTaintSecurityRegressionTest.register_human_identity!/1.

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.SessionToken

  def register_human_identity!(label) when is_binary(label) do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://oidc-test.arbor.local/j0-baseline/#{label}/#{unique}"
    subject = "j0-subject-#{label}-#{unique}"
    client_id = "arbor-test-client"
    kid = "j0-test-key-#{unique}"

    private_jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, private_map} = JOSE.JWK.to_map(private_jwk)
    {_, public_map} = JOSE.JWK.to_public_map(private_jwk)
    public_map = Map.merge(public_map, %{"alg" => "ES256", "kid" => kid})
    signer = Joken.Signer.create("ES256", private_map, %{"kid" => kid})

    claims = %{
      "iss" => issuer,
      "sub" => subject,
      "aud" => client_id,
      "exp" => System.os_time(:second) + 3_600,
      "iat" => System.os_time(:second),
      "email" => "#{label}-#{unique}@example.test",
      "name" => "J0 Baseline #{label} Human"
    }

    assert {:ok, id_token} = Joken.Signer.sign(claims, signer)
    jwks_table = :arbor_oidc_jwks_cache

    if :ets.whereis(jwks_table) == :undefined do
      :ets.new(jwks_table, [:named_table, :public, :set, read_concurrency: true])
    end

    true =
      :ets.insert(
        jwks_table,
        {issuer, %{"keys" => [public_map]}, System.monotonic_time(:millisecond) + 60_000}
      )

    assert {:ok, identity} = Identity.generate(name: claims["name"])

    human_id =
      "human_" <>
        String.slice(
          Base.encode16(:crypto.hash(:sha256, "#{issuer}:#{subject}"), case: :lower),
          0,
          40
        )

    human_identity = %{
      identity
      | agent_id: human_id,
        metadata: %{
          "identity_type" => "human",
          "oidc_issuer" => issuer,
          "oidc_sub" => subject
        }
    }

    assert :ok =
             Security.register_oidc_identity(human_identity, id_token, %{
               issuer: issuer,
               client_id: client_id
             })

    on_exit(fn ->
      if :ets.whereis(jwks_table) != :undefined, do: :ets.delete(jwks_table, issuer)
      _ = Security.deregister_identity(human_id)
    end)

    %{id: human_id, identity: human_identity, issuer: issuer, subject: subject}
  end

  def grant!(principal, resource) do
    assert {:ok, capability} =
             Security.grant(principal: principal, resource: resource, constraints: %{})

    capability
  end

  def chat_resource(agent_id), do: "arbor://chat/agent/#{agent_id}"

  def session_token!(human_id) when is_binary(human_id) do
    assert {:ok, token} = SessionToken.generate(human_id)
    token
  end
end
