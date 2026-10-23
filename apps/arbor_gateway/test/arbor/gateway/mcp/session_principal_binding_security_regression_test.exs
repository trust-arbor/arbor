defmodule Arbor.Gateway.MCP.SessionPrincipalBindingSecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check group M, 2026-10-21): MCP Streamable
  HTTP / legacy SSE sessions were not bound to the authenticated caller.

  `@mcp_http_init_opts` omitted ExMCP.HttpPlug's `:principal_id` resolver, so
  session metadata stored `principal_id: nil`. `session_identity_matches?/2`
  treats a nil binding as a match for any later caller. An authenticated
  agent that merely presents another agent's `mcp-session-id` could therefore
  attach over GET/SSE (closing the owner's stream and replaying up to 1000
  buffered events, including tool results in legacy mode), POST, or DELETE.

  This is the same class as GHSA-953h-535j-jg2v (Envoy AI Gateway session
  resume skips the subject check). Tool authorization is still checked per
  request against the caller's own identity; the hole is session attach and
  event replay.

  Pre-fix: agent B's GET/SSE, POST, and DELETE with A's session id succeed
  (GET streams / POST 200 / DELETE 204) and can replay A's buffered events.
  Post-fix: those calls are refused as an unknown session, no events are
  replayed, and A's own reconnect still works.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Router
  alias Arbor.Security
  alias ExMCP.HttpPlug.SessionRegistry
  alias ExMCP.SessionManager

  @moduletag :fast

  @api_key "session-principal-binding-api-key"
  @secret_event "SECRET_TOOL_RESULT_AGENT_A_MUST_NOT_REPLAY"
  @attach_timeout_ms 1_500

  setup do
    previous_key = Application.get_env(:arbor_gateway, :api_key)
    previous_limit = Application.get_env(:arbor_gateway, :rate_limit)
    Application.put_env(:arbor_gateway, :api_key, @api_key)
    Application.put_env(:arbor_gateway, :rate_limit, max_requests: 1_000, window_seconds: 60)

    if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
      :ets.delete(Arbor.Gateway.RateLimiter)
    end

    agent_a = register_agent!("session-owner")
    agent_b = register_agent!("session-attacker")

    on_exit(fn ->
      restore_env(:api_key, previous_key)
      restore_env(:rate_limit, previous_limit)

      if :ets.whereis(Arbor.Gateway.RateLimiter) != :undefined do
        :ets.delete(Arbor.Gateway.RateLimiter)
      end

      _ = Security.deregister_identity_fixture(agent_a.agent_id)
      _ = Security.deregister_identity_fixture(agent_b.agent_id)
    end)

    %{agent_a: agent_a, agent_b: agent_b}
  end

  test "security regression: another agent cannot attach to or replay an MCP session", %{
    agent_a: agent_a,
    agent_b: agent_b
  } do
    {session_id, init_conn} = initialize_session!(agent_a)
    refute_replayed(init_conn)

    assert {:ok, _event} =
             SessionManager.append_event(session_id, "message", %{
               "role" => "tool",
               "content" => @secret_event
             })

    owner_stream = start_owner_sse_stream(agent_a, session_id)
    owner_handler = wait_for_sse_handler!(session_id)

    b_get = await_request(fn -> signed_get_sse(agent_b, session_id) end)

    assert_refused_attach(b_get, "GET/SSE")
    refute_replayed(b_get)

    assert Process.alive?(owner_handler),
           "agent B's GET/SSE must not close the owner's stream"

    assert {:ok, ^owner_handler} = SessionRegistry.lookup(session_id)

    b_post = signed_post(agent_b, session_id, tools_list_body(20))
    assert_refused_attach(b_post, "POST")
    refute_replayed(b_post)

    b_delete = signed_delete(agent_b, session_id)
    assert_refused_attach(b_delete, "DELETE")
    refute_replayed(b_delete)

    assert {:ok, session} = SessionManager.get_session(session_id)
    assert session.status == :active

    events = SessionManager.replay_events_after(session_id, nil)
    assert is_list(events)
    assert Enum.any?(events, fn event -> event_mentions_secret?(event) end)

    owner_post = signed_post(agent_a, session_id, tools_list_body(21))
    assert owner_post.status == 200, "owner POST reconnect failed: #{inspect_conn(owner_post)}"
    refute_replayed(owner_post)

    assert {:ok, ^owner_handler} = SessionRegistry.lookup(session_id)
    assert Process.alive?(owner_handler)

    stop_owner_sse_stream(owner_stream)
  end

  test "security regression: an API-key caller cannot attach to an agent session", %{
    agent_a: agent_a
  } do
    {session_id, _init_conn} = initialize_session!(agent_a)

    assert {:ok, _event} =
             SessionManager.append_event(session_id, "message", %{
               "role" => "tool",
               "content" => @secret_event
             })

    api_get = await_request(fn -> api_key_get_sse(session_id) end)
    assert_refused_attach(api_get, "API-key GET/SSE")
    refute_replayed(api_get)

    api_post = api_key_post(session_id, tools_list_body(30))
    assert_refused_attach(api_post, "API-key POST")
    refute_replayed(api_post)

    api_delete = api_key_delete(session_id)
    assert_refused_attach(api_delete, "API-key DELETE")
    refute_replayed(api_delete)

    owner_post = signed_post(agent_a, session_id, tools_list_body(31))
    assert owner_post.status == 200, "owner POST reconnect failed: #{inspect_conn(owner_post)}"
  end

  test "API-key callers still get a stateful session bound to a key fingerprint" do
    init_conn = api_key_post(nil, initialize_body(40))
    assert init_conn.status == 200, "API-key initialize failed: #{inspect_conn(init_conn)}"

    session_id = session_id!(init_conn)
    reconnect = api_key_post(session_id, tools_list_body(41))

    assert reconnect.status == 200,
           "API-key reconnect with the same key failed: #{inspect_conn(reconnect)}"
  end

  defp initialize_session!(identity) do
    conn = signed_post(identity, nil, initialize_body(1))
    assert conn.status == 200, "owner initialize failed: #{inspect_conn(conn)}"
    session_id = session_id!(conn)

    initialized =
      signed_post(
        identity,
        session_id,
        ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})
      )

    assert initialized.status in [200, 202],
           "owner initialized notification failed: #{inspect_conn(initialized)}"

    {session_id, conn}
  end

  defp start_owner_sse_stream(identity, session_id) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        send(test, {:owner_sse_started, self()})
        conn = signed_get_sse(identity, session_id)
        send(test, {:owner_sse_finished, conn})
      end)

    receive do
      {:owner_sse_started, ^pid} -> %{pid: pid}
    after
      1_000 ->
        flunk("owner GET/SSE task did not start")
    end
  end

  defp stop_owner_sse_stream(%{pid: pid}) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp wait_for_sse_handler!(session_id, attempts \\ 50)

  defp wait_for_sse_handler!(_session_id, 0) do
    flunk("owner GET/SSE never registered an SSE handler")
  end

  defp wait_for_sse_handler!(session_id, attempts) do
    case SessionRegistry.lookup(session_id) do
      {:ok, handler} when is_pid(handler) ->
        handler

      _other ->
        Process.sleep(20)
        wait_for_sse_handler!(session_id, attempts - 1)
    end
  end

  defp await_request(fun) do
    task = Task.async(fun)

    case Task.yield(task, @attach_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, conn} ->
        conn

      nil ->
        flunk(
          "request attached and streamed instead of being refused (waited #{@attach_timeout_ms}ms)"
        )
    end
  end

  defp assert_refused_attach(%Plug.Conn{} = conn, label) do
    assert conn.status == 404,
           "#{label} must be refused as an unknown session, got #{inspect_conn(conn)}"

    body = response_body(conn)
    assert body =~ "Session not found", "#{label} body was #{inspect(body)}"
    refute String.contains?(body, "event:"), "#{label} returned an SSE stream"
  end

  defp refute_replayed(%Plug.Conn{} = conn) do
    body = response_body(conn)

    refute String.contains?(body, @secret_event),
           "buffered owner events were replayed to the caller: #{inspect(body)}"
  end

  defp event_mentions_secret?(event) when is_map(event) do
    event
    |> Jason.encode!()
    |> String.contains?(@secret_event)
  end

  defp event_mentions_secret?(_event), do: false

  defp signed_get_sse(identity, session_id) do
    "GET"
    |> conn("/mcp", "")
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> sign_and_call(identity, "GET", "/mcp", "")
  end

  defp signed_post(identity, session_id, body) do
    "POST"
    |> conn("/mcp", body)
    |> put_req_header("content-type", "application/json")
    |> maybe_put_session(session_id)
    |> sign_and_call(identity, "POST", "/mcp", body)
  end

  defp signed_delete(identity, session_id) do
    "DELETE"
    |> conn("/mcp", "")
    |> put_req_header("mcp-session-id", session_id)
    |> sign_and_call(identity, "DELETE", "/mcp", "")
  end

  defp api_key_get_sse(session_id) do
    :get
    |> conn("/mcp", "")
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("x-api-key", @api_key)
    |> call()
  end

  defp api_key_post(session_id, body) do
    :post
    |> conn("/mcp", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-api-key", @api_key)
    |> maybe_put_session(session_id)
    |> call()
  end

  defp api_key_delete(session_id) do
    :delete
    |> conn("/mcp", "")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("x-api-key", @api_key)
    |> call()
  end

  defp sign_and_call(conn, identity, method, path, body) do
    Process.delete(:arbor_authenticated_agent_id)
    Process.delete(:arbor_authenticated_signed_request)

    conn
    |> put_req_header("authorization", signed_header(identity, method, path, body))
    |> call()
  end

  defp call(conn) do
    conn
    |> Map.put(:remote_ip, {10, 21, 10, 21})
    |> Router.call(Router.init([]))
  end

  defp maybe_put_session(conn, nil), do: conn
  defp maybe_put_session(conn, session_id), do: put_req_header(conn, "mcp-session-id", session_id)

  defp signed_header(identity, method, path, body) do
    {:ok, signed} =
      SignedRequest.sign(
        method <> "\n" <> path <> "\n" <> body,
        identity.agent_id,
        identity.private_key
      )

    envelope =
      Jason.encode!(%{
        "agent_id" => signed.agent_id,
        "timestamp" => DateTime.to_iso8601(signed.timestamp),
        "nonce" => Base.encode64(signed.nonce),
        "signature" => Base.encode64(signed.signature)
      })

    "Signature " <> Base.encode64(envelope, padding: false)
  end

  defp register_agent!(name) do
    {:ok, identity} = Security.generate_identity(name: "mcp-session-#{name}")
    :ok = Security.register_identity_fixture(identity)
    identity
  end

  defp session_id!(conn) do
    case get_resp_header(conn, "mcp-session-id") do
      [session_id] when is_binary(session_id) and session_id != "" ->
        session_id

      other ->
        flunk("expected mcp-session-id response header, got #{inspect(other)}")
    end
  end

  defp initialize_body(id) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "session-principal-binding", "version" => "0.0.1"}
      }
    })
  end

  defp tools_list_body(id) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/list",
      "params" => %{}
    })
  end

  defp response_body(%Plug.Conn{resp_body: body}) when is_binary(body), do: body
  defp response_body(%Plug.Conn{resp_body: body}), do: IO.iodata_to_binary(List.wrap(body))

  defp inspect_conn(conn) do
    "status=#{inspect(conn.status)} body=#{inspect(response_body(conn))}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_gateway, key, value)
end
