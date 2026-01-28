defmodule Arbor.Historian.HistoryEntry do
  @moduledoc """
  A single entry in the history log, representing a persisted signal.

  HistoryEntry is the historian's view of an event — enriched with stream
  positioning and category/type parsing from the original signal's type string.
  """

  use TypedStruct

  alias Arbor.Common.SafeAtom
  alias Arbor.Historian.Event

  @derive Jason.Encoder
  typedstruct do
    @typedoc "A persisted history entry"

    field :id, String.t(), enforce: true
    field :signal_id, String.t(), enforce: true
    field :stream_id, String.t(), enforce: true
    field :event_number, non_neg_integer()
    field :global_position, non_neg_integer()
    field :category, atom(), enforce: true
    field :type, atom(), enforce: true
    field :data, map(), default: %{}
    field :source, String.t()
    field :cause_id, String.t()
    field :correlation_id, String.t()
    field :metadata, map(), default: %{}
    field :timestamp, DateTime.t(), enforce: true
    field :persisted_at, DateTime.t()
  end

  @doc """
  Create a HistoryEntry from an Event stored in the EventLog.

  Parses the event type string (e.g., "activity:agent_started") back into
  separate category and type atoms.
  """
  @spec from_event(Event.t()) :: t()
  def from_event(%Event{} = event) do
    {category, type} = parse_event_type(event.type)

    %__MODULE__{
      id: generate_id(),
      signal_id: event.metadata[:signal_id] || event.id,
      stream_id: event.stream_id || "unknown",
      event_number: event.stream_version,
      global_position: event.global_position,
      category: category,
      type: type,
      data: event.data || %{},
      source: event.metadata[:source],
      cause_id: event.causation_id,
      correlation_id: event.correlation_id,
      metadata: Map.drop(event.metadata, [:signal_id, :source]),
      timestamp: event.timestamp,
      persisted_at: event.metadata[:persisted_at]
    }
  end

  @doc """
  Check if this entry matches a filter map.

  Supported filter keys: `:category`, `:type`, `:source`, `:agent_id`,
  `:correlation_id`, `:from`, `:to`.
  """
  @spec matches?(t(), map() | keyword()) :: boolean()
  def matches?(%__MODULE__{} = entry, filters) do
    filters = Map.new(filters)

    Enum.all?(filters, fn
      {:category, cat} -> entry.category == cat
      {:type, type} -> entry.type == type
      {:source, source} -> entry.source == source
      {:correlation_id, cid} -> entry.correlation_id == cid
      {:from, from} -> DateTime.compare(entry.timestamp, from) in [:gt, :eq]
      {:to, to} -> DateTime.compare(entry.timestamp, to) in [:lt, :eq]
      _ -> true
    end)
  end

  defp parse_event_type(type) when is_atom(type) do
    type
    |> Atom.to_string()
    |> parse_event_type_string()
  end

  defp parse_event_type(type) when is_binary(type) do
    parse_event_type_string(type)
  end

  defp parse_event_type_string(type_string) do
    SafeAtom.decode_event_type(type_string)
  end

  defp generate_id do
    "hist_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
