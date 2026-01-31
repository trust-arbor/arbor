defmodule Arbor.Memory.Index do
  @moduledoc """
  In-memory vector index for semantic memory retrieval.

  Provides ETS-backed storage with cosine similarity search for fast in-memory
  semantic retrieval. Each agent gets its own isolated index via the IndexSupervisor.

  ## Features

  - Cosine similarity search with configurable threshold
  - Type-based filtering on recall
  - Batch indexing
  - LRU eviction when max entries exceeded
  - Per-agent isolation via Registry

  ## Architecture

  - Uses ETS for storage (fast reads, concurrent access)
  - Embeddings are stored alongside content
  - On crash, rebuild from Postgres (no re-embedding needed)
  - Embedding backend is pluggable via arbor_ai

  ## Examples

      # Start an index for an agent
      {:ok, pid} = Arbor.Memory.Index.start_link(agent_id: "agent_001")

      # Index content
      {:ok, entry_id} = Arbor.Memory.Index.index(pid, "Hello world", %{type: :fact})

      # Recall similar content
      {:ok, results} = Arbor.Memory.Index.recall(pid, "greeting")
  """

  use GenServer

  alias Arbor.Common.SafeAtom

  require Logger

  @type entry_id :: String.t()
  @type entry :: %{
          id: entry_id(),
          content: String.t(),
          embedding: [float()],
          metadata: map(),
          indexed_at: DateTime.t(),
          accessed_at: DateTime.t(),
          access_count: non_neg_integer()
        }

  @type recall_result :: %{
          id: entry_id(),
          content: String.t(),
          similarity: float(),
          metadata: map(),
          indexed_at: DateTime.t()
        }

  @default_max_entries 10_000
  @default_threshold 0.3
  @default_limit 10

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start a new index for an agent.

  ## Options

  - `:agent_id` - Required. The agent ID this index belongs to.
  - `:max_entries` - Max entries before LRU eviction (default: 10_000)
  - `:threshold` - Default similarity threshold for recall (default: 0.3)
  - `:name` - Optional name for the GenServer

  ## Examples

      {:ok, pid} = Arbor.Memory.Index.start_link(agent_id: "agent_001")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    name = Keyword.get(opts, :name) || via_tuple(agent_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Index content with optional metadata.

  ## Options

  - `:type` - Category type for the entry (atom)
  - `:source` - Source of the content
  - `:embedding` - Pre-computed embedding (skips embedding call)

  ## Examples

      {:ok, id} = Arbor.Memory.Index.index(pid, "Important fact", %{type: :fact})
  """
  @spec index(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, entry_id()} | {:error, term()}
  def index(server, content, metadata \\ %{}, opts \\ []) do
    GenServer.call(server, {:index, content, metadata, opts})
  end

  @doc """
  Recall content similar to query.

  ## Options

  - `:limit` - Max results to return (default: 10)
  - `:threshold` - Minimum similarity threshold (default: 0.3)
  - `:type` - Filter by entry type
  - `:types` - Filter by multiple types

  ## Examples

      {:ok, results} = Arbor.Memory.Index.recall(pid, "greeting")
      {:ok, facts} = Arbor.Memory.Index.recall(pid, "query", type: :fact, limit: 5)
  """
  @spec recall(GenServer.server(), String.t(), keyword()) ::
          {:ok, [recall_result()]} | {:error, term()}
  def recall(server, query, opts \\ []) do
    GenServer.call(server, {:recall, query, opts})
  end

  @doc """
  Index multiple items in a batch.

  Each item should be a tuple of `{content, metadata}`.

  ## Examples

      items = [
        {"Fact one", %{type: :fact}},
        {"Fact two", %{type: :fact}}
      ]
      {:ok, ids} = Arbor.Memory.Index.batch_index(pid, items)
  """
  @spec batch_index(GenServer.server(), [{String.t(), map()}], keyword()) ::
          {:ok, [entry_id()]} | {:error, term()}
  def batch_index(server, items, opts \\ []) do
    GenServer.call(server, {:batch_index, items, opts}, :infinity)
  end

  @doc """
  Get statistics about the index.

  ## Examples

      stats = Arbor.Memory.Index.stats(pid)
      #=> %{entry_count: 100, max_entries: 10000, ...}
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Clear all entries from the index.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  @doc """
  Get a specific entry by ID.
  """
  @spec get(GenServer.server(), entry_id()) :: {:ok, entry()} | {:error, :not_found}
  def get(server, entry_id) do
    GenServer.call(server, {:get, entry_id})
  end

  @doc """
  Delete a specific entry by ID.
  """
  @spec delete(GenServer.server(), entry_id()) :: :ok | {:error, :not_found}
  def delete(server, entry_id) do
    GenServer.call(server, {:delete, entry_id})
  end

  # Registry lookup helper
  defp via_tuple(agent_id) do
    {:via, Registry, {Arbor.Memory.Registry, {:index, agent_id}}}
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    # Create ETS table for this index
    table = :ets.new(:memory_index, [:set, :protected])

    state = %{
      agent_id: agent_id,
      table: table,
      max_entries: max_entries,
      default_threshold: threshold,
      entry_count: 0
    }

    Logger.debug("Started memory index for agent #{agent_id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:index, content, metadata, opts}, _from, state) do
    case do_index(content, metadata, opts, state) do
      {:ok, entry_id, new_state} ->
        {:reply, {:ok, entry_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recall, query, opts}, _from, state) do
    result = do_recall(query, opts, state)
    {:reply, result, state}
  end

  def handle_call({:batch_index, items, opts}, _from, state) do
    case do_batch_index(items, opts, state) do
      {:ok, ids, new_state} ->
        {:reply, {:ok, ids}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      agent_id: state.agent_id,
      entry_count: state.entry_count,
      max_entries: state.max_entries,
      default_threshold: state.default_threshold
    }

    {:reply, stats, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | entry_count: 0}}
  end

  def handle_call({:get, entry_id}, _from, state) do
    case :ets.lookup(state.table, entry_id) do
      [{^entry_id, entry}] ->
        # Update access time and count
        updated_entry = %{
          entry
          | accessed_at: DateTime.utc_now(),
            access_count: entry.access_count + 1
        }

        :ets.insert(state.table, {entry_id, updated_entry})
        {:reply, {:ok, updated_entry}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, entry_id}, _from, state) do
    case :ets.lookup(state.table, entry_id) do
      [{^entry_id, _entry}] ->
        :ets.delete(state.table, entry_id)
        {:reply, :ok, %{state | entry_count: max(0, state.entry_count - 1)}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp do_index(content, metadata, opts, state) do
    with {:ok, embedding} <- get_or_compute_embedding(content, opts),
         entry_id <- generate_entry_id(),
         now <- DateTime.utc_now() do
      entry = %{
        id: entry_id,
        content: content,
        embedding: embedding,
        metadata: normalize_metadata(metadata),
        indexed_at: now,
        accessed_at: now,
        access_count: 0
      }

      # Check if we need to evict
      new_state = maybe_evict(state)

      # Store in ETS
      :ets.insert(new_state.table, {entry_id, entry})

      {:ok, entry_id, %{new_state | entry_count: new_state.entry_count + 1}}
    end
  end

  defp do_recall(query, opts, state) do
    with {:ok, query_embedding} <- get_or_compute_embedding(query, opts) do
      threshold = Keyword.get(opts, :threshold, state.default_threshold)
      limit = Keyword.get(opts, :limit, @default_limit)
      type_filter = get_type_filter(opts)

      results = find_matching_entries(state.table, query_embedding, type_filter, threshold)

      sorted =
        results
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

      {:ok, sorted}
    end
  end

  defp find_matching_entries(table, query_embedding, type_filter, threshold) do
    :ets.foldl(
      fn {_id, entry}, acc ->
        score_entry(entry, query_embedding, type_filter, threshold, acc)
      end,
      [],
      table
    )
  end

  defp score_entry(entry, query_embedding, type_filter, threshold, acc) do
    if matches_type_filter?(entry, type_filter) do
      similarity = cosine_similarity(query_embedding, entry.embedding)

      if similarity >= threshold do
        [entry_to_result(entry, similarity) | acc]
      else
        acc
      end
    else
      acc
    end
  end

  defp entry_to_result(entry, similarity) do
    %{
      id: entry.id,
      content: entry.content,
      similarity: similarity,
      metadata: entry.metadata,
      indexed_at: entry.indexed_at
    }
  end

  defp do_batch_index(items, opts, state) do
    results =
      Enum.reduce_while(items, {:ok, [], state}, fn {content, metadata}, {:ok, ids, acc_state} ->
        case do_index(content, metadata, opts, acc_state) do
          {:ok, entry_id, new_state} ->
            {:cont, {:ok, [entry_id | ids], new_state}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, ids, final_state} ->
        {:ok, Enum.reverse(ids), final_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_or_compute_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  defp get_or_compute_embedding(content, opts) do
    case Keyword.get(opts, :embedding) do
      nil ->
        compute_embedding(content)

      embedding when is_list(embedding) ->
        {:ok, embedding}
    end
  end

  @spec compute_embedding(String.t()) :: {:ok, [float()]} | {:error, term()}
  defp compute_embedding(""), do: {:error, :empty_content}

  defp compute_embedding(content) do
    # For now, use a simple hash-based embedding as fallback
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO: Integrate with arbor_ai for real embeddings
    # This function can return {:error, reason} in production when
    # the embedding service fails
    {:ok, simple_embedding(content)}
  end

  # Simple hash-based embedding for testing/fallback
  # In production, this would call arbor_ai's embedding service
  defp simple_embedding(text) do
    # Create a deterministic pseudo-embedding from text
    # This is NOT a real semantic embedding - just for testing
    hash = :erlang.phash2(text, 1_000_000)

    for i <- 0..127 do
      # Create deterministic but varied values
      :math.sin((hash + i) / 1000) * 0.5 + 0.5
    end
  end

  defp cosine_similarity(vec_a, vec_b) when length(vec_a) == length(vec_b) do
    dot_product = Enum.zip(vec_a, vec_b) |> Enum.reduce(0, fn {a, b}, acc -> acc + a * b end)
    magnitude_a = :math.sqrt(Enum.reduce(vec_a, 0, fn x, acc -> acc + x * x end))
    magnitude_b = :math.sqrt(Enum.reduce(vec_b, 0, fn x, acc -> acc + x * x end))

    if magnitude_a == 0 or magnitude_b == 0 do
      0.0
    else
      dot_product / (magnitude_a * magnitude_b)
    end
  end

  defp cosine_similarity(_vec_a, _vec_b) do
    # Mismatched dimensions
    0.0
  end

  defp maybe_evict(%{entry_count: count, max_entries: max} = state) when count >= max do
    # Find least recently accessed entries and remove them
    entries_to_remove = div(max, 10)

    all_entries =
      :ets.foldl(
        fn {id, entry}, acc -> [{id, entry.accessed_at} | acc] end,
        [],
        state.table
      )

    to_remove =
      all_entries
      |> Enum.sort_by(fn {_id, accessed_at} -> accessed_at end, DateTime)
      |> Enum.take(entries_to_remove)
      |> Enum.map(fn {id, _} -> id end)

    Enum.each(to_remove, &:ets.delete(state.table, &1))

    %{state | entry_count: count - length(to_remove)}
  end

  defp maybe_evict(state), do: state

  defp generate_entry_id do
    "mem_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    # Safely atomize known keys
    known_keys = [:type, :source, :tags, :agent_id, :correlation_id]
    SafeAtom.atomize_keys(metadata, known_keys)
  end

  defp normalize_metadata(_), do: %{}

  defp get_type_filter(opts) do
    cond do
      type = Keyword.get(opts, :type) -> {:single, type}
      types = Keyword.get(opts, :types) -> {:multiple, types}
      true -> :none
    end
  end

  defp matches_type_filter?(_entry, :none), do: true

  defp matches_type_filter?(entry, {:single, type}) do
    Map.get(entry.metadata, :type) == type
  end

  defp matches_type_filter?(entry, {:multiple, types}) do
    Map.get(entry.metadata, :type) in types
  end
end
