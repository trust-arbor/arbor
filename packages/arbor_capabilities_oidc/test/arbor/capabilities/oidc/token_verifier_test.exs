defmodule Arbor.Capabilities.OIDC.TokenVerifierTest do
  use ExUnit.Case, async: true

  alias Arbor.Capabilities.OIDC
  alias Arbor.Capabilities.OIDC.TestSupport.LoopbackHTTPServer, as: Server
  alias Arbor.Capabilities.OIDC.TestSupport.TokenFixture
  alias Arbor.Common.OAuth.HttpClient.{Request, Response}

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

  defmodule NeverFetchClient do
    def request(_request), do: raise("invalid token reached network IO")
  end

  describe "decode_unverified/1" do
    test "decodes claims without treating the payload as verification" do
      fixture = TokenFixture.issue()
      assert {:ok, claims} = OIDC.decode_unverified(fixture.id_token)
      assert claims == fixture.claims

      assert {:ok, claims} = OIDC.decode_unverified(TokenFixture.tamper(fixture.id_token))
      assert claims == fixture.claims
    end

    test "malformed tokens and nonbinary input return closed errors" do
      for token <- ["not-a-jwt", "a.!!!.c", nil, %{}] do
        assert {:error, :invalid_token_format} = OIDC.decode_unverified(token)
      end
    end
  end

  describe "standalone verify/2" do
    test "verifies genuine ES256 and RS256 tokens without an identity or cache owner" do
      for algorithm <- ["ES256", "RS256"] do
        fixture = TokenFixture.issue(algorithm: algorithm)
        assert {:ok, claims} = OIDC.verify(fixture.id_token, fixture.provider)
        assert claims == fixture.claims

        assert {:error, {:signature_verification_failed, _}} =
                 OIDC.verify(TokenFixture.tamper(fixture.id_token), fixture.provider)
      end
    end

    test "unreachable issuer preserves the transport error family without DNS" do
      provider = %{issuer: Server.closed_port_url(), client_id: "test", allow_http: true}
      assert {:error, {:http_request_failed, _}} = OIDC.verify(unsigned_token(), provider)
    end

    test "invalid providers and headers are rejected before network IO" do
      provider = %{
        issuer: "https://idp.example",
        client_id: "test",
        http_client: NeverFetchClient
      }

      assert {:error, :invalid_jwt_header} = OIDC.verify("not-jwt", provider)
      assert {:error, :invalid_token_format} = OIDC.verify(nil, provider)
      assert {:error, :invalid_provider_config} = OIDC.verify("token", %{})

      assert {:error, {:invalid_issuer, _}} =
               OIDC.verify(unsigned_token(), %{provider | issuer: "http://idp.example"})
    end

    test "discovered JWKS must stay on an authorized origin" do
      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               OIDC.verify(unsigned_token(), %{
                 issuer: "https://idp.example",
                 client_id: "test-client",
                 http_client: CrossOriginDiscoveryClient
               })
    end

    test "JWKS transport enforces the response byte budget" do
      assert {:error, {:response_bytes_exceeded, 262_144}} =
               OIDC.verify(unsigned_token(), %{
                 issuer: "https://idp.example",
                 client_id: "test-client",
                 endpoints: %{jwks_uri: "https://idp.example/jwks"},
                 http_client: OversizedJwksClient
               })
    end

    test "provider options cannot select a cache or fetch callback" do
      fixture = TokenFixture.issue()

      provider =
        Map.merge(fixture.provider, %{
          cache: NeverFetchClient,
          cache_module: NeverFetchClient,
          fetch_jwks: fn -> raise "untrusted callback invoked" end,
          jwks: %{"keys" => [%{"kid" => fixture.kid, "alg" => "not-an-algorithm"}]}
        })

      assert {:ok, claims} = OIDC.verify(fixture.id_token, provider)
      assert claims == fixture.claims
    end
  end

  describe "prepared verification" do
    test "context inspection redacts the token, provider, and decoded header" do
      fixture = TokenFixture.issue(provider_overrides: %{client_secret: "SECRET-CONTEXT-CANARY"})
      assert {:ok, context} = OIDC.prepare_verification(fixture.id_token, fixture.provider)
      inspected = inspect(context)
      assert inspected == "#Arbor.Capabilities.OIDC.Verification<[REDACTED]>"

      for secret <- [
            fixture.id_token,
            fixture.provider.issuer,
            fixture.kid,
            "SECRET-CONTEXT-CANARY"
          ] do
        refute inspected =~ secret
      end

      assert {:ok, claims} = OIDC.verify_prepared(context, fixture.jwks)
      assert claims == fixture.claims
    end

    test "a missing kid is returned for the host's owned refresh decision" do
      fixture = TokenFixture.issue()
      {:ok, context} = OIDC.prepare_verification(fixture.id_token, fixture.provider)

      assert {:error, {:kid_not_found, kid}} =
               OIDC.verify_prepared(context, %{"keys" => [%{"kid" => "retired-key"}]})

      assert kid == fixture.kid
      assert {:ok, claims} = OIDC.verify_prepared(context, fixture.jwks)
      assert claims == fixture.claims
    end

    test "malformed JWKS and algorithms return errors rather than raising" do
      fixture = TokenFixture.issue()
      {:ok, context} = OIDC.prepare_verification(fixture.id_token, fixture.provider)

      assert {:error, :invalid_jwks_key} =
               OIDC.verify_prepared(context, %{
                 "keys" => [%{"kid" => fixture.kid, "alg" => "not-an-algorithm"}]
               })

      for jwks <- [
            nil,
            %{},
            %{"keys" => []},
            %{"keys" => [nil]},
            %{"keys" => [%{}, "not-a-key"]},
            %{"keys" => List.duplicate(%{}, 129)}
          ] do
        assert {:error, :invalid_jwks_format} = OIDC.verify_prepared(context, jwks)
      end

      for context <- [nil, %{}, "not-a-context"] do
        assert {:error, :invalid_verification_context} =
                 OIDC.verify_prepared(context, fixture.jwks)
      end
    end

    test "rejects non-integer expiry claims" do
      fixture = TokenFixture.issue(claim_overrides: %{"exp" => "future"})
      assert {:error, :invalid_exp_claim} = verify_fixture(fixture)
    end

    test "rejects a signed token with the wrong issuer or audience" do
      issuer_fixture = TokenFixture.issue(claim_overrides: %{"iss" => "https://other.example"})

      assert {:error, {:issuer_mismatch, "https://other.example", expected_issuer}} =
               verify_fixture(issuer_fixture)

      assert expected_issuer == issuer_fixture.provider.issuer

      audience_fixture = TokenFixture.issue(claim_overrides: %{"aud" => "other-client"})

      assert {:error, {:audience_mismatch, "other-client", "arbor-test-client"}} =
               verify_fixture(audience_fixture)
    end

    test "rejects an expired token and an empty subject" do
      expired =
        TokenFixture.issue(
          claim_overrides: %{"exp" => System.os_time(:second) - 600},
          provider_overrides: %{clock_skew_seconds: 0}
        )

      assert {:error, :token_expired} = verify_fixture(expired)
      empty_subject = TokenFixture.issue(claim_overrides: %{"sub" => ""})
      assert {:error, :missing_sub_claim} = verify_fixture(empty_subject)
    end

    test "rejects invalid issued-at and not-before claims" do
      future = System.os_time(:second) + 600

      for {claim, expected} <- [{"iat", :invalid_iat_claim}, {"nbf", :invalid_nbf_claim}] do
        fixture =
          TokenFixture.issue(
            claim_overrides: %{claim => future},
            provider_overrides: %{clock_skew_seconds: 0}
          )

        assert {:error, ^expected} = verify_fixture(fixture)
      end
    end

    test "multiple audiences require the client as authorized party" do
      fixture = TokenFixture.issue(claim_overrides: %{"aud" => ["arbor-test-client", "other"]})
      assert {:error, :invalid_authorized_party_claim} = verify_fixture(fixture)
    end

    test "an expected nonce must round trip" do
      fixture =
        TokenFixture.issue(
          claim_overrides: %{"nonce" => "attacker-nonce"},
          provider_overrides: %{expected_nonce: "browser-flow-nonce"}
        )

      assert {:error, :nonce_mismatch} = verify_fixture(fixture)
    end

    test "a missing nonce fails while a bound nonce and authorized party succeed" do
      missing = TokenFixture.issue(provider_overrides: %{expected_nonce: "bound-nonce"})
      assert {:error, :nonce_mismatch} = verify_fixture(missing)

      bound =
        TokenFixture.issue(
          claim_overrides: %{
            "nonce" => "bound-nonce",
            "aud" => ["arbor-test-client", "another-client"],
            "azp" => "arbor-test-client"
          },
          provider_overrides: %{expected_nonce: "bound-nonce"}
        )

      assert {:ok, claims} = verify_fixture(bound)
      assert claims == bound.claims
    end
  end

  defp verify_fixture(fixture) do
    with {:ok, context} <- OIDC.prepare_verification(fixture.id_token, fixture.provider) do
      OIDC.verify_prepared(context, fixture.jwks)
    end
  end

  defp unsigned_token do
    header =
      Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "test"}), padding: false)

    payload = Base.url_encode64("{}", padding: false)
    signature = Base.url_encode64("signature", padding: false)
    Enum.join([header, payload, signature], ".")
  end
end
