defmodule Arbor.Client.SocketTest do
  use ExUnit.Case, async: true
  @moduletag :integration
  @moduletag capture_log: true
  alias Arbor.Client.Socket

  defp identity do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {%{agent_id: "human_" <> String.duplicate("a", 40), private_key: private}, public}
  end

  test "raw owner preserves upgrade-coalesced text and signs each connection independently" do
    {identity, public} = identity()

    nonces =
      for _ <- 1..2 do
        {peer, url} = peer(coalesced: frame(1, 1, "ready"))
        {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
        assert_receive {:peer_upgrade, ^peer, request}, 1_000
        assert_receive {:arbor_socket, ^socket, :connected}, 1_000
        assert_receive {:arbor_socket, ^socket, {:frame, "ready"}}, 1_000
        assert String.starts_with?(request, "GET /api/chat/socket HTTP/1.1\r\n")
        [_, encoded] = Regex.run(~r/authorization: Signature ([^\r]+)\r/i, request)
        envelope = encoded |> Base.decode64!(padding: false) |> Jason.decode!()
        nonce = Base.decode64!(envelope["nonce"])
        payload = "GET\n/api/chat/socket\n"

        signed =
          length_prefix(payload) <>
            length_prefix(identity.agent_id) <> length_prefix(envelope["timestamp"]) <> nonce

        assert :crypto.verify(:eddsa, :sha512, signed, Base.decode64!(envelope["signature"]), [
                 public,
                 :ed25519
               ])

        assert :ok = Socket.close(socket)
        refute Process.alive?(socket)
        assert_receive {:arbor_socket, ^socket, {:closed, :closed}}, 1_000
        nonce
      end

    assert length(Enum.uniq(nonces)) == 2
  end

  test "fragmented text and interleaved ping preserve payload and protocol control" do
    {identity, _} = identity()
    {peer, url} = peer()
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    send(peer, {:send, frame(0, 1, "hello") <> frame(1, 9, "ping")})
    refute_receive {:arbor_socket, ^socket, {:frame, _}}, 100
    send(peer, {:read, :pong, 1_000})
    assert_receive {:peer_read, :pong, {:ok, 10, "ping"}}, 1_000
    send(peer, {:send, frame(1, 0, " world")})
    assert_receive {:arbor_socket, ^socket, {:frame, "hello world"}}, 1_000
    assert :ok = Socket.send_frame(socket, "outbound")
    send(peer, {:read, :text, 1_000})
    assert_receive {:peer_read, :text, {:ok, 1, "outbound"}}, 1_000
    assert :ok = Socket.close(socket)
  end

  test "oversized declared payload closes before receiving its body" do
    {identity, _} = identity()
    {peer, url} = peer()
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    monitor = Process.monitor(socket)
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    length = Socket.max_message_bytes() + 1
    send(peer, {:send, <<0x81, 127, length::64>>})
    assert_receive {:arbor_socket, ^socket, {:closed, :frame_too_large}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^socket, :normal}, 1_000
    refute_receive {:arbor_socket, ^socket, {:frame, _}}
  end

  test "fragment-count bound closes even an empty fragmented message" do
    {identity, _} = identity()
    {peer, url} = peer()
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    fragments = frame(0, 1, "") <> :binary.copy(frame(0, 0, ""), Socket.max_fragments())
    send(peer, {:send, fragments})
    assert_receive {:arbor_socket, ^socket, {:closed, :fragment_limit}}, 1_000
    refute_receive {:arbor_socket, ^socket, {:frame, _}}
  end

  @tag :slow
  test "upgrade deadline is total despite incomplete HTTP progress" do
    {identity, _} = identity()
    {peer, url} = peer(stall: true)
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    assert_receive {:peer_upgrade, ^peer, _}, 1_000
    send(peer, {:send, "HTTP/1.1 101 Switching Protocols\r\n"})
    assert_receive {:arbor_socket, ^socket, {:closed, :connect_timeout}}, 6_000
    refute_receive {:arbor_socket, ^socket, :connected}
  end

  test "normal owner exit retires its exact socket and closes the peer" do
    {identity, _} = identity()
    {peer, url} = peer()
    observer = self()

    owner =
      spawn(fn ->
        {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
        send(observer, {:owned_socket, socket})

        receive do
          {:arbor_socket, ^socket, :connected} -> send(observer, :owner_ready)
        end

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:owned_socket, socket}, 1_000
    monitor = Process.monitor(socket)
    assert_receive :owner_ready, 1_000
    send(owner, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^socket, :normal}, 1_000
    send(peer, {:read, :closed, 1_000})
    assert_receive {:peer_read, :closed, {:error, :closed}}, 1_000
  end

  test "security regression: queued send checks its absolute deadline at effect time" do
    {identity, _} = identity()
    {peer, url} = peer()
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    :ok = :sys.suspend(socket)

    resumer =
      spawn_link(fn ->
        receive do
          :resume -> :sys.resume(socket)
        end
      end)

    Process.send_after(resumer, :resume, 60)
    deadline = System.monotonic_time(:millisecond) + 20
    assert {:error, :timeout} = Socket.send_frame(socket, "must not escape", deadline)
    send(peer, {:read, :expired, 100})
    assert_receive {:peer_read, :expired, {:error, :timeout}}, 1_000
    assert :ok = Socket.close(socket)
  end

  test "transport configuration rejects remote plaintext and credential-bearing URLs" do
    {identity, _} = identity()

    for url <- [
          "ws://example.com",
          "wss://user:secret@example.com",
          "wss://example.com/?token=secret",
          "ftp://127.0.0.1"
        ] do
      assert {:error, :invalid_options} =
               Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    end
  end

  test "system status redacts credentials and a foreign caller cannot write" do
    {identity, _} = identity()
    {_peer, url} = peer()
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    status = inspect(:sys.get_status(socket), limit: :infinity)
    refute status =~ inspect(identity.private_key)
    refute status =~ identity.agent_id

    assert Task.async(fn -> Socket.send_frame(socket, "foreign") end) |> Task.await() ==
             {:error, :not_owner}

    assert :ok = Socket.close(socket)
    assert {:error, :closed} = Socket.send_frame(socket, "late")
  end

  @tag :terminal_credential_redaction
  test "security regression: actual socket crash diagnostics do not disclose a credential-bearing message" do
    {identity, _} = identity()
    {_peer, url} = peer()
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    Process.unlink(socket)
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    credential = Base.url_encode64(:binary.copy(<<83>>, 32), padding: false)

    monitor = Process.monitor(socket)

    {{result, reason}, log} =
      ExUnit.CaptureLog.with_log(fn ->
        result =
          try do
            GenServer.call(socket, {:unhandled_private_request, [session_token: credential]})
          catch
            :exit, _ -> :owner_exited
          end

        assert_receive {:DOWN, ^monitor, :process, ^socket, reason}, 1_000
        {result, reason}
      end)

    assert log =~ "terminating"
    refute log =~ credential
    assert result == {:error, :invalid_request}
    assert reason == :invalid_request
    refute Process.alive?(socket)

    synthetic =
      Socket.format_status(%{
        state: credential,
        message: credential,
        reason: credential,
        log: [credential]
      })

    refute inspect(synthetic) =~ credential
  end

  test "session authentication is confined to the upgrade and status stays redacted" do
    credential = Base.url_encode64(:binary.copy(<<31>>, 32), padding: false)

    session = %{
      principal: "human_terminal",
      target: "agent_target",
      credential: credential,
      lifetime: :connection
    }

    {peer, url} = peer()
    assert {:ok, socket} = Socket.start_link(owner: self(), session: session, gateway_url: url)
    assert_receive {:peer_upgrade, ^peer, request}, 1_000
    assert request =~ "authorization: Conversation " <> credential
    refute request =~ "Signature "
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    refute inspect(:sys.get_status(socket), limit: :infinity) =~ credential

    for index <- 1..3 do
      challenge = "session-keepalive-#{index}"
      send(peer, {:send, frame(1, 9, challenge)})
      send(peer, {:read, {:session_pong, index}, 1_000})
      assert_receive {:peer_read, {:session_pong, ^index}, {:ok, 10, ^challenge}}, 1_000
    end

    frame =
      Jason.encode!(%{payload: "canonical operation", authentication: "conversation_session"})

    assert :ok = Socket.send_frame(socket, frame)
    send(peer, {:read, :session_frame, 1_000})
    assert_receive {:peer_read, :session_frame, {:ok, 1, ^frame}}, 1_000
    refute frame =~ credential
    assert :ok = Socket.close(socket)
  end

  test "session and signing modes cannot mix, and unsupported or unsafe session options are refused" do
    {identity, _} = identity()

    session = %{
      principal: "human_terminal",
      target: "agent_target",
      credential: Base.url_encode64(:binary.copy(<<31>>, 32), padding: false),
      lifetime: :connection
    }

    assert {:error, :invalid_options} =
             Socket.start_link(
               owner: self(),
               identity: identity,
               session: session,
               gateway_url: "ws://127.0.0.1:1"
             )

    assert {:error, :invalid_options} =
             Socket.start_link(
               owner: self(),
               session: %{session | lifetime: :unknown},
               gateway_url: "ws://127.0.0.1:1"
             )

    assert {:error, :invalid_options} =
             Socket.start_link(owner: self(), session: session, gateway_url: "ws://localhost:1")

    assert {:error, :invalid_options} =
             Socket.start_link(
               owner: self(),
               session: Map.put(session, :extra, true),
               gateway_url: "wss://gateway.example"
             )
  end

  test "session upgrade waits for a retiring owner without sending or replaying an operation" do
    {peer, url} = busy_peer(2)
    {:ok, socket} = Socket.start_link(owner: self(), session: session(), gateway_url: url)
    assert_receive {:busy_upgrade, ^peer, 1}, 1_000
    assert_receive {:busy_upgrade, ^peer, 2}, 1_000
    assert_receive {:arbor_socket, ^socket, :connected}, 1_000
    assert_receive {:peer_upgrade, ^peer, request}, 1_000
    assert request =~ "authorization: Conversation " <> session().credential
    assert :ok = Socket.send_frame(socket, "one operation")
    send(peer, {:read, :single_operation, 1_000})
    assert_receive {:peer_read, :single_operation, {:ok, 1, "one operation"}}, 1_000
    send(peer, {:read, :no_replay, 100})
    assert_receive {:peer_read, :no_replay, {:error, :timeout}}, 1_000
    assert :ok = Socket.close(socket)
  end

  @tag :slow
  test "session busy responses cannot extend the original total upgrade deadline" do
    {peer, url} = busy_peer(:forever)
    started = System.monotonic_time(:millisecond)
    {:ok, socket} = Socket.start_link(owner: self(), session: session(), gateway_url: url)
    assert_receive {:busy_upgrade, ^peer, 1}, 1_000
    assert_receive {:busy_upgrade, ^peer, 2}, 1_000
    assert_receive {:arbor_socket, ^socket, {:closed, :connect_timeout}}, 6_000
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_000 and elapsed < 7_000
    refute_receive {:arbor_socket, ^socket, :connected}, 100
  end

  test "busy upgrade retry does not apply to signing mode or other HTTP statuses" do
    {identity, _} = identity()
    {peer, url} = busy_peer(:forever)
    {:ok, socket} = Socket.start_link(owner: self(), identity: identity, gateway_url: url)
    assert_receive {:busy_upgrade, ^peer, 1}, 1_000
    assert_receive {:arbor_socket, ^socket, {:closed, :upgrade_failed}}, 1_000
    refute_receive {:busy_upgrade, ^peer, 2}, 100

    for status <- [302, 401, 403, 500] do
      {peer, url} = busy_peer(:forever, status)
      {:ok, socket} = Socket.start_link(owner: self(), session: session(), gateway_url: url)
      assert_receive {:busy_upgrade, ^peer, 1}, 1_000
      reason = if status in [401, 403], do: :unauthorized, else: :upgrade_failed
      assert_receive {:arbor_socket, ^socket, {:closed, ^reason}}, 1_000
      refute_receive {:busy_upgrade, ^peer, 2}, 100
    end
  end

  defp session do
    %{
      principal: "human_terminal",
      target: "agent_target",
      credential: Base.url_encode64(:binary.copy(<<31>>, 32), padding: false),
      lifetime: :connection
    }
  end

  defp busy_peer(busy_count, status \\ 409) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    owner = self()
    pid = spawn(fn -> busy_accept(listener, owner, busy_count, status, 1) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {pid, "ws://127.0.0.1:#{port}"}
  end

  defp busy_accept(listener, owner, remaining, status, index) do
    case :gen_tcp.accept(listener, 10_000) do
      {:ok, socket} ->
        request = read_upgrade(socket, "")

        if remaining == 0 do
          :gen_tcp.close(listener)
          send(owner, {:peer_upgrade, self(), request})
          [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r/i, request)

          accept =
            :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n"
            )

          peer_loop(socket, owner)
        else
          send(owner, {:busy_upgrade, self(), index})
          :gen_tcp.send(socket, "HTTP/1.1 #{status} Response\r\ncontent-length: 0\r\n\r\n")
          :gen_tcp.recv(socket, 0, 2_000)
          :gen_tcp.close(socket)
          next = if remaining == :forever, do: :forever, else: remaining - 1
          busy_accept(listener, owner, next, status, index + 1)
        end

      _ ->
        :ok
    end
  end

  defp peer(opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    owner = self()

    peer =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.close(listener)
        request = read_upgrade(socket, "")
        send(owner, {:peer_upgrade, self(), request})

        unless opts[:stall] do
          [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r/i, request)

          accept =
            :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

          response =
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n"

          :ok = :gen_tcp.send(socket, [response, Keyword.get(opts, :coalesced, "")])
        end

        peer_loop(socket, owner)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(peer), do: Process.exit(peer, :kill)
    end)

    {peer, "ws://127.0.0.1:#{port}"}
  end

  defp read_upgrade(socket, data) do
    if String.contains?(data, "\r\n\r\n") do
      data
    else
      {:ok, part} = :gen_tcp.recv(socket, 0, 2_000)
      read_upgrade(socket, data <> part)
    end
  end

  defp peer_loop(socket, owner) do
    receive do
      {:send, bytes} ->
        :gen_tcp.send(socket, bytes)
        peer_loop(socket, owner)

      {:read, tag, timeout} ->
        send(owner, {:peer_read, tag, read_frame(socket, timeout)})
        peer_loop(socket, owner)
    end
  end

  defp read_frame(socket, timeout) do
    with {:ok, <<_fin::1, _reserved::3, opcode::4, 1::1, size::7>>} <-
           :gen_tcp.recv(socket, 2, timeout),
         {:ok, length} <- frame_length(socket, size, timeout),
         {:ok, <<mask::binary-size(4), data::binary>>} <-
           :gen_tcp.recv(socket, length + 4, timeout) do
      unmasked =
        for {byte, index} <- Enum.with_index(:binary.bin_to_list(data)),
            into: <<>>,
            do: <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>

      {:ok, opcode, unmasked}
    end
  end

  defp frame_length(socket, 126, timeout) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, timeout), do: {:ok, length}
  end

  defp frame_length(socket, 127, timeout) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, timeout), do: {:ok, length}
  end

  defp frame_length(_, length, _), do: {:ok, length}

  defp frame(fin, opcode, text),
    do: <<fin::1, 0::3, opcode::4, 0::1, byte_size(text)::7, text::binary>>

  defp length_prefix(binary), do: <<byte_size(binary)::32, binary::binary>>
end
