defmodule Arbor.Contracts.Memory.Types do
  @moduledoc """
  Type definitions for the Arbor memory system.

  These types are used across the memory system for consistent
  representation of memory entries, knowledge nodes, and related data.

  ## Memory Entry

  A memory entry represents indexed content in the vector store:

      %{
        id: "mem_abc123",
        content: "The sky is blue",
        type: :fact,
        similarity: 0.85,
        timestamp: ~U[2025-01-15 10:00:00Z]
      }

  ## Knowledge Node

  A knowledge node represents a piece of knowledge in the semantic graph:

      %{
        id: "node_xyz789",
        type: :fact,
        content: "Paris is the capital of France",
        relevance: 0.95,
        access_count: 5,
        created_at: ~U[2025-01-10 10:00:00Z],
        last_accessed: ~U[2025-01-15 10:00:00Z]
      }
  """

  # ============================================================================
  # Memory Entry Types (Index)
  # ============================================================================

  @typedoc """
  Unique identifier for a memory entry.
  """
  @type entry_id :: String.t()

  @typedoc """
  Type/category of a memory entry.
  """
  @type entry_type :: :fact | :experience | :skill | :insight | :relationship | :custom

  @typedoc """
  A memory entry returned from recall operations.
  """
  @type memory_entry :: %{
          id: entry_id(),
          content: String.t(),
          type: entry_type(),
          similarity: float(),
          timestamp: DateTime.t()
        }

  @typedoc """
  Full memory entry with all metadata (internal representation).
  """
  @type memory_entry_full :: %{
          id: entry_id(),
          content: String.t(),
          embedding: [float()],
          metadata: map(),
          indexed_at: DateTime.t(),
          accessed_at: DateTime.t(),
          access_count: non_neg_integer()
        }

  # ============================================================================
  # Knowledge Graph Types
  # ============================================================================

  @typedoc """
  Unique identifier for a knowledge node.
  """
  @type node_id :: String.t()

  @typedoc """
  Unique identifier for a knowledge edge.
  """
  @type edge_id :: String.t()

  @typedoc """
  Type of a knowledge node.
  """
  @type node_type :: :fact | :experience | :skill | :insight | :relationship | :custom

  @typedoc """
  A knowledge node in the semantic graph.
  """
  @type knowledge_node :: %{
          id: node_id(),
          type: node_type(),
          content: String.t(),
          relevance: float(),
          access_count: non_neg_integer(),
          created_at: DateTime.t(),
          last_accessed: DateTime.t(),
          metadata: map(),
          pinned: boolean()
        }

  @typedoc """
  An edge connecting two knowledge nodes.
  """
  @type knowledge_edge :: %{
          id: edge_id(),
          source_id: node_id(),
          target_id: node_id(),
          relationship: atom(),
          strength: float(),
          created_at: DateTime.t()
        }

  @typedoc """
  Relationship types between knowledge nodes.
  """
  @type relationship_type ::
          :supports
          | :contradicts
          | :relates_to
          | :derived_from
          | :example_of
          | :part_of
          | :causes
          | :follows
          | atom()

  # ============================================================================
  # Pending Item Types (Proposal Queue)
  # ============================================================================

  @typedoc """
  Unique identifier for a pending proposal.
  """
  @type pending_id :: String.t()

  @typedoc """
  Type of pending item.
  """
  @type pending_type :: :fact | :learning

  @typedoc """
  A pending item awaiting agent approval.
  """
  @type pending_item :: %{
          id: pending_id(),
          type: pending_type(),
          content: String.t(),
          confidence: float(),
          source: String.t() | nil,
          extracted_at: DateTime.t(),
          metadata: map()
        }

  # ============================================================================
  # Token Budget Types
  # ============================================================================

  @typedoc """
  Model identifier in provider:model format.
  """
  @type model_id :: String.t()

  @typedoc """
  Token budget specification.

  - `{:fixed, count}` - Exact token count
  - `{:percentage, pct}` - Percentage of context window (0.0-1.0)
  - `{:min_max, min, max, pct}` - Percentage with floor and ceiling
  """
  @type token_budget ::
          {:fixed, non_neg_integer()}
          | {:percentage, float()}
          | {:min_max, non_neg_integer(), non_neg_integer(), float()}

  # ============================================================================
  # Memory Statistics Types
  # ============================================================================

  @typedoc """
  Statistics for a memory index.
  """
  @type index_stats :: %{
          agent_id: String.t(),
          entry_count: non_neg_integer(),
          max_entries: non_neg_integer(),
          default_threshold: float()
        }

  @typedoc """
  Statistics for a knowledge graph.
  """
  @type graph_stats :: %{
          agent_id: String.t(),
          node_count: non_neg_integer(),
          nodes_by_type: %{node_type() => non_neg_integer()},
          edge_count: non_neg_integer(),
          average_relevance: float(),
          pending_facts: non_neg_integer(),
          pending_learnings: non_neg_integer(),
          config: map()
        }

  @typedoc """
  Consolidation metrics.
  """
  @type consolidation_metrics :: %{
          decayed_count: non_neg_integer(),
          pruned_count: non_neg_integer(),
          duration_ms: non_neg_integer(),
          total_nodes: non_neg_integer(),
          average_relevance: float()
        }
end
