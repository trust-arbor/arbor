defmodule Arbor.Gateway.Chat.TerminalLoginTest.Security do
  @moduledoc false
  def begin_terminal_login(target, source) do
    send(self(), {:login_start, target, source})

    Process.get(
      :terminal_start,
      {:ok,
       %{
         handle: String.duplicate("h", 43),
         verification_uri: "https://identity.example/verify",
         user_code: "TEST-CODE",
         expires_in: 300,
         interval: 5
       }}
    )
  end

  def terminal_login_status(handle, source) do
    send(self(), {:login_poll, handle, source})
    Process.get(:terminal_poll, {:ok, :pending})
  end

  def cancel_terminal_login(handle, source) do
    send(self(), {:login_cancel, handle, source})
    :ok
  end

  def revoke_terminal_session(credential) do
    send(self(), {:login_logout, credential})
    :ok
  end

  def preflight_terminal_session(credential) do
    send(self(), {:login_preflight, credential})
    Process.get(:terminal_preflight, {:error, :unauthorized})
  end

  def verify_terminal_session(credential) do
    send(self(), {:login_verify, credential})
    Process.get(:terminal_verify, {:error, :unauthorized})
  end
end

defmodule Arbor.Gateway.Chat.TerminalLoginTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog
  alias Arbor.Gateway.Chat.TerminalLogin
  alias Arbor.Gateway.Router
  @moduletag :fast
  @handle String.duplicate("h", 43)
  @credential String.duplicate("c", 43)

  setup do
    keys = [:terminal_login_security, :api_key, :rate_limit]
    old = Map.new(keys, &{&1, Application.fetch_env(:arbor_gateway, &1)})
    Application.put_env(:arbor_gateway, :terminal_login_security, __MODULE__.Security)
    Application.put_env(:arbor_gateway, :api_key, "test-api-key")
    Application.put_env(:arbor_gateway, :rate_limit, max_requests: 10_000, window_seconds: 60)

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:arbor_gateway, key, value)
          :error -> Application.delete_env(:arbor_gateway, key)
        end
      end
    end)

    :ok
  end

  defp request(path, body, opts \\ []) do
    method = Keyword.get(opts, :method, :post)
    origin = Keyword.get(opts, :origin, "http://127.0.0.1")
    bytes = if is_binary(body), do: body, else: Jason.encode!(body)

    conn(method, origin <> path, bytes)
    |> put_req_header("content-type", "application/json")
    |> Map.put(:remote_ip, Keyword.get(opts, :peer, {127, 0, 0, 21}))
  end

  defp call(conn), do: Router.call(conn, Router.init([]))
  defp json(conn), do: Jason.decode!(conn.resp_body)

  test "exact anonymous routes use closed request and response projections" do
    start = call(request("/api/chat/login/start", %{target: "agent_a"}))
    assert start.status == 200

    assert json(start) == %{
             "status" => "pending",
             "handle" => @handle,
             "verification_uri" => "https://identity.example/verify",
             "user_code" => "TEST-CODE",
             "expires_in" => 300,
             "interval" => 5
           }

    assert get_resp_header(start, "cache-control") == ["no-store"]
    assert_receive {:login_start, "agent_a", source}
    assert is_binary(source) and byte_size(source) == 43

    assert json(call(request("/api/chat/login/poll", %{handle: @handle}))) == %{
             "status" => "pending"
           }

    assert_receive {:login_poll, @handle, ^source}

    assert json(call(request("/api/chat/login/cancel", %{handle: @handle}))) == %{
             "status" => "closed"
           }

    assert_receive {:login_cancel, @handle, ^source}
  end

  test "completion projects only the scoped credential and public binding" do
    Process.put(
      :terminal_poll,
      {:ok,
       %{
         principal: "human_owner",
         target: "agent_a",
         credential: @credential,
         lifetime: :connection,
         session_token: "must-not-cross-wire"
       }}
    )

    result = call(request("/api/chat/login/poll", %{handle: @handle}))

    assert json(result) == %{
             "status" => "complete",
             "principal" => "human_owner",
             "target" => "agent_a",
             "credential" => @credential,
             "lifetime" => "connection"
           }

    refute result.resp_body =~ "must-not-cross-wire"
  end

  test "security regression: anonymous exemption is exact method and path only" do
    for {method, path} <- [
          {:get, "/api/chat/login/start"},
          {:put, "/api/chat/login/poll"},
          {:post, "/api/chat/login/start/"},
          {:post, "/api/chat/login/other"},
          {:post, "/api/chat/agents"},
          {:get, "/api/chat/socket"},
          {:post, "/api/chat/login/logout"}
        ] do
      assert call(request(path, %{}, method: method)).status == 401
    end

    refute_receive {:login_start, _, _}
    refute_receive {:login_poll, _, _}
    refute_receive {:login_logout, _}
  end

  test "security regression: login rejects unsafe transport, query credentials and mixed auth" do
    bad = [
      request("/api/chat/login/start", %{target: "agent_a"}, origin: "http://remote.example"),
      request("/api/chat/login/start", %{target: "agent_a"}, origin: "http://localhost"),
      request("/api/chat/login/start", %{target: "agent_a"}, peer: {10, 0, 0, 1}),
      request("/api/chat/login/start?handle=secret", %{target: "agent_a"}),
      request("/api/chat/login/start", %{target: "agent_a"})
      |> put_req_header("authorization", "Bearer test-api-key"),
      request("/api/chat/login/start", %{target: "agent_a"})
      |> put_req_header("x-api-key", "test-api-key")
    ]

    for conn <- bad, do: assert(call(conn).status == 401)
    refute_receive {:login_start, _, _}

    assert call(
             request("/api/chat/login/start", %{target: "agent_a"},
               origin: "https://remote.example",
               peer: {10, 0, 0, 1}
             )
           ).status == 200
  end

  test "security regression: JSON objects are small, closed, unique and uncompressed" do
    for body <- [
          %{target: "agent_a", principal: "human_attacker"},
          %{},
          [],
          "{\"target\":\"agent_b\",\"target\":\"agent_a\"}",
          "{",
          String.duplicate(" ", 2_049) <> "{}"
        ] do
      assert call(request("/api/chat/login/start", body)).status in [400, 401]
    end

    assert request("/api/chat/login/start", %{target: "agent_a"})
           |> put_req_header("content-encoding", "gzip")
           |> call()
           |> Map.fetch!(:status) == 401

    refute_receive {:login_start, _, _}
  end

  test "security regression: anonymous login still passes through the IP limiter" do
    Application.put_env(:arbor_gateway, :rate_limit, max_requests: 1, window_seconds: 60)
    peer = {127, 0, 0, 119}
    assert call(request("/api/chat/login/start", %{target: "agent_a"}, peer: peer)).status == 200
    assert call(request("/api/chat/login/start", %{target: "agent_a"}, peer: peer)).status == 429
  end

  test "security regression: login admission is bound to trusted transport peer" do
    peer = {127, 0, 0, 120}

    first =
      request("/api/chat/login/start", %{target: "agent_a"}, peer: peer)
      |> put_req_header("x-forwarded-for", "203.0.113.10")
      |> call()

    second =
      request("/api/chat/login/start", %{target: "agent_a"}, peer: peer)
      |> put_req_header("x-forwarded-for", "203.0.113.11")
      |> call()

    third =
      request("/api/chat/login/start", %{target: "agent_a"}, peer: {127, 0, 0, 121})
      |> call()

    assert first.status == 200
    assert second.status == 200
    assert third.status == 200
    assert_receive {:login_start, "agent_a", source_a}
    assert_receive {:login_start, "agent_a", source_b}
    assert_receive {:login_start, "agent_a", source_c}
    assert source_a == source_b
    refute source_a == source_c
  end

  test "security regression: Conversation credential never authenticates another API" do
    for scheme <- ["Conversation", "conversation", "CONVERSATION"],
        {method, path} <- [
          {:get, "/api/chat/agents"},
          {:post, "/mcp"},
          {:post, "/api/chat/agents"},
          {:get, "/api/chat/login/logout"}
        ] do
      result =
        request(path, %{}, method: method)
        |> put_req_header("authorization", scheme <> " " <> @credential)
        |> put_req_header("x-api-key", "test-api-key")
        |> call()

      assert result.status == 401
      refute result.assigns[:agent_id]
      refute result.assigns[:jwt_authenticated]
    end

    refute_receive {:login_verify, _}
  end

  test "logout requires exact credential-only auth and an empty JSON object" do
    result =
      request("/api/chat/login/logout", %{})
      |> put_req_header("authorization", "Conversation " <> @credential)
      |> call()

    assert json(result) == %{"status" => "closed"}
    assert_receive {:login_logout, @credential}

    for conn <- [
          request("/api/chat/login/logout", %{target: "agent_a"}),
          request("/api/chat/login/logout?credential=secret", %{}),
          request("/api/chat/login/logout", %{}) |> put_req_header("x-api-key", "test-api-key")
        ] do
      assert conn
             |> put_req_header("authorization", "Conversation " <> @credential)
             |> call()
             |> Map.fetch!(:status) == 401
    end

    refute_receive {:login_logout, _}
  end

  test "credential socket classification and binding do not expose generic authenticated assigns" do
    proof = "server-hmac-proof"

    Process.put(
      :terminal_preflight,
      {:ok,
       %{
         principal: "human_owner",
         target: "agent_a",
         owner: "human_canonical",
         session_token: proof,
         lifetime: :connection
       }}
    )

    conn =
      request("/api/chat/socket", "", method: :get)
      |> put_req_header("authorization", "Conversation " <> @credential)
      |> TerminalLogin.call([])

    assert conn.private.terminal_conversation
    refute conn.assigns[:agent_id]
    assert {:ok, state} = TerminalLogin.socket_state(conn)
    assert state.principal == "human_owner"
    assert state.credential == @credential
    assert state.lifetime == :connection
    assert_receive {:login_preflight, @credential}
    refute_receive {:login_verify, _}
    refute Map.has_key?(state, :session_token)
    mixed = %{conn | req_headers: [{"authorization", "Signature another"} | conn.req_headers]}
    assert TerminalLogin.call(mixed, []).status == 401
  end

  test "a still-owned credential returns only the typed preflight busy response" do
    Process.put(:terminal_preflight, {:error, :session_in_use})

    result =
      request("/api/chat/socket", "", method: :get)
      |> put_req_header("authorization", "Conversation " <> @credential)
      |> call()

    assert result.status == 409
    assert json(result) == %{"error" => "session_in_use"}
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert_receive {:login_preflight, @credential}
    refute_receive {:login_verify, _}
    refute result.resp_body =~ @credential
  end

  test "provider failures, handles and credentials never appear in response errors or logs" do
    Process.put(:terminal_start, {:error, {:provider, "private-provider-response"}})

    log =
      capture_log(fn ->
        result = call(request("/api/chat/login/start", %{target: "agent_a"}))
        assert result.status == 503
        assert json(result) == %{"error" => "login_unavailable"}
        call(request("/api/chat/login/poll?handle=secret-query-value", %{handle: @handle}))

        request("/api/chat/login/logout", %{})
        |> put_req_header("authorization", "Conversation " <> @credential)
        |> call()
      end)

    for secret <- ["private-provider-response", "secret-query-value", @handle, @credential],
        do: refute(log =~ secret)
  end
end
