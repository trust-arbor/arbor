defmodule Arbor.Security.OIDC.DeviceFlowSecurityRegressionTest do
  @moduledoc """
  Public behavioural security regressions for the OAuth device-flow path.

  Each test calls `Arbor.Security.authenticate_oidc/1` directly and is keyed to
  the historical bug pattern: trust-policy regressions and response-body leaks.
  """

  use ExUnit.Case, async: true

  alias Arbor.Security
  alias Arbor.Security.LoopbackHTTPServer, as: Server

  @moduletag :fast
  @moduletag :security

  describe "security regression: untrusted device endpoint refusal" do
    test "returns origin-mismatch error before POSTing any token credentials" do
      {foreign_url, foreign_server} =
        Server.start(
          %{
            "/device" => {:respond, 200, [{"content-type", "application/json"}], "{}"},
            "/token" => {:respond, 200, [{"content-type", "application/json"}], "{}"}
          },
          connections: 2
        )

      {issuer_url, issuer_server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "device_authorization_endpoint" => "#{foreign_url}/device",
                   "token_endpoint" => "#{foreign_url}/token"
                 })}
            }
          end,
          connections: 2
        )

      on_exit(fn ->
        Server.stop(foreign_server)
        Server.stop(issuer_server)
      end)

      result =
        Security.authenticate_oidc(%{
          issuer: issuer_url,
          client_id: "security-client",
          allow_http: true
        })

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} = result

      foreign_report = Server.await(foreign_server)
      assert foreign_report.requests == []
    end
  end

  describe "security regression: token poll response body must not leak" do
    test "returns token status only when poll endpoint returns provider body errors" do
      canary = "OIDC-DEVICE-POLL-CANARY-#{System.unique_integer([:positive])}"

      {issuer_url, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "device_authorization_endpoint" => "#{base}/device",
                   "token_endpoint" => "#{base}/token"
                 })},
              "/device" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "device_code" => "test-device-code",
                   "interval" => 1,
                   "expires_in" => 600,
                   "user_code" => "TEST-ABCD",
                   "verification_uri" => "#{base}/verify"
                 })},
              "/token" =>
                {:respond, 400, [{"content-type", "application/json"}],
                 Jason.encode!(%{"error" => "invalid_request", "error_description" => canary})}
            }
          end,
          connections: 4
        )

      on_exit(fn -> Server.stop(server) end)

      result =
        Security.authenticate_oidc(%{
          issuer: issuer_url,
          client_id: "security-client",
          allow_http: true
        })

      assert {:error, {:token_request_failed, 400}} = result
      refute inspect(result) =~ canary
    end
  end
end
