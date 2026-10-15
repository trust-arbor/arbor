defmodule Arbor.Gateway.BridgeAuthorizeToolRouteSecurityRegressionTest do
  @moduledoc """
  Security regression: POST /api/bridge/authorize_tool must not be a live HTTP
  side door.

  The Claude Code PreToolUse hook that called this route
  (`arbor_bridge_authorize.sh`) was removed 2026-08-26 after it failed open on
  every tool call once `/api/*` gained auth (2026-02-07). Harness authorization
  is the signed-MCP / ACP path. The unused Plug route was still forwarded from
  `Arbor.Gateway.Router`. This test fails on that main (authenticated POST
  returns 200 with a decision JSON) and passes once the route is gone (404).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias Arbor.Gateway.Router

  @moduletag :fast
  @moduletag :security_regression

  @api_key "bridge-route-regression-key"
  @body Jason.encode!(%{
          session_id: "unused-http-side-door",
          tool_name: "Read",
          tool_input: %{file_path: "/tmp/unused"},
          cwd: "/tmp"
        })

  setup do
    if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
      :ets.delete(Arbor.Gateway.RateLimiter)
    end

    previous_key = Application.get_env(:arbor_gateway, :api_key)
    previous_env = System.get_env("ARBOR_GATEWAY_API_KEY")
    previous_limit = Application.get_env(:arbor_gateway, :rate_limit)

    Application.put_env(:arbor_gateway, :api_key, @api_key)
    System.delete_env("ARBOR_GATEWAY_API_KEY")

    on_exit(fn ->
      case previous_key do
        nil -> Application.delete_env(:arbor_gateway, :api_key)
        key -> Application.put_env(:arbor_gateway, :api_key, key)
      end

      case previous_env do
        nil -> System.delete_env("ARBOR_GATEWAY_API_KEY")
        value -> System.put_env("ARBOR_GATEWAY_API_KEY", value)
      end

      if previous_limit,
        do: Application.put_env(:arbor_gateway, :rate_limit, previous_limit),
        else: Application.delete_env(:arbor_gateway, :rate_limit)

      if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
        :ets.delete(Arbor.Gateway.RateLimiter)
      end
    end)

    :ok
  end

  test "security regression: authenticated POST /api/bridge/authorize_tool is gone (404)" do
    conn =
      conn(:post, "/api/bridge/authorize_tool", @body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-api-key", @api_key)
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Router.call(Router.init([]))

    assert conn.status == 404
    refute conn.resp_body =~ "decision"
  end

  test "security regression: the unused HTTP bridge handler module is gone" do
    assert {:error, :nofile} = Code.ensure_compiled(Arbor.Gateway.Bridge.Router)
    assert {:error, :nofile} = Code.ensure_compiled(Arbor.Gateway.Bridge.RegistrationAuthority)
    assert {:error, :nofile} = Code.ensure_compiled(Arbor.Gateway.Schemas.Bridge)
  end
end
