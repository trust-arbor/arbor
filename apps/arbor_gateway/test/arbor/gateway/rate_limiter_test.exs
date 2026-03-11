defmodule Arbor.Gateway.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Arbor.Gateway.RateLimiter

  @moduletag :fast

  # RateLimiter uses a named ETS table, so we can't run async.
  # Clean up between tests to avoid cross-contamination.

  setup do
    # Delete the ETS table if it exists from a previous test
    if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
      :ets.delete(Arbor.Gateway.RateLimiter)
    end

    # Restore any app env changes
    original = Application.get_env(:arbor_gateway, :rate_limit)
    on_exit(fn ->
      if original do
        Application.put_env(:arbor_gateway, :rate_limit, original)
      else
        Application.delete_env(:arbor_gateway, :rate_limit)
      end

      # Clean env var
      System.delete_env("GATEWAY_RATE_LIMIT")
    end)

    :ok
  end

  defp make_conn(ip \\ {127, 0, 0, 1}) do
    Plug.Test.conn(:get, "/")
    |> Map.put(:remote_ip, ip)
  end

  describe "init/1" do
    test "passes opts through" do
      assert RateLimiter.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2 under limit" do
    test "allows requests under the limit and sets rate limit headers" do
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 10, window_seconds: 60)

      conn = make_conn() |> RateLimiter.call([])

      refute conn.halted
      assert Plug.Conn.get_resp_header(conn, "x-ratelimit-limit") == ["10"]

      remaining = Plug.Conn.get_resp_header(conn, "x-ratelimit-remaining")
      assert remaining == ["9"]
    end

    test "decrements remaining count on successive requests" do
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 5, window_seconds: 60)

      conn1 = make_conn() |> RateLimiter.call([])
      conn2 = make_conn() |> RateLimiter.call([])
      conn3 = make_conn() |> RateLimiter.call([])

      assert Plug.Conn.get_resp_header(conn1, "x-ratelimit-remaining") == ["4"]
      assert Plug.Conn.get_resp_header(conn2, "x-ratelimit-remaining") == ["3"]
      assert Plug.Conn.get_resp_header(conn3, "x-ratelimit-remaining") == ["2"]
    end
  end

  describe "call/2 at/over limit" do
    test "returns 429 when limit is exceeded" do
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 2, window_seconds: 60)

      _conn1 = make_conn() |> RateLimiter.call([])
      _conn2 = make_conn() |> RateLimiter.call([])
      conn3 = make_conn() |> RateLimiter.call([])

      assert conn3.halted
      assert conn3.status == 429
      assert Plug.Conn.get_resp_header(conn3, "retry-after") == ["60"]

      body = Jason.decode!(conn3.resp_body)
      assert body["error"] == "rate_limit_exceeded"
      assert body["retry_after"] == 60
    end

    test "different IPs have independent limits" do
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 1, window_seconds: 60)

      conn_a = make_conn({10, 0, 0, 1}) |> RateLimiter.call([])
      conn_b = make_conn({10, 0, 0, 2}) |> RateLimiter.call([])

      refute conn_a.halted
      refute conn_b.halted
    end
  end

  describe "config override via environment variable" do
    test "GATEWAY_RATE_LIMIT overrides config" do
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 1000, window_seconds: 60)
      System.put_env("GATEWAY_RATE_LIMIT", "1")

      _conn1 = make_conn({192, 168, 1, 1}) |> RateLimiter.call([])
      conn2 = make_conn({192, 168, 1, 1}) |> RateLimiter.call([])

      assert conn2.halted
      assert conn2.status == 429
    end
  end

  describe "cleanup/0" do
    test "removes expired buckets" do
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 100, window_seconds: 60)

      # Make a request to create the table and a bucket
      _conn = make_conn() |> RateLimiter.call([])

      # Insert an old bucket (window_key far in the past)
      table = Arbor.Gateway.RateLimiter
      :ets.insert(table, {{"old_ip", 0}, 50})

      # cleanup should remove old buckets
      assert :ok = RateLimiter.cleanup()

      # Old bucket should be gone
      assert :ets.lookup(table, {"old_ip", 0}) == []
    end

    test "returns :ok when table does not exist" do
      # Table was deleted in setup
      assert :ok = RateLimiter.cleanup()
    end
  end
end
