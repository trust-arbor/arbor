defmodule Arbor.Consensus.StateRecovery do
  @moduledoc """
  Rebuilds Coordinator state from persisted events.

  Enables crash recovery by replaying the event stream and
  reconstructing proposals, decisions, and detecting interrupted
  evaluations.

  ## Recovery Flow

      1. Read all events from "arbor:consensus" stream
      2. Fold events into state accumulator
      3. Detect interrupted evaluations (started but no decision)
      4. Return recovered state for Coordinator to use

  ## Interrupted Evaluation Handling

  When an evaluation was started but no decision was rendered:
  - Track which perspectives completed via EvaluationCompleted events
  - Mark as interrupted with list of missing perspectives
  - Coordinator decides: deadlock vs resume vs restart

  ## Usage

      alias Arbor.Consensus.StateRecovery

      # Full recovery from event stream
      {:ok, state} = StateRecovery.rebuild_from_events(event_log_config)

      # state contains:
      # - proposals: %{proposal_id => proposal_info}
      # - decisions: %{proposal_id => decision}
      # - interrupted: [%{proposal_id: id, missing_perspectives: [...]}]
  """

  alias Arbor.Consensus.Config
  alias Arbor.Contracts.Consensus.Events

  require Logger

  @type proposal_info :: %{
          id: String.t(),
          proposer: String.t(),
          change_type: atom(),
          description: String.t(),
          status: :submitted | :evaluating | :decided | :executed | :deadlocked,
          submitted_at: DateTime.t(),
          perspectives: [atom()],
          completed_evaluations: %{atom() => map()},
          decision: map() | nil
        }

  @type recovered_state :: %{
          proposals: %{String.t() => proposal_info()},
          decisions: %{String.t() => map()},
          interrupted: [%{proposal_id: String.t(), missing_perspectives: [atom()]}],
          last_position: non_neg_integer(),
          events_replayed: non_neg_integer()
        }

  @doc """
  Rebuild state from persisted events.

  Returns recovered state including proposals, decisions, and
  any interrupted evaluations that need handling.
  """
  @spec rebuild_from_events(term()) :: {:ok, recovered_state()} | {:error, term()}
  def rebuild_from_events(event_log_config) do
    case event_log_config do
      nil ->
        {:ok, empty_state()}

      {module, opts} ->
        stream_id = Config.event_stream()

        case module.read_stream(stream_id, opts) do
          {:ok, events} ->
            state = replay_events(events)
            {:ok, state}

          {:error, :stream_not_found} ->
            {:ok, empty_state()}

          {:error, reason} = error ->
            Logger.error("StateRecovery: failed to read events: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Apply a single event to the state accumulator.

  Used during replay and can be used for live event processing.
  """
  @spec apply_event(map(), recovered_state()) :: recovered_state()
  def apply_event(event, state) do
    case Events.from_persistence_event(event) do
      {:ok, domain_event} ->
        do_apply_event(domain_event, state)

      {:error, {:unknown_event_type, type}} ->
        Logger.warning("StateRecovery: skipping unknown event type: #{type}")
        state
    end
  end

  @doc """
  Detect interrupted evaluations from recovered state.

  An evaluation is interrupted if:
  - EvaluationStarted was emitted
  - No DecisionRendered or ProposalDeadlocked followed
  """
  @spec detect_interrupted(recovered_state()) :: [map()]
  def detect_interrupted(state) do
    state.proposals
    |> Enum.filter(fn {_id, proposal} -> proposal.status == :evaluating end)
    |> Enum.map(fn {id, proposal} ->
      completed = Map.keys(proposal.completed_evaluations)
      missing = proposal.perspectives -- completed

      %{
        proposal_id: id,
        perspectives: proposal.perspectives,
        completed_perspectives: completed,
        missing_perspectives: missing,
        completed_evaluations: proposal.completed_evaluations
      }
    end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp empty_state do
    %{
      proposals: %{},
      decisions: %{},
      interrupted: [],
      last_position: 0,
      events_replayed: 0
    }
  end

  defp replay_events(events) do
    initial_state = empty_state()

    state =
      Enum.reduce(events, initial_state, fn event, acc ->
        position = Map.get(event, :global_position) || Map.get(event, :position, 0)

        apply_event(event, acc)
        |> Map.update!(:events_replayed, &(&1 + 1))
        |> Map.put(:last_position, position || acc.last_position)
      end)

    # Detect interrupted evaluations after full replay
    interrupted = detect_interrupted(state)
    %{state | interrupted: interrupted}
  end

  # Coordinator lifecycle events

  defp do_apply_event(%Events.CoordinatorStarted{} = _event, state) do
    # Coordinator start doesn't affect proposal state
    state
  end

  defp do_apply_event(%Events.RecoveryStarted{} = _event, state) do
    state
  end

  defp do_apply_event(%Events.RecoveryCompleted{} = _event, state) do
    state
  end

  # Proposal lifecycle events

  defp do_apply_event(%Events.ProposalSubmitted{} = event, state) do
    proposal = %{
      id: event.proposal_id,
      proposer: event.proposer,
      change_type: event.change_type,
      description: event.description,
      target_layer: event.target_layer,
      target_module: event.target_module,
      metadata: event.metadata,
      status: :submitted,
      submitted_at: event.timestamp,
      perspectives: [],
      completed_evaluations: %{},
      decision: nil
    }

    put_in(state, [:proposals, event.proposal_id], proposal)
  end

  defp do_apply_event(%Events.EvaluationStarted{} = event, state) do
    update_proposal(state, event.proposal_id, fn proposal ->
      %{proposal | status: :evaluating, perspectives: event.perspectives}
    end)
  end

  defp do_apply_event(%Events.EvaluationCompleted{} = event, state) do
    evaluation = %{
      id: event.evaluation_id,
      perspective: event.perspective,
      vote: event.vote,
      confidence: event.confidence,
      risk_score: event.risk_score,
      benefit_score: event.benefit_score,
      concerns: event.concerns,
      recommendations: event.recommendations,
      reasoning: event.reasoning,
      timestamp: event.timestamp
    }

    update_proposal(state, event.proposal_id, fn proposal ->
      completed = Map.put(proposal.completed_evaluations, event.perspective, evaluation)
      %{proposal | completed_evaluations: completed}
    end)
  end

  defp do_apply_event(%Events.EvaluationFailed{} = event, state) do
    # Track failed evaluation as completed (with error marker)
    failed_eval = %{
      perspective: event.perspective,
      vote: :error,
      reason: event.reason,
      timestamp: event.timestamp
    }

    update_proposal(state, event.proposal_id, fn proposal ->
      completed = Map.put(proposal.completed_evaluations, event.perspective, failed_eval)
      %{proposal | completed_evaluations: completed}
    end)
  end

  # Decision lifecycle events

  defp do_apply_event(%Events.DecisionRendered{} = event, state) do
    decision = %{
      id: event.decision_id,
      proposal_id: event.proposal_id,
      decision: event.decision,
      approve_count: event.approve_count,
      reject_count: event.reject_count,
      abstain_count: event.abstain_count,
      required_quorum: event.required_quorum,
      quorum_met: event.quorum_met,
      primary_concerns: event.primary_concerns,
      average_confidence: event.average_confidence,
      timestamp: event.timestamp
    }

    state
    |> put_in([:decisions, event.proposal_id], decision)
    |> update_proposal(event.proposal_id, fn proposal ->
      %{proposal | status: :decided, decision: decision}
    end)
  end

  defp do_apply_event(%Events.ProposalExecuted{} = event, state) do
    update_proposal(state, event.proposal_id, fn proposal ->
      %{proposal | status: :executed}
    end)
  end

  defp do_apply_event(%Events.ProposalDeadlocked{} = event, state) do
    update_proposal(state, event.proposal_id, fn proposal ->
      %{proposal | status: :deadlocked}
    end)
  end

  # Helper to update a proposal if it exists

  defp update_proposal(state, proposal_id, update_fn) do
    case get_in(state, [:proposals, proposal_id]) do
      nil ->
        Logger.warning("StateRecovery: event for unknown proposal #{proposal_id}")
        state

      proposal ->
        put_in(state, [:proposals, proposal_id], update_fn.(proposal))
    end
  end
end
