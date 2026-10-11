defmodule Arbor.Gateway.AuthEnvPrecedenceSecurityRegressionTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :fast

  alias Arbor.Gateway.Auth

  @opts Auth.init([])

  # 2026-10-11 cross-library review F-019: `Application.get_env(:api_key) ||
  # System.get_env(...)` let the committed dev literal (`arbor-dev-key`) shadow
  # an operator-set ARBOR_GATEWAY_API_KEY, so the key could not be rotated.
  setup do
    prev_app = Application.get_env(:arbor_gateway, :api_key)
    prev_env = System.get_env("ARBOR_GATEWAY_API_KEY")

    Application.put_env(:arbor_gateway, :api_key, "committed-dev-key")
    System.put_env("ARBOR_GATEWAY_API_KEY", "operator-env-key")

    on_exit(fn ->
      case prev_app do
        nil -> Application.delete_env(:arbor_gateway, :api_key)
        v -> Application.put_env(:arbor_gateway, :api_key, v)
      end

      case prev_env do
        nil -> System.delete_env("ARBOR_GATEWAY_API_KEY")
        v -> System.put_env("ARBOR_GATEWAY_API_KEY", v)
      end
    end)

    :ok
  end

  test "security regression (F-019): the environment key wins over the committed config literal" do
    rejected =
      conn(:get, "/api/signals/claude/x")
      |> put_req_header("x-api-key", "committed-dev-key")
      |> Auth.call(@opts)

    assert rejected.halted
    assert rejected.status == 401

    accepted =
      conn(:get, "/api/signals/claude/x")
      |> put_req_header("x-api-key", "operator-env-key")
      |> Auth.call(@opts)

    refute accepted.halted
  end
end
