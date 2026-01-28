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

  alias Arbor.Consensus.{Config, Council, EventStore}
  alias Arbor.Contracts.Consensus.{ConsensusEvent, CouncilDecision, Proposal}

  require Logger

  defstruct [
    :config,
    :evaluator_backend,
    :authorizer,
    :executor,
    :event_sink,
    proposals: %{},
    decisions: %{},
    active_councils: %{},
    pending_fingerprints: %{},
    proposals_by_agent: %{}
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          evaluator_backend: module(),
          authorizer: module() | nil,
          executor: module() | nil,
          event_sink: module() | nil,
          proposals: map(),
          decisions: map(),
          active_councils: map(),
          pending_fingerprints: map(),
          proposals_by_agent: %{String.t() => [String.t()]}
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

    state = %__MODULE__{
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

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, proposal_or_attrs, opts}, _from, state) do
    with {:ok, proposal} <- resolve_proposal(proposal_or_attrs),
         :ok <- check_capacity(state),
         :ok <- check_duplicate(state, proposal),
         :ok <- check_invariants(proposal),
         :ok <- check_agent_quota(state, proposal),
         :ok <- maybe_authorize(state.authorizer, proposal) do
      # Register proposal
      proposal = Proposal.update_status(proposal, :evaluating)
      fingerprint = compute_fingerprint(proposal)

      state = %{
        state
        | proposals: Map.put(state.proposals, proposal.id, proposal),
          pending_fingerprints: Map.put(state.pending_fingerprints, fingerprint, proposal.id),
          proposals_by_agent: add_proposal_to_agent(state.proposals_by_agent, proposal)
      }

      # Record submission event
      record_event(state, :proposal_submitted, %{
        proposal_id: proposal.id,
        agent_id: proposal.proposer,
        data: %{
          change_type: proposal.change_type,
          description: proposal.description
        }
      })

      # Spawn council asynchronously
      evaluator_backend = Keyword.get(opts, :evaluator_backend, state.evaluator_backend)
      state = spawn_council(state, proposal, evaluator_backend)

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
        council_size: state.config.council_size,
        max_concurrent: state.config.max_concurrent_proposals,
        auto_execute: state.config.auto_execute_approved
      },
      # Quota stats (Phase 7)
      max_proposals_per_agent: Config.max_proposals_per_agent(),
      agents_with_proposals: map_size(state.proposals_by_agent),
      proposal_quota_enabled: Config.proposal_quota_enabled?()
    }

    {:reply, stats, state}
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

        record_event(state, :proposal_timeout, %{
          proposal_id: proposal_id,
          data: %{reason: inspect(reason)}
        })

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task monitor DOWN message — already handled by the ref message above
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
    active = map_size(state.active_councils)

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
    data =
      :erlang.term_to_binary({
        proposal.change_type,
        proposal.target_module,
        proposal.description,
        proposal.code_diff
      })

    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp spawn_council(state, proposal, evaluator_backend) do
    config = state.config
    perspectives = Council.required_perspectives(proposal, config)
    quorum = Config.quorum_for(config, proposal.change_type)

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

    record_event(state, :decision_reached, %{
      proposal_id: proposal_id,
      decision_id: decision.id,
      decision: decision.decision,
      approve_count: decision.approve_count,
      reject_count: decision.reject_count,
      abstain_count: decision.abstain_count,
      data: %{
        quorum_met: decision.quorum_met,
        average_confidence: decision.average_confidence
      }
    })

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
      {:ok, _result} ->
        record_event(state, :execution_succeeded, %{
          proposal_id: proposal.id
        })

        state

      {:error, reason} ->
        Logger.error("Execution failed for #{proposal.id}: #{inspect(reason)}")

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
          %{state | proposals_by_agent: remove_proposal_from_agent(state.proposals_by_agent, proposal)}
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
    EventStore.append(event)
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
    if Config.proposal_quota_enabled?() do
      max_per_agent = Config.max_proposals_per_agent()
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
end
