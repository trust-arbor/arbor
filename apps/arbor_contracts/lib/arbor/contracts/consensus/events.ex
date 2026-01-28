defmodule Arbor.Contracts.Consensus.Events do
  @moduledoc """
  Event definitions for consensus system event sourcing.

  These events form the append-only history of all consensus activity.
  They enable crash recovery, audit trails, and state reconstruction.

  ## Stream Strategy

  All consensus events go to a single stream: `"arbor:consensus"`
  This simplifies replay and subscription patterns.

  ## Event Flow

      ProposalSubmitted
            │
            ▼
      EvaluationStarted
            │
            ├──► EvaluationCompleted (×N, one per perspective)
            │
            ▼
      DecisionRendered
            │
            ├──► ProposalExecuted (if approved + auto-execute)
            └──► ProposalDeadlocked (if interrupted or no quorum)

  ## Usage

      alias Arbor.Contracts.Consensus.Events

      # Create an event
      event = Events.ProposalSubmitted.new(%{
        proposal_id: "prop_123",
        proposer: "agent_1",
        change_type: :code_modification,
        description: "Add caching"
      })

      # Convert to persistence format
      persistence_event = Events.to_persistence_event(event, "arbor:consensus")
  """

  # Note: We accept maps with :stream_id, :type, :data, :timestamp, :metadata fields
  # instead of struct to avoid cyclic dependency with arbor_persistence

  # ============================================================================
  # Coordinator Lifecycle
  # ============================================================================

  defmodule CoordinatorStarted do
    @moduledoc "Emitted when a Coordinator process starts."
    use TypedStruct

    typedstruct do
      field :coordinator_id, String.t(), enforce: true
      field :config, map(), default: %{}
      field :recovered_from, non_neg_integer() | nil
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        coordinator_id: Map.fetch!(attrs, :coordinator_id),
        config: Map.get(attrs, :config, %{}),
        recovered_from: Map.get(attrs, :recovered_from),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "coordinator.started"
  end

  # ============================================================================
  # Proposal Lifecycle
  # ============================================================================

  defmodule ProposalSubmitted do
    @moduledoc "Emitted when a new proposal is submitted."
    use TypedStruct

    typedstruct do
      field :proposal_id, String.t(), enforce: true
      field :proposer, String.t(), enforce: true
      field :change_type, atom(), enforce: true
      field :description, String.t(), enforce: true
      field :target_layer, integer()
      field :target_module, String.t()
      field :metadata, map(), default: %{}
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        proposal_id: Map.fetch!(attrs, :proposal_id),
        proposer: Map.fetch!(attrs, :proposer),
        change_type: Map.fetch!(attrs, :change_type),
        description: Map.fetch!(attrs, :description),
        target_layer: Map.get(attrs, :target_layer),
        target_module: Map.get(attrs, :target_module) |> stringify_module(),
        metadata: Map.get(attrs, :metadata, %{}),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    defp stringify_module(nil), do: nil
    defp stringify_module(mod) when is_atom(mod), do: Atom.to_string(mod)
    defp stringify_module(mod) when is_binary(mod), do: mod

    def event_type, do: "proposal.submitted"
  end

  defmodule EvaluationStarted do
    @moduledoc "Emitted when council evaluation begins for a proposal."
    use TypedStruct

    typedstruct do
      field :proposal_id, String.t(), enforce: true
      field :perspectives, [atom()], enforce: true
      field :council_size, pos_integer(), enforce: true
      field :required_quorum, pos_integer(), enforce: true
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        proposal_id: Map.fetch!(attrs, :proposal_id),
        perspectives: Map.fetch!(attrs, :perspectives),
        council_size: Map.fetch!(attrs, :council_size),
        required_quorum: Map.fetch!(attrs, :required_quorum),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "evaluation.started"
  end

  defmodule EvaluationCompleted do
    @moduledoc """
    Emitted when a single evaluator completes.

    This event is critical for partial recovery - if the Coordinator crashes
    mid-evaluation, we can see which perspectives already completed and
    only re-run the missing ones.
    """
    use TypedStruct

    typedstruct do
      field :proposal_id, String.t(), enforce: true
      field :evaluation_id, String.t(), enforce: true
      field :perspective, atom(), enforce: true
      field :vote, atom(), enforce: true
      field :confidence, float(), enforce: true
      field :risk_score, float(), default: 0.0
      field :benefit_score, float(), default: 0.0
      field :concerns, [String.t()], default: []
      field :recommendations, [String.t()], default: []
      field :reasoning, String.t()
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        proposal_id: Map.fetch!(attrs, :proposal_id),
        evaluation_id: Map.fetch!(attrs, :evaluation_id),
        perspective: Map.fetch!(attrs, :perspective),
        vote: Map.fetch!(attrs, :vote),
        confidence: Map.fetch!(attrs, :confidence),
        risk_score: Map.get(attrs, :risk_score, 0.0),
        benefit_score: Map.get(attrs, :benefit_score, 0.0),
        concerns: Map.get(attrs, :concerns, []),
        recommendations: Map.get(attrs, :recommendations, []),
        reasoning: Map.get(attrs, :reasoning),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "evaluation.completed"
  end

  defmodule EvaluationFailed do
    @moduledoc "Emitted when an evaluator fails (timeout, error, etc.)."
    use TypedStruct

    typedstruct do
      field :proposal_id, String.t(), enforce: true
      field :perspective, atom(), enforce: true
      field :reason, String.t(), enforce: true
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        proposal_id: Map.fetch!(attrs, :proposal_id),
        perspective: Map.fetch!(attrs, :perspective),
        reason: Map.fetch!(attrs, :reason),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "evaluation.failed"
  end

  # ============================================================================
  # Decision Lifecycle
  # ============================================================================

  defmodule DecisionRendered do
    @moduledoc "Emitted when the council reaches a decision."
    use TypedStruct

    typedstruct do
      field :proposal_id, String.t(), enforce: true
      field :decision_id, String.t(), enforce: true
      field :decision, atom(), enforce: true
      field :approve_count, non_neg_integer(), enforce: true
      field :reject_count, non_neg_integer(), enforce: true
      field :abstain_count, non_neg_integer(), enforce: true
      field :required_quorum, pos_integer(), enforce: true
      field :quorum_met, boolean(), enforce: true
      field :primary_concerns, [String.t()], default: []
      field :average_confidence, float(), default: 0.0
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        proposal_id: Map.fetch!(attrs, :proposal_id),
        decision_id: Map.fetch!(attrs, :decision_id),
        decision: Map.fetch!(attrs, :decision),
        approve_count: Map.fetch!(attrs, :approve_count),
        reject_count: Map.fetch!(attrs, :reject_count),
        abstain_count: Map.fetch!(attrs, :abstain_count),
        required_quorum: Map.fetch!(attrs, :required_quorum),
        quorum_met: Map.fetch!(attrs, :quorum_met),
        primary_concerns: Map.get(attrs, :primary_concerns, []),
        average_confidence: Map.get(attrs, :average_confidence, 0.0),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "decision.rendered"
  end

  defmodule ProposalExecuted do
    @moduledoc "Emitted when an approved proposal is executed."
    use TypedStruct

    typedstruct do
      field :proposal_id, String.t(), enforce: true
      field :result, atom(), enforce: true
      field :output, term()
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        proposal_id: Map.fetch!(attrs, :proposal_id),
        result: Map.fetch!(attrs, :result),
        output: Map.get(attrs, :output),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "proposal.executed"
  end

  defmodule ProposalDeadlocked do
    @moduledoc "Emitted when a proposal ends in deadlock (interrupted or no quorum)."
    use TypedStruct

    typedstruct do
      field :proposal_id, String.t(), enforce: true
      field :reason, atom(), enforce: true
      field :details, String.t()
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        proposal_id: Map.fetch!(attrs, :proposal_id),
        reason: Map.fetch!(attrs, :reason),
        details: Map.get(attrs, :details),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "proposal.deadlocked"
  end

  # ============================================================================
  # Recovery Events
  # ============================================================================

  defmodule RecoveryStarted do
    @moduledoc "Emitted when Coordinator begins crash recovery."
    use TypedStruct

    typedstruct do
      field :coordinator_id, String.t(), enforce: true
      field :from_position, non_neg_integer(), enforce: true
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        coordinator_id: Map.fetch!(attrs, :coordinator_id),
        from_position: Map.fetch!(attrs, :from_position),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "recovery.started"
  end

  defmodule RecoveryCompleted do
    @moduledoc "Emitted when crash recovery finishes."
    use TypedStruct

    typedstruct do
      field :coordinator_id, String.t(), enforce: true
      field :proposals_recovered, non_neg_integer(), enforce: true
      field :decisions_recovered, non_neg_integer(), enforce: true
      field :interrupted_count, non_neg_integer(), enforce: true
      field :events_replayed, non_neg_integer(), enforce: true
      field :timestamp, DateTime.t(), enforce: true
    end

    def new(attrs) do
      %__MODULE__{
        coordinator_id: Map.fetch!(attrs, :coordinator_id),
        proposals_recovered: Map.fetch!(attrs, :proposals_recovered),
        decisions_recovered: Map.fetch!(attrs, :decisions_recovered),
        interrupted_count: Map.fetch!(attrs, :interrupted_count),
        events_replayed: Map.fetch!(attrs, :events_replayed),
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
      }
    end

    def event_type, do: "recovery.completed"
  end

  # ============================================================================
  # Serialization Helpers
  # ============================================================================

  @doc """
  Convert a domain event to a persistence event map.

  Returns a map compatible with `Arbor.Persistence.Event.new/4`.
  The caller (EventEmitter) is responsible for actually creating
  the persistence event.
  """
  def to_persistence_event(event, stream_id, opts \\ []) do
    event_type = event.__struct__.event_type()

    # Convert struct to map, handling atoms and datetimes
    data =
      event
      |> Map.from_struct()
      |> Map.drop([:timestamp])
      |> serialize_data()

    # Return a map that can be passed to Arbor.Persistence.Event.new/4
    %{
      stream_id: stream_id,
      type: event_type,
      data: data,
      metadata: Keyword.get(opts, :metadata, %{}),
      causation_id: Keyword.get(opts, :causation_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      timestamp: event.timestamp
    }
  end

  @doc """
  Convert a persistence event back to a domain event.

  Accepts either a struct with :type, :data, :timestamp fields
  or a map with the same keys.
  """
  def from_persistence_event(%{type: type, data: data, timestamp: timestamp} = _event) do
    case type_to_module(type) do
      nil ->
        {:error, {:unknown_event_type, type}}

      module when is_atom(module) ->
        deserialized =
          data
          |> deserialize_data()
          |> Map.put(:timestamp, timestamp)

        {:ok, create_event(module, deserialized)}
    end
  end

  # Helper to avoid dynamic module.new/1 warning
  defp create_event(module, attrs), do: module.new(attrs)

  @event_type_modules %{
    "coordinator.started" => CoordinatorStarted,
    "proposal.submitted" => ProposalSubmitted,
    "evaluation.started" => EvaluationStarted,
    "evaluation.completed" => EvaluationCompleted,
    "evaluation.failed" => EvaluationFailed,
    "decision.rendered" => DecisionRendered,
    "proposal.executed" => ProposalExecuted,
    "proposal.deadlocked" => ProposalDeadlocked,
    "recovery.started" => RecoveryStarted,
    "recovery.completed" => RecoveryCompleted
  }

  @doc """
  Get the event module for an event type string.
  """
  def type_to_module(type), do: Map.get(@event_type_modules, type)

  @doc """
  List all known event types.
  """
  def all_event_types, do: Map.keys(@event_type_modules)

  # Private helpers

  defp serialize_data(data) when is_map(data) do
    Map.new(data, fn
      {k, v} when is_atom(v) -> {k, Atom.to_string(v)}
      {k, v} when is_list(v) -> {k, Enum.map(v, &serialize_value/1)}
      {k, v} -> {k, serialize_value(v)}
    end)
  end

  defp serialize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_value(v), do: v

  defp deserialize_data(data) when is_map(data) do
    Map.new(data, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), deserialize_value(k, v)}
      {k, v} -> {k, deserialize_value(k, v)}
    end)
  rescue
    ArgumentError -> data
  end

  # Fields that should be atoms
  @atom_fields [:change_type, :perspective, :vote, :decision, :reason, :result]

  defp deserialize_value(key, value) when is_binary(value) do
    key_atom = if is_binary(key), do: String.to_existing_atom(key), else: key

    if key_atom in @atom_fields do
      String.to_existing_atom(value)
    else
      value
    end
  rescue
    ArgumentError -> value
  end

  defp deserialize_value(_key, value), do: value
end
