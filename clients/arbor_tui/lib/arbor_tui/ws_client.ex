defmodule ArborTui.WSClient do
  @moduledoc """
  WebSocket transport to the Gateway chat API (`/api/chat/socket`).

  A GenServer that owns a `Mint.WebSocket` connection: it performs the HTTP/1
  upgrade with a signed `Authorization` header (`ArborTui.Signer`), then signs
  every conversation operation independently. History and journal pages are
  polled with separate cursors and fresh one-use proofs. Decoded server events (`ArborTui.Protocol`) are
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
    * `:target_agent_id` — the agent to `attach` to on connect, or `nil` to
      start IDLE (no connection until `connect_to/2` is called) (required key,
      `nil` allowed)
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts[:gen_opts] || [])

  @doc "Send a protocol command to the server (fire-and-forget)."
  @spec send_command(GenServer.server(), Protocol.command()) :: :ok
  def send_command(server, command), do: GenServer.cast(server, {:command, command})

  @doc """
  Set (or switch) the target agent and (re)connect to it.

  Tears down any existing connection, resets the reconnect attempt counter, and
  initiates a fresh signed upgrade + attach to `agent_id`. Use this to attach
  from an idle (unattached) start, or to switch agents.
  """
  @spec connect_to(GenServer.server(), String.t()) :: :ok
  def connect_to(server, agent_id), do: GenServer.cast(server, {:connect_to, agent_id})

  @doc """
  Change the gateway URL and reconnect (re-attaching to the current target if
  one is set). A no-op for the connection if there is no target yet.
  """
  @spec set_url(GenServer.server(), String.t()) :: :ok
  def set_url(server, url), do: GenServer.cast(server, {:set_url, url})

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
      reconnect_timer: nil,
      # Whether the CURRENT target has ever successfully attached. The first
      # attach is best-effort (failure → detached, no retry); only AFTER a
      # successful attach does a later drop trigger indefinite backoff-reconnect.
      # Reset to false on init/connect_to/set_url (a fresh target).
      attached?: false,
      history: [],
      history_cursor: 0,
      engagement_id: nil,
      event_cursor: 0,
      poll_timer: nil,
      last_command: nil,
      command_attempts: 0
    }

    # No target yet → start IDLE: no connection until connect_to/2 sets one.
    if state.target_agent_id do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    notify(state, {:ws_status, :connecting, state.gateway_url})

    result = with {:ok, state} <- resolve_target(state), do: connect(state)

    case result do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        {:noreply, schedule_reconnect(state, "connect failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_cast({:command, {:send, "/" <> _}}, state) do
    notify(
      state,
      {:server_event,
       {:error,
        "Server slash commands are unavailable during conversation migration; local /help lists supported controls."}}
    )

    {:noreply, state}
  end

  def handle_cast({:command, {:send, text}}, %{websocket: ws, attached?: true} = state)
      when ws != nil do
    if state.last_command &&
         state.last_command["status"] in ["admitted", "dispatch_started", "transport_unknown"] do
      notify(
        state,
        {:server_event,
         {:error,
          "A delivery is still unresolved. Use /retry to query or retry that exact command."}}
      )

      {:noreply, state}
    else
      id = "tui_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      command = %{"id" => id, "text" => text, "status" => "transport_unknown"}
      state = %{state | last_command: command, command_attempts: 1}
      notify(state, {:server_event, {:conversation_command, command}})
      {:noreply, send_operation(state, :submit, %{id: id, text: text})}
    end
  end

  def handle_cast({:command, :retry}, %{websocket: ws, last_command: command} = state)
      when ws != nil and is_map(command) do
    # A retry preserves the exact admitted id and text, but signs a fresh proof.
    # The host journal decides whether admission, lookup or no redispatch applies.
    state = %{state | command_attempts: state.command_attempts + 1}
    {:noreply, send_operation(state, :submit, %{id: command["id"], text: command["text"]})}
  end

  def handle_cast({:command, _command}, %{websocket: ws} = state) when ws != nil do
    notify(
      state,
      {:server_event,
       {:error, "This server control is unavailable on the authenticated conversation transport."}}
    )

    {:noreply, state}
  end

  def handle_cast({:command, _command}, state) do
    notify(state, {:server_event, {:error, "Not connected; message was not sent."}})
    {:noreply, state}
  end

  # Set/switch the target agent and (re)connect. Tear down any live connection,
  # reset the attempt counter, then run the connect continuation (which signs a
  # fresh upgrade and attaches to the new target on success).
  def handle_cast({:connect_to, agent_id}, state) do
    state =
      state
      |> clear_reconnect()
      |> reset_conn()
      |> Map.merge(%{
        target_agent_id: agent_id,
        attempt: 0,
        attached?: false,
        history: [],
        history_cursor: 0,
        engagement_id: nil,
        event_cursor: 0,
        last_command: nil
      })

    {:noreply, _state} = handle_continue(:connect, state)
  end

  # Change the gateway URL. Reconnect only if a target is set; otherwise just
  # record the new URL for the next connect_to/2.
  def handle_cast({:set_url, url}, %{target_agent_id: nil} = state) do
    {:noreply, %{state | gateway_url: url}}
  end

  def handle_cast({:set_url, url}, state) do
    state =
      state
      |> clear_reconnect()
      |> reset_conn()
      |> Map.merge(%{
        gateway_url: url,
        attempt: 0,
        attached?: false,
        history: [],
        history_cursor: 0,
        engagement_id: nil,
        event_cursor: 0,
        last_command: nil
      })

    {:noreply, _state} = handle_continue(:connect, state)
  end

  @impl true
  def handle_info(:reconnect, state) do
    # Re-run the same connect continuation (re-signs the upgrade header and
    # re-attaches to the same target_agent_id on success).
    {:noreply, _state} = handle_continue(:connect, %{state | reconnect_timer: nil})
  end

  def handle_info(:poll_conversation, %{websocket: ws, attached?: true} = state) when ws != nil do
    state = %{state | poll_timer: nil}
    state = send_operation(state, :history, nil, after: state.history_cursor, limit: 100)

    state =
      if state.websocket,
        do: send_operation(state, :events, state.event_cursor, limit: 100),
        else: state

    {:noreply, state}
  end

  def handle_info(:poll_conversation, state), do: {:noreply, %{state | poll_timer: nil}}

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

  defp resolve_target(state) do
    if Regex.match?(~r/\Aagent_[0-9a-f]{64}\z/, state.target_agent_id) do
      {:ok, state}
    else
      case ArborTui.AgentsClient.resolve(state.identity, state.gateway_url, state.target_agent_id) do
        {:ok, target} -> {:ok, %{state | target_agent_id: target}}
        error -> error
      end
    end
  end

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
        # Attach to the target agent's :user engagement immediately (a target is
        # always set on any path that reaches connect — guarded for safety).
        if state.target_agent_id do
          send_operation(state, :history, nil, after: state.history_cursor, limit: 100)
        else
          state
        end

      {:error, _conn, reason} ->
        schedule_reconnect(state, "upgrade failed: #{inspect(reason)}")
    end
  end

  # ── Outbound frames ──────────────────────────────────────────────────────

  defp send_operation(%{websocket: nil} = state, _operation, _input, _opts), do: state

  defp send_operation(state, operation, input, opts) do
    opts =
      if state.engagement_id,
        do: Keyword.put(opts, :expected_engagement_id, state.engagement_id),
        else: opts

    send_frame(
      state,
      Protocol.signed_operation(state.identity, state.target_agent_id, operation, input, opts)
    )
  end

  defp send_operation(state, operation, input), do: send_operation(state, operation, input, [])

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

  # A scope-change error can be followed by already-decoded frames from the old
  # connection in the same packet. Once detached, none may repopulate the UI.
  defp handle_frame(_frame, %{websocket: nil} = state), do: state

  defp handle_frame({:text, text}, state) do
    case Protocol.decode(text) do
      {:ok, event} ->
        handle_conversation_event(event, state)

      {:error, _} ->
        state
    end
  end

  defp handle_frame({:ping, data}, state), do: send_control(state, {:pong, data})

  defp handle_frame({:close, _code, reason}, state) do
    # The server closed the socket — reconnect rather than going terminal.
    schedule_reconnect(state, "server closed: #{to_string(reason)}")
  end

  defp handle_frame(_frame, state), do: state

  defp handle_conversation_event({type, page}, %{engagement_id: pinned} = state)
       when type in [:conversation_history, :conversation_events] and not is_nil(pinned) and
              (not is_map_key(page, "engagement_id") or
                 :erlang.map_get("engagement_id", page) != pinned) do
    scope_changed(state)
  end

  defp handle_conversation_event({:conversation_history, page}, state) do
    entries = Enum.uniq_by(state.history ++ page["entries"], & &1["id"])
    history = Enum.sort_by(entries, & &1["entry_ordinal"])
    event = %{id: page["engagement_id"], transcript: history, display_name: page["agent_id"]}

    if not state.attached? do
      notify(state, {:server_event, {:engagement, event}})
    else
      if history != state.history,
        do: notify(state, {:server_event, {:conversation_history, event}})
    end

    state = %{
      state
      | history: history,
        history_cursor: page["cursor"],
        engagement_id: page["engagement_id"],
        attached?: true
    }

    if page["has_more"] do
      send_operation(state, :history, nil,
        after: page["cursor"],
        through: page["head"],
        limit: 100
      )
    else
      schedule_poll(state)
    end
  end

  defp handle_conversation_event({:conversation_events, page}, state) do
    state =
      Enum.reduce(page["events"], state, fn event, acc ->
        command = event["command"]

        if acc.last_command && command["id"] == acc.last_command["id"],
          do: handle_conversation_event({:conversation_command, command}, acc),
          else: acc
      end)

    state = %{state | event_cursor: page["cursor"]}

    if page["has_more"],
      do: send_operation(state, :events, page["cursor"], through: page["head"], limit: 100),
      else: schedule_poll(state)
  end

  defp handle_conversation_event({:conversation_rejected, rejection}, state) do
    case classify_rejection(state.last_command, state.command_attempts, rejection) do
      {:definite, command} ->
        notify(
          state,
          {:server_event, {:conversation_rejected, Map.put(rejection, "text", command["text"])}}
        )

        %{state | last_command: nil, command_attempts: 0}

      :preserve ->
        notify(
          state,
          {:server_event,
           {:error,
            "Request rejected: #{rejection["reason"]}. Earlier delivery state remains unchanged."}}
        )

        state
    end
  end

  defp handle_conversation_event(
         {:conversation_command, %{"id" => id} = command},
         %{last_command: %{"id" => id}} = state
       ) do
    if command != state.last_command,
      do: notify(state, {:server_event, {:conversation_command, command}})

    %{state | last_command: command}
  end

  # A retry response can arrive after the user has started another command.
  # Only the current command may change the pending delivery or its UI status.
  defp handle_conversation_event({:conversation_command, _command}, state), do: state

  defp handle_conversation_event({:error, "conversation_scope_changed"}, state),
    do: scope_changed(state)

  defp handle_conversation_event({:error, reason} = event, state) do
    notify(state, {:server_event, event})

    if reason in ["unauthorized", "not_attached"],
      do: detach(state, reason),
      else: schedule_poll(state)
  end

  defp handle_conversation_event(event, state) do
    notify(state, {:server_event, event})
    state
  end

  defp scope_changed(state) do
    notify(
      state,
      {:server_event,
       {:conversation_reset,
        "Conversation ownership changed. Draft and pending retry were cleared; reconnect explicitly."}}
    )

    state = %{
      state
      | history: [],
        history_cursor: 0,
        engagement_id: nil,
        event_cursor: 0,
        last_command: nil
    }

    detach(state, "Conversation ownership changed")
  end

  @doc false
  def classify_rejection(%{"id" => id, "status" => "transport_unknown"} = command, 1, %{
        "id" => id,
        "reason" => reason
      })
      when reason in [
             "unsupported_conversation_capability",
             "invalid_command",
             "command_conflict"
           ],
      do: {:definite, command}

  def classify_rejection(_, _, _), do: :preserve

  defp schedule_poll(%{poll_timer: nil, websocket: ws} = state) when ws != nil,
    do: %{state | poll_timer: Process.send_after(self(), :poll_conversation, 1_000)}

  defp schedule_poll(state), do: state

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

    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    %{
      state
      | conn: nil,
        ref: nil,
        websocket: nil,
        status: nil,
        resp_headers: nil,
        poll_timer: nil
    }
  end

  # Funnel for every disconnect path. The behaviour forks on whether this target
  # has EVER successfully attached:
  #
  #   * attached? == true  → an established connection dropped (e.g. the server
  #     restarted): tear down + indefinite jittered backoff-reconnect.
  #   * attached? == false → the FIRST attach to this target never succeeded
  #     (gateway down, agent not running, unauthorized, upgrade rejected): go
  #     DETACHED best-effort — no retry-spam against a dead/forbidden agent.
  defp schedule_reconnect(%{attached?: false} = state, detail),
    do: detach(state, detail)

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

  # Best-effort give-up: tear down, clear the target, and tell the UI we're
  # detached (so it can prompt for /agent <id> to retry). No reconnect timer.
  defp detach(state, detail) do
    short = short_id(state.target_agent_id)
    state = state |> clear_reconnect() |> reset_conn()
    state = %{state | target_agent_id: nil, attempt: 0, attached?: false}

    notify(
      state,
      {:ws_status, :detached,
       "Couldn't attach to #{short} (not running or unauthorized): #{detail}"}
    )

    state
  end

  defp short_id(nil), do: "agent"
  defp short_id("agent_" <> rest), do: "agent_" <> String.slice(rest, 0, 6) <> "…"
  defp short_id(other) when is_binary(other), do: other

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
