defmodule Arbor.Contracts.Consensus.ConsensusEvent do
  @moduledoc """
  Data structure for consensus system events.

  ConsensusEvents provide a complete audit trail of all activities
  in the consensus system, enabling historical analysis and debugging
  of past decisions.

  ## Event Types

  - `:proposal_submitted` - A new proposal was created
  - `:evaluation_submitted` - An evaluator cast their vote
  - `:council_complete` - All evaluators have voted
  - `:decision_reached` - Final decision determined
  - `:execution_started` - Approved change execution began
  - `:execution_succeeded` - Change executed successfully
  - `:execution_failed` - Change execution failed
  - `:proposal_cancelled` - Proposal was manually cancelled

  ## Usage

      {:ok, event} = ConsensusEvent.new(%{
        event_type: :proposal_submitted,
        proposal_id: "prop_123",
        agent_id: "agent_456",
        data: %{change_type: :code_modification}
      })

      # Query events via the consensus facade
      events = Arbor.Consensus.get_events("prop_123")
  """

  use TypedStruct

  @type event_type ::
          :proposal_submitted
          | :evaluation_submitted
          | :council_complete
          | :decision_reached
          | :execution_started
          | :execution_succeeded
          | :execution_failed
          | :proposal_cancelled
          | :proposal_timeout

  @event_types [
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

  typedstruct enforce: true do
    @typedoc "A consensus system event"

    field(:id, String.t())
    field(:event_type, event_type())
    field(:proposal_id, String.t())
    field(:agent_id, String.t() | nil, enforce: false)
    field(:evaluator_id, String.t() | nil, enforce: false)
    field(:decision_id, String.t() | nil, enforce: false)

    # Event-specific data
    field(:data, map(), default: %{})

    # For evaluation events
    field(:vote, atom() | nil, enforce: false)
    field(:perspective, atom() | nil, enforce: false)
    field(:confidence, float() | nil, enforce: false)

    # For decision events
    field(:decision, atom() | nil, enforce: false)
    field(:approve_count, non_neg_integer() | nil, enforce: false)
    field(:reject_count, non_neg_integer() | nil, enforce: false)
    field(:abstain_count, non_neg_integer() | nil, enforce: false)

    # Metadata
    field(:correlation_id, String.t() | nil, enforce: false)
    field(:timestamp, DateTime.t())
  end

  @doc """
  Create a new consensus event.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    event_type = Map.fetch!(attrs, :event_type)

    unless event_type in @event_types do
      raise ArgumentError, "Invalid event_type: #{inspect(event_type)}"
    end

    event = %__MODULE__{
      id: attrs[:id] || generate_id(),
      event_type: event_type,
      proposal_id: Map.fetch!(attrs, :proposal_id),
      agent_id: Map.get(attrs, :agent_id),
      evaluator_id: Map.get(attrs, :evaluator_id),
      decision_id: Map.get(attrs, :decision_id),
      data: Map.get(attrs, :data, %{}),
      vote: Map.get(attrs, :vote),
      perspective: Map.get(attrs, :perspective),
      confidence: Map.get(attrs, :confidence),
      decision: Map.get(attrs, :decision),
      approve_count: Map.get(attrs, :approve_count),
      reject_count: Map.get(attrs, :reject_count),
      abstain_count: Map.get(attrs, :abstain_count),
      correlation_id: Map.get(attrs, :correlation_id),
      timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
    }

    {:ok, event}
  rescue
    e in [KeyError, ArgumentError] ->
      {:error, {:invalid_event, Exception.message(e)}}
  end

  @doc """
  Create a proposal submitted event.
  """
  @spec proposal_submitted(map()) :: {:ok, t()} | {:error, term()}
  def proposal_submitted(attrs) do
    new(
      Map.merge(attrs, %{
        event_type: :proposal_submitted,
        data:
          Map.merge(Map.get(attrs, :data, %{}), %{
            change_type: attrs[:change_type],
            description: attrs[:description],
            target_module: attrs[:target_module]
          })
      })
    )
  end

  @doc """
  Create an evaluation submitted event.
  """
  @spec evaluation_submitted(map()) :: {:ok, t()} | {:error, term()}
  def evaluation_submitted(attrs) do
    new(
      Map.merge(attrs, %{
        event_type: :evaluation_submitted,
        data:
          Map.merge(Map.get(attrs, :data, %{}), %{
            concerns: attrs[:concerns] || [],
            recommendations: attrs[:recommendations] || [],
            risk_score: attrs[:risk_score],
            benefit_score: attrs[:benefit_score],
            reasoning: attrs[:reasoning]
          })
      })
    )
  end

  @doc """
  Create a decision reached event.
  """
  @spec decision_reached(map()) :: {:ok, t()} | {:error, term()}
  def decision_reached(attrs) do
    new(
      Map.merge(attrs, %{
        event_type: :decision_reached,
        data:
          Map.merge(Map.get(attrs, :data, %{}), %{
            quorum_met: attrs[:quorum_met],
            required_quorum: attrs[:required_quorum],
            primary_concerns: attrs[:primary_concerns] || [],
            average_confidence: attrs[:average_confidence],
            average_risk: attrs[:average_risk],
            average_benefit: attrs[:average_benefit]
          })
      })
    )
  end

  @doc """
  Create an execution event.
  """
  @spec execution_event(atom(), map()) :: {:ok, t()} | {:error, term()}
  def execution_event(status, attrs) when status in [:started, :succeeded, :failed] do
    event_type =
      case status do
        :started -> :execution_started
        :succeeded -> :execution_succeeded
        :failed -> :execution_failed
      end

    new(
      Map.merge(attrs, %{
        event_type: event_type,
        data:
          Map.merge(Map.get(attrs, :data, %{}), %{
            result: attrs[:result],
            error: attrs[:error],
            duration_ms: attrs[:duration_ms]
          })
      })
    )
  end

  @doc """
  Get all valid event types.
  """
  @spec event_types() :: [
          :proposal_submitted
          | :evaluation_submitted
          | :council_complete
          | :decision_reached
          | :execution_started
          | :execution_succeeded
          | :execution_failed
          | :proposal_cancelled
          | :proposal_timeout,
          ...
        ]
  def event_types, do: @event_types

  @doc """
  Check if this is a terminal event (proposal lifecycle complete).
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{event_type: type}) do
    type in [:execution_succeeded, :execution_failed, :proposal_cancelled, :proposal_timeout]
  end

  @doc """
  Convert event to a map suitable for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      id: event.id,
      event_type: event.event_type,
      proposal_id: event.proposal_id,
      agent_id: event.agent_id,
      evaluator_id: event.evaluator_id,
      decision_id: event.decision_id,
      data: event.data,
      vote: event.vote,
      perspective: event.perspective,
      confidence: event.confidence,
      decision: event.decision,
      approve_count: event.approve_count,
      reject_count: event.reject_count,
      abstain_count: event.abstain_count,
      correlation_id: event.correlation_id,
      timestamp: DateTime.to_iso8601(event.timestamp)
    }
  end

  @doc """
  Reconstruct event from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    attrs =
      map
      |> Enum.map(fn
        {"event_type", v} -> {:event_type, String.to_existing_atom(v)}
        {"timestamp", v} when is_binary(v) -> {:timestamp, DateTime.from_iso8601(v) |> elem(1)}
        {"vote", v} when is_binary(v) -> {:vote, String.to_existing_atom(v)}
        {"perspective", v} when is_binary(v) -> {:perspective, String.to_existing_atom(v)}
        {"decision", v} when is_binary(v) -> {:decision, String.to_existing_atom(v)}
        {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
        {k, v} when is_atom(k) -> {k, v}
      end)
      |> Map.new()

    new(attrs)
  rescue
    _ -> {:error, :invalid_map}
  end

  # Private functions

  defp generate_id do
    "cev_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
