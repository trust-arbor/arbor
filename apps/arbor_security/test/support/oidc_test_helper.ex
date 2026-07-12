defmodule Arbor.Security.OIDCTestHelper do
  @moduledoc false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.OIDC.IdentityStore

  @jwks_cache_table :arbor_oidc_jwks_cache

  def issue_identity(opts \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = Keyword.get(opts, :issuer, "https://oidc-test.arbor.local/#{unique}")
    subject = Keyword.get(opts, :subject, "subject-#{unique}")
    client_id = Keyword.get(opts, :client_id, "arbor-test-client")
    kid = "test-key-#{unique}"

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
      "email" => "operator-#{unique}@example.test",
      "name" => "OIDC Test Operator"
    }

    {:ok, id_token} = Joken.Signer.sign(claims, signer)
    cache_jwks(issuer, %{"keys" => [public_map]})

    {:ok, identity} = Identity.generate(name: claims["name"])
    human_id = IdentityStore.derive_agent_id(claims)

    human_identity = %{
      identity
      | agent_id: human_id,
        metadata: %{
          "identity_type" => "human",
          "oidc_issuer" => issuer,
          "oidc_sub" => subject
        }
    }

    %{
      identity: human_identity,
      id_token: id_token,
      provider: %{issuer: issuer, client_id: client_id},
      claims: claims,
      cleanup: fn -> delete_cached_jwks(issuer) end
    }
  end

  def tamper_token(id_token) do
    [header, payload, signature] = String.split(id_token, ".")
    {:ok, <<first, rest::binary>>} = Base.url_decode64(signature, padding: false)
    tampered = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
    Enum.join([header, payload, tampered], ".")
  end

  defp cache_jwks(issuer, jwks) do
    ensure_jwks_table()
    expires_at = System.monotonic_time(:millisecond) + 60_000
    true = :ets.insert(@jwks_cache_table, {issuer, jwks, expires_at})
    :ok
  end

  defp delete_cached_jwks(issuer) do
    if :ets.whereis(@jwks_cache_table) != :undefined do
      :ets.delete(@jwks_cache_table, issuer)
    end

    :ok
  end

  defp ensure_jwks_table do
    if :ets.whereis(@jwks_cache_table) == :undefined do
      :ets.new(@jwks_cache_table, [:set, :public, :named_table])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
