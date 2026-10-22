defmodule Arbor.Gateway.PreAuthBodyCapSecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check group Q, 2026-10-22): pre-auth body
  buffering exceeded ExMCP's 1 MiB cap, and unsigned non-/mcp routes parsed
  JSON before authentication.

  `SignedRequestAuth` called `Plug.Conn.read_body/1` with Plug's 8 MB default,
  so a 2 MB signed request was fully buffered before the signature check.
  `:conditional_parsers` then ran before `:require_auth_unless_health` for
  non-/mcp routes, so an unauthenticated JSON POST was decoded first.

  Post-fix: signed reads and `Plug.Parsers` share a 1_048_576-byte cap, a
  2 MB signed request is refused with 413 without reading past that cap, and
  unsigned non-/mcp requests authenticate before the body is parsed.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.Gateway.Router

  @moduletag :fast
  @moduletag :security_regression

  @max_body_bytes 1_048_576
  @oversized_body_bytes 2 * 1024 * 1024
  @probe_key "must_not_parse_before_auth"
  @probe_value "pre-auth-body-cap-probe"

  defmodule TrackingAdapter do
    @moduledoc false
    @behaviour Plug.Conn.Adapter

    def read_req_body(state, opts) do
      length = Keyword.get(opts, :length, 8_000_000)
      {tag, data, new_state} = Plug.Adapters.Test.Conn.read_req_body(state, opts)

      send(state.owner, {:body_read, %{length: length, bytes: byte_size(data), tag: tag}})

      {tag, data, new_state}
    end

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn

    defdelegate send_file(state, status, headers, path, offset, length),
      to: Plug.Adapters.Test.Conn

    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate chunk(state, body), to: Plug.Adapters.Test.Conn
    defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
    defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn
  end

  setup do
    previous_key = Application.get_env(:arbor_gateway, :api_key)
    previous_limit = Application.get_env(:arbor_gateway, :rate_limit)
    previous_env = System.get_env("ARBOR_GATEWAY_API_KEY")

    Application.put_env(:arbor_gateway, :api_key, "pre-auth-body-cap-test-key")
    Application.put_env(:arbor_gateway, :rate_limit, max_requests: 1_000, window_seconds: 60)
    System.delete_env("ARBOR_GATEWAY_API_KEY")

    if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
      :ets.delete(Arbor.Gateway.RateLimiter)
    end

    on_exit(fn ->
      restore_env(:api_key, previous_key)
      restore_env(:rate_limit, previous_limit)
      restore_system_env("ARBOR_GATEWAY_API_KEY", previous_env)

      if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
        :ets.delete(Arbor.Gateway.RateLimiter)
      end
    end)

    :ok
  end

  test "security regression: a 2 MB signed request is 413 without buffering past 1 MiB" do
    body = String.duplicate("x", @oversized_body_bytes)
    assert byte_size(body) == @oversized_body_bytes

    conn =
      :post
      |> conn("/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Signature #{well_formed_envelope()}")
      |> track_body_reads()
      |> Map.put(:remote_ip, {10, 22, 10, 17})
      |> call()

    reads = drain_body_reads()
    buffered = Enum.reduce(reads, 0, fn %{bytes: bytes}, acc -> acc + bytes end)

    assert conn.status == 413,
           "oversized signed request must be 413, got #{inspect_conn(conn)}"

    assert reads != [], "SignedRequestAuth never read the body"

    assert Enum.all?(reads, fn %{length: length} -> length <= @max_body_bytes end),
           "body read used Plug's default 8 MB window: #{inspect(reads)}"

    assert buffered <= @max_body_bytes,
           "buffered #{buffered} bytes past the 1 MiB cap: #{inspect(reads)}"

    cached = Map.get(conn.assigns, :raw_body, "")
    assert is_binary(cached)
    assert byte_size(cached) <= @max_body_bytes
  end

  test "security regression: unauthenticated JSON POST is 401 without parsing the body" do
    payload = Jason.encode!(%{@probe_key => @probe_value})

    conn =
      :post
      |> conn("/api/signals/ingest", payload)
      |> put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, {10, 22, 10, 18})
      |> call()

    assert conn.status == 401,
           "unauthenticated non-health POST must be 401, got #{inspect_conn(conn)}"

    assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params

    refute match?(%{@probe_key => @probe_value}, conn.body_params)
    refute match?(%{@probe_key => @probe_value}, conn.params)
  end

  defp call(conn), do: Router.call(conn, Router.init([]))

  defp track_body_reads(%{adapter: {Plug.Adapters.Test.Conn, state}} = conn) do
    %{conn | adapter: {TrackingAdapter, state}}
  end

  defp drain_body_reads(acc \\ []) do
    receive do
      {:body_read, info} -> drain_body_reads([info | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp well_formed_envelope do
    %{
      "agent_id" => "agent_" <> String.duplicate("ab", 32),
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
      "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
    }
    |> Jason.encode!()
    |> Base.encode64(padding: false)
  end

  defp inspect_conn(conn) do
    "status=#{inspect(conn.status)} body=#{inspect(conn.resp_body)}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_gateway, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
