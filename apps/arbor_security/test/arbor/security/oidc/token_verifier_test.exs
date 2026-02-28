defmodule Arbor.Security.OIDC.TokenVerifierTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.OIDC.TokenVerifier

  @moduletag :fast

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

      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "key1"}), padding: false)
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
  end
end
