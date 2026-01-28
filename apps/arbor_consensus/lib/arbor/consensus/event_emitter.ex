defmodule Arbor.Consensus.EventEmitter do
  @moduledoc """
  Emits consensus events to the configured EventLog.

  Wraps event creation and persistence, handling both ETS (dev/test)
  and Postgres (production) backends transparently.

  ## Configuration

      config :arbor_consensus,
        event_log: {Arbor.Persistence.EventLog.ETS, name: :consensus_events},
        event_stream: "arbor:consensus"

  ## Usage

      alias Arbor.Consensus.EventEmitter
      alias Arbor.Contracts.Consensus.Events

      # Emit a proposal submitted event
      event = Events.ProposalSubmitted.new(%{
        proposal_id: "prop_123",
        proposer: "agent_1",
        change_type: :code_modification,
        description: "Add caching"
      })

      EventEmitter.emit(event, correlation_id: "corr_123")
  """

  alias Arbor.Consensus.Config
  alias Arbor.Contracts.Consensus.Events
  alias Arbor.Persistence.Event, as: PersistenceEvent

  require Logger

  @type event :: struct()
  @type opts :: keyword()

  @doc """
  Emit a consensus event to the configured EventLog.

  ## Options

  - `:correlation_id` - ID linking related events
  - `:causation_id` - ID of the event that caused this one
  - `:metadata` - Additional metadata to attach
  """
  @spec emit(event(), opts()) :: :ok | {:error, term()}
  def emit(event, opts \\ []) do
    case event_log_config() do
      nil ->
        # No event log configured - events are not persisted
        Logger.debug("EventEmitter: no event_log configured, event not persisted",
          event_type: event.__struct__.event_type()
        )

        :ok

      {module, log_opts} ->
        do_emit(event, module, log_opts, opts)
    end
  end

  @doc """
  Emit multiple events atomically (if supported by backend).
  """
  @spec emit_all([event()], opts()) :: :ok | {:error, term()}
  def emit_all(events, opts \\ []) when is_list(events) do
    case event_log_config() do
      nil ->
        :ok

      {module, log_opts} ->
        stream_id = Config.event_stream()

        persistence_events =
          Enum.map(events, fn event ->
            event_map =
              Events.to_persistence_event(event, stream_id,
                metadata: Keyword.get(opts, :metadata, %{}),
                causation_id: Keyword.get(opts, :causation_id),
                correlation_id: Keyword.get(opts, :correlation_id)
              )

            PersistenceEvent.new(
              event_map.stream_id,
              event_map.type,
              event_map.data,
              metadata: event_map.metadata,
              causation_id: event_map.causation_id,
              correlation_id: event_map.correlation_id,
              timestamp: event_map.timestamp
            )
          end)

        case module.append(stream_id, persistence_events, log_opts) do
          {:ok, _persisted} ->
            Logger.debug("EventEmitter: emitted #{length(events)} events")
            :ok

          {:error, reason} = error ->
            Logger.error("EventEmitter: failed to emit events: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Check if event logging is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    event_log_config() != nil
  end

  @doc """
  Get the current event stream name.
  """
  @spec stream_id() :: String.t()
  def stream_id do
    Config.event_stream()
  end

  # ============================================================================
  # Convenience Emitters
  # ============================================================================

  @doc "Emit a CoordinatorStarted event."
  def coordinator_started(coordinator_id, config_map, opts \\ []) do
    Events.CoordinatorStarted.new(%{
      coordinator_id: coordinator_id,
      config: config_map,
      recovered_from: Keyword.get(opts, :recovered_from)
    })
    |> emit(opts)
  end

  @doc "Emit a ProposalSubmitted event."
  def proposal_submitted(proposal, opts \\ []) do
    Events.ProposalSubmitted.new(%{
      proposal_id: proposal.id,
      proposer: proposal.proposer,
      change_type: proposal.change_type,
      description: proposal.description,
      target_layer: proposal.target_layer,
      target_module: proposal.target_module,
      metadata: proposal.metadata
    })
    |> emit(Keyword.put(opts, :correlation_id, proposal.id))
  end

  @doc "Emit an EvaluationStarted event."
  def evaluation_started(proposal_id, perspectives, council_size, required_quorum, opts \\ []) do
    Events.EvaluationStarted.new(%{
      proposal_id: proposal_id,
      perspectives: perspectives,
      council_size: council_size,
      required_quorum: required_quorum
    })
    |> emit(Keyword.put(opts, :correlation_id, proposal_id))
  end

  @doc "Emit an EvaluationCompleted event."
  def evaluation_completed(evaluation, opts \\ []) do
    Events.EvaluationCompleted.new(%{
      proposal_id: evaluation.proposal_id,
      evaluation_id: evaluation.id,
      perspective: evaluation.perspective,
      vote: evaluation.vote,
      confidence: evaluation.confidence,
      risk_score: evaluation.risk_score,
      benefit_score: evaluation.benefit_score,
      concerns: evaluation.concerns,
      recommendations: evaluation.recommendations,
      reasoning: evaluation.reasoning
    })
    |> emit(Keyword.put(opts, :correlation_id, evaluation.proposal_id))
  end

  @doc "Emit an EvaluationFailed event."
  def evaluation_failed(proposal_id, perspective, reason, opts \\ []) do
    Events.EvaluationFailed.new(%{
      proposal_id: proposal_id,
      perspective: perspective,
      reason: inspect(reason)
    })
    |> emit(Keyword.put(opts, :correlation_id, proposal_id))
  end

  @doc "Emit a DecisionRendered event."
  def decision_rendered(decision, opts \\ []) do
    Events.DecisionRendered.new(%{
      proposal_id: decision.proposal_id,
      decision_id: decision.id,
      decision: decision.decision,
      approve_count: decision.approve_count,
      reject_count: decision.reject_count,
      abstain_count: decision.abstain_count,
      required_quorum: decision.required_quorum,
      quorum_met: decision.quorum_met,
      primary_concerns: decision.primary_concerns,
      average_confidence: decision.average_confidence
    })
    |> emit(Keyword.put(opts, :correlation_id, decision.proposal_id))
  end

  @doc "Emit a ProposalExecuted event."
  def proposal_executed(proposal_id, result, output \\ nil, opts \\ []) do
    Events.ProposalExecuted.new(%{
      proposal_id: proposal_id,
      result: result,
      output: output
    })
    |> emit(Keyword.put(opts, :correlation_id, proposal_id))
  end

  @doc "Emit a ProposalDeadlocked event."
  def proposal_deadlocked(proposal_id, reason, details \\ nil, opts \\ []) do
    Events.ProposalDeadlocked.new(%{
      proposal_id: proposal_id,
      reason: reason,
      details: details
    })
    |> emit(Keyword.put(opts, :correlation_id, proposal_id))
  end

  @doc "Emit a RecoveryStarted event."
  def recovery_started(coordinator_id, from_position, opts \\ []) do
    Events.RecoveryStarted.new(%{
      coordinator_id: coordinator_id,
      from_position: from_position
    })
    |> emit(opts)
  end

  @doc "Emit a RecoveryCompleted event."
  def recovery_completed(coordinator_id, stats, opts \\ []) do
    Events.RecoveryCompleted.new(%{
      coordinator_id: coordinator_id,
      proposals_recovered: stats.proposals_recovered,
      decisions_recovered: stats.decisions_recovered,
      interrupted_count: stats.interrupted_count,
      events_replayed: stats.events_replayed
    })
    |> emit(opts)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_emit(event, module, log_opts, opts) do
    stream_id = Config.event_stream()

    # Get event data as map from Events module
    event_map =
      Events.to_persistence_event(event, stream_id,
        metadata: Keyword.get(opts, :metadata, %{}),
        causation_id: Keyword.get(opts, :causation_id),
        correlation_id: Keyword.get(opts, :correlation_id)
      )

    # Create actual persistence event
    persistence_event =
      PersistenceEvent.new(
        event_map.stream_id,
        event_map.type,
        event_map.data,
        metadata: event_map.metadata,
        causation_id: event_map.causation_id,
        correlation_id: event_map.correlation_id,
        timestamp: event_map.timestamp
      )

    case module.append(stream_id, persistence_event, log_opts) do
      {:ok, [_persisted]} ->
        Logger.debug("EventEmitter: emitted #{event.__struct__.event_type()}")
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} = error ->
        Logger.error("EventEmitter: failed to emit event: #{inspect(reason)}")
        error
    end
  end

  defp event_log_config do
    Config.event_log()
  end
end
