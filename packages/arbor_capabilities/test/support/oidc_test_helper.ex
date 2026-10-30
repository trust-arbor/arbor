defmodule Arbor.Security.OIDCTestHelper do
  @moduledoc false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.OIDC.JwksCache

  # Explicit fixture for tests whose owned identity universe has no aliases.
  # Production never installs this fallback; missing resolver/store denies.
  defmodule UnlinkedIdentityResolver do
    def resolve(id) when is_binary(id), do: {:ok, id}
  end

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

    claims =
      Map.merge(
        %{
          "iss" => issuer,
          "sub" => subject,
          "aud" => client_id,
          "exp" => System.os_time(:second) + 3_600,
          "iat" => System.os_time(:second),
          "email" => "operator-#{unique}@example.test",
          "name" => "OIDC Test Operator"
        },
        Keyword.get(opts, :claim_overrides, %{})
      )

    {:ok, id_token} = Joken.Signer.sign(claims, signer)

    provider =
      Map.merge(
        %{issuer: issuer, client_id: client_id},
        Keyword.get(opts, :provider_overrides, %{})
      )

    cache_jwks(provider, %{"keys" => [public_map]})

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
      provider: provider,
      jwks: %{"keys" => [public_map]},
      claims: claims,
      cleanup: fn -> delete_cached_jwks(provider) end
    }
  end

  def tamper_token(id_token) do
    [header, payload, signature] = String.split(id_token, ".")
    {:ok, <<first, rest::binary>>} = Base.url_decode64(signature, padding: false)
    tampered = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
    Enum.join([header, payload, tampered], ".")
  end

  defp cache_jwks(provider, jwks) do
    JwksCache.put_fixture(provider, jwks)
  end

  defp delete_cached_jwks(provider) do
    JwksCache.delete_fixture(provider)
  end
end
