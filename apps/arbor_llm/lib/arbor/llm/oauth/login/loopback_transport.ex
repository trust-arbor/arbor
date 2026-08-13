defmodule Arbor.LLM.OAuth.Login.LoopbackTransport do
  @moduledoc false

  @behaviour :ranch_transport

  @request_line_timeout_ms 2_000
  @max_request_line_bytes 5_000

  def name, do: :ranch_tcp.name()
  def secure, do: :ranch_tcp.secure()
  def messages, do: :ranch_tcp.messages()
  def listen(opts), do: :ranch_tcp.listen(opts)
  def accept(socket, timeout), do: :ranch_tcp.accept(socket, timeout)

  def handshake(socket, timeout) do
    with :ok <- preflight_request_target(socket, timeout) do
      :ranch_tcp.handshake(socket, timeout)
    end
  end

  def handshake(socket, opts, timeout) do
    with :ok <- preflight_request_target(socket, timeout) do
      :ranch_tcp.handshake(socket, opts, timeout)
    end
  end

  def handshake_continue(socket, timeout), do: :ranch_tcp.handshake_continue(socket, timeout)

  def handshake_continue(socket, opts, timeout),
    do: :ranch_tcp.handshake_continue(socket, opts, timeout)

  def handshake_cancel(socket), do: :ranch_tcp.handshake_cancel(socket)
  def connect(host, port, opts), do: :ranch_tcp.connect(host, port, opts)
  def connect(host, port, opts, timeout), do: :ranch_tcp.connect(host, port, opts, timeout)

  def recv(socket, length, timeout), do: :ranch_tcp.recv(socket, length, timeout)

  def recv_proxy_header(socket, timeout), do: :ranch_tcp.recv_proxy_header(socket, timeout)
  def send(socket, data), do: :ranch_tcp.send(socket, data)
  def sendfile(socket, file), do: :ranch_tcp.sendfile(socket, file)
  def sendfile(socket, file, offset, bytes), do: :ranch_tcp.sendfile(socket, file, offset, bytes)

  def sendfile(socket, file, offset, bytes, opts),
    do: :ranch_tcp.sendfile(socket, file, offset, bytes, opts)

  def setopts(socket, opts), do: :ranch_tcp.setopts(socket, opts)
  def getopts(socket, opts), do: :ranch_tcp.getopts(socket, opts)
  def getstat(socket), do: :ranch_tcp.getstat(socket)
  def getstat(socket, opts), do: :ranch_tcp.getstat(socket, opts)
  def controlling_process(socket, pid), do: :ranch_tcp.controlling_process(socket, pid)
  def peername(socket), do: :ranch_tcp.peername(socket)
  def sockname(socket), do: :ranch_tcp.sockname(socket)
  def shutdown(socket, direction), do: :ranch_tcp.shutdown(socket, direction)
  def close(socket), do: :ranch_tcp.close(socket)
  def cleanup(opts), do: :ranch_tcp.cleanup(opts)
  def format_error(reason), do: :ranch_tcp.format_error(reason)

  defp preflight_request_target(socket, timeout) do
    deadline = System.monotonic_time(:millisecond) + min_timeout(timeout)
    preflight_request_target(socket, deadline, "")
  end

  defp preflight_request_target(socket, deadline, acc) do
    with :ok <- within_request_line_bound(acc),
         {:ok, remaining} <- remaining_ms(deadline),
         {:ok, data} <- :ranch_tcp.recv(socket, 0, remaining) do
      combined = acc <> data

      with :ok <- within_request_line_bound(combined) do
        case :binary.match(combined, "\r\n") do
          {line_end, 2} -> validate_request_target(socket, combined, line_end)
          :nomatch -> preflight_request_target(socket, deadline, combined)
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_request_target(socket, data, line_end) do
    line = binary_part(data, 0, line_end)

    case :binary.split(line, " ", [:global]) do
      [_method, target, _version] ->
        if absolute_http_target?(target), do: reject(socket), else: restore(socket, data)

      _invalid ->
        restore(socket, data)
    end
  end

  defp restore(socket, data) do
    case :gen_tcp.unrecv(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp absolute_http_target?(<<h, t1, t2, p, ?:, ?/, ?/, _rest::binary>>)
       when h in [?h, ?H] and t1 in [?t, ?T] and t2 in [?t, ?T] and p in [?p, ?P],
       do: true

  defp absolute_http_target?(<<h, t1, t2, p, s, ?:, ?/, ?/, _rest::binary>>)
       when h in [?h, ?H] and t1 in [?t, ?T] and t2 in [?t, ?T] and p in [?p, ?P] and
              s in [?s, ?S],
       do: true

  defp absolute_http_target?(_target), do: false

  defp reject(socket) do
    :ranch_tcp.close(socket)
    {:error, :closed}
  end

  defp within_request_line_bound(data) do
    if byte_size(data) <= @max_request_line_bytes,
      do: :ok,
      else: {:error, :closed}
  end

  defp remaining_ms(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, :timeout}
  end

  defp min_timeout(:infinity), do: @request_line_timeout_ms
  defp min_timeout(timeout) when is_integer(timeout), do: min(timeout, @request_line_timeout_ms)
end
