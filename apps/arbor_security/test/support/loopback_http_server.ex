defmodule Arbor.Security.LoopbackHTTPServer do
  @moduledoc false
  # Deterministic ephemeral-loopback HTTP server for OAuth/OIDC tests.
  #
  # Raw :gen_tcp — arbor_security has no plug/bandit dep. Binds 127.0.0.1:0 so
  # tests stay async-safe, and the literal IP avoids IPv6 resolution flakiness
  # that "localhost" introduces on some hosts.
  #
  # No DNS, no egress: every byte stays on the loopback interface.

  @accept_timeout 2_000
  @read_timeout 5_000

  defmodule Handle do
    @moduledoc false
    # Plain pid + ref rather than a Task: ExUnit runs on_exit callbacks in a
    # different process, and Task's owner-only await/shutdown contract makes
    # both cleanup and reporting awkward from there.
    defstruct [:pid, :ref, :owner]
  end

  defmodule Report do
    @moduledoc false
    defstruct requests: [], chunks_sent: 0, completed?: false, closed?: false
  end

  @doc """
  Start a server. `routes` is either a path => response-spec map, or a
  one-argument function receiving the server's own base URL and returning that
  map — the latter is how a discovery document advertises a *same-origin*
  token endpoint, whose port is only known after binding.

  A response spec is one of:

    * `{:respond, status, headers, body}` — a normal framed response
    * `{:paced_stream, headers, chunk, count, sleep_ms}` — headers then `count`
      writes of `chunk`, pausing `sleep_ms` between them, aborting the moment
      the peer closes. `completed?` in the report tells you whether the server
      managed to send them all.
    * `:close` — accept then close without replying
    * `:hang` — accept and never reply

  Returns `{base_url, task}`. `await/1` yields the `Report`.
  """
  def start(routes, opts \\ []) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true,
        packet: :raw,
        backlog: 8
      ])

    {:ok, port} = :inet.port(listen)
    connections = Keyword.get(opts, :connections, 1)
    base_url = "http://127.0.0.1:#{port}"
    resolved = if is_function(routes, 1), do: routes.(base_url), else: routes

    owner = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        report = serve(listen, resolved, connections, %Report{})
        :gen_tcp.close(listen)
        send(owner, {ref, report})
      end)

    :ok = :gen_tcp.controlling_process(listen, pid)

    {base_url, %Handle{pid: pid, ref: ref, owner: owner}}
  end

  @doc "Bind and immediately close a port, yielding a URL guaranteed to refuse connections."
  def closed_port_url do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  Await the server's report. Must be called from the process that started it.

  The server self-terminates once it has served its expected connections or the
  accept timeout elapses, so this never hangs indefinitely.
  """
  def await(%Handle{ref: ref}, timeout \\ 15_000) do
    receive do
      {^ref, report} -> report
    after
      timeout -> flunk_timeout()
    end
  end

  @doc "Shut the server down without caring about its report. Safe from any process."
  def stop(%Handle{pid: pid}) do
    Process.exit(pid, :kill)
    :ok
  end

  defp flunk_timeout do
    raise "LoopbackHTTPServer.await/2 timed out waiting for the server report"
  end

  # --- Accept loop ---

  defp serve(_listen, _routes, 0, report), do: report

  defp serve(listen, routes, remaining, report) do
    case :gen_tcp.accept(listen, @accept_timeout) do
      {:ok, socket} ->
        report = handle(socket, routes, report)
        :gen_tcp.close(socket)
        serve(listen, routes, remaining - 1, report)

      {:error, :timeout} ->
        report

      {:error, :closed} ->
        report
    end
  end

  defp handle(socket, routes, report) do
    case read_request(socket) do
      {:ok, method, path} ->
        report = %{report | requests: report.requests ++ [%{method: method, path: path}]}
        respond(socket, Map.get(routes, path, {:respond, 404, [], "not found"}), report)

      {:error, _reason} ->
        report
    end
  end

  # Read the head, then drain any Content-Length body so the client sees a
  # complete exchange rather than a truncated write.
  defp read_request(socket) do
    with {:ok, head, pre_read_body} <- read_head(socket, "") do
      [request_line | header_lines] = String.split(head, "\r\n")
      pre_read_len = byte_size(pre_read_body)

      case String.split(request_line, " ") do
        [method, target | _rest] ->
          drain_body(socket, content_length(header_lines), pre_read_len)
          {:ok, method, target |> String.split("?") |> hd()}

        _ ->
          {:error, :bad_request_line}
      end
    end
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      [head, rest] = String.split(acc, "\r\n\r\n", parts: 2)
      {:ok, head, rest}
    else
      case :gen_tcp.recv(socket, 0, @read_timeout) do
        {:ok, data} -> read_head(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp content_length(header_lines) do
    Enum.find_value(header_lines, 0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            case Integer.parse(String.trim(value)) do
              {n, _} -> n
              :error -> nil
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp drain_body(socket, length, pre_read_len) when is_integer(length) do
    remain = length - pre_read_len

    if remain <= 0 do
      :ok
    else
      bytes_to_read = min(remain, 8_192)

      case :gen_tcp.recv(socket, bytes_to_read, @read_timeout) do
        {:ok, chunk} ->
          drain_body(socket, length, pre_read_len + byte_size(chunk))

        {:error, _reason} ->
          :ok
      end
    end
  end

  defp drain_body(_socket, nil, _pre_read_len), do: :ok

  defp drain_body(_socket, _length, _pre_read_len), do: :ok

  # --- Responses ---

  defp respond(socket, {:respond, status, headers, body}, report) do
    head =
      [
        "HTTP/1.1 #{status} #{reason_phrase(status)}",
        "content-length: #{byte_size(body)}",
        "connection: close"
      ] ++ Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)

    :gen_tcp.send(socket, Enum.join(head, "\r\n") <> "\r\n\r\n" <> body)
    %{report | completed?: true}
  end

  defp respond(socket, {:paced_stream, headers, chunk, count, sleep_ms}, report) do
    head =
      ["HTTP/1.1 200 OK", "connection: close"] ++
        Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)

    case :gen_tcp.send(socket, Enum.join(head, "\r\n") <> "\r\n\r\n") do
      :ok -> pace(socket, chunk, count, sleep_ms, report, 0)
      {:error, _reason} -> %{report | closed?: true}
    end
  end

  defp respond(_socket, :close, report), do: %{report | closed?: true}

  defp respond(_socket, :hang, report) do
    Process.sleep(@read_timeout)
    report
  end

  # Paced writes are what make the transport-bound proof portable: a client that
  # buffered the whole body would let every chunk through, so `completed?: false`
  # means the client tore the socket down early — no OS-specific byte threshold
  # required.
  defp pace(_socket, _chunk, 0, _sleep_ms, report, sent),
    do: %{report | chunks_sent: sent, completed?: true}

  defp pace(socket, chunk, remaining, sleep_ms, report, sent) do
    case :gen_tcp.send(socket, chunk) do
      :ok ->
        Process.sleep(sleep_ms)
        pace(socket, chunk, remaining - 1, sleep_ms, report, sent + 1)

      {:error, _reason} ->
        %{report | chunks_sent: sent, completed?: false, closed?: true}
    end
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_status), do: "Status"
end
