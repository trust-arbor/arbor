defmodule Arbor.Persistence.EventLog.Agent do
  @moduledoc """
  Agent-backed implementation of the EventLog behaviour.

  Lightweight alternative to ETS for small datasets or testing.
  Does NOT support subscriptions (subscribe/3 returns {:error, :not_supported}).

  Append calls accept `:call_timeout_ms` in `1..60_000` (default `5_000`).
  Requests first processed after their captured deadline fail without mutation.

      children = [
        {Arbor.Persistence.EventLog.Agent, name: :my_event_log}
      ]
  """

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Persistence.{Event, EventLog}

  @default_append_call_timeout_ms 5_000
  @max_append_call_timeout_ms 60_000

  # --- Client API ---

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts) do
    with {:ok, events, preconditions} <- EventLog.validate_append(stream_id, events, opts),
         {:ok, call_timeout_ms} <- append_call_timeout(opts) do
      name = Keyword.fetch!(opts, :name)
      deadline_mono = System.monotonic_time(:millisecond) + call_timeout_ms

      safe_get_and_update(name, call_timeout_ms, fn state ->
        processed_at = System.monotonic_time(:millisecond)

        if processed_at >= deadline_mono do
          {{:error, :operation_timeout}, state}
        else
          case check_preconditions(stream_id, preconditions, processed_at, state) do
            :ok ->
              {persisted, state} = do_append(stream_id, events, processed_at, state)
              {{:ok, persisted}, state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
        end
      end)
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_stream(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    from_num = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)
    direction = Keyword.get(opts, :direction, :forward)

    events =
      Agent.get(name, fn state ->
        state.streams
        |> Map.get(stream_id, [])
        |> Enum.filter(&(&1.event_number >= from_num))
        |> apply_direction(direction)
        |> apply_limit(limit)
      end)

    {:ok, events}
  end

  @impl Arbor.Persistence.EventLog
  def read_stream_head(stream_id, opts) do
    with {:ok, max_current_age_ms} <- EventLog.validate_head_read(stream_id, opts) do
      name = Keyword.fetch!(opts, :name)

      event =
        Agent.get(name, fn state ->
          if fresh_head?(
               stream_id,
               max_current_age_ms,
               System.monotonic_time(:millisecond),
               state
             ) do
            state.streams |> Map.get(stream_id, []) |> List.last()
          end
        end)

      {:ok, event}
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_all(opts) do
    name = Keyword.fetch!(opts, :name)
    from_pos = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)

    events =
      Agent.get(name, fn state ->
        state.global
        |> Enum.filter(&(&1.global_position >= from_pos))
        |> apply_limit(limit)
      end)

    {:ok, events}
  end

  @impl Arbor.Persistence.EventLog
  def stream_exists?(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    Agent.get(name, &Map.has_key?(&1.streams, stream_id))
  end

  @impl Arbor.Persistence.EventLog
  def stream_version(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    version = Agent.get(name, &Map.get(&1.versions, stream_id, 0))
    {:ok, version}
  end

  # --- Lifecycle ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.start_link(
      fn ->
        %{streams: %{}, global: [], versions: %{}, global_position: 0, head_inserted_mono: %{}}
      end,
      name: name
    )
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # --- Private ---

  defp apply_direction(events, :forward), do: events
  defp apply_direction(events, :backward), do: Enum.reverse(events)

  defp apply_limit(events, nil), do: events
  defp apply_limit(events, n), do: Enum.take(events, n)

  defp do_append(stream_id, events, inserted_mono, state) do
    current_version = Map.get(state.versions, stream_id, 0)

    {persisted, final_version, final_global_pos} =
      Enum.reduce(events, {[], current_version, state.global_position}, fn %Event{} = event,
                                                                           {acc, ver, gpos} ->
        new_ver = ver + 1
        new_gpos = gpos + 1

        persisted_event = %Event{
          event
          | event_number: new_ver,
            global_position: new_gpos,
            stream_id: stream_id
        }

        {[persisted_event | acc], new_ver, new_gpos}
      end)

    persisted = Enum.reverse(persisted)

    streams = Map.update(state.streams, stream_id, persisted, &(&1 ++ persisted))

    state = %{
      state
      | streams: streams,
        global: state.global ++ persisted,
        versions: Map.put(state.versions, stream_id, final_version),
        global_position: final_global_pos,
        head_inserted_mono: Map.put(state.head_inserted_mono, stream_id, inserted_mono)
    }

    {persisted, state}
  end

  defp check_preconditions(stream_id, preconditions, now, state) do
    current_version = Map.get(state.versions, stream_id, 0)

    cond do
      not is_nil(preconditions.expected_version) and
          preconditions.expected_version != current_version ->
        {:error, :version_conflict}

      not fresh_head?(stream_id, preconditions.max_current_age_ms, now, state) ->
        {:error, :deadline_exceeded}

      true ->
        :ok
    end
  end

  defp fresh_head?(_stream_id, nil, _now, _state), do: true

  defp fresh_head?(stream_id, max_age_ms, now, state) do
    case Map.get(state.head_inserted_mono, stream_id) do
      inserted when is_integer(inserted) -> now - inserted < max_age_ms
      _empty_or_unknown -> false
    end
  end

  defp append_call_timeout(opts) do
    case Keyword.get(opts, :call_timeout_ms, @default_append_call_timeout_ms) do
      timeout
      when is_integer(timeout) and timeout > 0 and timeout <= @max_append_call_timeout_ms ->
        {:ok, timeout}

      _invalid ->
        {:error, :invalid_precondition}
    end
  end

  defp safe_get_and_update(name, timeout, fun) do
    Agent.get_and_update(name, fun, timeout)
  catch
    :exit, reason ->
      cond do
        exit_reason_contains?(reason, :timeout) -> {:error, :operation_timeout}
        backend_unavailable_exit?(reason) -> {:error, :backend_unavailable}
        true -> exit(reason)
      end
  end

  defp backend_unavailable_exit?(reason) do
    Enum.any?([:noproc, :shutdown, :normal], &exit_reason_contains?(reason, &1))
  end

  defp exit_reason_contains?(reason, expected) when reason == expected, do: true

  defp exit_reason_contains?(reason, expected) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&exit_reason_contains?(&1, expected))
  end

  defp exit_reason_contains?(reason, expected) when is_list(reason) do
    Enum.any?(reason, &exit_reason_contains?(&1, expected))
  end

  defp exit_reason_contains?(_reason, _expected), do: false
end
