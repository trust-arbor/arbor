defmodule Arbor.Security.OIDC.AuthCodeFlowTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.OIDC.AuthCodeFlow

  @moduletag :fast

  describe "generate_pkce/0" do
    test "returns code_verifier and code_challenge pair" do
      {verifier, challenge} = AuthCodeFlow.generate_pkce()

      assert is_binary(verifier)
      assert is_binary(challenge)
      assert verifier != challenge
      # base64url encoded 32 bytes = 43 chars
      assert String.length(verifier) == 43
    end

    test "challenge is SHA-256 of verifier" do
      {verifier, challenge} = AuthCodeFlow.generate_pkce()

      expected_challenge =
        :crypto.hash(:sha256, verifier)
        |> Base.url_encode64(padding: false)

      assert challenge == expected_challenge
    end

    test "generates unique pairs each call" do
      {v1, c1} = AuthCodeFlow.generate_pkce()
      {v2, c2} = AuthCodeFlow.generate_pkce()

      assert v1 != v2
      assert c1 != c2
    end
  end

  describe "generate_state/0" do
    test "returns a non-empty base64url string" do
      state = AuthCodeFlow.generate_state()
      assert is_binary(state)
      assert String.length(state) > 0
    end

    test "generates unique state each call" do
      s1 = AuthCodeFlow.generate_state()
      s2 = AuthCodeFlow.generate_state()
      assert s1 != s2
    end
  end

  describe "build_authorize_url/4" do
    test "returns error when issuer is unreachable" do
      provider = %{
        issuer: "https://nonexistent.arbor-test-oidc.invalid",
        client_id: "test-client"
      }

      assert {:error, {:http_request_failed, _}} =
               AuthCodeFlow.build_authorize_url(provider, "http://localhost/cb", "state123")
    end
  end

  describe "exchange_code/4" do
    test "returns error when issuer is unreachable" do
      provider = %{
        issuer: "https://nonexistent.arbor-test-oidc.invalid",
        client_id: "test-client"
      }

      assert {:error, {:http_request_failed, _}} =
               AuthCodeFlow.exchange_code(provider, "code123", "http://localhost/cb", "verifier123")
    end
  end
end
