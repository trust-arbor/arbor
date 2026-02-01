defmodule Arbor.Memory.Embedding do
  @moduledoc """
  Postgres-backed vector storage using pgvector.

  Provides persistent semantic search that survives restarts.
  Used as the durable backend for the memory index, with ETS as hot cache.

  ## Features

  - Cosine similarity search via pgvector
  - Content deduplication by hash
  - Batch insert for efficiency
  - Type-based filtering

  ## Examples

      # Store an embedding
      {:ok, id} = Embedding.store("agent_001", "Hello world", [0.1, 0.2, ...], %{type: "fact"})

      # Search for similar content
      {:ok, results} = Embedding.search("agent_001", query_embedding, limit: 10, threshold: 0.5)

      # Get storage statistics
      stats = Embedding.stats("agent_001")
  """

  import Ecto.Query

  alias Arbor.Identifiers
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.MemoryEmbedding

  require Logger

  @doc """
  Store an embedding in Postgres.

  Deduplicates by content_hash — if an embedding for the same agent_id + content
  already exists, updates the existing record.

  ## Parameters

  - `agent_id` - The agent this embedding belongs to
  - `content` - The text content
  - `embedding` - Vector representation as list of floats
  - `metadata` - Optional metadata map with keys like :type, :source

  ## Examples

      {:ok, id} = Embedding.store("agent_001", "Some fact", [0.1, 0.2, ...])
      {:ok, id} = Embedding.store("agent_001", "Some fact", [0.1, 0.2, ...], %{type: "fact"})
  """
  @spec store(String.t(), String.t(), [float()], map()) ::
          {:ok, String.t()} | {:error, term()}
  def store(agent_id, content, embedding, metadata \\ %{}) do
    content_hash = compute_content_hash(content)
    # Allow caller to provide an ID (for dual-mode consistency with ETS)
    id = Map.get(metadata, :id) || Map.get(metadata, "id") || Identifiers.generate_id("emb_")

    attrs = %{
      id: id,
      agent_id: agent_id,
      content: content,
      content_hash: content_hash,
      embedding: Pgvector.new(embedding),
      memory_type: get_in(metadata, [:type]) || Map.get(metadata, "type"),
      source: get_in(metadata, [:source]) || Map.get(metadata, "source"),
      metadata: metadata
    }

    changeset = MemoryEmbedding.changeset(%MemoryEmbedding{}, attrs)

    # Upsert: on conflict with same agent_id + content_hash, update the embedding
    case Repo.insert(changeset,
           on_conflict: {:replace, [:embedding, :memory_type, :source, :metadata, :updated_at]},
           conflict_target: [:agent_id, :content_hash],
           returning: true
         ) do
      {:ok, record} ->
        Logger.debug("Stored embedding #{record.id} for agent #{agent_id}")
        {:ok, record.id}

      {:error, changeset} ->
        Logger.warning("Failed to store embedding: #{inspect(changeset.errors)}")
        {:error, changeset.errors}
    end
  end

  @doc """
  Search for similar embeddings using cosine distance.

  ## Options

  - `:limit` — max results (default 10)
  - `:threshold` — minimum similarity 0.0-1.0 (default 0.3)
  - `:type_filter` — filter by memory_type

  ## Examples

      {:ok, results} = Embedding.search("agent_001", query_embedding)
      {:ok, results} = Embedding.search("agent_001", query_embedding, limit: 5, threshold: 0.5)
  """
  @spec search(String.t(), [float()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(agent_id, query_embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.3)
    type_filter = Keyword.get(opts, :type_filter)

    # pgvector's <=> operator computes cosine distance (0 = identical, 2 = opposite)
    # Similarity = 1.0 - cosine_distance
    query_vector = Pgvector.new(query_embedding)

    base_query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id,
        select: %{
          id: e.id,
          content: e.content,
          cosine_distance: fragment("embedding <=> ?", ^query_vector),
          metadata: e.metadata,
          memory_type: e.memory_type,
          inserted_at: e.inserted_at
        }
      )

    # Apply type filter if provided
    query =
      if type_filter do
        from(e in base_query, where: e.memory_type == ^type_filter)
      else
        base_query
      end

    # Order by cosine distance (ascending = most similar first)
    # Filter by threshold (similarity >= threshold means distance <= 1 - threshold)
    max_distance = 1.0 - threshold

    query =
      from(q in query,
        where: fragment("embedding <=> ?", ^query_vector) <= ^max_distance,
        order_by: fragment("embedding <=> ?", ^query_vector),
        limit: ^limit
      )

    try do
      results =
        Repo.all(query)
        |> Enum.map(fn row ->
          %{
            id: row.id,
            content: row.content,
            similarity: 1.0 - row.cosine_distance,
            metadata: row.metadata || %{},
            memory_type: row.memory_type,
            indexed_at: row.inserted_at
          }
        end)

      {:ok, results}
    rescue
      e ->
        Logger.error("Embedding search failed: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Delete an embedding by ID.

  ## Examples

      :ok = Embedding.delete("agent_001", "emb_abc123...")
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent_id, embedding_id) do
    query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id and e.id == ^embedding_id
      )

    case Repo.delete_all(query) do
      {1, _} ->
        Logger.debug("Deleted embedding #{embedding_id} for agent #{agent_id}")
        :ok

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Count embeddings for an agent.

  ## Examples

      count = Embedding.count("agent_001")
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(agent_id) do
    query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id,
        select: count(e.id)
      )

    Repo.one(query) || 0
  end

  @doc """
  Get storage statistics for an agent.

  Returns a map with total count, type distribution, and time bounds.

  ## Examples

      stats = Embedding.stats("agent_001")
      #=> %{total: 100, by_type: %{"fact" => 50, "insight" => 30, ...}, oldest: ~U[...], newest: ~U[...]}
  """
  @spec stats(String.t()) :: map()
  def stats(agent_id) do
    # Total count
    total_query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id,
        select: count(e.id)
      )

    total = Repo.one(total_query) || 0

    # Count by type
    type_query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id and not is_nil(e.memory_type),
        group_by: e.memory_type,
        select: {e.memory_type, count(e.id)}
      )

    by_type = Repo.all(type_query) |> Map.new()

    # Time bounds
    bounds_query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id,
        select: {min(e.inserted_at), max(e.inserted_at)}
      )

    {oldest, newest} = Repo.one(bounds_query) || {nil, nil}

    %{
      total: total,
      by_type: by_type,
      oldest: oldest,
      newest: newest
    }
  end

  @doc """
  Batch store multiple embeddings.

  Entries is a list of `{content, embedding, metadata}` tuples.
  Uses insert_all for efficiency.

  ## Examples

      entries = [
        {"Fact one", [0.1, 0.2, ...], %{type: "fact"}},
        {"Fact two", [0.3, 0.4, ...], %{type: "fact"}}
      ]
      {:ok, 2} = Embedding.store_batch("agent_001", entries)
  """
  @spec store_batch(String.t(), [{String.t(), [float()], map()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def store_batch(_agent_id, []), do: {:ok, 0}

  def store_batch(agent_id, entries) when is_list(entries) do
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn {content, embedding, metadata} ->
        content_hash = compute_content_hash(content)

        %{
          id: Identifiers.generate_id("emb_"),
          agent_id: agent_id,
          content: content,
          content_hash: content_hash,
          embedding: Pgvector.new(embedding),
          memory_type: get_in(metadata, [:type]) || Map.get(metadata, "type"),
          source: get_in(metadata, [:source]) || Map.get(metadata, "source"),
          metadata: metadata,
          inserted_at: now,
          updated_at: now
        }
      end)

    try do
      {count, _} =
        Repo.insert_all(MemoryEmbedding, rows,
          on_conflict: {:replace, [:embedding, :memory_type, :source, :metadata, :updated_at]},
          conflict_target: [:agent_id, :content_hash]
        )

      Logger.debug("Batch stored #{count} embeddings for agent #{agent_id}")
      {:ok, count}
    rescue
      e ->
        Logger.error("Batch store failed: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Get a single embedding by ID.

  ## Examples

      {:ok, embedding} = Embedding.get("agent_001", "emb_abc123...")
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(agent_id, embedding_id) do
    query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id and e.id == ^embedding_id
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      record ->
        {:ok,
         %{
           id: record.id,
           agent_id: record.agent_id,
           content: record.content,
           content_hash: record.content_hash,
           embedding: record.embedding,
           memory_type: record.memory_type,
           source: record.source,
           metadata: record.metadata,
           inserted_at: record.inserted_at,
           updated_at: record.updated_at
         }}
    end
  end

  @doc """
  Delete all embeddings for an agent.

  Use with caution — this permanently removes all memory embeddings.

  ## Examples

      {:ok, 100} = Embedding.delete_all("agent_001")
  """
  @spec delete_all(String.t()) :: {:ok, non_neg_integer()}
  def delete_all(agent_id) do
    query =
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id
      )

    {count, _} = Repo.delete_all(query)
    Logger.info("Deleted #{count} embeddings for agent #{agent_id}")
    {:ok, count}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @spec compute_content_hash(String.t()) :: String.t()
  defp compute_content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
