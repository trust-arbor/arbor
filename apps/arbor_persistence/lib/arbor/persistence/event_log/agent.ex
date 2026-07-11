defmodule Arbor.Persistence.EventLog.Agent do
  @moduledoc """
  Agent-backed implementation of the EventLog behaviour.

  Lightweight alternative to ETS for small datasets or testing.
  Does NOT support subscriptions (subscribe/3 returns {:error, :not_supported}).

  Append calls accept `:append_timeout_ms` in `1..60_000` (default `5_000`;
  `:call_timeout_ms` remains a compatibility alias). Candidate state is committed
  only after the server checks the caller-owned absolute operation deadline. A
  caller-side timeout after dispatch returns a reconcilable indeterminate result.

      children = [
        {Arbor.Persistence.EventLog.Agent, name: :my_event_log}
      ]
  """

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Contracts.Persistence.AppendOperation
  alias Arbor.Persistence.{Event, EventLog}

  # --- Client API ---

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts) do
    with {:ok, events, preconditions, operation, deadline_mono} <-
           EventLog.prepare_append(stream_id, events, opts),
         {:ok, name} <- fetch_name(opts) do
      safe_get_and_update(name, deadline_mono, operation, fn state ->
        append_before_deadline(
          state,
          stream_id,
          events,
          preconditions,
          operation,
          deadline_mono
        )
      end)
    end
  end

  @impl Arbor.Persistence.EventLog
  def reconcile_append(operation, opts) do
    with {:ok, operation, normalized_opts, deadline_mono} <-
           EventLog.prepare_reconcile(operation, opts),
         {:ok, name} <- fetch_name(normalized_opts) do
      reconcile_from_agent(name, operation, deadline_mono)
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
        |> project_direction(direction)
        |> Enum.filter(&(&1.event_number >= from_num))
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
            state.streams |> Map.get(stream_id, []) |> List.first()
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
        |> Enum.reverse()
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
    candidate_hook = Keyword.get(opts, :append_candidate_hook)

    Agent.start_link(
      fn ->
        %{
          streams: %{},
          global: [],
          versions: %{},
          global_position: 0,
          event_index: %{},
          head_inserted_mono: %{},
          append_candidate_hook: candidate_hook
        }
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

  defp project_direction(events, :forward), do: Enum.reverse(events)
  defp project_direction(events, :backward), do: events

  defp apply_limit(events, nil), do: events
  defp apply_limit(events, n), do: Enum.take(events, n)

  defp do_append(stream_id, events, state) do
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

    persisted_reversed = persisted
    persisted = Enum.reverse(persisted_reversed)

    streams =
      Map.update(state.streams, stream_id, persisted_reversed, &(persisted_reversed ++ &1))

    event_index =
      Enum.reduce(persisted, state.event_index, fn event, index ->
        Map.put(index, event.id, event)
      end)

    state = %{
      state
      | streams: streams,
        global: persisted_reversed ++ state.global,
        versions: Map.put(state.versions, stream_id, final_version),
        global_position: final_global_pos,
        event_index: event_index
    }

    {persisted, state}
  end

  defp append_before_deadline(
         state,
         stream_id,
         events,
         preconditions,
         operation,
         deadline_mono
       ) do
    processed_at = System.monotonic_time(:millisecond)

    if processed_at >= deadline_mono do
      {{:error, :operation_timeout}, state}
    else
      case reconcile_state(operation, state) do
        {:ok, {:committed, persisted}} ->
          {{:ok, persisted}, state}

        {:ok, :absent} ->
          append_after_preconditions(
            state,
            stream_id,
            events,
            preconditions,
            processed_at,
            deadline_mono
          )

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end
  end

  defp append_after_preconditions(
         state,
         stream_id,
         events,
         preconditions,
         processed_at,
         deadline_mono
       ) do
    case check_preconditions(stream_id, preconditions, processed_at, state) do
      :ok ->
        commit_candidate_before_deadline(state, stream_id, events, deadline_mono)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp commit_candidate_before_deadline(state, stream_id, events, deadline_mono) do
    with :ok <-
           EventLog.ensure_position_capacity(
             Map.get(state.versions, stream_id, 0),
             state.global_position,
             length(events)
           ) do
      {persisted, candidate} = do_append(stream_id, events, state)
      run_candidate_hook(state)
      completed_at = System.monotonic_time(:millisecond)

      if completed_at >= deadline_mono do
        {{:error, :operation_timeout}, state}
      else
        candidate = put_head_freshness(candidate, stream_id, completed_at)
        {{:ok, persisted}, candidate}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
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

  defp safe_get_and_update(name, deadline_mono, operation, fun) do
    with {:ok, timeout} <- EventLog.remaining_timeout(deadline_mono) do
      Agent.get_and_update(name, fun, timeout)
    end
  catch
    :exit, reason ->
      if exit_reason_contains?(reason, :timeout),
        do: EventLog.indeterminate(operation),
        else: {:error, :backend_unavailable}
  end

  defp reconcile_from_agent(name, operation, deadline_mono) do
    with {:ok, timeout} <- EventLog.remaining_timeout(deadline_mono) do
      Agent.get(name, &reconcile_state(operation, &1), timeout)
    else
      {:error, :operation_timeout} -> EventLog.indeterminate(operation)
    end
  catch
    :exit, _reason -> EventLog.indeterminate(operation)
  end

  defp fetch_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, :invalid_precondition}
    end
  end

  defp reconcile_state(%AppendOperation{} = operation, state) do
    events =
      operation.event_ids
      |> Enum.flat_map(fn event_id ->
        case Map.fetch(state.event_index, event_id) do
          {:ok, event} -> [event]
          :error -> []
        end
      end)

    EventLog.reconcile_events(operation, events)
  end

  defp put_head_freshness(state, stream_id, committed_mono) do
    %{state | head_inserted_mono: Map.put(state.head_inserted_mono, stream_id, committed_mono)}
  end

  defp run_candidate_hook(%{append_candidate_hook: hook}) when is_function(hook, 0), do: hook.()
  defp run_candidate_hook(_state), do: :ok

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
