defmodule Arbor.Historian.StreamRegistry do
  @moduledoc """
  Agent tracking stream metadata: names, event counts, and last timestamps.

  Provides a fast lookup of known streams without querying the EventLog.
  """

  use Agent

  @type stream_meta :: %{
          event_count: non_neg_integer(),
          first_event_at: DateTime.t() | nil,
          last_event_at: DateTime.t() | nil
        }

  @doc "Start the registry."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc "Record that an event was appended to a stream."
  @spec record_event(GenServer.server(), String.t(), DateTime.t()) :: :ok
  def record_event(server \\ __MODULE__, stream_id, timestamp) do
    Agent.update(server, fn state ->
      meta = Map.get(state, stream_id, %{event_count: 0, first_event_at: nil, last_event_at: nil})

      updated = %{
        meta
        | event_count: meta.event_count + 1,
          first_event_at: meta.first_event_at || timestamp,
          last_event_at: timestamp
      }

      Map.put(state, stream_id, updated)
    end)
  end

  @doc "Get metadata for a specific stream."
  @spec get_stream(GenServer.server(), String.t()) :: {:ok, stream_meta()} | {:error, :not_found}
  def get_stream(server \\ __MODULE__, stream_id) do
    case Agent.get(server, &Map.get(&1, stream_id)) do
      nil -> {:error, :not_found}
      meta -> {:ok, meta}
    end
  end

  @doc "List all known stream IDs."
  @spec list_streams(GenServer.server()) :: [String.t()]
  def list_streams(server \\ __MODULE__) do
    Agent.get(server, &Map.keys/1)
  end

  @doc "Get metadata for all streams."
  @spec all_streams(GenServer.server()) :: %{String.t() => stream_meta()}
  def all_streams(server \\ __MODULE__) do
    Agent.get(server, & &1)
  end

  @doc "Get the total event count across all streams."
  @spec total_events(GenServer.server()) :: non_neg_integer()
  def total_events(server \\ __MODULE__) do
    Agent.get(server, fn state ->
      state |> Map.values() |> Enum.reduce(0, &(&1.event_count + &2))
    end)
  end

  @doc "Reset the registry (primarily for testing)."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    Agent.update(server, fn _ -> %{} end)
  end
end
