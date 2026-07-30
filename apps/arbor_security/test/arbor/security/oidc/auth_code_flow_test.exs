defmodule Arbor.Security.OIDC.AuthCodeFlowTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.LoopbackHTTPServer, as: Server
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

  # These replace the previous pair of tests that resolved
  # "https://nonexistent.arbor-test-oidc.invalid" — those depended on live DNS.
  # The preserved {:http_request_failed, _} error family is still asserted, now
  # against deterministic loopback transports.
  describe "transport failures keep the historical error family" do
    test "a refused connection yields {:http_request_failed, _}" do
      provider = %{
        issuer: Server.closed_port_url(),
        client_id: "test-client",
        allow_http: true
      }

      assert {:error, {:http_request_failed, {:transport_error, :econnrefused}}} =
               AuthCodeFlow.build_authorize_url(provider, "http://127.0.0.1:1/cb", "state123")

      assert {:error, {:http_request_failed, {:transport_error, :econnrefused}}} =
               AuthCodeFlow.exchange_code(
                 provider,
                 "code123",
                 "http://127.0.0.1:1/cb",
                 "verifier123"
               )
    end

    test "a socket closed without a response yields {:http_request_failed, _}" do
      {issuer, server} =
        Server.start(%{"/.well-known/openid-configuration" => :close})

      on_exit(fn -> Server.stop(server) end)

      provider = %{issuer: issuer, client_id: "test-client", allow_http: true}

      assert {:error, {:http_request_failed, {:transport_error, _}}} =
               AuthCodeFlow.exchange_code(
                 provider,
                 "code123",
                 "http://127.0.0.1:1/cb",
                 "verifier123"
               )
    end

    test "a server that never replies yields a normalized timeout" do
      {issuer, server} = Server.start(%{"/.well-known/openid-configuration" => :hang})
      on_exit(fn -> Server.stop(server) end)

      provider = %{
        issuer: issuer,
        client_id: "test-client",
        allow_http: true,
        timeout_ms: 200
      }

      assert {:error, {:http_request_failed, {:timeout, 200}}} =
               AuthCodeFlow.exchange_code(
                 provider,
                 "code123",
                 "http://127.0.0.1:1/cb",
                 "verifier123"
               )
    end
  end

  describe "build_authorize_url/4 behaviour preservation" do
    setup do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "#{base}/authorize",
                 "token_endpoint" => "#{base}/token"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      %{provider: %{issuer: issuer, client_id: "test-client", allow_http: true}}
    end

    test "returns {:ok, url, verifier} with the historical defaults", %{provider: provider} do
      assert {:ok, url, verifier} =
               AuthCodeFlow.build_authorize_url(provider, "http://127.0.0.1:1/cb", "state123")

      assert String.length(verifier) == 43

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["response_type"] == "code"
      assert query["client_id"] == "test-client"
      assert query["state"] == "state123"
      assert query["code_challenge_method"] == "S256"
      # Historical default scopes.
      assert query["scope"] == "openid email profile"
    end

    test "accepts the production provider shape and uses its configured scopes", %{
      provider: provider
    } do
      provider = Map.put(provider, :scopes, ["openid", "custom"])

      assert {:ok, url, _verifier} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123"
               )

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["scope"] == "openid custom"
    end

    test "a caller-supplied challenge without a verifier still yields \"\"", %{provider: provider} do
      assert {:ok, _url, ""} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123",
                 code_challenge: "preset-challenge"
               )
    end

    test "uses a caller-supplied challenge when verifier is omitted", %{provider: provider} do
      assert {:ok, url, ""} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123",
                 code_challenge: "preset-challenge"
               )

      query = URI.decode_query(URI.parse(url).query || "")
      assert query["code_challenge"] == "preset-challenge"
    end

    test "rejects option alias collision on build_authorize_url options", %{provider: provider} do
      assert {:error, {:invalid_params, :duplicate_key}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123",
                 [{:code_challenge, "one"}, {"code_challenge", "two"}]
               )
    end

    test "rejects extra_query that would override a reserved field", %{provider: provider} do
      assert {:error, {:invalid_extra_query, {:reserved_key, "redirect_uri"}}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123",
                 extra_query: [{"redirect_uri", "http://evil.example/cb"}]
               )
    end

    test "rejects unsupported PKCE challenge methods", %{provider: provider} do
      assert {:error, {:invalid_params, :invalid_challenge_method}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123",
                 code_challenge_method: "plain"
               )
    end

    test "rejects malformed options before opening any network socket", %{provider: provider} do
      assert {:error, {:invalid_params, :invalid_options}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123",
                 [1 | 2]
               )

      assert {:error, {:invalid_params, :invalid_options}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state123",
                 [:not_a_kv | []]
               )
    end

    test "operation-scoped discovery lets a bad token endpoint pass authorize URL discovery", %{
      provider: provider
    } do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "#{base}/authorize",
                 "token_endpoint" => "https://evil.example/token"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      provider = Map.put(provider, :issuer, issuer)

      assert {:ok, url, _verifier} =
               AuthCodeFlow.build_authorize_url(provider, "http://127.0.0.1/cb", "state123")

      assert String.contains?(url, "#{issuer}/authorize")
    end
  end

  describe "missing endpoints keep their historical atoms" do
    test "an empty discovery document yields :no_token_endpoint" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{"issuer" => base})}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      provider = %{issuer: issuer, client_id: "test-client", allow_http: true}

      assert {:error, :no_token_endpoint} =
               AuthCodeFlow.exchange_code(provider, "c", "http://127.0.0.1:1/cb", "v")
    end

    test "an empty discovery document yields :no_authorization_endpoint" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{"issuer" => base})}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      provider = %{issuer: issuer, client_id: "test-client", allow_http: true}

      assert {:error, :no_authorization_endpoint} =
               AuthCodeFlow.build_authorize_url(provider, "http://127.0.0.1:1/cb", "state123")
    end
  end

  describe "public-boundary totality" do
    test "rejects non-map provider values at the boundary" do
      assert {:error, {:invalid_provider, :invalid_map}} =
               AuthCodeFlow.build_authorize_url(
                 "https://idp.example",
                 "http://127.0.0.1:1/cb",
                 "state",
                 []
               )

      assert {:error, {:invalid_provider, :invalid_map}} =
               AuthCodeFlow.exchange_code(
                 [:not, :a, :map],
                 "code",
                 "http://127.0.0.1:1/cb",
                 "verifier"
               )
    end

    test "rejects oversized provider and options without reading from the network" do
      too_many =
        1..200
        |> Enum.map(&{String.to_atom("k#{&1}"), "v"})
        |> Enum.into([])

      provider =
        Enum.reduce(too_many, %{issuer: "https://idp", client_id: "c"}, fn {k, v}, acc ->
          Map.put(acc, k, v)
        end)

      assert {:error, {:invalid_provider, :too_many_fields}} =
               AuthCodeFlow.exchange_code(provider, "code", "http://127.0.0.1:1/cb", "v")

      assert {:error, {:invalid_params, :too_many_options}} =
               AuthCodeFlow.build_authorize_url(
                 %{issuer: "https://idp", client_id: "c"},
                 "http://127.0.0.1:1/cb",
                 "state",
                 too_many
               )
    end

    test "rejects raw whitespace in URI fields and embedded scope whitespace before discovery" do
      provider = %{
        issuer: Server.closed_port_url(),
        client_id: "test-client",
        allow_http: true
      }

      assert {:error, {:invalid_params, :invalid_text}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb path",
                 "state"
               )

      assert {:error, {:invalid_params, :invalid_scopes}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 "http://127.0.0.1:1/cb",
                 "state",
                 scopes: ["open" <> <<0xC2, 0xA0>> <> "id"]
               )
    end
  end
end
