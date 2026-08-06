defmodule Arbor.Memory.Embedding do
  @moduledoc """
  Durable legacy PostgreSQL/pgvector compatibility API for the memory index.

  Database ownership stays behind the `Arbor.Persistence` facade. This module
  preserves the established Memory API without importing persistence schemas,
  repositories, query builders, or adapter-specific vector types.
  """

  alias Arbor.Persistence

  @behaviour Arbor.Memory.Index.PersistentWriter

  @doc "Validate and normalize one durable legacy embedding without dispatching a write."
  @spec validate(String.t(), String.t(), term(), term()) ::
          {:ok, [float()]} | {:error, {:invalid_legacy_embedding, atom()}}
  def validate(agent_id, content, embedding, metadata),
    do: Persistence.validate_legacy_embedding(agent_id, content, embedding, metadata)

  @doc "Store or deduplicate one embedding."
  @impl true
  @spec store(String.t(), String.t(), [float()], map()) ::
          {:ok, String.t()} | {:error, term()}
  def store(agent_id, content, embedding, metadata \\ %{}),
    do: Persistence.store_legacy_embedding(agent_id, content, embedding, metadata)

  @doc "Search legacy embeddings using cosine similarity."
  @spec search(String.t(), [float()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(agent_id, query_embedding, opts \\ []),
    do: Persistence.search_legacy_embeddings(agent_id, query_embedding, opts)

  @doc "Delete an embedding by its durable row ID."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent_id, embedding_id),
    do: Persistence.delete_legacy_embedding(agent_id, embedding_id)

  @doc "Count embeddings for an agent."
  @spec count(String.t()) :: non_neg_integer()
  def count(agent_id), do: Persistence.count_legacy_embeddings(agent_id)

  @doc "Return aggregate embedding statistics for an agent."
  @spec stats(String.t()) :: map()
  def stats(agent_id), do: Persistence.legacy_embedding_stats(agent_id)

  @doc "Store or deduplicate a batch of embeddings."
  @spec store_batch(String.t(), [{String.t(), [float()], map()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def store_batch(agent_id, entries),
    do: Persistence.store_legacy_embedding_batch(agent_id, entries)

  @doc false
  @impl true
  @spec store_batch_with_ids(String.t(), [{String.t(), [float()], map()}]) ::
          {:ok, [String.t()]} | {:error, term()}
  def store_batch_with_ids(agent_id, entries),
    do: Persistence.store_legacy_embedding_batch_with_ids(agent_id, entries)

  @doc "Fetch one embedding by its durable row ID."
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(agent_id, embedding_id),
    do: Persistence.fetch_legacy_embedding(agent_id, embedding_id)

  @doc "Delete all legacy embeddings for an agent."
  @spec delete_all(String.t()) :: {:ok, non_neg_integer()}
  def delete_all(agent_id), do: Persistence.delete_all_legacy_embeddings(agent_id)
end
