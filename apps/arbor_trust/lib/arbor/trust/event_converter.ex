defmodule Arbor.Trust.EventConverter do
  @moduledoc """
  Converts between `Arbor.Contracts.Trust.Event` and `Arbor.Persistence.Event`.

  Used at the domain boundary when persisting trust events to the
  unified EventLog and when reading them back.

  ## Stream ID Convention

  Trust events are stored in streams named `"trust:{agent_id}"`.

  ## Type Convention

  Event types are stored as `"arbor.trust.{event_type}"`.
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Contracts.Trust.Event, as: TrustEvent
  alias Arbor.Persistence.Event, as: PersistenceEvent

  # Known allowed tiers for safe atom conversion
  @allowed_tiers [
    :untrusted,
    :probationary,
    :trusted,
    :veteran,
    :autonomous,
    # Legacy score-based tiers
    :elevated,
    :core
  ]

  @doc """
  Convert a Trust.Event to a Persistence.Event for durable storage.
  """
  @spec to_persistence_event(TrustEvent.t()) :: PersistenceEvent.t()
  def to_persistence_event(%TrustEvent{} = event) do
    stream_id = stream_id(event)

    data = %{
      agent_id: event.agent_id,
      event_type: event.event_type,
      previous_score: event.previous_score,
      new_score: event.new_score,
      delta: event.delta,
      previous_tier: event.previous_tier,
      new_tier: event.new_tier,
      reason: event.reason
    }

    PersistenceEvent.new(
      stream_id,
      "arbor.trust.#{event.event_type}",
      data,
      id: event.id,
      metadata: event.metadata || %{},
      timestamp: event.timestamp
    )
  end

  @doc """
  Convert a Persistence.Event back to a Trust.Event.
  """
  @spec from_persistence_event(PersistenceEvent.t()) :: {:ok, TrustEvent.t()} | {:error, term()}
  def from_persistence_event(%PersistenceEvent{} = event) do
    data = event.data

    TrustEvent.new(
      id: event.id,
      agent_id: data[:agent_id] || data["agent_id"],
      event_type: atomize_event_type(data[:event_type] || data["event_type"]),
      timestamp: event.timestamp,
      previous_score: data[:previous_score] || data["previous_score"],
      new_score: data[:new_score] || data["new_score"],
      previous_tier: atomize_tier(data[:previous_tier] || data["previous_tier"]),
      new_tier: atomize_tier(data[:new_tier] || data["new_tier"]),
      reason: data[:reason] || data["reason"],
      metadata: event.metadata || %{}
    )
  end

  @doc """
  Build the stream ID for a trust event.
  """
  @spec stream_id(TrustEvent.t()) :: String.t()
  def stream_id(%TrustEvent{agent_id: agent_id}), do: "trust:#{agent_id}"

  # Safe atom conversion for event types using the TrustEvent's known values
  defp atomize_event_type(nil), do: nil
  defp atomize_event_type(value) when is_atom(value), do: value

  defp atomize_event_type(value) when is_binary(value) do
    case SafeAtom.to_allowed(value, TrustEvent.valid_event_types()) do
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end

  # Safe atom conversion for tier values
  defp atomize_tier(nil), do: nil
  defp atomize_tier(value) when is_atom(value), do: value

  defp atomize_tier(value) when is_binary(value) do
    case SafeAtom.to_allowed(value, @allowed_tiers) do
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end
end
