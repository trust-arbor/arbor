defmodule Arbor.Contracts.API.Consensus do
  @moduledoc """
  Public API contract for the Arbor.Consensus library.

  Defines the facade interface for the multi-perspective consensus engine
  that evaluates proposals for system changes.

  ## Quick Start

      # Submit a proposal for consensus
      {:ok, proposal_id} = Arbor.Consensus.submit(%{
        proposer: "agent_001",
        topic: :code_modification,
        description: "Add caching to API calls",
        context: %{new_code: "defmodule Cache do ... end"}
      })

      # Check proposal status
      {:ok, :evaluating} = Arbor.Consensus.get_status(proposal_id)

      # Retrieve the decision once evaluation completes
      {:ok, decision} = Arbor.Consensus.get_decision(proposal_id)

  ## Proposal Lifecycle

  | Status | Meaning |
  |--------|---------|
  | `:pending` | Awaiting evaluation |
  | `:evaluating` | Evaluators are voting |
  | `:approved` | Quorum reached for approval |
  | `:rejected` | Quorum reached for rejection |
  | `:deadlock` | No quorum in either direction |
  | `:vetoed` | Vetoed by authorizer or force-reject |
  """

  alias Arbor.Contracts.Consensus.{ConsensusEvent, CouncilDecision, Proposal}

  # ===========================================================================
  # Types
  # ===========================================================================

  @type proposal_id :: String.t()
  @type proposal_attrs :: map()

  @type proposal_status ::
          :pending
          | :evaluating
          | :approved
          | :rejected
          | :deadlock
          | :vetoed

  @type submit_opts :: [
          server: GenServer.server(),
          evaluator_backend: module()
        ]

  @type event_filters :: [
          proposal_id: proposal_id(),
          event_type: ConsensusEvent.event_type(),
          agent_id: String.t(),
          since: DateTime.t(),
          until: DateTime.t(),
          limit: pos_integer()
        ]

  @type stats :: %{
          total_proposals: non_neg_integer(),
          pending: non_neg_integer(),
          approved: non_neg_integer(),
          rejected: non_neg_integer(),
          deadlocked: non_neg_integer()
        }

  @type timeline_entry :: {non_neg_integer(), ConsensusEvent.t()}

  # ===========================================================================
  # Proposal Lifecycle
  # ===========================================================================

  @doc """
  Submit a proposal for consensus evaluation.

  Accepts a map of proposal attributes or a `Proposal.t()` struct.
  Returns the assigned proposal ID on success.

  ## Options

    * `:evaluator_backend` - Override the evaluator backend for this proposal
  """
  @callback submit_proposal_for_consensus_evaluation(
              proposal_or_attrs :: Proposal.t() | proposal_attrs(),
              opts :: submit_opts()
            ) ::
              {:ok, proposal_id()} | {:error, :invalid_proposal | :authorization_denied | term()}

  @doc """
  Get the current status of a proposal by its ID.

  Returns the proposal's lifecycle status atom.
  """
  @callback get_proposal_status_by_id(proposal_id()) ::
              {:ok, proposal_status()} | {:error, :not_found}

  @doc """
  Get the council decision for a proposal by its ID.

  Returns the complete decision struct once evaluation is complete.
  """
  @callback get_council_decision_for_proposal(proposal_id()) ::
              {:ok, CouncilDecision.t()} | {:error, :not_found | :pending}

  @doc """
  Get a proposal by its ID.

  Returns the full proposal struct including metadata and status.
  """
  @callback get_proposal_by_id(proposal_id()) ::
              {:ok, Proposal.t()} | {:error, :not_found}

  # ===========================================================================
  # Listing & Querying
  # ===========================================================================

  @doc """
  List all proposals with pending status awaiting evaluation.
  """
  @callback list_pending_proposals() :: [Proposal.t()]

  @doc """
  List all proposals regardless of status.
  """
  @callback list_all_proposals() :: [Proposal.t()]

  @doc """
  List all council decisions rendered so far.
  """
  @callback list_all_decisions() :: [CouncilDecision.t()]

  @doc """
  Get recent decisions ordered most-recent-first, up to the given limit.
  """
  @callback get_recent_decisions_with_limit(limit :: pos_integer()) :: [CouncilDecision.t()]

  # ===========================================================================
  # Management
  # ===========================================================================

  @doc """
  Cancel a pending proposal by its ID.

  Only proposals in `:pending` or `:evaluating` status can be cancelled.
  """
  @callback cancel_proposal_by_id(proposal_id()) ::
              :ok | {:error, :not_found | :already_decided}

  @doc """
  Force-approve a proposal via human override.

  Bypasses the normal evaluation process. The approver ID is recorded
  for audit purposes.
  """
  @callback force_approve_proposal_by_authority(
              proposal_id(),
              approver_id :: String.t()
            ) :: :ok | {:error, :not_found | :already_decided}

  @doc """
  Force-reject a proposal via human override.

  Bypasses the normal evaluation process. The rejector ID is recorded
  for audit purposes.
  """
  @callback force_reject_proposal_by_authority(
              proposal_id(),
              rejector_id :: String.t()
            ) :: :ok | {:error, :not_found | :already_decided}

  @doc """
  Get aggregate statistics about the consensus system.

  Returns counts of proposals by status and other system metrics.
  """
  @callback get_consensus_system_stats() :: stats()

  # ===========================================================================
  # Events
  # ===========================================================================

  @doc """
  Query consensus events using the given filters.

  ## Supported Filters

    * `:proposal_id` - Filter by proposal ID
    * `:event_type` - Filter by event type
    * `:agent_id` - Filter by agent ID
    * `:since` / `:until` - Time range boundaries
    * `:limit` - Maximum number of results (default: 100)
  """
  @callback query_consensus_events_with_filters(event_filters()) :: [ConsensusEvent.t()]

  @doc """
  Get all events associated with a specific proposal.
  """
  @callback get_events_for_proposal(proposal_id()) :: [ConsensusEvent.t()]

  @doc """
  Get a chronological timeline of events for a proposal.

  Returns tuples of `{sequence_number, event}` in order.
  """
  @callback get_timeline_for_proposal(proposal_id()) :: [timeline_entry()]

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the consensus system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the consensus system is running and healthy.
  """
  @callback healthy?() :: boolean()

  # ===========================================================================
  # Optional Callbacks
  # ===========================================================================

  @optional_callbacks [
    # Listing
    list_pending_proposals: 0,
    list_all_proposals: 0,
    list_all_decisions: 0,
    get_recent_decisions_with_limit: 1,
    # Management
    force_approve_proposal_by_authority: 2,
    force_reject_proposal_by_authority: 2,
    get_consensus_system_stats: 0,
    # Events
    query_consensus_events_with_filters: 1,
    get_events_for_proposal: 1,
    get_timeline_for_proposal: 1
  ]
end
