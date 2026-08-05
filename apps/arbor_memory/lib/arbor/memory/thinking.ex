defmodule Arbor.Memory.Thinking do
  @moduledoc """
  Store and retrieve Claude thinking blocks.

  Thinking blocks are the internal reasoning traces from Claude's extended
  thinking feature. This module stores them in a ring buffer per agent,
  enabling retrospective analysis of reasoning patterns.

  ## Storage

  Thinking entries are stored in ETS per-agent with a ring buffer
  (default: 50 entries). Each entry includes:
  - The thinking text
  - A timestamp
  - Optional metadata (e.g., which tool call triggered it)
  - Whether it's been flagged as significant for reflection

  ## Stream Processing

  For streaming integration, `process_stream_chunk/3` accumulates
  partial thinking blocks until they're complete, then stores the
  full text.

  Eviction removes an independent item rather than transforming its content.
  The durable aggregate label is therefore recomputed from the exact retained
  item labels. Labels on retained stable IDs never decrease; provenance from a
  removed item is not attached to unrelated retained content.
  """

  use GenServer

  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.Memory.{MemoryStore, Provenance, Signals, ThinkingCodec}

  require Logger

  @ets_table :arbor_memory_thinking
  @default_buffer_size 50
  @max_entries 256
  @max_cleanup_entries @max_entries * 2 + 1
  @max_loaded_agents 1_024
  @max_active_streams 1_024
  # Critical mutations must not outlive the caller because of the default
  # five-second owner-call timeout.
  # C3D either returns a definitive in-process result or adds operation-ID
  # reconciliation before this can become bounded/asynchronous.
  @owner_call_timeout :infinity

  # ============================================================================
  # Types
  # ============================================================================

  @type thinking_entry :: %{
          id: String.t(),
          agent_id: String.t(),
          text: String.t(),
          significant: boolean(),
          created_at: DateTime.t(),
          metadata: map()
        }

  @type provenance_status ::
          :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type tainted_entry :: {TaintedValue.t(), provenance_status()}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Thinking GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec active_stream_limit() :: pos_integer()
  def active_stream_limit, do: @max_active_streams

  @doc """
  Record a thinking block for an agent.

  ## Options

  - `:significant` — flag as significant for reflection (default: false)
  - `:metadata` — additional metadata map

  ## Examples

      {:ok, entry} = Thinking.record_thinking("agent_001", "Let me analyze the error...",
        significant: true,
        metadata: %{trigger: "test_failure"}
      )
  """
  @spec record_thinking(String.t(), String.t(), keyword()) ::
          {:ok, thinking_entry()} | {:error, atom()}
  def record_thinking(agent_id, text, opts \\ []) do
    record_thinking_tainted(agent_id, text, TaintEnvelope.missing_fallback(), opts)
  end

  @doc "Records thinking with an exact caller-supplied taint label."
  @spec record_thinking_tainted(String.t(), String.t(), Taint.t(), keyword()) ::
          {:ok, thinking_entry()} | {:error, atom()}
  def record_thinking_tainted(agent_id, text, taint, opts \\ [])

  def record_thinking_tainted(agent_id, text, taint, opts)
      when is_binary(agent_id) and is_binary(text) do
    with true <- valid_agent_id?(agent_id),
         :ok <- validate_record_opts(opts),
         {:ok, taint} <- Taint.canonicalize(taint) do
      GenServer.call(
        server_name(),
        {:record, agent_id, text, taint, opts},
        @owner_call_timeout
      )
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  def record_thinking_tainted(_agent_id, _text, _taint, _opts),
    do: {:error, :invalid_request}

  @doc """
  Get recent thinking entries for an agent.

  ## Options

  - `:limit` — max entries to return (default: 10)
  - `:since` — only entries after this DateTime
  - `:significant_only` — only return significant entries (default: false)

  ## Examples

      entries = Thinking.recent_thinking("agent_001", limit: 5)
      significant = Thinking.recent_thinking("agent_001", significant_only: true)
  """
  @spec recent_thinking(String.t(), keyword()) :: [thinking_entry()]
  def recent_thinking(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    since = Keyword.get(opts, :since)
    significant_only = Keyword.get(opts, :significant_only, false)

    get_agent_entries(agent_id)
    |> maybe_filter_significant(significant_only)
    |> maybe_filter_since(since)
    |> Enum.take(limit)
  end

  @doc "Returns recent thinking with item-specific taint and provenance status."
  @spec recent_thinking_tainted(String.t(), keyword()) ::
          {:ok, [tainted_entry()]} | {:error, atom()}
  def recent_thinking_tainted(agent_id, opts \\ []) do
    case validate_reader_request(agent_id, opts) do
      :ok ->
        GenServer.call(
          server_name(),
          {:recent_tainted, agent_id, opts},
          @owner_call_timeout
        )

      _error ->
        {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  @doc """
  Process a streaming thinking chunk.

  Accumulates chunks for an agent until the stream is complete.
  Call with `complete: true` to finalize and store the accumulated text.

  ## Examples

      Thinking.process_stream_chunk("agent_001", "Let me think")
      Thinking.process_stream_chunk("agent_001", " about this...")
      {:ok, entry} = Thinking.process_stream_chunk("agent_001", "", complete: true)
  """
  @spec process_stream_chunk(String.t(), String.t(), keyword()) ::
          :ok | {:ok, thinking_entry()} | {:error, atom()}
  def process_stream_chunk(agent_id, chunk, opts \\ []) do
    process_stream_chunk_tainted(
      agent_id,
      chunk,
      TaintEnvelope.missing_fallback(),
      opts
    )
  end

  @doc "Processes one streaming thinking chunk with an exact taint label."
  @spec process_stream_chunk_tainted(String.t(), String.t(), Taint.t(), keyword()) ::
          :ok | {:ok, thinking_entry()} | {:error, atom()}
  def process_stream_chunk_tainted(agent_id, chunk, taint, opts \\ [])

  def process_stream_chunk_tainted(agent_id, chunk, taint, opts)
      when is_binary(agent_id) and is_binary(chunk) do
    with true <- valid_agent_id?(agent_id),
         :ok <- validate_stream_opts(opts),
         {:ok, taint} <- Taint.canonicalize(taint) do
      GenServer.call(
        server_name(),
        {:stream_chunk, agent_id, chunk, taint, opts},
        @owner_call_timeout
      )
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  def process_stream_chunk_tainted(_agent_id, _chunk, _taint, _opts),
    do: {:error, :invalid_request}

  @doc """
  Clear all thinking entries for an agent.
  """
  @spec clear(String.t()) :: :ok | {:error, atom()}
  def clear(agent_id) do
    GenServer.call(server_name(), {:clear, agent_id}, @owner_call_timeout)
  end

  @doc "Reloads the complete Thinking projection from the durable memory store."
  @spec reload_from_durable() :: :ok | {:error, atom()}
  def reload_from_durable do
    GenServer.call(server_name(), :reload_from_durable, @owner_call_timeout)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    ensure_ets_table()
    buffer_size = normalize_buffer_size(Keyword.get(opts, :buffer_size, @default_buffer_size))
    _loaded = load_from_durable(buffer_size, false)
    {:ok, %{buffer_size: buffer_size, streams: %{}}}
  end

  @impl true
  def handle_call({:record, agent_id, text, taint, opts}, _from, state) do
    case store_entry(agent_id, text, taint, opts, state) do
      {:ok, entry} -> {:reply, {:ok, entry}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:stream_chunk, agent_id, chunk, taint, opts}, _from, state) do
    complete = Keyword.get(opts, :complete, false)
    current = Map.get(state.streams, agent_id)

    if is_nil(current) and not complete and map_size(state.streams) >= @max_active_streams do
      {:reply, {:error, :stream_capacity}, state}
    else
      case append_stream(current, chunk, taint) do
        {:ok, text, stream_taint} ->
          if complete do
            finish_stream(agent_id, text, stream_taint, opts, state)
          else
            streams = Map.put(state.streams, agent_id, %{text: text, taint: stream_taint})
            {:reply, :ok, %{state | streams: streams}}
          end

        _error ->
          {:reply, {:error, :invalid_payload}, state}
      end
    end
  end

  @impl true
  def handle_call({:recent_tainted, agent_id, opts}, _from, state) do
    {:reply, authoritative_tainted_read(agent_id, opts, state.buffer_size), state}
  end

  @impl true
  def handle_call({:clear, agent_id}, _from, state) do
    entries = get_agent_entries(agent_id)
    durable_entries = durable_entries_for_cleanup(agent_id, @max_entries)
    cleanup_entries = durable_entries ++ safe_cleanup_entries(entries)

    case delete_aggregate_before_live_clear(agent_id) do
      :ok ->
        :ets.delete(@ets_table, agent_id)
        cleanup_thinking_sidecars_after_clear(agent_id, cleanup_entries)
        {:reply, :ok, %{state | streams: Map.delete(state.streams, agent_id)}}

      {:error, reason} ->
        {:reply, {:error, normalize_store_error(reason)}, state}
    end
  end

  @impl true
  def handle_call(:reload_from_durable, _from, state) do
    case load_from_durable(state.buffer_size, true) do
      :ok -> {:reply, :ok, %{state | streams: %{}}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp server_name, do: __MODULE__

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_agent_entries(agent_id) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, entries}] -> entries
      [] -> []
    end
  end

  defp build_entry(agent_id, text, opts) do
    %{
      id: generate_id(),
      agent_id: agent_id,
      text: text,
      significant: Keyword.get(opts, :significant, false),
      created_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp generate_id do
    "thk_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end

  defp maybe_filter_significant(entries, false), do: entries

  defp maybe_filter_significant(entries, true) do
    Enum.filter(entries, &(is_map(&1) and Map.get(&1, :significant) == true))
  end

  defp maybe_filter_since(entries, nil), do: entries

  defp maybe_filter_since(entries, since) do
    Enum.filter(entries, fn entry ->
      case entry do
        %{created_at: %DateTime{} = created_at} ->
          DateTime.compare(created_at, since) in [:gt, :eq]

        _ ->
          false
      end
    end)
  end

  # ============================================================================
  # Persistence Helpers
  # ============================================================================

  defp store_entry(agent_id, text, taint, opts, state) do
    entry = build_entry(agent_id, text, opts)

    with {:ok, _payload} <- ThinkingCodec.entry_payload(entry),
         {:ok, retained} <- mutation_base(agent_id, state.buffer_size) do
      all_labelled = [{entry, taint} | retained]
      labelled_entries = Enum.take(all_labelled, state.buffer_size)
      evicted = all_labelled |> Enum.drop(state.buffer_size) |> Enum.map(&elem(&1, 0))

      result =
        with {:ok, aggregate, aggregate_taint} <-
               ThinkingCodec.encode_aggregate(labelled_entries),
             :ok <-
               persist_aggregate_before_live_install(agent_id, aggregate, aggregate_taint) do
          install_entry_after_persist(
            agent_id,
            entry,
            taint,
            labelled_entries,
            evicted
          )
        end

      case result do
        {:error, reason} -> {:error, normalize_store_error(reason)}
        other -> other
      end
    else
      {:error, reason} -> {:error, normalize_store_error(reason)}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp mutation_base(agent_id, buffer_size) do
    with {:ok, items, authority} <- load_mutation_items(agent_id),
         {:ok, items} <- mutation_items_from_authority(agent_id, items, authority, buffer_size) do
      retained = Enum.map(items, fn {entry, taint, _status} -> {entry, taint} end)

      {:ok, retained}
    else
      {:error, :store_unavailable} = error -> error
      _ -> {:error, :invalid_payload}
    end
  end

  defp load_mutation_items(agent_id) do
    if MemoryStore.available?() do
      case load_stored_mutation_items(agent_id) do
        {:ok, items} -> {:ok, items, :authoritative}
        error -> error
      end
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp load_stored_mutation_items(agent_id) do
    case MemoryStore.load_tainted_with_status("thinking", agent_id) do
      {:ok, %TaintedValue{value: aggregate, taint: outer_taint}, status} ->
        ThinkingCodec.decode_aggregate(
          agent_id,
          aggregate,
          outer_taint,
          status,
          @max_entries
        )

      {:error, :not_found} ->
        {:ok, []}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp mutation_items_from_authority(agent_id, items, :authoritative, buffer_size),
    do: reconcile_authoritative_projection(agent_id, items, buffer_size)

  defp mutation_items_from_authority(_agent_id, _items, _authority, _buffer_size),
    do: {:error, :invalid_payload}

  defp put_live_label(agent_id, entry_id, payload, taint) do
    case Provenance.put(:thinking_entry, agent_id, entry_id, payload, taint) do
      :ok -> :ok
      _ -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  # VP-05D2C C3D integration point: MemoryStore.persist/4 is currently
  # cache-acknowledged and may return :ok during a configured backend outage.
  # Replace this read/commit boundary with C3D's shared primitive: acknowledge
  # backend:nil as deliberate ephemeral mode, require a durable write otherwise,
  # and CAS the aggregate version read by mutation_base/2. Thinking's GenServer
  # serializes only this node, so the present call is not cluster-monotonic. The
  # owner call waits without a client timeout; if this primitive ever detaches
  # work, it must add operation-ID reconciliation before returning.
  defp persist_aggregate_before_live_install(agent_id, aggregate, taint) do
    if MemoryStore.available?() do
      case MemoryStore.persist("thinking", agent_id, aggregate, taint: taint) do
        :ok -> :ok
        _ -> {:error, :store_unavailable}
      end
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp install_entry_after_persist(
         agent_id,
         entry,
         taint,
         labelled_entries,
         evicted
       ) do
    entries = Enum.map(labelled_entries, &elem(&1, 0))

    case install_live_entries(agent_id, labelled_entries, entries) do
      :ok ->
        cleanup_labels(agent_id, evicted)
        enqueue_embedding(entry, taint)
        emit_recorded(entry)
        {:ok, entry}

      {:error, _reason} ->
        fail_closed_agent_projection(agent_id, entries ++ evicted)
        {:ok, entry}
    end
  rescue
    _ ->
      fail_closed_agent_projection(agent_id, Enum.map(labelled_entries, &elem(&1, 0)) ++ evicted)
      {:ok, entry}
  catch
    _, _ ->
      fail_closed_agent_projection(agent_id, Enum.map(labelled_entries, &elem(&1, 0)) ++ evicted)
      {:ok, entry}
  end

  defp install_live_entries(agent_id, labelled_entries, entries) do
    with {:ok, bindings} <- prepare_live_bindings(agent_id, labelled_entries, []),
         :ok <- bind_installation(bindings, []),
         true <- :ets.insert(@ets_table, {agent_id, entries}) do
      :ok
    else
      _ -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp prepare_live_bindings(_agent_id, [], acc), do: {:ok, Enum.reverse(acc)}

  defp prepare_live_bindings(agent_id, [{entry, taint} | rest], acc) do
    with %{agent_id: ^agent_id, id: entry_id} when is_binary(entry_id) <- entry,
         {:ok, payload} <- ThinkingCodec.entry_payload(entry) do
      binding = {agent_id, entry_id, payload, taint}
      prepare_live_bindings(agent_id, rest, [binding | acc])
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp prepare_live_bindings(_agent_id, _entries, _acc), do: {:error, :invalid_payload}

  # VP-05D2C C3D integration point: this temporary delete preserves the required
  # ordering but is cache-acknowledged. Replace it with the shared critical
  # delete, which acknowledges backend:nil ephemeral mode, requires durable
  # deletion for configured backends, and reports an outage before live cleanup.
  defp delete_aggregate_before_live_clear(agent_id) do
    if MemoryStore.available?() do
      case MemoryStore.delete("thinking", agent_id) do
        :ok -> :ok
        _ -> {:error, :store_unavailable}
      end
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp fail_closed_agent_projection(agent_id, candidate_entries) do
    current_entries = get_agent_entries(agent_id)
    :ets.delete(@ets_table, agent_id)
    cleanup_labels(agent_id, safe_cleanup_entries(candidate_entries ++ current_entries))
    :ok
  rescue
    _ ->
      :ets.delete(@ets_table, agent_id)
      :ok
  catch
    _, _ ->
      :ets.delete(@ets_table, agent_id)
      :ok
  end

  defp append_stream(nil, chunk, taint) do
    validate_stream_value(chunk, taint)
  end

  defp append_stream(%{text: accumulated, taint: accumulated_taint}, chunk, taint)
       when is_binary(accumulated) do
    with {:ok, joined} <- Taint.join(accumulated_taint, taint) do
      validate_stream_value(accumulated <> chunk, joined)
    end
  end

  defp append_stream(_current, _chunk, _taint), do: {:error, :invalid_payload}

  defp validate_stream_value(text, taint) do
    with {:ok, taint} <- Taint.canonicalize(taint),
         true <- byte_size(text) <= 65_536,
         true <- String.valid?(text) do
      {:ok, text, taint}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp finish_stream(agent_id, text, stream_taint, opts, state) do
    if String.trim(text) == "" do
      {:reply, :ok, %{state | streams: Map.delete(state.streams, agent_id)}}
    else
      case store_entry(agent_id, text, stream_taint, opts, state) do
        {:ok, entry} ->
          {:reply, {:ok, entry}, %{state | streams: Map.delete(state.streams, agent_id)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  defp authoritative_tainted_read(agent_id, opts, buffer_size) do
    if MemoryStore.available?() do
      case load_stored_mutation_items(agent_id) do
        {:ok, durable_items} ->
          reconcile_durable_read(agent_id, durable_items, opts, buffer_size)

        {:error, _reason} ->
          {:error, :invalid_durable_state}
      end
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp reconcile_durable_read(agent_id, durable_items, opts, buffer_size) do
    case reconcile_authoritative_projection(agent_id, durable_items, buffer_size) do
      {:ok, projection} -> {:ok, filter_decoded_items(projection, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_authoritative_projection(agent_id, durable_items, buffer_size) do
    projection = Enum.take(durable_items, buffer_size)
    live_entries = safe_cleanup_entries(get_agent_entries(agent_id))
    labelled_entries = Enum.map(projection, fn {entry, taint, _status} -> {entry, taint} end)
    entries = Enum.map(projection, &elem(&1, 0))

    install_result =
      case labelled_entries do
        [] ->
          true = :ets.delete(@ets_table, agent_id)
          :ok

        _ ->
          install_live_entries(agent_id, labelled_entries, entries)
      end

    case install_result do
      :ok ->
        cleanup_stale_projection(agent_id, live_entries, entries)
        {:ok, projection}

      {:error, _reason} ->
        fail_closed_agent_projection(agent_id, entries ++ live_entries)
        {:error, :store_unavailable}
    end
  rescue
    _ ->
      fail_closed_agent_projection(agent_id, safe_cleanup_entries(durable_items))
      {:error, :store_unavailable}
  catch
    _, _ ->
      fail_closed_agent_projection(agent_id, safe_cleanup_entries(durable_items))
      {:error, :store_unavailable}
  end

  defp cleanup_stale_projection(agent_id, live_entries, retained_entries) do
    retained_ids =
      Enum.reduce(retained_entries, MapSet.new(), fn
        %{id: id}, acc when is_binary(id) -> MapSet.put(acc, id)
        _entry, acc -> acc
      end)

    stale_entries =
      Enum.reject(live_entries, fn
        %{id: id} when is_binary(id) -> MapSet.member?(retained_ids, id)
        _entry -> false
      end)

    cleanup_labels(agent_id, stale_entries)
  end

  defp filter_decoded_items(items, opts) do
    since = Keyword.get(opts, :since)
    significant_only = Keyword.get(opts, :significant_only, false)
    limit = Keyword.get(opts, :limit, 10)

    items
    |> Enum.filter(fn {entry, _taint, _status} ->
      (not significant_only or entry.significant) and entry_since?(entry, since)
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {entry, taint, status} ->
      {TaintedValue.wrap(entry, taint), ThinkingCodec.status_for(taint, status)}
    end)
  end

  defp entry_since?(_entry, nil), do: true

  defp entry_since?(%{created_at: %DateTime{} = created_at}, %DateTime{} = since),
    do: DateTime.compare(created_at, since) in [:gt, :eq]

  defp entry_since?(_entry, _since), do: false

  defp load_from_durable(buffer_size, replace?) do
    if MemoryStore.available?() do
      with {:ok, records} <- MemoryStore.load_all_tainted("thinking"),
           {:ok, plans} <- decode_records(records, buffer_size, 0, []),
           {:ok, installation} <- prepare_installation(plans, MapSet.new(), [], []) do
        if replace?, do: clear_live_projection()

        case commit_installation(installation) do
          :ok ->
            Logger.info("Thinking durable projection loaded", record_count: length(plans))
            :ok

          {:error, reason} ->
            clear_live_projection()
            {:error, reason}
        end
      else
        _ -> {:error, :invalid_durable_state}
      end
    else
      if replace?, do: {:error, :store_unavailable}, else: :ok
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp decode_records([], _buffer_size, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_records([record | rest], buffer_size, count, acc)
       when count < @max_loaded_agents do
    plan = decode_record(record, buffer_size)
    decode_records(rest, buffer_size, count + 1, [plan | acc])
  end

  defp decode_records(_records, _buffer_size, _count, _acc),
    do: {:error, :invalid_durable_state}

  defp decode_record(
         {agent_id, %TaintedValue{value: aggregate, taint: outer_taint}, status},
         limit
       ) do
    case ThinkingCodec.decode_aggregate(agent_id, aggregate, outer_taint, status, limit) do
      {:ok, items} -> {agent_id, items}
      {:error, _reason} -> {agent_id, []}
    end
  end

  defp decode_record(_record, _limit), do: {nil, []}

  defp durable_entries_for_cleanup(agent_id, limit) do
    with true <- MemoryStore.available?(),
         {:ok, %TaintedValue{value: aggregate, taint: outer_taint}, status} <-
           MemoryStore.load_tainted_with_status("thinking", agent_id),
         {:ok, items} <-
           ThinkingCodec.decode_aggregate(agent_id, aggregate, outer_taint, status, limit) do
      Enum.map(items, &elem(&1, 0))
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp prepare_installation([], _seen_agents, rows, bindings) do
    {:ok, %{rows: Enum.reverse(rows), bindings: Enum.reverse(bindings)}}
  end

  defp prepare_installation(
         [{agent_id, items} | rest],
         seen_agents,
         rows,
         bindings
       )
       when is_binary(agent_id) do
    with true <- valid_agent_id?(agent_id),
         false <- MapSet.member?(seen_agents, agent_id),
         {:ok, entries, item_bindings} <- prepare_agent_installation(agent_id, items, [], []) do
      prepare_installation(
        rest,
        MapSet.put(seen_agents, agent_id),
        [{agent_id, entries} | rows],
        Enum.reverse(item_bindings, bindings)
      )
    else
      _ -> {:error, :invalid_durable_state}
    end
  end

  defp prepare_installation(_plans, _seen_agents, _rows, _bindings),
    do: {:error, :invalid_durable_state}

  defp prepare_agent_installation(_agent_id, [], entries, bindings),
    do: {:ok, Enum.reverse(entries), bindings}

  defp prepare_agent_installation(agent_id, [{entry, taint, _status} | rest], entries, bindings) do
    with %{id: entry_id} when is_binary(entry_id) <- entry,
         {:ok, payload} <- ThinkingCodec.entry_payload(entry) do
      binding = {agent_id, entry_id, payload, taint}
      prepare_agent_installation(agent_id, rest, [entry | entries], [binding | bindings])
    else
      _ -> {:error, :invalid_durable_state}
    end
  end

  defp prepare_agent_installation(_agent_id, _items, _entries, _bindings),
    do: {:error, :invalid_durable_state}

  defp commit_installation(%{rows: rows, bindings: bindings}) do
    # VP-05D2C integration point: before rebinding each durable agent, invoke
    # the planned bounded domain+agent provenance cleanup. Known ETS bindings
    # are cleared today, but process/ETS churn can leave unenumerated orphans.
    with :ok <- bind_installation(bindings, []) do
      Enum.each(rows, fn
        {_agent_id, []} -> :ok
        {agent_id, entries} -> true = :ets.insert(@ets_table, {agent_id, entries})
      end)

      :ok
    end
  rescue
    _ ->
      cleanup_bindings(bindings)
      {:error, :store_unavailable}
  catch
    _, _ ->
      cleanup_bindings(bindings)
      {:error, :store_unavailable}
  end

  defp bind_installation([], _bound), do: :ok

  defp bind_installation([{agent_id, entry_id, payload, taint} = binding | rest], bound) do
    case put_live_label(agent_id, entry_id, payload, taint) do
      :ok ->
        bind_installation(rest, [binding | bound])

      {:error, _reason} ->
        cleanup_bindings(bound)
        {:error, :store_unavailable}
    end
  end

  defp bind_installation(_bindings, bound) do
    cleanup_bindings(bound)
    {:error, :invalid_durable_state}
  end

  defp cleanup_bindings(bindings) do
    Enum.each(bindings, fn {agent_id, entry_id, _payload, _taint} ->
      _ = Provenance.delete(:thinking_entry, agent_id, entry_id)
    end)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp clear_live_projection do
    @ets_table
    |> :ets.tab2list()
    |> Enum.each(fn
      {agent_id, entries} when is_binary(agent_id) and is_list(entries) ->
        cleanup_labels(agent_id, entries)

      _ ->
        :ok
    end)

    :ets.delete_all_objects(@ets_table)
  end

  defp cleanup_thinking_sidecars_after_clear(agent_id, entries) do
    cleanup_labels(agent_id, entries)

    # VP-05D2C integration point: invoke the planned bounded
    # Provenance.delete_domain_agent(:thinking_entry, agent_id) primitive here.
    # Enumerating known ETS/durable IDs handles current recovery, but cannot prove
    # orphan removal after both inventories were lost; delete_agent/1 is too broad.
    :ok
  end

  defp cleanup_labels(agent_id, entries) when is_list(entries) do
    cleanup_labels_list(agent_id, entries, 0)
  end

  defp cleanup_labels(_agent_id, _entries), do: :ok

  defp safe_cleanup_entries(entries), do: safe_cleanup_entries(entries, [], 0)

  defp safe_cleanup_entries([], acc, _count), do: Enum.reverse(acc)

  defp safe_cleanup_entries([entry | rest], acc, count)
       when count < @max_cleanup_entries,
       do: safe_cleanup_entries(rest, [entry | acc], count + 1)

  defp safe_cleanup_entries(_entries, acc, _count), do: Enum.reverse(acc)

  defp cleanup_labels_list(_agent_id, [], _count), do: :ok

  defp cleanup_labels_list(agent_id, [%{id: id} | rest], count)
       when is_binary(id) and count < @max_cleanup_entries do
    _ = Provenance.delete(:thinking_entry, agent_id, id)
    cleanup_labels_list(agent_id, rest, count + 1)
  end

  defp cleanup_labels_list(agent_id, [_entry | rest], count)
       when count < @max_cleanup_entries,
       do: cleanup_labels_list(agent_id, rest, count + 1)

  defp cleanup_labels_list(_agent_id, _entries, _count), do: :ok

  # C3G owns shared embedding identity, provenance convergence, and eviction.
  # Thinking only preserves the existing post-commit enqueue path and never
  # deletes content-hash embeddings that another memory domain may share.
  defp enqueue_embedding(entry, taint) do
    _ =
      MemoryStore.embed_async("thinking", "#{entry.agent_id}:#{entry.id}", entry.text,
        agent_id: entry.agent_id,
        type: :thought,
        taint: taint
      )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp emit_recorded(entry) do
    Signals.emit_memory_signal(entry.agent_id, :thinking_recorded, %{
      entry_id: entry.id,
      text_bytes: byte_size(entry.text),
      significant: entry.significant,
      recorded_at: entry.created_at
    })

    Logger.debug("Thinking recorded", agent_id: entry.agent_id, entry_id: entry.id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp validate_record_opts(opts) do
    with :ok <- validate_keyword_keys(opts, [:significant, :metadata]),
         significant <- Keyword.get(opts, :significant, false),
         metadata <- Keyword.get(opts, :metadata, %{}),
         true <- is_boolean(significant),
         true <- is_map(metadata) and not is_struct(metadata) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_stream_opts(opts) do
    with :ok <- validate_keyword_keys(opts, [:complete, :significant, :metadata]),
         true <- is_boolean(Keyword.get(opts, :complete, false)) do
      validate_record_opts(Keyword.delete(opts, :complete))
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_reader_request(agent_id, opts) do
    with true <- valid_agent_id?(agent_id),
         :ok <- validate_keyword_keys(opts, [:limit, :since, :significant_only]),
         limit <- Keyword.get(opts, :limit, 10),
         true <- is_integer(limit) and limit >= 0 and limit <= @max_entries,
         since <- Keyword.get(opts, :since),
         true <- is_nil(since) or match?(%DateTime{}, since),
         true <- is_boolean(Keyword.get(opts, :significant_only, false)) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_keyword_keys(opts, allowed) do
    with {:ok, keys} <- bounded_keyword_keys(opts, length(allowed), [], 0),
         true <- Enum.all?(keys, &(&1 in allowed)),
         true <- length(keys) == MapSet.size(MapSet.new(keys)) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp bounded_keyword_keys([], _max, acc, _count), do: {:ok, Enum.reverse(acc)}

  defp bounded_keyword_keys([{key, _value} | rest], max, acc, count)
       when is_atom(key) and count < max,
       do: bounded_keyword_keys(rest, max, [key | acc], count + 1)

  defp bounded_keyword_keys(_opts, _max, _acc, _count),
    do: {:error, :invalid_request}

  defp valid_agent_id?(agent_id) when is_binary(agent_id) do
    byte_size(agent_id) in 1..256 and String.valid?(agent_id) and String.trim(agent_id) != ""
  end

  defp valid_agent_id?(_agent_id), do: false

  defp normalize_buffer_size(size)
       when is_integer(size) and size > 0 and size <= @max_entries,
       do: size

  defp normalize_buffer_size(_size), do: @default_buffer_size

  defp normalize_store_error(reason)
       when reason in [:invalid_payload, :invalid_aggregate, :invalid_request],
       do: :invalid_payload

  defp normalize_store_error(_reason), do: :store_unavailable

  # ============================================================================
  # Multi-Provider Extraction (ported from Seed ThinkingBlockProcessor)
  # ============================================================================

  @doc """
  Extract thinking content from an LLM response.

  Supports multiple providers:
  - `:anthropic` — content blocks with `"type" => "thinking"`
  - `:deepseek` — `reasoning_content` field
  - `:openai` — explicitly returns `{:none, :hidden_reasoning}` (o1/o3 hide reasoning)
  - `:generic` — fallback chain: anthropic → deepseek → XML `<thinking>` tags

  ## Options

  - `:fallback_to_generic` — try generic extraction on failure (default: false)

  ## Returns

  - `{:ok, text}` — extracted thinking text
  - `{:none, reason}` — no thinking found
  """
  @spec extract(map(), atom(), keyword()) :: {:ok, String.t()} | {:none, atom()}
  def extract(response, provider, opts \\ [])

  def extract(response, :anthropic, opts) do
    case extract_anthropic_thinking(response) do
      {:ok, _} = ok ->
        ok

      {:none, _} = none ->
        if Keyword.get(opts, :fallback_to_generic, false),
          do: extract(response, :generic, []),
          else: none
    end
  end

  def extract(response, :deepseek, opts) do
    case extract_deepseek_reasoning(response) do
      {:ok, _} = ok ->
        ok

      {:none, _} = none ->
        if Keyword.get(opts, :fallback_to_generic, false),
          do: extract(response, :generic, []),
          else: none
    end
  end

  def extract(_response, :openai, _opts) do
    {:none, :hidden_reasoning}
  end

  def extract(response, :generic, _opts) do
    extract_generic_thinking(response)
  end

  def extract(response, _unknown_provider, _opts) do
    extract_generic_thinking(response)
  end

  @doc """
  Extract thinking from an LLM response and record it for the agent.

  Combines `extract/3` and `record_thinking/3`. Automatically flags
  identity-affecting thinking as significant.
  """
  @spec extract_and_record(String.t(), map(), atom(), keyword()) ::
          {:ok, thinking_entry()} | {:none, atom()} | {:error, atom()}
  def extract_and_record(agent_id, response, provider, opts \\ []) do
    case extract(response, provider, opts) do
      {:ok, text} ->
        significant = identity_affecting?(text)
        metadata = Keyword.get(opts, :metadata, %{})
        record_thinking(agent_id, text, significant: significant, metadata: metadata)

      {:none, reason} ->
        {:none, reason}
    end
  end

  @doc """
  Returns true if the thinking text contains identity-affecting patterns.

  Checks for goal-related, learning, self-reflection, and constraint keywords.
  """
  @spec identity_affecting?(String.t()) :: boolean()
  def identity_affecting?(text) when is_binary(text) do
    downcased = String.downcase(text)

    goal_patterns = ["my goal", "i should", "i want to", "i need to"]
    learning_patterns = ["i learned", "i realize", "i understand now", "i discovered"]
    self_patterns = ["i am", "my purpose", "my role", "my values"]
    constraint_patterns = ["i cannot", "i must not", "my constraints"]

    Enum.any?(
      goal_patterns ++ learning_patterns ++ self_patterns ++ constraint_patterns,
      fn pattern ->
        String.contains?(downcased, pattern)
      end
    )
  end

  def identity_affecting?(_), do: false

  # ============================================================================
  # Provider-Specific Extraction
  # ============================================================================

  defp extract_anthropic_thinking(response) do
    blocks = get_content_blocks(response)

    thinking_texts =
      blocks
      |> Enum.filter(&(is_map(&1) and (&1["type"] == "thinking" or &1[:type] == "thinking")))
      |> Enum.map(&(&1["thinking"] || &1[:thinking] || ""))
      |> Enum.reject(&(&1 == ""))

    case thinking_texts do
      [] -> {:none, :no_thinking_blocks}
      texts -> {:ok, Enum.join(texts, "\n\n")}
    end
  end

  defp extract_deepseek_reasoning(response) do
    reasoning =
      get_nested(response, ["reasoning_content"]) ||
        get_nested(response, [:reasoning_content])

    case reasoning do
      nil -> {:none, :no_reasoning_content}
      "" -> {:none, :no_reasoning_content}
      text when is_binary(text) -> {:ok, text}
      _ -> {:none, :no_reasoning_content}
    end
  end

  defp extract_generic_thinking(response) do
    with :not_found <- try_anthropic_thinking(response),
         :not_found <- try_deepseek_reasoning(response),
         :not_found <- try_thinking_field(response) do
      extract_xml_thinking(response)
    end
  end

  defp try_anthropic_thinking(response) do
    case extract_anthropic_thinking(response) do
      {:ok, _} = ok -> ok
      _ -> :not_found
    end
  end

  defp try_deepseek_reasoning(response) do
    case extract_deepseek_reasoning(response) do
      {:ok, _} = ok -> ok
      _ -> :not_found
    end
  end

  defp try_thinking_field(response) do
    thinking = get_nested(response, ["thinking"]) || get_nested(response, [:thinking])

    case thinking do
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> :not_found
    end
  end

  defp extract_xml_thinking(response) do
    text = extract_text_content(response)

    case Regex.run(~r/<thinking>(.*?)<\/thinking>/s, text) do
      [_, captured] when captured != "" -> {:ok, String.trim(captured)}
      _ -> {:none, :no_thinking_found}
    end
  end

  defp extract_text_content(response) when is_binary(response), do: response

  defp extract_text_content(response) when is_map(response) do
    cond do
      is_binary(response["content"]) -> response["content"]
      is_binary(response[:content]) -> response[:content]
      true -> extract_text_from_blocks(response)
    end
  end

  defp extract_text_content(_response), do: ""

  defp extract_text_from_blocks(response) do
    response
    |> get_content_blocks()
    |> Enum.filter(&(is_map(&1) and (&1["type"] == "text" or &1[:type] == "text")))
    |> Enum.map_join("\n", &(&1["text"] || &1[:text] || ""))
  end

  defp get_content_blocks(response) when is_map(response) do
    cond do
      is_list(response["content"]) -> response["content"]
      is_list(response[:content]) -> response[:content]
      true -> []
    end
  end

  defp get_content_blocks(_), do: []

  defp get_nested(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:halt, value}
        _ -> {:halt, nil}
      end
    end)
  end

  defp get_nested(_, _), do: nil
end
