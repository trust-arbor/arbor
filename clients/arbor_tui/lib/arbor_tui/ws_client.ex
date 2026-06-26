defmodule ArborTui.WSClient do
  @moduledoc """
  WebSocket transport to the Gateway chat API (`/api/chat/socket`).

  A GenServer that owns a `Mint.WebSocket` connection: it performs the HTTP/1
  upgrade with a signed `Authorization` header (`ArborTui.Signer`), then pumps
  frames in both directions. Decoded server events (`ArborTui.Protocol`) are
  pushed into the TermUI runtime via `TermUI.Runtime.send_message(runtime,
  :root, {:server_event, event})`; the UI sends commands back via
  `send_command/2`.

  Connection-lifecycle changes (connecting/connected/reconnecting/closed/error)
  are reported to the runtime as `{:ws_status, status, detail}` so the status
  bar can render them. This process is intentionally decoupled from the UI loop —
  the only contract is the messages it sends to the runtime.

  ## Auto-reconnect

  Every disconnect path — the server `:close` frame, a transport error from
  `Mint.WebSocket.stream`, an outbound `send_frame`/upgrade failure, and an
  initial-connect failure — funnels into `schedule_reconnect/2`. The connection
  is torn down (`reset_conn/1`) while identity/url/target stay, an attempt
  counter is incremented, and a `:reconnect` is scheduled after a jittered
  exponential-backoff delay (`backoff_window/1`, capped at 30s, retried
  indefinitely). On a successful upgrade the attempt counter resets to 0 and any
  pending reconnect timer is cancelled. The UI never wipes its transcript across
  a reconnect — the server replays the engagement transcript on re-attach.
  """

  use GenServer

  require Logger

  alias ArborTui.{Protocol, Signer}

  @path "/api/chat/socket"

  # Backoff schedule: base 500ms, doubling per attempt, capped at 30s.
  @base_backoff_ms 500
  @max_backoff_ms 30_000

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

  @doc """
  The jittered backoff window for a reconnect `attempt` (1-based).

  Pure and exported so the schedule is testable. The window is
  `base 500ms * 2^(attempt-1)`, capped at 30_000ms, returned as a
  `{ceil(window/2), window}` jitter pair — the actual delay is picked uniformly
  inside that window. Retries are indefinite (the window simply pins at the cap).
  """
  @spec backoff_window(pos_integer()) :: {pos_integer(), pos_integer()}
  def backoff_window(attempt) when is_integer(attempt) and attempt >= 1 do
    window =
      @base_backoff_ms
      |> Kernel.*(pow2(attempt - 1))
      |> min(@max_backoff_ms)

    {ceil_div(window, 2), window}
  end

  # 2^n without floats (avoids :math.pow precision drift at large n).
  defp pow2(n) when n >= 0, do: Bitwise.bsl(1, n)

  defp ceil_div(n, d), do: div(n + d - 1, d)

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
      resp_headers: nil,
      # Reconnect bookkeeping (survives reset_conn/1).
      attempt: 0,
      reconnect_timer: nil
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
        {:noreply, schedule_reconnect(state, "connect failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_cast({:command, command}, %{websocket: ws} = state) when ws != nil do
    {:noreply, send_frame(state, Protocol.encode(command))}
  end

  def handle_cast({:command, _command}, state) do
    # Not connected (or reconnecting) — drop (the UI shows the connection status).
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    # Re-run the same connect continuation (re-signs the upgrade header and
    # re-attaches to the same target_agent_id on success).
    {:noreply, _state} = handle_continue(:connect, %{state | reconnect_timer: nil})
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, handle_responses(%{state | conn: conn}, responses)}

      {:error, _conn, reason, _responses} ->
        {:noreply, schedule_reconnect(state, "transport error: #{inspect(reason)}")}

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
        # Successful upgrade — clear the backoff counter + any pending retry.
        state = clear_reconnect(%{state | conn: conn, websocket: websocket, attempt: 0})
        notify(state, {:ws_status, :connected, nil})
        # Attach to the target agent's :user engagement immediately.
        send_frame(state, Protocol.encode({:attach, state.target_agent_id, nil}))

      {:error, _conn, reason} ->
        schedule_reconnect(state, "upgrade failed: #{inspect(reason)}")
    end
  end

  # ── Outbound frames ──────────────────────────────────────────────────────

  defp send_frame(%{websocket: ws, conn: conn, ref: ref} = state, payload) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, {:text, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      %{state | websocket: ws, conn: conn}
    else
      {:error, %Mint.WebSocket{}, reason} ->
        schedule_reconnect(state, "send failed: #{inspect(reason)}")

      {:error, _conn, reason} ->
        schedule_reconnect(state, "send failed: #{inspect(reason)}")
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
    # The server closed the socket — reconnect rather than going terminal.
    schedule_reconnect(state, "server closed: #{to_string(reason)}")
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

  # ── Reconnect ──────────────────────────────────────────────────────────────

  # Tear down the half-open Mint connection and clear per-connection fields, but
  # KEEP identity/url/target_agent_id and the attempt counter so a retry can
  # re-sign + re-attach.
  defp reset_conn(%{conn: conn} = state) do
    if conn do
      try do
        Mint.HTTP.close(conn)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    %{state | conn: nil, ref: nil, websocket: nil, status: nil, resp_headers: nil}
  end

  # Funnel for every disconnect path: tear down, bump the attempt counter,
  # schedule a jittered :reconnect, and tell the UI we're reconnecting.
  defp schedule_reconnect(state, detail) do
    state = state |> clear_reconnect() |> reset_conn()
    attempt = state.attempt + 1
    {lo, hi} = backoff_window(attempt)
    delay = lo + :rand.uniform(hi - lo + 1) - 1

    timer = Process.send_after(self(), :reconnect, delay)

    state = %{state | attempt: attempt, reconnect_timer: timer}

    notify(
      state,
      {:ws_status, :reconnecting, "#{detail} — attempt #{attempt}, retrying in #{delay}ms"}
    )

    state
  end

  defp clear_reconnect(%{reconnect_timer: nil} = state), do: state

  defp clear_reconnect(%{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end

  # ── Runtime delivery ───────────────────────────────────────────────────────

  defp notify(%{runtime: runtime}, message) do
    TermUI.Runtime.send_message(runtime, :root, message)
    :ok
  end
end
