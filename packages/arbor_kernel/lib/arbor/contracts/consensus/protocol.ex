defmodule Arbor.Contracts.Consensus.Protocol do
  @moduledoc """
  Contract for the consensus protocol.

  The consensus system enables multi-agent agreement on system changes.
  It uses Byzantine fault-tolerant voting with independent evaluators
  spawned fresh for each proposal.

  ## Council Structure

  - 7 evaluators per council
  - 5/7 quorum for standard changes
  - 6/7 quorum for meta-changes (governance modifications)

  ## Evaluator Perspectives

  Each evaluator assesses from a different angle:
  - Security: vulnerability assessment
  - Stability: reliability impact
  - Capability: functionality changes
  - Adversarial: exploitation potential
  - Resource: efficiency impact
  - Emergence: novel behavior potential
  - Random: unpredictable fresh perspective

  ## Invariants

  For quorum calculations and invariant rules, see `Arbor.Contracts.Consensus.Invariants`.
  """

  alias Arbor.Contracts.Consensus.Invariants

  @type proposal_id :: String.t()
  @type agent_id :: String.t()
  @type vote :: :approve | :reject | :abstain
  @type decision :: :approved | :rejected | :deadlock

  @type proposal :: %{
          id: proposal_id(),
          proposer: agent_id(),
          change_type: change_type(),
          target_layer: layer(),
          description: String.t(),
          code_diff: String.t() | nil,
          metadata: map()
        }

  # Change types ordered by risk level (highest to lowest):
  # - governance_change: Changes to consensus system itself (6/7 quorum)
  # - capability_change: Security/permission changes (5/7 quorum)
  # - code_modification: Business logic changes (5/7 quorum)
  # - dependency_change: External dependency updates (5/7 quorum, extra scrutiny)
  # - configuration_change: Runtime config changes (5/7 quorum)
  # - layer_modification: Architecture layer changes (5/7 quorum)
  # - test_change: Test file modifications (4/7 quorum)
  # - documentation_change: Docs/README changes (4/7 quorum)
  @type change_type ::
          :code_modification
          | :capability_change
          | :configuration_change
          | :governance_change
          | :layer_modification
          | :documentation_change
          | :test_change
          | :dependency_change

  @type layer :: 0 | 1 | 2 | 3 | 4

  @type evaluator_perspective ::
          :security
          | :stability
          | :capability
          | :adversarial
          | :resource
          | :emergence
          | :random
          | :test_runner
          | :code_review
          | :human

  @type evaluation :: %{
          evaluator_id: agent_id(),
          perspective: evaluator_perspective(),
          vote: vote(),
          reasoning: String.t(),
          confidence: float(),
          concerns: [String.t()],
          timestamp: DateTime.t()
        }

  @type council_decision :: %{
          proposal_id: proposal_id(),
          decision: decision(),
          votes: %{
            approve: non_neg_integer(),
            reject: non_neg_integer(),
            abstain: non_neg_integer()
          },
          evaluations: [evaluation()],
          quorum_met: boolean(),
          decided_at: DateTime.t()
        }

  # Callbacks

  @doc """
  Submit a proposal for consensus evaluation.
  """
  @callback propose(proposal()) :: {:ok, proposal_id()} | {:error, term()}

  @doc """
  Get the current status of a proposal.
  """
  @callback get_proposal_status(proposal_id()) ::
              {:ok, :pending | :evaluating | :decided} | {:error, :not_found}

  @doc """
  Get the final decision for a proposal.
  """
  @callback get_decision(proposal_id()) :: {:ok, council_decision()} | {:error, term()}

  @doc """
  Spawn a fresh council of evaluators for a proposal.
  """
  @callback spawn_council(proposal()) :: {:ok, [pid()]} | {:error, term()}

  @doc """
  Check if a change type requires elevated quorum.
  """
  @callback requires_supermajority?(change_type()) :: boolean()

  @doc """
  Get the required quorum for a change type.
  """
  @callback quorum_for(change_type()) :: non_neg_integer()

  @doc """
  Check if a proposal violates immutable invariants.
  """
  @callback violates_invariants?(proposal()) :: boolean()

  # ===========================================================================
  # Helper Functions - Delegating to Invariants
  # ===========================================================================

  # Module name patterns mapped to architecture layers.
  # Layer 1: Governance, Layer 2: Core Systems, Layer 3: Shared Infrastructure
  @layer_patterns [
    {"Consensus", 1},
    {"Trust.Manager", 1},
    {"Security.Kernel", 1},
    {"Supervisor", 2},
    {"Registry", 2},
    {"Gateway", 2},
    {"Arbor.Security", 3},
    {"Arbor.Signals", 3}
  ]

  @doc """
  Returns the council size.

  Delegates to `Arbor.Contracts.Consensus.Invariants.council_size/0`.
  """
  @spec council_size() :: 7
  defdelegate council_size(), to: Invariants

  @doc """
  Returns the standard quorum requirement.

  Delegates to `Arbor.Contracts.Consensus.Invariants.standard_quorum/0`.
  """
  @spec standard_quorum() :: 5
  defdelegate standard_quorum(), to: Invariants

  @doc """
  Returns the meta-change quorum requirement.

  Delegates to `Arbor.Contracts.Consensus.Invariants.meta_quorum/0`.
  """
  @spec meta_quorum() :: 6
  defdelegate meta_quorum(), to: Invariants

  @doc """
  Returns the low-risk change quorum requirement.

  Delegates to `Arbor.Contracts.Consensus.Invariants.low_risk_quorum/0`.
  """
  @spec low_risk_quorum() :: 4
  defdelegate low_risk_quorum(), to: Invariants

  @doc """
  All evaluator perspectives.
  """
  @spec perspectives() :: [
          :security | :stability | :capability | :adversarial | :resource | :emergence | :random,
          ...
        ]
  def perspectives do
    [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random,
      :test_runner,
      :code_review,
      :human
    ]
  end

  @doc """
  Get the required quorum for a change type.

  Delegates to `Arbor.Contracts.Consensus.Invariants.quorum_for_change_type/1`.
  """
  @spec quorum_for_change_type(change_type()) :: non_neg_integer()
  defdelegate quorum_for_change_type(change_type), to: Invariants

  @doc """
  Check if a decision meets quorum.

  Delegates to `Arbor.Contracts.Consensus.Invariants.meets_quorum?/2`.
  """
  @spec meets_quorum?(non_neg_integer(), change_type()) :: boolean()
  defdelegate meets_quorum?(approve_count, change_type), to: Invariants

  @doc """
  Check if a change type is a meta-change (governance modification).

  Delegates to `Arbor.Contracts.Consensus.Invariants.meta_change?/1`.
  """
  @spec meta_change?(change_type()) :: boolean()
  defdelegate meta_change?(change_type), to: Invariants

  @doc """
  Check if a change type is a low-risk change (documentation, tests).

  Delegates to `Arbor.Contracts.Consensus.Invariants.low_risk_change?/1`.
  """
  @spec low_risk_change?(change_type()) :: boolean()
  defdelegate low_risk_change?(change_type), to: Invariants

  @doc """
  Determine which layer a module belongs to.
  """
  @spec layer_for_module(module()) :: 1 | 2 | 3 | 4
  def layer_for_module(module) do
    module_string = to_string(module)

    @layer_patterns
    |> Enum.find_value(fn {pattern, layer} ->
      if String.contains?(module_string, pattern), do: layer
    end)
    # Layer 4: Agent Sandboxes (default)
    |> Kernel.||(4)
  end

  @doc """
  Immutable invariants that cannot be changed.

  Delegates to `Arbor.Contracts.Consensus.Invariants.immutable_invariants/0`.
  """
  @spec immutable_invariants() :: [atom()]
  defdelegate immutable_invariants(), to: Invariants
end
