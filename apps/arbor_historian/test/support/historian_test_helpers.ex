defmodule Arbor.Historian.TestHelpers do
  @moduledoc """
  Test helpers for historian tests.

  Creates events directly in the EventLog, bypassing any signal collection.
  This aligns with the historian's role as a pure query layer.
  """

  alias Arbor.Historian.StreamIds
  alias Arbor.Historian.StreamRegistry
  alias Arbor.Persistence.Event, as: PersistenceEvent
  alias Arbor.Persistence.EventLog.ETS, as: ETSEventLog

  @doc "Build a test event struct for testing."
  def build_event(opts \\ []) do
    category = Keyword.get(opts, :category, :activity)
    type = Keyword.get(opts, :type, :agent_started)
    id = Keyword.get(opts, :id, "sig_#{random_hex(16)}")
    source = Keyword.get(opts, :source, "arbor://test/historian")
    timestamp = Keyword.get(opts, :time, DateTime.utc_now())
    data = Keyword.get(opts, :data, %{})
    cause_id = Keyword.get(opts, :cause_id)
    correlation_id = Keyword.get(opts, :correlation_id)

    # Merge source into metadata and preserve signal_id for query compatibility
    metadata =
      Map.merge(
        %{signal_id: id, source: source},
        Keyword.get(opts, :metadata, %{})
      )

    %{
      id: id,
      category: category,
      type: type,
      source: source,
      timestamp: timestamp,
      data: data,
      cause_id: cause_id,
      correlation_id: correlation_id,
      metadata: metadata
    }
  end

  @doc "Build an event with agent_id in data."
  def build_agent_event(agent_id, opts \\ []) do
    data = Map.put(Keyword.get(opts, :data, %{}), :agent_id, agent_id)
    build_event(Keyword.put(opts, :data, data))
  end

  @doc "Build an event with session_id in data."
  def build_session_event(session_id, opts \\ []) do
    data = Map.put(Keyword.get(opts, :data, %{}), :session_id, session_id)
    build_event(Keyword.put(opts, :data, data))
  end

  @doc "Start an isolated historian stack for testing (no collector)."
  def start_test_historian(test_name) do
    # credo:disable-for-lines:2 Credo.Check.Security.UnsafeAtomConversion
    event_log_name = :"event_log_#{test_name}"
    registry_name = :"registry_#{test_name}"

    {:ok, event_log} =
      ETSEventLog.start_link(name: event_log_name)

    {:ok, registry} =
      StreamRegistry.start_link(name: registry_name)

    %{
      event_log: event_log_name,
      registry: registry_name,
      pids: [event_log, registry]
    }
  end

  @doc """
  Insert an event into the test stack.

  Routes the event to appropriate streams based on its properties.
  """
  def insert_event(ctx, event) do
    streams = determine_streams(event)

    for stream_id <- streams do
      persistence_event = to_persistence_event(event, stream_id)
      ETSEventLog.append(stream_id, persistence_event, name: ctx.event_log)
      StreamRegistry.record_event(ctx.registry, stream_id, event.timestamp)
    end

    :ok
  end

  # Legacy alias for backwards compatibility with existing tests
  def collect_signal(ctx, signal_map), do: insert_event(ctx, signal_map)

  # Also alias for build_signal for backwards compat
  def build_signal(opts \\ []), do: build_event(opts)
  def build_agent_signal(agent_id, opts \\ []), do: build_agent_event(agent_id, opts)
  def build_session_signal(session_id, opts \\ []), do: build_session_event(session_id, opts)

  # Private helpers

  defp determine_streams(event) do
    streams = ["global"]

    streams =
      if event[:category] do
        streams ++ [StreamIds.for_category(event.category)]
      else
        streams
      end

    streams =
      case get_in(event, [:data, :agent_id]) do
        nil -> streams
        agent_id -> streams ++ [StreamIds.for_agent(agent_id)]
      end

    streams =
      case get_in(event, [:data, :session_id]) do
        nil -> streams
        session_id -> streams ++ [StreamIds.for_session(session_id)]
      end

    streams =
      case event[:correlation_id] do
        nil -> streams
        "" -> streams
        cid -> streams ++ [StreamIds.for_correlation(cid)]
      end

    streams
  end

  defp to_persistence_event(event, stream_id) do
    PersistenceEvent.new(
      stream_id,
      "arbor.historian.#{event.category}:#{event.type}",
      event.data,
      id: event.id,
      metadata:
        Map.merge(event.metadata || %{}, %{
          subject_id: stream_id,
          subject_type: :historian,
          version: "1.0.0"
        }),
      causation_id: event[:cause_id],
      correlation_id: event[:correlation_id],
      timestamp: event.timestamp
    )
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end
end
