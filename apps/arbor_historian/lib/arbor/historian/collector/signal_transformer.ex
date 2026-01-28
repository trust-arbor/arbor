defmodule Arbor.Historian.Collector.SignalTransformer do
  @moduledoc """
  Pure transformation functions between Signals, Events, and HistoryEntries.

  Converts Arbor.Signals.Signal structs into Arbor.Historian.Event
  structs for storage, and back into HistoryEntry structs for querying.
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Historian.Event
  alias Arbor.Historian.HistoryEntry

  @doc """
  Convert a Signal to an Event for storage in the EventLog.

  The signal's category and type are encoded as `"category:type"` in the
  event's type field. Signal metadata (id, source, priority) is preserved
  in event metadata.

  ## Parameters
  - `signal` - The signal to transform
  - `stream_id` - The stream this event will be appended to
  """
  @spec signal_to_event(struct(), String.t()) :: {:ok, Event.t()} | {:error, term()}
  def signal_to_event(signal, stream_id) do
    category = extract_category(signal)
    signal_type = extract_signal_type(signal)
    event_type = encode_type(category, signal_type)

    Event.new(
      type: event_type,
      subject_id: stream_id,
      subject_type: :historian,
      data: signal.data || %{},
      stream_id: stream_id,
      causation_id: get_in_safe(signal, :cause_id) || get_in_safe(signal, :jido_causation_id),
      correlation_id: get_in_safe(signal, :correlation_id) || get_in_safe(signal, :jido_correlation_id),
      timestamp: get_in_safe(signal, :timestamp) || get_in_safe(signal, :time) || DateTime.utc_now(),
      metadata: %{
        signal_id: signal.id,
        source: get_in_safe(signal, :source),
        priority: get_in_safe(signal, :priority),
        persisted_at: DateTime.utc_now()
      }
    )
  end

  @doc """
  Convert a stored Event back into a HistoryEntry for querying.
  """
  @spec event_to_history_entry(Event.t()) :: HistoryEntry.t()
  def event_to_history_entry(%Event{} = event) do
    HistoryEntry.from_event(event)
  end

  @doc """
  Encode a category and signal type into an event type atom.

  ## Examples

      iex> encode_type(:activity, :agent_started)
      :"activity:agent_started"
  """
  @spec encode_type(atom(), atom()) :: atom()
  def encode_type(category, signal_type) do
    SafeAtom.encode_event_type(category, signal_type)
  end

  @doc """
  Decode an event type atom back into {category, signal_type}.

  Uses SafeAtom to prevent atom exhaustion from untrusted input.

  ## Examples

      iex> decode_type(:"activity:agent_started")
      {:activity, :agent_started}
  """
  @spec decode_type(atom()) :: {atom(), atom()}
  def decode_type(event_type) when is_atom(event_type) do
    SafeAtom.decode_event_type(event_type)
  end

  # Extract category from signal - handles both CloudEvents string types
  # (e.g. "arbor.activity.agent_started") and Arbor.Signals.Signal atom
  # category fields.
  #
  # Uses SafeAtom to prevent atom exhaustion from untrusted CloudEvents.
  defp extract_category(signal) do
    cond do
      # Trust-arbor Arbor.Signals.Signal has a :category atom field
      is_atom(Map.get(signal, :category)) and Map.get(signal, :category) != nil ->
        SafeAtom.to_category(signal.category)

      # CloudEvents / jido_signal style: type is "arbor.category.type"
      is_binary(signal.type) ->
        case signal.type do
          "arbor." <> rest ->
            rest |> String.split(".", parts: 2) |> List.first() |> SafeAtom.to_category()

          type ->
            type |> String.split(".", parts: 2) |> List.first() |> SafeAtom.to_category()
        end

      true ->
        :unknown
    end
  end

  # Extract signal type from signal - handles both string and atom type fields.
  # Uses SafeAtom.to_existing to only convert known signal types.
  defp extract_signal_type(%{type: type}) when is_atom(type), do: type
  defp extract_signal_type(%{type: "arbor." <> rest}), do: parse_signal_type_segment(rest)
  defp extract_signal_type(%{type: type}) when is_binary(type), do: parse_signal_type_segment(type)
  defp extract_signal_type(_signal), do: :unknown

  defp parse_signal_type_segment(segment) do
    case String.split(segment, ".", parts: 2) do
      [_prefix, type] -> safe_to_signal_type(type)
      [single] -> safe_to_signal_type(single)
    end
  end

  # Safely convert signal type string to atom - only if already exists
  defp safe_to_signal_type(type_string) do
    case SafeAtom.to_existing(type_string) do
      {:ok, atom} -> atom
      {:error, _} -> :unknown
    end
  end

  defp get_in_safe(signal, field) do
    Map.get(signal, field)
  rescue
    _ -> nil
  end
end
