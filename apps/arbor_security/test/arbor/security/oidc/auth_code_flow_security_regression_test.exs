defmodule Arbor.Security.OIDC.AuthCodeFlowSecurityRegressionTest do
  @moduledoc """
  Public behavioural security regressions for the OIDC authorization-code flow.

  Most tests drive the **public** `AuthCodeFlow.exchange_code/4` against real
  ephemeral-loopback HTTP servers. Each fails on the parent revision (e40ecce6e)
  and passes here:

    * **cross-origin credential POST** — the parent demonstrably POSTs the
      client_secret, code, and PKCE verifier to a second server on a different
      origin, because it took `token_endpoint` straight out of remote discovery
      JSON. The candidate rejects before any POST is made.

    * **provider-body secret leak** — the parent returns the raw 400 body
      inside its error tuple. The candidate returns the status only.

  A final helper-focused describe uses explicit loopback sockets to validate the
  request parser behavior directly.
  """

  use ExUnit.Case, async: true

  alias Arbor.Security.LoopbackHTTPServer, as: Server
  alias Arbor.Security.OIDC.AuthCodeFlow

  @moduletag :fast
  @moduletag :security

  @redirect_uri "http://127.0.0.1:1/callback"
  @code "auth-code-abc"
  @verifier "pkce-verifier-xyz"

  describe "security regression: cross-origin token endpoint" do
    test "rejects before POSTing credentials to a foreign origin" do
      # Server 2 is on a different port, therefore a different origin. It
      # answers with a perfectly valid token response, so nothing except the
      # origin gate can stop the exchange from succeeding.
      {foreign_url, foreign_server} =
        Server.start(%{
          "/token" =>
            {:respond, 200, [{"content-type", "application/json"}],
             Jason.encode!(%{"id_token" => "eyJ.captured", "token_type" => "Bearer"})}
        })

      {issuer_url, issuer_server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "#{foreign_url}/authorize",
                 "token_endpoint" => "#{foreign_url}/token"
               })}
          }
        end)

      on_exit(fn ->
        Server.stop(foreign_server)
        Server.stop(issuer_server)
      end)

      provider = %{
        issuer: issuer_url,
        client_id: "arbor-test-client",
        client_secret: "test-only-client-secret",
        allow_http: true
      }

      result = AuthCodeFlow.exchange_code(provider, @code, @redirect_uri, @verifier)

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} = result

      # The gate fired BEFORE the network call: the foreign server saw nothing.
      foreign_report = Server.await(foreign_server)
      assert foreign_report.requests == []
    end
  end

  describe "security regression: provider error body is not leaked" do
    test "a 400 token response yields status only, never the body" do
      canary = "ARBOR-LEAK-CANARY-#{System.unique_integer([:positive])}"

      {issuer_url, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "authorization_endpoint" => "#{base}/authorize",
                   "token_endpoint" => "#{base}/token"
                 })},
              "/token" =>
                {:respond, 400, [{"content-type", "application/json"}],
                 Jason.encode!(%{"error" => "invalid_grant", "error_description" => canary})}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      provider = %{issuer: issuer_url, client_id: "arbor-test-client", allow_http: true}

      result = AuthCodeFlow.exchange_code(provider, @code, @redirect_uri, @verifier)

      assert {:error, {:token_exchange_failed, 400}} = result

      # No fragment of the provider body may survive into the error term.
      rendered = inspect(result)
      refute rendered =~ canary
      refute rendered =~ "invalid_grant"
      refute rendered =~ "error_description"
    end
  end

  describe "security regression: transport byte bound reaches the OIDC path" do
    test "an oversized discovery body is halted at the transport" do
      # 8 KiB chunks, paced. A client that buffered the whole body would let all
      # 512 through; completed? == false is therefore the proof that the
      # transport was torn down early, with no OS-specific byte threshold.
      chunk = String.duplicate("x", 8_192)

      {issuer_url, server} =
        Server.start(%{
          "/.well-known/openid-configuration" =>
            {:paced_stream, [{"content-type", "application/json"}], chunk, 512, 5}
        })

      on_exit(fn -> Server.stop(server) end)

      provider = %{
        issuer: issuer_url,
        client_id: "arbor-test-client",
        allow_http: true
      }

      assert {:error, {:response_bytes_exceeded, 262_144}} =
               AuthCodeFlow.exchange_code(provider, @code, @redirect_uri, @verifier)

      report = Server.await(server)
      refute report.completed?
      assert report.chunks_sent < 512
    end
  end

  describe "security regression: same-origin token exchange still succeeds" do
    test "a valid same-origin provider accepts the empty verifier sentinel and returns the full body" do
      {issuer_url, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "authorization_endpoint" => "#{base}/authorize",
                   "token_endpoint" => "#{base}/token"
                 })},
              "/token" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "id_token" => "eyJ.header.payload",
                   "access_token" => "at-123",
                   "token_type" => "Bearer",
                   "expires_in" => 3600,
                   # An undeclared provider field must survive the round trip.
                   "id_token_expires_in" => 300
                 })}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      provider = %{issuer: issuer_url, client_id: "arbor-test-client", allow_http: true}

      assert {:ok, tokens} = AuthCodeFlow.exchange_code(provider, @code, @redirect_uri, "")

      assert tokens["id_token"] == "eyJ.header.payload"
      assert tokens["expires_in"] == 3600
      assert tokens["id_token_expires_in"] == 300
    end
  end

  describe "security regression: public boundary validation ordering" do
    test "rejects malformed scopes before discovery I/O" do
      bad_scope = String.duplicate("s", 129)

      provider = %{
        issuer: Server.closed_port_url(),
        client_id: "arbor-test-client",
        allow_http: true
      }

      assert {:error, {:invalid_params, :invalid_scopes}} =
               AuthCodeFlow.build_authorize_url(
                 provider,
                 @redirect_uri,
                 "state123",
                 scopes: [bad_scope]
               )
    end

    test "rejects malformed token-response keys before accepting oversized objects" do
      long_key = String.duplicate("k", 129)

      {issuer_url, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "authorization_endpoint" => "#{base}/authorize",
                   "token_endpoint" => "#{base}/token"
                 })},
              "/token" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{long_key => "value", "id_token" => "eyJ.header.payload"})}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      provider = %{issuer: issuer_url, client_id: "arbor-test-client", allow_http: true}

      assert {:error, {:invalid_token_response, :invalid_key}} =
               AuthCodeFlow.exchange_code(provider, @code, @redirect_uri, @verifier)
    end
  end

  describe "loopback request parsing regression" do
    test "coalesced request body is parsed without an artificial body-read timeout" do
      {base, server} =
        Server.start(%{
          "/token" => {:respond, 200, [{"content-type", "application/json"}], "{}"}
        })

      on_exit(fn -> Server.stop(server) end)

      %URI{port: port} = URI.parse(base)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      request =
        [
          "POST /token HTTP/1.1",
          "content-length: 4",
          "content-type: application/x-www-form-urlencoded",
          "",
          "abcd"
        ]
        |> Enum.join("\r\n")

      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = :gen_tcp.recv(socket, 0, 500)
      assert String.starts_with?(response, "HTTP/1.1 200")
      :ok = :gen_tcp.close(socket)

      report = Server.await(server)
      assert report.completed?
    end

    test "split request body does not require a coalesced write to parse correctly" do
      {base, server} =
        Server.start(%{
          "/token" => {:respond, 200, [{"content-type", "application/json"}], "{}"}
        })

      on_exit(fn -> Server.stop(server) end)

      %URI{port: port} = URI.parse(base)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      header =
        [
          "POST /token HTTP/1.1",
          "content-length: 4",
          "content-type: application/x-www-form-urlencoded",
          ""
        ]
        |> Enum.join("\r\n")

      :ok = :gen_tcp.send(socket, header <> "\r\n")
      :timer.sleep(50)
      :ok = :gen_tcp.send(socket, "abcd")

      assert {:ok, response} = :gen_tcp.recv(socket, 0, 500)
      assert String.starts_with?(response, "HTTP/1.1 200")
      :ok = :gen_tcp.close(socket)

      report = Server.await(server)
      assert report.completed?
    end
  end
end
