defmodule ConversationKit.Arbor.GatewayTest.Server do
  @moduledoc false

  def start(test, status \\ 101) do
    pid =
      spawn_link(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, {_, port}} = :inet.sockname(listener)
        send(test, {:listening, self(), port})
        accept(listener, test, status)
      end)

    receive do
      {:listening, ^pid, port} -> {pid, "ws://127.0.0.1:#{port}"}
    after
      1_000 -> raise "test listener did not start"
    end
  end

  defp accept(listener, test, status) do
    {:ok, socket} = :gen_tcp.accept(listener)

    child =
      spawn_link(fn ->
        receive do
          {:socket, socket} -> handshake(socket, test, status)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, child)
    send(child, {:socket, socket})
    accept(listener, test, status)
  end

  defp handshake(socket, test, status) when status in [401, 403] do
    _headers = read_headers(socket, "")
    :ok = :gen_tcp.send(socket, "HTTP/1.1 #{status} Unauthorized\r\ncontent-length: 0\r\n\r\n")
    :ok = :gen_tcp.close(socket)
    send(test, {:upgrade_refused, self(), status})
  end

  defp handshake(socket, test, 101) do
    headers = read_headers(socket, "")
    [_, key] = Regex.run(~r/sec-websocket-key:\s*([^\r]+)\r/i, headers)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "upgrade: websocket\r\nconnection: Upgrade\r\n",
        "sec-websocket-accept: ",
        accept,
        "\r\n\r\n"
      ])

    send(test, {:upgraded, self(), headers})
    frames(socket, test)
  end

  defp read_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
      read_headers(socket, acc <> bytes)
    end
  end

  defp frames(socket, test) do
    # Keep this channel alive through the queued-request deadline witness.
    # An idle peer timeout must not hide a missing pre-send deadline check.
    case :gen_tcp.recv(socket, 2, 6_000) do
      {:ok, <<_fin::1, _::3, opcode::4, 1::1, len::7>>} when opcode == 1 ->
        size =
          case len do
            126 ->
              {:ok, <<n::16>>} = :gen_tcp.recv(socket, 2, 2_000)
              n

            127 ->
              {:ok, <<n::64>>} = :gen_tcp.recv(socket, 8, 2_000)
              n

            n ->
              n
          end

        {:ok, mask} = :gen_tcp.recv(socket, 4, 2_000)
        {:ok, bytes} = :gen_tcp.recv(socket, size, 2_000)

        decoded =
          for {byte, i} <- Enum.with_index(:binary.bin_to_list(bytes)),
              into: <<>>,
              do: <<Bitwise.bxor(byte, :binary.at(mask, rem(i, 4)))>>

        send(test, {:frame, self(), Jason.decode!(decoded)})

        receive do
          {:reply, reply} ->
            send(test, {:reply_sent, self(), :gen_tcp.send(socket, wire_frame(reply))})
            frames(socket, test)

          {:reply_and_push, reply, unsolicited} ->
            bytes = [wire_frame(reply), wire_frame(unsolicited)]
            send(test, {:reply_sent, self(), :gen_tcp.send(socket, bytes)})
            frames(socket, test)

          :close ->
            :gen_tcp.close(socket)
        after
          3_000 -> :gen_tcp.close(socket)
        end

      _ ->
        :gen_tcp.close(socket)
        send(test, {:channel_closed, self()})
    end
  end

  defp wire_frame(reply) do
    binary = if is_binary(reply), do: reply, else: Jason.encode!(reply)

    header =
      if byte_size(binary) < 126,
        do: <<129, byte_size(binary)>>,
        else: <<129, 126, byte_size(binary)::16>>

    [header, binary]
  end
end

defmodule ConversationKit.Arbor.GatewayTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  alias ConversationKit.Arbor.Gateway
  alias ConversationKit.Arbor.GatewayTest.Server
  @engagement "eng_11111111111111111111111111111111"

  setup do
    {pub, key} = :crypto.generate_key(:eddsa, :ed25519)
    {server, url} = Server.start(self())
    on_exit(fn -> Process.exit(server, :kill) end)
    identity = %{agent_id: "human_test", private_key: key}
    %{identity: identity, pub: pub, url: url}
  end

  defp start(c, timeout \\ 5_000) do
    {:ok, remote} =
      Gateway.start_link(
        identity: c.identity,
        target: "agent_test",
        gateway_url: c.url,
        request_timeout_ms: timeout
      )

    {:ok, opts} = Gateway.client_options(remote)

    {:ok, client} =
      Arbor.new(opts[:caller], opts[:target], opts[:proof_provider], opts[:adapter_options])

    {remote, client, opts}
  end

  defp history,
    do: %{
      type: "conversation_history",
      data: %{
        agent_id: "agent_test",
        engagement_id: @engagement,
        entries: [],
        cursor: 0,
        head: 0,
        has_more: false
      }
    }

  defp events,
    do: %{
      type: "conversation_events",
      data: %{engagement_id: @engagement, events: [], cursor: 0, head: 0, has_more: false}
    }

  defp attach(client, unsolicited \\ nil) do
    task = Task.async(fn -> Arbor.sync(client) end)
    assert_receive {:upgraded, channel, _}, 2_000
    assert_receive {:frame, ^channel, history_request}, 2_000
    send(channel, {:reply, history()})
    assert_receive {:reply_sent, ^channel, :ok}
    assert_receive {:frame, ^channel, events_request}, 2_000

    if unsolicited,
      do: send(channel, {:reply_and_push, events(), unsolicited}),
      else: send(channel, {:reply, events()})

    assert_receive {:reply_sent, ^channel, :ok}, 1_000
    assert {:ok, next} = Task.await(task)
    {next, channel, history_request, events_request}
  end

  test "actual Socket channel uses fresh signatures and explicit fenced reattachment", c do
    {remote, client, opts} = start(c)
    {attached, old_channel, first, second} = attach(client)
    refute first["authorization"] == second["authorization"]
    assert_signed(first, c.pub)
    assert_signed(second, c.pub)

    assert ["arbor.conversation.v2", "events", "human_test", "agent_test", 0, _, @engagement] =
             Jason.decode!(second["payload"])

    assert :ok = opts[:disconnect].()
    assert {:error, :transport_not_attached} = Arbor.command(attached, "id1")
    refute_receive {:frame, _, _}, 20
    {_next, new_channel, reconnect, _} = attach(attached)
    refute old_channel == new_channel
    assert List.last(Jason.decode!(reconnect["payload"])) == @engagement
    assert :ok = Gateway.close(remote)
  end

  test "security regression: timeout retires channel and late response cannot satisfy another operation",
       c do
    {remote, client, _opts} = start(c, 2_000)
    {attached, old_channel, _, _} = attach(client)
    task = Task.async(fn -> Arbor.command(attached, "timed-out") end)
    assert_receive {:frame, ^old_channel, _}, 1_000
    assert {:error, :transport_timeout} = Task.await(task)
    send(old_channel, {:reply, %{type: "error", reason: "not_found"}})
    # Reattachment is a new TCP/WebSocket generation. Old frame/errors cannot
    # satisfy either new history or events request.
    {_next, new_channel, _, _} = attach(attached)
    refute old_channel == new_channel
    assert :ok = Gateway.close(remote)
  end

  test "concurrent operation is refused while exactly one wire request is unresolved", c do
    {remote, client, _opts} = start(c)
    {attached, channel, _, _} = attach(client)
    pending = Task.async(fn -> Arbor.command(attached, "first") end)
    assert_receive {:frame, ^channel, frame}
    assert Enum.at(Jason.decode!(frame["payload"]), 4) == "first"
    assert {:error, :transport_busy} = Arbor.command(attached, "second")
    refute_receive {:frame, _, _}, 20
    send(channel, {:reply, %{type: "error", reason: "not_found"}})
    assert {:error, :not_found} = Task.await(pending)
    assert :ok = Gateway.close(remote)
  end

  test "security regression: queued submit past its deadline never reaches the socket", c do
    {remote, client, opts} = start(c, 2_000)
    {_attached, _channel, _, _} = attach(client)

    context = %{
      caller: "human_test",
      target: "agent_test",
      operation: :submit,
      input: %{id: "expired-submit", text: "must not execute"},
      options: [expected_engagement_id: @engagement]
    }

    assert {:ok, proof} = opts[:proof_provider].(context)
    transport = opts[:adapter_options][:transport]
    :ok = :sys.suspend(remote)

    try do
      pending = Task.async(fn -> transport.(context, proof) end)
      assert {:error, :transport_timeout} = Task.await(pending, 4_000)
    after
      :sys.resume(remote)
    end

    # This call is a barrier after the expired queued request has been checked.
    assert {:ok, _} = Gateway.client_options(remote)
    refute_receive {:frame, _, _}, 30
    assert :ok = Gateway.close(remote)
  end

  @tag :terminal_credential_redaction
  test "security regression: actual remote-owner crash diagnostics redact private message and reason",
       c do
    {remote, _client, _opts} = start(c)
    Process.unlink(remote)
    on_exit(fn -> if Process.alive?(remote), do: Process.exit(remote, :kill) end)
    credential = Base.url_encode64(:binary.copy(<<89>>, 32), padding: false)

    monitor = Process.monitor(remote)

    {{result, reason}, log} =
      ExUnit.CaptureLog.with_log(fn ->
        result =
          try do
            GenServer.call(remote, {:unhandled_private_request, [session_token: credential]})
          catch
            :exit, _ -> :owner_exited
          end

        assert_receive {:DOWN, ^monitor, :process, ^remote, reason}, 1_000
        {result, reason}
      end)

    assert log =~ "terminating"
    refute log =~ credential
    assert result == {:error, :invalid_request}
    assert reason == :invalid_request
    refute Process.alive?(remote)

    synthetic =
      Gateway.format_status(%{
        state: credential,
        message: credential,
        reason: credential,
        log: [credential]
      })

    refute inspect(synthetic) =~ credential
  end

  test "session mode keeps credential at upgrade and binds every operation to the owned session",
       c do
    credential = Base.url_encode64(:binary.copy(<<19>>, 32), padding: false)

    session = %{
      principal: "human_test",
      target: "agent_test",
      credential: credential,
      lifetime: :connection
    }

    assert {:ok, remote} =
             Gateway.start_link(session: session, target: "agent_test", gateway_url: c.url)

    assert {:ok, opts} = Gateway.client_options(remote)
    assert opts[:caller] == session.principal

    assert {:ok, client} =
             Arbor.new(
               opts[:caller],
               opts[:target],
               opts[:proof_provider],
               opts[:adapter_options]
             )

    task = Task.async(fn -> Arbor.sync(client) end)
    assert_receive {:upgraded, channel, headers}, 2_000
    assert headers =~ "authorization: Conversation " <> credential
    assert_receive {:frame, ^channel, first}, 2_000
    assert Enum.sort(Map.keys(first)) == ["authentication", "payload"]
    assert first["authentication"] == "conversation_session"
    refute Jason.encode!(first) =~ credential
    send(channel, {:reply, history()})
    assert_receive {:frame, ^channel, second}, 2_000
    assert second["authentication"] == "conversation_session"
    send(channel, {:reply, events()})
    assert {:ok, attached} = Task.await(task)
    assert Arbor.position(attached) == %{history: 0, commands: 0}

    context = %{
      caller: "human_test",
      target: "agent_test",
      operation: :command,
      input: "id1",
      options: [expected_engagement_id: @engagement]
    }

    assert {:error, :unauthorized} =
             opts[:adapter_options][:transport].(context, session_token: "other")

    refute_receive {:frame, ^channel, _}, 100
    refute inspect(:sys.get_status(remote), limit: :infinity) =~ credential
    assert :ok = Gateway.close(remote)
  end

  test "session target and mutually exclusive authentication modes are checked before startup",
       c do
    session = %{
      principal: "human_test",
      target: "agent_test",
      credential: Base.url_encode64(:binary.copy(<<19>>, 32), padding: false),
      lifetime: :connection
    }

    assert {:error, :invalid_options} =
             Gateway.start_link(session: session, target: "agent_other", gateway_url: c.url)

    assert {:error, :invalid_options} =
             Gateway.start_link(
               identity: c.identity,
               session: session,
               target: "agent_test",
               gateway_url: c.url
             )

    assert {:error, :invalid_options} =
             Gateway.start_link(
               session: %{session | lifetime: :unknown},
               target: "agent_test",
               gateway_url: c.url
             )

    refute_receive {:upgraded, _, _}, 100
  end

  @tag :terminal_idle_authloss
  test "security regression: unsolicited session revocation latches unauthorized until a new login",
       c do
    {remote, client, opts} = start_session(c)
    {attached, channel, _, _} = attach(client, %{type: "error", reason: "unauthorized"})
    assert_receive {:channel_closed, ^channel}, 2_000

    assert {:error, :unauthorized} = Arbor.sync(attached)
    assert {:error, :unauthorized} = opts[:proof_provider].(history_context())
    assert :ok = opts[:disconnect].()
    assert {:error, :unauthorized} = Arbor.sync(attached)
    assert {:error, :unauthorized} = opts[:proof_provider].(history_context())
    assert Arbor.position(attached) == %{history: 0, commands: 0}
    refute_receive {:upgraded, _, _}, 100
    refute_receive {:frame, _, _}, 100
    assert :ok = Gateway.close(remote)
  end

  test "session authorization loss after a sent submit stays uncertain and is never replayed",
       c do
    {remote, client, opts} = start_session(c)
    {attached, channel, _, _} = attach(client)
    task = Task.async(fn -> Arbor.submit(attached, "stable-uncertain", "one effect at most") end)
    assert_receive {:frame, ^channel, request}, 2_000

    assert ["arbor.conversation.v2", "submit", "human_test", "agent_test", input, _, @engagement] =
             Jason.decode!(request["payload"])

    assert input == ["stable-uncertain", "one effect at most"]
    # Exercise ordinary response decoding beyond the small idle-control fast path.
    revoked =
      String.duplicate(" ", 257) <> Jason.encode!(%{type: "error", reason: "unauthorized"})

    send(channel, {:reply, revoked})
    assert {:error, :unauthorized} = Task.await(task)
    assert_receive {:channel_closed, ^channel}, 2_000
    assert :ok = opts[:disconnect].()

    assert {:error, :unauthorized} =
             Arbor.submit(attached, "stable-uncertain", "one effect at most")

    assert {:error, :unauthorized} = Arbor.sync(attached)
    assert Arbor.position(attached) == %{history: 0, commands: 0}
    refute_receive {:upgraded, _, _}, 100
    refute_receive {:frame, _, _}, 100
    assert :ok = Gateway.close(remote)
  end

  test "unsolicited conversation data and signed-mode authorization events remain invalid", c do
    for {mode, unsolicited} <- [
          {:session, history()},
          {:session, %{type: "error", reason: "unauthorized", extra: "not a control envelope"}},
          {:signature, %{type: "error", reason: "unauthorized"}}
        ] do
      {remote, client, _opts} = if mode == :session, do: start_session(c), else: start(c)
      {attached, channel, _, _} = attach(client, unsolicited)
      assert_receive {:channel_closed, ^channel}, 2_000
      assert {:error, :invalid_transport_response} = Arbor.sync(attached)
      refute_receive {:upgraded, _, _}, 50
      refute_receive {:frame, _, _}, 50
      assert :ok = Gateway.close(remote)
    end
  end

  test "session upgrade rejection latches unauthorized without sending a conversation operation",
       c do
    for status <- [401, 403] do
      {server, url} = Server.start(self(), status)
      on_exit(fn -> Process.exit(server, :kill) end)
      {remote, client, opts} = start_session(%{c | url: url})
      assert {:error, :unauthorized} = Arbor.sync(client)
      assert_receive {:upgrade_refused, _, ^status}, 2_000
      assert {:error, :unauthorized} = opts[:proof_provider].(history_context())
      assert :ok = opts[:disconnect].()
      assert {:error, :unauthorized} = Arbor.sync(client)
      refute_receive {:upgrade_refused, _, _}, 100
      refute_receive {:frame, _, _}, 100
      assert :ok = Gateway.close(remote)
    end
  end

  defp start_session(c) do
    session = %{
      principal: "human_test",
      target: "agent_test",
      credential: Base.url_encode64(:binary.copy(<<29>>, 32), padding: false),
      lifetime: :connection
    }

    {:ok, remote} =
      Gateway.start_link(session: session, target: session.target, gateway_url: c.url)

    {:ok, opts} = Gateway.client_options(remote)

    {:ok, client} =
      Arbor.new(opts[:caller], opts[:target], opts[:proof_provider], opts[:adapter_options])

    {remote, client, opts}
  end

  defp history_context,
    do: %{
      caller: "human_test",
      target: "agent_test",
      operation: :history,
      input: nil,
      options: []
    }

  defp assert_signed(%{"payload" => payload, "authorization" => "Signature " <> encoded}, pub) do
    auth = encoded |> Base.decode64!(padding: false) |> Jason.decode!()
    nonce = Base.decode64!(auth["nonce"])
    signature = Base.decode64!(auth["signature"])

    fields =
      for value <- [payload, auth["agent_id"], auth["timestamp"]],
          into: <<>>,
          do: <<byte_size(value)::32, value::binary>>

    assert :crypto.verify(:eddsa, :sha512, fields <> nonce, signature, [pub, :ed25519])
  end
end
