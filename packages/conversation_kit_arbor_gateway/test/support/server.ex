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
