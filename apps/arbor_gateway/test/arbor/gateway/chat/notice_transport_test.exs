defmodule Arbor.Gateway.Chat.NoticeTransportTest.Security do
  @moduledoc false
  @credential String.duplicate("t", 43)

  def fixture, do: Application.fetch_env!(:arbor_gateway, :notice_transport_fixture)

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
        send(state.observer, {:notice_transport_claimed, caller})
        {{:ok, metadata()}, %{state | owner: caller}}
      else
        {{:error, :unauthorized}, state}
      end
    end)
  end

  def claim_terminal_session(_), do: {:error, :unauthorized}

  def verify_terminal_session(@credential) do
    caller = self()

    Agent.get_and_update(fixture(), fn state ->
      if state.active and state.owner == caller do
        number = state.proof_number + 1
        proof = "private-transport-notice-proof-#{number}"

        {{:ok, Map.put(metadata(), :session_token, proof)},
         %{state | proof_number: number, latest_proof: proof}}
      else
        {{:error, :unauthorized}, state}
      end
    end)
  end

  def verify_terminal_session(_), do: {:error, :unauthorized}

  defp metadata,
    do: %{
      principal: "human_owner",
      target: "agent_a",
      owner: "human_owner",
      lifetime: :connection
    }
end

defmodule Arbor.Gateway.Chat.NoticeTransportTest.Host do
  @moduledoc false
  # Actual Router/WebSock transport, deterministic public-facade collaborator.
  # No agent runtime, publication authority or external provider is claimed.
  alias Arbor.Gateway.Chat.NoticeTransportTest.Security

  @engagement "eng_11111111111111111111111111111111"

  def conversation_window(caller, target, opts) do
    with :ok <- record(:window, caller, target, opts) do
      {:ok,
       %{
         engagement_id: @engagement,
         entries: [],
         head: 0,
         first: 0,
         last: 0,
         has_older: false,
         has_newer: false
       }}
    end
  end

  def conversation_notices(caller, target, opts) do
    with :ok <- record(:notices, caller, target, opts) do
      {:ok,
       %{
         owner_id: "human_owner",
         target_agent_id: "agent_a",
         engagement_id: @engagement,
         notices: [],
         head: 1,
         through: 1,
         has_older: false,
         next_before: nil,
         complete: true
       }}
    end
  end

  defp record(operation, caller, target, opts) do
    owner = self()
    state = Agent.get(Security.fixture(), & &1)

    if state.active and state.owner == owner and caller == "human_owner" and target == "agent_a" and
         Keyword.get(opts, :session_token) == state.latest_proof do
      send(state.observer, {:notice_transport_dispatch, owner, operation, caller, target, opts})
      :ok
    else
      {:error, :unauthorized}
    end
  end
end

defmodule Arbor.Gateway.Chat.NoticeTransportTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :slow
  @credential String.duplicate("t", 43)
  @engagement "eng_11111111111111111111111111111111"

  setup do
    keys = [:terminal_login_security, :chat_agent_facade, :notice_transport_fixture, :rate_limit]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_gateway, &1)})
    observer = self()

    fixture =
      start_supervised!(
        {Agent,
         fn ->
           %{owner: nil, active: true, observer: observer, proof_number: 0, latest_proof: nil}
         end}
      )

    Application.put_env(:arbor_gateway, :notice_transport_fixture, fixture)
    Application.put_env(:arbor_gateway, :terminal_login_security, __MODULE__.Security)
    Application.put_env(:arbor_gateway, :chat_agent_facade, __MODULE__.Host)
    Application.put_env(:arbor_gateway, :rate_limit, max_requests: 10_000, window_seconds: 60)
    listener = {__MODULE__, make_ref()}

    on_exit(fn ->
      Plug.Cowboy.shutdown(listener)

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:arbor_gateway, key, value)
          :error -> Application.delete_env(:arbor_gateway, key)
        end
      end
    end)

    {:ok, _} =
      Plug.Cowboy.http(Arbor.Gateway.Router, [], ref: listener, ip: {127, 0, 0, 1}, port: 0)

    %{port: :ranch.get_port(listener)}
  end

  test "security regression real terminal WebSocket returns notices after a supported window on its claimed owner",
       c do
    connection = connect(c.port)
    assert_receive {:notice_transport_claimed, owner}, 1_000
    monitor = Process.monitor(owner)

    {:ok, window_payload} =
      Arbor.Agent.conversation_request_payload(:window, "human_owner", "agent_a", nil, limit: 20)

    :ok = send_text(connection, window_payload)
    {window, connection} = recv_text(connection)
    assert Jason.decode!(window)["type"] == "conversation_window"
    assert Jason.decode!(window)["data"]["engagement_id"] == @engagement

    assert_receive {:notice_transport_dispatch, ^owner, :window, "human_owner", "agent_a",
                    first_opts},
                   1_000

    {:ok, notice_payload} =
      Arbor.Agent.conversation_notice_request_payload("human_owner", "agent_a",
        before: 2,
        through: 1,
        limit: 1,
        expected_engagement_id: @engagement
      )

    :ok = send_text(connection, notice_payload)
    {notices, _connection} = recv_text(connection)

    assert Jason.decode!(notices) == %{
             "type" => "conversation_notices",
             "data" => %{
               "owner_id" => "human_owner",
               "target_agent_id" => "agent_a",
               "engagement_id" => @engagement,
               "notices" => [],
               "head" => 1,
               "through" => 1,
               "has_older" => false,
               "next_before" => nil,
               "complete" => true
             }
           }

    assert_receive {:notice_transport_dispatch, ^owner, :notices, "human_owner", "agent_a", opts},
                   1_000

    assert Keyword.drop(opts, [:session_token]) |> Map.new() == %{
             before: 2,
             through: 1,
             limit: 1,
             expected_engagement_id: @engagement
           }

    assert is_binary(opts[:session_token])
    assert opts[:session_token] != first_opts[:session_token]
    refute notices =~ "private-transport-notice-proof"
    refute notices =~ @credential
    :ok = :gen_tcp.close(connection.socket)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
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

  defp recv_text(connection) do
    {<<1::1, 0::3, 1::4, 0::1, size::7>>, connection} = read_bytes(connection, 2)

    {size, connection} =
      case size do
        126 ->
          {<<length::16>>, next} = read_bytes(connection, 2)
          {length, next}

        length when length < 126 ->
          {length, connection}
      end

    assert size <= 8_192
    read_bytes(connection, size)
  end

  defp read_bytes(%{buffered: buffered} = connection, count) when byte_size(buffered) >= count do
    <<body::binary-size(count), rest::binary>> = buffered
    {body, %{connection | buffered: rest}}
  end

  defp read_bytes(connection, count) do
    {:ok, more} = :gen_tcp.recv(connection.socket, count - byte_size(connection.buffered), 1_000)
    read_bytes(%{connection | buffered: connection.buffered <> more}, count)
  end

  defp send_text(connection, payload) do
    body = Jason.encode!(%{payload: payload, authentication: "conversation_session"})
    mask = <<1, 2, 3, 4>>

    masked =
      for {byte, index} <- Enum.with_index(:binary.bin_to_list(body)),
          into: <<>>,
          do: <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>

    header =
      if byte_size(body) < 126,
        do: <<1::1, 0::3, 1::4, 1::1, byte_size(body)::7>>,
        else: <<1::1, 0::3, 1::4, 1::1, 126::7, byte_size(body)::16>>

    :gen_tcp.send(connection.socket, [header, mask, masked])
  end
end
