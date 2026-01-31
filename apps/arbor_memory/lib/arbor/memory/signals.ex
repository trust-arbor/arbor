defmodule Arbor.Memory.Signals do
  @moduledoc """
  Transient signal emissions for memory operations.

  Emits signals to the arbor_signals bus for operational notifications.
  These are ephemeral, pub/sub signals stored in a circular buffer —
  designed for real-time observers, dashboards, and subconscious processors.

  ## Signal Categories

  All memory signals use category `:memory` with different types:

  | Signal Type | Purpose |
  |-------------|---------|
  | `:indexed` | Content was indexed |
  | `:recalled` | Content was recalled |
  | `:consolidation_started` | Consolidation cycle began |
  | `:consolidation_completed` | Consolidation cycle ended |
  | `:fact_extracted` | Fact was extracted (pending) |
  | `:knowledge_added` | Node added to knowledge graph |
  | `:knowledge_linked` | Nodes linked in knowledge graph |
  | `:knowledge_decayed` | Decay cycle completed |
  | `:knowledge_pruned` | Nodes were pruned |

  ## Examples

      # Emit an indexed signal
      :ok = Arbor.Memory.Signals.emit_indexed("agent_001", %{
        entry_id: "mem_123",
        type: :fact
      })

      # Subscribe to memory signals
      {:ok, _sub_id} = Arbor.Signals.subscribe("memory.*", fn signal ->
        IO.inspect(signal.data, label: "Memory event")
        :ok
      end)
  """

  @doc """
  Emit a signal when content is indexed.

  ## Metadata

  - `:entry_id` - The ID of the indexed entry
  - `:type` - The type of content indexed
  - `:source` - Source of the content (optional)
  """
  @spec emit_indexed(String.t(), map()) :: :ok
  def emit_indexed(agent_id, metadata) do
    Arbor.Signals.emit(:memory, :indexed, %{
      agent_id: agent_id,
      entry_id: metadata[:entry_id],
      type: metadata[:type],
      source: metadata[:source]
    })
  end

  @doc """
  Emit a signal when content is recalled.

  ## Metadata

  - `:query` - The recall query
  - `:result_count` - Number of results returned
  - `:top_similarity` - Highest similarity score (optional)
  """
  @spec emit_recalled(String.t(), String.t(), non_neg_integer(), keyword()) :: :ok
  def emit_recalled(agent_id, query, result_count, opts \\ []) do
    Arbor.Signals.emit(:memory, :recalled, %{
      agent_id: agent_id,
      query: query,
      result_count: result_count,
      top_similarity: Keyword.get(opts, :top_similarity)
    })
  end

  @doc """
  Emit a signal when consolidation starts.

  Consolidation is the process of decay, pruning, and archiving.
  """
  @spec emit_consolidation_started(String.t()) :: :ok
  def emit_consolidation_started(agent_id) do
    Arbor.Signals.emit(:memory, :consolidation_started, %{
      agent_id: agent_id,
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when consolidation completes.

  ## Metrics

  - `:decayed_count` - Nodes that had relevance reduced
  - `:pruned_count` - Nodes that were pruned
  - `:duration_ms` - How long consolidation took
  """
  @spec emit_consolidation_completed(String.t(), map()) :: :ok
  def emit_consolidation_completed(agent_id, metrics) do
    Arbor.Signals.emit(:memory, :consolidation_completed, %{
      agent_id: agent_id,
      decayed_count: metrics[:decayed_count],
      pruned_count: metrics[:pruned_count],
      duration_ms: metrics[:duration_ms],
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a fact is extracted (added to pending queue).
  """
  @spec emit_fact_extracted(String.t(), map()) :: :ok
  def emit_fact_extracted(agent_id, fact) do
    Arbor.Signals.emit(:memory, :fact_extracted, %{
      agent_id: agent_id,
      pending_id: fact[:id],
      content_preview: String.slice(fact[:content] || "", 0, 100),
      confidence: fact[:confidence],
      source: fact[:source]
    })
  end

  @doc """
  Emit a signal when a learning is extracted (added to pending queue).
  """
  @spec emit_learning_extracted(String.t(), map()) :: :ok
  def emit_learning_extracted(agent_id, learning) do
    Arbor.Signals.emit(:memory, :learning_extracted, %{
      agent_id: agent_id,
      pending_id: learning[:id],
      content_preview: String.slice(learning[:content] || "", 0, 100),
      confidence: learning[:confidence],
      source: learning[:source]
    })
  end

  @doc """
  Emit a signal when knowledge is added to the graph.
  """
  @spec emit_knowledge_added(String.t(), String.t(), atom()) :: :ok
  def emit_knowledge_added(agent_id, node_id, node_type) do
    Arbor.Signals.emit(:memory, :knowledge_added, %{
      agent_id: agent_id,
      node_id: node_id,
      node_type: node_type
    })
  end

  @doc """
  Emit a signal when knowledge nodes are linked.
  """
  @spec emit_knowledge_linked(String.t(), String.t(), String.t(), atom()) :: :ok
  def emit_knowledge_linked(agent_id, source_id, target_id, relationship) do
    Arbor.Signals.emit(:memory, :knowledge_linked, %{
      agent_id: agent_id,
      source_id: source_id,
      target_id: target_id,
      relationship: relationship
    })
  end

  @doc """
  Emit a signal when decay is applied to the knowledge graph.
  """
  @spec emit_knowledge_decayed(String.t(), map()) :: :ok
  def emit_knowledge_decayed(agent_id, stats) do
    Arbor.Signals.emit(:memory, :knowledge_decayed, %{
      agent_id: agent_id,
      node_count: stats[:node_count],
      average_relevance: stats[:average_relevance]
    })
  end

  @doc """
  Emit a signal when nodes are pruned from the knowledge graph.
  """
  @spec emit_knowledge_pruned(String.t(), non_neg_integer()) :: :ok
  def emit_knowledge_pruned(agent_id, pruned_count) do
    Arbor.Signals.emit(:memory, :knowledge_pruned, %{
      agent_id: agent_id,
      pruned_count: pruned_count
    })
  end

  @doc """
  Emit a signal when a pending item is approved.
  """
  @spec emit_pending_approved(String.t(), String.t(), String.t()) :: :ok
  def emit_pending_approved(agent_id, pending_id, node_id) do
    Arbor.Signals.emit(:memory, :pending_approved, %{
      agent_id: agent_id,
      pending_id: pending_id,
      node_id: node_id
    })
  end

  @doc """
  Emit a signal when a pending item is rejected.
  """
  @spec emit_pending_rejected(String.t(), String.t()) :: :ok
  def emit_pending_rejected(agent_id, pending_id) do
    Arbor.Signals.emit(:memory, :pending_rejected, %{
      agent_id: agent_id,
      pending_id: pending_id
    })
  end

  @doc """
  Emit a signal when memory is initialized for an agent.
  """
  @spec emit_memory_initialized(String.t(), map()) :: :ok
  def emit_memory_initialized(agent_id, opts \\ %{}) do
    Arbor.Signals.emit(:memory, :initialized, %{
      agent_id: agent_id,
      index_enabled: Map.get(opts, :index_enabled, true),
      graph_enabled: Map.get(opts, :graph_enabled, true)
    })
  end

  @doc """
  Emit a signal when memory is cleaned up for an agent.
  """
  @spec emit_memory_cleaned_up(String.t()) :: :ok
  def emit_memory_cleaned_up(agent_id) do
    Arbor.Signals.emit(:memory, :cleaned_up, %{
      agent_id: agent_id
    })
  end
end
