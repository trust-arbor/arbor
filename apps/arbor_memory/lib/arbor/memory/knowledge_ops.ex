defmodule Arbor.Memory.KnowledgeOps do
  @moduledoc """
  Sub-facade for knowledge graph and consolidation operations.

  Handles semantic knowledge graph CRUD, spreading activation,
  decay/pruning consolidation, and graph export/import.

  This module is not intended to be called directly by external consumers.
  Use `Arbor.Memory` as the public API.
  """

  alias Arbor.Memory.{
    Consolidation,
    GraphOps
  }

  # ============================================================================
  # Knowledge Graph Operations
  # ============================================================================

  @doc "Add a knowledge node to the agent's graph."
  defdelegate add_knowledge(agent_id, node_data), to: GraphOps

  @doc "Link two knowledge nodes."
  defdelegate link_knowledge(agent_id, source_id, target_id, relationship, opts \\ []),
    to: GraphOps

  @doc "Recall a knowledge node, reinforcing its relevance."
  defdelegate reinforce_knowledge(agent_id, node_id), to: GraphOps

  @doc "Search knowledge graph by content."
  defdelegate search_knowledge(agent_id, query, opts \\ []), to: GraphOps

  @doc "Find a knowledge node by name (case-insensitive exact match)."
  defdelegate find_knowledge_by_name(agent_id, name), to: GraphOps

  @doc "Get all pending proposals (facts and learnings awaiting approval)."
  defdelegate get_pending_proposals(agent_id), to: GraphOps

  @doc "Approve a pending fact or learning."
  defdelegate approve_pending(agent_id, pending_id), to: GraphOps

  @doc "Reject a pending fact or learning."
  defdelegate reject_pending(agent_id, pending_id), to: GraphOps

  @doc "Get knowledge graph statistics."
  defdelegate knowledge_stats(agent_id), to: GraphOps

  @doc "Trigger spreading activation from a node, boosting related nodes."
  defdelegate cascade_recall(agent_id, node_id, boost_amount, opts \\ []), to: GraphOps

  @doc "Get the lowest-relevance nodes approaching decay threshold."
  defdelegate near_threshold_nodes(agent_id, count \\ 10), to: GraphOps

  # ============================================================================
  # Consolidation (Decay and Pruning)
  # ============================================================================

  @doc "Run consolidation on the agent's knowledge graph."
  defdelegate consolidate(agent_id, opts \\ []), to: Consolidation, as: :consolidate_basic

  # ============================================================================
  # Enhanced Consolidation (Phase 3)
  # ============================================================================

  @doc "Run enhanced consolidation on the agent's knowledge graph."
  defdelegate run_consolidation(agent_id, opts \\ []), to: Consolidation, as: :run_enhanced

  @doc "Check if consolidation should run for an agent."
  defdelegate should_consolidate?(agent_id, opts \\ []), to: Consolidation, as: :should_run?

  @doc "Preview what consolidation would do without actually doing it."
  defdelegate preview_consolidation(agent_id, opts \\ []),
    to: Consolidation,
    as: :preview_for_agent

  # ============================================================================
  # Export / Import (for Seed capture & restore)
  # ============================================================================

  @doc "Export the full knowledge graph for an agent as a serializable map."
  defdelegate export_knowledge_graph(agent_id), to: GraphOps

  @doc "Import a knowledge graph from a serializable map."
  defdelegate import_knowledge_graph(agent_id, graph_map), to: GraphOps
end
