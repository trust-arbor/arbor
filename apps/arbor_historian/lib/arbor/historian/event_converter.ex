defmodule Arbor.Historian.EventConverter do
  @moduledoc """
  Converts between `Arbor.Historian.Event` and `Arbor.Persistence.Event`.

  Used at the domain boundary when the Historian persists events to the
  unified EventLog and when reading them back.

  Uses `Arbor.Common.SafeAtom` for safe string-to-atom conversion to prevent
  atom exhaustion attacks from untrusted input.

  ## Stream ID Convention

  Historian events already carry a `stream_id`. This is preserved as-is.

  ## Type Convention

  Event types are stored as `"arbor.historian.{type}"`.
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Historian.Event, as: HistorianEvent
  alias Arbor.Persistence.Event, as: PersistenceEvent

  @doc """
  Convert a Historian.Event to a Persistence.Event for durable storage.
  """
  @spec to_persistence_event(HistorianEvent.t(), String.t()) :: PersistenceEvent.t()
  def to_persistence_event(%HistorianEvent{} = event, stream_id) do
    PersistenceEvent.new(
      stream_id,
      "arbor.historian.#{event.type}",
      event.data,
      id: event.id,
      metadata:
        Map.merge(event.metadata || %{}, %{
          subject_id: event.subject_id,
          subject_type: event.subject_type,
          version: event.version
        }),
      causation_id: event.causation_id,
      correlation_id: event.correlation_id,
      timestamp: event.timestamp
    )
  end

  @doc """
  Convert a Persistence.Event back to a Historian.Event.
  """
  @spec from_persistence_event(PersistenceEvent.t()) ::
          {:ok, HistorianEvent.t()} | {:error, term()}
  def from_persistence_event(%PersistenceEvent{} = event) do
    # Extract the historian-specific type from the persistence type
    type = extract_type(event.type)
    meta = event.metadata || %{}

    HistorianEvent.new(
      id: event.id,
      type: type,
      subject_id: meta[:subject_id] || meta["subject_id"] || event.stream_id,
      subject_type: atomize_subject_type(meta[:subject_type] || meta["subject_type"]),
      data: event.data,
      timestamp: event.timestamp,
      causation_id: event.causation_id,
      correlation_id: event.correlation_id,
      stream_id: event.stream_id,
      stream_version: event.event_number,
      global_position: event.global_position,
      version: meta[:version] || meta["version"] || "1.0.0",
      metadata: Map.drop(meta, [:subject_id, :subject_type, :version, "subject_id", "subject_type", "version"])
    )
  end

  defp extract_type("arbor.historian." <> rest) do
    encode_event_type_from_string(rest)
  end

  defp extract_type(type) when is_binary(type) do
    encode_event_type_from_string(type)
  end

  # Convert a "category:type" string into a safely-encoded event type atom.
  # Uses SafeAtom.encode_event_type to create the combined atom safely.
  defp encode_event_type_from_string(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [category_str, type_str] ->
        category = SafeAtom.to_category(category_str)
        # For type, use to_existing to only allow known types
        type =
          case SafeAtom.to_existing(type_str) do
            {:ok, atom} -> atom
            {:error, _} -> :unknown
          end

        SafeAtom.encode_event_type(category, type)

      [_single] ->
        # Single value without colon - try to atomize it safely
        case SafeAtom.to_existing(value) do
          {:ok, atom} -> atom
          {:error, _} -> :unknown
        end
    end
  end

  defp encode_event_type_from_string(nil), do: nil
  defp encode_event_type_from_string(value) when is_atom(value), do: value

  # Subject type uses SafeAtom.to_subject_type which has known allowed values
  defp atomize_subject_type(nil), do: nil
  defp atomize_subject_type(value) when is_atom(value), do: value
  defp atomize_subject_type(value) when is_binary(value), do: SafeAtom.to_subject_type(value)
end
