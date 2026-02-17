defmodule Arbor.Consensus.Coordinator do
  @moduledoc """
  Central GenServer orchestrating the proposal lifecycle.

  Manages proposals from submission through evaluation to decision.
  Delegates evaluation to Council, uses pluggable behaviours for
  authorization, execution, and event sinking.

  ## Lifecycle

      submit -> validate -> authorize -> spawn council -> collect evaluations
           -> render decision -> (optional) execute -> record events

  ## State

  Tracks active proposals, decisions, council tasks, and duplicate
  fingerprints for deduplication.

  ## Sub-modules

  * `Coordinator.Voting` - Evaluation processing, decision rendering, council spawning
  * `Coordinator.TopicRouting` - Topic matching, routing, organic topic creation
  """

  use GenServer

  alias Arbor.Consensus.{Config, EventEmitter, EventStore, StateRecovery}
  alias Arbor.Consensus.Coordinator.{TopicRouting, Voting}
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
    * `:evaluator_backend` - Module implementing `Evaluator` behaviour
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
          Arbor.Consensus.Evaluator.RuleBased
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
         {:ok, proposal} <- TopicRouting.maybe_route_via_topic_matcher(proposal),
         :ok <- check_capacity(state),
         :ok <- check_duplicate_unless_advisory(state, proposal),
         :ok <- check_invariants(proposal),
         :ok <- check_agent_quota_unless_advisory(state, proposal),
         :ok <- maybe_authorize(state.authorizer, proposal) do
      # Register proposal
      proposal = Proposal.update_status(proposal, :evaluating)
      fingerprint = compute_fingerprint(proposal)

      # Phase 5: Track routing stats for organic topic creation
      state = TopicRouting.track_routing_stats(state, proposal)

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
      {resolved_evaluators, resolved_quorum} = TopicRouting.resolve_council_config(proposal, state.config)

      # Allow override via opts (for testing), otherwise use resolved evaluators
      # Priority: opts[:evaluators] > opts[:evaluator_backend] > state.evaluator_backend > resolved
      evaluators =
        case {Keyword.get(opts, :evaluators), Keyword.get(opts, :evaluator_backend)} do
          {override, _} when override != nil -> override
          {nil, backend} when backend != nil -> [backend]
          {nil, nil} ->
            # Use state.evaluator_backend if different from default, otherwise use resolved
            if state.evaluator_backend != Arbor.Consensus.Evaluator.RuleBased do
              [state.evaluator_backend]
            else
              resolved_evaluators
            end
        end

      # Extract perspectives from evaluators
      perspectives = Voting.resolve_perspectives_from_evaluators(evaluators)

      # Recalculate quorum based on actual perspectives available
      # This prevents mismatches where resolved quorum exceeds available perspectives
      quorum =
        if proposal.mode == :advisory do
          nil
        else
          council_size = length(perspectives)
          # Use the minimum of resolved quorum or simple majority of actual perspectives
          # This ensures quorum is achievable while respecting topic rules when possible
          min(resolved_quorum, div(council_size, 2) + 1)
        end

      # Emit evaluation started event
      EventEmitter.evaluation_started(
        proposal.id,
        perspectives,
        length(perspectives),
        quorum
      )

      state = Voting.spawn_council(state, proposal, evaluators, quorum)

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
    # H6: Require consensus/admin capability for force operations
    with :ok <- check_force_authorization(approver_id),
         proposal when not is_nil(proposal) <- Map.get(state.proposals, proposal_id) do
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
      state = Voting.maybe_execute(state, proposal, nil)

      {:reply, :ok, state}
    else
      nil -> {:reply, {:error, :not_found}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:force_reject, proposal_id, rejector_id}, _from, state) do
    # H6: Require consensus/admin capability for force operations
    with :ok <- check_force_authorization(rejector_id),
         proposal when not is_nil(proposal) <- Map.get(state.proposals, proposal_id) do
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
    else
      nil -> {:reply, {:error, :not_found}, state}
      {:error, _} = error -> {:reply, error, state}
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
        # Recalculate quorum from topic for this proposal
        quorum = TopicRouting.get_proposal_quorum(state, proposal_id)
        state = Voting.process_evaluations(state, proposal_id, evaluations, quorum)
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
    state = Voting.collect_agent_evaluation(state, proposal_id, evaluation)
    {:noreply, state}
  end

  # Handle evaluation failure from persistent agents
  @impl true
  def handle_info({:evaluation_failed, proposal_id, evaluator_name, reason}, state) do
    Logger.warning(
      "EvaluatorAgent #{evaluator_name} failed for proposal #{proposal_id}: #{inspect(reason)}"
    )

    # Remove evaluator from pending list (treat as abstention)
    state = Voting.remove_pending_evaluator(state, proposal_id, evaluator_name)
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
  # Private Functions - Validation & Proposal Management
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

  # M5: Check force_approve/force_reject authorization via full authorize/4 pipeline.
  defp check_force_authorization(actor_id) do
    case Arbor.Security.authorize(actor_id, "arbor://consensus/admin", :force) do
      {:ok, :authorized} ->
        :ok

      {:ok, :pending_approval, _proposal_id} ->
        Logger.warning("Force operation by #{actor_id} requires approval")
        {:error, {:unauthorized, :pending_approval}}

      {:error, reason} ->
        Logger.warning("Unauthorized force operation attempted by #{actor_id}: #{inspect(reason)}")
        {:error, {:unauthorized, :consensus_admin_required}}
    end
  rescue
    _ ->
      # If security module isn't available, deny by default (fail-closed)
      {:error, {:unauthorized, :security_unavailable}}
  catch
    :exit, _ ->
      # GenServer not running (Identity.Registry etc.) — fail closed
      {:error, {:unauthorized, :security_unavailable}}
  end

  defp maybe_authorize(nil, _proposal), do: :ok

  defp maybe_authorize(authorizer, proposal) do
    authorizer.authorize_proposal(proposal)
  end

  defp compute_fingerprint(proposal) do
    data =
      :erlang.term_to_binary({
        proposal.topic,
        Map.get(proposal.context, :target_module),
        proposal.description,
        Map.get(proposal.context, :code_diff)
      })

    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  # Advisory mode skips duplicate check
  defp check_duplicate_unless_advisory(_state, %{mode: :advisory}), do: :ok
  defp check_duplicate_unless_advisory(state, proposal), do: check_duplicate(state, proposal)

  # Advisory mode skips agent quota check
  defp check_agent_quota_unless_advisory(_state, %{mode: :advisory}), do: :ok
  defp check_agent_quota_unless_advisory(state, proposal), do: check_agent_quota(state, proposal)

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

  # ============================================================================
  # Quota Enforcement (Phase 7)
  # ============================================================================

  defp check_agent_quota(state, proposal) do
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

  # ============================================================================
  # Waiter Support (Phase 2: Tier 1 Notification)
  # ============================================================================

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

  defp cleanup_waiter_by_ref(state, ref, pid) do
    case find_waiter_proposal(state.waiters, ref, pid) do
      nil ->
        state

      {proposal_id, waiters} ->
        new_waiters = Enum.reject(waiters, fn {p, _} -> p == pid end)
        update_waiters_for_proposal(state, proposal_id, new_waiters)
    end
  end

  defp find_waiter_proposal(all_waiters, ref, pid) do
    Enum.find_value(all_waiters, fn {proposal_id, waiters} ->
      if waiter_in_list?(waiters, ref, pid), do: {proposal_id, waiters}
    end)
  end

  defp waiter_in_list?(waiters, ref, pid) do
    Enum.any?(waiters, fn {p, r} -> p == pid and r == ref end)
  end

  defp update_waiters_for_proposal(state, proposal_id, []) do
    %{state | waiters: Map.delete(state.waiters, proposal_id)}
  end

  defp update_waiters_for_proposal(state, proposal_id, new_waiters) do
    %{state | waiters: Map.put(state.waiters, proposal_id, new_waiters)}
  end

  # ============================================================================
  # Event Recording & Signals
  # ============================================================================

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

  # ============================================================================
  # Event Sourcing & Recovery
  # ============================================================================

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
    Logger.info("Coordinator: marking proposal #{info.proposal_id} as deadlocked (interrupted)")

    state = update_proposal_status(state, info.proposal_id, :deadlock)

    EventEmitter.proposal_deadlocked(
      info.proposal_id,
      :interrupted,
      "Evaluation interrupted by crash. Missing perspectives: #{inspect(info.missing_perspectives)}"
    )

    emit_proposal_timeout(info.proposal_id, :interrupted)

    state
  end

  defp handle_single_interrupted(state, info, :resume) do
    case Map.get(state.proposals, info.proposal_id) do
      nil ->
        state

      proposal ->
        Logger.info(
          "Coordinator: resuming evaluation for #{info.proposal_id}, " <>
            "#{length(info.missing_perspectives)} perspectives remaining"
        )

        Voting.spawn_council_for_perspectives(state, proposal, info.missing_perspectives)
    end
  end

  defp handle_single_interrupted(state, info, :restart) do
    case Map.get(state.proposals, info.proposal_id) do
      nil ->
        state

      proposal ->
        Logger.info("Coordinator: restarting full evaluation for #{info.proposal_id}")
        {evaluators, quorum} = TopicRouting.resolve_council_config(proposal, state.config)
        Voting.spawn_council(state, proposal, evaluators, quorum)
    end
  end

  # ============================================================================
  # Signal Emission Helpers
  # ============================================================================

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
end
