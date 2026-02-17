defmodule Arbor.Gateway.AuthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Auth

  @moduletag :fast

  @opts Auth.init([])

  # ===========================================================================
  # API key configured — valid key
  # ===========================================================================

  describe "with configured API key via Bearer token" do
    setup do
      previous = Application.get_env(:arbor_gateway, :api_key)
      Application.put_env(:arbor_gateway, :api_key, "test-secret-key-123")
      on_exit(fn -> Application.put_env(:arbor_gateway, :api_key, previous) end)
      :ok
    end

    test "allows request with correct Bearer token" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer test-secret-key-123")
        |> Auth.call(@opts)

      refute conn.halted
    end

    test "rejects request with incorrect Bearer token" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer wrong-key")
        |> Auth.call(@opts)

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Unauthorized"
      assert body["detail"] =~ "Invalid API key"
    end

    test "rejects request with no authorization header" do
      conn =
        conn(:get, "/")
        |> Auth.call(@opts)

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Unauthorized"
      assert body["detail"] =~ "Missing API key"
    end

    test "trims whitespace from Bearer token" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer test-secret-key-123  ")
        |> Auth.call(@opts)

      refute conn.halted
    end
  end

  # ===========================================================================
  # API key configured — x-api-key header
  # ===========================================================================

  describe "with configured API key via x-api-key header" do
    setup do
      previous = Application.get_env(:arbor_gateway, :api_key)
      Application.put_env(:arbor_gateway, :api_key, "test-secret-key-456")
      on_exit(fn -> Application.put_env(:arbor_gateway, :api_key, previous) end)
      :ok
    end

    test "allows request with correct x-api-key header" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", "test-secret-key-456")
        |> Auth.call(@opts)

      refute conn.halted
    end

    test "rejects request with incorrect x-api-key header" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", "wrong-key")
        |> Auth.call(@opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "trims whitespace from x-api-key header" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", "test-secret-key-456  ")
        |> Auth.call(@opts)

      refute conn.halted
    end

    test "prefers Authorization Bearer over x-api-key when both present" do
      # When Authorization header is present, x-api-key is not checked
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer test-secret-key-456")
        |> put_req_header("x-api-key", "wrong-key")
        |> Auth.call(@opts)

      refute conn.halted
    end
  end

  # ===========================================================================
  # No API key configured
  # ===========================================================================

  describe "without configured API key" do
    setup do
      previous = Application.get_env(:arbor_gateway, :api_key)
      previous_env = System.get_env("ARBOR_GATEWAY_API_KEY")
      Application.put_env(:arbor_gateway, :api_key, nil)
      System.delete_env("ARBOR_GATEWAY_API_KEY")

      on_exit(fn ->
        Application.put_env(:arbor_gateway, :api_key, previous)
        if previous_env, do: System.put_env("ARBOR_GATEWAY_API_KEY", previous_env)
      end)

      :ok
    end

    test "returns 503 when no API key is configured" do
      conn =
        conn(:get, "/")
        |> Auth.call(@opts)

      assert conn.halted
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "not configured"
      assert body["detail"] =~ "ARBOR_GATEWAY_API_KEY"
    end

    test "returns 503 even with valid-looking auth header" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer some-key")
        |> Auth.call(@opts)

      assert conn.halted
      assert conn.status == 503
    end
  end

  # ===========================================================================
  # Response format
  # ===========================================================================

  describe "response format" do
    setup do
      previous = Application.get_env(:arbor_gateway, :api_key)
      Application.put_env(:arbor_gateway, :api_key, "test-key")
      on_exit(fn -> Application.put_env(:arbor_gateway, :api_key, previous) end)
      :ok
    end

    test "rejection response has JSON content type" do
      conn =
        conn(:get, "/")
        |> Auth.call(@opts)

      assert {"content-type", content_type} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert content_type =~ "application/json"
    end
  end
end
