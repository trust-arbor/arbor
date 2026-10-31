defmodule LLMStandaloneConsumer.Wire do
  @moduledoc false

  def start(responses) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          serve(listener, responses, [])
        rescue
          _ -> %{error: :wire_fixture_failed}
        catch
          _, _ -> %{error: :wire_fixture_failed}
        after
          safe_close(listener)
        end
      end)

    %{listener: listener, task: task, url: "http://127.0.0.1:#{port}/v1"}
  end

  def finish(wire), do: Task.await(wire.task, 5_000)

  def stop(wire) do
    safe_close(wire.listener)
    if Process.alive?(wire.task.pid), do: Task.shutdown(wire.task, :brutal_kill)
    Process.demonitor(wire.task.ref, [:flush])
    :ok
  end

  defp serve(listener, [], captures) do
    extra =
      case :gen_tcp.accept(listener, 100) do
        {:error, :timeout} ->
          0

        {:ok, socket} ->
          safe_close(socket)
          1

        {:error, :closed} ->
          0
      end

    %{captures: Enum.reverse(captures), extra_connections: extra}
  end

  defp serve(listener, [response | rest], captures) do
    case :gen_tcp.accept(listener, 2_000) do
      {:ok, socket} ->
        captured =
          try do
            request = read_request(socket, "")
            sent = send_response(socket, response)
            Map.merge(request, sent)
          after
            safe_close(socket)
          end

        serve(listener, rest, [captured | captures])

      {:error, :timeout} ->
        %{captures: Enum.reverse(captures), extra_connections: 0, accept_timeout: true}
    end
  end

  defp read_request(socket, bytes) when byte_size(bytes) <= 1_048_576 do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        [line | header_lines] = String.split(head, "\r\n")
        [method, path, "HTTP/1.1"] = String.split(line, " ")

        headers =
          Map.new(header_lines, fn header ->
            [name, value] = String.split(header, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        length = headers |> Map.fetch!("content-length") |> String.to_integer()
        true = length in 0..1_048_576
        body = read_body(socket, body, length)
        %{method: method, path: path, body: JSON.decode!(body)}

      [_head] ->
        {:ok, part} = :gen_tcp.recv(socket, 0, 2_000)
        read_request(socket, bytes <> part)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) == length, do: body

  defp read_body(socket, body, length) when byte_size(body) < length do
    {:ok, part} = :gen_tcp.recv(socket, length - byte_size(body), 2_000)
    read_body(socket, body <> part, length)
  end

  defp send_response(socket, %{json: body}) do
    bytes = if is_binary(body), do: body, else: JSON.encode!(body)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(bytes)}\r\nconnection: close\r\n\r\n" <> bytes
      )

    %{sent_chunks: 1, peer_closed: false}
  end

  defp send_response(socket, %{chunks: chunks} = response) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
          "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"
      )

    send_chunks(socket, chunks, Map.get(response, :delay_ms, 0), 0)
  end

  defp send_chunks(socket, [], _delay, sent) do
    closed = :gen_tcp.send(socket, "0\r\n\r\n") != :ok
    %{sent_chunks: sent, peer_closed: closed}
  end

  defp send_chunks(socket, [chunk | rest], delay, sent) do
    case :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]) do
      :ok ->
        if delay > 0, do: Process.sleep(delay)
        send_chunks(socket, rest, delay, sent + 1)

      {:error, _} ->
        %{sent_chunks: sent, peer_closed: true}
    end
  end

  defp safe_close(socket) do
    :gen_tcp.close(socket)
    :ok
  catch
    :error, :badarg -> :ok
  end
end
