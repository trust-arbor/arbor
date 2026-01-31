defmodule Arbor.Memory do
  @moduledoc """
  Public API facade for the Arbor memory system.

  Provides a unified interface for all memory operations, including:
  - Vector-based semantic search (Index)
  - Semantic knowledge graph (KnowledgeGraph)
  - Token budget management (TokenBudget)
  - Signal emissions and event logging

  ## Agent-Agnostic Design

  All functions take `agent_id` as the first parameter. The facade is completely
  agent-type agnostic — whether the caller is a native Jido agent (direct Elixir
  call) or a bridged agent (via gateway HTTP), the same functions are used.

  ## Quick Start

      # Initialize memory for an agent
      {:ok, _pid} = Arbor.Memory.init_for_agent("agent_001")

      # Index content
      {:ok, entry_id} = Arbor.Memory.index("agent_001", "Important fact", %{type: :fact})

      # Recall similar content
      {:ok, results} = Arbor.Memory.recall("agent_001", "fact query")

      # Add to knowledge graph
      {:ok, node_id} = Arbor.Memory.add_knowledge("agent_001", %{
        type: :fact,
        content: "The sky is blue"
      })

      # Cleanup when done
      :ok = Arbor.Memory.cleanup_for_agent("agent_001")

  ## Architecture

  The memory system consists of:

  1. **Index** - ETS-backed vector storage for fast semantic search
  2. **KnowledgeGraph** - Semantic network with decay and reinforcement
  3. **Signals** - Transient operational notifications
  4. **Events** - Permanent history records
  5. **TokenBudget** - Model-agnostic budget allocation

  See the module docs for each component for details.
  """

  alias Arbor.Memory.{
    Events,
    Index,
    IndexSupervisor,
    KnowledgeGraph,
    Retrieval,
    Signals,
    Summarizer,
    TokenBudget,
    WorkingMemory
  }

  require Logger

  # State storage for knowledge graphs (agent_id => KnowledgeGraph.t())
  # In production, this would be backed by a GenServer or persistence
  @graph_ets :arbor_memory_graphs

  # State storage for working memory (agent_id => WorkingMemory.t())
  @working_memory_ets :arbor_working_memory

  # ============================================================================
  # Agent Lifecycle
  # ============================================================================

  @doc """
  Initialize memory for an agent.

  Creates an isolated memory index and knowledge graph for the agent.
  Should be called when an agent starts.

  ## Options

  - `:max_entries` - Max entries in the index before LRU eviction
  - `:threshold` - Default similarity threshold for recall
  - `:decay_rate` - How fast knowledge graph nodes decay
  - `:index_enabled` - Whether to enable vector index (default: true)
  - `:graph_enabled` - Whether to enable knowledge graph (default: true)

  ## Examples

      {:ok, pid} = Arbor.Memory.init_for_agent("agent_001")
      {:ok, pid} = Arbor.Memory.init_for_agent("agent_001", max_entries: 5000)
  """
  @spec init_for_agent(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def init_for_agent(agent_id, opts \\ []) do
    # Merge caller opts with application config defaults
    opts = merge_config_defaults(opts)

    # Start index if enabled
    index_enabled = Keyword.get(opts, :index_enabled, true)
    graph_enabled = Keyword.get(opts, :graph_enabled, true)

    index_result =
      if index_enabled do
        IndexSupervisor.start_index(agent_id, opts)
      else
        {:ok, nil}
      end

    # Initialize knowledge graph if enabled
    if graph_enabled do
      graph = KnowledgeGraph.new(agent_id, opts)
      :ets.insert(@graph_ets, {agent_id, graph})
    end

    # Emit initialization signal
    Signals.emit_memory_initialized(agent_id, %{
      index_enabled: index_enabled,
      graph_enabled: graph_enabled
    })

    Logger.debug("Initialized memory for agent #{agent_id}")
    index_result
  end

  @doc """
  Cleanup memory for an agent.

  Stops the index and removes the knowledge graph.
  Should be called when an agent stops.

  ## Examples

      :ok = Arbor.Memory.cleanup_for_agent("agent_001")
  """
  @spec cleanup_for_agent(String.t()) :: :ok
  def cleanup_for_agent(agent_id) do
    # Stop index
    IndexSupervisor.stop_index(agent_id)

    # Remove knowledge graph
    :ets.delete(@graph_ets, agent_id)

    # Remove working memory (Phase 2)
    delete_working_memory(agent_id)

    # Emit cleanup signal
    Signals.emit_memory_cleaned_up(agent_id)

    Logger.debug("Cleaned up memory for agent #{agent_id}")
    :ok
  end

  @doc """
  Check if memory is initialized for an agent.
  """
  @spec initialized?(String.t()) :: boolean()
  def initialized?(agent_id) do
    IndexSupervisor.has_index?(agent_id) or has_graph?(agent_id)
  end

  # ============================================================================
  # Index Operations
  # ============================================================================

  @doc """
  Index content for semantic retrieval.

  Stores content with its embedding in the agent's memory index.

  ## Options

  - `:type` - Category type for the entry (atom)
  - `:source` - Source of the content
  - `:embedding` - Pre-computed embedding (skips embedding call)

  ## Examples

      {:ok, entry_id} = Arbor.Memory.index("agent_001", "Hello world", %{type: :fact})
  """
  @spec index(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def index(agent_id, content, metadata \\ %{}, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        result = Index.index(pid, content, metadata, opts)

        # Emit signal on success
        case result do
          {:ok, entry_id} ->
            Signals.emit_indexed(agent_id, %{
              entry_id: entry_id,
              type: metadata[:type],
              source: metadata[:source]
            })

            {:ok, entry_id}

          error ->
            error
        end

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  @doc """
  Recall content similar to query.

  Performs semantic search in the agent's memory index.

  ## Options

  - `:limit` - Max results to return (default: 10)
  - `:threshold` - Minimum similarity threshold (default: 0.3)
  - `:type` - Filter by entry type
  - `:types` - Filter by multiple types

  ## Examples

      {:ok, results} = Arbor.Memory.recall("agent_001", "greeting")
      {:ok, facts} = Arbor.Memory.recall("agent_001", "query", type: :fact, limit: 5)
  """
  @spec recall(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def recall(agent_id, query, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        result = Index.recall(pid, query, opts)

        # Emit signal on success
        case result do
          {:ok, results} ->
            top_similarity = if length(results) > 0, do: hd(results).similarity, else: nil

            Signals.emit_recalled(agent_id, query, length(results),
              top_similarity: top_similarity
            )

            {:ok, results}

          error ->
            error
        end

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  @doc """
  Index multiple items in a batch.

  ## Examples

      items = [{"Fact one", %{type: :fact}}, {"Fact two", %{type: :fact}}]
      {:ok, ids} = Arbor.Memory.batch_index("agent_001", items)
  """
  @spec batch_index(String.t(), [{String.t(), map()}], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def batch_index(agent_id, items, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        Index.batch_index(pid, items, opts)

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  @doc """
  Get statistics for an agent's index.
  """
  @spec index_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def index_stats(agent_id) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} -> {:ok, Index.stats(pid)}
      {:error, :not_found} -> {:error, :index_not_initialized}
    end
  end

  # ============================================================================
  # Knowledge Graph Operations
  # ============================================================================

  @doc """
  Add a knowledge node to the agent's graph.

  ## Node Data

  - `:type` - Node type (required): :fact, :experience, :skill, :insight, :relationship
  - `:content` - Node content (required)
  - `:relevance` - Initial relevance (optional, default: 1.0)
  - `:metadata` - Additional metadata (optional)
  - `:pinned` - Whether node is protected from decay (optional)

  ## Examples

      {:ok, node_id} = Arbor.Memory.add_knowledge("agent_001", %{
        type: :fact,
        content: "Paris is the capital of France"
      })
  """
  @spec add_knowledge(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def add_knowledge(agent_id, node_data) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, node_id} <- KnowledgeGraph.add_node(graph, node_data) do
      save_graph(agent_id, new_graph)

      # Emit signal
      Signals.emit_knowledge_added(agent_id, node_id, node_data[:type])

      {:ok, node_id}
    end
  end

  @doc """
  Link two knowledge nodes.

  ## Examples

      {:ok, _} = Arbor.Memory.link_knowledge("agent_001", node_a, node_b, :supports)
  """
  @spec link_knowledge(String.t(), String.t(), String.t(), atom(), keyword()) ::
          :ok | {:error, term()}
  def link_knowledge(agent_id, source_id, target_id, relationship, opts \\ []) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph} <-
           KnowledgeGraph.add_edge(graph, source_id, target_id, relationship, opts) do
      save_graph(agent_id, new_graph)

      # Emit signal
      Signals.emit_knowledge_linked(agent_id, source_id, target_id, relationship)

      :ok
    end
  end

  @doc """
  Recall a knowledge node, reinforcing its relevance.
  """
  @spec reinforce_knowledge(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def reinforce_knowledge(agent_id, node_id) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, node} <- KnowledgeGraph.reinforce(graph, node_id) do
      save_graph(agent_id, new_graph)
      {:ok, node}
    end
  end

  @doc """
  Search knowledge graph by content.
  """
  @spec search_knowledge(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search_knowledge(agent_id, query, opts \\ []) do
    with {:ok, graph} <- get_graph(agent_id) do
      KnowledgeGraph.recall(graph, query, opts)
    end
  end

  @doc """
  Get all pending proposals (facts and learnings awaiting approval).
  """
  @spec get_pending_proposals(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_pending_proposals(agent_id) do
    with {:ok, graph} <- get_graph(agent_id) do
      {:ok, KnowledgeGraph.get_pending(graph)}
    end
  end

  @doc """
  Approve a pending fact or learning.
  """
  @spec approve_pending(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def approve_pending(agent_id, pending_id) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, node_id} <- KnowledgeGraph.approve_pending(graph, pending_id) do
      save_graph(agent_id, new_graph)

      # Emit signal
      Signals.emit_pending_approved(agent_id, pending_id, node_id)

      {:ok, node_id}
    end
  end

  @doc """
  Reject a pending fact or learning.
  """
  @spec reject_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def reject_pending(agent_id, pending_id) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph} <- KnowledgeGraph.reject_pending(graph, pending_id) do
      save_graph(agent_id, new_graph)

      # Emit signal
      Signals.emit_pending_rejected(agent_id, pending_id)

      :ok
    end
  end

  @doc """
  Get knowledge graph statistics.
  """
  @spec knowledge_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def knowledge_stats(agent_id) do
    with {:ok, graph} <- get_graph(agent_id) do
      {:ok, KnowledgeGraph.stats(graph)}
    end
  end

  # ============================================================================
  # Consolidation (Decay and Pruning)
  # ============================================================================

  @doc """
  Run consolidation on the agent's knowledge graph.

  Consolidation applies decay to all non-pinned nodes and prunes
  nodes that fall below the relevance threshold.

  ## Options

  - `:prune_threshold` - Override the default prune threshold

  Returns metrics about what was consolidated.
  """
  @spec consolidate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate(agent_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    # Emit start signal
    Signals.emit_consolidation_started(agent_id)

    with {:ok, graph} <- get_graph(agent_id) do
      # Apply decay
      decayed_graph = KnowledgeGraph.decay(graph)
      decayed_count = map_size(graph.nodes)

      # Prune
      threshold = Keyword.get(opts, :prune_threshold, 0.1)
      {pruned_graph, pruned_count} = KnowledgeGraph.prune(decayed_graph, threshold)

      # Save
      save_graph(agent_id, pruned_graph)

      # Calculate duration
      duration_ms = System.monotonic_time(:millisecond) - start_time

      # Get final stats
      stats = KnowledgeGraph.stats(pruned_graph)

      metrics = %{
        decayed_count: decayed_count,
        pruned_count: pruned_count,
        duration_ms: duration_ms,
        total_nodes: stats.node_count,
        average_relevance: stats.average_relevance
      }

      # Emit signals
      Signals.emit_consolidation_completed(agent_id, metrics)
      Signals.emit_knowledge_decayed(agent_id, stats)

      if pruned_count > 0 do
        Signals.emit_knowledge_pruned(agent_id, pruned_count)
      end

      # Record permanent event
      Events.record_consolidation_completed(agent_id, metrics)

      {:ok, metrics}
    end
  end

  # ============================================================================
  # Token Budget Delegation
  # ============================================================================

  @doc """
  Resolve a token budget specification.

  See `Arbor.Memory.TokenBudget.resolve/2` for details.
  """
  defdelegate resolve_budget(budget, context_size), to: TokenBudget, as: :resolve

  @doc """
  Resolve a token budget for a specific model.

  See `Arbor.Memory.TokenBudget.resolve_for_model/2` for details.
  """
  defdelegate resolve_budget_for_model(budget, model_id), to: TokenBudget, as: :resolve_for_model

  @doc """
  Estimate tokens in text.

  See `Arbor.Memory.TokenBudget.estimate_tokens/1` for details.
  """
  defdelegate estimate_tokens(text), to: TokenBudget

  @doc """
  Get model context size.

  See `Arbor.Memory.TokenBudget.model_context_size/1` for details.
  """
  defdelegate model_context_size(model_id), to: TokenBudget

  # ============================================================================
  # Working Memory (Phase 2)
  # ============================================================================

  @doc """
  Get working memory for an agent.

  Returns the current working memory or nil if not set.

  ## Examples

      wm = Arbor.Memory.get_working_memory("agent_001")
  """
  @spec get_working_memory(String.t()) :: WorkingMemory.t() | nil
  def get_working_memory(agent_id) do
    case :ets.lookup(@working_memory_ets, agent_id) do
      [{^agent_id, wm}] -> wm
      [] -> nil
    end
  end

  @doc """
  Save working memory for an agent.

  Stores the working memory in ETS (Phase 2) or Postgres (Phase 6+).

  ## Examples

      wm = WorkingMemory.new("agent_001")
      :ok = Arbor.Memory.save_working_memory("agent_001", wm)
  """
  @spec save_working_memory(String.t(), WorkingMemory.t()) :: :ok
  def save_working_memory(agent_id, working_memory) do
    :ets.insert(@working_memory_ets, {agent_id, working_memory})
    Signals.emit_working_memory_saved(agent_id, WorkingMemory.stats(working_memory))
    :ok
  end

  @doc """
  Load working memory for an agent.

  Returns existing working memory or creates a new one if none exists.
  This is the primary entry point for session startup.

  ## Examples

      wm = Arbor.Memory.load_working_memory("agent_001")
  """
  @spec load_working_memory(String.t(), keyword()) :: WorkingMemory.t()
  def load_working_memory(agent_id, opts \\ []) do
    case get_working_memory(agent_id) do
      nil ->
        wm = WorkingMemory.new(agent_id, opts)
        save_working_memory(agent_id, wm)
        Signals.emit_working_memory_loaded(agent_id, :created)
        wm

      wm ->
        Signals.emit_working_memory_loaded(agent_id, :existing)
        wm
    end
  end

  @doc """
  Delete working memory for an agent.

  Called during cleanup.
  """
  @spec delete_working_memory(String.t()) :: :ok
  def delete_working_memory(agent_id) do
    :ets.delete(@working_memory_ets, agent_id)
    :ok
  end

  # ============================================================================
  # Retrieval (Phase 2)
  # ============================================================================

  @doc """
  Semantic recall with human-readable formatting for LLM context injection.

  Delegates to `Arbor.Memory.Retrieval.let_me_recall/3`.

  ## Options

  - `:limit` - Max results (default: 10)
  - `:threshold` - Min similarity (default: 0.3)
  - `:max_tokens` - Max tokens in output (default: 500)
  - `:type` / `:types` - Type filtering

  ## Examples

      {:ok, text} = Arbor.Memory.let_me_recall("agent_001", "elixir patterns")
  """
  @spec let_me_recall(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate let_me_recall(agent_id, query, opts \\ []), to: Retrieval

  # ============================================================================
  # Context Building (Phase 2)
  # ============================================================================

  @doc """
  Build combined context for LLM injection.

  Combines working memory and optional relationship context into
  formatted text suitable for system prompt injection.

  ## Options

  - `:max_thoughts` - Max recent thoughts to include (default: 5)
  - `:include_relationship` - Include relationship context (default: true)

  ## Examples

      wm = Arbor.Memory.load_working_memory("agent_001")
      context = Arbor.Memory.build_context(wm)
      context = Arbor.Memory.build_context(wm, relationship: "Close collaborator...")
  """
  @spec build_context(WorkingMemory.t(), keyword()) :: String.t()
  def build_context(working_memory, opts \\ []) do
    relationship = Keyword.get(opts, :relationship)

    # If relationship provided in opts, set it on working memory first
    wm =
      if relationship do
        WorkingMemory.set_relationship_context(working_memory, relationship)
      else
        working_memory
      end

    WorkingMemory.to_prompt_text(wm, opts)
  end

  # ============================================================================
  # Summarization (Phase 2)
  # ============================================================================

  @doc """
  Summarize text with complexity-based model routing.

  Delegates to `Arbor.Memory.Summarizer.summarize/2`.

  Note: Returns `{:error, :llm_not_configured}` until arbor_ai integration.

  ## Examples

      {:error, {:llm_not_configured, info}} = Arbor.Memory.summarize("agent_001", text)
  """
  @spec summarize(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def summarize(_agent_id, text, opts \\ []) do
    # Currently always returns error until LLM integration.
    # When arbor_ai is wired in, this will emit context_summarized signal
    # on success via: Signals.emit_context_summarized(agent_id, info)
    Summarizer.summarize(text, opts)
  end

  @doc """
  Assess complexity of text.

  Delegates to `Arbor.Memory.Summarizer.assess_complexity/1`.

  ## Examples

      :moderate = Arbor.Memory.assess_complexity("Some technical text...")
  """
  @spec assess_complexity(String.t()) :: Summarizer.complexity()
  defdelegate assess_complexity(text), to: Summarizer

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Merge caller-provided opts with application config defaults.
  # Caller opts take precedence over config.
  defp merge_config_defaults(opts) do
    defaults = [
      max_entries: Application.get_env(:arbor_memory, :index_max_entries, 10_000),
      threshold: Application.get_env(:arbor_memory, :index_default_threshold, 0.3),
      decay_rate: Application.get_env(:arbor_memory, :kg_default_decay_rate, 0.10),
      max_nodes_per_type: Application.get_env(:arbor_memory, :kg_max_nodes_per_type, 500)
    ]

    Keyword.merge(defaults, opts)
  end

  # Graph ETS table is created eagerly in Application.start/2
  # to avoid race conditions from lazy initialization.

  defp get_graph(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :graph_not_initialized}
    end
  end

  defp save_graph(agent_id, graph) do
    :ets.insert(@graph_ets, {agent_id, graph})
    :ok
  end

  defp has_graph?(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, _}] -> true
      [] -> false
    end
  end
end
