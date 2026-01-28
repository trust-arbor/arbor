defmodule Arbor.Consensus do
  @moduledoc """
  Pure deliberation engine for multi-perspective consensus on system changes.

  Provides a facade API for submitting proposals, querying decisions,
  and managing the consensus lifecycle. Delegates to the Coordinator
  GenServer.

  ## Architecture

      Proposal  →  Coordinator  →  Council  →  Evaluators (behaviour)
                       │                           │
                  EventStore (ETS)          EvaluatorBackend.evaluate/3
                       │                     (rule-based default)
                  Decision rendered          (LLM adapter in host app)
                       │
              on_decision callback  →  host app executes

  ## Pluggable Behaviours

    * `EvaluatorBackend` — Required. Evaluates proposals from a perspective.
      Default: `EvaluatorBackend.RuleBased`
    * `Authorizer` — Optional. Pre-submit and pre-execution authorization.
    * `Executor` — Optional. Executes approved proposals.
    * `EventSink` — Optional. Persists events to external storage.

  ## Quick Start

      # Submit a proposal
      {:ok, proposal_id} = Arbor.Consensus.submit(%{
        proposer: "agent_1",
        change_type: :code_modification,
        description: "Add caching to API calls",
        new_code: "defmodule Cache do ... end"
      })

      # Check status
      {:ok, :evaluating} = Arbor.Consensus.get_status(proposal_id)

      # Get decision (once evaluated)
      {:ok, decision} = Arbor.Consensus.get_decision(proposal_id)
  """

  alias Arbor.Consensus.{Coordinator, EventStore}

  # ============================================================================
  # Proposal Lifecycle
  # ============================================================================

  @doc """
  Submit a proposal for consensus evaluation.

  Accepts a map of proposal attributes or a `Proposal.t()` struct.
  Returns the proposal ID on success.

  ## Options

    * `:server` - Coordinator server (default: `Coordinator`)
    * `:evaluator_backend` - Override the evaluator backend for this proposal
  """
  @spec submit(map() | Arbor.Contracts.Consensus.Proposal.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate submit(proposal_or_attrs, opts \\ []), to: Coordinator

  @doc """
  Get the current status of a proposal.
  """
  @spec get_status(String.t(), GenServer.server()) ::
          {:ok, atom()} | {:error, :not_found}
  defdelegate get_status(proposal_id, server \\ Coordinator), to: Coordinator

  @doc """
  Get the decision for a proposal.
  """
  @spec get_decision(String.t(), GenServer.server()) ::
          {:ok, Arbor.Contracts.Consensus.CouncilDecision.t()} | {:error, term()}
  defdelegate get_decision(proposal_id, server \\ Coordinator), to: Coordinator

  @doc """
  Get a proposal by ID.
  """
  @spec get_proposal(String.t(), GenServer.server()) ::
          {:ok, Arbor.Contracts.Consensus.Proposal.t()} | {:error, :not_found}
  defdelegate get_proposal(proposal_id, server \\ Coordinator), to: Coordinator

  # ============================================================================
  # Listing & Querying
  # ============================================================================

  @doc """
  List all pending proposals.
  """
  @spec list_pending(GenServer.server()) :: [Arbor.Contracts.Consensus.Proposal.t()]
  defdelegate list_pending(server \\ Coordinator), to: Coordinator

  @doc """
  List all proposals.
  """
  @spec list_proposals(GenServer.server()) :: [Arbor.Contracts.Consensus.Proposal.t()]
  defdelegate list_proposals(server \\ Coordinator), to: Coordinator

  @doc """
  List all decisions.
  """
  @spec list_decisions(GenServer.server()) :: [Arbor.Contracts.Consensus.CouncilDecision.t()]
  defdelegate list_decisions(server \\ Coordinator), to: Coordinator

  @doc """
  Get recent decisions (most recent first).
  """
  @spec recent_decisions(pos_integer(), GenServer.server()) ::
          [Arbor.Contracts.Consensus.CouncilDecision.t()]
  defdelegate recent_decisions(limit \\ 10, server \\ Coordinator), to: Coordinator

  # ============================================================================
  # Management
  # ============================================================================

  @doc """
  Cancel a pending proposal.
  """
  @spec cancel(String.t(), GenServer.server()) :: :ok | {:error, term()}
  defdelegate cancel(proposal_id, server \\ Coordinator), to: Coordinator

  @doc """
  Force-approve a proposal (human override).
  """
  @spec force_approve(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  defdelegate force_approve(proposal_id, approver_id, server \\ Coordinator), to: Coordinator

  @doc """
  Force-reject a proposal (human override).
  """
  @spec force_reject(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  defdelegate force_reject(proposal_id, rejector_id, server \\ Coordinator), to: Coordinator

  @doc """
  Get coordinator statistics.
  """
  @spec stats(GenServer.server()) :: map()
  defdelegate stats(server \\ Coordinator), to: Coordinator

  # ============================================================================
  # Event Store
  # ============================================================================

  @doc """
  Query consensus events.

  ## Filters

    * `:proposal_id` - Filter by proposal ID
    * `:event_type` - Filter by event type
    * `:agent_id` - Filter by agent ID
    * `:since` / `:until` - Time range
    * `:limit` - Max results (default: 100)
  """
  @spec query_events(keyword(), GenServer.server()) ::
          [Arbor.Contracts.Consensus.ConsensusEvent.t()]
  defdelegate query_events(filters \\ [], server \\ EventStore), to: EventStore, as: :query

  @doc """
  Get all events for a proposal.
  """
  @spec events_for(String.t(), GenServer.server()) ::
          [Arbor.Contracts.Consensus.ConsensusEvent.t()]
  defdelegate events_for(proposal_id, server \\ EventStore), to: EventStore, as: :get_by_proposal

  @doc """
  Get a chronological timeline of events for a proposal.
  """
  @spec timeline(String.t(), GenServer.server()) ::
          [{non_neg_integer(), Arbor.Contracts.Consensus.ConsensusEvent.t()}]
  defdelegate timeline(proposal_id, server \\ EventStore), to: EventStore, as: :get_timeline
end
