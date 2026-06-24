defmodule Arbor.Gateway.RouterSecurityTest do
  # async: false — drives the real Router pipeline (named RateLimiter ETS table,
  # app-env rate_limit override).
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias Arbor.Gateway.Router

  @moduletag :fast

  setup do
    if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
      :ets.delete(Arbor.Gateway.RateLimiter)
    end

    original = Application.get_env(:arbor_gateway, :rate_limit)

    on_exit(fn ->
      if original,
        do: Application.put_env(:arbor_gateway, :rate_limit, original),
        else: Application.delete_env(:arbor_gateway, :rate_limit)

      if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
        :ets.delete(Arbor.Gateway.RateLimiter)
      end
    end)

    :ok
  end

  defp call(conn), do: Router.call(conn, Router.init([]))

  describe "rate limiter ordering (codex rate-limit.gateway-auth-failures-before-limiter)" do
    test "security regression: FAILED auth attempts are rate-limited (limiter runs before auth)" do
      # Tight limit so we trip it quickly.
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 2, window_seconds: 60)

      # Unauthenticated POSTs to a non-health route. Pre-fix, require_auth halted
      # each with 401 BEFORE the rate limiter ran, so the limiter never counted
      # failed attempts and 429 was unreachable for unauthenticated traffic.
      statuses =
        for _ <- 1..3 do
          conn(:post, "/api/signals/ingest", Jason.encode!(%{a: 1}))
          |> put_req_header("content-type", "application/json")
          |> Map.put(:remote_ip, {10, 9, 8, 7})
          |> call()
          |> Map.get(:status)
        end

      # First requests are rejected by auth (401); once the per-IP count exceeds
      # the limit, the limiter rejects with 429 — which it can only do if it runs
      # ahead of the auth halt.
      assert 429 in statuses,
             "failed auth attempts must hit the rate limiter (429), got: #{inspect(statuses)}"
    end

    test "/health is never rate-limited (monitoring probes)" do
      Application.put_env(:arbor_gateway, :rate_limit, max_requests: 1, window_seconds: 60)

      statuses =
        for _ <- 1..5 do
          conn(:get, "/health")
          |> Map.put(:remote_ip, {10, 9, 8, 6})
          |> call()
          |> Map.get(:status)
        end

      assert Enum.all?(statuses, &(&1 == 200)),
             "health probes must not be throttled, got: #{inspect(statuses)}"
    end
  end

  describe "cached_body_reader (codex authn.signed-request-body-parser-order)" do
    test "returns the raw body cached by SignedRequestAuth (so parsing binds the verified bytes)" do
      raw = ~s({"hello":"world"})
      conn = conn(:post, "/api/x", raw) |> Plug.Conn.assign(:raw_body, raw)

      assert {:ok, ^raw, _conn} = Router.cached_body_reader(conn, [])
    end

    test "falls back to reading the stream when no signature cached the body" do
      raw = ~s({"unsigned":true})
      conn = conn(:post, "/api/x", raw)

      assert {:ok, ^raw, _conn} = Router.cached_body_reader(conn, [])
    end

    test "an unsigned JSON POST still parses cleanly through the router (no parse error)" do
      # Parsing now runs after signed-auth; the body_reader fallback must keep
      # JSON parsing working for ordinary (unsigned) requests. A Plug.Parsers
      # failure would surface as 400 — the request may be rejected by auth (401)
      # or hit the route (503 if a subsystem is down), but must NOT 400 on parse.
      status =
        conn(:post, "/api/signals/ingest", Jason.encode!(%{event: "x"}))
        |> put_req_header("content-type", "application/json")
        |> Map.put(:remote_ip, {10, 9, 8, 5})
        |> call()
        |> Map.get(:status)

      refute status == 400,
             "JSON body failed to parse in the new pipeline order (got 400)"

      assert is_integer(status), "request did not complete"
    end
  end
end
