defmodule Arbor.Common.Sanitizers.SSRFTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Common.Sanitizers
  alias Arbor.Common.Sanitizers.SSRF
  alias Arbor.Common.Sanitizers.SSRF.FinchPool
  alias Arbor.Contracts.Security.Taint

  @bit 0b00100000
  # Exercise the public-address path without making fast tests depend on public DNS.
  @public_ip "8.8.8.8"

  defmodule MixedResolver do
    def resolve_all(_host) do
      {:ok, [{8, 8, 8, 8}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]}
    end
  end

  defmodule PublicResolver do
    def resolve_all(_host), do: {:ok, [{8, 8, 8, 8}]}
  end

  defmodule LoopbackResolver do
    def resolve_all(_host), do: {:ok, [{127, 0, 0, 1}]}
  end

  defmodule LyingResolver do
    def resolve_all(_host), do: {:ok, [{8, 8, 8, 8}]}
  end

  defmodule SlowResolver do
    def resolve_all(_host) do
      Process.sleep(500)
      {:ok, [{8, 8, 8, 8}]}
    end
  end

  defmodule RebindingResolver do
    def resolve_all(_host) do
      Agent.get_and_update(__MODULE__.State, fn
        [answer | rest] -> {answer, rest}
        [] -> {{:error, :no_test_answer}, []}
      end)
    end
  end

  defmodule PacedServer do
    @moduledoc false

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
          receive do
            {:serve, ^listen} ->
              report = serve(listen, response_fun)
              :gen_tcp.close(listen)
              send(owner, {ref, report})
          end
        end)

      :ok = :gen_tcp.controlling_process(listen, pid)
      send(pid, {:serve, listen})

      {port, %{pid: pid, ref: ref}}
    end

    def await(%{ref: ref}, timeout \\ 10_000) do
      receive do
        {^ref, report} -> report
      after
        timeout -> raise "paced SSRF server did not report within #{timeout}ms"
      end
    end

    def stop(%{pid: pid}) do
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :ok
    end

    def paced(chunk, count, sleep_ms, headers \\ []) do
      fn socket ->
        head =
          ["HTTP/1.1 200 OK", "connection: close" | headers]
          |> Enum.join("\r\n")

        case :gen_tcp.send(socket, head <> "\r\n\r\n") do
          :ok -> pace(socket, chunk, count, sleep_ms, 0)
          {:error, reason} -> %{chunks_sent: 0, completed?: false, error: reason}
        end
      end
    end

    defp serve(listen, response_fun) do
      case :gen_tcp.accept(listen, 5_000) do
        {:ok, socket} ->
          _ = read_head(socket, "")
          report = response_fun.(socket)
          :gen_tcp.close(socket)
          report

        {:error, reason} ->
          %{chunks_sent: 0, completed?: false, error: reason}
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

  describe "sanitize/3" do
    test "valid public URL passes with bit set" do
      taint = %Taint{level: :untrusted}
      url = "https://#{@public_ip}/api"
      {:ok, ^url, updated} = SSRF.sanitize(url, taint)
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "rejects non-http scheme" do
      taint = %Taint{}
      assert {:error, {:blocked_scheme, "ftp"}} = SSRF.sanitize("ftp://evil.com", taint)
    end

    test "rejects file scheme" do
      taint = %Taint{}
      assert {:error, {:blocked_scheme, "file"}} = SSRF.sanitize("file:///etc/passwd", taint)
    end

    test "rejects missing host" do
      taint = %Taint{}
      assert {:error, _} = SSRF.sanitize("http://", taint)
    end

    test "rejects localhost" do
      taint = %Taint{}
      assert {:error, {:private_ip, "127.0.0.1"}} = SSRF.sanitize("http://localhost/admin", taint)
    end

    test "rejects 127.0.0.1 directly" do
      taint = %Taint{}
      assert {:error, {:private_ip, "127.0.0.1"}} = SSRF.sanitize("http://127.0.0.1/admin", taint)
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: rejects every private address returned by DNS" do
      taint = %Taint{}

      assert {:error, {:private_ip, _mapped_loopback}} =
               SSRF.sanitize("https://mixed.example/path", taint, resolver: MixedResolver)
    end

    @tag :security_regression
    test "security regression: a resolver cannot launder a private IP literal" do
      taint = %Taint{}

      assert {:error, {:private_ip, "127.0.0.1"}} =
               SSRF.sanitize("http://127.0.0.1/admin", taint, resolver: LyingResolver)
    end

    @tag :security_regression
    test "security regression: rejects a DNS name when the string result cannot preserve its pin" do
      taint = %Taint{}

      assert {:error, :dns_pinning_required} =
               SSRF.sanitize("https://public.example/path", taint, resolver: PublicResolver)
    end

    @tag :security_regression
    test "security regression: rejects omitted special-use IPv4 ranges" do
      taint = %Taint{}

      for url <- [
            "http://0.1.2.3/path",
            "http://100.64.0.1/path",
            "http://192.0.0.1/path",
            "http://192.0.2.1/path",
            "http://198.18.0.1/path",
            "http://198.51.100.1/path",
            "http://203.0.113.1/path",
            "http://224.0.0.1/path",
            "http://240.0.0.1/path"
          ] do
        assert {:error, {:private_ip, _address}} = SSRF.sanitize(url, taint)
      end
    end

    @tag :security_regression
    test "security regression: rejects non-global IPv6 literals" do
      taint = %Taint{}

      for url <- [
            "http://[ff02::1]/path",
            "http://[100::1]/path",
            "http://[2001:db8::1]/path",
            "http://[2002:7f00:1::]/path",
            "http://[3fff::1]/path"
          ] do
        assert {:error, {:private_ip, _address}} = SSRF.sanitize(url, taint)
      end
    end

    @tag :security_regression
    test "security regression: rejects IPv4-mapped IPv6 loopback" do
      taint = %Taint{}

      assert {:error, {:private_ip, _address}} =
               SSRF.sanitize("http://[::ffff:127.0.0.1]/admin", taint)
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: rejects IPv4-compatible IPv6 even with public low bits" do
      assert {:error, {:private_ip, _address}} =
               SSRF.sanitize("http://[::8.8.8.8]/path", %Taint{})
    end

    test "rejects cloud metadata endpoint" do
      taint = %Taint{}

      assert {:error, {:metadata_endpoint, "169.254.169.254"}} =
               SSRF.sanitize("http://169.254.169.254/latest/meta-data", taint)
    end

    test "rejects blocked port" do
      taint = %Taint{}
      assert {:error, {:blocked_port, 22}} = SSRF.sanitize("http://example.com:22/ssh", taint)
    end

    test "allows port 8080" do
      taint = %Taint{}
      {:ok, _, _} = SSRF.sanitize("http://#{@public_ip}:8080/api", taint)
    end

    test "allows private IPs when allow_private is true" do
      taint = %Taint{}
      {:ok, _, _} = SSRF.sanitize("http://127.0.0.1/api", taint, allow_private: true)
    end

    test "custom allowed schemes" do
      taint = %Taint{}

      {:ok, _, _} =
        SSRF.sanitize("ftp://#{@public_ip}/file", taint,
          allowed_schemes: ["ftp", "http", "https"],
          allowed_ports: [21, 80, 443, 8080, 8443]
        )
    end

    test "rejects invalid URL" do
      taint = %Taint{}
      assert {:error, {:invalid_url, _}} = SSRF.sanitize("not a url", taint)
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{sanitizations: 0b00000001}
      {:ok, _, updated} = SSRF.sanitize("https://#{@public_ip}", taint)
      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end
  end

  describe "req_options/3" do
    @tag :security_regression
    test "security regression: Req connects to the validated IP while preserving HTTPS authority" do
      parent = self()

      transport = fn request, _finch_name, _finch_options ->
        send(parent, {:pinned_request, request})
        {:ok, %Finch.Response{status: 200, body: "ok", headers: [], trailers: []}}
      end

      assert {:ok, options} =
               Sanitizers.ssrf_req_options("https://public.example/path", [],
                 resolver: PublicResolver,
                 finch_request: transport
               )

      assert options[:redirect] == false
      assert options[:max_redirects] == 0
      assert options[:retry] == false
      assert options[:compressed] == false
      assert options[:decode_body] == false
      assert options[:raw] == true
      assert options[:connect_options] == nil
      assert options[:finch] == FinchPool.req_name()

      assert {:ok, %Req.Response{status: 200, body: "ok"}} =
               Req.get("https://public.example/path", options)

      assert_receive {:pinned_request,
                      %Finch.Request{
                        scheme: :https,
                        host: {8, 8, 8, 8},
                        port: 443,
                        headers: headers
                      }}

      assert {"host", "public.example"} in headers
    end

    @tag :security_regression
    @tag :integration
    test "security regression: real Finch transport connects to the pin and sends original SNI" do
      owner = self()
      tls_config = :public_key.pkix_test_data(%{root: [], intermediates: [], peer: []})

      sni_fun = fn hostname ->
        send(owner, {:observed_sni, to_string(hostname)})
        :undefined
      end

      assert {:ok, listener} =
               :ssl.listen(
                 0,
                 tls_config ++
                   [active: false, reuseaddr: true, ip: {127, 0, 0, 1}, sni_fun: sni_fun]
               )

      on_exit(fn -> :ssl.close(listener) end)
      assert {:ok, {{127, 0, 0, 1}, port}} = :ssl.sockname(listener)

      server =
        Task.async(fn ->
          with {:ok, socket} <- :ssl.transport_accept(listener, 5_000) do
            result = :ssl.handshake(socket, 5_000)
            :ssl.close(socket)
            result
          end
        end)

      url = "https://public.example:#{port}/pinned"

      assert {:ok, options} =
               Sanitizers.ssrf_req_options(url, [retry: false, receive_timeout: 2_000],
                 resolver: LoopbackResolver,
                 allow_private: true,
                 allowed_ports: [port]
               )

      # The generated test certificate is intentionally not trusted. Reaching
      # its TLS listener and observing this SNI proves the actual Finch/Mint
      # connection used the validated tuple while retaining the URL hostname.
      assert {:error, _tls_verification_failure} = Req.get(url, options)
      assert_receive {:observed_sni, "public.example"}, 5_000
      assert {:error, _server_alert} = Task.await(server, 5_000)
    end

    @tag :security_regression
    test "security regression: DNS rebinding to loopback is refused before the transport" do
      start_supervised!(%{
        id: RebindingResolver.State,
        start:
          {Agent, :start_link,
           [
             fn -> [{:ok, [{8, 8, 8, 8}]}, {:ok, [{127, 0, 0, 1}]}] end,
             [name: RebindingResolver.State]
           ]}
      })

      parent = self()

      transport = fn _request, _finch_name, _finch_options ->
        send(parent, :unexpected_transport)
        {:error, :unexpected_transport}
      end

      assert {:ok, options} =
               Sanitizers.ssrf_req_options("https://rebind.example/path", [],
                 resolver: RebindingResolver,
                 finch_request: transport
               )

      assert {:error,
              %Req.TransportError{
                reason: {:ssrf_blocked, {:private_ip, "127.0.0.1"}}
              }} =
               Req.get("https://rebind.example/path", options)

      refute_received :unexpected_transport
    end

    @tag :security_regression
    test "security regression: caller cannot replace the pinned Req adapter" do
      assert {:error, {:unsafe_req_option, :adapter}} =
               Sanitizers.ssrf_req_options(
                 "https://public.example/path",
                 [adapter: fn request -> request end],
                 resolver: PublicResolver
               )

      assert {:error, {:unsafe_req_option, :plug}} =
               Sanitizers.ssrf_req_options(
                 "https://public.example/path",
                 [plug: fn conn -> conn end],
                 resolver: PublicResolver
               )

      assert {:error, {:unsafe_req_option, :into}} =
               Sanitizers.ssrf_req_options(
                 "https://public.example/path",
                 [into: :self],
                 resolver: PublicResolver
               )
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: slow DNS admission consumes the whole-request deadline" do
      timeout_ms = 100
      started_at = System.monotonic_time(:millisecond)

      assert {:error, {:request_timeout, ^timeout_ms}} =
               Sanitizers.ssrf_req_options(
                 "https://slow-resolver.example/path",
                 [receive_timeout: timeout_ms],
                 resolver: SlowResolver
               )

      assert System.monotonic_time(:millisecond) - started_at < 400
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: public SSRF Req options stop a paced body at one MiB" do
      chunk = String.duplicate("x", 8_192)
      chunk_count = 512
      {port, server} = PacedServer.start(PacedServer.paced(chunk, chunk_count, 3))
      on_exit(fn -> PacedServer.stop(server) end)

      url = "http://127.0.0.1:#{port}/paced"

      assert {:ok, options} =
               Sanitizers.ssrf_req_options(url, [receive_timeout: 10_000],
                 allow_private: true,
                 allowed_ports: [port]
               )

      assert {:error, %Req.TransportError{reason: {:response_bytes_exceeded, 1_048_576}}} =
               Req.get(url, options)

      report = PacedServer.await(server)
      refute report.completed?
      assert report.chunks_sent < chunk_count
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: hostile content encoding is never decompressed after the byte bound" do
      compressed = :zlib.gzip(String.duplicate("x", 2_097_152))

      {port, server} =
        PacedServer.start(
          PacedServer.paced(compressed, 1, 0, [
            "content-encoding: gzip",
            "content-length: #{byte_size(compressed)}"
          ])
        )

      on_exit(fn -> PacedServer.stop(server) end)
      url = "http://127.0.0.1:#{port}/compressed"

      assert {:ok, options} =
               Sanitizers.ssrf_req_options(url, [],
                 allow_private: true,
                 allowed_ports: [port]
               )

      assert {:error,
              %Req.TransportError{
                reason: {:invalid_response, :non_identity_content_encoding}
              }} = Req.get(url, options)
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: paced chunks cannot reset the whole-request deadline" do
      chunk = String.duplicate("z", 128)
      chunk_count = 200
      timeout_ms = 250
      {port, server} = PacedServer.start(PacedServer.paced(chunk, chunk_count, 25))
      on_exit(fn -> PacedServer.stop(server) end)

      url = "http://127.0.0.1:#{port}/slow-drip"

      assert {:ok, options} =
               Sanitizers.ssrf_req_options(url, [receive_timeout: timeout_ms],
                 allow_private: true,
                 allowed_ports: [port]
               )

      started_at = System.monotonic_time(:millisecond)
      assert {:error, %Req.TransportError{reason: :timeout}} = Req.get(url, options)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms < 1_000

      report = PacedServer.await(server)
      refute report.completed?
      assert report.chunks_sent < chunk_count
      assert_eventually(fn -> FinchPool.stats().active_slots == 0 end)
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: arbitrary hosts reuse a fixed transport cardinality and clean up" do
      for index <- 1..12 do
        {port, server} =
          PacedServer.start(PacedServer.paced("ok", 1, 0, ["content-length: 2"]))

        url = "http://host-#{index}.example:#{port}/bounded"

        assert {:ok, options} =
                 Sanitizers.ssrf_req_options(url, [receive_timeout: 2_000],
                   resolver: LoopbackResolver,
                   allow_private: true,
                   allowed_ports: [port]
                 )

        assert options[:connect_options] == nil
        assert {:ok, %Req.Response{body: "ok"}} = Req.get(url, options)
        assert %{capacity: 8} = FinchPool.stats()
        assert %{completed?: true} = PacedServer.await(server)
      end

      assert_eventually(fn -> FinchPool.stats().active_slots == 0 end)
    end
  end

  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(predicate, 0), do: assert(predicate.())

  describe "detect/1" do
    test "public URL is safe" do
      assert {:safe, 1.0} = SSRF.detect("https://example.com/api")
    end

    test "detects localhost" do
      {:unsafe, patterns} = SSRF.detect("http://localhost/admin")
      assert "localhost" in patterns
    end

    test "detects loopback IP" do
      {:unsafe, patterns} = SSRF.detect("http://127.0.0.1/admin")
      assert "loopback_ip" in patterns
    end

    test "detects private 10.x" do
      {:unsafe, patterns} = SSRF.detect("http://10.0.0.1/internal")
      assert "private_ip_10" in patterns
    end

    test "detects private 172.16.x" do
      {:unsafe, patterns} = SSRF.detect("http://172.16.0.1/internal")
      assert "private_ip_172" in patterns
    end

    test "detects private 192.168.x" do
      {:unsafe, patterns} = SSRF.detect("http://192.168.1.1/router")
      assert "private_ip_192" in patterns
    end

    test "detects link-local" do
      {:unsafe, patterns} = SSRF.detect("http://169.254.1.1/cloud")
      assert "link_local_ip" in patterns
    end

    test "detects AWS metadata" do
      {:unsafe, patterns} = SSRF.detect("http://169.254.169.254/latest")
      assert "aws_metadata" in patterns
    end

    test "detects GCP metadata" do
      {:unsafe, patterns} = SSRF.detect("http://metadata.google.internal/v1")
      assert "gcp_metadata" in patterns
    end

    test "detects unusual schemes" do
      {:unsafe, patterns} = SSRF.detect("gopher://internal:25/")
      assert "unusual_scheme" in patterns
    end

    test "detects credentials in URL" do
      {:unsafe, patterns} = SSRF.detect("http://admin:pass@internal/")
      assert "credentials_in_url" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = SSRF.detect(42)
    end
  end
end
