defmodule Arbor.Persistence.LegacyEmbeddingStore do
  @moduledoc false

  import Ecto.Query

  alias Arbor.Identifiers
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.MemoryEmbedding

  require Logger

  @spec store(String.t(), String.t(), [float()], map()) ::
          {:ok, String.t()} | {:error, term()}
  def store(agent_id, content, embedding, metadata) do
    content_hash = compute_content_hash(content)
    id = Map.get(metadata, :id) || Map.get(metadata, "id") || Identifiers.generate_id("emb_")

    if is_binary(id) and protected_vector_id?(id) do
      {:error, :protected_vector_row}
    else
      store_legacy_embedding(agent_id, id, content, content_hash, embedding, metadata)
    end
  end

  @spec search(String.t(), [float()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(agent_id, query_embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.3)
    type_filter = Keyword.get(opts, :type_filter)
    query_vector = Pgvector.new(query_embedding)

    base_query =
      from(e in legacy_rows(),
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

    query =
      if type_filter do
        from(e in base_query, where: e.memory_type == ^type_filter)
      else
        base_query
      end

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
      error ->
        Logger.error("Embedding search failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent_id, embedding_id) do
    query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id and e.id == ^embedding_id
      )

    case Repo.delete_all(query) do
      {1, _} ->
        Logger.debug("Deleted embedding #{embedding_id} for agent #{agent_id}")
        :ok

      {0, _} ->
        if protected_vector_id?(agent_id, embedding_id),
          do: {:error, :protected_vector_row},
          else: {:error, :not_found}
    end
  end

  @spec count(String.t()) :: non_neg_integer()
  def count(agent_id) do
    query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id,
        select: count(e.id)
      )

    Repo.one(query) || 0
  end

  @spec stats(String.t()) :: map()
  def stats(agent_id) do
    total_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id,
        select: count(e.id)
      )

    type_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id and not is_nil(e.memory_type),
        group_by: e.memory_type,
        select: {e.memory_type, count(e.id)}
      )

    bounds_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id,
        select: {min(e.inserted_at), max(e.inserted_at)}
      )

    {oldest, newest} = Repo.one(bounds_query) || {nil, nil}

    %{
      total: Repo.one(total_query) || 0,
      by_type: Repo.all(type_query) |> Map.new(),
      oldest: oldest,
      newest: newest
    }
  end

  @spec store_batch(String.t(), [{String.t(), [float()], map()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def store_batch(_agent_id, []), do: {:ok, 0}

  def store_batch(agent_id, entries) when is_list(entries) do
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn {content, embedding, metadata} ->
        %{
          id: Identifiers.generate_id("emb_"),
          agent_id: agent_id,
          content: content,
          content_hash: compute_content_hash(content),
          embedding: Pgvector.new(embedding),
          memory_type: safe_to_string(get_in(metadata, [:type]) || Map.get(metadata, "type")),
          source: safe_to_string(get_in(metadata, [:source]) || Map.get(metadata, "source")),
          metadata: metadata,
          inserted_at: now,
          updated_at: now
        }
      end)

    try do
      {count, _} =
        Repo.insert_all(MemoryEmbedding, rows,
          on_conflict: legacy_conflict_query(),
          conflict_target: [:agent_id, :content_hash]
        )

      if count == length(rows) do
        Logger.debug("Batch stored #{count} embeddings for agent #{agent_id}")
        {:ok, count}
      else
        {:error, :protected_vector_row}
      end
    rescue
      error ->
        Logger.error("Batch store failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(agent_id, embedding_id) do
    query =
      from(e in legacy_rows(),
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

  @spec delete_all(String.t()) :: {:ok, non_neg_integer()}
  def delete_all(agent_id) do
    query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id
      )

    {count, _} = Repo.delete_all(query)
    Logger.info("Deleted #{count} embeddings for agent #{agent_id}")
    {:ok, count}
  end

  defp store_legacy_embedding(agent_id, id, content, content_hash, embedding, metadata) do
    attrs = %{
      id: id,
      agent_id: agent_id,
      content: content,
      content_hash: content_hash,
      embedding: Pgvector.new(embedding),
      memory_type: safe_to_string(get_in(metadata, [:type]) || Map.get(metadata, "type")),
      source: safe_to_string(get_in(metadata, [:source]) || Map.get(metadata, "source")),
      metadata: metadata
    }

    changeset = MemoryEmbedding.changeset(%MemoryEmbedding{}, attrs)

    case insert_legacy_changeset(changeset, agent_id, content_hash) do
      {:ok, %MemoryEmbedding{} = record} ->
        if is_nil(record.vector_protocol) and is_nil(record.source_namespace) do
          Logger.debug("Stored embedding #{record.id} for agent #{agent_id}")
          {:ok, record.id}
        else
          {:error, :protected_vector_row}
        end

      {:error, :protected_vector_row} ->
        {:error, :protected_vector_row}

      {:error, changeset} ->
        Logger.warning("Failed to store embedding: #{inspect(changeset.errors)}")
        {:error, changeset.errors}
    end
  end

  defp legacy_rows do
    from(e in MemoryEmbedding,
      where: is_nil(e.vector_protocol) and is_nil(e.source_namespace)
    )
  end

  defp insert_legacy_changeset(changeset, agent_id, content_hash) do
    Repo.insert(changeset,
      on_conflict: legacy_conflict_query(),
      conflict_target: [:agent_id, :content_hash],
      returning: true
    )
  rescue
    error in Ecto.StaleEntryError ->
      if protected_vector_hash?(agent_id, content_hash) do
        {:error, :protected_vector_row}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp protected_vector_hash?(agent_id, content_hash) do
    Repo.exists?(
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id and e.content_hash == ^content_hash,
        where: not is_nil(e.vector_protocol) or not is_nil(e.source_namespace)
      )
    )
  end

  defp protected_vector_id?(agent_id, id) do
    Repo.exists?(
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id and e.id == ^id,
        where: not is_nil(e.vector_protocol) or not is_nil(e.source_namespace)
      )
    )
  end

  defp protected_vector_id?(id) do
    Repo.exists?(
      from(e in MemoryEmbedding,
        where: e.id == ^id,
        where: not is_nil(e.vector_protocol) or not is_nil(e.source_namespace)
      )
    )
  end

  defp legacy_conflict_query do
    from(e in MemoryEmbedding,
      update: [
        set: [
          embedding: fragment("EXCLUDED.embedding"),
          memory_type: fragment("EXCLUDED.memory_type"),
          source: fragment("EXCLUDED.source"),
          metadata: fragment("EXCLUDED.metadata"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where: is_nil(e.vector_protocol) and is_nil(e.source_namespace)
    )
  end

  defp compute_content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp safe_to_string(nil), do: nil
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: to_string(value)
end
