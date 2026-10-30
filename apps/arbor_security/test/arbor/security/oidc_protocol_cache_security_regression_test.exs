defmodule Arbor.Security.OIDCProtocolCacheSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.OAuth.HttpClient.{Request, Response}
  alias Arbor.Security
  alias Arbor.Security.OIDC.JwksCache

  @moduletag :fast
  @fixture_key :oidc_protocol_cache_test_fixture

  defmodule ProtocolDelegates do
    @moduledoc false

    # These helpers exist only in this test. The pre-extraction host ignores
    # them, so dynamically dispatch to the package facade without making the
    # regression's compilation depend on that package existing on the parent.
    def prepare_verification(token, provider),
      do: apply(Arbor.Capabilities.OIDC, :prepare_verification, [token, provider])

    def verify_prepared(context, jwks),
      do: apply(Arbor.Capabilities.OIDC, :verify_prepared, [context, jwks])

    def fetch_jwks_uncached(provider),
      do: apply(Arbor.Capabilities.OIDC, :fetch_jwks_uncached, [provider])
  end

  defmodule ProtocolA do
    @moduledoc false
    defdelegate prepare_verification(token, provider), to: ProtocolDelegates
    defdelegate verify_prepared(context, jwks), to: ProtocolDelegates
    defdelegate fetch_jwks_uncached(provider), to: ProtocolDelegates
  end

  defmodule ProtocolB do
    @moduledoc false
    defdelegate prepare_verification(token, provider), to: ProtocolDelegates
    defdelegate verify_prepared(context, jwks), to: ProtocolDelegates
    defdelegate fetch_jwks_uncached(provider), to: ProtocolDelegates
  end

  defmodule TrustedSelectorHttpClient do
    @moduledoc false

    def request(%Request{url: url}) do
      %{counter: counter, endpoint: endpoint} =
        Application.fetch_env!(:arbor_security, :oidc_protocol_cache_test_fixture)

      # Only trusted application configuration selects this fixture's source.
      # Neither the request nor provider fields can select a protocol backend.
      backend =
        case Application.fetch_env!(:arbor_security, :oidc_adapter) do
          ProtocolA -> :a
          ProtocolB -> :b
        end

      if url == endpoint do
        jwks =
          Agent.get_and_update(counter, fn state ->
            {Map.fetch!(state.jwks, backend), update_in(state, [:fetches, backend], &(&1 + 1))}
          end)

        {:ok, %Response{status: 200, body: Jason.encode!(jwks)}}
      else
        {:error, {:transport_error, :other}}
      end
    end
  end

  test "security regression: changing the trusted protocol backend never reuses another backend's signing keys" do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://protocol-cache.example/#{unique}"
    client_id = "arbor-protocol-cache"
    kid = "same-kid-#{unique}"
    now = System.os_time(:second)

    claims_a = %{
      "iss" => issuer,
      "sub" => "operator-a",
      "aud" => client_id,
      "iat" => now,
      "exp" => now + 3_600
    }

    claims_b = Map.put(claims_a, "sub", "operator-b")
    {token_a, jwks_a} = signed_token(kid, claims_a)
    {token_b, jwks_b} = signed_token(kid, claims_b)
    refute jwks_a == jwks_b

    counter =
      start_supervised!(
        {Agent,
         fn ->
           %{jwks: %{a: jwks_a, b: jwks_b}, fetches: %{a: 0, b: 0}}
         end}
      )

    endpoint = issuer <> "/jwks"

    provider = %{
      issuer: issuer,
      client_id: client_id,
      allow_http: false,
      endpoints: %{jwks_uri: endpoint},
      http_client: TrustedSelectorHttpClient
    }

    originals =
      for key <- [:oidc, :oidc_adapter, @fixture_key] do
        {key, Application.fetch_env(:arbor_security, key)}
      end

    on_exit(fn ->
      # Clear both trusted protocol epochs before restoring the caller's
      # configuration. The old host has one epoch; deleting twice is harmless.
      for backend <- [ProtocolA, ProtocolB] do
        Application.put_env(:arbor_security, :oidc_adapter, backend)
        JwksCache.delete_fixture(provider)
      end

      for {key, prior} <- originals do
        case prior do
          {:ok, value} -> Application.put_env(:arbor_security, key, value)
          :error -> Application.delete_env(:arbor_security, key)
        end
      end
    end)

    Application.put_env(:arbor_security, @fixture_key, %{counter: counter, endpoint: endpoint})

    # A real configured provider authorizes the supervised cache to retain its
    # fetched keys; no test-only key planting is involved in this regression.
    Application.put_env(:arbor_security, :oidc, providers: [provider])
    Application.put_env(:arbor_security, :oidc_adapter, ProtocolA)

    assert {:ok, ^claims_a} = Security.verify_oidc_token(token_a, provider)
    assert fetches(counter) == %{a: 1, b: 0}
    assert {:ok, ^claims_a} = Security.verify_oidc_token(token_a, provider)
    assert fetches(counter) == %{a: 1, b: 0}

    Application.put_env(:arbor_security, :oidc_adapter, ProtocolB)

    # The kid deliberately stays the same: a stale key produces a signature
    # failure instead of the separate kid-miss refresh path masking this bug.
    assert {:ok, ^claims_b} = Security.verify_oidc_token(token_b, provider)
    assert fetches(counter) == %{a: 1, b: 1}
    assert {:error, _reason} = Security.verify_oidc_token(token_a, provider)
    assert {:ok, ^claims_b} = Security.verify_oidc_token(token_b, provider)
    assert fetches(counter) == %{a: 1, b: 1}

    untrusted_overrides =
      Map.merge(provider, %{
        "oidc_adapter" => ProtocolA,
        "protocol_adapter" => ProtocolA,
        oidc_adapter: ProtocolA,
        protocol_adapter: ProtocolA
      })

    assert {:error, _reason} = Security.verify_oidc_token(token_a, untrusted_overrides)
    assert {:ok, ^claims_b} = Security.verify_oidc_token(token_b, untrusted_overrides)
    assert fetches(counter) == %{a: 1, b: 1}
  end

  defp fetches(counter), do: Agent.get(counter, & &1.fetches)

  defp signed_token(kid, claims) do
    private_jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, private_map} = JOSE.JWK.to_map(private_jwk)
    {_, public_map} = JOSE.JWK.to_public_map(private_jwk)
    signer = Joken.Signer.create("ES256", private_map, %{"kid" => kid})
    {:ok, token} = Joken.Signer.sign(claims, signer)
    jwks = %{"keys" => [Map.merge(public_map, %{"alg" => "ES256", "kid" => kid})]}
    {token, jwks}
  end
end
