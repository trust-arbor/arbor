defmodule Arbor.Security.OIDC.DeviceFlowTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.OIDC.DeviceFlow
  alias Arbor.Security.LoopbackHTTPServer, as: Server

  @moduletag :fast

  describe "start/1" do
    test "rejects conflicting scope and scopes options at the public boundary" do
      assert {:error, {:invalid_scope_options, :scope_and_scopes}} =
               DeviceFlow.start(%{
                 issuer: "https://idp.example",
                 client_id: "test-client",
                 scope: "openid",
                 scopes: ["email"]
               })
    end

    test "returns error when issuer is unreachable" do
      config = %{
        issuer: "https://nonexistent.arbor-test-oidc.invalid",
        client_id: "test-client"
      }

      assert {:error, {:http_request_failed, _}} = DeviceFlow.start(config)
    end

    test "uses dedicated discovery timeout and byte budget keys" do
      {issuer, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "device_authorization_endpoint" => "#{base}/device"
                 })},
              "/device" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "device_code" => "dev-1",
                   "interval" => 5,
                   "expires_in" => 600,
                   "user_code" => "ABCD-EFGH",
                   "verification_uri" => "#{base}/verify"
                 })}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      config = %{
        issuer: issuer,
        client_id: "test-client",
        allow_http: true,
        discovery_timeout_ms: 1_000,
        discovery_max_response_bytes: 64_000,
        timeout_ms: 120_000
      }

      assert {:ok, _device_response} = DeviceFlow.start(config)
    end

    test "enforces dedicated discovery_max_response_bytes before token request" do
      {issuer, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "device_authorization_endpoint" => "#{base}/device"
                 })}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      config = %{
        issuer: issuer,
        client_id: "test-client",
        allow_http: true,
        discovery_max_response_bytes: 16
      }

      assert {:error, {:response_bytes_exceeded, 16}} = DeviceFlow.start(config)
    end
  end

  describe "refresh/2" do
    test "returns error when issuer is unreachable" do
      config = %{
        issuer: "https://nonexistent.arbor-test-oidc.invalid",
        client_id: "test-client"
      }

      assert {:error, {:http_request_failed, _}} =
               DeviceFlow.refresh(config, "fake-refresh-token")
    end

    test "returns body-free errors when token endpoint rejects refresh" do
      canary = "REFRESH-REJECTION-#{System.unique_integer([:positive])}"

      {issuer, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{"issuer" => base, "token_endpoint" => "#{base}/token"})},
              "/token" =>
                {:respond, 400, [{"content-type", "application/json"}],
                 Jason.encode!(%{"error" => "invalid_grant", "error_description" => canary})}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      config = %{issuer: issuer, client_id: "test-client", allow_http: true}

      result = DeviceFlow.refresh(config, "fake-refresh-token")

      assert {:error, {:token_request_failed, 400}} = result
      refute inspect(result) =~ canary
    end
  end

  describe "poll/2" do
    test "requires expires_in from the device response" do
      config = %{
        issuer: "https://idp.example",
        client_id: "test-client",
        endpoints: %{token_endpoint: "https://idp.example/token"}
      }

      assert {:error, {:invalid_params, {:expires_in, :invalid_integer}}} =
               DeviceFlow.poll(config, %{"device_code" => "device-code", "interval" => 5})
    end

    test "returns body-free errors when the token endpoint rejects authorization" do
      canary = "POLL-REJECTION-#{System.unique_integer([:positive])}"

      {issuer, server} =
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
                   "device_code" => "dev-1",
                   "interval" => 1,
                   "expires_in" => 600,
                   "user_code" => "ABCD-EFGH",
                   "verification_uri" => "#{base}/verify"
                 })},
              "/token" =>
                {:respond, 400, [{"content-type", "application/json"}],
                 Jason.encode!(%{"error" => "invalid_grant", "error_description" => canary})}
            }
          end,
          connections: 4
        )

      on_exit(fn -> Server.stop(server) end)

      config = %{issuer: issuer, client_id: "test-client", allow_http: true}

      {:ok, device_response} = DeviceFlow.start(config)
      result = DeviceFlow.poll(config, device_response)

      assert {:error, {:token_request_failed, 400}} = result
      refute inspect(result) =~ canary
    end
  end
end
