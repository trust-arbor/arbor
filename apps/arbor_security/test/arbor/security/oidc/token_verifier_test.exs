defmodule Arbor.Security.OIDC.TokenVerifierTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.OAuth.HttpClient.{Request, Response}
  alias Arbor.Security.OIDC.JwksCache
  alias Arbor.Security.OIDC.TokenVerifier

  @moduletag :fast

  defmodule CrossOriginDiscoveryClient do
    def request(%Request{url: "https://idp.example/.well-known/openid-configuration"}) do
      {:ok,
       %Response{
         status: 200,
         body:
           Jason.encode!(%{
             "issuer" => "https://idp.example",
             "jwks_uri" => "https://attacker.example/jwks"
           })
       }}
    end

    def request(_request), do: raise("untrusted JWKS endpoint was fetched")
  end

  defmodule OversizedJwksClient do
    def request(%Request{}) do
      {:ok, %Response{status: 200, body: String.duplicate("x", 262_145)}}
    end
  end

  defmodule RotatedJwksClient do
    def request(%Request{}) do
      jwks = Application.fetch_env!(:arbor_security, :rotated_jwks_test_fixture)
      {:ok, %Response{status: 200, body: Jason.encode!(jwks)}}
    end
  end

  describe "decode_unverified/1" do
    test "decodes a valid JWT payload without verification" do
      # Create a minimal JWT (header.payload.signature)
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(
          Jason.encode!(%{
            "iss" => "https://accounts.google.com",
            "sub" => "12345",
            "email" => "user@example.com",
            "exp" => System.os_time(:second) + 3600
          }),
          padding: false
        )

      sig = Base.url_encode64("fake-sig", padding: false)

      token = "#{header}.#{payload}.#{sig}"

      assert {:ok, claims} = TokenVerifier.decode_unverified(token)
      assert claims["iss"] == "https://accounts.google.com"
      assert claims["sub"] == "12345"
      assert claims["email"] == "user@example.com"
    end

    test "returns error for invalid token format" do
      assert {:error, :invalid_token_format} = TokenVerifier.decode_unverified("not-a-jwt")
    end

    test "returns error for malformed base64" do
      assert {:error, :invalid_token_format} = TokenVerifier.decode_unverified("a.!!!.c")
    end
  end

  describe "verify/2" do
    test "returns error when issuer is unreachable" do
      provider = %{
        issuer: "https://nonexistent.arbor-test-oidc.invalid",
        client_id: "test-client"
      }

      header =
        Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "key1"}), padding: false)

      payload = Base.url_encode64(Jason.encode!(%{"iss" => "test", "sub" => "1"}), padding: false)
      sig = Base.url_encode64("sig", padding: false)
      token = "#{header}.#{payload}.#{sig}"

      assert {:error, {:http_request_failed, _}} = TokenVerifier.verify(token, provider)
    end

    test "returns error for invalid JWT header" do
      provider = %{issuer: "https://example.com", client_id: "test"}
      assert {:error, reason} = TokenVerifier.verify("not-jwt", provider)
      assert reason in [:invalid_token_format, :invalid_jwt_header]
    end

    test "security regression: discovered JWKS must stay on an authorized origin" do
      token = unsigned_token(%{"alg" => "RS256", "kid" => "cross-origin"})

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               TokenVerifier.verify(token, %{
                 issuer: "https://idp.example",
                 client_id: "test-client",
                 http_client: CrossOriginDiscoveryClient
               })
    end

    test "security regression: JWKS transport enforces a response byte budget" do
      token = unsigned_token(%{"alg" => "RS256", "kid" => "oversized"})

      assert {:error, {:response_bytes_exceeded, 262_144}} =
               TokenVerifier.verify(token, %{
                 issuer: "https://idp.example",
                 client_id: "test-client",
                 endpoints: %{jwks_uri: "https://idp.example/jwks"},
                 http_client: OversizedJwksClient
               })
    end

    test "security regression: malformed JWKS algorithms return an error instead of raising" do
      fixture = Arbor.Security.OIDCTestHelper.issue_identity()
      on_exit(fixture.cleanup)
      [header_b64, _payload, _signature] = String.split(fixture.id_token, ".")
      {:ok, header_json} = Base.url_decode64(header_b64, padding: false)
      header = Jason.decode!(header_json)

      :ok =
        JwksCache.put_fixture(
          fixture.provider,
          %{"keys" => [%{"kid" => header["kid"], "alg" => "not-an-algorithm"}]}
        )

      assert {:error, :invalid_jwks_key} =
               TokenVerifier.verify(fixture.id_token, fixture.provider)
    end

    test "security regression: a cached kid miss refetches rotated JWKS once" do
      fixture = Arbor.Security.OIDCTestHelper.issue_identity()

      provider =
        Map.merge(fixture.provider, %{
          endpoints: %{jwks_uri: fixture.provider.issuer <> "/jwks"},
          http_client: RotatedJwksClient
        })

      Application.put_env(:arbor_security, :rotated_jwks_test_fixture, fixture.jwks)

      on_exit(fn ->
        Application.delete_env(:arbor_security, :rotated_jwks_test_fixture)
        JwksCache.delete_fixture(provider)
        fixture.cleanup.()
      end)

      :ok =
        JwksCache.put_fixture(
          provider,
          %{"keys" => [%{"kid" => "retired-key", "kty" => "RSA"}]}
        )

      assert {:ok, claims} = TokenVerifier.verify(fixture.id_token, provider)
      assert claims["sub"] == fixture.claims["sub"]
    end

    test "security regression: the supervised JWKS table rejects direct key planting" do
      table = :arbor_oidc_jwks_cache
      assert :ets.info(table, :owner) == Process.whereis(JwksCache)
      assert :ets.info(table, :protection) == :protected

      assert_raise ArgumentError, fn ->
        :ets.insert(
          table,
          {"https://attacker.example", %{"keys" => [%{"kid" => "planted"}]}, :infinity}
        )
      end
    end

    test "security regression: arbitrary cache mutation cannot poison a configured verifier" do
      fixture = Arbor.Security.OIDCTestHelper.issue_identity()
      on_exit(fixture.cleanup)

      refute function_exported?(JwksCache, :put, 3)
      refute function_exported?(JwksCache, :delete, 1)

      poisoned_provider = Map.put(fixture.provider, :http_client, RotatedJwksClient)

      :ok =
        JwksCache.put_fixture(poisoned_provider, %{
          "keys" => [%{"kid" => "poisoned", "alg" => "not-an-algorithm"}]
        })

      on_exit(fn -> JwksCache.delete_fixture(poisoned_provider) end)

      assert {:ok, claims} = TokenVerifier.verify(fixture.id_token, fixture.provider)
      assert claims["sub"] == fixture.claims["sub"]
    end

    test "security regression: rejects non-integer expiry claims" do
      fixture =
        Arbor.Security.OIDCTestHelper.issue_identity(
          claim_overrides: %{"exp" => Integer.to_string(System.os_time(:second) + 3_600)}
        )

      on_exit(fixture.cleanup)

      assert {:error, :invalid_exp_claim} =
               TokenVerifier.verify(fixture.id_token, fixture.provider)
    end

    test "security regression: rejects invalid issued-at and not-before claims" do
      future = System.os_time(:second) + 600

      for claim <- ["iat", "nbf"] do
        fixture =
          Arbor.Security.OIDCTestHelper.issue_identity(
            claim_overrides: %{claim => future},
            provider_overrides: %{clock_skew_seconds: 0}
          )

        on_exit(fixture.cleanup)

        expected = if claim == "iat", do: :invalid_iat_claim, else: :invalid_nbf_claim
        assert {:error, ^expected} = TokenVerifier.verify(fixture.id_token, fixture.provider)
      end
    end

    test "security regression: multiple audiences require the client as authorized party" do
      fixture =
        Arbor.Security.OIDCTestHelper.issue_identity(
          claim_overrides: %{"aud" => ["arbor-test-client", "another-client"]}
        )

      on_exit(fixture.cleanup)

      assert {:error, :invalid_authorized_party_claim} =
               TokenVerifier.verify(fixture.id_token, fixture.provider)
    end

    test "security regression: an expected OIDC nonce must round-trip" do
      fixture =
        Arbor.Security.OIDCTestHelper.issue_identity(
          claim_overrides: %{"nonce" => "attacker-nonce"},
          provider_overrides: %{expected_nonce: "browser-flow-nonce"}
        )

      on_exit(fixture.cleanup)

      assert {:error, :nonce_mismatch} =
               TokenVerifier.verify(fixture.id_token, fixture.provider)
    end
  end

  defp unsigned_token(header) do
    encoded_header = Base.url_encode64(Jason.encode!(header), padding: false)
    encoded_payload = Base.url_encode64(Jason.encode!(%{}), padding: false)
    encoded_signature = Base.url_encode64("signature", padding: false)
    Enum.join([encoded_header, encoded_payload, encoded_signature], ".")
  end
end
