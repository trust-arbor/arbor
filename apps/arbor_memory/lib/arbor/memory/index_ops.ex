defmodule Arbor.Memory.IndexOps do
  @moduledoc """
  Sub-facade for index and embedding operations.

  Handles vector-based semantic search via the in-memory ETS index
  and persistent pgvector embeddings.

  This module is not intended to be called directly by external consumers.
  Use `Arbor.Memory` as the public API.
  """

  alias Arbor.Memory.{
    Embedding,
    Index,
    IndexSupervisor,
    Signals
  }

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
    with {:ok, pid} <- IndexSupervisor.get_index(agent_id),
         {:ok, results} <- Index.recall(pid, query, opts) do
      emit_recall_signal(agent_id, query, results)
      {:ok, results}
    else
      {:error, :not_found} -> {:error, :index_not_initialized}
      error -> error
    end
  end

  defp emit_recall_signal(agent_id, query, results) do
    top_similarity = if results != [], do: hd(results).similarity, else: nil

    Signals.emit_recalled(agent_id, query, length(results), top_similarity: top_similarity)
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
  # Persistent Embeddings (Phase 6)
  # ============================================================================

  @doc """
  Store an embedding in the persistent vector store (pgvector).

  This bypasses the in-memory index and writes directly to Postgres.
  Use for bulk imports or when you want persistent-only storage.

  ## Examples

      {:ok, id} = Arbor.Memory.store_embedding("agent_001", "Some fact", embedding, %{type: "fact"})
  """
  @spec store_embedding(String.t(), String.t(), [float()], map()) ::
          {:ok, String.t()} | {:error, term()}
  def store_embedding(agent_id, content, embedding, metadata \\ %{}) do
    Embedding.store(agent_id, content, embedding, metadata)
  end

  @doc """
  Search the persistent vector store directly.

  Bypasses the in-memory index and queries pgvector directly.

  ## Options

  - `:limit` -- max results (default 10)
  - `:threshold` -- minimum similarity 0.0-1.0 (default 0.3)
  - `:type_filter` -- filter by memory_type

  ## Examples

      {:ok, results} = Arbor.Memory.search_embeddings("agent_001", query_embedding)
  """
  @spec search_embeddings(String.t(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search_embeddings(agent_id, query_embedding, opts \\ []) do
    Embedding.search(agent_id, query_embedding, opts)
  end

  @doc """
  Get statistics for an agent's persistent embeddings.

  ## Examples

      stats = Arbor.Memory.embedding_stats("agent_001")
      #=> %{total: 100, by_type: %{"fact" => 50, ...}, oldest: ~U[...], newest: ~U[...]}
  """
  @spec embedding_stats(String.t()) :: map()
  def embedding_stats(agent_id) do
    Embedding.stats(agent_id)
  end

  @doc """
  Warm the in-memory index cache from persistent storage.

  Loads recent entries from pgvector into the ETS index.
  Only works when the index is running in `:dual` or `:pgvector` mode.

  ## Options

  - `:limit` -- Maximum entries to load (default: 1000)

  ## Examples

      :ok = Arbor.Memory.warm_index_cache("agent_001")
      :ok = Arbor.Memory.warm_index_cache("agent_001", limit: 500)
  """
  @spec warm_index_cache(String.t(), keyword()) :: :ok | {:error, term()}
  def warm_index_cache(agent_id, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        Index.warm_cache(pid, opts)

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end
end
