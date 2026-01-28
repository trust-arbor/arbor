defmodule Arbor.Contracts.Consensus.Protocol do
  @moduledoc """
  Contract for the autonomous consensus protocol.

  The consensus system enables multi-agent agreement on system changes
  without human oversight. It uses Byzantine fault-tolerant voting
  with independent evaluators spawned fresh for each proposal.

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
  """

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
  # - test_change: Test file modifications (3/7 quorum)
  # - documentation_change: Docs/README changes (3/7 quorum)
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

  # Helper functions

  @council_size 7
  @meta_quorum 6
  @standard_quorum 5
  # 4/7 = majority for low-risk changes
  @low_risk_quorum 4

  @doc """
  Returns the council size.
  """
  @spec council_size() :: 7
  def council_size, do: @council_size

  @doc """
  Returns the standard quorum requirement.
  """
  @spec standard_quorum() :: 5
  def standard_quorum, do: @standard_quorum

  @doc """
  Returns the meta-change quorum requirement.
  """
  @spec meta_quorum() :: 6
  def meta_quorum, do: @meta_quorum

  @doc """
  Returns the low-risk change quorum requirement.
  """
  @spec low_risk_quorum() :: 4
  def low_risk_quorum, do: @low_risk_quorum

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

  Returns the number of approvals needed:
  - 6/7 for governance changes (meta-changes)
  - 5/7 for standard changes (code, capabilities, config, dependencies)
  - 3/7 for low-risk changes (documentation, tests)
  """
  @spec quorum_for_change_type(change_type()) :: non_neg_integer()
  def quorum_for_change_type(change_type) do
    cond do
      meta_change?(change_type) -> @meta_quorum
      low_risk_change?(change_type) -> @low_risk_quorum
      true -> @standard_quorum
    end
  end

  @doc """
  Check if a decision meets quorum.
  """
  @spec meets_quorum?(non_neg_integer(), change_type()) :: boolean()
  def meets_quorum?(approve_count, change_type) do
    approve_count >= quorum_for_change_type(change_type)
  end

  @doc """
  Check if a change type is a meta-change (governance modification).
  """
  @spec meta_change?(change_type()) :: boolean()
  def meta_change?(:governance_change), do: true
  def meta_change?(_), do: false

  @doc """
  Check if a change type is a low-risk change (documentation, tests).
  """
  @spec low_risk_change?(change_type()) :: boolean()
  def low_risk_change?(:documentation_change), do: true
  def low_risk_change?(:test_change), do: true
  def low_risk_change?(_), do: false

  @doc """
  Determine which layer a module belongs to.
  """
  @spec layer_for_module(module()) :: 1 | 2 | 3 | 4
  def layer_for_module(module) do
    module_string = to_string(module)

    cond do
      # Layer 1: Governance
      String.contains?(module_string, "Consensus") -> 1
      String.contains?(module_string, "Trust.Manager") -> 1
      String.contains?(module_string, "CapabilityKernel") -> 1
      # Layer 2: Core Systems
      String.contains?(module_string, "Supervisor") -> 2
      String.contains?(module_string, "Registry") -> 2
      String.contains?(module_string, "Gateway") -> 2
      # Layer 3: Shared Infrastructure
      String.contains?(module_string, "Arbor.Core") -> 3
      String.contains?(module_string, "Arbor.Security") -> 3
      # Layer 4: Agent Sandboxes (default)
      true -> 4
    end
  end

  @doc """
  Immutable invariants that cannot be changed.
  """
  @spec immutable_invariants() :: [
          :consensus_requires_quorum
          | :evaluators_are_independent
          | :containment_boundary_exists
          | :audit_log_append_only
          | :layer_hierarchy_enforced,
          ...
        ]
  def immutable_invariants do
    [
      :consensus_requires_quorum,
      :evaluators_are_independent,
      :containment_boundary_exists,
      :audit_log_append_only,
      :layer_hierarchy_enforced
    ]
  end
end
