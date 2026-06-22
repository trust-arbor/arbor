defmodule ArborTui.WSClient do
  @moduledoc """
  WebSocket transport to the Gateway chat API (`/api/chat/socket`).

  A GenServer that owns a `Mint.WebSocket` connection: it performs the HTTP/1
  upgrade with a signed `Authorization` header (`ArborTui.Signer`), then pumps
  frames in both directions. Decoded server events (`ArborTui.Protocol`) are
  pushed into the TermUI runtime via `TermUI.Runtime.send_message(runtime,
  :root, {:server_event, event})`; the UI sends commands back via
  `send_command/2`.

  Connection-lifecycle changes (connecting/connected/closed/error) are reported
  to the runtime as `{:ws_status, status, detail}` so the status bar can render
  them. This process is intentionally decoupled from the UI loop — the only
  contract is the messages it sends to the runtime.
  """

  use GenServer

  require Logger

  alias ArborTui.{Protocol, Signer}

  @path "/api/chat/socket"

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Start the client.

  Options:
    * `:runtime` — the TermUI runtime (name or pid) to push events to (required)
    * `:identity` — `%{agent_id, private_key}` from `ArborTui.Signer` (required)
    * `:gateway_url` — e.g. `"ws://localhost:4000"` (required)
    * `:target_agent_id` — the agent to `attach` to on connect (required)
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts[:gen_opts] || [])

  @doc "Send a protocol command to the server (fire-and-forget)."
  @spec send_command(GenServer.server(), Protocol.command()) :: :ok
  def send_command(server, command), do: GenServer.cast(server, {:command, command})

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      runtime: Keyword.fetch!(opts, :runtime),
      identity: Keyword.fetch!(opts, :identity),
      gateway_url: Keyword.fetch!(opts, :gateway_url),
      target_agent_id: Keyword.fetch!(opts, :target_agent_id),
      conn: nil,
      ref: nil,
      websocket: nil,
      status: nil,
      resp_headers: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    notify(state, {:ws_status, :connecting, state.gateway_url})

    case connect(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        notify(state, {:ws_status, :error, inspect(reason)})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:command, command}, %{websocket: ws} = state) when ws != nil do
    {:noreply, send_frame(state, Protocol.encode(command))}
  end

  def handle_cast({:command, _command}, state) do
    # Not connected yet — drop (the UI shows the connection status).
    {:noreply, state}
  end

  @impl true
  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, handle_responses(%{state | conn: conn}, responses)}

      {:error, conn, reason, _responses} ->
        notify(state, {:ws_status, :error, inspect(reason)})
        {:noreply, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Connect + upgrade ──────────────────────────────────────────────────────

  defp connect(state) do
    uri = URI.parse(state.gateway_url)
    {http_scheme, ws_scheme} = schemes(uri.scheme)
    host = uri.host || "localhost"
    port = uri.port || default_port(uri.scheme)

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, host, port, protocols: [:http1]),
         headers = upgrade_headers(state, host, port),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, @path, headers) do
      {:ok, %{state | conn: conn, ref: ref}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp schemes("wss"), do: {:https, :wss}
  defp schemes("https"), do: {:https, :wss}
  defp schemes(_), do: {:http, :ws}

  defp default_port("wss"), do: 443
  defp default_port("https"), do: 443
  defp default_port(_), do: 80

  # The Authorization header is signed over the canonical GET request to @path
  # (empty body) — matching Arbor.Gateway.SignedRequestAuth's reconstruction.
  defp upgrade_headers(state, host, port) do
    [
      {"authorization", Signer.authorization_header(state.identity, "GET", @path, "")},
      {"host", "#{host}:#{port}"}
    ]
  end

  # ── Response handling (upgrade completion + frames) ─────────────────────────

  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, &handle_response/2)
  end

  defp handle_response({:status, ref, status}, %{ref: ref} = state),
    do: %{state | status: status}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state),
    do: complete_upgrade(%{state | resp_headers: headers})

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: ws} = state) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | websocket: ws}, &handle_frame/2)
      {:error, ws, _reason} -> %{state | websocket: ws}
    end
  end

  defp handle_response({:done, ref}, %{ref: ref} = state), do: state
  defp handle_response(_other, state), do: state

  defp complete_upgrade(%{conn: conn, ref: ref, status: status, resp_headers: headers} = state) do
    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        notify(state, {:ws_status, :connected, nil})
        # Attach to the target agent's :user engagement immediately.
        send_frame(state, Protocol.encode({:attach, state.target_agent_id, nil}))

      {:error, conn, reason} ->
        notify(state, {:ws_status, :error, inspect(reason)})
        %{state | conn: conn}
    end
  end

  # ── Outbound frames ──────────────────────────────────────────────────────

  defp send_frame(%{websocket: ws, conn: conn, ref: ref} = state, payload) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, {:text, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      %{state | websocket: ws, conn: conn}
    else
      {:error, %Mint.WebSocket{} = ws, reason} ->
        notify(state, {:ws_status, :error, inspect(reason)})
        %{state | websocket: ws}

      {:error, conn, reason} ->
        notify(state, {:ws_status, :error, inspect(reason)})
        %{state | conn: conn}
    end
  end

  # ── Inbound frames ───────────────────────────────────────────────────────

  defp handle_frame({:text, text}, state) do
    case Protocol.decode(text) do
      {:ok, event} -> notify(state, {:server_event, event})
      {:error, _} -> :ok
    end

    state
  end

  defp handle_frame({:ping, data}, state), do: send_control(state, {:pong, data})

  defp handle_frame({:close, _code, reason}, state) do
    notify(state, {:ws_status, :closed, to_string(reason)})
    state
  end

  defp handle_frame(_frame, state), do: state

  defp send_control(%{websocket: ws, conn: conn, ref: ref} = state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      %{state | websocket: ws, conn: conn}
    else
      _ -> state
    end
  end

  # ── Runtime delivery ───────────────────────────────────────────────────────

  defp notify(%{runtime: runtime}, message) do
    TermUI.Runtime.send_message(runtime, :root, message)
    :ok
  end
end
