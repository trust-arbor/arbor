defmodule Arbor.Client.Socket do
  @moduledoc """
  Renderer-neutral, owner-bound Gateway WebSocket channel. It has no conversation
  reducer, replay cursor or operation retry. During session upgrade only, a
  host's HTTP 409 may be retried within the original connection deadline while
  the prior socket retires. No operation has been sent at that point. Every generation
  sends owner messages tagged with its exact pid. The owner retains signing and
  conversation policy; the socket signs only its own HTTP upgrade.

  Text messages are bounded to 8 MiB and 128 RFC6455 fragments before Mint can
  accumulate them. Outbound envelopes retain the Gateway's 262,144-byte bound.
  No compression extension is negotiated. Plain ws is restricted to loopback.
  """
  use GenServer
  alias Arbor.Client.{Endpoint, Login, Signer, Socket.FrameBudget}
  @path "/api/chat/socket"
  @connect_timeout 5_000
  @send_timeout 1_000
  @max_outbound_bytes 262_144
  @max_upgrade_bytes 65_536

  def start_link(opts) do
    case options(opts) do
      {:ok, _, _, _} -> GenServer.start_link(__MODULE__, opts)
      _ -> {:error, :invalid_options}
    end
  end

  def send_frame(pid, text),
    do: send_frame(pid, text, System.monotonic_time(:millisecond) + 5_000)

  def send_frame(pid, text, deadline) when is_pid(pid) and is_integer(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      GenServer.call(pid, {:send_frame, text, deadline}, min(remaining, 5_000) + 1_000)
    else
      {:error, :timeout}
    end
  catch
    :exit, _ -> {:error, :closed}
  end

  def send_frame(_, _, _), do: {:error, :invalid_options}

  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 7_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, _ -> {:error, :close_failed}
  end

  def close(_), do: {:error, :invalid_options}
  def max_message_bytes, do: FrameBudget.max_message_bytes()
  def max_fragments, do: FrameBudget.max_fragments()

  @impl true
  def init(opts) do
    with {:ok, owner, authentication, uri} <- options(opts) do
      Process.flag(:sensitive, true)
      monitor = Process.monitor(owner)
      deadline = System.monotonic_time(:millisecond) + @connect_timeout
      timer = Process.send_after(self(), :connect_deadline, @connect_timeout)

      {:ok,
       %{
         owner: owner,
         monitor: monitor,
         authentication: authentication,
         uri: uri,
         deadline: deadline,
         timer: timer,
         retry_tag: nil,
         conn: nil,
         ref: nil,
         websocket: nil,
         status: nil,
         headers: nil,
         upgrade_bytes: 0,
         budget: FrameBudget.new(),
         closed_reason: :closed
       }, {:continue, :connect}}
    else
      _ -> {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    uri = state.uri
    scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 1)
    transport_opts = [timeout: remaining, send_timeout: @send_timeout, send_timeout_close: true]

    transport_opts =
      if uri.host == "::1", do: [inet6: true] ++ transport_opts, else: transport_opts

    case Mint.HTTP.connect(scheme, uri.host, uri.port,
           protocols: [:http1],
           transport_opts: transport_opts
         ) do
      {:ok, conn} ->
        latest = %{state | conn: conn}

        if expired?(latest) do
          stop(latest, :connect_timeout)
        else
          authorization = authorization(state.authentication)

          case Mint.WebSocket.upgrade(ws_scheme, conn, @path, [{"authorization", authorization}]) do
            {:ok, conn, ref} -> {:noreply, %{latest | conn: conn, ref: ref}}
            {:error, conn, _} -> stop(%{latest | conn: conn}, :upgrade_failed)
          end
        end

      {:error, _} ->
        stop(state, :connection_failed)
    end
  rescue
    _ -> stop(state, :connection_failed)
  catch
    _, _ -> stop(state, :connection_failed)
  end

  @impl true
  def handle_call({:send_frame, text, deadline}, {caller, _}, state) do
    cond do
      caller != state.owner or not Process.alive?(caller) ->
        {:reply, {:error, :not_owner}, state}

      System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :timeout}, state}

      not is_binary(text) or byte_size(text) > @max_outbound_bytes or not String.valid?(text) ->
        {:reply, {:error, :invalid_frame}, state}

      is_nil(state.websocket) ->
        {:reply, {:error, :not_connected}, state}

      true ->
        case transmit(state, {:text, text}) do
          {:ok, latest} ->
            {:reply, :ok, latest}

          {:error, latest} ->
            {:stop, :normal, {:error, :transport_failed},
             %{latest | closed_reason: :transport_failed}}
        end
    end
  end

  # A malformed call must not put credential-bearing arguments in an exception stacktrace.
  def handle_call(_request, _from, state),
    do:
      {:stop, :invalid_request, {:error, :invalid_request},
       %{state | closed_reason: :invalid_request}}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: stop(state, :owner_down)

  def handle_info(:connect_deadline, %{websocket: nil} = state), do: stop(state, :connect_timeout)
  def handle_info(:connect_deadline, state), do: {:noreply, state}

  def handle_info({:retry_upgrade, tag}, %{retry_tag: tag, websocket: nil} = state)
      when is_reference(tag) do
    if expired?(state),
      do: stop(state, :connect_timeout),
      else: {:noreply, %{state | retry_tag: nil}, {:continue, :connect}}
  end

  def handle_info({:retry_upgrade, _}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    with :ok <- admission(message, state),
         {:ok, latest} <- stream(message, state) do
      {:noreply, latest}
    else
      {:retry_upgrade, latest} -> wait_for_attachment(latest)
      {:error, latest, reason} -> stop(latest, reason)
      {:error, reason} -> stop(state, reason)
    end
  rescue
    _ -> stop(state, :protocol_error)
  catch
    _, _ -> stop(state, :protocol_error)
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.conn, do: Mint.HTTP.close(state.conn)
    notify(state, {:closed, state.closed_reason})
    :ok
  rescue
    _ -> notify(state, {:closed, state.closed_reason})
  catch
    _, _ -> notify(state, {:closed, state.closed_reason})
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _value} -> {:log, []}
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted_client_state}
      pair -> pair
    end)
  end

  defp admission(message, %{websocket: nil} = state) do
    cond do
      expired?(state) ->
        {:error, :connect_timeout}

      state.upgrade_bytes + socket_bytes(message) > @max_upgrade_bytes ->
        {:error, :upgrade_failed}

      true ->
        :ok
    end
  end

  defp admission(_, _), do: :ok

  defp socket_bytes({kind, _, data}) when kind in [:tcp, :ssl] and is_binary(data),
    do: byte_size(data)

  defp socket_bytes(_), do: 0

  defp stream(message, state) do
    before_upgrade = is_nil(state.websocket)

    state =
      if before_upgrade,
        do: %{state | upgrade_bytes: state.upgrade_bytes + socket_bytes(message)},
        else: state

    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} -> responses(responses, %{state | conn: conn})
      {:error, conn, _, _} -> {:error, %{state | conn: conn}, :transport_failed}
      :unknown -> {:ok, state}
    end
  end

  defp responses([], state), do: {:ok, state}

  defp responses([response | rest], state) do
    case response(response, state) do
      {:ok, latest} -> responses(rest, latest)
      error -> error
    end
  end

  defp response({:status, ref, status}, %{ref: ref} = state), do: {:ok, %{state | status: status}}

  defp response(
         {:headers, ref, _headers},
         %{ref: ref, websocket: nil, status: 409, authentication: {:session, _}} = state
       ),
       do: {:retry_upgrade, state}

  defp response(
         {:headers, ref, _headers},
         %{ref: ref, websocket: nil, status: status, authentication: {:session, _}} = state
       )
       when status in [401, 403],
       do: {:error, state, :unauthorized}

  defp response({:headers, ref, headers}, %{ref: ref, websocket: nil} = state) do
    if expired?(state) do
      {:error, state, :connect_timeout}
    else
      case Mint.WebSocket.new(state.conn, ref, state.status, headers) do
        {:ok, conn, websocket} ->
          Process.cancel_timer(state.timer)

          latest = %{
            state
            | conn: conn,
              websocket: websocket,
              timer: nil,
              authentication: nil,
              uri: nil
          }

          notify(latest, :connected)
          {:ok, latest}

        {:error, conn, _} ->
          {:error, %{state | conn: conn}, :upgrade_failed}
      end
    end
  end

  defp response({:data, ref, data}, %{ref: ref, websocket: ws} = state) when ws != nil do
    with {:ok, budget} <- FrameBudget.consume(state.budget, data) do
      case Mint.WebSocket.decode(ws, data) do
        {:ok, websocket, frames} ->
          frames(frames, %{state | websocket: websocket, budget: budget})

        {:error, websocket, _} ->
          {:error, %{state | websocket: websocket, budget: budget}, :protocol_error}
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp response({:done, ref}, %{ref: ref} = state), do: {:ok, state}
  defp response(_, state), do: {:ok, state}

  defp frames([], state), do: {:ok, state}

  defp frames([{:text, text} | rest], state) when is_binary(text) do
    if String.valid?(text) do
      notify(state, {:frame, text})
      frames(rest, state)
    else
      {:error, state, :protocol_error}
    end
  end

  defp frames([{:ping, data} | rest], state) do
    case transmit(state, {:pong, data}) do
      {:ok, latest} -> frames(rest, latest)
      {:error, latest} -> {:error, latest, :transport_failed}
    end
  end

  defp frames([{:pong, _} | rest], state), do: frames(rest, state)
  defp frames([{:close, _, _} | _], state), do: {:error, state, :closed}
  defp frames(_, state), do: {:error, state, :protocol_error}

  defp transmit(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        latest = %{state | websocket: websocket}

        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> {:ok, %{latest | conn: conn}}
          {:error, conn, _} -> {:error, %{latest | conn: conn}}
        end

      {:error, websocket, _} ->
        {:error, %{state | websocket: websocket}}
    end
  rescue
    _ -> {:error, state}
  catch
    _, _ -> {:error, state}
  end

  defp expired?(state), do: System.monotonic_time(:millisecond) >= state.deadline

  defp wait_for_attachment(state) do
    Mint.HTTP.close(state.conn)

    if expired?(state) do
      stop(%{state | conn: nil}, :connect_timeout)
    else
      tag = make_ref()
      Process.send_after(self(), {:retry_upgrade, tag}, 50)
      # Keep the original total deadline and cumulative wire budget. Never
      # carry a previous HTTP response or retry after a successful upgrade.
      {:noreply, %{state | conn: nil, ref: nil, status: nil, headers: nil, retry_tag: tag}}
    end
  end

  defp stop(state, reason), do: {:stop, :normal, %{state | closed_reason: reason}}
  defp notify(state, event), do: send(state.owner, {:arbor_socket, self(), event})

  defp options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <-
           Enum.sort(Keyword.keys(opts)) in [
             [:gateway_url, :identity, :owner],
             [:gateway_url, :owner, :session]
           ],
         owner when is_pid(owner) <- opts[:owner],
         true <- Process.alive?(owner),
         {:ok, authentication} <- authentication(opts),
         {:ok, uri} <-
           Endpoint.socket(
             opts[:gateway_url],
             if(Keyword.has_key?(opts, :identity), do: :signed, else: :session)
           ) do
      {:ok, owner, authentication, uri}
    else
      _ -> {:error, :invalid_options}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp options(_), do: {:error, :invalid_options}

  defp authentication(opts) do
    if Keyword.has_key?(opts, :session) do
      with {:ok, session} <- Login.session(opts[:session]), do: {:ok, {:session, session}}
    else
      if Signer.valid_identity?(opts[:identity]),
        do: {:ok, {:identity, opts[:identity]}},
        else: {:error, :invalid_options}
    end
  end

  defp authorization({:identity, identity}),
    do: Signer.authorization_header(identity, "GET", @path, "")

  defp authorization({:session, session}) do
    {:ok, current} = Login.session(session)
    "Conversation " <> current.credential
  end
end

defmodule Arbor.Client.Socket.FrameBudget do
  @moduledoc false
  @max_bytes 8 * 1_024 * 1_024
  @max_fragments 128
  def max_message_bytes, do: @max_bytes
  def max_fragments, do: @max_fragments
  def new, do: %{header: <<>>, remaining: 0, fragmented: false, bytes: 0, fragments: 0}

  def consume(state, <<>>), do: {:ok, state}

  def consume(%{remaining: remaining} = state, data) when remaining > 0 do
    taken = min(remaining, byte_size(data))
    <<_::binary-size(taken), rest::binary>> = data
    consume(%{state | remaining: remaining - taken}, rest)
  end

  def consume(state, data) do
    # Buffer only an incomplete RFC header (at most 9 bytes), never payload.
    combined = state.header <> data

    case header(combined) do
      :more ->
        {:ok, %{state | header: combined}}

      {:error, reason} ->
        {:error, reason}

      {:ok, fin, opcode, length, rest} ->
        with {:ok, latest} <- account(state, fin, opcode, length) do
          consume(%{latest | header: <<>>, remaining: length}, rest)
        end
    end
  end

  defp header(data) when byte_size(data) < 2, do: :more

  defp header(<<fin::1, 0::3, opcode::4, 0::1, size::7, rest::binary>>) do
    case size do
      126 ->
        case rest do
          <<length::16, tail::binary>> -> {:ok, fin, opcode, length, tail}
          _ -> :more
        end

      127 ->
        case rest do
          <<0::1, length::63, tail::binary>> -> {:ok, fin, opcode, length, tail}
          <<_::64, _::binary>> -> {:error, :protocol_error}
          _ -> :more
        end

      length ->
        {:ok, fin, opcode, length, rest}
    end
  end

  defp header(_), do: {:error, :protocol_error}

  defp account(state, 1, opcode, length) when opcode in [8, 9, 10] and length <= 125,
    do: {:ok, state}

  defp account(state, fin, 1, length) when not state.fragmented,
    do: message(state, fin, length, 1)

  defp account(state, fin, 0, length) when state.fragmented,
    do: message(state, fin, state.bytes + length, state.fragments + 1)

  defp account(_, _, _, _), do: {:error, :protocol_error}

  defp message(_, _, bytes, _) when bytes > @max_bytes, do: {:error, :frame_too_large}
  defp message(_, _, _, count) when count > @max_fragments, do: {:error, :fragment_limit}
  defp message(state, 1, _, _), do: {:ok, %{state | fragmented: false, bytes: 0, fragments: 0}}

  defp message(state, 0, bytes, count),
    do: {:ok, %{state | fragmented: true, bytes: bytes, fragments: count}}
end
