defmodule Arbor.Contracts.Consensus.Invariants do
  @moduledoc """
  Invariants for the consensus system.

  This module centralizes the hardcoded invariants that govern consensus
  decisions: council size, quorum requirements, and immutable system rules.

  ## Council Structure

  - 7 evaluators per council
  - 6/7 quorum for meta-changes (governance modifications)
  - 5/7 quorum for standard changes
  - 4/7 quorum for low-risk changes (documentation, tests)

  ## Immutable Invariants

  These invariants cannot be violated by any proposal:
  - `:consensus_requires_quorum` — All decisions require proper quorum
  - `:evaluators_are_independent` — Evaluators cannot influence each other
  - `:containment_boundary_exists` — Security boundaries are enforced
  - `:audit_log_append_only` — Audit logs cannot be modified or deleted
  - `:layer_hierarchy_enforced` — Architecture layers are respected

  ## Usage

      # Check quorum requirements
      quorum = Invariants.quorum_for_change_type(:governance_change)
      # => 6

      # Check if a change is a meta-change
      Invariants.meta_change?(:governance_change)
      # => true

      # Get the list of immutable invariants
      Invariants.immutable_invariants()
      # => [:consensus_requires_quorum, ...]
  """

  # ===========================================================================
  # Council Constants
  # ===========================================================================

  @council_size 7
  @meta_quorum 6
  @standard_quorum 5
  @low_risk_quorum 4

  # ===========================================================================
  # Public API
  # ===========================================================================

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
  Get the required quorum for a change type.

  Returns the number of approvals needed:
  - 6/7 for governance changes (meta-changes)
  - 5/7 for standard changes (code, capabilities, config, dependencies)
  - 4/7 for low-risk changes (documentation, tests)
  """
  @spec quorum_for_change_type(atom()) :: non_neg_integer()
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
  @spec meets_quorum?(non_neg_integer(), atom()) :: boolean()
  def meets_quorum?(approve_count, change_type) do
    approve_count >= quorum_for_change_type(change_type)
  end

  @doc """
  Check if a change type is a meta-change (governance modification).
  """
  @spec meta_change?(atom()) :: boolean()
  def meta_change?(:governance_change), do: true
  def meta_change?(:topic_governance), do: true
  def meta_change?(_), do: false

  @doc """
  Check if a change type is a low-risk change (documentation, tests).
  """
  @spec low_risk_change?(atom()) :: boolean()
  def low_risk_change?(:documentation_change), do: true
  def low_risk_change?(:test_change), do: true
  def low_risk_change?(_), do: false

  @doc """
  Immutable invariants that cannot be changed.

  These are the fundamental rules that govern the consensus system.
  Any proposal that would violate these invariants must be rejected.
  """
  @spec immutable_invariants() :: [atom()]
  def immutable_invariants do
    [
      :consensus_requires_quorum,
      :evaluators_are_independent,
      :containment_boundary_exists,
      :audit_log_append_only,
      :layer_hierarchy_enforced
    ]
  end

  @doc """
  Patterns that indicate an attempt to violate invariants.

  Used for heuristic detection in proposals.
  """
  @spec violation_patterns() :: [String.t()]
  def violation_patterns do
    [
      "quorum = 0",
      "bypass_boundary",
      "clear_log",
      "remove_layer",
      "delete_audit",
      "skip_consensus"
    ]
  end
end
