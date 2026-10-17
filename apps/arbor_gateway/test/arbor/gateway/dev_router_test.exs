defmodule Arbor.Gateway.Dev.RouterTest do
  # Not async: setup toggles the global :dev_endpoints app env, and another
  # module flips it too, so a concurrent on_exit restore races the request.
  use ExUnit.Case, async: false
  @moduletag :fast
  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Dev.Router

  setup do
    # Enable dev endpoints for testing
    previous = Application.get_env(:arbor_gateway, :dev_endpoints)
    Application.put_env(:arbor_gateway, :dev_endpoints, true)
    on_exit(fn -> Application.put_env(:arbor_gateway, :dev_endpoints, previous) end)
    :ok
  end

  @opts Router.init([])

  describe "GET /info" do
    test "returns system info from localhost" do
      conn =
        conn(:get, "/info")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_integer(body["processes"])
      assert is_float(body["memory_mb"]) or is_integer(body["memory_mb"])
      assert is_list(body["applications"])
    end
  end

  describe "POST /eval" do
    test "refuses HTTP eval of request bodies from localhost" do
      conn =
        conn(:post, "/eval", Jason.encode!(%{code: "1 + 2"}))
        |> put_req_header("content-type", "application/json")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "forbidden"
      assert body["reason"] =~ "eval"
      refute Map.has_key?(body, "result")
    end
  end

  describe "GET /config/:app" do
    test "returns config for known arbor app" do
      conn =
        conn(:get, "/config/arbor_gateway")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["app"] == "arbor_gateway"
    end

    test "rejects unknown app" do
      conn =
        conn(:get, "/config/some_random_app")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end
end
