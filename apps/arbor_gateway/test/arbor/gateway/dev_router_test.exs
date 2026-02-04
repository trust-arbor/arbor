defmodule Arbor.Gateway.Dev.RouterTest do
  use ExUnit.Case, async: true
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
    test "evaluates simple expressions from localhost" do
      conn =
        conn(:post, "/eval", Jason.encode!(%{code: "1 + 2"}))
        |> put_req_header("content-type", "application/json")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert body["result"] == "3"
    end

    test "returns error for invalid code" do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        conn =
          conn(:post, "/eval", Jason.encode!(%{code: "undefined_var + 1"}))
          |> put_req_header("content-type", "application/json")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> Router.call(@opts)

        send(self(), {:dev_eval_conn, conn})
      end)

      assert_received {:dev_eval_conn, conn}

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "error"
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
