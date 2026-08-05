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
    GenServer.call(server, {:index, content, metadata, opts}, :infinity)
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
  The whole batch is preflighted before mutation. Persistent backends commit
  through the writer's all-or-nothing batch operation. In dual mode, a durable
  error admits the whole batch locally as pending or admits none at capacity.
  Same-content fallback members share one pending authority while every returned
  ID remains usable as an alias; admission is reserved before durable dispatch.
  Fresh rows request the index-generated `mem_*` IDs; durable content dedupe can
  instead return an existing authoritative ID for every matching input item.

  A writer exception or exit can represent commit-acknowledgement loss. Pending
  retry is idempotent and may reconcile a whole prior commit; callers must not
  interpret the fallback acknowledgement as proof that no durable write occurred.

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
    GenServer.call(server, :clear, :infinity)
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
    GenServer.call(server, {:delete, entry_id}, :infinity)
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
      # Unsynced caller-visible IDs represented by each pending authority.
      pending_group_members: %{},
      # A failed eager write can later deduplicate to a different durable ID.
      id_aliases: %{},
      # At most one durable mutation runs outside the GenServer. Other mutations
      # retain invocation order; reads continue against acknowledged ETS state.
      inflight_mutation: nil,
      mutation_queue: :queue.new()
    }

    Logger.debug("Started memory index for agent #{agent_id} with backend #{backend}")
    {:ok, state}
  end

  defp get_backend_config do
    Application.get_env(:arbor_memory, :embedding_backend, :ets)
  end

  @impl true
  def handle_call({:index, _content, _metadata, _opts} = request, from, state),
    do: dispatch_mutation_call(request, from, state)

  def handle_call({:recall, query, opts}, _from, state) do
    result = do_recall(query, opts, state)
    {:reply, result, state}
  end

  def handle_call({:batch_index, _items, _opts} = request, from, state),
    do: dispatch_mutation_call(request, from, state)

  def handle_call(:stats, _from, state) do
    stats = %{
      agent_id: state.agent_id,
      entry_count: state.entry_count,
      max_entries: state.max_entries,
      default_threshold: state.default_threshold
    }

    {:reply, stats, state}
  end

  def handle_call(:clear = request, from, state),
    do: dispatch_mutation_call(request, from, state)

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

  def handle_call({:delete, _entry_id} = request, from, state),
    do: dispatch_mutation_call(request, from, state)

  def handle_call({:warm_cache, _opts} = request, from, state),
    do: dispatch_mutation_call(request, from, state)

  def handle_call({:sync_to_persistent, _opts} = request, from, state),
    do: dispatch_mutation_call(request, from, state)

  def handle_call(:backend_mode, _from, state) do
    {:reply, state.backend, state}
  end

  @impl true
  def handle_info(
        {:persistent_index_result, operation_ref, result},
        %{inflight_mutation: %{operation_ref: operation_ref} = inflight} = state
      ) do
    Process.demonitor(inflight.monitor_ref, [:flush])
    finish_persistent_index(inflight, result, state)
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{inflight_mutation: %{monitor_ref: monitor_ref} = inflight} = state
      ) do
    finish_persistent_index(inflight, {:error, :persistence_indeterminate}, state)
  end

  @impl true
  def terminate(_reason, state) do
    case state.inflight_mutation do
      %{worker_pid: worker_pid} -> Process.exit(worker_pid, :shutdown)
      nil -> :ok
    end

    :ets.delete(state.table)
    :ok
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp dispatch_mutation_call(request, from, %{inflight_mutation: nil} = state),
    do: execute_mutation_call(request, from, state)

  defp dispatch_mutation_call(request, from, state) do
    queued_state = %{state | mutation_queue: :queue.in({request, from}, state.mutation_queue)}
    {:noreply, queued_state}
  end

  defp execute_mutation_call({:index, content, metadata, opts}, from, state) do
    case do_index(content, metadata, opts, state) do
      {:ok, entry_id, new_state} ->
        {:reply, {:ok, entry_id}, new_state}

      {:async, writer_call, completion} ->
        {:noreply, start_persistent_index(writer_call, completion, from, state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp execute_mutation_call({:batch_index, items, opts}, _from, state) do
    case do_batch_index(items, opts, state) do
      {:ok, ids, new_state} -> {:reply, {:ok, ids}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp execute_mutation_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)

    {:reply, :ok,
     %{
       state
       | entry_count: 0,
         pending_sync: MapSet.new(),
         pending_entry_orders: %{},
         pending_group_members: %{},
         id_aliases: %{}
     }}
  end

  defp execute_mutation_call({:delete, entry_id}, _from, state) do
    case delete_entry(entry_id, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  defp execute_mutation_call({:warm_cache, opts}, _from, state) do
    if state.backend in [:pgvector, :dual] do
      {:reply, do_warm_cache(opts, state), state}
    else
      {:reply, {:error, :backend_not_persistent}, state}
    end
  end

  defp execute_mutation_call({:sync_to_persistent, _opts}, _from, state) do
    if state.backend == :dual do
      case do_sync_to_persistent(state) do
        {:ok, count, new_state} -> {:reply, {:ok, count}, new_state}
        error -> {:reply, error, state}
      end
    else
      {:reply, {:error, :not_dual_backend}, state}
    end
  end

  defp start_persistent_index(writer_call, completion, from, state) do
    owner = self()
    operation_ref = make_ref()

    {worker_pid, monitor_ref} =
      spawn_opt(
        fn ->
          result = run_persistent_writer_call(writer_call)
          send(owner, {:persistent_index_result, operation_ref, result})
        end,
        [:link, :monitor]
      )

    %{
      state
      | inflight_mutation: %{
          operation_ref: operation_ref,
          worker_pid: worker_pid,
          monitor_ref: monitor_ref,
          from: from,
          completion: completion
        }
    }
  end

  defp finish_persistent_index(inflight, result, state) do
    {reply, new_state} = complete_persistent_index(inflight.completion, result, state)
    GenServer.reply(inflight.from, reply)

    state_without_inflight = %{new_state | inflight_mutation: nil}
    continue_mutation_queue(state_without_inflight)
  end

  defp continue_mutation_queue(state) do
    case :queue.out(state.mutation_queue) do
      {{:value, {request, from}}, remaining} ->
        state = %{state | mutation_queue: remaining}

        if caller_alive?(from) do
          case execute_mutation_call(request, from, state) do
            {:reply, reply, new_state} ->
              GenServer.reply(from, reply)
              continue_mutation_queue(new_state)

            {:noreply, new_state} ->
              {:noreply, new_state}
          end
        else
          continue_mutation_queue(state)
        end

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  defp caller_alive?({pid, _tag}) when is_pid(pid), do: Process.alive?(pid)
  defp caller_alive?(_from), do: false

  defp do_index(content, metadata, opts, state) do
    with {:ok, embedding} <- get_or_compute_embedding(content, opts),
         {:ok, entry_id, now} <- generate_entry_identity(state),
         :ok <- validate_new_entry_id(entry_id, state),
         {:ok, normalized_embedding, normalized_metadata} <-
           preflight_entry(state, content, embedding, metadata, entry_id) do
      insertion_sequence = state.next_insertion_sequence

      entry = %{
        id: entry_id,
        content: content,
        embedding: normalized_embedding,
        metadata: normalized_metadata,
        indexed_at: now,
        accessed_at: now,
        access_count: 0
      }

      # Store based on backend mode
      case state.backend do
        :ets ->
          with {:ok, eviction_ids} <- plan_local_admission(state, [entry_id]) do
            new_state =
              state
              |> apply_local_admission(eviction_ids)
              |> put_local_entry(entry)
              |> advance_insertion_sequence(insertion_sequence)

            {:ok, entry_id, new_state}
          end

        :pgvector ->
          writer_call =
            {Embedding, state.agent_id, entry, with_requested_id(normalized_metadata, entry_id)}

          {:async, writer_call, {:pgvector_index, insertion_sequence}}

        :dual ->
          candidate = %{entry: entry, insertion_sequence: insertion_sequence, position: 0}
          [group] = group_prepared_batch_entries([candidate], state)

          with {:ok, pending_admission} <- plan_pending_group_admission(state, [group]) do
            writer_call =
              {state.persistent_writer, state.agent_id, group.canonical_entry,
               with_requested_id(group.canonical_entry.metadata, group.requested_id)}

            {:async, writer_call, {:dual_index, entry_id, group, pending_admission}}
          end
      end
    end
  end

  defp complete_persistent_index({:pgvector_index, insertion_sequence}, result, state) do
    case result do
      {:ok, authoritative_id} ->
        {{:ok, authoritative_id}, advance_insertion_sequence(state, insertion_sequence)}

      {:error, {:permanent, reason}} ->
        {{:error, reason}, state}

      {:error, {:malformed, reason}} ->
        {{:error, reason}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp complete_persistent_index(
         {:dual_index, entry_id, group, pending_admission},
         result,
         state
       ) do
    case result do
      {:ok, authoritative_id} ->
        with :ok <-
               validate_authoritative_binding(
                 state,
                 group.canonical_entry.content,
                 authoritative_id
               ),
             {:ok, admitted_state} <-
               cache_authoritative_bindings(state, [{group, authoritative_id}]) do
          new_state = advance_insertion_sequence(admitted_state, group.canonical_sequence)
          {{:ok, authoritative_id}, new_state}
        else
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, {:permanent, reason}} ->
        {{:error, reason}, state}

      {:error, {:malformed, reason}} ->
        {{:error, reason}, state}

      {:error, reason} ->
        log_dual_write_failure(entry_id, reason)

        new_state =
          state
          |> apply_local_admission(pending_admission.eviction_ids)
          |> cache_pending_groups([group], pending_admission)
          |> advance_insertion_sequence(group.canonical_sequence)

        {{:ok, entry_id}, new_state}
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
    with {:ok, prepared} <- prepare_batch_entries(items, opts, state) do
      case state.backend do
        :ets ->
          with {:ok, eviction_ids} <- plan_prepared_batch_admission(state, prepared) do
            commit_ets_batch(prepared, eviction_ids, state)
          end

        :pgvector ->
          commit_persistent_batch(prepared, state, Embedding)

        :dual ->
          commit_persistent_batch(prepared, state, state.persistent_writer)
      end
    end
  end

  defp prepare_batch_entries(items, opts, state) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {{content, metadata}, offset}, {:ok, prepared}
      when is_binary(content) and is_map(metadata) ->
        with {:ok, embedding} <- get_or_compute_embedding(content, opts),
             {:ok, entry_id, now} <- generate_entry_identity(state) do
          insertion_sequence = state.next_insertion_sequence + offset

          entry = %{
            id: entry_id,
            content: content,
            embedding: embedding,
            metadata: normalize_metadata(metadata),
            indexed_at: now,
            accessed_at: now,
            access_count: 0
          }

          candidate = %{
            entry: entry,
            input_metadata: metadata,
            insertion_sequence: insertion_sequence,
            position: offset
          }

          {:cont, {:ok, [candidate | prepared]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _invalid_item, _acc ->
        {:halt, {:error, :invalid_batch}}
    end)
    |> case do
      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)

        with :ok <- validate_prepared_batch_identities(prepared, state),
             {:ok, preflighted} <- preflight_prepared_batch(prepared, state) do
          {:ok, preflighted}
        end

      error ->
        error
    end
  rescue
    _error -> {:error, :invalid_batch}
  catch
    _kind, _reason -> {:error, :invalid_batch}
  end

  defp prepare_batch_entries(_items, _opts, _state), do: {:error, :invalid_batch}

  defp validate_prepared_batch_identities(prepared, state) do
    ids = Enum.map(prepared, & &1.entry.id)
    occupied_ids = occupied_entry_ids(state)

    if length(ids) == MapSet.size(MapSet.new(ids)) and
         Enum.all?(ids, &(not MapSet.member?(occupied_ids, &1))) do
      :ok
    else
      {:error, :invalid_batch_identity}
    end
  end

  defp preflight_prepared_batch(prepared, %{backend: :ets}) do
    {:ok, Enum.map(prepared, &Map.delete(&1, :input_metadata))}
  end

  defp preflight_prepared_batch(prepared, state) do
    Enum.reduce_while(prepared, {:ok, []}, fn candidate, {:ok, validated} ->
      entry = candidate.entry

      case Embedding.validate(
             state.agent_id,
             entry.content,
             entry.embedding,
             candidate.input_metadata
           ) do
        {:ok, normalized_embedding} ->
          normalized_entry = %{
            entry
            | embedding: normalized_embedding,
              metadata: sanitize_entry_metadata(candidate.input_metadata)
          }

          normalized_candidate =
            candidate
            |> Map.delete(:input_metadata)
            |> Map.put(:entry, normalized_entry)

          {:cont, {:ok, [normalized_candidate | validated]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp commit_ets_batch(prepared, eviction_ids, state) do
    new_state =
      prepared
      |> Enum.reduce(apply_local_admission(state, eviction_ids), fn %{entry: entry}, acc ->
        put_local_entry(acc, entry)
      end)
      |> advance_prepared_batch_sequence(prepared)

    {:ok, Enum.map(prepared, & &1.entry.id), new_state}
  end

  defp commit_persistent_batch([], state, _writer), do: {:ok, [], state}

  defp commit_persistent_batch(prepared, state, writer) do
    groups = group_prepared_batch_entries(prepared, state)
    entries = Enum.map(groups, &prepared_group_batch_entry/1)

    with {:ok, pending_admission} <- plan_persistent_batch_admission(state, groups) do
      case batch_store_with_ids(state, writer, entries) do
        {:ok, authoritative_ids} ->
          with {:ok, bindings} <-
                 validate_authoritative_bindings(state, groups, authoritative_ids),
               {:ok, admitted_state} <- cache_authoritative_bindings(state, bindings) do
            ids = expand_batch_authoritative_ids(bindings)

            new_state = advance_prepared_batch_sequence(admitted_state, prepared)

            {:ok, ids, new_state}
          end

        {:error, reason} ->
          maybe_commit_pending_batch(prepared, groups, pending_admission, state, reason)
      end
    end
  end

  defp maybe_commit_pending_batch(
         prepared,
         groups,
         pending_admission,
         %{backend: :dual} = state,
         reason
       ) do
    case reason do
      {:permanent, permanent_reason} -> {:error, permanent_reason}
      {:malformed, malformed_reason} -> {:error, malformed_reason}
      _indeterminate -> commit_pending_batch(prepared, groups, pending_admission, state, reason)
    end
  end

  defp maybe_commit_pending_batch(_prepared, _groups, _admission, _state, reason) do
    case reason do
      {:permanent, permanent_reason} -> {:error, permanent_reason}
      {:malformed, malformed_reason} -> {:error, malformed_reason}
      other -> {:error, other}
    end
  end

  defp commit_pending_batch(prepared, groups, pending_admission, state, reason) do
    Enum.each(prepared, fn %{entry: entry} -> log_dual_write_failure(entry.id, reason) end)

    new_state =
      state
      |> apply_local_admission(pending_admission.eviction_ids)
      |> cache_pending_groups(groups, pending_admission)
      |> advance_prepared_batch_sequence(prepared)

    {:ok, Enum.map(prepared, & &1.entry.id), new_state}
  end

  defp group_prepared_batch_entries(prepared, state) do
    prepared
    |> Enum.group_by(fn %{entry: entry} -> :crypto.hash(:sha256, entry.content) end)
    |> Enum.map(fn {content_digest, members} ->
      ordered_members = Enum.sort_by(members, & &1.insertion_sequence)
      first = hd(ordered_members)
      latest = List.last(ordered_members)
      local_member_ids = local_content_ids(state, latest.entry.content)

      {requested_id, first_sequence} =
        prepared_group_identity(state, local_member_ids, first)

      prepared_member_ids = Enum.map(ordered_members, & &1.entry.id)

      %{
        content_digest: content_digest,
        member_ids: Enum.uniq(local_member_ids ++ prepared_member_ids),
        prepared_member_ids: prepared_member_ids,
        member_positions: Enum.map(ordered_members, & &1.position),
        requested_id: requested_id,
        first_sequence: first_sequence,
        canonical_entry: latest.entry,
        canonical_sequence: latest.insertion_sequence,
        order_key: first.insertion_sequence
      }
    end)
    |> Enum.sort_by(& &1.order_key)
  end

  defp prepared_group_identity(state, local_member_ids, first) do
    synced_ids =
      Enum.reject(local_member_ids, &MapSet.member?(state.pending_sync, &1))

    pending_members =
      Enum.flat_map(local_member_ids, fn id ->
        case Map.fetch(state.pending_entry_orders, id) do
          {:ok, order} -> [{id, order}]
          :error -> []
        end
      end)

    first_sequence =
      case pending_members do
        [] -> first.insertion_sequence
        members -> members |> Enum.map(fn {_id, order} -> order.first end) |> Enum.min()
      end

    cond do
      synced_ids != [] ->
        {Enum.min(synced_ids), first_sequence}

      pending_members != [] ->
        {id, order} = Enum.min_by(pending_members, fn {_id, order} -> order.first end)
        {id, order.first}

      true ->
        {first.entry.id, first.insertion_sequence}
    end
  end

  defp prepared_group_batch_entry(group) do
    entry = group.canonical_entry
    {entry.content, entry.embedding, with_requested_id(entry.metadata, group.requested_id)}
  end

  defp expand_batch_authoritative_ids(bindings) do
    bindings
    |> Enum.flat_map(fn {group, authoritative_id} ->
      Enum.map(group.member_positions, &{&1, authoritative_id})
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp cache_authoritative_bindings(%{backend: :pgvector} = state, _bindings),
    do: {:ok, state}

  defp cache_authoritative_bindings(state, bindings) do
    with {:ok, admission} <- plan_authoritative_admission(state, bindings) do
      admitted_state = apply_local_admission(state, admission.eviction_ids)

      new_state =
        Enum.reduce(bindings, admitted_state, fn {group, authoritative_id}, acc ->
          replacement_ids = Map.fetch!(admission.replacement_ids, authoritative_id)

          if replacement_ids == [] do
            authoritative_entry = %{group.canonical_entry | id: authoritative_id}
            put_local_entry(acc, authoritative_entry)
          else
            converge_local_members(
              acc,
              replacement_ids,
              group.canonical_entry,
              authoritative_id
            )
          end
        end)

      {:ok, new_state}
    else
      {:error, :capacity_exceeded} -> {:error, :indeterminate_persistence_result}
    end
  end

  defp cache_pending_groups(state, groups, admission) do
    Enum.reduce(groups, state, fn group, acc ->
      authoritative_id = group.requested_id

      pending_members =
        Enum.reduce(group.member_ids, MapSet.new(group.prepared_member_ids), fn member_id,
                                                                                members ->
          MapSet.union(
            members,
            Map.get(acc.pending_group_members, member_id, MapSet.new())
          )
        end)

      member_ids =
        admission.replacement_ids
        |> Map.fetch!(authoritative_id)
        |> Kernel.++(group.member_ids)
        |> Enum.uniq()

      acc
      |> converge_local_members(member_ids, group.canonical_entry, authoritative_id)
      |> mark_pending_group(
        authoritative_id,
        group.first_sequence,
        group.canonical_sequence,
        pending_members
      )
    end)
  end

  defp advance_prepared_batch_sequence(state, []), do: state

  defp advance_prepared_batch_sequence(state, prepared) do
    %{insertion_sequence: insertion_sequence} = List.last(prepared)
    advance_insertion_sequence(state, insertion_sequence)
  end

  @spec get_or_compute_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  defp get_or_compute_embedding(content, opts) do
    case Keyword.get(opts, :embedding) do
      nil ->
        compute_embedding(content)

      embedding when is_list(embedding) ->
        {:ok, embedding}

      _invalid_embedding ->
        {:error, :invalid_embedding}
    end
  end

  defp preflight_entry(%{backend: :ets}, _content, embedding, metadata, _entry_id),
    do: {:ok, embedding, normalize_metadata(metadata)}

  defp preflight_entry(state, content, embedding, metadata, _entry_id) do
    case Embedding.validate(state.agent_id, content, embedding, metadata) do
      {:ok, normalized_embedding} ->
        {:ok, normalized_embedding, sanitize_entry_metadata(metadata)}

      {:error, reason} ->
        {:error, reason}
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

  defp plan_prepared_batch_admission(state, prepared) do
    plan_local_admission(state, Enum.map(prepared, & &1.entry.id))
  end

  defp plan_persistent_batch_admission(%{backend: :pgvector}, _groups), do: {:ok, nil}

  defp plan_persistent_batch_admission(state, groups),
    do: plan_pending_group_admission(state, groups)

  defp plan_pending_group_admission(state, groups) do
    bindings = Enum.map(groups, &{&1, &1.requested_id})
    plan_authoritative_admission(state, bindings)
  end

  defp plan_authoritative_admission(state, bindings) do
    current_ids = MapSet.new(:ets.select(state.table, [{{:"$1", :_}, [], [:"$1"]}]))

    replacement_ids =
      Map.new(bindings, fn {group, authoritative_id} ->
        {authoritative_id, local_content_ids(state, group.canonical_entry.content)}
      end)

    removed_ids = replacement_ids |> Map.values() |> List.flatten() |> MapSet.new()

    additions = length(bindings)

    projected_count = MapSet.size(current_ids) - MapSet.size(removed_ids) + additions
    slots_to_free = max(projected_count - state.max_entries, 0)

    authoritative_ids =
      MapSet.new(bindings, fn {_group, authoritative_id} -> authoritative_id end)

    candidates =
      state
      |> safely_evictable_entries()
      |> Enum.reject(fn {id, _entry} ->
        MapSet.member?(removed_ids, id) or MapSet.member?(authoritative_ids, id)
      end)

    if slots_to_free <= length(candidates) do
      {:ok,
       %{
         eviction_ids: candidates |> Enum.take(slots_to_free) |> Enum.map(&elem(&1, 0)),
         replacement_ids: replacement_ids
       }}
    else
      {:error, :capacity_exceeded}
    end
  end

  defp plan_local_admission(state, incoming_ids) do
    current_count = :ets.info(state.table, :size)
    slots_to_free = max(current_count + length(incoming_ids) - state.max_entries, 0)
    candidates = safely_evictable_entries(state)

    if slots_to_free <= length(candidates) do
      {:ok, candidates |> Enum.take(slots_to_free) |> Enum.map(&elem(&1, 0))}
    else
      {:error, :capacity_exceeded}
    end
  end

  defp safely_evictable_entries(state) do
    protected_ids =
      state.pending_sync
      |> MapSet.union(MapSet.new(Map.keys(state.id_aliases)))
      |> MapSet.union(MapSet.new(Map.values(state.id_aliases)))

    state.table
    |> :ets.tab2list()
    |> Enum.reject(fn {id, _entry} -> MapSet.member?(protected_ids, id) end)
    |> Enum.sort_by(fn {_id, entry} -> entry.accessed_at end, DateTime)
  end

  defp local_content_ids(state, content) do
    state.table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {id, %{content: ^content}} -> [id]
      {_id, _entry} -> []
    end)
  end

  defp validate_new_entry_id(entry_id, state) do
    if MapSet.member?(occupied_entry_ids(state), entry_id),
      do: {:error, :invalid_entry_identity},
      else: :ok
  end

  defp occupied_entry_ids(state) do
    pending_member_ids =
      state.pending_group_members
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1))

    state.pending_sync
    |> MapSet.union(pending_member_ids)
    |> MapSet.union(MapSet.new(Map.keys(state.id_aliases)))
    |> MapSet.union(MapSet.new(Map.values(state.id_aliases)))
    |> MapSet.union(MapSet.new(:ets.select(state.table, [{{:"$1", :_}, [], [:"$1"]}])))
  end

  defp apply_local_admission(state, eviction_ids) do
    Enum.each(eviction_ids, &:ets.delete(state.table, &1))
    %{state | entry_count: :ets.info(state.table, :size)}
  end

  defp generate_entry_id do
    "mem_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    # Safely atomize known keys
    known_keys = [:type, :source, :tags, :agent_id, :correlation_id]
    SafeAtom.atomize_keys(metadata, known_keys)
  end

  defp normalize_metadata(_), do: %{}

  defp sanitize_entry_metadata(metadata) do
    metadata
    |> normalize_metadata()
    |> Map.drop([:id, "id"])
  end

  defp with_requested_id(metadata, requested_id) when is_map(metadata) do
    metadata
    |> Map.drop([:id, "id"])
    |> Map.put(:id, requested_id)
  end

  defp with_requested_id(metadata, _requested_id), do: metadata

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
        {:ok, 0,
         %{
           state
           | pending_sync: MapSet.new(),
             pending_entry_orders: %{},
             pending_group_members: %{}
         }}
      else
        groups = group_pending_entries(pending_entries)
        entries = Enum.map(groups, &pending_group_batch_entry/1)
        converged_count = pending_converged_count(state, pending_ids)

        case batch_store_with_ids(state, entries) do
          {:ok, authoritative_ids} ->
            with {:ok, bindings} <-
                   validate_authoritative_bindings(state, groups, authoritative_ids) do
              new_state =
                Enum.reduce(bindings, state, fn {group, authoritative_id}, acc ->
                  converge_pending_group(acc, group, authoritative_id)
                end)

              {:ok, converged_count, new_state}
            end

          {:error, {:permanent, reason}} ->
            {:error, reason}

          {:error, {:malformed, reason}} ->
            {:error, reason}

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

  defp pending_converged_count(state, pending_ids) do
    Enum.reduce(pending_ids, 0, fn id, count ->
      count + MapSet.size(Map.get(state.pending_group_members, id, MapSet.new([id])))
    end)
  end

  defp pending_identity_order_key({_id, _entry, first_sequence, _latest_sequence}),
    do: first_sequence

  defp pending_value_order_key({_id, _entry, _first_sequence, latest_sequence}),
    do: latest_sequence

  defp validate_authoritative_bindings(state, groups, authoritative_ids) do
    with {:ok, member_owners} <- prepared_member_owners(groups) do
      validate_authoritative_bindings(
        state,
        groups,
        authoritative_ids,
        member_owners,
        MapSet.new(),
        []
      )
    end
  end

  defp validate_authoritative_bindings(_state, [], [], _member_owners, _seen_ids, bindings) do
    {:ok, Enum.reverse(bindings)}
  end

  defp validate_authoritative_bindings(
         state,
         [group | groups],
         [authoritative_id | authoritative_ids],
         member_owners,
         seen_ids,
         bindings
       ) do
    with false <- MapSet.member?(seen_ids, authoritative_id),
         :ok <- validate_prepared_member_owner(group, authoritative_id, member_owners),
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
        member_owners,
        MapSet.put(seen_ids, authoritative_id),
        [{group, authoritative_id} | bindings]
      )
    else
      _invalid -> {:error, :malformed_persistence_result}
    end
  end

  defp validate_authoritative_bindings(
         _state,
         _groups,
         _ids,
         _member_owners,
         _seen_ids,
         _bindings
       ),
       do: {:error, :malformed_persistence_result}

  defp prepared_member_owners(groups) do
    Enum.reduce_while(groups, {:ok, %{}}, fn group, {:ok, owners} ->
      owner = group_owner(group)

      Enum.reduce_while(group.member_ids, {:ok, owners}, fn member_id, {:ok, acc} ->
        case Map.fetch(acc, member_id) do
          :error -> {:cont, {:ok, Map.put(acc, member_id, owner)}}
          {:ok, ^owner} -> {:cont, {:ok, acc}}
          {:ok, _other_owner} -> {:halt, {:error, :malformed_persistence_result}}
        end
      end)
      |> case do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_prepared_member_owner(group, authoritative_id, member_owners) do
    expected_owner = group_owner(group)

    case Map.fetch(member_owners, authoritative_id) do
      :error -> :ok
      {:ok, ^expected_owner} -> :ok
      {:ok, _other_owner} -> {:error, :malformed_persistence_result}
    end
  end

  defp group_owner(group), do: {group.content_digest, group.order_key}

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

  defp run_persistent_writer_call({writer, agent_id, entry, metadata}) do
    writer.store(agent_id, entry.content, entry.embedding, metadata)
    |> normalize_single_writer_result()
  rescue
    _error -> {:error, :persistence_indeterminate}
  catch
    _kind, _reason -> {:error, :persistence_indeterminate}
  end

  defp normalize_single_writer_result({:ok, authoritative_id}) do
    if valid_entry_id?(authoritative_id),
      do: {:ok, authoritative_id},
      else: {:error, {:malformed, :malformed_persistence_result}}
  end

  defp normalize_single_writer_result({:error, reason}), do: normalize_writer_error(reason)

  defp normalize_single_writer_result(_malformed),
    do: {:error, {:malformed, :malformed_persistence_result}}

  defp normalize_writer_error({:invalid_legacy_embedding, reason}) when is_atom(reason),
    do: {:error, {:permanent, {:invalid_legacy_embedding, reason}}}

  defp normalize_writer_error(:protected_vector_row),
    do: {:error, {:permanent, :protected_vector_row}}

  defp normalize_writer_error(_reason), do: {:error, :persistence_indeterminate}

  defp batch_store_with_ids(state, entries) do
    batch_store_with_ids(state, state.persistent_writer, entries)
  end

  defp batch_store_with_ids(state, writer, entries) do
    writer.store_batch_with_ids(state.agent_id, entries)
    |> normalize_batch_writer_result(length(entries))
  rescue
    _error -> {:error, :persistence_indeterminate}
  catch
    _kind, _reason -> {:error, :persistence_indeterminate}
  end

  defp normalize_batch_writer_result({:ok, authoritative_ids}, expected_count)
       when is_list(authoritative_ids) do
    if length(authoritative_ids) == expected_count and
         Enum.all?(authoritative_ids, &valid_entry_id?/1) do
      {:ok, authoritative_ids}
    else
      {:error, {:malformed, :malformed_persistence_result}}
    end
  end

  defp normalize_batch_writer_result({:error, reason}, _expected_count),
    do: normalize_writer_error(reason)

  defp normalize_batch_writer_result(_malformed, _expected_count),
    do: {:error, {:malformed, :malformed_persistence_result}}

  defp converge_pending_group(state, group, authoritative_id) do
    converge_local_members(state, group.member_ids, group.canonical_entry, authoritative_id)
  end

  defp converge_local_members(state, member_ids, canonical_entry, authoritative_id) do
    member_ids = Enum.sort(member_ids)
    member_id_set = MapSet.new(member_ids)

    Enum.each(member_ids, &:ets.delete(state.table, &1))

    authoritative_entry = %{canonical_entry | id: authoritative_id}
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
        pending_group_members: Map.drop(state.pending_group_members, member_ids),
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

  defp mark_pending_group(state, id, first_sequence, latest_sequence, pending_members) do
    %{
      state
      | pending_sync: MapSet.put(state.pending_sync, id),
        pending_entry_orders:
          Map.put(state.pending_entry_orders, id, %{
            first: first_sequence,
            latest: latest_sequence
          }),
        pending_group_members: Map.put(state.pending_group_members, id, pending_members)
    }
  end

  defp advance_insertion_sequence(state, insertion_sequence) do
    %{state | next_insertion_sequence: insertion_sequence + 1}
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
        pending_group_members: Map.delete(state.pending_group_members, canonical_id),
        id_aliases: aliases
    }
  end
end
