defmodule Arbor.Voice.Backend.XaiTransportLifecycleTest do
  use ExUnit.Case, async: true
  alias Arbor.Voice.Backend.XaiRealtime.Transport
  @moduletag :fast

  defmodule Http do
    def connect(:https, _host, _port, opts) do
      send(self(), {:http_mode, Keyword.get(opts, :mode)})

      case Process.get(:transport_scenario) do
        :connect_error ->
          {:error, :refused}

        :connect_raise ->
          raise "private-connect-fault"

        _ ->
          {:ok, %{socket: :connected}}
      end
    end

    def get_socket(conn), do: conn.socket
    def close(conn), do: send(self(), {:mint_close, conn.socket})

    def recv(_, 0, timeout) when is_integer(timeout) and timeout > 0 do
      case Process.get(:transport_scenario) do
        :stream_error ->
          {:error, %{socket: :streamed}, :failed, []}

        :stream_raise ->
          raise "private-stream-fault"

        :incomplete_upgrade ->
          {:ok, %{socket: :streamed}, [{:done, :request}]}

        :coalesced ->
          {:ok, %{socket: :streamed},
           [
             {:status, :request, 101},
             {:headers, :request, []},
             {:data, :request, Process.get(:upgrade_frame_bytes)},
             {:done, :request}
           ]}

        _ ->
          {:ok, %{socket: :streamed},
           [{:status, :request, 101}, {:headers, :request, []}, {:done, :request}]}
      end
    end
  end

  defmodule Websocket do
    def upgrade(:wss, _, _, _) do
      case Process.get(:transport_scenario) do
        :upgrade_error -> {:error, %{socket: :upgraded}, :failed}
        :upgrade_raise -> raise "private-upgrade-fault"
        _ -> {:ok, %{socket: :upgraded}, :request}
      end
    end

    def new(_, _, _, _, opts) do
      send(self(), {:websocket_mode, Keyword.get(opts, :mode)})

      case Process.get(:transport_scenario) do
        :new_error -> {:error, %{socket: :newed}, :failed}
        :new_raise -> raise "private-new-fault"
        :coalesced -> {:ok, %{socket: :newed}, struct(Mint.WebSocket)}
        _ -> {:ok, %{socket: :newed}, :websocket}
      end
    end
  end

  defmodule Ssl do
    def close(socket) do
      send(self(), {:tls_close, socket})

      case Process.get(:transport_close, :ok) do
        :ok -> :ok
        :error -> {:error, :private_close_failure}
        :raise -> raise "private-close-fault"
      end
    end
  end

  defp connect(scenario, close \\ :ok) do
    Process.put(:transport_scenario, scenario)
    Process.put(:transport_close, close)
    Process.put(:transport_clock, 0)

    clock = fn ->
      n = Process.get(:transport_clock)
      Process.put(:transport_clock, n + 1)
      if scenario == :upgrade_timeout and n > 0, do: 90_000, else: 0
    end

    Transport.connect(
      [host: "fixed.invalid", port: 443, path: "/", token: "private-token", clock_fun: clock],
      {Http, Websocket, Ssl}
    )
  end

  test "security regression: each acquired connection is positively closed before startup rejection" do
    for {scenario, socket} <- [
          upgrade_error: :upgraded,
          upgrade_raise: :connected,
          upgrade_timeout: :upgraded,
          stream_error: :streamed,
          stream_raise: :upgraded,
          incomplete_upgrade: :streamed,
          new_error: :newed,
          new_raise: :streamed
        ] do
      assert {:error, :connect_failed, :closed} = connect(scenario)
      assert_receive {:tls_close, ^socket}
    end
  end

  test "security regression: cleanup error fault and unobserved acquisition remain unknown" do
    for mode <- [:error, :raise] do
      assert {:error, :connect_failed, :cleanup_pending} = connect(:new_error, mode)
      assert_receive {:tls_close, :newed}
    end

    assert {:error, :connect_failed, :cleanup_pending} = connect(:connect_raise)
    refute_receive {:tls_close, _}
  end

  test "no-handle rejection and success preserve their exact ownership disposition" do
    assert {:error, :connect_failed, :closed} = connect(:connect_error)
    refute_receive {:tls_close, _}
    assert {:ok, %{conn: %{socket: :newed}}} = connect(:ok)
    refute_receive {:tls_close, _}
  end

  test "HTTP and WebSocket remain passive from acquisition through upgrade" do
    assert {:ok, _} = connect(:ok)
    assert_receive {:http_mode, :passive}
    assert_receive {:websocket_mode, :passive}
  end

  test "coalesced upgrade bytes retain complete and partial WebSocket frames" do
    first = %{"type" => "ping"}
    second = %{"type" => "session.created", "session" => %{}}
    first_json = Jason.encode!(first)
    second_json = Jason.encode!(second)
    first_wire = <<0x81, byte_size(first_json), first_json::binary>>
    second_wire = <<0x81, byte_size(second_json), second_json::binary>>
    <<prefix::binary-size(5), suffix::binary>> = second_wire
    Process.put(:upgrade_frame_bytes, first_wire <> prefix)

    assert {:ok, state} = connect(:coalesced)
    assert {:ok, state, ^first} = Transport.recv_frame(state, 100)
    assert {:ok, _, [{:text, ^second_json}]} = Mint.WebSocket.decode(state.ws, suffix)
    assert state.pending == []
    refute_receive {:tls_close, _}
  end

  test "malformed coalesced upgrade data closes the latest acquired handle" do
    Process.put(:upgrade_frame_bytes, <<0x81, 1, "{">>)
    assert {:error, :connect_failed, :closed} = connect(:coalesced)
    assert_receive {:tls_close, :newed}
    refute_receive {:tls_close, :streamed}
  end

  test "security regression: final close checks TLS directly, not Mint's unconditional close envelope" do
    Process.put(:transport_close, :error)
    assert {:error, :close_failed} = Transport.close(%{conn: %{socket: :exact}}, {Http, Ssl})
    assert_receive {:tls_close, :exact}
    refute_receive {:mint_close, _}
    Process.put(:transport_close, :ok)
    assert :ok = Transport.close(%{conn: %{socket: :exact}}, {Http, Ssl})
  end

  test "checked TLS close remains idempotent for timeout retirement followed by owner close" do
    # OTP 28 ssl_gen_statem.close/2 maps the already-closed socket result to :ok.
    # Keep that contract in the fake: no real socket is created by this suite.
    Process.put(:transport_close, :ok)
    state = %{conn: %{socket: :exact}}
    assert :ok = Transport.close(state, {Http, Ssl})
    assert :ok = Transport.close(state, {Http, Ssl})
    assert_receive {:tls_close, :exact}
    assert_receive {:tls_close, :exact}
    refute_receive {:mint_close, _}
  end
end
