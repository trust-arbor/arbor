defmodule Arbor.Capabilities.OIDC.TestSupport.TokenFixture do
  @moduledoc false

  alias Arbor.Common.OAuth.HttpClient.{Request, Response}

  # This adapter carries only the public JWKS in its URL. It needs no shared
  # cache, identity universe, application configuration or background process.
  defmodule JwksClient do
    @moduledoc false

    def request(%Request{url: url}) do
      [_issuer, encoded] = String.split(url, "/jwks/", parts: 2)
      {:ok, body} = Base.url_decode64(encoded, padding: false)
      {:ok, %Response{status: 200, body: body}}
    end
  end

  def issue(opts \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = Keyword.get(opts, :issuer, "https://oidc-test.example/#{unique}")
    client_id = Keyword.get(opts, :client_id, "arbor-test-client")
    algorithm = Keyword.get(opts, :algorithm, "ES256")
    kid = "test-key-#{unique}"

    key_type = if algorithm == "RS256", do: {:rsa, 2_048}, else: {:ec, :secp256r1}
    private_jwk = JOSE.JWK.generate_key(key_type)
    {_, private_map} = JOSE.JWK.to_map(private_jwk)
    {_, public_map} = JOSE.JWK.to_public_map(private_jwk)
    public_map = Map.merge(public_map, %{"alg" => algorithm, "kid" => kid})
    signer = Joken.Signer.create(algorithm, private_map, %{"kid" => kid})

    claims =
      Map.merge(
        %{
          "iss" => issuer,
          "sub" => "subject-#{unique}",
          "aud" => client_id,
          "exp" => System.os_time(:second) + 3_600,
          "iat" => System.os_time(:second),
          "email" => "operator-#{unique}@example.test",
          "name" => "OIDC Test Operator"
        },
        Keyword.get(opts, :claim_overrides, %{})
      )

    {:ok, id_token} = Joken.Signer.sign(claims, signer)
    jwks = %{"keys" => [public_map]}
    encoded = jwks |> Jason.encode!() |> Base.url_encode64(padding: false)

    provider =
      Map.merge(
        %{
          issuer: issuer,
          client_id: client_id,
          endpoints: %{jwks_uri: issuer <> "/jwks/" <> encoded},
          http_client: JwksClient
        },
        Keyword.get(opts, :provider_overrides, %{})
      )

    %{id_token: id_token, provider: provider, jwks: jwks, claims: claims, kid: kid}
  end

  def tamper(id_token) do
    [header, payload, signature] = String.split(id_token, ".")
    {:ok, <<first, rest::binary>>} = Base.url_decode64(signature, padding: false)
    tampered = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
    Enum.join([header, payload, tampered], ".")
  end
end
