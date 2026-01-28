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

  alias Arbor.Common.SafeAtom
  alias Arbor.Contracts.Consensus.ConsensusEvent
  alias Arbor.Persistence.Event, as: PersistenceEvent

  # Known allowed values for safe atom conversion
  @allowed_event_types [
    :proposal_submitted,
    :evaluation_submitted,
    :council_complete,
    :decision_reached,
    :execution_started,
    :execution_succeeded,
    :execution_failed,
    :proposal_cancelled,
    :proposal_timeout
  ]

  @allowed_votes [:approve, :reject, :abstain]

  @allowed_perspectives [
    :security,
    :stability,
    :capability,
    :adversarial,
    :resource,
    :emergence,
    :random,
    :test_runner,
    :code_review,
    :human
  ]

  @allowed_decisions [:approved, :rejected, :deadlock]

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
      event_type: atomize_event_type(field(data, :event_type)),
      proposal_id: field(data, :proposal_id),
      agent_id: field(data, :agent_id),
      evaluator_id: field(data, :evaluator_id),
      decision_id: field(data, :decision_id),
      vote: atomize_vote(field(data, :vote)),
      perspective: atomize_perspective(field(data, :perspective)),
      confidence: field(data, :confidence),
      decision: atomize_decision(field(data, :decision)),
      approve_count: field(data, :approve_count),
      reject_count: field(data, :reject_count),
      abstain_count: field(data, :abstain_count),
      data: field(data, :data) || %{},
      correlation_id: event.correlation_id,
      timestamp: event.timestamp
    })
  end

  @doc """
  Build the stream ID for a consensus event.
  """
  @spec stream_id(ConsensusEvent.t()) :: String.t()
  def stream_id(%ConsensusEvent{proposal_id: proposal_id}), do: "consensus:#{proposal_id}"

  defp field(data, key) do
    data[key] || data[Atom.to_string(key)]
  end

  # Safe atom conversion for each field type using explicit allowlists
  defp atomize_event_type(nil), do: nil
  defp atomize_event_type(value) when is_atom(value), do: value

  defp atomize_event_type(value) when is_binary(value) do
    case SafeAtom.to_allowed(value, @allowed_event_types) do
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end

  defp atomize_vote(nil), do: nil
  defp atomize_vote(value) when is_atom(value), do: value

  defp atomize_vote(value) when is_binary(value) do
    case SafeAtom.to_allowed(value, @allowed_votes) do
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end

  defp atomize_perspective(nil), do: nil
  defp atomize_perspective(value) when is_atom(value), do: value

  defp atomize_perspective(value) when is_binary(value) do
    case SafeAtom.to_allowed(value, @allowed_perspectives) do
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end

  defp atomize_decision(nil), do: nil
  defp atomize_decision(value) when is_atom(value), do: value

  defp atomize_decision(value) when is_binary(value) do
    case SafeAtom.to_allowed(value, @allowed_decisions) do
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end
end
