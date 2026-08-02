defmodule Arbor.Voice.Backend.XaiRealtime.Transport do
  @moduledoc false

  # Real Mint/Mint.WebSocket transport for Arbor.Voice.Backend.XaiRealtime,
  # extracted from Arbor.Agent.Prototypes.XaiVoiceOrchestrator's verified
  # connect/await_upgrade/send_json/recv_event. A behaviour-less 4-function
  # contract (connect/1, send_frame/2, recv_frame/2, close/1) so tests can
  # swap in a scripted fake via opts.

  @default_recv_timeout 90_000

  @spec connect(keyword()) :: {:ok, map()} | {:error, term()}
  def connect(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    path = Keyword.fetch!(opts, :path)
    token = Keyword.fetch!(opts, :token)
    clock_fun = Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end)
    upgrade_deadline = clock_fun.() + @default_recv_timeout

    with {:ok, conn} <- Mint.HTTP.connect(:https, host, port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(:wss, conn, path, [{"authorization", "Bearer " <> token}]),
         {:ok, conn, status, headers} <-
           await_upgrade(conn, ref, nil, nil, upgrade_deadline, clock_fun),
         {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, %{conn: conn, ref: ref, ws: ws, pending: [], clock_fun: clock_fun}}
    else
      {:error, _conn, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_upgrade(conn, ref, status, headers, deadline, clock_fun) do
    case remaining_budget(deadline, clock_fun) do
      :timeout ->
        {:error, :upgrade_timeout}

      remaining ->
        receive do
          msg ->
            case upgrade_step(Mint.WebSocket.stream(conn, msg), conn, ref, status, headers) do
              {:continue, conn, status, headers} ->
                await_upgrade(conn, ref, status, headers, deadline, clock_fun)

              {:complete, conn, status, headers} ->
                {:ok, conn, status, headers}

              {:error, reason} ->
                {:error, reason}
            end
        after
          remaining -> {:error, :upgrade_timeout}
        end
    end
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
  def send_frame(state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, {:text, Jason.encode!(frame)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | ws: ws, conn: conn}}
    else
      {:error, _state, reason} -> {:error, reason}
    end
  end

  @spec recv_frame(map(), timeout()) :: {:ok, map(), map()} | {:error, term()}
  def recv_frame(%{pending: [event | rest]} = state, _timeout),
    do: {:ok, %{state | pending: rest}, event}

  def recv_frame(state, :infinity), do: poll(state, :infinity)

  def recv_frame(state, timeout) when is_integer(timeout) and timeout >= 0 do
    deadline = state.clock_fun.() + timeout
    poll(state, deadline)
  end

  def recv_frame(_state, _timeout), do: {:error, :invalid_timeout}

  # One absolute deadline for the whole recv_frame/2 call. Every internal
  # skip site (empty data batch, non-text control payload, and a foreign
  # :unknown mailbox message) recurses through poll/2 with this SAME deadline
  # term -- never a freshly reconstructed timeout. Malformed JSON is an
  # explicit transport error rather than an indefinitely skipped payload.
  defp poll(state, deadline) do
    case remaining_budget(deadline, state.clock_fun) do
      :timeout -> {:error, :timeout}
      ms -> await_message(state, deadline, ms)
    end
  end

  defp await_message(state, :infinity, :infinity) do
    receive do
      msg -> handle_message(state, :infinity, msg)
    end
  end

  defp await_message(state, deadline, ms) do
    receive do
      msg -> handle_message(state, deadline, msg)
    after
      ms -> {:error, :timeout}
    end
  end

  defp handle_message(state, deadline, msg) do
    case Mint.WebSocket.stream(state.conn, msg) do
      {:ok, conn, resps} ->
        state = %{state | conn: conn}
        data = for {:data, r, d} <- resps, r == state.ref, into: <<>>, do: d

        if data == <<>> do
          poll(state, deadline)
        else
          case decode_events(state.ws, data) do
            {:ok, ws, []} ->
              poll(%{state | ws: ws}, deadline)

            {:ok, ws, [first | rest]} ->
              {:ok, %{state | ws: ws, pending: rest}, first}

            {:error, reason} ->
              {:error, reason}
          end
        end

      :unknown ->
        # Message not addressed to this connection (foreign mailbox
        # traffic) -- skip through the same deadline, never crash.
        poll(state, deadline)

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

  @spec close(map()) :: :ok
  def close(state) do
    _ = Mint.HTTP.close(state.conn)
    :ok
  rescue
    _exception -> :ok
  end
end
