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
  - `:pgvector` — durable strict vector store only
  - `:dual` — Write to both, read from ETS first then durable ANN

  Durable paths use `Arbor.Memory.StrictVectorSeam` (encode/execute/reconcile and
  search/fetch/list). Logical identity is `{agent_id, "memory_index", entry_id}`.

  ## Examples

      # Start an index for an agent
      {:ok, pid} = Arbor.Memory.Index.start_link(agent_id: "agent_001")

      # Index content
      {:ok, entry_id} = Arbor.Memory.Index.index(pid, "Hello world", %{type: :fact})

      # Recall similar content
      {:ok, results} = Arbor.Memory.Index.recall(pid, "greeting")

      # Warm cache from durable store (in dual mode)
      :ok = Arbor.Memory.Index.warm_cache(pid, limit: 1000)
  """

  use GenServer

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorRecord}
  alias Arbor.Common.SafeAtom
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory.EmbeddingEvidence
  alias Arbor.Memory.Index.Input
  alias Arbor.Memory.StrictEmbeddingInput
  alias Arbor.Memory.StrictVectorSeam

  require Logger

  @index_namespace "memory_index"

  @type entry_id :: String.t()
  @type entry :: %{
          id: entry_id(),
          content: String.t(),
          embedding: [float()],
          metadata: map(),
          indexed_at: DateTime.t(),
          accessed_at: DateTime.t(),
          access_count: non_neg_integer(),
          model_id: String.t() | nil,
          dimensions: pos_integer() | nil,
          encoding: term() | nil,
          category: String.t() | nil,
          taint: term() | nil,
          provenance_status: atom() | nil,
          model_evidence: term() | nil
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
  @default_operation_timeout_ms 15_000
  @default_max_pending_mutations 16
  @default_max_concurrent_recalls 4
  @max_operation_timeout_ms 120_000
  @max_pending_mutations 64
  @max_concurrent_recalls 32
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
  - `:strict_vector_seam` - Injectable strict vector seam (default: app env / Default).
    Selected only from process start options or trusted application config.
  - `:embedding_provider` - Embedding provider module (default: `Arbor.AI`)
  - `:entry_id_generator` - Zero-arity entry ID generator (default: random `mem_` ID)
  - `:clock` - Zero-arity UTC clock (default: `DateTime.utc_now/0`)
  - `:operation_timeout_ms` - Finite deadline for one serialized mutation (default: 15s)
  - `:max_pending_mutations` - Bounded mutation queue depth (default: 16)
  - `:max_concurrent_recalls` - Bounded concurrent recall workers (default: 4)

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
    with {:ok, {content, metadata, opts}} <- Input.index(content, metadata, opts) do
      GenServer.call(server, {:index, content, metadata, opts}, :infinity)
    end
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
    with {:ok, {query, opts}} <- Input.recall(query, opts) do
      GenServer.call(server, {:recall, query, opts}, :infinity)
    end
  end

  @doc """
  Index multiple items in a batch.

  Each item should be a tuple of `{content, metadata}`.
  The whole batch is preflighted before mutation. Persistent backends commit
  through the strict vector seam as one atomic batch. In dual mode, a durable
  error admits the whole batch locally as pending or admits none at capacity.
  Each entry_id is its own durable identity — equal content under distinct keys
  remains distinct. Admission is reserved before durable dispatch.

  A writer exception or exit can represent commit-acknowledgement loss. Pending
  retry is idempotent and may reconcile a whole prior commit against exact
  logical identity; callers must not interpret the fallback acknowledgement as
  proof that no durable write occurred.

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
    with {:ok, {items, opts}} <- Input.batch(items, opts) do
      GenServer.call(server, {:batch_index, items, opts}, :infinity)
    end
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
    with {:ok, entry_id} <- Input.get(entry_id) do
      GenServer.call(server, {:get, entry_id})
    end
  end

  @doc """
  Delete a specific entry by ID.
  """
  @spec delete(GenServer.server(), entry_id()) :: :ok | {:error, :not_found}
  def delete(server, entry_id) do
    with {:ok, entry_id} <- Input.delete(entry_id) do
      GenServer.call(server, {:delete, entry_id}, :infinity)
    end
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
    with {:ok, opts} <- Input.warm(opts) do
      GenServer.call(server, {:warm_cache, opts}, :infinity)
    end
  end

  @doc """
  Sync ETS entries to the persistent backend.

  Flushes entries that haven't been persisted yet to pgvector.
  Only useful in `:dual` backend mode.

  The returned count is the number of acknowledged local entries that
  converged against exact logical identity
  `{agent_id, "memory_index", entry_id}`. Equal content under distinct keys
  remains distinct. Ordering comes from a process-local monotonic sequence
  assigned by the serialized index, never from wall-clock timestamps.

  ## Examples

      {:ok, count} = Arbor.Memory.Index.sync_to_persistent(pid)
  """
  @spec sync_to_persistent(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_to_persistent(server, opts \\ []) do
    with {:ok, opts} <- Input.sync(opts) do
      GenServer.call(server, {:sync_to_persistent, opts}, :infinity)
    end
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

    operation_timeout_ms =
      Keyword.get(opts, :operation_timeout_ms, @default_operation_timeout_ms)

    max_pending_mutations =
      Keyword.get(opts, :max_pending_mutations, @default_max_pending_mutations)

    max_concurrent_recalls =
      Keyword.get(opts, :max_concurrent_recalls, @default_max_concurrent_recalls)

    valid_options? =
      is_integer(max_entries) and max_entries > 0 and
        is_number(threshold) and threshold >= -1.0 and threshold <= 1.0 and
        backend in [:ets, :pgvector, :dual] and
        is_integer(operation_timeout_ms) and operation_timeout_ms > 0 and
        operation_timeout_ms <= @max_operation_timeout_ms and
        is_integer(max_pending_mutations) and max_pending_mutations >= 0 and
        max_pending_mutations <= @max_pending_mutations and
        is_integer(max_concurrent_recalls) and max_concurrent_recalls > 0 and
        max_concurrent_recalls <= @max_concurrent_recalls

    unless valid_options?, do: raise(ArgumentError, "invalid memory index options")

    # Create ETS table for this index
    table = :ets.new(:memory_index, [:set, :protected])

    state = %{
      agent_id: agent_id,
      table: table,
      max_entries: max_entries,
      default_threshold: threshold,
      entry_count: 0,
      backend: backend,
      strict_vector_seam: StrictVectorSeam.resolve(opts),
      embedding_provider: Keyword.get(opts, :embedding_provider, Arbor.AI),
      entry_id_generator: Keyword.get(opts, :entry_id_generator, &generate_entry_id/0),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      operation_timeout_ms: operation_timeout_ms,
      max_pending_mutations: max_pending_mutations,
      max_concurrent_recalls: max_concurrent_recalls,
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
      mutation_queue: :queue.new(),
      inflight_recalls: %{}
    }

    Logger.debug("Started memory index for agent #{agent_id} with backend #{backend}")
    {:ok, state}
  end

  @impl true
  def handle_call({:index, _content, _metadata, _opts} = request, from, state),
    do: dispatch_mutation_call(request, from, state)

  def handle_call({:recall, query, opts}, from, state),
    do: dispatch_recall(query, opts, from, state)

  def handle_call(:recall_context, _from, state), do: {:reply, {:error, :unsupported}, state}

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

  defp get_backend_config do
    Application.get_env(:arbor_memory, :embedding_backend, :ets)
  end

  @impl true
  def handle_info(
        {:background_operation_result, operation_ref, result},
        %{inflight_mutation: %{operation_ref: operation_ref} = inflight} = state
      ) do
    inflight = put_operation_result(inflight, result)
    maybe_finish_mutation(%{state | inflight_mutation: inflight})
  end

  def handle_info(
        {:background_operation_cancelled, operation_ref},
        %{inflight_mutation: %{operation_ref: operation_ref} = inflight} = state
      ) do
    result = inflight.cancellation_result || background_failure_result(inflight.worker_call)
    inflight = %{inflight | terminal_result: result}
    maybe_finish_mutation(%{state | inflight_mutation: inflight})
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{inflight_mutation: %{coordinator_monitor_ref: monitor_ref} = inflight} = state
      ) do
    result =
      inflight.terminal_result || inflight.cancellation_result ||
        background_failure_result(inflight.worker_call)

    inflight =
      inflight
      |> Map.put(:coordinator_down?, true)
      |> Map.put(:terminal_result, result)
      |> kill_unsettled_worker()

    maybe_finish_mutation(%{state | inflight_mutation: inflight})
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{inflight_mutation: %{worker_monitor_ref: monitor_ref} = inflight} = state
      ) do
    inflight = %{inflight | worker_down?: true}
    maybe_finish_mutation(%{state | inflight_mutation: inflight})
  end

  def handle_info({:background_operation_result, operation_ref, result}, state) do
    update_recall_operation(state, operation_ref, fn recall ->
      put_operation_result(recall, result)
    end)
  end

  def handle_info({:background_operation_cancelled, operation_ref}, state) do
    update_recall_operation(state, operation_ref, fn recall ->
      result = recall.cancellation_result || background_failure_result(recall.worker_call)
      %{recall | terminal_result: result}
    end)
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case recall_monitor_owner(state.inflight_recalls, monitor_ref) do
      {:coordinator, operation_ref, recall} ->
        result =
          recall.terminal_result || recall.cancellation_result ||
            background_failure_result(recall.worker_call)

        recall =
          recall
          |> Map.put(:coordinator_down?, true)
          |> Map.put(:terminal_result, result)
          |> kill_unsettled_worker()

        maybe_finish_recall(put_in(state.inflight_recalls[operation_ref], recall), operation_ref)

      {:worker, operation_ref, recall} ->
        recall = %{recall | worker_down?: true}
        maybe_finish_recall(put_in(state.inflight_recalls[operation_ref], recall), operation_ref)

      {:caller, operation_ref, _recall} ->
        cancel_recall_operation(state, operation_ref, :caller_down)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:mutation_deadline, mutation_ref},
        %{inflight_mutation: %{mutation_ref: mutation_ref} = inflight} = state
      ) do
    result = deadline_result(inflight.phase)
    cancel_background_operation(inflight.coordinator_pid, inflight.operation_ref)

    inflight = %{
      inflight
      | cancellation_result: result,
        terminal_result: result,
        timer_ref: nil
    }

    maybe_finish_mutation(%{state | inflight_mutation: inflight})
  end

  def handle_info({:recall_deadline, operation_ref}, state) do
    cancel_recall_operation(state, operation_ref, {:error, :operation_timeout})
  end

  def handle_info({:mutation_deadline, _mutation_ref}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp dispatch_recall(query, opts, from, state) do
    if map_size(state.inflight_recalls) >= state.max_concurrent_recalls do
      {:reply, {:error, :recall_saturated}, state}
    else
      context = %{
        agent_id: state.agent_id,
        table: state.table,
        backend: state.backend,
        default_threshold: state.default_threshold,
        embedding_provider: state.embedding_provider,
        strict_vector_seam: state.strict_vector_seam,
        id_aliases: state.id_aliases
      }

      worker_call = {:recall, context, query, opts}

      case start_background_operation(worker_call) do
        {:ok,
         {operation_ref, coordinator_pid, coordinator_monitor_ref, worker_pid, worker_monitor_ref}} ->
          caller_pid = elem(from, 0)
          caller_monitor_ref = Process.monitor(caller_pid)

          timer_ref =
            Process.send_after(
              self(),
              {:recall_deadline, operation_ref},
              state.operation_timeout_ms
            )

          recall = %{
            operation_ref: operation_ref,
            coordinator_pid: coordinator_pid,
            coordinator_monitor_ref: coordinator_monitor_ref,
            coordinator_down?: false,
            worker_pid: worker_pid,
            worker_monitor_ref: worker_monitor_ref,
            worker_down?: false,
            worker_call: worker_call,
            from: from,
            caller_pid: caller_pid,
            caller_monitor_ref: caller_monitor_ref,
            timer_ref: timer_ref,
            cancellation_result: nil,
            terminal_result: nil
          }

          activate_background_operation(coordinator_pid, operation_ref)
          {:noreply, put_in(state.inflight_recalls[operation_ref], recall)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  defp update_recall_operation(state, operation_ref, update) do
    case Map.fetch(state.inflight_recalls, operation_ref) do
      {:ok, recall} ->
        recall = update.(recall)
        maybe_finish_recall(put_in(state.inflight_recalls[operation_ref], recall), operation_ref)

      :error ->
        {:noreply, state}
    end
  end

  defp cancel_recall_operation(state, operation_ref, result) do
    case Map.fetch(state.inflight_recalls, operation_ref) do
      {:ok, %{cancellation_result: nil} = recall} ->
        cancel_background_operation(recall.coordinator_pid, operation_ref)
        cancel_mutation_deadline(recall.timer_ref)

        recall = %{
          recall
          | cancellation_result: result,
            terminal_result: result,
            timer_ref: nil
        }

        maybe_finish_recall(put_in(state.inflight_recalls[operation_ref], recall), operation_ref)

      {:ok, _recall} ->
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  defp recall_monitor_owner(recalls, monitor_ref) do
    Enum.find_value(recalls, fn {operation_ref, recall} ->
      cond do
        recall.coordinator_monitor_ref == monitor_ref ->
          {:coordinator, operation_ref, recall}

        recall.worker_monitor_ref == monitor_ref ->
          {:worker, operation_ref, recall}

        recall.caller_monitor_ref == monitor_ref ->
          {:caller, operation_ref, recall}

        true ->
          nil
      end
    end)
  end

  defp dispatch_mutation_call(request, from, state) do
    deadline = monotonic_milliseconds() + state.operation_timeout_ms

    cond do
      is_nil(state.inflight_mutation) ->
        execute_mutation_call(request, from, deadline, state)

      :queue.len(state.mutation_queue) < state.max_pending_mutations ->
        queued = :queue.in({request, from, deadline}, state.mutation_queue)
        {:noreply, %{state | mutation_queue: queued}}

      true ->
        {:reply, {:error, :mutation_queue_full}, state}
    end
  end

  defp execute_mutation_call({:index, content, metadata, opts}, from, deadline, state) do
    worker_call =
      {:preflight_index, state.backend, state.agent_id, state.embedding_provider,
       state.entry_id_generator, state.clock, content, metadata, opts}

    start_persistent_mutation(
      worker_call,
      :preflight_index,
      :preflight,
      from,
      deadline,
      state
    )
  end

  defp execute_mutation_call({:batch_index, items, opts}, from, deadline, state) do
    worker_call =
      {:preflight_batch, state.backend, state.agent_id, state.embedding_provider,
       state.entry_id_generator, state.clock, items, opts}

    start_persistent_mutation(
      worker_call,
      :preflight_batch,
      :preflight,
      from,
      deadline,
      state
    )
  end

  defp execute_mutation_call(:clear, _from, _deadline, state) do
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

  defp execute_mutation_call({:delete, entry_id}, from, deadline, state) do
    case prepare_delete(entry_id, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:async, worker_call, completion, phase} ->
        start_persistent_mutation(worker_call, completion, phase, from, deadline, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp execute_mutation_call({:warm_cache, opts}, from, deadline, state) do
    if state.backend in [:pgvector, :dual] do
      worker_call =
        {:warm_cache, state.strict_vector_seam, state.agent_id, state.embedding_provider, opts}

      start_persistent_mutation(
        worker_call,
        {:warm_cache, Keyword.fetch!(opts, :limit)},
        :preflight,
        from,
        deadline,
        state
      )
    else
      {:reply, {:error, :backend_not_persistent}, state}
    end
  end

  defp execute_mutation_call({:sync_to_persistent, _opts}, from, deadline, state) do
    if state.backend == :dual do
      case prepare_persistent_sync(state) do
        {:ok, count, new_state} ->
          {:reply, {:ok, count}, new_state}

        {:async, writer_call, completion} ->
          start_persistent_mutation(
            writer_call,
            completion,
            :durable,
            from,
            deadline,
            state
          )
      end
    else
      {:reply, {:error, :not_dual_backend}, state}
    end
  end

  defp start_persistent_mutation(worker_call, completion, phase, from, deadline, state) do
    mutation_ref = make_ref()
    timer_ref = schedule_mutation_deadline(mutation_ref, deadline)

    case start_persistent_stage(
           worker_call,
           completion,
           phase,
           from,
           deadline,
           mutation_ref,
           timer_ref,
           state
         ) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        cancel_mutation_deadline(timer_ref)
        {:reply, {:error, reason}, state}
    end
  end

  defp start_persistent_stage(
         worker_call,
         completion,
         phase,
         from,
         deadline,
         mutation_ref,
         timer_ref,
         state
       ) do
    case start_background_operation(worker_call) do
      {:ok,
       {operation_ref, coordinator_pid, coordinator_monitor_ref, worker_pid, worker_monitor_ref}} ->
        new_state = %{
          state
          | inflight_mutation: %{
              mutation_ref: mutation_ref,
              operation_ref: operation_ref,
              coordinator_pid: coordinator_pid,
              coordinator_monitor_ref: coordinator_monitor_ref,
              coordinator_down?: false,
              worker_pid: worker_pid,
              worker_monitor_ref: worker_monitor_ref,
              worker_down?: false,
              worker_call: worker_call,
              timer_ref: timer_ref,
              deadline: deadline,
              from: from,
              completion: completion,
              phase: phase,
              cancellation_result: nil,
              terminal_result: nil
            }
        }

        activate_background_operation(coordinator_pid, operation_ref)
        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_background_operation(worker_call) do
    owner = self()
    operation_ref = make_ref()

    coordinator_pid =
      spawn(fn -> coordinate_background_operation(owner, operation_ref, worker_call) end)

    coordinator_monitor_ref = Process.monitor(coordinator_pid)

    receive do
      {:background_operation_ready, ^operation_ref, ^coordinator_pid, worker_pid} ->
        worker_monitor_ref = Process.monitor(worker_pid)

        {:ok,
         {operation_ref, coordinator_pid, coordinator_monitor_ref, worker_pid, worker_monitor_ref}}

      {:DOWN, ^coordinator_monitor_ref, :process, ^coordinator_pid, _reason} ->
        {:error, :operation_failed}
    end
  end

  defp coordinate_background_operation(owner, operation_ref, worker_call) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)

    if owner_available?(owner, owner_monitor) do
      coordinate_live_owner(owner, owner_monitor, operation_ref, worker_call)
    end
  end

  defp owner_available?(owner, owner_monitor) do
    if Process.alive?(owner) do
      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> false
      after
        0 -> true
      end
    else
      Process.demonitor(owner_monitor, [:flush])
      false
    end
  end

  defp coordinate_live_owner(owner, owner_monitor, operation_ref, worker_call) do
    coordinator = self()

    {worker_pid, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {:run_background_operation, ^coordinator} ->
              result = run_background_call(worker_call)
              send(coordinator, {:background_worker_result, self(), result})
          end
        end,
        [:link, :monitor]
      )

    send(owner, {:background_operation_ready, operation_ref, coordinator, worker_pid})

    coordinate_inactive_worker(
      owner,
      owner_monitor,
      operation_ref,
      worker_call,
      worker_pid,
      worker_monitor
    )
  end

  defp coordinate_inactive_worker(
         owner,
         owner_monitor,
         operation_ref,
         worker_call,
         worker_pid,
         worker_monitor
       ) do
    receive do
      {:activate_background_operation, ^operation_ref} ->
        send(worker_pid, {:run_background_operation, self()})

        coordinate_active_worker(
          owner,
          owner_monitor,
          operation_ref,
          worker_call,
          worker_pid,
          worker_monitor
        )

      {:cancel_background_operation, ^operation_ref} ->
        stop_worker(worker_pid, worker_monitor)
        Process.demonitor(owner_monitor, [:flush])
        send(owner, {:background_operation_cancelled, operation_ref})

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        stop_worker(worker_pid, worker_monitor)

      {:DOWN, ^worker_monitor, :process, ^worker_pid, _reason} ->
        Process.demonitor(owner_monitor, [:flush])

        send(
          owner,
          {:background_operation_result, operation_ref, background_failure_result(worker_call)}
        )
    end
  end

  defp coordinate_active_worker(
         owner,
         owner_monitor,
         operation_ref,
         worker_call,
         worker_pid,
         worker_monitor
       ) do
    receive do
      {:background_worker_result, ^worker_pid, result} ->
        await_worker_down(worker_monitor, worker_pid)
        Process.demonitor(owner_monitor, [:flush])
        send(owner, {:background_operation_result, operation_ref, result})

      {:cancel_background_operation, ^operation_ref} ->
        stop_worker(worker_pid, worker_monitor)
        Process.demonitor(owner_monitor, [:flush])
        send(owner, {:background_operation_cancelled, operation_ref})

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        stop_worker(worker_pid, worker_monitor)

      {:DOWN, ^worker_monitor, :process, ^worker_pid, _reason} ->
        Process.demonitor(owner_monitor, [:flush])

        send(
          owner,
          {:background_operation_result, operation_ref, background_failure_result(worker_call)}
        )
    end
  end

  defp stop_worker(worker_pid, worker_monitor) do
    Process.exit(worker_pid, :kill)
    await_worker_down(worker_monitor, worker_pid)
  end

  defp await_worker_down(worker_monitor, worker_pid) do
    receive do
      {:DOWN, ^worker_monitor, :process, ^worker_pid, _reason} -> :ok
    end
  end

  defp background_failure_result({:strict_write, _seam, _agent_id, _closed}),
    do: {:error, :persistence_indeterminate}

  defp background_failure_result({:strict_batch, _seam, _agent_id, _closed}),
    do: {:error, :persistence_indeterminate}

  defp background_failure_result({:strict_delete, _seam, _agent_id, _entry_id}),
    do: {:error, :persistence_indeterminate}

  # Legacy shapes retained so mixed-era tests/fakes still map correctly.
  defp background_failure_result({:single, _writer, _agent_id, _entry, _metadata}),
    do: {:error, :persistence_indeterminate}

  defp background_failure_result({:batch, _writer, _agent_id, _entries}),
    do: {:error, :persistence_indeterminate}

  defp background_failure_result({:delete, _agent_id, _entry_id}),
    do: {:error, :persistence_indeterminate}

  defp background_failure_result(_read_or_preflight), do: {:error, :operation_failed}

  defp activate_background_operation(coordinator_pid, operation_ref) do
    send(coordinator_pid, {:activate_background_operation, operation_ref})
    :ok
  end

  defp cancel_background_operation(coordinator_pid, operation_ref) do
    send(coordinator_pid, {:cancel_background_operation, operation_ref})
    :ok
  end

  defp put_operation_result(operation, result) do
    %{operation | terminal_result: operation.cancellation_result || result}
  end

  defp kill_unsettled_worker(%{worker_pid: worker_pid, worker_down?: false} = operation)
       when is_pid(worker_pid) do
    Process.exit(worker_pid, :kill)
    operation
  end

  defp kill_unsettled_worker(operation), do: operation

  defp maybe_finish_mutation(%{inflight_mutation: inflight} = state) do
    if operation_finished?(inflight) do
      cleanup_operation_monitors(inflight)
      advance_persistent_mutation(inflight, inflight.terminal_result, state)
    else
      {:noreply, state}
    end
  end

  defp maybe_finish_recall(state, operation_ref) do
    recall = Map.fetch!(state.inflight_recalls, operation_ref)

    if operation_finished?(recall) do
      cleanup_operation_monitors(recall)
      cancel_mutation_deadline(recall.timer_ref)

      state = %{state | inflight_recalls: Map.delete(state.inflight_recalls, operation_ref)}

      if recall.terminal_result != :caller_down and caller_alive?(recall.from) do
        GenServer.reply(recall.from, recall.terminal_result)
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp operation_finished?(operation) do
    not is_nil(operation.terminal_result) and operation.coordinator_down? and
      (is_nil(operation.worker_pid) or operation.worker_down?)
  end

  defp cleanup_operation_monitors(operation) do
    demonitor(operation.coordinator_monitor_ref)
    demonitor(operation.worker_monitor_ref)

    if Map.has_key?(operation, :caller_monitor_ref) do
      demonitor(operation.caller_monitor_ref)
    end

    :ok
  end

  defp demonitor(nil), do: :ok
  defp demonitor(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])

  defp advance_persistent_mutation(inflight, result, state) do
    case complete_mutation_stage(inflight.completion, result, state) do
      {:continue, worker_call, completion, phase, new_state} ->
        if inflight.deadline <= monotonic_milliseconds() do
          cancel_mutation_deadline(inflight.timer_ref)
          GenServer.reply(inflight.from, {:error, :operation_timeout})
          continue_mutation_queue(%{new_state | inflight_mutation: nil})
        else
          next_state = %{new_state | inflight_mutation: nil}

          case start_persistent_stage(
                 worker_call,
                 completion,
                 phase,
                 inflight.from,
                 inflight.deadline,
                 inflight.mutation_ref,
                 inflight.timer_ref,
                 next_state
               ) do
            {:ok, started_state} ->
              {:noreply, started_state}

            {:error, reason} ->
              cancel_mutation_deadline(inflight.timer_ref)
              GenServer.reply(inflight.from, {:error, reason})
              continue_mutation_queue(next_state)
          end
        end

      {:final, reply, new_state} ->
        cancel_mutation_deadline(inflight.timer_ref)
        GenServer.reply(inflight.from, reply)

        state_without_inflight = %{new_state | inflight_mutation: nil}
        continue_mutation_queue(state_without_inflight)
    end
  end

  defp continue_mutation_queue(state) do
    case :queue.out(state.mutation_queue) do
      {{:value, {request, from, deadline}}, remaining} ->
        state = %{state | mutation_queue: remaining}

        cond do
          not caller_alive?(from) ->
            continue_mutation_queue(state)

          deadline <= monotonic_milliseconds() ->
            GenServer.reply(from, {:error, :operation_timeout})
            continue_mutation_queue(state)

          true ->
            case execute_mutation_call(request, from, deadline, state) do
              {:reply, reply, new_state} ->
                GenServer.reply(from, reply)
                continue_mutation_queue(new_state)

              {:noreply, new_state} ->
                {:noreply, new_state}
            end
        end

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  defp caller_alive?({pid, _tag}) when is_pid(pid), do: Process.alive?(pid)
  defp caller_alive?(_from), do: false

  defp schedule_mutation_deadline(mutation_ref, deadline) do
    remaining = max(deadline - monotonic_milliseconds(), 0)
    Process.send_after(self(), {:mutation_deadline, mutation_ref}, remaining)
  end

  defp cancel_mutation_deadline(nil), do: :ok
  defp cancel_mutation_deadline(timer_ref), do: Process.cancel_timer(timer_ref)

  defp monotonic_milliseconds, do: System.monotonic_time(:millisecond)

  defp deadline_result(:preflight), do: {:error, :operation_timeout}
  defp deadline_result(:durable), do: {:error, :persistence_indeterminate}

  defp do_index(%{entry_id: entry_id, now: now} = prepared, state) do
    with :ok <- validate_new_entry_id(entry_id, state) do
      insertion_sequence = state.next_insertion_sequence

      entry = build_local_entry(entry_id, prepared, now)

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
          closed = closed_index_insert(state.agent_id, entry)

          {:async, {:strict_write, state.strict_vector_seam, state.agent_id, closed},
           {:pgvector_index, insertion_sequence, entry_id}}

        :dual ->
          candidate = %{entry: entry, insertion_sequence: insertion_sequence, position: 0}
          [group] = group_prepared_batch_entries([candidate], state)

          with {:ok, pending_admission} <- plan_pending_group_admission(state, [group]) do
            closed = closed_index_insert(state.agent_id, group.canonical_entry)

            {:async, {:strict_write, state.strict_vector_seam, state.agent_id, closed},
             {:dual_index, entry_id, group, pending_admission}}
          end
      end
    end
  end

  defp build_local_entry(entry_id, prepared, now) do
    type = Map.get(prepared.metadata, :type) || Map.get(prepared.metadata, "type")

    %{
      id: entry_id,
      content: prepared.content,
      embedding: prepared.embedding,
      metadata: prepared.metadata,
      indexed_at: now,
      accessed_at: now,
      access_count: 0,
      model_id: Map.get(prepared, :model_id),
      dimensions: Map.get(prepared, :dimensions, VectorRecord.dimensions()),
      encoding: Map.get(prepared, :encoding, VectorRecord.encoding()),
      category: StrictEmbeddingInput.category_for_type(type),
      taint: Map.get(prepared, :taint, TaintEnvelope.missing_fallback()),
      provenance_status: Map.get(prepared, :provenance_status, :verified),
      model_evidence: Map.get(prepared, :model_evidence, :absent)
    }
  end

  defp closed_index_insert(agent_id, entry) do
    StrictEmbeddingInput.index_insert(%{
      agent_id: agent_id,
      entry_id: entry.id,
      content: entry.content,
      vector: entry.embedding,
      metadata: entry.metadata,
      model_evidence: Map.get(entry, :model_evidence, :absent),
      taint: Map.get(entry, :taint, TaintEnvelope.missing_fallback())
    })
  end

  defp complete_mutation_stage(:preflight_index, result, state) do
    case result do
      {:ok, prepared} ->
        case do_index(prepared, state) do
          {:ok, entry_id, new_state} ->
            {:final, {:ok, entry_id}, new_state}

          {:async, worker_call, completion} ->
            {:continue, worker_call, completion, :durable, state}

          {:error, reason} ->
            {:final, {:error, reason}, state}
        end

      {:error, reason} ->
        {:final, {:error, reason}, state}
    end
  end

  defp complete_mutation_stage(:preflight_batch, result, state) do
    case result do
      {:ok, preflighted} ->
        case do_batch_index(preflighted, state) do
          {:ok, ids, new_state} ->
            {:final, {:ok, ids}, new_state}

          {:async, worker_call, completion} ->
            {:continue, worker_call, completion, :durable, state}

          {:error, reason} ->
            {:final, {:error, reason}, state}
        end

      {:error, reason} ->
        {:final, {:error, reason}, state}
    end
  end

  defp complete_mutation_stage({:warm_cache, limit}, result, state) do
    case result do
      {:ok, entries} ->
        case commit_warm_cache(entries, limit, state) do
          {:ok, new_state} -> {:final, :ok, new_state}
          {:error, reason} -> {:final, {:error, reason}, state}
        end

      {:error, reason} ->
        {:final, {:error, reason}, state}
    end
  end

  defp complete_mutation_stage(
         {:sync_then_delete, requested_id, groups, converged_count},
         result,
         state
       ) do
    case finish_pending_sync(result, groups, converged_count, state) do
      {:ok, _count, synced_state} ->
        durable_id = resolve_entry_id(requested_id, synced_state)

        {:continue,
         {:strict_delete, synced_state.strict_vector_seam, synced_state.agent_id, durable_id},
         {:delete_persistent, durable_id, true}, :durable, synced_state}

      {:error, reason} ->
        {:final, {:error, reason}, state}
    end
  end

  defp complete_mutation_stage({:delete_persistent, durable_id, remove_local?}, result, state) do
    case result do
      :ok when remove_local? -> {:final, :ok, remove_local_entry(state, durable_id)}
      :ok -> {:final, :ok, state}
      {:error, reason} -> {:final, {:error, reason}, state}
    end
  end

  defp complete_mutation_stage(completion, result, state) do
    {reply, new_state} = complete_persistent_mutation(completion, result, state)
    {:final, reply, new_state}
  end

  defp complete_persistent_mutation(completion, result, state) do
    case completion do
      {:pgvector_index, insertion_sequence, entry_id} ->
        complete_pgvector_index(insertion_sequence, entry_id, result, state)

      {:pgvector_index, insertion_sequence} ->
        complete_pgvector_index(insertion_sequence, nil, result, state)

      {:dual_index, entry_id, group, pending_admission} ->
        complete_dual_index(entry_id, group, pending_admission, result, state)

      {:batch_index, prepared, groups, pending_admission} ->
        complete_batch_index(prepared, groups, pending_admission, result, state)

      {:sync_to_persistent, groups, converged_count} ->
        complete_persistent_sync(groups, converged_count, result, state)
    end
  end

  defp complete_pgvector_index(insertion_sequence, entry_id, result, state) do
    case result do
      {:ok, authoritative_id} ->
        requested_id = if is_binary(entry_id), do: entry_id, else: authoritative_id

        case validate_authoritative_identity(requested_id, authoritative_id) do
          :ok ->
            {{:ok, authoritative_id}, advance_insertion_sequence(state, insertion_sequence)}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      {:error, {:permanent, reason}} ->
        {{:error, reason}, state}

      {:error, {:malformed, reason}} ->
        {{:error, reason}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp complete_dual_index(entry_id, group, _pending_admission, result, state) do
    case result do
      {:ok, authoritative_id} ->
        with :ok <-
               validate_authoritative_identity(group.requested_id, authoritative_id),
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

        case plan_pending_group_admission(state, [group]) do
          {:ok, current_admission} ->
            new_state =
              state
              |> apply_local_admission(current_admission.eviction_ids)
              |> cache_pending_groups([group], current_admission)
              |> advance_insertion_sequence(group.canonical_sequence)

            {{:ok, entry_id}, new_state}

          {:error, :capacity_exceeded} ->
            {{:error, :persistence_indeterminate}, state}
        end
    end
  end

  defp log_dual_write_failure(entry_id, reason) do
    require Logger
    Logger.warning("Dual-mode pgvector write failed for #{entry_id}: #{inspect(reason)}")
  end

  defp do_recall(query, opts, state) do
    with {:ok, evidence} <- get_or_compute_embedding(query, opts, state.embedding_provider) do
      threshold = Keyword.get(opts, :threshold, state.default_threshold)
      limit = Keyword.get(opts, :limit, @default_limit)
      type_filter = get_type_filter(opts)

      case state.backend do
        :ets ->
          do_ets_recall(evidence, type_filter, threshold, limit, state)

        :pgvector ->
          do_pgvector_recall(evidence, type_filter, threshold, limit, state)

        :dual ->
          do_dual_recall(evidence, type_filter, threshold, limit, state)
      end
    end
  end

  defp do_ets_recall(evidence, type_filter, threshold, limit, state) do
    results = find_matching_entries(state.table, evidence, type_filter, threshold)

    sorted =
      results
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)

    {:ok, sorted}
  end

  defp do_pgvector_recall(evidence, type_filter, threshold, limit, state) do
    strict_ann_search(state, evidence, type_filter, threshold, limit)
  end

  defp do_dual_recall(evidence, type_filter, threshold, limit, state) do
    ets_results =
      find_matching_entries(state.table, evidence, type_filter, threshold)

    if length(ets_results) >= limit do
      sorted =
        ets_results
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

      {:ok, sorted}
    else
      case strict_ann_search(state, evidence, type_filter, threshold, limit) do
        {:ok, pgvector_results} ->
          ets_ids = MapSet.new(ets_results, & &1.id)

          unique_pgvector =
            Enum.reject(pgvector_results, fn r -> MapSet.member?(ets_ids, r.id) end)

          merged =
            (ets_results ++ unique_pgvector)
            |> Enum.sort_by(& &1.similarity, :desc)
            |> Enum.take(limit)

          {:ok, merged}

        {:error, reason} when reason in [:backend_failure, :unsupported, :indeterminate] ->
          sorted =
            ets_results
            |> Enum.sort_by(& &1.similarity, :desc)
            |> Enum.take(limit)

          {:ok, sorted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp strict_ann_search(state, evidence, type_filter, threshold, limit) do
    descriptor = search_descriptor(evidence)

    base_opts = [
      model_id: descriptor.model_id,
      dimensions: descriptor.dimensions,
      encoding: descriptor.encoding,
      source_namespace: @index_namespace,
      threshold: threshold,
      limit: min(limit, 1000)
    ]

    case type_filter do
      :none ->
        search_and_validate(state, evidence.vector, base_opts, nil, descriptor)

      {:single, type} ->
        opts = Keyword.put(base_opts, :category, StrictEmbeddingInput.category_for_type(type))
        search_and_validate(state, evidence.vector, opts, opts[:category], descriptor)

      {:multiple, types} ->
        fan_out_category_search(state, evidence.vector, base_opts, types, limit, descriptor)
    end
  end

  defp search_descriptor(evidence) do
    %{
      model_id: evidence.model_id,
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding()
    }
  end

  defp fan_out_category_search(state, vector, base_opts, types, limit, descriptor) do
    types
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, acc} ->
      category = StrictEmbeddingInput.category_for_type(type)
      opts = Keyword.put(base_opts, :category, category)

      case search_and_validate(state, vector, opts, category, descriptor) do
        {:ok, results} -> {:cont, {:ok, acc ++ results}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} ->
        # Full set already validated; only then id-dedupe/sort/take.
        deduped =
          results
          |> Enum.reduce(%{}, fn result, acc ->
            case Map.fetch(acc, result.id) do
              :error ->
                Map.put(acc, result.id, result)

              {:ok, existing} ->
                if result.similarity > existing.similarity,
                  do: Map.put(acc, result.id, result),
                  else: acc
            end
          end)
          |> Map.values()
          |> Enum.sort_by(& &1.similarity, :desc)
          |> Enum.take(limit)

        {:ok, deduped}

      error ->
        error
    end
  end

  defp search_and_validate(state, vector, opts, expected_category, descriptor) do
    case state.strict_vector_seam.search(state.agent_id, vector, opts) do
      {:ok, matches} ->
        validate_strict_match_set(state, matches, expected_category, descriptor, for_cache: false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_strict_match_set(state, matches, expected_category, descriptor, opts)
       when is_list(matches) do
    for_cache? = Keyword.get(opts, :for_cache, false)

    # Fail closed on the complete returned set before any take/cache/use.
    matches
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case validate_one_match(state, item, expected_category, descriptor, for_cache?) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp validate_strict_match_set(_state, _matches, _category, _descriptor, _opts),
    do: {:error, :malformed_persistence_result}

  defp validate_one_match(
         state,
         %{match: view, similarity: similarity},
         expected_category,
         descriptor,
         for_cache?
       )
       when is_map(view) and is_number(similarity) do
    view_agent_id = view_field(view, :agent_id)
    source_namespace = view_field(view, :source_namespace)
    source_key = view_field(view, :source_key)
    row_id = view_field(view, :id)
    category = view_field(view, :category)
    model_id = view_field(view, :model_id)
    dimensions = view_field(view, :dimensions)
    encoding = view_field(view, :encoding)
    tombstone = view_field(view, :tombstone)
    body = view_field(view, :body)
    provenance_status = view_field(view, :provenance_status)

    cond do
      view_agent_id != state.agent_id ->
        {:error, :tenant_mismatch}

      source_namespace != @index_namespace ->
        {:error, :namespace_mismatch}

      expected_category != nil and category != expected_category ->
        {:error, :category_mismatch}

      not is_binary(model_id) or model_id != descriptor.model_id ->
        {:error, :descriptor_mismatch}

      dimensions != descriptor.dimensions ->
        {:error, :descriptor_mismatch}

      encoding != descriptor.encoding ->
        {:error, :descriptor_mismatch}

      tombstone != false ->
        {:error, :malformed_persistence_result}

      not valid_similarity?(similarity) ->
        {:error, :malformed_persistence_result}

      not valid_entry_id?(source_key) ->
        {:error, :malformed_persistence_result}

      # Index durable identity: VectorRecord.id == source_key == entry_id
      not is_binary(row_id) or row_id != source_key ->
        {:error, :malformed_persistence_result}

      not is_map(body) ->
        {:error, :malformed_persistence_result}

      not is_binary(Map.get(body, "content")) ->
        {:error, :malformed_persistence_result}

      not is_map(Map.get(body, "metadata", %{})) ->
        {:error, :malformed_persistence_result}

      provenance_status == :invalid_durable_provenance ->
        {:error, :invalid_durable_provenance}

      provenance_status not in [:verified, :legacy_unlabeled] ->
        {:error, :malformed_persistence_result}

      for_cache? and provenance_status != :verified ->
        {:error, :unverified_strict_provenance}

      true ->
        {:ok, decoded_view_to_recall_result(view, similarity)}
    end
  end

  defp validate_one_match(_state, _item, _category, _descriptor, _for_cache?),
    do: {:error, :malformed_persistence_result}

  defp view_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp view_field(_value, _key), do: nil

  defp valid_similarity?(similarity) do
    match?({:ok, _normalized}, VectorMatch.normalize_similarity(similarity))
  end

  defp valid_contract_vector?(vector) do
    match?({:ok, _normalized}, VectorRecord.normalize_vector(vector))
  end

  defp decoded_view_to_recall_result(view, similarity) do
    body = view_field(view, :body)
    body = if is_map(body), do: body, else: %{}
    metadata = Map.get(body, "metadata", %{})

    metadata =
      if is_map(metadata) do
        normalize_metadata(atomize_metadata_keys(metadata))
      else
        %{}
      end

    %{
      id: view_field(view, :source_key),
      content: Map.get(body, "content", ""),
      similarity: similarity,
      metadata: metadata,
      indexed_at: view_field(view, :indexed_at) || DateTime.utc_now()
    }
  end

  defp atomize_metadata_keys(metadata) do
    known = [:type, :source, :tags, :agent_id, :correlation_id]

    Enum.reduce(metadata, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, k, v)

      {k, v}, acc when is_binary(k) ->
        case Enum.find(known, fn atom -> Atom.to_string(atom) == k end) do
          nil -> Map.put(acc, k, v)
          atom -> Map.put(acc, atom, v)
        end

      _, acc ->
        acc
    end)
  end

  defp find_matching_entries(table, evidence, type_filter, threshold) do
    :ets.foldl(
      fn {_id, entry}, acc ->
        score_entry(entry, evidence, type_filter, threshold, acc)
      end,
      [],
      table
    )
  end

  defp score_entry(entry, evidence, type_filter, threshold, acc) do
    if compatible_entry_descriptor?(entry, evidence) and matches_type_filter?(entry, type_filter) do
      similarity = cosine_similarity(evidence.vector, entry.embedding)

      if similarity >= threshold do
        [entry_to_result(entry, similarity) | acc]
      else
        acc
      end
    else
      acc
    end
  end

  defp compatible_entry_descriptor?(entry, evidence) do
    Map.get(entry, :model_id) == evidence.model_id and
      Map.get(entry, :dimensions) == VectorRecord.dimensions() and
      Map.get(entry, :encoding) == VectorRecord.encoding()
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

  defp do_batch_index(preflighted, state) do
    with {:ok, prepared} <- prepare_batch_entries(preflighted, state) do
      case state.backend do
        :ets ->
          with {:ok, eviction_ids} <- plan_prepared_batch_admission(state, prepared) do
            commit_ets_batch(prepared, eviction_ids, state)
          end

        :pgvector ->
          prepare_persistent_batch(prepared, state, state.strict_vector_seam)

        :dual ->
          prepare_persistent_batch(prepared, state, state.strict_vector_seam)
      end
    end
  end

  defp prepare_batch_entries(preflighted, state) when is_list(preflighted) do
    prepared =
      Enum.map(preflighted, fn item ->
        entry = build_local_entry(item.entry_id, item, item.now)

        %{
          entry: entry,
          insertion_sequence: state.next_insertion_sequence + item.position,
          position: item.position
        }
      end)

    with :ok <- validate_prepared_batch_identities(prepared, state), do: {:ok, prepared}
  rescue
    _error -> {:error, :invalid_batch}
  catch
    _kind, _reason -> {:error, :invalid_batch}
  end

  defp prepare_batch_entries(_preflighted, _state), do: {:error, :invalid_batch}

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

  defp commit_ets_batch(prepared, eviction_ids, state) do
    new_state =
      prepared
      |> Enum.reduce(apply_local_admission(state, eviction_ids), fn %{entry: entry}, acc ->
        put_local_entry(acc, entry)
      end)
      |> advance_prepared_batch_sequence(prepared)

    {:ok, Enum.map(prepared, & &1.entry.id), new_state}
  end

  defp prepare_persistent_batch([], state, _seam), do: {:ok, [], state}

  defp prepare_persistent_batch(prepared, state, seam) do
    groups = group_prepared_batch_entries(prepared, state)
    closed_inputs = Enum.map(groups, &prepared_group_closed_input(state.agent_id, &1))

    with {:ok, pending_admission} <- plan_persistent_batch_admission(state, groups) do
      writer_call = {:strict_batch, seam, state.agent_id, closed_inputs}
      completion = {:batch_index, prepared, groups, pending_admission}
      {:async, writer_call, completion}
    end
  end

  defp complete_batch_index(prepared, groups, pending_admission, result, state) do
    case result do
      {:ok, authoritative_ids} ->
        with {:ok, bindings} <-
               validate_authoritative_bindings(state, groups, authoritative_ids),
             {:ok, admitted_state} <- cache_authoritative_bindings(state, bindings) do
          ids = expand_batch_authoritative_ids(bindings)
          new_state = advance_prepared_batch_sequence(admitted_state, prepared)
          {{:ok, ids}, new_state}
        else
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, reason} ->
        case maybe_commit_pending_batch(
               prepared,
               groups,
               pending_admission,
               state,
               reason
             ) do
          {:ok, ids, new_state} -> {{:ok, ids}, new_state}
          {:error, error_reason} -> {{:error, error_reason}, state}
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

  defp commit_pending_batch(prepared, groups, _pending_admission, state, reason) do
    Enum.each(prepared, fn %{entry: entry} -> log_dual_write_failure(entry.id, reason) end)

    case plan_pending_group_admission(state, groups) do
      {:ok, current_admission} ->
        new_state =
          state
          |> apply_local_admission(current_admission.eviction_ids)
          |> cache_pending_groups(groups, current_admission)
          |> advance_prepared_batch_sequence(prepared)

        {:ok, Enum.map(prepared, & &1.entry.id), new_state}

      {:error, :capacity_exceeded} ->
        {:error, :persistence_indeterminate}
    end
  end

  # One durable identity per entry_id — equal content under distinct keys stays distinct.
  defp group_prepared_batch_entries(prepared, _state) do
    prepared
    |> Enum.sort_by(& &1.insertion_sequence)
    |> Enum.map(fn item ->
      %{
        content_digest: item.entry.id,
        member_ids: [item.entry.id],
        prepared_member_ids: [item.entry.id],
        member_positions: [item.position],
        requested_id: item.entry.id,
        first_sequence: item.insertion_sequence,
        canonical_entry: item.entry,
        canonical_sequence: item.insertion_sequence,
        order_key: item.insertion_sequence
      }
    end)
  end

  defp prepared_group_closed_input(agent_id, group) do
    closed_index_insert(agent_id, %{group.canonical_entry | id: group.requested_id})
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

  @spec get_or_compute_embedding(String.t(), keyword(), module()) ::
          {:ok, map()} | {:error, term()}
  defp get_or_compute_embedding(content, opts, provider) do
    case Keyword.get(opts, :embedding) do
      nil ->
        compute_embedding(content, provider)

      embedding when is_list(embedding) ->
        case EmbeddingEvidence.from_precomputed(embedding) do
          {:ok, evidence} ->
            {:ok, evidence}

          {:error, :invalid_embedding} ->
            # Compatible public preflight shape used by dual/pgvector callers.
            {:error, {:invalid_legacy_embedding, :invalid_embedding}}

          {:error, reason} ->
            {:error, reason}
        end

      _invalid_embedding ->
        {:error, {:invalid_legacy_embedding, :invalid_embedding}}
    end
  end

  @max_content_bytes 65_536
  @max_metadata_json_bytes 65_536

  defp preflight_entry(:ets, evidence, metadata) do
    {:ok, evidence.vector, normalize_metadata(metadata), evidence}
  end

  defp preflight_entry(_backend, evidence, metadata) do
    with {:ok, vector} <- VectorRecord.normalize_vector(evidence.vector),
         {:ok, meta} <- validate_durable_metadata(metadata) do
      {:ok, vector, meta, %{evidence | vector: vector}}
    else
      # Preserve legacy public preflight error shape for dual/pgvector callers.
      {:error, :invalid_vector} ->
        {:error, {:invalid_legacy_embedding, :invalid_embedding}}

      {:error, :invalid_embedding} ->
        {:error, {:invalid_legacy_embedding, :invalid_embedding}}

      {:error, :invalid_metadata} ->
        {:error, {:invalid_legacy_embedding, :invalid_metadata}}

      {:error, :invalid_content} ->
        {:error, {:invalid_legacy_embedding, :invalid_content}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_durable_metadata(metadata) when is_map(metadata) do
    sanitized = sanitize_entry_metadata(metadata)

    case safe_metadata_json(sanitized) do
      {:ok, json} when byte_size(json) <= @max_metadata_json_bytes ->
        {:ok, sanitized}

      {:ok, _too_large} ->
        {:error, :invalid_metadata}

      :error ->
        {:error, :invalid_metadata}
    end
  end

  defp validate_durable_metadata(_), do: {:error, :invalid_metadata}

  defp safe_metadata_json(metadata) do
    case json_safe_map(metadata) do
      {:ok, safe} ->
        case Jason.encode(safe) do
          {:ok, json} -> {:ok, json}
          _ -> :error
        end

      :error ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp json_safe_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {k, v}, {:ok, acc} when is_atom(k) or is_binary(k) ->
        key = if is_atom(k), do: Atom.to_string(k), else: k

        case json_safe_value(v) do
          {:ok, safe_v} -> {:cont, {:ok, Map.put(acc, key, safe_v)}}
          :error -> {:halt, :error}
        end

      _, _acc ->
        {:halt, :error}
    end)
  end

  defp json_safe_map(_), do: :error

  defp json_safe_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
    do: {:ok, v}

  defp json_safe_value(v) when is_atom(v), do: {:ok, Atom.to_string(v)}

  defp json_safe_value(v) when is_list(v) do
    Enum.reduce_while(v, {:ok, []}, fn item, {:ok, acc} ->
      case json_safe_value(item) do
        {:ok, safe} -> {:cont, {:ok, [safe | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      :error -> :error
    end
  end

  defp json_safe_value(v) when is_map(v), do: json_safe_map(v)
  defp json_safe_value(_), do: :error

  defp validate_durable_content(content) when is_binary(content) do
    if byte_size(content) > 0 and byte_size(content) <= @max_content_bytes and
         String.valid?(content) do
      :ok
    else
      {:error, :invalid_content}
    end
  end

  defp validate_durable_content(_), do: {:error, :invalid_content}

  @spec compute_embedding(String.t(), module()) :: {:ok, map()} | {:error, term()}
  defp compute_embedding("", _provider), do: {:error, :empty_content}

  defp compute_embedding(content, provider) do
    if provider == Arbor.AI and not embedding_service_enabled?() do
      {:ok, EmbeddingEvidence.local_hash_fallback(content)}
    else
      compute_embedding_via_provider(content, provider)
    end
  end

  defp embedding_service_enabled?,
    do: Application.get_env(:arbor_memory, :embedding_service_enabled, true)

  defp compute_embedding_via_provider(content, provider) do
    case provider.embed(content) do
      {:ok, result} ->
        case EmbeddingEvidence.from_provider_result(result) do
          {:ok, evidence} ->
            {:ok, evidence}

          {:error, _reason} ->
            Logger.warning("Embedding provider result invalid, using hash fallback")
            {:ok, EmbeddingEvidence.local_hash_fallback(content)}
        end

      {:error, reason} ->
        Logger.warning("Embedding provider failed, using hash fallback: #{inspect(reason)}")
        {:ok, EmbeddingEvidence.local_hash_fallback(content)}
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
        # Identity-scoped and table-scoped: only existing local member ids are
        # removed. Brand-new source keys must not inflate removed_ids or the
        # projected capacity math skips LRU eviction at the commit point.
        members = Map.get(group, :member_ids, [authoritative_id])

        existing_members =
          Enum.filter(members, fn id -> MapSet.member?(current_ids, id) end)

        {authoritative_id, existing_members}
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
    # Metadata is body data only; owner-generated top-level identity remains
    # authoritative even when the payload contains an `id` key.
    normalize_metadata(metadata)
  end

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

  defp prepare_persistent_sync(state) do
    case pending_sync_plan(state) do
      {:complete, count, new_state} ->
        {:ok, count, new_state}

      {:write, groups, closed_inputs, converged_count} ->
        writer_call =
          {:strict_batch, state.strict_vector_seam, state.agent_id, closed_inputs}

        {:async, writer_call, {:sync_to_persistent, groups, converged_count}}
    end
  end

  defp pending_sync_plan(state) do
    pending_ids = state.pending_sync |> MapSet.to_list() |> Enum.sort()

    if pending_ids == [] do
      {:complete, 0, state}
    else
      pending_entries = Enum.flat_map(pending_ids, &collect_pending_entry(&1, state))

      if pending_entries == [] do
        {:complete, 0,
         %{
           state
           | pending_sync: MapSet.new(),
             pending_entry_orders: %{},
             pending_group_members: %{}
         }}
      else
        groups = group_pending_entries(pending_entries)
        closed_inputs = Enum.map(groups, &pending_group_closed_input(state.agent_id, &1))
        converged_count = pending_converged_count(state, pending_ids)
        {:write, groups, closed_inputs, converged_count}
      end
    end
  end

  defp complete_persistent_sync(groups, converged_count, result, state) do
    case finish_pending_sync(result, groups, converged_count, state) do
      {:ok, count, new_state} -> {{:ok, count}, new_state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp finish_pending_sync({:ok, authoritative_ids}, groups, converged_count, state) do
    with {:ok, bindings} <- validate_authoritative_bindings(state, groups, authoritative_ids) do
      new_state =
        Enum.reduce(bindings, state, fn {group, authoritative_id}, acc ->
          converge_pending_group(acc, group, authoritative_id)
        end)

      {:ok, converged_count, new_state}
    end
  end

  defp finish_pending_sync({:error, {:permanent, reason}}, _groups, _count, _state),
    do: {:error, reason}

  defp finish_pending_sync({:error, {:malformed, reason}}, _groups, _count, _state),
    do: {:error, reason}

  defp finish_pending_sync({:error, reason}, _groups, _count, _state),
    do: {:error, reason}

  defp fetch_warm_cache_entries(seam, agent_id, provider, opts) do
    limit = Keyword.fetch!(opts, :limit)

    case Keyword.get(opts, :query) do
      nil ->
        list_opts = [
          source_namespace: @index_namespace,
          limit: min(limit, 1000),
          include_tombstones: false
        ]

        case seam.list(agent_id, list_opts) do
          {:ok, views} ->
            validate_warm_views(agent_id, views, limit, nil)

          {:error, reason} ->
            {:error, reason}
        end

      query when is_binary(query) ->
        with {:ok, evidence} <- get_or_compute_embedding(query, [], provider),
             descriptor = search_descriptor(evidence),
             search_opts = [
               model_id: descriptor.model_id,
               dimensions: descriptor.dimensions,
               encoding: descriptor.encoding,
               source_namespace: @index_namespace,
               threshold: 0.0,
               limit: min(limit, 1000)
             ],
             {:ok, matches} <- seam.search(agent_id, evidence.vector, search_opts),
             {:ok, views} <- warm_match_views(matches) do
          validate_warm_views(agent_id, views, limit, descriptor)
        end
    end
  end

  defp warm_match_views(matches) when is_list(matches) do
    Enum.reduce_while(matches, {:ok, []}, fn
      %{match: view, similarity: similarity}, {:ok, acc}
      when is_map(view) and is_number(similarity) ->
        if valid_similarity?(similarity) do
          {:cont, {:ok, [view | acc]}}
        else
          {:halt, {:error, :malformed_persistence_result}}
        end

      _malformed, _acc ->
        {:halt, {:error, :malformed_persistence_result}}
    end)
    |> case do
      {:ok, views} -> {:ok, Enum.reverse(views)}
      error -> error
    end
  end

  defp warm_match_views(_matches), do: {:error, :malformed_persistence_result}

  defp validate_warm_views(agent_id, views, limit, descriptor) when is_list(views) do
    # Validate the complete returned set before any take/admission.
    case Enum.reduce_while(views, {:ok, []}, fn view, {:ok, acc} ->
           case warm_view_to_entry(agent_id, view, descriptor) do
             {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      {:ok, entries} ->
        {:ok, entries |> Enum.reverse() |> Enum.take(limit)}

      error ->
        error
    end
  end

  defp validate_warm_views(_agent_id, _views, _limit, _descriptor),
    do: {:error, :malformed_persistence_result}

  defp warm_view_to_entry(agent_id, view, descriptor) when is_map(view) do
    view_agent_id = view_field(view, :agent_id)
    source_namespace = view_field(view, :source_namespace)
    source_key = view_field(view, :source_key)
    row_id = view_field(view, :id)
    model_id = view_field(view, :model_id)
    dimensions = view_field(view, :dimensions)
    encoding = view_field(view, :encoding)
    tombstone = view_field(view, :tombstone)
    body = view_field(view, :body)
    vector = view_field(view, :vector)
    provenance_status = view_field(view, :provenance_status)

    cond do
      view_agent_id != agent_id ->
        {:error, :tenant_mismatch}

      source_namespace != @index_namespace ->
        {:error, :namespace_mismatch}

      tombstone != false ->
        {:error, :malformed_persistence_result}

      provenance_status != :verified ->
        {:error, :unverified_strict_provenance}

      not is_binary(model_id) or model_id == "" ->
        {:error, :descriptor_mismatch}

      not valid_entry_id?(source_key) ->
        {:error, :malformed_persistence_result}

      not is_binary(row_id) or row_id != source_key ->
        {:error, :malformed_persistence_result}

      not is_map(body) ->
        {:error, :malformed_persistence_result}

      is_map(descriptor) and model_id != descriptor.model_id ->
        {:error, :descriptor_mismatch}

      is_map(descriptor) and dimensions != descriptor.dimensions ->
        {:error, :descriptor_mismatch}

      is_map(descriptor) and encoding != descriptor.encoding ->
        {:error, :descriptor_mismatch}

      dimensions != VectorRecord.dimensions() ->
        {:error, :descriptor_mismatch}

      encoding != VectorRecord.encoding() ->
        {:error, :descriptor_mismatch}

      true ->
        content = Map.get(body, "content")
        metadata = Map.get(body, "metadata", %{})

        with true <- is_binary(content),
             true <- is_map(metadata),
             {:ok, vector} <- VectorRecord.normalize_vector(vector) do
          now = DateTime.utc_now()

          {:ok,
           %{
             id: source_key,
             content: content,
             embedding: vector,
             metadata: normalize_metadata(atomize_metadata_keys(metadata)),
             indexed_at: now,
             accessed_at: now,
             access_count: 0,
             model_id: model_id,
             dimensions: dimensions,
             encoding: encoding,
             category: view_field(view, :category),
             taint: view_field(view, :taint),
             provenance_status: provenance_status,
             model_evidence: {:model_id, model_id}
           }}
        else
          _invalid -> {:error, :malformed_persistence_result}
        end
    end
  end

  defp warm_view_to_entry(_agent_id, _view, _descriptor),
    do: {:error, :malformed_persistence_result}

  defp commit_warm_cache(entries, limit, state) when is_list(entries) do
    incoming =
      entries
      |> Enum.take(limit)
      |> Enum.reject(fn entry -> :ets.member(state.table, entry.id) end)

    ids = Enum.map(incoming, & &1.id)

    with true <- length(ids) == MapSet.size(MapSet.new(ids)),
         true <- Enum.all?(ids, &valid_entry_id?/1),
         {:ok, eviction_ids} <- plan_local_admission(state, ids) do
      new_state =
        Enum.reduce(incoming, apply_local_admission(state, eviction_ids), fn entry, acc ->
          put_local_entry(acc, entry)
        end)

      {:ok, new_state}
    else
      false -> {:error, :malformed_persistence_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_warm_cache(_entries, _limit, _state),
    do: {:error, :malformed_persistence_result}

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
    |> Enum.map(fn {id, entry, first_sequence, _latest} ->
      %{
        content_digest: id,
        member_ids: [id],
        requested_id: id,
        canonical_entry: entry,
        order_key: first_sequence
      }
    end)
    |> Enum.sort_by(& &1.order_key)
  end

  defp pending_group_closed_input(agent_id, group) do
    closed_index_insert(agent_id, %{group.canonical_entry | id: group.requested_id})
  end

  defp pending_converged_count(state, pending_ids) do
    Enum.reduce(pending_ids, 0, fn id, count ->
      count + MapSet.size(Map.get(state.pending_group_members, id, MapSet.new([id])))
    end)
  end

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
         :ok <- validate_authoritative_identity(group.requested_id, authoritative_id) do
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

  defp validate_authoritative_identity(requested_id, authoritative_id) do
    if valid_entry_id?(authoritative_id) and authoritative_id == requested_id do
      :ok
    else
      {:error, :malformed_persistence_result}
    end
  end

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

  defp valid_entry_id?(id) when is_binary(id) do
    size = byte_size(id)

    size > 0 and size <= @max_entry_id_bytes and String.valid?(id) and String.trim(id) != ""
  end

  defp valid_entry_id?(_id), do: false

  defp generate_entry_identity(entry_id_generator, clock) do
    entry_id = entry_id_generator.()
    now = clock.()

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

  defp run_background_call(
         {:preflight_index, backend, _agent_id, provider, entry_id_generator, clock, content,
          metadata, opts}
       ) do
    with :ok <- maybe_validate_durable_content(backend, content),
         {:ok, evidence} <- get_or_compute_embedding(content, opts, provider),
         {:ok, entry_id, now} <- generate_entry_identity(entry_id_generator, clock),
         {:ok, normalized_embedding, normalized_metadata, evidence} <-
           preflight_entry(backend, evidence, metadata) do
      {:ok,
       %{
         entry_id: entry_id,
         now: now,
         content: content,
         embedding: normalized_embedding,
         metadata: normalized_metadata,
         model_evidence: evidence.model_evidence,
         model_id: evidence.model_id,
         dimensions: VectorRecord.dimensions(),
         encoding: VectorRecord.encoding(),
         taint: TaintEnvelope.missing_fallback(),
         provenance_status: :verified
       }}
    end
  rescue
    _error -> {:error, :operation_failed}
  catch
    _kind, _reason -> {:error, :operation_failed}
  end

  defp run_background_call(
         {:preflight_batch, backend, _agent_id, provider, entry_id_generator, clock, items, opts}
       ) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{content, metadata}, position}, {:ok, acc} ->
      with :ok <- maybe_validate_durable_content(backend, content),
           {:ok, evidence} <- get_or_compute_embedding(content, opts, provider),
           {:ok, entry_id, now} <- generate_entry_identity(entry_id_generator, clock),
           {:ok, normalized_embedding, normalized_metadata, evidence} <-
             preflight_entry(backend, evidence, metadata) do
        prepared = %{
          entry_id: entry_id,
          now: now,
          content: content,
          embedding: normalized_embedding,
          metadata: normalized_metadata,
          position: position,
          model_evidence: evidence.model_evidence,
          model_id: evidence.model_id,
          dimensions: VectorRecord.dimensions(),
          encoding: VectorRecord.encoding(),
          taint: TaintEnvelope.missing_fallback(),
          provenance_status: :verified
        }

        {:cont, {:ok, [prepared | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  rescue
    _error -> {:error, :operation_failed}
  catch
    _kind, _reason -> {:error, :operation_failed}
  end

  defp run_background_call({:recall, context, query, opts}) do
    do_recall(query, opts, context)
  rescue
    _error -> {:error, :operation_failed}
  catch
    _kind, _reason -> {:error, :operation_failed}
  end

  defp run_background_call({:warm_cache, seam, agent_id, provider, opts}) do
    fetch_warm_cache_entries(seam, agent_id, provider, opts)
  rescue
    _error -> {:error, :operation_failed}
  catch
    _kind, _reason -> {:error, :operation_failed}
  end

  defp run_background_call({:strict_delete, seam, agent_id, entry_id}) do
    strict_delete_entry(seam, agent_id, entry_id)
  rescue
    _error -> {:error, :persistence_indeterminate}
  catch
    _kind, _reason -> {:error, :persistence_indeterminate}
  end

  defp run_background_call({:strict_write, seam, agent_id, closed_input}) do
    case seam.encode_operation(closed_input) do
      {:ok, operation, _view} ->
        execute_or_reconcile_single(seam, agent_id, operation)

      {:error, reason} ->
        {:error, {:permanent, reason}}
    end
  rescue
    _error -> {:error, :persistence_indeterminate}
  catch
    _kind, _reason -> {:error, :persistence_indeterminate}
  end

  defp run_background_call({:strict_batch, seam, agent_id, closed_inputs}) do
    case seam.encode_batch(closed_inputs) do
      {:ok, operation, _views} ->
        execute_or_reconcile_batch(seam, agent_id, operation, length(closed_inputs))

      {:error, reason} ->
        {:error, {:permanent, reason}}
    end
  rescue
    _error -> {:error, :persistence_indeterminate}
  catch
    _kind, _reason -> {:error, :persistence_indeterminate}
  end

  defp maybe_validate_durable_content(:ets, _content), do: :ok

  defp maybe_validate_durable_content(_backend, content) do
    case validate_durable_content(content) do
      :ok -> :ok
      {:error, :invalid_content} -> {:error, {:invalid_legacy_embedding, :invalid_content}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_or_reconcile_single(seam, agent_id, operation),
    do: execute_or_reconcile_single(seam, agent_id, operation, 1)

  defp execute_or_reconcile_single(seam, agent_id, operation, retries_left) do
    try do
      case seam.execute(agent_id, operation, []) do
        {:ok, receipt} ->
          receipt_to_single_id(receipt, operation)

        {:error, :indeterminate} ->
          reconcile_single(seam, agent_id, operation, retries_left)

        {:error, reason} ->
          normalize_strict_error(reason)

        malformed ->
          # Bare :ok / non-receipt tuples are permanent malformation, not indeterminate.
          _ = malformed
          {:error, {:malformed, :malformed_persistence_result}}
      end
    rescue
      _error -> reconcile_single(seam, agent_id, operation, retries_left)
    catch
      _kind, _reason -> reconcile_single(seam, agent_id, operation, retries_left)
    end
  end

  defp execute_or_reconcile_batch(seam, agent_id, operation, expected_count),
    do: execute_or_reconcile_batch(seam, agent_id, operation, expected_count, 1)

  defp execute_or_reconcile_batch(seam, agent_id, operation, expected_count, retries_left) do
    try do
      case seam.execute(agent_id, operation, []) do
        {:ok, receipt} ->
          receipt_to_batch_ids(receipt, operation, expected_count)

        {:error, :indeterminate} ->
          reconcile_batch(seam, agent_id, operation, expected_count, retries_left)

        {:error, reason} ->
          normalize_strict_error(reason)

        malformed ->
          _ = malformed
          {:error, {:malformed, :malformed_persistence_result}}
      end
    rescue
      _error -> reconcile_batch(seam, agent_id, operation, expected_count, retries_left)
    catch
      _kind, _reason -> reconcile_batch(seam, agent_id, operation, expected_count, retries_left)
    end
  end

  defp reconcile_single(seam, agent_id, operation, retries_left) do
    case seam.reconcile(agent_id, operation, []) do
      {:ok, :absent} when retries_left > 0 ->
        execute_or_reconcile_single(seam, agent_id, operation, retries_left - 1)

      {:ok, :absent} ->
        {:error, :persistence_indeterminate}

      {:ok, receipt} ->
        receipt_to_single_id(receipt, operation)

      {:error, reason} ->
        normalize_strict_error(reason)

      _ ->
        {:error, :persistence_indeterminate}
    end
  rescue
    _ -> {:error, :persistence_indeterminate}
  catch
    _, _ -> {:error, :persistence_indeterminate}
  end

  defp reconcile_batch(seam, agent_id, operation, expected_count, retries_left) do
    case seam.reconcile(agent_id, operation, []) do
      {:ok, :absent} when retries_left > 0 ->
        execute_or_reconcile_batch(seam, agent_id, operation, expected_count, retries_left - 1)

      {:ok, :absent} ->
        {:error, :persistence_indeterminate}

      {:ok, receipt} ->
        receipt_to_batch_ids(receipt, operation, expected_count)

      {:error, reason} ->
        normalize_strict_error(reason)

      _ ->
        {:error, :persistence_indeterminate}
    end
  rescue
    _ -> {:error, :persistence_indeterminate}
  catch
    _, _ -> {:error, :persistence_indeterminate}
  end

  defp receipt_to_single_id(receipt, %{record: expected_record}) do
    expected_key = expected_record.source_key
    expected_id = expected_record.id

    with {:ok, ^expected_key} <- receipt_source_key(receipt),
         {:ok, ^expected_id} <- receipt_record_id(receipt) do
      {:ok, expected_key}
    else
      _ -> {:error, {:malformed, :malformed_persistence_result}}
    end
  end

  defp receipt_to_batch_ids(
         %{kind: :batch, receipts: receipts},
         %{kind: :batch, operations: operations},
         expected_count
       )
       when is_list(receipts) and is_list(operations) do
    pairs = Enum.zip(receipts, operations)

    if length(receipts) == expected_count and length(operations) == expected_count and
         length(pairs) == expected_count do
      pairs
      |> Enum.reduce_while({:ok, []}, fn {receipt, operation}, {:ok, ids} ->
        case receipt_to_single_id(receipt, operation) do
          {:ok, id} -> {:cont, {:ok, [id | ids]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, ids} -> {:ok, Enum.reverse(ids)}
        error -> error
      end
    else
      {:error, {:malformed, :malformed_persistence_result}}
    end
  end

  defp receipt_to_batch_ids(_receipt, _operation, _expected),
    do: {:error, {:malformed, :malformed_persistence_result}}

  # Exact durable identity for Index is source_key (== entry_id). Prefer source_key
  # over row id so reconcile/receipt convergence never confuses digest-style ids.
  defp receipt_source_key(%{record: record}) when not is_nil(record) do
    key =
      cond do
        is_map(record) and is_binary(Map.get(record, :source_key)) ->
          Map.get(record, :source_key)

        is_map(record) and is_binary(Map.get(record, "source_key")) ->
          Map.get(record, "source_key")

        true ->
          nil
      end

    if valid_entry_id?(key), do: {:ok, key}, else: :error
  end

  defp receipt_source_key(_), do: :error

  defp receipt_record_id(%{record: record}) when is_map(record) do
    id = Map.get(record, :id) || Map.get(record, "id")
    if valid_entry_id?(id), do: {:ok, id}, else: :error
  end

  defp receipt_record_id(_), do: :error

  defp normalize_strict_error(reason)
       when reason in [
              :invalid_request,
              :invalid_embedding_input,
              :invalid_model_evidence,
              :invalid_provenance,
              :unverified_strict_provenance,
              :tenant_mismatch,
              :conflict,
              :protected_vector_row,
              :unsupported
            ],
       do: {:error, {:permanent, reason}}

  defp normalize_strict_error(:indeterminate), do: {:error, :persistence_indeterminate}
  defp normalize_strict_error(_reason), do: {:error, :persistence_indeterminate}

  defp strict_delete_entry(seam, agent_id, entry_id) do
    case seam.fetch(agent_id, @index_namespace, entry_id, []) do
      {:error, :not_found} ->
        :ok

      {:ok, view} ->
        with :ok <- validate_delete_view(agent_id, entry_id, view),
             closed <- StrictEmbeddingInput.index_delete(view),
             {:ok, operation, _view} <- seam.encode_operation(closed) do
          case execute_or_reconcile_single(seam, agent_id, operation) do
            {:ok, ^entry_id} -> :ok
            {:ok, _other_id} -> {:error, {:malformed, :malformed_persistence_result}}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, reason} -> {:error, {:permanent, reason}}
        end

      {:error, reason} ->
        normalize_strict_error(reason)
    end
  end

  defp validate_delete_view(agent_id, entry_id, view) when is_map(view) do
    view_agent_id = view_field(view, :agent_id)
    source_namespace = view_field(view, :source_namespace)
    source_key = view_field(view, :source_key)
    row_id = view_field(view, :id)
    tombstone = view_field(view, :tombstone)
    body = view_field(view, :body)
    vector = view_field(view, :vector)
    model_id = view_field(view, :model_id)
    dimensions = view_field(view, :dimensions)
    encoding = view_field(view, :encoding)
    category = view_field(view, :category)
    generation = view_field(view, :generation)
    revision = view_field(view, :revision)

    cond do
      view_agent_id != agent_id ->
        {:error, :tenant_mismatch}

      source_namespace != @index_namespace ->
        {:error, :namespace_mismatch}

      source_key != entry_id ->
        {:error, :malformed_persistence_result}

      row_id != entry_id ->
        {:error, :malformed_persistence_result}

      tombstone != false ->
        {:error, :malformed_persistence_result}

      not is_map(body) or not is_binary(Map.get(body, "content")) or
          not is_map(Map.get(body, "metadata", %{})) ->
        {:error, :malformed_persistence_result}

      not valid_contract_vector?(vector) ->
        {:error, :malformed_persistence_result}

      not is_binary(model_id) or model_id == "" or dimensions != VectorRecord.dimensions() or
          encoding != VectorRecord.encoding() ->
        {:error, :descriptor_mismatch}

      not is_binary(category) or category == "" ->
        {:error, :malformed_persistence_result}

      not is_integer(generation) or generation < 1 ->
        {:error, :malformed_persistence_result}

      not is_integer(revision) or revision < 1 ->
        {:error, :malformed_persistence_result}

      true ->
        :ok
    end
  end

  defp validate_delete_view(_agent_id, _entry_id, _view),
    do: {:error, :malformed_persistence_result}

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

  defp prepare_delete(entry_id, %{backend: :pgvector} = state) do
    {:async, {:strict_delete, state.strict_vector_seam, state.agent_id, entry_id},
     {:delete_persistent, entry_id, false}, :durable}
  end

  defp prepare_delete(entry_id, state) do
    canonical_id = resolve_entry_id(entry_id, state)

    case :ets.lookup(state.table, canonical_id) do
      [] ->
        {:error, :not_found}

      [{^canonical_id, _entry}] when state.backend == :ets ->
        {:ok, remove_local_entry(state, canonical_id)}

      [{^canonical_id, _entry}] ->
        prepare_persistent_delete(entry_id, canonical_id, state)
    end
  end

  defp prepare_persistent_delete(requested_id, canonical_id, state) do
    if MapSet.member?(state.pending_sync, canonical_id) do
      case pending_sync_plan(state) do
        {:complete, _count, synced_state} ->
          durable_id = resolve_entry_id(requested_id, synced_state)

          {:async,
           {:strict_delete, synced_state.strict_vector_seam, synced_state.agent_id, durable_id},
           {:delete_persistent, durable_id, true}, :durable}

        {:write, groups, closed_inputs, converged_count} ->
          writer_call =
            {:strict_batch, state.strict_vector_seam, state.agent_id, closed_inputs}

          completion = {:sync_then_delete, requested_id, groups, converged_count}
          {:async, writer_call, completion, :durable}
      end
    else
      {:async, {:strict_delete, state.strict_vector_seam, state.agent_id, canonical_id},
       {:delete_persistent, canonical_id, true}, :durable}
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
