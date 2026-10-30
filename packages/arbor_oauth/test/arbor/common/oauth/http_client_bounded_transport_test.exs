defmodule Arbor.Common.OAuth.HttpClientBoundedTransportTest do
  @moduledoc """
  Transport-level proof that the response byte budget is enforced by the
  collector, not by a post-hoc size check.

  The server writes **paced** chunks and reports whether it managed to finish.
  A client that buffered the whole body would let every chunk through, so
  `completed?: false` is itself the proof that the socket was torn down early —
  no OS-specific byte threshold is asserted, which keeps the test portable
  across macOS/Linux/CI socket-buffer sizes.

  Header tests separately prove Mint's parser-level aggregate bound and the
  facade's stricter post-parse shape validation.

  Loopback only (`127.0.0.1` literal, ephemeral port): no DNS, no egress.
  """

  use ExUnit.Case, async: true

  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.{Request, Response}

  @moduletag :fast

  @chunk_size 8_192
  @chunk_count 512
  @pace_ms 5

  defmodule Server do
    @moduledoc false
    # Minimal :gen_tcp HTTP server. arbor_common has no plug/bandit dep, and
    # duplicating ~60 lines here is preferable to a test-only dependency on
    # another app's support tree.

    def start(response_fun) do
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          ip: {127, 0, 0, 1},
          active: false,
          reuseaddr: true,
          packet: :raw
        ])

      {:ok, port} = :inet.port(listen)
      owner = self()
      ref = make_ref()

      pid =
        spawn(fn ->
          report =
            case :gen_tcp.accept(listen, 5_000) do
              {:ok, socket} ->
                _ = read_head(socket, "")
                result = response_fun.(socket)
                :gen_tcp.close(socket)
                result

              {:error, reason} ->
                %{chunks_sent: 0, completed?: false, error: reason}
            end

          :gen_tcp.close(listen)
          send(owner, {ref, report})
        end)

      :ok = :gen_tcp.controlling_process(listen, pid)
      {"http://127.0.0.1:#{port}/token", %{pid: pid, ref: ref}}
    end

    def await(%{ref: ref}, timeout \\ 15_000) do
      receive do
        {^ref, report} -> report
      after
        timeout -> raise "bounded transport server did not report within #{timeout}ms"
      end
    end

    def stop(%{pid: pid}), do: Process.exit(pid, :kill)

    def paced(headers, chunk, count, sleep_ms) do
      fn socket ->
        head = ["HTTP/1.1 200 OK", "connection: close" | headers] |> Enum.join("\r\n")

        case :gen_tcp.send(socket, head <> "\r\n\r\n") do
          :ok -> pace(socket, chunk, count, sleep_ms, 0)
          {:error, reason} -> %{chunks_sent: 0, completed?: false, error: reason}
        end
      end
    end

    def paced_unterminated_header(chunk, count, sleep_ms) do
      fn socket ->
        case :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nx-flood: ") do
          :ok -> pace(socket, chunk, count, sleep_ms, 0)
          {:error, reason} -> %{chunks_sent: 0, completed?: false, error: reason}
        end
      end
    end

    defp pace(_socket, _chunk, 0, _sleep_ms, sent),
      do: %{chunks_sent: sent, completed?: true, error: nil}

    defp pace(socket, chunk, remaining, sleep_ms, sent) do
      case :gen_tcp.send(socket, chunk) do
        :ok ->
          Process.sleep(sleep_ms)
          pace(socket, chunk, remaining - 1, sleep_ms, sent + 1)

        {:error, reason} ->
          %{chunks_sent: sent, completed?: false, error: reason}
      end
    end

    defp read_head(socket, acc) do
      if String.contains?(acc, "\r\n\r\n") do
        {:ok, acc}
      else
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_head(socket, acc <> data)
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp get(url, max_response_bytes, timeout_ms \\ 10_000) do
    HttpClient.request(%Request{
      method: :get,
      url: url,
      headers: [],
      max_response_bytes: max_response_bytes,
      timeout_ms: timeout_ms
    })
  end

  describe "security regression: transport-level response bound" do
    test "an endless connection-close body halts before the server can finish" do
      chunk = String.duplicate("x", @chunk_size)

      {url, server} =
        Server.start(
          Server.paced(
            encode([{"content-type", "application/json"}]),
            chunk,
            @chunk_count,
            @pace_ms
          )
        )

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:response_bytes_exceeded, 8_192}} = get(url, 8_192)

      report = Server.await(server)
      refute report.completed?
      assert report.chunks_sent < @chunk_count
    end

    test "a Content-Length far above the budget is halted by the collector" do
      chunk = String.duplicate("y", @chunk_size)
      declared = @chunk_size * @chunk_count

      {url, server} =
        Server.start(
          Server.paced(
            encode([
              {"content-type", "application/json"},
              {"content-length", Integer.to_string(declared)}
            ]),
            chunk,
            @chunk_count,
            @pace_ms
          )
        )

      on_exit(fn -> Server.stop(server) end)

      # Framing says 4 MiB is coming; the collector stops at the budget rather
      # than reading to the declared length.
      assert {:error, {:response_bytes_exceeded, 8_192}} = get(url, 8_192)

      report = Server.await(server)
      refute report.completed?
      assert report.chunks_sent < @chunk_count
    end

    test "slow-drip chunks cannot reset the whole-request deadline" do
      chunk = String.duplicate("z", 128)
      chunk_count = 100
      timeout_ms = 150

      {url, server} =
        Server.start(
          Server.paced(
            encode([{"content-type", "application/json"}]),
            chunk,
            chunk_count,
            25
          )
        )

      on_exit(fn -> Server.stop(server) end)

      started_at = System.monotonic_time(:millisecond)
      assert {:error, {:timeout, ^timeout_ms}} = get(url, 65_536, timeout_ms)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms < 1_000

      report = Server.await(server)
      refute report.completed?
      assert report.chunks_sent < chunk_count
    end

    test "security regression: HTTP/1 header accumulation is stopped by the parser bound" do
      chunk = String.duplicate("h", @chunk_size)
      chunk_count = 128

      {url, server} =
        Server.start(Server.paced_unterminated_header(chunk, chunk_count, @pace_ms))

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:transport_error, _reason}} = get(url, 65_536, 2_000)

      report = Server.await(server)
      refute report.completed?
      assert report.chunks_sent < chunk_count
    end

    test "an individually oversized HTTP/1 header is rejected by the facade" do
      header_value = String.duplicate("h", 4_097)

      {url, server} =
        Server.start(fn socket ->
          head =
            [
              "HTTP/1.1 200 OK",
              "x-oversized: #{header_value}",
              "content-length: 0",
              "connection: close"
            ]
            |> Enum.join("\r\n")

          :gen_tcp.send(socket, head <> "\r\n\r\n")
          %{chunks_sent: 0, completed?: true, error: nil}
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:invalid_response, :invalid_headers}} = get(url, 65_536)
    end

    test "a non-identity content-encoding is refused rather than decompressed" do
      payload = :zlib.gzip(Jason.encode!(%{"id_token" => String.duplicate("t", 100)}))

      {url, server} =
        Server.start(fn socket ->
          head =
            [
              "HTTP/1.1 200 OK",
              "content-type: application/json",
              "content-encoding: gzip",
              "content-length: #{byte_size(payload)}",
              "connection: close"
            ]
            |> Enum.join("\r\n")

          :gen_tcp.send(socket, head <> "\r\n\r\n" <> payload)
          %{chunks_sent: 1, completed?: true, error: nil}
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:invalid_response, :non_identity_content_encoding}} = get(url, 65_536)
    end

    test "a body inside the budget is returned raw and undecoded" do
      body = Jason.encode!(%{"id_token" => "abc", "expires_in" => 60})

      {url, server} =
        Server.start(fn socket ->
          head =
            [
              "HTTP/1.1 200 OK",
              "content-type: application/json",
              "content-length: #{byte_size(body)}",
              "connection: close"
            ]
            |> Enum.join("\r\n")

          :gen_tcp.send(socket, head <> "\r\n\r\n" <> body)
          %{chunks_sent: 1, completed?: true, error: nil}
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:ok, %Response{status: 200, body: ^body}} = get(url, 65_536)
    end
  end

  defp encode(headers), do: Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)
end
