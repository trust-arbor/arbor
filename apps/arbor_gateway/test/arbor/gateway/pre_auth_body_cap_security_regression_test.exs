defmodule Arbor.Gateway.PreAuthBodyCapSecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check item AI; re-land of closed PR #34):
  `SignedRequestAuth` called `Plug.Conn.read_body/1` with Plug's 8 MB default,
  so an unauthenticated body was buffered before the Ed25519 check.

  Post-fix: the pre-auth read uses an explicit configurable `:length` /
  `:read_length` of 1 MiB. A badly signed POST of cap+1 bytes is 413 without
  reading past the cap plus one chunk. A valid signed request under the cap
  still succeeds. Post-auth parser / ExMCP limits are unchanged.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Router
  alias Arbor.Gateway.SignedRequestAuth
  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression

  @max_body_bytes 1_048_576
  @oversized_body_bytes @max_body_bytes + 1

  defmodule TrackingAdapter do
    @moduledoc false
    @behaviour Plug.Conn.Adapter

    def read_req_body(state, opts) do
      length = Keyword.get(opts, :length, 8_000_000)
      read_length = Keyword.get(opts, :read_length, 1_000_000)
      {tag, data, new_state} = Plug.Adapters.Test.Conn.read_req_body(state, opts)

      send(
        state.owner,
        {:body_read,
         %{
           length: length,
           read_length: read_length,
           bytes: byte_size(data),
           tag: tag
         }}
      )

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
    previous_max = Application.get_env(:arbor_gateway, :signed_request_max_body_bytes)
    previous_read = Application.get_env(:arbor_gateway, :signed_request_read_length)
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
      restore_env(:signed_request_max_body_bytes, previous_max)
      restore_env(:signed_request_read_length, previous_read)
      restore_system_env("ARBOR_GATEWAY_API_KEY", previous_env)

      if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
        :ets.delete(Arbor.Gateway.RateLimiter)
      end
    end)

    :ok
  end

  test "security regression: badly signed POST of cap+1 bytes is 413 without reading past the cap plus one chunk" do
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
    chunk = max_read_length(reads)

    assert conn.status == 413,
           "oversized badly signed POST must be 413, got #{inspect_conn(conn)}"

    assert reads != [], "SignedRequestAuth never read the body"

    assert Enum.all?(reads, fn %{length: length} -> length <= @max_body_bytes end),
           "body read used Plug's default 8 MB window: #{inspect(reads)}"

    assert buffered <= @max_body_bytes + chunk,
           "buffered #{buffered} bytes past the cap plus one chunk (#{chunk}): #{inspect(reads)}"

    cached = Map.get(conn.assigns, :raw_body, "")
    assert is_binary(cached)
    assert byte_size(cached) <= @max_body_bytes
  end

  test "security regression: a valid signed request under the cap still succeeds" do
    {:ok, identity} = Security.generate_identity(name: "pre-auth-body-cap-under-cap")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    on_exit(fn ->
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    path = "/api/signals/claude/session_start"
    body = Jason.encode!(%{session_id: "pre-auth-body-cap"})
    assert byte_size(body) < @max_body_bytes

    conn =
      :post
      |> conn(path, body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", signed_header(identity, "POST", path, body))
      |> Map.put(:remote_ip, {10, 22, 10, 19})
      |> call()

    assert conn.status == 202,
           "valid signed request under the cap must succeed, got #{inspect_conn(conn)}"

    assert conn.assigns[:signed_request_authenticated] == true
    assert conn.assigns[:agent_id] == identity.agent_id
    assert Jason.decode!(conn.resp_body)["status"] == "accepted"
  end

  test "security regression: default pre-auth body cap is 1 MiB" do
    assert function_exported?(SignedRequestAuth, :max_body_bytes, 0)
    assert SignedRequestAuth.max_body_bytes() == @max_body_bytes
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

  defp max_read_length([]), do: 0

  defp max_read_length(reads) do
    reads
    |> Enum.map(&Map.get(&1, :read_length, 0))
    |> Enum.max()
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

  defp signed_header(identity, method, path, body) do
    {:ok, signed} =
      SignedRequest.sign(
        method <> "\n" <> path <> "\n" <> body,
        identity.agent_id,
        identity.private_key
      )

    %{
      "agent_id" => signed.agent_id,
      "timestamp" => DateTime.to_iso8601(signed.timestamp),
      "nonce" => Base.encode64(signed.nonce),
      "signature" => Base.encode64(signed.signature)
    }
    |> Jason.encode!()
    |> Base.encode64(padding: false)
    |> then(&("Signature " <> &1))
  end

  defp inspect_conn(conn) do
    "status=#{inspect(conn.status)} body=#{inspect(conn.resp_body)}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_gateway, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
