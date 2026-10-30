defmodule OAuthStandaloneConsumer.HTTPFixture do
  @moduledoc false

  @read_timeout 1_000
  @head_limit 32_768
  @body_limit 65_536

  def run(routes, operation) do
    {base, handle} = start(routes)

    try do
      result = operation.(base)
      send(handle.pid, {:finish, handle.ref})

      receive do
        {:finished, ref, report} when ref == handle.ref -> {result, report}
      after
        5_000 -> raise "owned HTTP fixture did not finish"
      end
    after
      stop(handle)
    end
  end

  defp start(routes) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(socket)
    base = "http://127.0.0.1:#{port}"
    resolved = if is_function(routes, 1), do: routes.(base), else: routes
    owner = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        owner_monitor = Process.monitor(owner)

        receive do
          {:serve, ^socket} ->
            send(owner, {:ready, ref})

            try do
              loop(socket, resolved, owner, owner_monitor, ref, %{
                accepted: 0,
                requests: [],
                chunks_sent: 0,
                completed?: true,
                closed?: false
              })
            after
              :gen_tcp.close(socket)
              Process.demonitor(owner_monitor, [:flush])
            end

          {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
            :gen_tcp.close(socket)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:serve, socket})

    receive do
      {:ready, ^ref} -> {base, %{pid: pid, ref: ref}}
    after
      2_000 ->
        Process.exit(pid, :kill)
        raise "owned HTTP fixture did not become ready"
    end
  end

  defp stop(handle) do
    monitor = Process.monitor(handle.pid)
    send(handle.pid, {:finish, handle.ref})

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      2_000 ->
        Process.exit(handle.pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        after
          1_000 -> raise "owned HTTP fixture survived exact-PID shutdown"
        end
    end
  end

  defp loop(listen, routes, owner, owner_monitor, ref, report) do
    receive do
      {:finish, ^ref} -> send(owner, {:finished, ref, report})
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
    after
      0 ->
        case :gen_tcp.accept(listen, 50) do
          {:ok, socket} ->
            next = %{report | accepted: report.accepted + 1}

            result = handle(socket, routes, next)
            loop(listen, routes, owner, owner_monitor, ref, result)

          {:error, :timeout} ->
            loop(listen, routes, owner, owner_monitor, ref, report)

          {:error, :closed} ->
            :ok
        end
    end
  end

  defp handle(socket, routes, report) do
    case request(socket) do
      {:ok, request} ->
        next = %{report | requests: report.requests ++ [request]}
        response = Map.get(routes, request.path, {:reply, 404, [], "absent"})
        response = if is_function(response, 1), do: response.(request), else: response
        respond(socket, response, next)

      :error ->
        %{report | closed?: true}
    end
  after
    :gen_tcp.close(socket)
  end

  defp request(socket) do
    with {:ok, head, rest} <- read_head(socket, ""),
         [line | header_lines] <- String.split(head, "\r\n"),
         [method, target, _version] <- String.split(line, " ", parts: 3),
         {:ok, length} <- content_length(header_lines),
         {:ok, body} <- read_body(socket, rest, length) do
      {:ok,
       %{
         method: method,
         path: target |> String.split("?", parts: 2) |> hd(),
         form: if(body == "", do: %{}, else: URI.decode_query(body))
       }}
    else
      _other -> :error
    end
  end

  defp read_head(_socket, bytes) when byte_size(bytes) > @head_limit, do: :error

  defp read_head(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_partial] ->
        case :gen_tcp.recv(socket, 0, @read_timeout) do
          {:ok, chunk} -> read_head(socket, bytes <> chunk)
          _other -> :error
        end
    end
  end

  defp content_length(lines) do
    value =
      Enum.find_value(lines, "0", fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "content-length", do: String.trim(value)

          _other ->
            nil
        end
      end)

    case Integer.parse(value) do
      {length, ""} when length >= 0 and length <= @body_limit -> {:ok, length}
      _other -> :error
    end
  end

  defp read_body(_socket, bytes, length) when byte_size(bytes) >= length,
    do: {:ok, binary_part(bytes, 0, length)}

  defp read_body(socket, bytes, length) do
    case :gen_tcp.recv(socket, length - byte_size(bytes), @read_timeout) do
      {:ok, chunk} -> read_body(socket, bytes <> chunk, length)
      _other -> :error
    end
  end

  defp respond(socket, {:reply, status, headers, body}, report) do
    headers = [{"content-length", Integer.to_string(byte_size(body))} | headers]
    :gen_tcp.send(socket, head(status, headers) <> body)
    report
  end

  defp respond(socket, {:body, headers, chunk, count, delay}, report) do
    :gen_tcp.send(socket, head(200, headers))
    pace(socket, chunk, count, delay, %{report | completed?: false})
  end

  defp respond(socket, {:header, chunk, count, delay}, report) do
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nx-unending: ")
    pace(socket, chunk, count, delay, %{report | completed?: false})
  end

  defp head(status, headers) do
    (["HTTP/1.1 #{status} Fixture", "connection: close"] ++
       Enum.map(headers, fn {name, value} -> "#{name}: #{value}" end))
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n\r\n")
  end

  defp pace(_socket, _chunk, 0, _delay, report), do: %{report | completed?: true}

  defp pace(socket, chunk, remaining, delay, report) do
    case :gen_tcp.send(socket, chunk) do
      :ok ->
        Process.sleep(delay)
        pace(socket, chunk, remaining - 1, delay, %{report | chunks_sent: report.chunks_sent + 1})

      {:error, _reason} ->
        %{report | closed?: true}
    end
  end
end
