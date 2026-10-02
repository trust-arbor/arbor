defmodule Arbor.Voice.Backend.XaiRealtime.Transport do
  @moduledoc false

  # Real Mint/Mint.WebSocket transport for Arbor.Voice.Backend.XaiRealtime,
  # extracted from Arbor.Agent.Prototypes.XaiVoiceOrchestrator's verified
  # connect/await_upgrade/send_json/recv_event. A behaviour-less 4-function
  # contract (connect/1, send_frame/3, recv_frame/2, close/1) so tests can
  # swap in a scripted fake via opts.

  @default_recv_timeout 90_000
  @default_send_timeout 30_000

  @spec connect(keyword()) :: {:ok, map()} | {:error, :connect_failed, :closed | :cleanup_pending}
  def connect(opts), do: connect(opts, {Mint.HTTP, Mint.WebSocket, :ssl})

  # Explicit internal qualification seam; production never reads collaborator
  # modules from caller options.
  @doc false
  def connect(opts, {http, _websocket, _ssl} = deps) do
    clock = Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end)
    deadline = clock.() + @default_recv_timeout

    case http.connect(:https, Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :port),
           protocols: [:http1],
           mode: :passive,
           transport_opts: [send_timeout: @default_send_timeout, send_timeout_close: true]
         ) do
      {:ok, conn} -> upgrade_connection(conn, opts, deadline, clock, deps)
      {:error, _reason} -> {:error, :connect_failed, :closed}
      _ -> {:error, :connect_failed, :cleanup_pending}
    end
  rescue
    _ -> {:error, :connect_failed, :cleanup_pending}
  catch
    _, _ -> {:error, :connect_failed, :cleanup_pending}
  end

  defp upgrade_connection(conn, opts, deadline, clock, {_http, websocket, _ssl} = deps) do
    case websocket.upgrade(:wss, conn, Keyword.fetch!(opts, :path), [
           {"authorization", "Bearer " <> Keyword.fetch!(opts, :token)}
         ]) do
      {:ok, next, ref} -> finish_upgrade(next, ref, deadline, clock, deps)
      {:error, next, _reason} -> reject_connection(next, deps)
      _ -> reject_connection(conn, deps)
    end
  rescue
    _ -> reject_connection(conn, deps)
  catch
    _, _ -> reject_connection(conn, deps)
  end

  defp finish_upgrade(conn, ref, deadline, clock, {http, _websocket, _ssl} = deps) do
    case await_upgrade(conn, ref, nil, nil, deadline, clock, http) do
      {:ok, next, status, headers, data} ->
        new_websocket(next, ref, status, headers, data, clock, deps)

      {:error, next, _reason} ->
        reject_connection(next, deps)
    end
  rescue
    _ -> reject_connection(conn, deps)
  catch
    _, _ -> reject_connection(conn, deps)
  end

  defp new_websocket(conn, ref, status, headers, data, clock, {_http, websocket, _ssl} = deps) do
    case websocket.new(conn, ref, status, headers, mode: :passive) do
      {:ok, next, ws} ->
        state = %{conn: next, ref: ref, ws: ws, pending: [], clock_fun: clock}
        retain_upgrade_frames(state, data, deps)

      {:error, next, _reason} ->
        reject_connection(next, deps)

      _ ->
        reject_connection(conn, deps)
    end
  rescue
    _ -> reject_connection(conn, deps)
  catch
    _, _ -> reject_connection(conn, deps)
  end

  defp retain_upgrade_frames(state, <<>>, _deps), do: {:ok, state}

  defp retain_upgrade_frames(state, data, deps) do
    case decode_events(state.ws, data) do
      {:ok, ws, events} -> {:ok, %{state | ws: ws, pending: events}}
      {:error, _reason} -> reject_connection(state.conn, deps)
    end
  rescue
    _ -> reject_connection(state.conn, deps)
  catch
    _, _ -> reject_connection(state.conn, deps)
  end

  defp reject_connection(conn, {http, _websocket, ssl}) do
    disposition = if close(%{conn: conn}, {http, ssl}) == :ok, do: :closed, else: :cleanup_pending
    {:error, :connect_failed, disposition}
  end

  defp await_upgrade(conn, ref, status, headers, deadline, clock_fun, http) do
    case remaining_budget(deadline, clock_fun) do
      :timeout ->
        {:error, conn, :upgrade_timeout}

      remaining ->
        received = http.recv(conn, 0, remaining)

        case received do
          {:error, next, _reason, _responses} ->
            {:error, next, :upgrade_failed}

          _ ->
            case upgrade_step(received, conn, ref, status, headers) do
              {:continue, next, status, headers} ->
                await_upgrade(next, ref, status, headers, deadline, clock_fun, http)

              {:complete, next, status, headers} ->
                # Mint's HTTP/1 101 body emits any coalesced WebSocket bytes
                # in the same response batch as :done. Keep full and partial frames.
                {:ok, _, responses} = received
                data = for {:data, ^ref, bytes} <- responses, into: <<>>, do: bytes
                {:ok, next, status, headers, data}

              {:error, _reason} ->
                failed_conn =
                  case received do
                    {:ok, latest, _responses} -> latest
                    _ -> conn
                  end

                {:error, failed_conn, :upgrade_failed}
            end
        end
    end
  rescue
    _ -> {:error, conn, :upgrade_failed}
  catch
    _, _ -> {:error, conn, :upgrade_failed}
  end

  @doc false
  def upgrade_step(:unknown, conn, _ref, status, headers),
    do: {:continue, conn, status, headers}

  def upgrade_step(
        {:error, _error_conn, reason, _responses},
        _prior_conn,
        _ref,
        _status,
        _headers
      ),
      do: {:error, {:upgrade_failed, reason}}

  def upgrade_step({:ok, conn, responses}, _prior_conn, ref, status, headers) do
    status =
      Enum.find_value(responses, status, fn
        {:status, ^ref, value} -> value
        _other -> nil
      end)

    headers =
      Enum.find_value(responses, headers, fn
        {:headers, ^ref, value} -> value
        _other -> nil
      end)

    if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
      if is_integer(status) and is_list(headers),
        do: {:complete, conn, status, headers},
        else: {:error, :incomplete_upgrade}
    else
      {:continue, conn, status, headers}
    end
  end

  @spec send_frame(map(), map()) :: {:ok, map()} | {:error, term()}
  def send_frame(state, frame),
    do: send_frame(state, frame, state.clock_fun.() + @default_send_timeout)

  @spec send_frame(map(), map(), integer()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def send_frame(state, frame, deadline) when is_integer(deadline) do
    with :ok <- send_budget(state, deadline),
         {:ok, json} <- Jason.encode(frame),
         :ok <- send_budget(state, deadline),
         {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, {:text, json}),
         :ok <- set_send_budget(state, deadline),
         :ok <- send_budget(state, deadline) do
      write_frame(%{state | ws: ws}, data, deadline)
    else
      {:error, reason} -> {:error, reason}
      {:error, _state, reason} -> {:error, reason}
    end
  end

  def send_frame(_state, _frame, _deadline), do: {:error, :invalid_timeout}

  defp send_budget(state, deadline) do
    case remaining_budget(deadline, state.clock_fun) do
      :timeout ->
        close(state)
        {:error, :timeout}

      _remaining ->
        :ok
    end
  end

  defp set_send_budget(state, deadline) do
    case remaining_budget(deadline, state.clock_fun) do
      :timeout ->
        close(state)
        {:error, :timeout}

      remaining ->
        # The provider route is HTTPS-only. This bounds real SSL backpressure;
        # BackendWorker's independent watchdog also covers encoding and faults.
        :ssl.setopts(Mint.HTTP.get_socket(state.conn),
          send_timeout: remaining,
          send_timeout_close: true
        )
    end
  end

  defp write_frame(state, data, deadline) do
    case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} ->
        latest = %{state | conn: conn}

        case send_budget(latest, deadline) do
          :ok -> {:ok, latest}
          {:error, reason} -> {:error, reason, latest}
        end

      {:error, conn, reason} ->
        latest = %{state | conn: conn}
        # The write may be partial even on the first frame. Fence that transport
        # immediately and retain the latest handle for owner-driven cleanup.
        close(latest)
        {:error, reason, latest}
    end
  end

  @spec recv_frame(map(), timeout()) ::
          {:ok, map(), map()} | {:error, :timeout, map()} | {:error, term()}
  def recv_frame(state, timeout), do: recv_frame(state, timeout, Mint.WebSocket)

  # Explicit qualification seam, never selected by production caller options.
  @doc false
  def recv_frame(%{pending: [event | rest]} = state, _timeout, _websocket),
    do: {:ok, %{state | pending: rest}, event}

  def recv_frame(state, :infinity, websocket), do: poll(state, :infinity, websocket)

  def recv_frame(state, timeout, websocket) when is_integer(timeout) and timeout >= 0 do
    deadline = state.clock_fun.() + timeout
    poll(state, deadline, websocket)
  end

  def recv_frame(_state, _timeout, _websocket), do: {:error, :invalid_timeout}

  # The worker's GenServer must never receive socket data between callbacks.
  # Passive reads keep bytes in the socket until this operation owns them.
  # Partial decode/control progress survives a timeout with the latest handle.
  defp poll(state, deadline, websocket) do
    case remaining_budget(deadline, state.clock_fun) do
      :timeout -> {:error, :timeout, state}
      ms -> receive_socket(state, deadline, ms, websocket)
    end
  end

  defp receive_socket(state, deadline, timeout, websocket) do
    case websocket.recv(state.conn, 0, timeout) do
      {:ok, conn, resps} ->
        state = %{state | conn: conn}
        data = for {:data, r, d} <- resps, r == state.ref, into: <<>>, do: d

        if data == <<>> do
          poll(state, deadline, websocket)
        else
          case decode_events(state.ws, data) do
            {:ok, ws, []} ->
              poll(%{state | ws: ws}, deadline, websocket)

            {:ok, ws, [first | rest]} ->
              {:ok, %{state | ws: ws, pending: rest}, first}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, conn, :timeout, _} ->
        {:error, :timeout, %{state | conn: conn}}

      {:error, conn, %Mint.TransportError{reason: :timeout}, _} ->
        {:error, :timeout, %{state | conn: conn}}

      {:error, _conn, reason, _} ->
        {:error, reason}
    end
  end

  defp decode_events(ws, data) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> reduce_frames(frames, ws, [])
      {:error, _ws, reason} -> {:error, reason}
    end
  end

  defp reduce_frames([], ws, events), do: {:ok, ws, Enum.reverse(events)}

  defp reduce_frames([{:text, payload} | rest], ws, events) do
    case Jason.decode(payload) do
      {:ok, event} when is_map(event) -> reduce_frames(rest, ws, [event | events])
      _other -> {:error, :invalid_json_frame}
    end
  end

  defp reduce_frames([{:error, reason} | _rest], _ws, _events), do: {:error, reason}
  defp reduce_frames([_control_frame | rest], ws, events), do: reduce_frames(rest, ws, events)

  # Public (not private) and @doc false solely so it is directly
  # unit-testable without a live socket -- the one deliberate exception to
  # keeping this module minimal/private.
  @doc false
  @spec remaining_budget(integer() | :infinity, (-> integer())) ::
          pos_integer() | :infinity | :timeout
  def remaining_budget(:infinity, _clock_fun), do: :infinity

  def remaining_budget(deadline, clock_fun) do
    ms = deadline - clock_fun.()
    if ms <= 0, do: :timeout, else: ms
  end

  @spec close(map()) :: :ok | {:error, :close_failed}
  def close(state), do: close(state, {Mint.HTTP, :ssl})

  @doc false
  def close(state, {http, ssl}) do
    # The source-owned route is HTTPS. Mint.HTTP.close/1 discards the TLS close
    # result, so check the actual socket operation under BackendWorker's watchdog.
    case ssl.close(http.get_socket(state.conn)) do
      :ok -> :ok
      _ -> {:error, :close_failed}
    end
  rescue
    _ -> {:error, :close_failed}
  catch
    _, _ -> {:error, :close_failed}
  end
end
