defmodule Arbor.Consensus.Coordinator do
  @moduledoc """
  Central GenServer orchestrating the proposal lifecycle.

  Manages proposals from submission through evaluation to decision.
  Delegates evaluation to Council, uses pluggable behaviours for
  authorization, execution, and event sinking.

  ## Lifecycle

      submit → validate → authorize → spawn council → collect evaluations
           → render decision → (optional) execute → record events

  ## State

  Tracks active proposals, decisions, council tasks, and duplicate
  fingerprints for deduplication.
  """

  use GenServer

  alias Arbor.Consensus.{Config, Council, EvaluatorAgent, EventEmitter, EventStore, StateRecovery}
  alias Arbor.Consensus.{TopicMatcher, TopicRegistry, TopicRule}
  alias Arbor.Contracts.Consensus.{ConsensusEvent, CouncilDecision, Proposal}
  alias Arbor.Signals

  require Logger

  defstruct [
    :coordinator_id,
    :config,
    :evaluator_backend,
    :authorizer,
    :executor,
    :event_sink,
    proposals: %{},
    decisions: %{},
    active_councils: %{},
    pending_fingerprints: %{},
    proposals_by_agent: %{},
    last_event_position: 0,
    # Waiter support for await/2 (Phase 2)
    waiters: %{},
    # Track pending evaluations from persistent agents
    # Map of proposal_id => %{quorum: n, mode: atom, collected: [Evaluation.t()], pending_evaluators: [atom()]}
    pending_evaluations: %{},
    # Phase 5: Routing stats for organic topic creation
    # Map of keyword_group => %{count: N, last_seen: DateTime, descriptions: [String.t()]}
    routing_stats: %{},
    general_route_count: 0
  ]

  @type t :: %__MODULE__{
          coordinator_id: String.t(),
          config: Config.t(),
          evaluator_backend: module(),
          authorizer: module() | nil,
          executor: module() | nil,
          event_sink: module() | nil,
          proposals: map(),
          decisions: map(),
          active_councils: map(),
          pending_fingerprints: map(),
          proposals_by_agent: %{String.t() => [String.t()]},
          last_event_position: non_neg_integer(),
          # Map of proposal_id => [{pid, monitor_ref}]
          waiters: %{String.t() => [{pid(), reference()}]},
          # Pending evaluations from persistent agents
          pending_evaluations: map(),
          # Phase 5: Routing stats for organic topic creation
          routing_stats: map(),
          general_route_count: non_neg_integer()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the coordinator.

  ## Options

    * `:config` - `Config.t()` or keyword opts for `Config.new/1`
    * `:evaluator_backend` - Module implementing `EvaluatorBackend` behaviour
    * `:authorizer` - Module implementing `Authorizer` behaviour (optional)
    * `:executor` - Module implementing `Executor` behaviour (optional)
    * `:event_sink` - Module implementing `EventSink` behaviour (optional)
    * `:name` - GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit a proposal for consensus evaluation.
  """
  @spec submit(map() | Proposal.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def submit(proposal_or_attrs, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:submit, proposal_or_attrs, opts})
  end

  @doc """
  Get the current status of a proposal.
  """
  @spec get_status(String.t(), GenServer.server()) ::
          {:ok, Proposal.status()} | {:error, :not_found}
  def get_status(proposal_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_status, proposal_id})
  end

  @doc """
  Get the decision for a proposal.
  """
  @spec get_decision(String.t(), GenServer.server()) ::
          {:ok, CouncilDecision.t()} | {:error, :not_found | :not_decided}
  def get_decision(proposal_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_decision, proposal_id})
  end

  @doc """
  Get a proposal by ID.
  """
  @spec get_proposal(String.t(), GenServer.server()) ::
          {:ok, Proposal.t()} | {:error, :not_found}
  def get_proposal(proposal_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_proposal, proposal_id})
  end

  @doc """
  List all pending proposals.
  """
  @spec list_pending(GenServer.server()) :: [Proposal.t()]
  def list_pending(server \\ __MODULE__) do
    GenServer.call(server, :list_pending)
  end

  @doc """
  List all proposals.
  """
  @spec list_proposals(GenServer.server()) :: [Proposal.t()]
  def list_proposals(server \\ __MODULE__) do
    GenServer.call(server, :list_proposals)
  end

  @doc """
  List all decisions.
  """
  @spec list_decisions(GenServer.server()) :: [CouncilDecision.t()]
  def list_decisions(server \\ __MODULE__) do
    GenServer.call(server, :list_decisions)
  end

  @doc """
  Get recent decisions (most recent first).
  """
  @spec recent_decisions(pos_integer(), GenServer.server()) :: [CouncilDecision.t()]
  def recent_decisions(limit \\ 10, server \\ __MODULE__) do
    GenServer.call(server, {:recent_decisions, limit})
  end

  @doc """
  Cancel a pending proposal.
  """
  @spec cancel(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def cancel(proposal_id, server \\ __MODULE__) do
    GenServer.call(server, {:cancel, proposal_id})
  end

  @doc """
  Force-approve a proposal (human override).
  """
  @spec force_approve(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def force_approve(proposal_id, approver_id, server \\ __MODULE__) do
    GenServer.call(server, {:force_approve, proposal_id, approver_id})
  end

  @doc """
  Force-reject a proposal (human override).
  """
  @spec force_reject(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def force_reject(proposal_id, rejector_id, server \\ __MODULE__) do
    GenServer.call(server, {:force_reject, proposal_id, rejector_id})
  end

  @doc """
  Get coordinator statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @doc """
  Wait for a proposal's result.

  Registers as a waiter in the Coordinator and receives the result
  via direct message. No polling required.

  ## Options

    * `:timeout` - Maximum wait time in ms (default: 30_000)
    * `:server` - Coordinator server (default: `__MODULE__`)

  ## Returns

    * `{:ok, decision}` - The decision was rendered
    * `{:error, :not_found}` - Proposal doesn't exist
    * `{:error, :timeout}` - Timed out waiting for decision
    * `{:error, :coordinator_down}` - Coordinator crashed while waiting
  """
  @spec await(String.t(), keyword()) :: {:ok, CouncilDecision.t()} | {:error, term()}
  def await(proposal_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 30_000)

    # Monitor the coordinator so we know if it crashes
    coord_ref = Process.monitor(server)

    case GenServer.call(server, {:register_waiter, proposal_id, self()}) do
      {:ok, :already_decided, decision} ->
        # Decision already exists, return immediately
        Process.demonitor(coord_ref, [:flush])
        {:ok, decision}

      {:ok, :registered} ->
        # Wait for the result or timeout
        receive do
          {:consensus_result, ^proposal_id, result} ->
            Process.demonitor(coord_ref, [:flush])
            {:ok, result}

          {:DOWN, ^coord_ref, :process, _pid, _reason} ->
            {:error, :coordinator_down}
        after
          timeout ->
            # Clean up our registration
            GenServer.cast(server, {:unregister_waiter, proposal_id, self()})
            Process.demonitor(coord_ref, [:flush])
            {:error, :timeout}
        end

      {:error, _} = error ->
        Process.demonitor(coord_ref, [:flush])
        error
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    config =
      case Keyword.get(opts, :config) do
        %Config{} = c -> c
        kw when is_list(kw) -> Config.new(kw)
        nil -> Config.new()
      end

    coordinator_id = generate_coordinator_id()

    state = %__MODULE__{
      coordinator_id: coordinator_id,
      config: config,
      evaluator_backend:
        Keyword.get(
          opts,
          :evaluator_backend,
          Arbor.Consensus.EvaluatorBackend.RuleBased
        ),
      authorizer: Keyword.get(opts, :authorizer),
      executor: Keyword.get(opts, :executor),
      event_sink: Keyword.get(opts, :event_sink)
    }

    # Attempt recovery from persisted events
    state = recover_from_events(state)

    # Emit startup event
    emit_coordinator_started(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, proposal_or_attrs, opts}, _from, state) do
    with {:ok, proposal} <- resolve_proposal(proposal_or_attrs),
         {:ok, proposal} <- maybe_route_via_topic_matcher(proposal),
         :ok <- check_capacity(state),
         :ok <- check_duplicate_unless_advisory(state, proposal),
         :ok <- check_invariants(proposal),
         :ok <- check_agent_quota_unless_advisory(state, proposal),
         :ok <- maybe_authorize(state.authorizer, proposal) do
      # Register proposal
      proposal = Proposal.update_status(proposal, :evaluating)
      fingerprint = compute_fingerprint(proposal)

      # Phase 5: Track routing stats for organic topic creation
      state = track_routing_stats(state, proposal)

      state = %{
        state
        | proposals: Map.put(state.proposals, proposal.id, proposal),
          pending_fingerprints: Map.put(state.pending_fingerprints, fingerprint, proposal.id),
          proposals_by_agent: add_proposal_to_agent(state.proposals_by_agent, proposal)
      }

      # Emit proposal submitted event (durable event log)
      EventEmitter.proposal_submitted(proposal)

      # Record submission event (in-memory event store)
      record_event(state, :proposal_submitted, %{
        proposal_id: proposal.id,
        agent_id: proposal.proposer,
        data: %{
          topic: proposal.topic,
          description: proposal.description
        }
      })

      # Get council configuration from TopicRegistry
      {perspectives, quorum} = resolve_council_config(proposal, state.config)

      # Spawn council asynchronously
      evaluator_backend = Keyword.get(opts, :evaluator_backend, state.evaluator_backend)

      # Emit evaluation started event
      EventEmitter.evaluation_started(
        proposal.id,
        perspectives,
        length(perspectives),
        quorum
      )

      state = spawn_council(state, proposal, evaluator_backend, perspectives, quorum)

      {:reply, {:ok, proposal.id}, state}
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_status, proposal_id}, _from, state) do
    case Map.get(state.proposals, proposal_id) do
      nil -> {:reply, {:error, :not_found}, state}
      proposal -> {:reply, {:ok, proposal.status}, state}
    end
  end

  @impl true
  def handle_call({:get_decision, proposal_id}, _from, state) do
    case Map.get(state.decisions, proposal_id) do
      nil ->
        if Map.has_key?(state.proposals, proposal_id) do
          {:reply, {:error, :not_decided}, state}
        else
          {:reply, {:error, :not_found}, state}
        end

      decision ->
        {:reply, {:ok, decision}, state}
    end
  end

  @impl true
  def handle_call({:get_proposal, proposal_id}, _from, state) do
    case Map.get(state.proposals, proposal_id) do
      nil -> {:reply, {:error, :not_found}, state}
      proposal -> {:reply, {:ok, proposal}, state}
    end
  end

  @impl true
  def handle_call(:list_pending, _from, state) do
    pending =
      state.proposals
      |> Map.values()
      |> Enum.filter(&(&1.status in [:pending, :evaluating]))

    {:reply, pending, state}
  end

  @impl true
  def handle_call(:list_proposals, _from, state) do
    {:reply, Map.values(state.proposals), state}
  end

  @impl true
  def handle_call(:list_decisions, _from, state) do
    {:reply, Map.values(state.decisions), state}
  end

  @impl true
  def handle_call({:recent_decisions, limit}, _from, state) do
    recent =
      state.decisions
      |> Map.values()
      |> Enum.sort_by(& &1.decided_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, recent, state}
  end

  @impl true
  def handle_call({:cancel, proposal_id}, _from, state) do
    case Map.get(state.proposals, proposal_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status in [:approved, :rejected] ->
        {:reply, {:error, :already_decided}, state}

      proposal ->
        # Kill active council if running
        state = kill_active_council(state, proposal_id)

        proposal = Proposal.update_status(proposal, :vetoed)

        state = %{
          state
          | proposals: Map.put(state.proposals, proposal_id, proposal),
            proposals_by_agent: remove_proposal_from_agent(state.proposals_by_agent, proposal)
        }

        record_event(state, :proposal_cancelled, %{
          proposal_id: proposal_id,
          agent_id: proposal.proposer
        })

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:force_approve, proposal_id, approver_id}, _from, state) do
    case Map.get(state.proposals, proposal_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      proposal ->
        state = kill_active_council(state, proposal_id)
        proposal = Proposal.update_status(proposal, :approved)

        state = %{
          state
          | proposals: Map.put(state.proposals, proposal_id, proposal),
            proposals_by_agent: remove_proposal_from_agent(state.proposals_by_agent, proposal)
        }

        record_event(state, :decision_reached, %{
          proposal_id: proposal_id,
          agent_id: approver_id,
          decision: :approved,
          data: %{override: true, approver: approver_id}
        })

        # Execute if configured
        state = maybe_execute(state, proposal, nil)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:force_reject, proposal_id, rejector_id}, _from, state) do
    case Map.get(state.proposals, proposal_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      proposal ->
        state = kill_active_council(state, proposal_id)
        proposal = Proposal.update_status(proposal, :rejected)

        state = %{
          state
          | proposals: Map.put(state.proposals, proposal_id, proposal),
            proposals_by_agent: remove_proposal_from_agent(state.proposals_by_agent, proposal)
        }

        record_event(state, :decision_reached, %{
          proposal_id: proposal_id,
          agent_id: rejector_id,
          decision: :rejected,
          data: %{override: true, rejector: rejector_id}
        })

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_proposals: map_size(state.proposals),
      total_decisions: map_size(state.decisions),
      active_councils: map_size(state.active_councils),
      pending:
        state.proposals |> Map.values() |> Enum.count(&(&1.status in [:pending, :evaluating])),
      approved: state.proposals |> Map.values() |> Enum.count(&(&1.status == :approved)),
      rejected: state.proposals |> Map.values() |> Enum.count(&(&1.status == :rejected)),
      deadlocked: state.proposals |> Map.values() |> Enum.count(&(&1.status == :deadlock)),
      evaluator_backend: state.evaluator_backend,
      config: %{
        max_concurrent: state.config.max_concurrent_proposals,
        auto_execute: state.config.auto_execute_approved
      },
      # Quota stats (Phase 7)
      max_proposals_per_agent: Config.max_proposals_per_agent(),
      agents_with_proposals: map_size(state.proposals_by_agent),
      proposal_quota_enabled: Config.proposal_quota_enabled?(),
      # Phase 5: Routing stats
      tracked_patterns: map_size(state.routing_stats),
      general_route_count: state.general_route_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:register_waiter, proposal_id, pid}, _from, state) do
    # Check if proposal exists
    case Map.get(state.proposals, proposal_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _proposal ->
        # Check if decision already exists
        case Map.get(state.decisions, proposal_id) do
          nil ->
            # Register the waiter and monitor it
            state = register_waiter(state, proposal_id, pid)
            {:reply, {:ok, :registered}, state}

          decision ->
            # Already decided, return immediately
            {:reply, {:ok, :already_decided, decision}, state}
        end
    end
  end

  @impl true
  def handle_cast({:unregister_waiter, proposal_id, pid}, state) do
    state = unregister_waiter(state, proposal_id, pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {:council_result, proposal_id, result}}, state) when is_reference(ref) do
    # Demonitor the task
    Process.demonitor(ref, [:flush])

    state = %{state | active_councils: Map.delete(state.active_councils, proposal_id)}

    case result do
      {:ok, evaluations} ->
        state = process_evaluations(state, proposal_id, evaluations)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Council failed for proposal #{proposal_id}: #{inspect(reason)}")

        state = update_proposal_status(state, proposal_id, :deadlock)

        # Emit to durable event log
        EventEmitter.proposal_deadlocked(proposal_id, :council_failed, inspect(reason))

        # Emit signal for real-time observability
        emit_coordinator_error(proposal_id, reason)

        record_event(state, :proposal_timeout, %{
          proposal_id: proposal_id,
          data: %{reason: inspect(reason)}
        })

        {:noreply, state}
    end
  end

  # Handle evaluation completion from persistent agents
  @impl true
  def handle_info({:evaluation_complete, proposal_id, evaluation}, state) do
    state = collect_agent_evaluation(state, proposal_id, evaluation)
    {:noreply, state}
  end

  # Handle evaluation failure from persistent agents
  @impl true
  def handle_info({:evaluation_failed, proposal_id, evaluator_name, reason}, state) do
    Logger.warning(
      "EvaluatorAgent #{evaluator_name} failed for proposal #{proposal_id}: #{inspect(reason)}"
    )

    # Remove evaluator from pending list (treat as abstention)
    state = remove_pending_evaluator(state, proposal_id, evaluator_name)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Could be a task monitor OR a waiter monitor
    # Clean up dead waiters
    state = cleanup_waiter_by_ref(state, ref, pid)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp resolve_proposal(%Proposal{} = proposal), do: {:ok, proposal}

  defp resolve_proposal(attrs) when is_map(attrs) do
    Proposal.new(attrs)
  end

  defp check_capacity(state) do
    # Count both direct active councils and pending agent evaluations
    active = map_size(state.active_councils) + map_size(state.pending_evaluations)

    if active < state.config.max_concurrent_proposals do
      :ok
    else
      {:error, :at_capacity}
    end
  end

  defp check_duplicate(state, proposal) do
    fingerprint = compute_fingerprint(proposal)

    if Map.has_key?(state.pending_fingerprints, fingerprint) do
      {:error, :duplicate_proposal}
    else
      :ok
    end
  end

  defp check_invariants(proposal) do
    case Proposal.violates_invariants?(proposal) do
      {true, violated} ->
        {:error, {:violates_invariants, violated}}

      {false, _} ->
        :ok
    end
  end

  defp maybe_authorize(nil, _proposal), do: :ok

  defp maybe_authorize(authorizer, proposal) do
    authorizer.authorize_proposal(proposal)
  end

  defp compute_fingerprint(proposal) do
    # Use topic (was change_type) and context fields for fingerprinting
    data =
      :erlang.term_to_binary({
        proposal.topic,
        Map.get(proposal.context, :target_module),
        proposal.description,
        Map.get(proposal.context, :code_diff)
      })

    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  # Try agent delivery first, fall back to direct council spawning
  defp spawn_council(state, proposal, evaluator_backend, perspectives, quorum) do
    case resolve_evaluator_agents(perspectives) do
      {:ok, agent_mapping} when map_size(agent_mapping) > 0 ->
        deliver_to_agents(state, proposal, agent_mapping, quorum)

      _ ->
        # Direct path: spawn temporary council tasks
        spawn_council_direct(state, proposal, evaluator_backend, perspectives, quorum)
    end
  end

  # Direct council spawning: temporary tasks for each perspective
  defp spawn_council_direct(state, proposal, evaluator_backend, perspectives, quorum) do
    config = state.config

    task =
      Task.async(fn ->
        result =
          Council.evaluate(proposal, perspectives, evaluator_backend,
            timeout: config.evaluation_timeout_ms,
            quorum: quorum
          )

        {:council_result, proposal.id, result}
      end)

    %{state | active_councils: Map.put(state.active_councils, proposal.id, task)}
  end

  # Deliver proposal to persistent evaluator agents
  defp deliver_to_agents(state, proposal, agent_mapping, quorum) do
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

      spawn_council_direct(
        state,
        proposal,
        state.evaluator_backend,
        Map.values(agent_mapping) |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq(),
        quorum
      )
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

  # Collect an evaluation from a persistent agent
  defp collect_agent_evaluation(state, proposal_id, evaluation) do
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

  # Remove a failed evaluator from pending list
  defp remove_pending_evaluator(state, proposal_id, evaluator_name) do
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

    # Process evaluations (same as direct council path)
    process_evaluations(state, proposal_id, evaluations)
  end

  defp process_evaluations(state, proposal_id, evaluations) do
    case Map.get(state.proposals, proposal_id) do
      nil ->
        Logger.warning("Received evaluations for unknown proposal #{proposal_id}")
        state

      proposal ->
        record_evaluation_events(state, proposal_id, evaluations)
        render_and_apply_decision(state, proposal_id, proposal, evaluations)
    end
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

  defp render_and_apply_decision(state, proposal_id, proposal, evaluations) do
    case CouncilDecision.from_evaluations(proposal, evaluations) do
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

  defp maybe_execute(state, %{status: :approved} = proposal, decision) do
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

  defp maybe_execute(state, _proposal, _decision), do: state

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
        if terminal_status?(status) do
          %{
            state
            | proposals_by_agent: remove_proposal_from_agent(state.proposals_by_agent, proposal)
          }
        else
          state
        end
    end
  end

  defp terminal_status?(status), do: status in [:approved, :rejected, :vetoed, :deadlock]

  defp kill_active_council(state, proposal_id) do
    case Map.get(state.active_councils, proposal_id) do
      nil ->
        state

      task ->
        Task.shutdown(task, :brutal_kill)
        %{state | active_councils: Map.delete(state.active_councils, proposal_id)}
    end
  end

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
    # Conditionally store based on persistence strategy
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

  # ===========================================================================
  # Quota Enforcement (Phase 7)
  # ===========================================================================

  defp check_agent_quota(state, proposal) do
    # Use per-coordinator config if set, otherwise fall back to Application env
    quota_enabled =
      case state.config.proposal_quota_enabled do
        nil -> Config.proposal_quota_enabled?()
        val -> val
      end

    if quota_enabled do
      max_per_agent =
        case state.config.max_proposals_per_agent do
          nil -> Config.max_proposals_per_agent()
          val -> val
        end

      agent_proposals = Map.get(state.proposals_by_agent, proposal.proposer, [])
      current_count = length(agent_proposals)

      if current_count >= max_per_agent do
        {:error, :agent_proposal_quota_exceeded}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp add_proposal_to_agent(proposals_by_agent, proposal) do
    Map.update(proposals_by_agent, proposal.proposer, [proposal.id], fn ids ->
      [proposal.id | ids]
    end)
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

  # ===========================================================================
  # Phase 3: Topic-Driven Routing
  # ===========================================================================

  # Route proposals via TopicMatcher when topic is :general or not explicitly set.
  # If the proposal already has a specific topic AND TopicRegistry has a rule for it,
  # use that topic directly. Otherwise, run TopicMatcher to find best fit.
  defp maybe_route_via_topic_matcher(proposal) do
    # If topic is explicitly set (not :general) and exists in registry, use it
    if proposal.topic != :general and topic_exists_in_registry?(proposal.topic) do
      {:ok, proposal}
    else
      # Run TopicMatcher to find best-fit topic
      {matched_topic, confidence} = match_topic(proposal)

      # Update proposal with matched topic and store routing metadata
      updated_proposal = %{
        proposal
        | topic: matched_topic,
          metadata:
            Map.merge(proposal.metadata, %{
              routing_confidence: confidence,
              original_topic: proposal.topic,
              routed_by: :topic_matcher
            })
      }

      {:ok, updated_proposal}
    end
  end

  # Check if topic exists in TopicRegistry
  defp topic_exists_in_registry?(topic) do
    case TopicRegistry.get(topic) do
      {:ok, _rule} -> true
      {:error, :not_found} -> false
    end
  rescue
    # TopicRegistry may not be running
    _ -> false
  end

  # Match proposal to topic via TopicMatcher
  defp match_topic(proposal) do
    topics = get_all_topic_rules()

    if topics == [] do
      # No registry available, keep existing topic
      {proposal.topic, 0.0}
    else
      TopicMatcher.match(
        proposal.description,
        proposal.context,
        topics
      )
    end
  end

  # Get all topic rules from registry
  defp get_all_topic_rules do
    TopicRegistry.list()
  rescue
    # TopicRegistry may not be running
    _ -> []
  end

  # Resolve council configuration from TopicRegistry.
  # Advisory mode proposals get quorum of nil (collect all perspectives).
  defp resolve_council_config(proposal, _config) do
    topic = proposal.topic

    case TopicRegistry.get(topic) do
      {:ok, rule} ->
        resolve_from_topic_rule(proposal, rule)

      {:error, :not_found} ->
        # Topic not in registry — use default perspectives (all non-human)
        Logger.warning("Topic #{inspect(topic)} not found in TopicRegistry, using defaults")
        default_perspectives_and_quorum(proposal)
    end
  rescue
    # TopicRegistry not running — fall back to default perspectives
    _ ->
      default_perspectives_and_quorum(proposal)
  end

  defp default_perspectives_and_quorum(proposal) do
    perspectives = Arbor.Contracts.Consensus.Protocol.perspectives() -- [:human]

    quorum =
      if proposal.mode == :advisory,
        do: nil,
        else: Arbor.Contracts.Consensus.Protocol.standard_quorum()

    {perspectives, quorum}
  end

  # Resolve council config from TopicRule
  defp resolve_from_topic_rule(proposal, rule) do
    # Get perspectives from required_evaluators if present, otherwise use defaults
    perspectives =
      case rule.required_evaluators do
        [] ->
          # No evaluators specified in rule, use default perspectives
          Arbor.Contracts.Consensus.Protocol.perspectives() -- [:human]

        evaluators ->
          # Resolve perspectives from evaluator modules
          resolve_perspectives_from_evaluators(evaluators)
      end

    # Calculate quorum - advisory mode gets nil (no early termination, collect all)
    quorum =
      if proposal.mode == :advisory do
        nil
      else
        council_size = length(perspectives)
        TopicRule.quorum_to_number(rule.min_quorum, council_size)
      end

    {perspectives, quorum}
  end

  # Resolve perspectives from evaluator modules.
  # Calls evaluator.perspectives() for each module and flattens the results.
  # Falls back to Protocol defaults if no valid perspectives are returned.
  defp resolve_perspectives_from_evaluators(evaluators) do
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

  # Advisory mode skips duplicate check
  defp check_duplicate_unless_advisory(_state, %{mode: :advisory}), do: :ok
  defp check_duplicate_unless_advisory(state, proposal), do: check_duplicate(state, proposal)

  # Advisory mode skips agent quota check
  defp check_agent_quota_unless_advisory(_state, %{mode: :advisory}), do: :ok
  defp check_agent_quota_unless_advisory(state, proposal), do: check_agent_quota(state, proposal)

  # ===========================================================================
  # Waiter Support (Phase 2: Tier 1 Notification)
  # ===========================================================================

  defp register_waiter(state, proposal_id, pid) do
    ref = Process.monitor(pid)
    waiter = {pid, ref}

    waiters =
      Map.update(state.waiters, proposal_id, [waiter], fn existing ->
        [waiter | existing]
      end)

    %{state | waiters: waiters}
  end

  defp unregister_waiter(state, proposal_id, pid) do
    case Map.get(state.waiters, proposal_id) do
      nil -> state
      waiters -> do_unregister_waiter(state, proposal_id, waiters, pid)
    end
  end

  defp do_unregister_waiter(state, proposal_id, waiters, pid) do
    case Enum.find(waiters, fn {p, _ref} -> p == pid end) do
      nil ->
        state

      {_pid, ref} ->
        Process.demonitor(ref, [:flush])
        new_waiters = Enum.reject(waiters, fn {p, _} -> p == pid end)
        update_waiters_for_proposal(state, proposal_id, new_waiters)
    end
  end

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

  defp cleanup_waiter_by_ref(state, ref, pid) do
    # Find which proposal this waiter was for and remove them
    case find_waiter_proposal(state.waiters, ref, pid) do
      nil ->
        state

      {proposal_id, waiters} ->
        new_waiters = Enum.reject(waiters, fn {p, _} -> p == pid end)
        update_waiters_for_proposal(state, proposal_id, new_waiters)
    end
  end

  # Find which proposal a waiter belongs to by ref and pid
  defp find_waiter_proposal(all_waiters, ref, pid) do
    Enum.find_value(all_waiters, fn {proposal_id, waiters} ->
      if waiter_in_list?(waiters, ref, pid), do: {proposal_id, waiters}
    end)
  end

  defp waiter_in_list?(waiters, ref, pid) do
    Enum.any?(waiters, fn {p, r} -> p == pid and r == ref end)
  end

  # Update waiters map for a proposal, removing entry if empty
  defp update_waiters_for_proposal(state, proposal_id, []) do
    %{state | waiters: Map.delete(state.waiters, proposal_id)}
  end

  defp update_waiters_for_proposal(state, proposal_id, new_waiters) do
    %{state | waiters: Map.put(state.waiters, proposal_id, new_waiters)}
  end

  # ===========================================================================
  # Event Sourcing & Recovery
  # ===========================================================================

  defp generate_coordinator_id do
    "coord_#{System.unique_integer([:positive, :monotonic])}_#{System.os_time(:millisecond)}"
  end

  defp recover_from_events(state) do
    case Config.event_log() do
      nil ->
        Logger.debug("Coordinator: no event_log configured, starting fresh")
        state

      event_log_config ->
        do_recover_from_events(state, event_log_config)
    end
  end

  defp do_recover_from_events(state, event_log_config) do
    case StateRecovery.rebuild_from_events(event_log_config) do
      {:ok, recovered} ->
        Logger.info(
          "Coordinator: recovered #{map_size(recovered.proposals)} proposals, " <>
            "#{map_size(recovered.decisions)} decisions, " <>
            "#{length(recovered.interrupted)} interrupted from #{recovered.events_replayed} events"
        )

        # Emit recovery events
        if Config.emit_recovery_events?() do
          emit_recovery_started(state, recovered.last_position)
        end

        # Convert recovered state to Coordinator state
        state = apply_recovered_state(state, recovered)

        # Handle interrupted evaluations
        state = handle_interrupted_evaluations(state, recovered.interrupted)

        if Config.emit_recovery_events?() do
          emit_recovery_completed(state, recovered)
        end

        state

      {:error, reason} ->
        Logger.error("Coordinator: recovery failed: #{inspect(reason)}, starting fresh")
        emit_coordinator_error(nil, {:recovery_failed, reason})
        state
    end
  end

  defp apply_recovered_state(state, recovered) do
    # Rebuild proposals map with Proposal structs
    proposals =
      Map.new(recovered.proposals, fn {id, info} ->
        # Migrate old fields into context for recovered proposals
        context =
          %{}
          |> maybe_put(:target_module, info.target_module)

        proposal = %Proposal{
          id: id,
          proposer: info.proposer,
          topic: info.topic,
          mode: :decision,
          description: info.description,
          target_layer: info.target_layer,
          context: context,
          metadata: info.metadata || %{},
          status: info.status,
          created_at: info.submitted_at,
          updated_at: info.submitted_at
        }

        {id, proposal}
      end)

    # Rebuild decisions map
    decisions =
      Map.new(recovered.decisions, fn {proposal_id, dec} ->
        decision = %CouncilDecision{
          id: dec.id,
          proposal_id: proposal_id,
          decision: dec.decision,
          approve_count: dec.approve_count,
          reject_count: dec.reject_count,
          abstain_count: dec.abstain_count,
          required_quorum: dec.required_quorum,
          quorum_met: dec.quorum_met,
          primary_concerns: dec.primary_concerns || [],
          average_confidence: dec.average_confidence || 0.0,
          created_at: dec.timestamp,
          decided_at: dec.timestamp
        }

        {proposal_id, decision}
      end)

    # Rebuild proposals_by_agent for quota tracking
    proposals_by_agent =
      proposals
      |> Map.values()
      |> Enum.filter(&(&1.status in [:pending, :evaluating]))
      |> Enum.group_by(& &1.proposer)
      |> Map.new(fn {agent, props} -> {agent, Enum.map(props, & &1.id)} end)

    %{
      state
      | proposals: proposals,
        decisions: decisions,
        proposals_by_agent: proposals_by_agent,
        last_event_position: recovered.last_position
    }
  end

  defp handle_interrupted_evaluations(state, []), do: state

  defp handle_interrupted_evaluations(state, interrupted) do
    strategy = Config.recovery_strategy()

    Logger.info(
      "Coordinator: handling #{length(interrupted)} interrupted evaluations with strategy: #{strategy}"
    )

    Enum.reduce(interrupted, state, fn info, acc_state ->
      handle_single_interrupted(acc_state, info, strategy)
    end)
  end

  defp handle_single_interrupted(state, info, :deadlock) do
    # Mark as deadlocked - safest option
    Logger.info("Coordinator: marking proposal #{info.proposal_id} as deadlocked (interrupted)")

    state = update_proposal_status(state, info.proposal_id, :deadlock)

    EventEmitter.proposal_deadlocked(
      info.proposal_id,
      :interrupted,
      "Evaluation interrupted by crash. Missing perspectives: #{inspect(info.missing_perspectives)}"
    )

    # Emit signal for real-time observability
    emit_proposal_timeout(info.proposal_id, :interrupted)

    state
  end

  defp handle_single_interrupted(state, info, :resume) do
    # Re-spawn only missing evaluations
    case Map.get(state.proposals, info.proposal_id) do
      nil ->
        state

      proposal ->
        Logger.info(
          "Coordinator: resuming evaluation for #{info.proposal_id}, " <>
            "#{length(info.missing_perspectives)} perspectives remaining"
        )

        # Spawn council for only the missing perspectives
        spawn_council_for_perspectives(state, proposal, info.missing_perspectives)
    end
  end

  defp handle_single_interrupted(state, info, :restart) do
    # Re-spawn entire council
    case Map.get(state.proposals, info.proposal_id) do
      nil ->
        state

      proposal ->
        Logger.info("Coordinator: restarting full evaluation for #{info.proposal_id}")
        {perspectives, quorum} = resolve_council_config(proposal, state.config)
        spawn_council(state, proposal, state.evaluator_backend, perspectives, quorum)
    end
  end

  defp spawn_council_for_perspectives(state, proposal, perspectives) do
    # Similar to spawn_council but with specific perspectives (used for recovery)
    config = state.config

    # Resolve quorum from TopicRegistry or Protocol default
    quorum =
      if proposal.mode == :advisory do
        nil
      else
        case TopicRegistry.get(proposal.topic) do
          {:ok, rule} ->
            TopicRule.quorum_to_number(rule.min_quorum, length(perspectives))

          _ ->
            Arbor.Contracts.Consensus.Protocol.standard_quorum()
        end
      end

    task =
      Task.async(fn ->
        result =
          Council.evaluate(proposal, perspectives, state.evaluator_backend,
            timeout: config.evaluation_timeout_ms,
            quorum: quorum
          )

        {:council_result, proposal.id, result}
      end)

    %{state | active_councils: Map.put(state.active_councils, proposal.id, task)}
  end

  defp emit_coordinator_started(state) do
    config_map = %{
      evaluation_timeout_ms: state.config.evaluation_timeout_ms,
      max_concurrent_proposals: state.config.max_concurrent_proposals,
      auto_execute_approved: state.config.auto_execute_approved
    }

    recovered_from =
      if state.last_event_position > 0 do
        state.last_event_position
      else
        nil
      end

    EventEmitter.coordinator_started(state.coordinator_id, config_map,
      recovered_from: recovered_from
    )
  end

  defp emit_recovery_started(state, from_position) do
    EventEmitter.recovery_started(state.coordinator_id, from_position)
  end

  defp emit_recovery_completed(state, recovered) do
    stats = %{
      proposals_recovered: map_size(recovered.proposals),
      decisions_recovered: map_size(recovered.decisions),
      interrupted_count: length(recovered.interrupted),
      events_replayed: recovered.events_replayed
    }

    EventEmitter.recovery_completed(state.coordinator_id, stats)
  end

  # Signal emission helpers for real-time observability

  defp emit_coordinator_error(proposal_id, reason) do
    Signals.emit(:consensus, :coordinator_error, %{
      proposal_id: proposal_id,
      reason: truncate_reason(reason)
    })
  end

  defp emit_proposal_timeout(proposal_id, reason) do
    Signals.emit(:consensus, :proposal_timeout, %{
      proposal_id: proposal_id,
      reason: reason
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

  # Helper to conditionally add to map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ===========================================================================
  # Phase 5: Organic Topic Creation
  # ===========================================================================

  @organic_topic_threshold 5
  @organic_check_interval 10
  @max_tracked_patterns 100
  @stats_max_age_days 30
  @max_descriptions_per_pattern 10

  # Track when proposals route to :general
  defp track_routing_stats(state, proposal) do
    if proposal.topic == :general do
      keywords = extract_keywords(proposal.description)
      now = DateTime.utc_now()

      routing_stats =
        Enum.reduce(keywords, state.routing_stats, fn keyword, stats ->
          Map.update(
            stats,
            keyword,
            %{count: 1, last_seen: now, descriptions: [proposal.description]},
            &update_routing_stat_entry(&1, now, proposal.description)
          )
        end)

      # Prune old and excess entries
      routing_stats = prune_routing_stats(routing_stats, now)

      new_count = state.general_route_count + 1

      state = %{state | routing_stats: routing_stats, general_route_count: new_count}

      # Check for organic topic patterns periodically
      if rem(new_count, @organic_check_interval) == 0 do
        check_organic_topics(state)
      else
        state
      end
    else
      state
    end
  end

  defp update_routing_stat_entry(entry, now, description) do
    descriptions =
      Enum.take(
        [description | entry.descriptions],
        @max_descriptions_per_pattern
      )

    %{entry | count: entry.count + 1, last_seen: now, descriptions: descriptions}
  end

  # Extract significant keywords from a description
  defp extract_keywords(description) do
    stop_words = ~w(the a an is are was were be been being have has had do does did
                     will would shall should may might can could of in to for on with
                     at by from this that it and or but not as if then than)

    description
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in stop_words or String.length(&1) < 3))
    |> Enum.uniq()
  end

  # Prune routing stats: remove old entries and cap size
  defp prune_routing_stats(stats, now) do
    cutoff = DateTime.add(now, -@stats_max_age_days, :day)

    stats
    |> Enum.reject(fn {_keyword, entry} ->
      DateTime.compare(entry.last_seen, cutoff) == :lt
    end)
    |> Enum.sort_by(fn {_keyword, entry} -> entry.count end, :desc)
    |> Enum.take(@max_tracked_patterns)
    |> Map.new()
  end

  # Analyze routing stats for potential new topics
  defp check_organic_topics(state) do
    # Find keywords that appear frequently in :general-routed proposals
    candidates =
      state.routing_stats
      |> Enum.filter(fn {_keyword, entry} -> entry.count >= @organic_topic_threshold end)
      |> Enum.sort_by(fn {_keyword, entry} -> entry.count end, :desc)

    case candidates do
      [] ->
        state

      candidates ->
        # Group related keywords (those appearing in the same descriptions)
        topic_candidate = build_topic_candidate(candidates)
        propose_organic_topic(state, topic_candidate)
    end
  end

  # Build a topic candidate from frequently co-occurring keywords
  defp build_topic_candidate(candidates) do
    # Take top keywords as match patterns
    keywords = Enum.map(candidates, fn {keyword, _entry} -> keyword end)
    top_keywords = Enum.take(keywords, 5)

    # Build a suggested topic name as a string — actual atom creation happens
    # if/when governance approves the topic via TopicRegistry
    {primary_keyword, _entry} = hd(candidates)
    topic_name = "organic_#{primary_keyword}"

    %{
      topic: topic_name,
      match_patterns: top_keywords,
      keyword_counts: Enum.map(Enum.take(candidates, 5), fn {k, e} -> {k, e.count} end)
    }
  end

  # Submit topic creation proposal to :topic_governance
  defp propose_organic_topic(state, candidate) do
    description =
      "Organic topic creation: #{candidate.topic}. " <>
        "Keywords #{inspect(candidate.match_patterns)} appeared frequently in " <>
        ":general-routed proposals (counts: #{inspect(candidate.keyword_counts)}). " <>
        "Suggesting dedicated topic for better routing."

    proposal_attrs = %{
      proposer: "coordinator:#{state.coordinator_id}",
      topic: :topic_governance,
      mode: :advisory,
      description: description,
      context: %{
        organic_topic: true,
        suggested_topic: candidate.topic,
        match_patterns: candidate.match_patterns,
        keyword_counts: candidate.keyword_counts
      },
      metadata: %{source: :organic_topic_detection}
    }

    # Submit internally via a Task to avoid blocking.
    # Capture the coordinator pid before spawning the Task.
    coordinator_pid = self()

    Task.start(fn ->
      case Proposal.new(proposal_attrs) do
        {:ok, proposal} ->
          try do
            GenServer.call(coordinator_pid, {:submit, proposal, []})
          catch
            :exit, _ ->
              Logger.debug("Organic topic proposal submission failed (coordinator busy)")
          end

        {:error, reason} ->
          Logger.warning("Failed to create organic topic proposal: #{inspect(reason)}")
      end
    end)

    # Reset the general route count to avoid re-proposing
    %{state | general_route_count: 0}
  rescue
    e ->
      Logger.warning("Organic topic creation error: #{inspect(e)}")
      state
  end
end
