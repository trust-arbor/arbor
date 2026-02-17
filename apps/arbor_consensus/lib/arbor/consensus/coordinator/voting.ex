defmodule Arbor.Consensus.Coordinator.Voting do
  @moduledoc """
  Voting and evaluation logic for the Coordinator.

  Handles processing evaluations, rendering decisions, applying decisions,
  execution of approved proposals, and agent-based evaluation collection.
  """

  alias Arbor.Consensus.{Config, Council, EvaluatorAgent, EventEmitter, EventStore}
  alias Arbor.Consensus.Coordinator.TopicRouting
  alias Arbor.Contracts.Consensus.{ConsensusEvent, CouncilDecision, Proposal}
  alias Arbor.Signals

  require Logger

  # ============================================================================
  # Council Spawning
  # ============================================================================

  @doc """
  Spawn a council to evaluate a proposal. Tries agent delivery first,
  falls back to direct council spawning.
  """
  def spawn_council(state, proposal, evaluators, quorum) do
    perspectives = resolve_perspectives_from_evaluators(evaluators)

    case resolve_evaluator_agents(perspectives) do
      {:ok, agent_mapping} when map_size(agent_mapping) > 0 ->
        deliver_to_agents(state, proposal, agent_mapping, evaluators, quorum)

      _ ->
        # Direct path: spawn temporary council tasks
        spawn_council_direct(state, proposal, evaluators, quorum)
    end
  end

  @doc """
  Spawn council for specific perspectives (used for recovery resume).
  """
  def spawn_council_for_perspectives(state, proposal, missing_perspectives) do
    config = state.config

    # Resolve evaluators and quorum from TopicRegistry
    {evaluators, _full_quorum} =
      TopicRouting.resolve_council_config(proposal, state.config)

    # Build evaluator map and filter to only missing perspectives
    evaluator_map = Council.build_evaluator_map(evaluators)

    filtered_evaluator_map =
      evaluator_map
      |> Enum.filter(fn {perspective, _} -> perspective in missing_perspectives end)
      |> Map.new()

    # Calculate quorum for the missing perspectives
    quorum =
      if proposal.mode == :advisory do
        nil
      else
        alias Arbor.Consensus.{TopicRegistry, TopicRule}

        case TopicRegistry.get(proposal.topic) do
          {:ok, rule} ->
            TopicRule.quorum_to_number(rule.min_quorum, length(missing_perspectives))

          _ ->
            Arbor.Contracts.Consensus.Protocol.standard_quorum()
        end
      end

    task =
      Task.async(fn ->
        result =
          Council.evaluate(proposal, filtered_evaluator_map,
            timeout: config.evaluation_timeout_ms,
            quorum: quorum
          )

        {:council_result, proposal.id, result}
      end)

    %{state | active_councils: Map.put(state.active_councils, proposal.id, task)}
  end

  # Direct council spawning: temporary tasks for each perspective
  defp spawn_council_direct(state, proposal, evaluators, quorum) do
    config = state.config

    task =
      Task.async(fn ->
        result =
          Council.evaluate(proposal, evaluators,
            timeout: config.evaluation_timeout_ms,
            quorum: quorum
          )

        {:council_result, proposal.id, result}
      end)

    %{state | active_councils: Map.put(state.active_councils, proposal.id, task)}
  end

  # Deliver proposal to persistent evaluator agents
  defp deliver_to_agents(state, proposal, agent_mapping, evaluators, quorum) do
    config = state.config
    deadline = DateTime.add(DateTime.utc_now(), config.evaluation_timeout_ms, :millisecond)

    # Determine priority based on topic (governance gets high priority)
    priority = if proposal.topic == :topic_governance, do: :high, else: :normal

    # Deliver to each agent's mailbox
    delivered =
      Enum.reduce_while(agent_mapping, [], fn {evaluator_name, {pid, perspectives}}, acc ->
        envelope = %{
          proposal: proposal,
          perspectives: perspectives,
          reply_to: self(),
          deadline: deadline,
          priority: priority
        }

        case EvaluatorAgent.deliver(pid, envelope, priority) do
          :ok ->
            {:cont, [evaluator_name | acc]}

          {:error, :mailbox_full} ->
            Logger.warning(
              "EvaluatorAgent #{evaluator_name} mailbox full for proposal #{proposal.id}"
            )

            # Continue with other agents
            {:cont, acc}
        end
      end)

    if delivered == [] do
      # No agents accepted the delivery, fall back to direct council
      Logger.warning("No agents accepted proposal #{proposal.id}, falling back to direct council")

      spawn_council_direct(state, proposal, evaluators, quorum)
    else
      # Track pending evaluations
      pending_entry = %{
        quorum: quorum,
        mode: proposal.mode,
        collected: [],
        pending_evaluators: delivered,
        started_at: DateTime.utc_now()
      }

      %{
        state
        | pending_evaluations: Map.put(state.pending_evaluations, proposal.id, pending_entry)
      }
    end
  end

  # Resolve which evaluator agents are available for the given perspectives
  defp resolve_evaluator_agents(perspectives) do
    alias Arbor.Consensus.EvaluatorAgent.Supervisor, as: AgentSupervisor

    try do
      agents = AgentSupervisor.list_agents()

      # Build a mapping: evaluator_name => {pid, [perspectives it can handle]}
      agent_mapping =
        agents
        |> Enum.reduce(%{}, fn {name, pid, status}, acc ->
          agent_perspectives = status.perspectives
          # Find which requested perspectives this agent can handle
          matching = Enum.filter(perspectives, &(&1 in agent_perspectives))

          if matching != [] do
            Map.put(acc, name, {pid, matching})
          else
            acc
          end
        end)

      {:ok, agent_mapping}
    rescue
      _ -> {:error, :no_agents}
    end
  end

  # ============================================================================
  # Evaluation Processing
  # ============================================================================

  @doc """
  Process evaluations for a proposal and render a decision.
  """
  def process_evaluations(state, proposal_id, evaluations, quorum) do
    case Map.get(state.proposals, proposal_id) do
      nil ->
        Logger.warning("Received evaluations for unknown proposal #{proposal_id}")
        state

      proposal ->
        record_evaluation_events(state, proposal_id, evaluations)
        render_and_apply_decision(state, proposal_id, proposal, evaluations, quorum)
    end
  end

  @doc """
  Collect an evaluation from a persistent agent.
  """
  def collect_agent_evaluation(state, proposal_id, evaluation) do
    case Map.get(state.pending_evaluations, proposal_id) do
      nil ->
        # Not tracking this proposal via agents (might be direct path)
        Logger.debug("Received agent evaluation for untracked proposal #{proposal_id}")
        state

      pending ->
        # Add to collected evaluations
        new_collected = [evaluation | pending.collected]
        new_pending = %{pending | collected: new_collected}

        state = %{
          state
          | pending_evaluations: Map.put(state.pending_evaluations, proposal_id, new_pending)
        }

        # Emit evaluation event
        EventEmitter.evaluation_completed(evaluation)

        record_event(state, :evaluation_submitted, %{
          proposal_id: proposal_id,
          evaluator_id: evaluation.evaluator_id,
          vote: evaluation.vote,
          perspective: evaluation.perspective,
          confidence: evaluation.confidence
        })

        # Check if we should finalize (quorum reached or all evaluators done)
        check_agent_evaluation_completion(state, proposal_id, new_pending)
    end
  end

  @doc """
  Remove a failed evaluator from pending list.
  """
  def remove_pending_evaluator(state, proposal_id, evaluator_name) do
    case Map.get(state.pending_evaluations, proposal_id) do
      nil ->
        state

      pending ->
        new_pending_evaluators = List.delete(pending.pending_evaluators, evaluator_name)
        new_pending = %{pending | pending_evaluators: new_pending_evaluators}

        state = %{
          state
          | pending_evaluations: Map.put(state.pending_evaluations, proposal_id, new_pending)
        }

        # Check if we should finalize (all remaining evaluators done)
        check_agent_evaluation_completion(state, proposal_id, new_pending)
    end
  end

  @doc """
  Resolve perspectives from evaluator modules.
  Calls evaluator.perspectives() for each module and flattens the results.
  Falls back to Protocol defaults if no valid perspectives are returned.
  """
  def resolve_perspectives_from_evaluators(evaluators) do
    perspectives =
      evaluators
      |> Enum.flat_map(fn evaluator ->
        try do
          if function_exported?(evaluator, :perspectives, 0) do
            evaluator.perspectives()
          else
            []
          end
        rescue
          _ -> []
        end
      end)
      |> Enum.uniq()

    if perspectives == [] do
      Arbor.Contracts.Consensus.Protocol.perspectives() -- [:human]
    else
      perspectives
    end
  end

  # ============================================================================
  # Decision Rendering & Application
  # ============================================================================

  @doc """
  Maybe execute an approved proposal if auto-execution is configured.
  """
  def maybe_execute(state, %{status: :approved} = proposal, decision) do
    if state.config.auto_execute_approved && state.executor do
      case maybe_authorize_execution(state.authorizer, proposal, decision) do
        :ok ->
          execute_proposal(state, proposal, decision)

        {:error, reason} ->
          Logger.warning("Execution authorization denied for #{proposal.id}: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  def maybe_execute(state, _proposal, _decision), do: state

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Check if agent evaluations are complete
  defp check_agent_evaluation_completion(state, proposal_id, pending) do
    quorum = pending.quorum

    # For advisory mode (quorum is nil), wait for all evaluators
    # For decision mode, we can terminate early once quorum is reached
    should_finalize =
      cond do
        # All evaluators have responded (or failed)
        pending.pending_evaluators == [] ->
          true

        # Decision mode: check if quorum is reached
        quorum != nil ->
          approve_count = Enum.count(pending.collected, &(&1.vote == :approve))
          reject_count = Enum.count(pending.collected, &(&1.vote == :reject))
          remaining = length(pending.pending_evaluators)

          # Quorum reached for approval or rejection
          # Can't reach quorum even with all remaining approvals
          approve_count >= quorum or
            reject_count >= quorum or
            (approve_count + remaining < quorum and reject_count + remaining < quorum)

        # Advisory mode: wait for all
        true ->
          false
      end

    if should_finalize do
      finalize_agent_evaluations(state, proposal_id, pending)
    else
      state
    end
  end

  # Finalize agent evaluations and render decision
  defp finalize_agent_evaluations(state, proposal_id, pending) do
    evaluations = Enum.reverse(pending.collected)

    record_event(state, :council_complete, %{
      proposal_id: proposal_id,
      data: %{evaluation_count: length(evaluations)}
    })

    # Clean up pending tracking
    state = %{state | pending_evaluations: Map.delete(state.pending_evaluations, proposal_id)}

    # Process evaluations with topic-specific quorum
    process_evaluations(state, proposal_id, evaluations, pending.quorum)
  end

  defp record_evaluation_events(state, proposal_id, evaluations) do
    Enum.each(evaluations, fn eval ->
      # Emit to durable event log
      EventEmitter.evaluation_completed(eval)

      # Record to in-memory event store
      record_event(state, :evaluation_submitted, %{
        proposal_id: proposal_id,
        evaluator_id: eval.evaluator_id,
        vote: eval.vote,
        perspective: eval.perspective,
        confidence: eval.confidence
      })
    end)

    record_event(state, :council_complete, %{
      proposal_id: proposal_id,
      data: %{evaluation_count: length(evaluations)}
    })
  end

  defp render_and_apply_decision(state, proposal_id, proposal, evaluations, quorum) do
    opts = if quorum, do: [quorum: quorum], else: []

    case CouncilDecision.from_evaluations(proposal, evaluations, opts) do
      {:ok, decision} ->
        apply_decision(state, proposal_id, proposal, decision)

      {:error, reason} ->
        Logger.error("Failed to render decision for #{proposal_id}: #{inspect(reason)}")
        update_proposal_status(state, proposal_id, :deadlock)
    end
  end

  defp apply_decision(state, proposal_id, proposal, decision) do
    proposal = Proposal.update_status(proposal, decision.decision)

    state = %{
      state
      | proposals: Map.put(state.proposals, proposal_id, proposal),
        decisions: Map.put(state.decisions, proposal_id, decision),
        proposals_by_agent: remove_proposal_from_agent(state.proposals_by_agent, proposal)
    }

    # Emit to durable event log - differentiate between advisory and decision mode
    if proposal.mode == :advisory do
      EventEmitter.advice_rendered(decision, proposal)
    else
      EventEmitter.decision_rendered(decision)
    end

    # Record to in-memory event store
    event_type = if proposal.mode == :advisory, do: :advice_rendered, else: :decision_reached

    record_event(state, event_type, %{
      proposal_id: proposal_id,
      decision_id: decision.id,
      decision: decision.decision,
      approve_count: decision.approve_count,
      reject_count: decision.reject_count,
      abstain_count: decision.abstain_count,
      data: %{
        mode: proposal.mode,
        quorum_met: decision.quorum_met,
        average_confidence: decision.average_confidence
      }
    })

    # Notify any waiters (Phase 2: Tier 1 notification)
    state = notify_waiters(state, proposal_id, decision)

    maybe_execute(state, proposal, decision)
  end

  defp maybe_authorize_execution(nil, _proposal, _decision), do: :ok
  defp maybe_authorize_execution(_authorizer, _proposal, nil), do: :ok

  defp maybe_authorize_execution(authorizer, proposal, decision) do
    authorizer.authorize_execution(proposal, decision)
  end

  defp execute_proposal(state, proposal, decision) do
    record_event(state, :execution_started, %{
      proposal_id: proposal.id
    })

    case state.executor.execute(proposal, decision) do
      {:ok, result} ->
        # Emit to durable event log
        EventEmitter.proposal_executed(proposal.id, :success, result)

        record_event(state, :execution_succeeded, %{
          proposal_id: proposal.id
        })

        state

      {:error, reason} ->
        Logger.error("Execution failed for #{proposal.id}: #{inspect(reason)}")

        # Emit to durable event log
        EventEmitter.proposal_executed(proposal.id, :failed, inspect(reason))

        # Emit signal for real-time observability
        emit_coordinator_error(proposal.id, reason)

        record_event(state, :execution_failed, %{
          proposal_id: proposal.id,
          data: %{error: inspect(reason)}
        })

        state
    end
  end

  defp update_proposal_status(state, proposal_id, status) do
    case Map.get(state.proposals, proposal_id) do
      nil ->
        state

      proposal ->
        proposal = Proposal.update_status(proposal, status)
        state = %{state | proposals: Map.put(state.proposals, proposal_id, proposal)}

        # Free quota on terminal statuses
        if status in [:approved, :rejected, :vetoed, :deadlock] do
          %{
            state
            | proposals_by_agent: remove_proposal_from_agent(state.proposals_by_agent, proposal)
          }
        else
          state
        end
    end
  end

  defp remove_proposal_from_agent(proposals_by_agent, proposal) do
    case Map.get(proposals_by_agent, proposal.proposer) do
      nil ->
        proposals_by_agent

      ids ->
        new_ids = List.delete(ids, proposal.id)

        if new_ids == [] do
          Map.delete(proposals_by_agent, proposal.proposer)
        else
          Map.put(proposals_by_agent, proposal.proposer, new_ids)
        end
    end
  end

  # Waiter notification (called from apply_decision)
  defp notify_waiters(state, proposal_id, decision) do
    case Map.get(state.waiters, proposal_id) do
      nil ->
        state

      waiters ->
        # Send result to all waiters and demonitor them
        Enum.each(waiters, fn {pid, ref} ->
          Process.demonitor(ref, [:flush])
          send(pid, {:consensus_result, proposal_id, decision})
        end)

        # Remove all waiters for this proposal
        %{state | waiters: Map.delete(state.waiters, proposal_id)}
    end
  end

  # Event recording (shared helper)
  defp record_event(state, event_type, attrs) do
    event_attrs =
      Map.merge(attrs, %{event_type: event_type})

    case ConsensusEvent.new(event_attrs) do
      {:ok, event} ->
        store_event(event)
        maybe_forward_to_sink(state.event_sink, event)

      {:error, reason} ->
        Logger.warning("Failed to create consensus event: #{inspect(reason)}")
    end
  end

  defp store_event(event) do
    if Config.event_store_enabled?() do
      EventStore.append(event)
    end
  rescue
    _ -> :ok
  end

  defp maybe_forward_to_sink(nil, _event), do: :ok

  defp maybe_forward_to_sink(event_sink, event) do
    Task.start(fn ->
      event_sink.record(event)
    end)
  end

  defp emit_coordinator_error(proposal_id, reason) do
    Signals.emit(:consensus, :coordinator_error, %{
      proposal_id: proposal_id,
      reason: truncate_reason(reason)
    })
  end

  defp truncate_reason(reason) do
    inspected = inspect(reason)

    if String.length(inspected) > 200 do
      String.slice(inspected, 0, 197) <> "..."
    else
      inspected
    end
  end
end
