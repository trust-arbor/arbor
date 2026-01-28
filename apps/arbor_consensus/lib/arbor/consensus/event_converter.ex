defmodule Arbor.Consensus.EventConverter do
  @moduledoc """
  Converts between `ConsensusEvent` and `Arbor.Persistence.Event`.

  Used at the domain boundary when persisting consensus events to the
  unified EventLog and when reading them back.

  ## Stream ID Convention

  Consensus events are stored in streams named `"consensus:{proposal_id}"`.

  ## Type Convention

  Event types are stored as `"arbor.consensus.{event_type}"`.
  """

  alias Arbor.Contracts.Consensus.ConsensusEvent
  alias Arbor.Persistence.Event, as: PersistenceEvent

  @doc """
  Convert a ConsensusEvent to a Persistence.Event for durable storage.
  """
  @spec to_persistence_event(ConsensusEvent.t()) :: PersistenceEvent.t()
  def to_persistence_event(%ConsensusEvent{} = event) do
    stream_id = stream_id(event)

    data = %{
      event_type: event.event_type,
      proposal_id: event.proposal_id,
      agent_id: event.agent_id,
      evaluator_id: event.evaluator_id,
      decision_id: event.decision_id,
      vote: event.vote,
      perspective: event.perspective,
      confidence: event.confidence,
      decision: event.decision,
      approve_count: event.approve_count,
      reject_count: event.reject_count,
      abstain_count: event.abstain_count,
      data: event.data
    }

    PersistenceEvent.new(
      stream_id,
      "arbor.consensus.#{event.event_type}",
      data,
      id: event.id,
      metadata: %{},
      correlation_id: event.correlation_id,
      timestamp: event.timestamp
    )
  end

  @doc """
  Convert a Persistence.Event back to a ConsensusEvent.
  """
  @spec from_persistence_event(PersistenceEvent.t()) ::
          {:ok, ConsensusEvent.t()} | {:error, term()}
  def from_persistence_event(%PersistenceEvent{} = event) do
    data = event.data

    ConsensusEvent.new(%{
      id: event.id,
      event_type: atomize(data[:event_type] || data["event_type"]),
      proposal_id: data[:proposal_id] || data["proposal_id"],
      agent_id: data[:agent_id] || data["agent_id"],
      evaluator_id: data[:evaluator_id] || data["evaluator_id"],
      decision_id: data[:decision_id] || data["decision_id"],
      vote: atomize(data[:vote] || data["vote"]),
      perspective: atomize(data[:perspective] || data["perspective"]),
      confidence: data[:confidence] || data["confidence"],
      decision: atomize(data[:decision] || data["decision"]),
      approve_count: data[:approve_count] || data["approve_count"],
      reject_count: data[:reject_count] || data["reject_count"],
      abstain_count: data[:abstain_count] || data["abstain_count"],
      data: data[:data] || data["data"] || %{},
      correlation_id: event.correlation_id,
      timestamp: event.timestamp
    })
  end

  @doc """
  Build the stream ID for a consensus event.
  """
  @spec stream_id(ConsensusEvent.t()) :: String.t()
  def stream_id(%ConsensusEvent{proposal_id: proposal_id}), do: "consensus:#{proposal_id}"

  defp atomize(nil), do: nil
  defp atomize(value) when is_atom(value), do: value

  defp atomize(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> String.to_atom(value)
  end
end
