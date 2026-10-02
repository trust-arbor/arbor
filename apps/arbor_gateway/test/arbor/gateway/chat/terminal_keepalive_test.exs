defmodule Arbor.Gateway.Chat.TerminalKeepaliveTest.Security do
  @moduledoc false
  @credential String.duplicate("k", 43)
  def fixture, do: Application.fetch_env!(:arbor_gateway, :terminal_keepalive_fixture)

  def preflight_terminal_session(@credential) do
    Agent.get(fixture(), fn state ->
      if state.active and (state.owner == nil or not Process.alive?(state.owner)),
        do: {:ok, metadata()},
        else: {:error, :unauthorized}
    end)
  end

  def preflight_terminal_session(_), do: {:error, :unauthorized}

  def claim_terminal_session(@credential) do
    caller = self()

    Agent.get_and_update(fixture(), fn state ->
      if state.active and (state.owner == nil or not Process.alive?(state.owner)) do
        send(state.observer, {:lease_claimed, caller})
        {{:ok, metadata()}, %{state | owner: caller}}
      else
        {{:error, :unauthorized}, state}
      end
    end)
  end

  def claim_terminal_session(_), do: {:error, :unauthorized}

  def verify_terminal_session(@credential) do
    caller = self()

    Agent.get(fixture(), fn state ->
      if state.active and state.owner == caller,
        do: {:ok, Map.put(metadata(), :session_token, "fresh-host-proof")},
        else: {:error, :unauthorized}
    end)
  end

  def verify_terminal_session(_), do: {:error, :unauthorized}

  defp metadata,
    do: %{
      principal: "human_keeper",
      target: "agent_a",
      owner: "human_owner",
      lifetime: :connection
    }
end

defmodule Arbor.Gateway.Chat.TerminalKeepaliveTest.Host do
  @moduledoc false
  alias Arbor.Gateway.Chat.TerminalKeepaliveTest.Security

  def conversation_history(_, _, _) do
    %{observer: observer} = Agent.get(Security.fixture(), & &1)
    reference = make_ref()
    send(observer, {:dispatch_waiting, self(), reference})

    receive do
      {:release_dispatch, ^reference} ->
        {:ok,
         %{
           engagement_id: "eng_11111111111111111111111111111111",
           entries: [],
           cursor: 0,
           head: 0,
           has_more: false
         }}
    after
      3_000 -> {:error, :conversation_unavailable}
    end
  end
end

defmodule Arbor.Gateway.Chat.TerminalKeepaliveTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :slow
  @credential String.duplicate("k", 43)

  setup do
    keys = [
      :terminal_login_security,
      :chat_agent_facade,
      :terminal_session_keepalive,
      :terminal_keepalive_fixture,
      :rate_limit
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_gateway, &1)})
    observer = self()

    fixture =
      start_supervised!({Agent, fn -> %{owner: nil, active: true, observer: observer} end})

    Application.put_env(:arbor_gateway, :terminal_keepalive_fixture, fixture)
    Application.put_env(:arbor_gateway, :terminal_login_security, __MODULE__.Security)
    Application.put_env(:arbor_gateway, :chat_agent_facade, __MODULE__.Host)

    Application.put_env(:arbor_gateway, :terminal_session_keepalive,
      interval_ms: 50,
      timeout_ms: 200,
      idle_timeout_ms: 1_000
    )

    Application.put_env(:arbor_gateway, :rate_limit, max_requests: 10_000, window_seconds: 60)
    listener = {__MODULE__, make_ref()}

    {:ok, _} =
      Plug.Cowboy.http(Arbor.Gateway.Router, [], ref: listener, ip: {127, 0, 0, 1}, port: 0)

    on_exit(fn ->
      :ok = Plug.Cowboy.shutdown(listener)

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:arbor_gateway, key, value)
          :error -> Application.delete_env(:arbor_gateway, key)
        end
      end
    end)

    %{port: :ranch.get_port(listener), fixture: fixture}
  end

  test "real WebSocket without the matching pong closes and retires its actual owner", c do
    connection = connect(c.port)
    assert_receive {:lease_claimed, owner}, 1_000
    monitor = Process.monitor(owner)
    {{9, challenge}, connection} = recv_frame(connection)
    assert byte_size(challenge) == 16
    :ok = send_frame(connection, 10, "wrong-challenge")
    assert {{8, <<1001::16, _::binary>>}, _} = recv_frame(connection)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
  end

  test "real matching pongs keep an idle socket alive beyond the configured transport idle timeout",
       c do
    connection = connect(c.port)
    assert_receive {:lease_claimed, owner}, 1_000
    {connection, count} = answer_pings(connection, System.monotonic_time(:millisecond) + 1_500, 0)
    assert count >= 3
    assert Process.alive?(owner)
    monitor = Process.monitor(owner)
    :ok = :gen_tcp.close(connection.socket)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
  end

  test "a real pong queued behind a blocked dispatch survives its old deadline and keeps one result",
       c do
    connection = connect(c.port)
    assert_receive {:lease_claimed, owner}, 1_000
    {{9, challenge}, connection} = recv_frame(connection)

    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(:history, "human_keeper", "agent_a", nil, [])

    :ok =
      send_frame(
        connection,
        1,
        Jason.encode!(%{payload: payload, authentication: "conversation_session"})
      )

    assert_receive {:dispatch_waiting, ^owner, reference}, 1_000
    # Both the pong and old timer become runnable while the callback is held.
    :ok = send_frame(connection, 10, challenge)
    Process.sleep(250)
    send(owner, {:release_dispatch, reference})
    assert {{1, response}, connection} = recv_frame(connection)
    assert Jason.decode!(response)["type"] == "conversation_history"
    {{9, next_challenge}, connection} = recv_frame(connection)
    :ok = send_frame(connection, 10, next_challenge)
    assert Process.alive?(owner)
    refute_receive {:dispatch_waiting, _, _}, 20
    :ok = :gen_tcp.close(connection.socket)
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET /api/chat/socket HTTP/1.1\r\nHost: 127.0.0.1:",
        Integer.to_string(port),
        "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ",
        key,
        "\r\nSec-WebSocket-Version: 13\r\nAuthorization: Conversation ",
        @credential,
        "\r\n\r\n"
      ])

    {headers, buffered} = read_headers(socket, <<>>)
    assert headers =~ "HTTP/1.1 101"
    %{socket: socket, buffered: buffered}
  end

  defp read_headers(socket, bytes) when byte_size(bytes) <= 16_384 do
    case :binary.match(bytes, "\r\n\r\n") do
      {at, 4} ->
        <<headers::binary-size(at + 4), rest::binary>> = bytes
        {headers, rest}

      :nomatch ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 1_000)
        read_headers(socket, bytes <> more)
    end
  end

  defp recv_frame(connection) do
    {<<1::1, 0::3, opcode::4, 0::1, size::7>>, connection} = read_bytes(connection, 2)

    {size, connection} =
      case size do
        126 ->
          {<<length::16>>, next} = read_bytes(connection, 2)
          {length, next}

        length when length < 126 ->
          {length, connection}
      end

    assert size <= 1_024
    {body, connection} = read_bytes(connection, size)
    {{opcode, body}, connection}
  end

  defp read_bytes(%{buffered: buffered} = connection, count) when byte_size(buffered) >= count do
    <<body::binary-size(count), rest::binary>> = buffered
    {body, %{connection | buffered: rest}}
  end

  defp read_bytes(connection, count) do
    {:ok, more} = :gen_tcp.recv(connection.socket, count - byte_size(connection.buffered), 1_000)
    read_bytes(%{connection | buffered: connection.buffered <> more}, count)
  end

  defp send_frame(connection, opcode, body) do
    mask = <<1, 2, 3, 4>>

    masked =
      for {byte, index} <- Enum.with_index(:binary.bin_to_list(body)),
          into: <<>>,
          do: <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>

    header =
      if byte_size(body) < 126,
        do: <<1::1, 0::3, opcode::4, 1::1, byte_size(body)::7>>,
        else: <<1::1, 0::3, opcode::4, 1::1, 126::7, byte_size(body)::16>>

    :gen_tcp.send(connection.socket, [header, mask, masked])
  end

  defp answer_pings(connection, deadline, count) do
    if System.monotonic_time(:millisecond) >= deadline do
      {connection, count}
    else
      {{9, challenge}, connection} = recv_frame(connection)
      :ok = send_frame(connection, 10, challenge)
      answer_pings(connection, deadline, count + 1)
    end
  end
end
