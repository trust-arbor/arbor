defmodule Arbor.Persistence.EventLog.Agent do
  @moduledoc """
  Agent-backed implementation of the EventLog behaviour.

  Lightweight alternative to ETS for small datasets or testing.
  Does NOT support subscriptions (subscribe/3 returns {:error, :not_supported}).

      children = [
        {Arbor.Persistence.EventLog.Agent, name: :my_event_log}
      ]
  """

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Persistence.Event

  # --- Client API ---

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts) do
    name = Keyword.fetch!(opts, :name)
    events = List.wrap(events)

    Agent.get_and_update(name, fn state ->
      {persisted, state} = do_append(stream_id, events, state)
      {{:ok, persisted}, state}
    end)
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
      fn -> %{streams: %{}, global: [], versions: %{}, global_position: 0} end,
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

    persisted = Enum.reverse(persisted)

    streams = Map.update(state.streams, stream_id, persisted, &(&1 ++ persisted))

    state = %{
      state
      | streams: streams,
        global: state.global ++ persisted,
        versions: Map.put(state.versions, stream_id, final_version),
        global_position: final_global_pos
    }

    {persisted, state}
  end
end
