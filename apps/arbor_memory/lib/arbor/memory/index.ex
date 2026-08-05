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
  - Optional dual backend mode (ETS + pgvector)

  ## Architecture

  - Uses ETS for storage (fast reads, concurrent access)
  - Embeddings are stored alongside content
  - On crash, rebuild from Postgres (no re-embedding needed)
  - Embedding backend is pluggable via arbor_ai

  ## Backend Modes

  Configure via `config :arbor_memory, :embedding_backend`:

  - `:ets` — ETS only (default, backward compatible)
  - `:pgvector` — pgvector only
  - `:dual` — Write to both, read from ETS first then pgvector

  ## Examples

      # Start an index for an agent
      {:ok, pid} = Arbor.Memory.Index.start_link(agent_id: "agent_001")

      # Index content
      {:ok, entry_id} = Arbor.Memory.Index.index(pid, "Hello world", %{type: :fact})

      # Recall similar content
      {:ok, results} = Arbor.Memory.Index.recall(pid, "greeting")

      # Warm cache from pgvector (in dual mode)
      :ok = Arbor.Memory.Index.warm_cache(pid, limit: 1000)
  """

  use GenServer

  alias Arbor.Common.SafeAtom
  alias Arbor.Memory.Embedding

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
  # Shared VectorRecord IDs and the legacy memory_embeddings primary key are varchar(255).
  @max_entry_id_bytes 255

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
  - `:persistent_writer` - Legacy durable writer module (default: `Embedding`)
  - `:entry_id_generator` - Zero-arity entry ID generator (default: random `mem_` ID)
  - `:clock` - Zero-arity UTC clock (default: `DateTime.utc_now/0`)

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

  @doc """
  Warm the ETS cache from pgvector.

  Loads recent entries from the persistent backend into ETS.
  Only useful in `:dual` or `:pgvector` backend modes.

  ## Options

  - `:limit` — Maximum entries to load (default: 1000)
  - `:query` — Optional query to filter which entries to warm

  ## Examples

      :ok = Arbor.Memory.Index.warm_cache(pid)
      :ok = Arbor.Memory.Index.warm_cache(pid, limit: 500)
  """
  @spec warm_cache(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def warm_cache(server, opts \\ []) do
    GenServer.call(server, {:warm_cache, opts}, :infinity)
  end

  @doc """
  Sync ETS entries to the persistent backend.

  Flushes entries that haven't been persisted yet to pgvector.
  Only useful in `:dual` backend mode.

  The returned count is the number of acknowledged local entries that
  converged. Same-content entries may converge to one durable row while each
  acknowledged ID remains usable as an alias. A same-content group requests
  the earliest indexed ID and persists the latest indexed content, vector, and
  ordinary metadata. Ordering comes from a process-local monotonic sequence
  assigned by the serialized index, never from wall-clock timestamps or IDs.

  This latest-value rule must not be extended to future C3G provenance labels.
  Provenance, taint, and authority labels must conservatively join every group
  member rather than using latest-wins semantics.

  ## Examples

      {:ok, count} = Arbor.Memory.Index.sync_to_persistent(pid)
  """
  @spec sync_to_persistent(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_to_persistent(server, opts \\ []) do
    GenServer.call(server, {:sync_to_persistent, opts}, :infinity)
  end

  @doc """
  Get the current backend mode.

  ## Examples

      :dual = Arbor.Memory.Index.backend_mode(pid)
  """
  @spec backend_mode(GenServer.server()) :: :ets | :pgvector | :dual
  def backend_mode(server) do
    GenServer.call(server, :backend_mode)
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
    backend = Keyword.get(opts, :backend, get_backend_config())

    # Create ETS table for this index
    table = :ets.new(:memory_index, [:set, :protected])

    state = %{
      agent_id: agent_id,
      table: table,
      max_entries: max_entries,
      default_threshold: threshold,
      entry_count: 0,
      backend: backend,
      persistent_writer: Keyword.get(opts, :persistent_writer, Embedding),
      entry_id_generator: Keyword.get(opts, :entry_id_generator, &generate_entry_id/0),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      # Local ordering only; never persisted or copied into caller metadata.
      next_insertion_sequence: 0,
      pending_entry_orders: %{},
      # Track entries not yet synced to persistent (for dual mode)
      pending_sync: MapSet.new(),
      # A failed eager write can later deduplicate to a different durable ID.
      id_aliases: %{}
    }

    Logger.debug("Started memory index for agent #{agent_id} with backend #{backend}")
    {:ok, state}
  end

  defp get_backend_config do
    Application.get_env(:arbor_memory, :embedding_backend, :ets)
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

    {:reply, :ok,
     %{
       state
       | entry_count: 0,
         pending_sync: MapSet.new(),
         pending_entry_orders: %{},
         id_aliases: %{}
     }}
  end

  def handle_call({:get, entry_id}, _from, state) do
    canonical_id = resolve_entry_id(entry_id, state)

    case :ets.lookup(state.table, canonical_id) do
      [{^canonical_id, entry}] ->
        # Update access time and count
        updated_entry = %{
          entry
          | accessed_at: DateTime.utc_now(),
            access_count: entry.access_count + 1
        }

        :ets.insert(state.table, {canonical_id, updated_entry})
        {:reply, {:ok, updated_entry}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, entry_id}, _from, state) do
    case delete_entry(entry_id, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:warm_cache, opts}, _from, state) do
    if state.backend in [:pgvector, :dual] do
      result = do_warm_cache(opts, state)
      {:reply, result, state}
    else
      {:reply, {:error, :backend_not_persistent}, state}
    end
  end

  def handle_call({:sync_to_persistent, _opts}, _from, state) do
    if state.backend == :dual do
      result = do_sync_to_persistent(state)

      case result do
        {:ok, count, new_state} ->
          {:reply, {:ok, count}, new_state}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :not_dual_backend}, state}
    end
  end

  def handle_call(:backend_mode, _from, state) do
    {:reply, state.backend, state}
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
         {:ok, entry_id, now} <- generate_entry_identity(state) do
      insertion_sequence = state.next_insertion_sequence
      normalized_metadata = normalize_metadata(metadata)

      entry = %{
        id: entry_id,
        content: content,
        embedding: embedding,
        metadata: normalized_metadata,
        indexed_at: now,
        accessed_at: now,
        access_count: 0
      }

      # Store based on backend mode
      case state.backend do
        :ets ->
          # ETS only
          new_state =
            state
            |> maybe_evict()
            |> put_local_entry(entry)
            |> advance_insertion_sequence(insertion_sequence)

          {:ok, entry_id, new_state}

        :pgvector ->
          # pgvector only
          case Embedding.store(state.agent_id, content, embedding, normalized_metadata) do
            {:ok, stored_id} ->
              if valid_entry_id?(stored_id),
                do: {:ok, stored_id, advance_insertion_sequence(state, insertion_sequence)},
                else: {:error, :malformed_persistence_result}

            {:error, reason} ->
              {:error, reason}
          end

        :dual ->
          index_dual_mode(entry_id, entry, insertion_sequence, state)
      end
    end
  end

  defp index_dual_mode(entry_id, entry, insertion_sequence, state) do
    metadata_with_id = Map.put(entry.metadata, :id, entry_id)

    case eager_store(state, entry, metadata_with_id) do
      {:ok, authoritative_id} ->
        with :ok <- validate_authoritative_binding(state, entry.content, authoritative_id) do
          authoritative_entry = %{entry | id: authoritative_id}

          new_state =
            state
            |> maybe_evict()
            |> put_local_entry(authoritative_entry)
            |> advance_insertion_sequence(insertion_sequence)
            |> refresh_pending_entry_order(authoritative_id, insertion_sequence)

          {:ok, authoritative_id, new_state}
        end

      {:error, reason} ->
        log_dual_write_failure(entry_id, reason)

        state =
          state
          |> maybe_evict()
          |> put_local_entry(entry)
          |> advance_insertion_sequence(insertion_sequence)

        new_state = %{
          state
          | pending_sync: MapSet.put(state.pending_sync, entry_id),
            pending_entry_orders:
              Map.put(state.pending_entry_orders, entry_id, %{
                first: insertion_sequence,
                latest: insertion_sequence
              })
        }

        {:ok, entry_id, new_state}
    end
  end

  defp log_dual_write_failure(entry_id, reason) do
    require Logger
    Logger.warning("Dual-mode pgvector write failed for #{entry_id}: #{inspect(reason)}")
  end

  defp do_recall(query, opts, state) do
    with {:ok, query_embedding} <- get_or_compute_embedding(query, opts) do
      threshold = Keyword.get(opts, :threshold, state.default_threshold)
      limit = Keyword.get(opts, :limit, @default_limit)
      type_filter = get_type_filter(opts)

      case state.backend do
        :ets ->
          # ETS only
          do_ets_recall(query_embedding, type_filter, threshold, limit, state)

        :pgvector ->
          # pgvector only
          do_pgvector_recall(query_embedding, type_filter, threshold, limit, state)

        :dual ->
          # Two-tier: check ETS first, then pgvector for additional results
          do_dual_recall(query_embedding, type_filter, threshold, limit, state)
      end
    end
  end

  defp do_ets_recall(query_embedding, type_filter, threshold, limit, state) do
    results = find_matching_entries(state.table, query_embedding, type_filter, threshold)

    sorted =
      results
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)

    {:ok, sorted}
  end

  defp do_pgvector_recall(query_embedding, type_filter, threshold, limit, state) do
    type_filter_value =
      case type_filter do
        {:single, type} -> to_string(type)
        _ -> nil
      end

    opts = [
      limit: limit,
      threshold: threshold,
      type_filter: type_filter_value
    ]

    Embedding.search(state.agent_id, query_embedding, opts)
  end

  defp do_dual_recall(query_embedding, type_filter, threshold, limit, state) do
    # First, search ETS (hot cache)
    ets_results = find_matching_entries(state.table, query_embedding, type_filter, threshold)

    # If we have enough results from ETS, return them
    if length(ets_results) >= limit do
      sorted =
        ets_results
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

      {:ok, sorted}
    else
      # Fall back to pgvector for additional results
      recall_dual_mode(query_embedding, type_filter, threshold, limit, ets_results, state)
    end
  end

  defp recall_dual_mode(query_embedding, type_filter, threshold, limit, ets_results, state) do
    type_filter_value =
      case type_filter do
        {:single, type} -> to_string(type)
        _ -> nil
      end

    pgvector_opts = [
      limit: limit,
      threshold: threshold,
      type_filter: type_filter_value
    ]

    case Embedding.search(state.agent_id, query_embedding, pgvector_opts) do
      {:ok, pgvector_results} ->
        # Merge results, deduplicating by content
        # ETS results have priority (fresher access times)
        ets_contents = MapSet.new(ets_results, & &1.content)

        unique_pgvector =
          Enum.reject(pgvector_results, fn r -> MapSet.member?(ets_contents, r.content) end)

        merged = ets_results ++ unique_pgvector

        sorted =
          merged
          |> Enum.sort_by(& &1.similarity, :desc)
          |> Enum.take(limit)

        {:ok, sorted}

      {:error, _reason} ->
        # Fallback to ETS results only
        sorted =
          ets_results
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
    if embedding_service_enabled?() do
      compute_embedding_via_provider(content)
    else
      # Hermetic test lane (config :arbor_memory, :embedding_service_enabled false):
      # skip the live embedding backend. A synchronous Arbor.AI.embed here runs
      # INSIDE this GenServer's {:index}/{:recall} handle_call, so when the backend
      # (Ollama) hangs on Finch under load it blocks past the caller's 5s timeout
      # (the IndexTest/PreconsciousTest flakes). The deterministic hash fallback
      # keeps index/recall functional offline.
      {:ok, hash_fallback_embedding(content)}
    end
  end

  defp embedding_service_enabled?,
    do: Application.get_env(:arbor_memory, :embedding_service_enabled, true)

  defp compute_embedding_via_provider(content) do
    case Arbor.AI.embed(content) do
      {:ok, %{embedding: embedding}} ->
        {:ok, embedding}

      {:error, reason} ->
        Logger.warning("Embedding provider failed, using hash fallback: #{inspect(reason)}")
        {:ok, hash_fallback_embedding(content)}
    end
  end

  # Hash-based fallback embedding when no provider is available.
  # Deterministic but not semantically meaningful.
  defp hash_fallback_embedding(text) do
    dimension = Application.get_env(:arbor_persistence, :embedding_dimension, 768)
    hash = :erlang.phash2(text, 1_000_000)

    for i <- 0..(dimension - 1) do
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

    pending_sync = Enum.reduce(to_remove, state.pending_sync, &MapSet.delete(&2, &1))

    %{
      state
      | entry_count: count - length(to_remove),
        pending_sync: pending_sync,
        pending_entry_orders: Map.drop(state.pending_entry_orders, to_remove)
    }
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

  # ============================================================================
  # Dual Backend Helpers
  # ============================================================================

  defp do_warm_cache(opts, state) do
    limit = Keyword.get(opts, :limit, 1000)

    # Use a simple search with a very low threshold to get recent entries
    # We can't directly query "most recent" without modifying the Embedding module,
    # so we'll use the stats to understand what's available
    stats = Embedding.stats(state.agent_id)

    if stats.total == 0 do
      Logger.debug("No embeddings to warm cache for agent #{state.agent_id}")
      :ok
    else
      warm_from_pgvector(limit, state)
    end
  end

  defp do_sync_to_persistent(state) do
    pending_ids = state.pending_sync |> MapSet.to_list() |> Enum.sort()

    if pending_ids == [] do
      {:ok, 0, state}
    else
      pending_entries = Enum.flat_map(pending_ids, &collect_pending_entry(&1, state))

      if pending_entries == [] do
        {:ok, 0, %{state | pending_sync: MapSet.new()}}
      else
        groups = group_pending_entries(pending_entries)
        entries = Enum.map(groups, &pending_group_batch_entry/1)

        case batch_store_with_ids(state, entries) do
          {:ok, authoritative_ids} ->
            with {:ok, bindings} <-
                   validate_authoritative_bindings(state, groups, authoritative_ids) do
              new_state =
                Enum.reduce(bindings, state, fn {group, authoritative_id}, acc ->
                  converge_pending_group(acc, group, authoritative_id)
                end)

              {:ok, length(pending_entries), new_state}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp warm_from_pgvector(limit, state) do
    # Get a sample embedding to search with (or use a zero vector)
    # This is a bit of a workaround - ideally we'd have a "list recent" function
    # For now, we'll load entries by doing a broad search
    dimension = Application.get_env(:arbor_persistence, :embedding_dimension, 768)
    zero_vector = List.duplicate(0.0, dimension)

    case Embedding.search(state.agent_id, zero_vector, limit: limit, threshold: 0.0) do
      {:ok, results} ->
        loaded_count = Enum.reduce(results, 0, &load_cache_entry(&1, &2, state))

        Logger.info("Warmed cache with #{loaded_count} entries for agent #{state.agent_id}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to warm cache: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_cache_entry(result, acc, state) do
    # Don't overwrite entries already in ETS
    case :ets.lookup(state.table, result.id) do
      [] ->
        # Fetch full embedding to store in ETS
        case Embedding.get(state.agent_id, result.id) do
          {:ok, full_record} ->
            now = DateTime.utc_now()

            entry = %{
              id: full_record.id,
              content: full_record.content,
              embedding:
                if(is_list(full_record.embedding),
                  do: full_record.embedding,
                  else: Pgvector.to_list(full_record.embedding)
                ),
              metadata: full_record.metadata || %{},
              indexed_at: full_record.inserted_at || now,
              accessed_at: now,
              access_count: 0
            }

            :ets.insert(state.table, {full_record.id, entry})
            acc + 1

          {:error, _} ->
            acc
        end

      _ ->
        # Already in ETS
        acc
    end
  end

  defp collect_pending_entry(id, state) do
    case {:ets.lookup(state.table, id), Map.fetch(state.pending_entry_orders, id)} do
      {[{^id, entry}], {:ok, %{first: first_sequence, latest: latest_sequence}}} ->
        [{id, entry, first_sequence, latest_sequence}]

      _missing_entry_or_sequence ->
        []
    end
  end

  defp group_pending_entries(pending_entries) do
    pending_entries
    |> Enum.group_by(fn {_id, entry, _first, _latest} ->
      :crypto.hash(:sha256, entry.content)
    end)
    |> Enum.map(fn {content_digest, members} ->
      {requested_id, _earliest_entry, earliest_sequence, _earliest_latest} =
        Enum.min_by(members, &pending_identity_order_key/1)

      {_latest_id, canonical_entry, _latest_first, _latest_sequence} =
        Enum.max_by(members, &pending_value_order_key/1)

      %{
        content_digest: content_digest,
        member_ids: Enum.map(members, fn {id, _entry, _first, _latest} -> id end),
        requested_id: requested_id,
        canonical_entry: canonical_entry,
        order_key: earliest_sequence
      }
    end)
    |> Enum.sort_by(& &1.order_key)
  end

  defp pending_group_batch_entry(group) do
    entry = group.canonical_entry

    {
      entry.content,
      entry.embedding,
      Map.put(entry.metadata, :id, group.requested_id)
    }
  end

  defp pending_identity_order_key({_id, _entry, first_sequence, _latest_sequence}),
    do: first_sequence

  defp pending_value_order_key({_id, _entry, _first_sequence, latest_sequence}),
    do: latest_sequence

  defp validate_authoritative_bindings(state, groups, authoritative_ids) do
    validate_authoritative_bindings(state, groups, authoritative_ids, MapSet.new(), [])
  end

  defp validate_authoritative_bindings(_state, [], [], _seen_ids, bindings) do
    {:ok, Enum.reverse(bindings)}
  end

  defp validate_authoritative_bindings(
         state,
         [group | groups],
         [authoritative_id | authoritative_ids],
         seen_ids,
         bindings
       ) do
    with false <- MapSet.member?(seen_ids, authoritative_id),
         :ok <-
           validate_authoritative_binding(
             state,
             group.canonical_entry.content,
             authoritative_id
           ) do
      validate_authoritative_bindings(
        state,
        groups,
        authoritative_ids,
        MapSet.put(seen_ids, authoritative_id),
        [{group, authoritative_id} | bindings]
      )
    else
      _invalid -> {:error, :malformed_persistence_result}
    end
  end

  defp validate_authoritative_bindings(_state, _groups, _ids, _seen_ids, _bindings),
    do: {:error, :malformed_persistence_result}

  defp validate_authoritative_binding(state, expected_content, authoritative_id) do
    with true <- valid_entry_id?(authoritative_id),
         false <- Map.has_key?(state.id_aliases, authoritative_id),
         :ok <- validate_authoritative_local_collision(state, expected_content, authoritative_id) do
      :ok
    else
      _invalid -> {:error, :malformed_persistence_result}
    end
  end

  defp validate_authoritative_local_collision(state, expected_content, authoritative_id) do
    case :ets.lookup(state.table, authoritative_id) do
      [{^authoritative_id, %{content: ^expected_content}}] ->
        :ok

      [{^authoritative_id, _other_entry}] ->
        {:error, :malformed_persistence_result}

      [] ->
        if MapSet.member?(state.pending_sync, authoritative_id),
          do: {:error, :malformed_persistence_result},
          else: :ok
    end
  end

  defp valid_entry_id?(id) when is_binary(id) do
    size = byte_size(id)

    size > 0 and size <= @max_entry_id_bytes and String.valid?(id) and String.trim(id) != ""
  end

  defp valid_entry_id?(_id), do: false

  defp generate_entry_identity(state) do
    entry_id = state.entry_id_generator.()
    now = state.clock.()

    if valid_entry_id?(entry_id) and match?(%DateTime{}, now) do
      {:ok, entry_id, now}
    else
      {:error, :invalid_entry_identity}
    end
  rescue
    _error -> {:error, :invalid_entry_identity}
  catch
    _kind, _reason -> {:error, :invalid_entry_identity}
  end

  defp eager_store(state, entry, metadata) do
    state.persistent_writer.store(state.agent_id, entry.content, entry.embedding, metadata)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp batch_store_with_ids(state, entries) do
    state.persistent_writer.store_batch_with_ids(state.agent_id, entries)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp converge_pending_group(state, group, authoritative_id) do
    member_ids = Enum.sort(group.member_ids)
    member_id_set = MapSet.new(member_ids)

    Enum.each(member_ids, &:ets.delete(state.table, &1))

    authoritative_entry = %{group.canonical_entry | id: authoritative_id}
    :ets.insert(state.table, {authoritative_id, authoritative_entry})

    aliases =
      state.id_aliases
      |> Enum.reject(fn {alias_id, _target_id} -> alias_id == authoritative_id end)
      |> Map.new(fn
        {alias_id, target_id} ->
          if MapSet.member?(member_id_set, target_id),
            do: {alias_id, authoritative_id},
            else: {alias_id, target_id}
      end)
      |> then(fn aliases ->
        Enum.reduce(member_ids, aliases, fn member_id, acc ->
          maybe_put_alias(acc, member_id, authoritative_id)
        end)
      end)

    pending_sync =
      Enum.reduce(member_ids, state.pending_sync, fn member_id, pending ->
        MapSet.delete(pending, member_id)
      end)

    %{
      state
      | entry_count: :ets.info(state.table, :size),
        pending_sync: pending_sync,
        pending_entry_orders: Map.drop(state.pending_entry_orders, member_ids),
        id_aliases: aliases
    }
  end

  defp maybe_put_alias(aliases, id, id), do: aliases

  defp maybe_put_alias(aliases, requested_id, authoritative_id),
    do: Map.put(aliases, requested_id, authoritative_id)

  defp put_local_entry(state, entry) do
    :ets.insert(state.table, {entry.id, entry})
    %{state | entry_count: :ets.info(state.table, :size)}
  end

  defp advance_insertion_sequence(state, insertion_sequence) do
    %{state | next_insertion_sequence: insertion_sequence + 1}
  end

  defp refresh_pending_entry_order(state, id, insertion_sequence) do
    if MapSet.member?(state.pending_sync, id) do
      %{
        state
        | pending_entry_orders:
            Map.update!(state.pending_entry_orders, id, fn order ->
              %{order | latest: insertion_sequence}
            end)
      }
    else
      state
    end
  end

  defp resolve_entry_id(entry_id, state), do: Map.get(state.id_aliases, entry_id, entry_id)

  defp delete_entry(entry_id, %{backend: :pgvector} = state) do
    case Embedding.delete(state.agent_id, entry_id) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp delete_entry(entry_id, state) do
    canonical_id = resolve_entry_id(entry_id, state)

    case :ets.lookup(state.table, canonical_id) do
      [] ->
        {:error, :not_found, state}

      [{^canonical_id, _entry}] when state.backend == :ets ->
        {:ok, remove_local_entry(state, canonical_id)}

      [{^canonical_id, _entry}] ->
        delete_synced_entry(entry_id, canonical_id, state)
    end
  end

  defp delete_synced_entry(requested_id, canonical_id, state) do
    case ensure_entry_synced(canonical_id, state) do
      {:ok, synced_state} ->
        durable_id = resolve_entry_id(requested_id, synced_state)

        case Embedding.delete(synced_state.agent_id, durable_id) do
          :ok -> {:ok, remove_local_entry(synced_state, durable_id)}
          {:error, reason} -> {:error, reason, synced_state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp ensure_entry_synced(canonical_id, state) do
    if MapSet.member?(state.pending_sync, canonical_id) do
      case do_sync_to_persistent(state) do
        {:ok, _count, synced_state} -> {:ok, synced_state}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  defp remove_local_entry(state, canonical_id) do
    :ets.delete(state.table, canonical_id)

    aliases =
      state.id_aliases
      |> Enum.reject(fn {alias_id, target_id} ->
        alias_id == canonical_id or target_id == canonical_id
      end)
      |> Map.new()

    %{
      state
      | entry_count: :ets.info(state.table, :size),
        pending_sync: MapSet.delete(state.pending_sync, canonical_id),
        pending_entry_orders: Map.delete(state.pending_entry_orders, canonical_id),
        id_aliases: aliases
    }
  end
end
