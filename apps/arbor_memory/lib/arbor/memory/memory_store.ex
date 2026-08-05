defmodule Arbor.Memory.MemoryStore do
  @moduledoc """
  Write-through persistence helpers for memory stores.

  All memory stores use ETS for fast reads. This module provides
  helpers to persist to a durable backend via `BufferedStore` for
  crash recovery and startup loading.

  Routes through `Arbor.Persistence.BufferedStore` at `:arbor_memory_durable`.
  The BufferedStore handles ETS caching + backend writes internally.
  All operations degrade gracefully — if the store process is not running
  (e.g., in tests), callers continue in ETS-only mode.
  """

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Memory.Embedding
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  require Logger

  @store_name :arbor_memory_durable
  @legacy_taint_keys ~w(
    taint_level
    taint_sensitivity
    taint_sanitizations
    taint_confidence
    taint_source
    taint_chain
    taint_data_hash
  )
  @legacy_taint_atom_keys [
    :taint_level,
    :taint_sensitivity,
    :taint_sanitizations,
    :taint_confidence,
    :taint_source,
    :taint_chain,
    :taint_data_hash
  ]
  @critical_delete_attempts 12
  @legacy_cleanup_attempts 4
  @max_critical_namespace_bytes 256
  @max_inventory_identifier_bytes 1_024

  @type provenance_status :: :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type authoritative_location :: :namespaced | :legacy_bare

  @doc """
  Persist a record to the durable store (sync).

  Returns `:ok` on success or if the store is unavailable (graceful degradation).
  Supplied taint or payload validation failures return a bounded error before
  any write.

  ## Options

  - `:taint` - A `Arbor.Contracts.Security.Taint` struct to persist alongside
    the data. Stored in `record.metadata["taint"]` as a string-keyed map.
  """
  @spec persist(String.t(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def persist(namespace, key, data, opts \\ [])

  def persist(namespace, key, data, opts) when is_binary(namespace) and is_binary(key) do
    if keyword_options?(opts) do
      case build_taint_metadata(data, opts) do
        {:ok, metadata} ->
          if available?(), do: persist_record(namespace, key, data, metadata), else: :ok

        {:error, _reason} = error ->
          error
      end
    else
      {:error, {:memory_store, :invalid_request, :invalid_options}}
    end
  end

  def persist(_namespace, _key, _data, _opts),
    do: {:error, {:memory_store, :invalid_request, :invalid_arguments}}

  @doc """
  Persist a record asynchronously.

  Spawns a Task to write. Backend failures remain fire-and-forget, while
  supplied taint or payload validation failures return a bounded error before
  spawning. Accepts the same options as `persist/4`.
  """
  @spec persist_async(String.t(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def persist_async(namespace, key, data, opts \\ [])

  def persist_async(namespace, key, data, opts)
      when is_binary(namespace) and is_binary(key) and is_list(opts) do
    if keyword_options?(opts) do
      case build_taint_metadata(data, opts) do
        {:ok, metadata} ->
          if available?() do
            Task.start(fn -> persist_record(namespace, key, data, metadata) end)
            :ok
          else
            :ok
          end

        {:error, _reason} = error ->
          error
      end
    else
      {:error, {:memory_store, :invalid_request, :invalid_options}}
    end
  end

  def persist_async(_namespace, _key, _data, _opts),
    do: {:error, {:memory_store, :invalid_request, :invalid_arguments}}

  @doc """
  Load a single record by namespace and key.

  Returns `{:ok, data_map}` or `{:error, :not_found}`.
  """
  @spec load(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load(namespace, key) do
    if available?() do
      composite_key = "#{namespace}:#{key}"

      case BufferedStore.get(composite_key, name: @store_name) do
        {:ok, %Record{data: data}} ->
          {:ok, data}

        {:error, :not_found} ->
          # Fallback: try bare key (old data loaded from Postgres without prefix)
          case BufferedStore.get(key, name: @store_name) do
            {:ok, %Record{data: data}} -> {:ok, data}
            _ -> {:error, :not_found}
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.load failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
      )

      {:error, :not_found}
  end

  @doc """
  Load all records for a namespace.

  Returns `{:ok, [{key, data}]}` or `{:ok, []}` if unavailable.
  """
  @spec load_all(String.t()) :: {:ok, [{String.t(), map()}]}
  def load_all(namespace) do
    if available?() do
      prefix = "#{namespace}:"

      {:ok, keys} = BufferedStore.list(name: @store_name)

      # Match keys with namespace prefix (new format) first
      prefixed = Enum.filter(keys, &String.starts_with?(&1, prefix))

      records =
        if prefixed != [] do
          load_prefixed_records(prefixed, prefix)
        else
          load_compat_records(keys, prefix)
        end

      {:ok, Enum.reverse(records)}
    else
      {:ok, []}
    end
  catch
    kind, reason ->
      Logger.warning("MemoryStore.load_all failed for #{namespace}: #{inspect({kind, reason})}")
      {:ok, []}
  end

  @doc """
  Load records matching a key prefix.

  Returns `{:ok, [{key, data}]}`.
  """
  @spec load_by_prefix(String.t(), String.t()) :: {:ok, [{String.t(), map()}]}
  def load_by_prefix(namespace, prefix) do
    if available?() do
      full_prefix = "#{namespace}:#{prefix}"

      {:ok, keys} = BufferedStore.list(name: @store_name)

      # Match prefixed keys first
      prefixed = Enum.filter(keys, &String.starts_with?(&1, full_prefix))

      records =
        if prefixed != [] do
          load_prefixed_records(prefixed, "#{namespace}:")
        else
          load_compat_records_by_prefix(keys, prefix, full_prefix)
        end

      {:ok, Enum.reverse(records)}
    else
      {:ok, []}
    end
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.load_by_prefix failed for #{namespace}/#{prefix}: #{inspect({kind, reason})}"
      )

      {:ok, []}
  end

  @doc """
  Load all records for a namespace with per-item taint and provenance status.

  Each item has the stable shape {key, tainted_value, status}, where status
  is :verified, :legacy_unlabeled, or :invalid_durable_provenance.
  """
  @spec load_all_tainted(String.t()) ::
          {:ok, [{String.t(), Arbor.Contracts.Security.TaintedValue.t(), atom()}]}
  def load_all_tainted(namespace) when is_binary(namespace) do
    if available?() do
      prefix = "#{namespace}:"
      {:ok, keys} = BufferedStore.list(name: @store_name)

      prefixed = Enum.filter(keys, &String.starts_with?(&1, prefix))

      records =
        if prefixed != [] do
          load_prefixed_record_entries(prefixed, prefix)
        else
          load_compat_record_entries(keys, prefix)
        end

      {:ok, tainted_entries(records)}
    else
      {:ok, []}
    end
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.load_all_tainted failed for #{namespace}: #{inspect({kind, reason})}"
      )

      {:ok, []}
  end

  def load_all_tainted(_namespace), do: {:ok, []}

  @doc """
  Load records matching a key prefix with per-item taint and provenance status.

  Each item has the stable shape {key, tainted_value, status}. A malformed
  item is retained with the invalid fail-closed status rather than dropped.
  """
  @spec load_by_prefix_tainted(String.t(), String.t()) ::
          {:ok, [{String.t(), Arbor.Contracts.Security.TaintedValue.t(), atom()}]}
  def load_by_prefix_tainted(namespace, prefix) when is_binary(namespace) and is_binary(prefix) do
    if available?() do
      full_prefix = "#{namespace}:#{prefix}"
      {:ok, keys} = BufferedStore.list(name: @store_name)

      prefixed = Enum.filter(keys, &String.starts_with?(&1, full_prefix))

      records =
        if prefixed != [] do
          load_prefixed_record_entries(prefixed, "#{namespace}:")
        else
          load_compat_record_entries_by_prefix(keys, prefix, full_prefix)
        end

      {:ok, tainted_entries(records)}
    else
      {:ok, []}
    end
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.load_by_prefix_tainted failed for #{namespace}/#{prefix}: #{inspect({kind, reason})}"
      )

      {:ok, []}
  end

  def load_by_prefix_tainted(_namespace, _prefix), do: {:ok, []}

  # ── Record loading helpers ──────────────────────────────────────────

  defp load_prefixed_records(prefixed_keys, prefix) do
    Enum.reduce(prefixed_keys, [], fn composite_key, acc ->
      case BufferedStore.get(composite_key, name: @store_name) do
        {:ok, %Record{key: k, data: data}} ->
          [{String.replace_prefix(k, prefix, ""), data} | acc]

        _ ->
          acc
      end
    end)
  end

  defp load_compat_records(keys, prefix) do
    Enum.reduce(keys, [], fn ets_key, acc ->
      case BufferedStore.get(ets_key, name: @store_name) do
        {:ok, %Record{id: id, key: k, data: data}} when is_binary(id) ->
          if String.starts_with?(id, prefix), do: [{k, data} | acc], else: acc

        _ ->
          acc
      end
    end)
  end

  defp load_compat_records_by_prefix(keys, key_prefix, id_prefix) do
    keys
    |> Enum.filter(&String.starts_with?(&1, key_prefix))
    |> Enum.reduce([], fn ets_key, acc ->
      case BufferedStore.get(ets_key, name: @store_name) do
        {:ok, %Record{id: id, key: k, data: data}} when is_binary(id) ->
          if String.starts_with?(id, id_prefix), do: [{k, data} | acc], else: acc

        _ ->
          acc
      end
    end)
  end

  defp load_prefixed_record_entries(prefixed_keys, prefix) do
    Enum.reduce(prefixed_keys, [], fn composite_key, acc ->
      case BufferedStore.get(composite_key, name: @store_name) do
        {:ok, %Record{key: k} = record} ->
          [{String.replace_prefix(k, prefix, ""), record} | acc]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp load_compat_record_entries(keys, prefix) do
    Enum.reduce(keys, [], fn ets_key, acc ->
      case BufferedStore.get(ets_key, name: @store_name) do
        {:ok, %Record{id: id, key: k} = record} when is_binary(id) ->
          if String.starts_with?(id, prefix), do: [{k, record} | acc], else: acc

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp load_compat_record_entries_by_prefix(keys, key_prefix, id_prefix) do
    keys
    |> Enum.filter(&String.starts_with?(&1, key_prefix))
    |> Enum.reduce([], fn ets_key, acc ->
      case BufferedStore.get(ets_key, name: @store_name) do
        {:ok, %Record{id: id, key: k} = record} when is_binary(id) ->
          if String.starts_with?(id, id_prefix), do: [{k, record} | acc], else: acc

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Load a single record with taint metadata as a TaintedValue.

  Unlike `load/2`, this returns the data wrapped in a `TaintedValue` struct
  that carries the persisted taint metadata. Legacy data without taint
  metadata gets an untrusted, restricted, unverified fallback and is reported
  as :legacy_unlabeled by the status-bearing primitive.

  Returns `{:ok, TaintedValue.t()}` or `{:error, term()}`.
  """
  @spec load_tainted(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def load_tainted(namespace, key) do
    case load_tainted_with_status(namespace, key) do
      {:ok, tainted_value, _status} -> {:ok, tainted_value}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Load a single record with its tainted value and provenance status.

  Missing metadata is reported as :legacy_unlabeled with an untrusted,
  restricted, unverified fallback. Malformed, versionless, unknown-version,
  and payload-mismatched envelopes are reported as
  :invalid_durable_provenance with a hostile fail-closed taint.
  """
  @spec load_tainted_with_status(String.t(), String.t()) ::
          {:ok, Arbor.Contracts.Security.TaintedValue.t(),
           :verified | :legacy_unlabeled | :invalid_durable_provenance}
          | {:error, term()}
  def load_tainted_with_status(namespace, key) do
    if available?() do
      composite_key = "#{namespace}:#{key}"

      case load_record_with_metadata(composite_key, key) do
        {:ok, %Record{} = record} -> resolve_tainted_record(record)
        {:error, _} = error -> error
      end
    else
      {:error, :not_found}
    end
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.load_tainted_with_status failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
      )

      {:error, :not_found}
  end

  @doc """
  Authoritatively load one tainted record and its backend-owned fencing token.

  Deliberate ETS-only stores are accepted as process-lifetime authority. A
  configured store must advertise `:node_restart` durability in code; unknown
  or weaker configured durability fails closed. Configured backend errors never
  fall back to the BufferedStore cache.
  """
  @spec load_tainted_authoritative_with_status(String.t(), String.t()) ::
          {:ok, Arbor.Contracts.Security.TaintedValue.t(), provenance_status(), Record.t(),
           authoritative_location()}
          | {:error, term()}
  def load_tainted_authoritative_with_status(namespace, key)
      when is_binary(namespace) and is_binary(key) do
    composite_key = composite_key(namespace, key)

    with :ok <- validate_critical_namespace(namespace),
         :ok <- ensure_critical_authority() do
      case Persistence.buffered_store_authoritative_get(@store_name, composite_key) do
        {:ok, %Record{} = record} ->
          if current_namespaced_record?(record, composite_key),
            do: resolve_authoritative_record(record, composite_key, :namespaced),
            else: critical_error(:invalid_record)

        {:ok, _other} ->
          critical_error(:invalid_record)

        {:error, :not_found} ->
          load_authoritative_bare_record(namespace, key)

        {:error, _reason} ->
          critical_error(:durable_unavailable)
      end
    end
  rescue
    _ -> critical_error(:durable_unavailable)
  catch
    _, _ -> critical_error(:durable_unavailable)
  end

  def load_tainted_authoritative_with_status(_namespace, _key),
    do: critical_error(:invalid_request)

  @doc """
  Return a bounded authoritative tainted inventory for one memory namespace.

  Configured stores read only from their durable backend; deliberate ephemeral
  stores read owner ETS. Namespaced rows take precedence over strictly owned
  bare legacy rows for the same logical key. Structural ambiguity, malformed
  rows, oversized inventories, and backend errors fail closed.
  """
  @spec load_all_tainted_authoritative(String.t()) ::
          {:ok, [{String.t(), Arbor.Contracts.Security.TaintedValue.t(), provenance_status()}]}
          | {:error, term()}
  def load_all_tainted_authoritative(namespace) when is_binary(namespace) do
    load_tainted_inventory_authoritative(namespace, nil)
  end

  def load_all_tainted_authoritative(_namespace), do: critical_error(:invalid_request)

  @doc "Return a bounded authoritative tainted inventory matching a logical-key prefix."
  @spec load_by_prefix_tainted_authoritative(String.t(), String.t()) ::
          {:ok, [{String.t(), Arbor.Contracts.Security.TaintedValue.t(), provenance_status()}]}
          | {:error, term()}
  def load_by_prefix_tainted_authoritative(namespace, prefix)
      when is_binary(namespace) and is_binary(prefix) do
    load_tainted_inventory_authoritative(namespace, prefix)
  end

  def load_by_prefix_tainted_authoritative(_namespace, _prefix),
    do: critical_error(:invalid_request)

  @doc """
  Validate taint and atomically CAS one authoritative structured record.

  On success the namespaced record is committed first, then any bare legacy
  compatibility key is removed with acknowledgement. Once the CAS returns its
  stored receipt, cleanup is best-effort maintenance and cannot turn a known
  business commit into a retryable error.
  """
  @spec compare_and_swap_tainted(
          String.t(),
          String.t(),
          :not_found | Record.t(),
          term(),
          keyword()
        ) :: {:ok, Record.t()} | {:error, term()}
  def compare_and_swap_tainted(namespace, key, expected, data, opts \\ [])

  def compare_and_swap_tainted(namespace, key, expected, data, opts)
      when is_binary(namespace) and is_binary(key) do
    case commit_tainted_compare_and_swap(namespace, key, expected, data, opts) do
      {:ok, %Record{} = stored} ->
        committed = {:ok, stored}
        _ = observe_legacy_cleanup(namespace, key)
        committed

      {:error, _reason} = error ->
        error
    end
  end

  def compare_and_swap_tainted(_namespace, _key, _expected, _data, _opts),
    do: critical_error(:invalid_request)

  defp commit_tainted_compare_and_swap(namespace, key, expected, data, opts) do
    with :ok <- validate_critical_namespace(namespace),
         true <- keyword_options?(opts),
         {:ok, metadata} <- build_taint_metadata(data, opts),
         :ok <- ensure_critical_authority(),
         composite_key <- composite_key(namespace, key),
         {:ok, cas_expected, replacement} <-
           build_cas_record(namespace, key, composite_key, expected, data, metadata),
         {:ok, %Record{} = stored} <-
           Persistence.buffered_store_acknowledged_compare_and_swap(
             @store_name,
             composite_key,
             cas_expected,
             replacement
           ) do
      {:ok, stored}
    else
      false -> critical_error(:invalid_options)
      {:error, {:memory_store, _kind, _reason}} = error -> error
      {:error, :conflict} -> critical_error(:conflict)
      {:error, :key_mismatch} -> critical_error(:invalid_record)
      {:error, _reason} -> critical_error(:durable_unavailable)
      _ -> critical_error(:invalid_record)
    end
  rescue
    _ -> critical_error(:durable_unavailable)
  catch
    _, _ -> critical_error(:durable_unavailable)
  end

  @doc """
  Delete owned legacy and namespaced records with authoritative fencing.

  Every physical row is first observed authoritatively and removed with
  compare-and-delete. Conflicts retry from a new authoritative observation, so
  a concurrent namespaced writer is a serial winner rather than an
  acknowledged live-only update later erased by an unconditional delete.
  """
  @spec delete_tainted_authoritative(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_tainted_authoritative(namespace, key)
      when is_binary(namespace) and is_binary(key) do
    with :ok <- validate_critical_namespace(namespace),
         :ok <- ensure_critical_authority() do
      delete_tainted_authoritative(namespace, key, @critical_delete_attempts)
    else
      {:error, {:memory_store, _kind, _reason}} = error -> error
      {:error, _reason} -> critical_error(:durable_unavailable)
      _ -> critical_error(:durable_unavailable)
    end
  rescue
    _ -> critical_error(:durable_unavailable)
  catch
    _, _ -> critical_error(:durable_unavailable)
  end

  def delete_tainted_authoritative(_namespace, _key),
    do: critical_error(:invalid_request)

  @doc """
  Delete a record.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(namespace, key) do
    if available?() do
      composite_key = "#{namespace}:#{key}"
      _ = cleanup_owned_legacy_bare_compat(namespace, key, @legacy_cleanup_attempts)
      BufferedStore.delete(composite_key, name: @store_name)
    end

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.delete failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
      )

      :ok
  end

  @doc """
  Delete all records matching a key prefix.
  """
  @spec delete_by_prefix(String.t(), String.t()) :: :ok
  def delete_by_prefix(namespace, prefix) do
    case load_by_prefix(namespace, prefix) do
      {:ok, pairs} ->
        Enum.each(pairs, fn {key, _data} ->
          delete(namespace, key)
        end)

      _ ->
        :ok
    end
  end

  @doc """
  Check if the durable store is available.
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(@store_name) != nil
  rescue
    _ -> false
  end

  # ============================================================================
  # Embedding — semantic memory via pgvector
  # ============================================================================

  @doc """
  Queue an embedding for a memory record (async).

  Generates an embedding via `Arbor.AI.embed/2` and stores it in the
  `memory_embeddings` table for semantic search. Fire-and-forget —
  failures are logged at debug level and never affect the caller. An invalid
  supplied taint returns a bounded error before spawning.

  ## Parameters

  - `namespace` - Memory store namespace (e.g., "goals", "thinking")
  - `key` - Record key (e.g., "agent_123:goal_456")
  - `content` - Text content to embed
  - `opts` - Additional metadata for the embedding
    - `:agent_id` - Agent that owns this memory
    - `:type` - Semantic type hint (e.g., :goal, :thought, :intent)
  """
  @spec embed_async(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def embed_async(namespace, key, content, opts \\ [])

  def embed_async(namespace, key, content, opts)
      when is_binary(namespace) and is_binary(key) do
    if keyword_options?(opts) do
      agent_id = Keyword.get(opts, :agent_id)
      type = Keyword.get(opts, :type)

      with {:ok, type} <- normalize_embedding_type(type),
           base_metadata <- %{type: type, source: namespace},
           {:ok, metadata} <- maybe_add_taint_to_embedding(base_metadata, content, opts) do
        if agent_id && is_binary(content) && content != "" do
          Task.start(fn ->
            try do
              case Arbor.AI.embed(content) do
                {:ok, %{embedding: embedding}} ->
                  Embedding.store(agent_id, content, embedding, metadata)

                {:error, reason} ->
                  Logger.debug("Embedding failed for #{namespace}/#{key}: #{inspect(reason)}")
              end
            rescue
              e -> Logger.debug("embed_async error: #{Exception.message(e)}")
            catch
              kind, reason -> Logger.debug("embed_async #{kind}: #{inspect(reason)}")
            end
          end)
        end

        :ok
      else
        {:error, _reason} = error -> error
      end
    else
      {:error, {:memory_store, :invalid_request, :invalid_options}}
    end
  end

  def embed_async(_namespace, _key, _content, _opts),
    do: {:error, {:memory_store, :invalid_request, :invalid_arguments}}

  @doc """
  Search memory by semantic similarity.

  Embeds the query text, then searches `memory_embeddings` using pgvector
  cosine distance. Returns `{:ok, results}` or `{:ok, []}` on any failure.

  ## Options

  - `:agent_id` - Required. Scopes search to this agent's embeddings.
  - `:limit` - Max results (default 10)
  - `:threshold` - Minimum similarity 0.0–1.0 (default 0.3)
  - `:type_filter` - Filter by memory_type (e.g., "goal", "intent", "thought")
  """
  @spec semantic_search(String.t(), String.t(), keyword()) :: {:ok, [map()]}
  def semantic_search(query_text, namespace, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)

    if agent_id && query_text && query_text != "" do
      do_semantic_search(query_text, agent_id, namespace, opts)
    else
      {:ok, []}
    end
  catch
    kind, reason ->
      Logger.debug("semantic_search #{kind}: #{inspect(reason)}")
      {:ok, []}
  end

  defp do_semantic_search(query_text, agent_id, _namespace, opts) do
    case Arbor.AI.embed(query_text) do
      {:ok, %{embedding: embedding}} ->
        search_opts =
          [
            limit: Keyword.get(opts, :limit, 10),
            threshold: Keyword.get(opts, :threshold, 0.3)
          ]
          |> maybe_add_type_filter(opts)

        case Embedding.search(agent_id, embedding, search_opts) do
          {:ok, results} ->
            {:ok, results}

          {:error, reason} ->
            Logger.debug("Semantic search query failed: #{inspect(reason)}")
            {:ok, []}
        end

      {:error, reason} ->
        Logger.debug("Semantic search embedding failed: #{inspect(reason)}")
        {:ok, []}
    end
  end

  defp maybe_add_type_filter(search_opts, opts) do
    case Keyword.get(opts, :type_filter) do
      nil -> search_opts
      filter -> Keyword.put(search_opts, :type_filter, to_string(filter))
    end
  end

  # ── Taint persistence helpers ────────────────────────────────────────

  defp persist_record(namespace, key, data, metadata) do
    if available?() do
      composite_key = "#{namespace}:#{key}"
      record = Record.new(composite_key, data, id: "memory:#{composite_key}", metadata: metadata)

      try do
        BufferedStore.put(composite_key, record, name: @store_name)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
        :throw, _ -> :ok
      end
    else
      :ok
    end
  end

  defp ensure_critical_authority do
    case Persistence.buffered_store_authority_mode(@store_name) do
      {:ok, :ephemeral} -> :ok
      {:ok, {:backend, :node_restart}} -> :ok
      {:ok, {:backend, _insufficient}} -> critical_error(:insufficient_durability)
      {:error, _reason} -> critical_error(:durable_unavailable)
      _ -> critical_error(:durable_unavailable)
    end
  end

  defp load_tainted_inventory_authoritative(namespace, prefix) do
    with :ok <- validate_critical_namespace(namespace),
         :ok <- validate_optional_inventory_prefix(prefix),
         :ok <- ensure_critical_authority(),
         {:ok, rows} <- authoritative_inventory_entries() do
      build_authoritative_inventory(namespace, prefix, rows)
    end
  rescue
    _ -> critical_error(:durable_unavailable)
  catch
    _, _ -> critical_error(:durable_unavailable)
  end

  defp authoritative_inventory_entries do
    case Persistence.buffered_store_authoritative_entries(@store_name) do
      {:ok, rows} -> {:ok, rows}
      {:error, :inventory_limit_exceeded} -> critical_error(:inventory_limit_exceeded)
      {:error, _reason} -> critical_error(:durable_unavailable)
      _ -> critical_error(:durable_unavailable)
    end
  end

  defp build_authoritative_inventory(namespace, prefix, rows) do
    with {:ok, classified} <- classify_authoritative_inventory(namespace, rows),
         {:ok, selected} <- select_authoritative_inventory(classified, prefix) do
      {:ok, selected}
    end
  end

  defp classify_authoritative_inventory(namespace, rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn {physical_key, value}, {:ok, acc} ->
      case classify_inventory_row(namespace, physical_key, value) do
        {:ok, :foreign} ->
          {:cont, {:ok, acc}}

        {:ok, {kind, logical_key, %Record{} = record}} ->
          case put_classified_inventory(acc, logical_key, kind, record) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp classify_inventory_row(namespace, physical_key, %Record{key: physical_key} = record) do
    namespaced_prefix = "#{namespace}:"

    cond do
      String.starts_with?(physical_key, namespaced_prefix) ->
        logical_key = String.replace_prefix(physical_key, namespaced_prefix, "")

        if logical_key != "" and current_namespaced_record?(record, physical_key) do
          {:ok, {:namespaced, logical_key, record}}
        else
          critical_error(:invalid_record)
        end

      current_namespaced_record?(record, physical_key) ->
        {:ok, :foreign}

      true ->
        case legacy_bare_owner(record, physical_key) do
          {:ok, ^namespace} -> {:ok, {:legacy_bare, physical_key, record}}
          {:ok, _foreign_namespace} -> {:ok, :foreign}
          :error -> critical_error(:invalid_record)
        end
    end
  end

  defp classify_inventory_row(_namespace, _physical_key, _value),
    do: critical_error(:invalid_record)

  defp current_namespaced_record?(%Record{id: id}, physical_key) do
    id in [physical_key, "memory:#{physical_key}"]
  end

  defp legacy_bare_owner(%Record{id: id}, physical_key) when is_binary(id) do
    normalized = String.replace_prefix(id, "memory:", "")
    suffix = ":#{physical_key}"

    if String.ends_with?(normalized, suffix) and byte_size(normalized) > byte_size(suffix) do
      owner_size = byte_size(normalized) - byte_size(suffix)
      {:ok, binary_part(normalized, 0, owner_size)}
    else
      :error
    end
  end

  defp legacy_bare_owner(_record, _physical_key), do: :error

  defp put_classified_inventory(acc, logical_key, kind, record) do
    entry = Map.get(acc, logical_key, %{})

    if Map.has_key?(entry, kind) do
      critical_error(:ambiguous_record)
    else
      {:ok, Map.put(acc, logical_key, Map.put(entry, kind, record))}
    end
  end

  defp select_authoritative_inventory(classified, prefix) do
    classified
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {logical_key, choices}, {:ok, acc} ->
      if is_binary(prefix) and not String.starts_with?(logical_key, prefix) do
        {:cont, {:ok, acc}}
      else
        record = Map.get(choices, :namespaced) || Map.get(choices, :legacy_bare)

        case resolve_tainted_record(record) do
          {:ok, value, status} ->
            {:cont, {:ok, [{logical_key, value, status} | acc]}}

          _ ->
            {:halt, critical_error(:invalid_record)}
        end
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_inventory_identifier(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_inventory_identifier_bytes and
         String.valid?(value) do
      :ok
    else
      critical_error(:invalid_request)
    end
  end

  # Critical physical keys use the historical "namespace:key" encoding. Keeping
  # ':' out of the admitted namespace grammar makes that encoding injective while
  # preserving every historical colon-free key and allowing ':' in logical keys.
  defp validate_critical_namespace(namespace) when is_binary(namespace) do
    if byte_size(namespace) > 0 and byte_size(namespace) <= @max_critical_namespace_bytes and
         String.valid?(namespace) and String.trim(namespace) != "" and
         :binary.match(namespace, ":") == :nomatch do
      :ok
    else
      critical_error(:invalid_request)
    end
  end

  defp validate_critical_namespace(_namespace), do: critical_error(:invalid_request)

  defp validate_optional_inventory_prefix(nil), do: :ok
  defp validate_optional_inventory_prefix(prefix), do: validate_inventory_identifier(prefix)

  defp load_authoritative_bare_record(namespace, key) do
    case classify_authoritative_bare(namespace, key) do
      {:ok, {:owned, record}} ->
        resolve_authoritative_record(record, key, :legacy_bare)

      {:ok, classification} when classification in [:absent, :not_owned] ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_authoritative_record(%Record{} = record, expected_key, location) do
    if record.key == expected_key do
      case resolve_tainted_record(record) do
        {:ok, tainted_value, status} ->
          {:ok, tainted_value, status, record, location}

        _ ->
          critical_error(:invalid_record)
      end
    else
      critical_error(:invalid_record)
    end
  end

  defp legacy_record_owned_by_namespace?(%Record{id: id, key: key}, namespace, bare_key) do
    composite = composite_key(namespace, bare_key)
    key == bare_key and id in [composite, "memory:#{composite}"]
  end

  defp build_cas_record(_namespace, _key, composite_key, :not_found, data, metadata) do
    replacement =
      Record.new(composite_key, data, id: "memory:#{composite_key}", metadata: metadata)

    {:ok, :not_found, replacement}
  end

  defp build_cas_record(
         _namespace,
         _key,
         composite_key,
         %Record{key: composite_key} = expected,
         data,
         metadata
       ) do
    if current_namespaced_record?(expected, composite_key) do
      replacement = Record.update(expected, data, metadata: metadata)
      {:ok, {:value, expected}, replacement}
    else
      critical_error(:invalid_record)
    end
  end

  defp build_cas_record(namespace, key, composite_key, %Record{} = expected, data, metadata) do
    if legacy_record_owned_by_namespace?(expected, namespace, key) do
      replacement =
        Record.new(composite_key, data, id: "memory:#{composite_key}", metadata: metadata)

      {:ok, :not_found, replacement}
    else
      critical_error(:invalid_record)
    end
  end

  defp build_cas_record(_namespace, _key, _composite_key, _expected, _data, _metadata),
    do: critical_error(:invalid_record)

  defp classify_authoritative_bare(namespace, key) do
    case Persistence.buffered_store_authoritative_get(@store_name, key) do
      {:ok, %Record{} = record} ->
        if legacy_record_owned_by_namespace?(record, namespace, key),
          do: {:ok, {:owned, record}},
          else: {:ok, :not_owned}

      {:ok, _other} ->
        {:ok, :not_owned}

      {:error, :not_found} ->
        {:ok, :absent}

      {:error, _reason} ->
        critical_error(:durable_unavailable)
    end
  end

  defp cleanup_owned_legacy_bare(_namespace, _key, 0),
    do: {:error, :legacy_cleanup_failed}

  defp cleanup_owned_legacy_bare(namespace, key, attempts) do
    case classify_authoritative_bare(namespace, key) do
      {:ok, {:owned, record}} ->
        case acknowledged_compare_and_delete(key, record) do
          :ok ->
            :ok

          {:error, {:memory_store, :critical, :conflict}} ->
            cleanup_owned_legacy_bare(namespace, key, attempts - 1)

          {:error, _reason} ->
            {:error, :legacy_cleanup_failed}
        end

      {:ok, classification} when classification in [:absent, :not_owned] ->
        :ok

      {:error, _reason} ->
        {:error, :legacy_cleanup_failed}
    end
  end

  defp observe_legacy_cleanup(namespace, key) do
    try do
      case cleanup_owned_legacy_bare(namespace, key, @legacy_cleanup_attempts) do
        :ok -> :ok
        _failure -> log_deferred_legacy_cleanup()
      end
    rescue
      _ -> log_deferred_legacy_cleanup()
    catch
      _, _ -> log_deferred_legacy_cleanup()
    end

    :ok
  end

  defp log_deferred_legacy_cleanup do
    try do
      Logger.warning("MemoryStore deferred legacy cleanup after committed CAS")
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp cleanup_owned_legacy_bare_compat(_namespace, _key, 0), do: :ok

  defp cleanup_owned_legacy_bare_compat(namespace, key, attempts) do
    case classify_authoritative_bare(namespace, key) do
      {:ok, {:owned, record}} ->
        case acknowledged_compare_and_delete(key, record) do
          :ok ->
            :ok

          {:error, {:memory_store, :critical, :conflict}} ->
            cleanup_owned_legacy_bare_compat(namespace, key, attempts - 1)

          {:error, _reason} ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp delete_tainted_authoritative(_namespace, _key, 0), do: critical_error(:conflict)

  defp delete_tainted_authoritative(namespace, key, attempts) do
    case load_tainted_authoritative_with_status(namespace, key) do
      {:ok, _value, _status, record, :legacy_bare} ->
        case acknowledged_compare_and_delete(key, record) do
          :ok ->
            :ok

          {:error, {:memory_store, :critical, :conflict}} ->
            delete_tainted_authoritative(namespace, key, attempts - 1)

          {:error, _reason} = error ->
            error
        end

      {:ok, _value, _status, record, :namespaced} ->
        with :ok <- cleanup_owned_legacy_bare_before_delete(namespace, key),
             :ok <- acknowledged_compare_and_delete(composite_key(namespace, key), record) do
          :ok
        else
          {:error, {:memory_store, :critical, :conflict}} ->
            delete_tainted_authoritative(namespace, key, attempts - 1)

          {:error, _reason} = error ->
            error
        end

      {:error, :not_found} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp cleanup_owned_legacy_bare_before_delete(namespace, key) do
    case classify_authoritative_bare(namespace, key) do
      {:ok, {:owned, record}} -> acknowledged_compare_and_delete(key, record)
      {:ok, classification} when classification in [:absent, :not_owned] -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp acknowledged_compare_and_delete(key, expected) do
    case Persistence.buffered_store_acknowledged_compare_and_delete(@store_name, key, expected) do
      :ok -> :ok
      {:error, :conflict} -> critical_error(:conflict)
      {:error, :key_mismatch} -> critical_error(:invalid_record)
      {:error, _reason} -> critical_error(:durable_unavailable)
      _ -> critical_error(:durable_unavailable)
    end
  end

  defp composite_key(namespace, key), do: "#{namespace}:#{key}"

  defp critical_error(reason), do: {:error, {:memory_store, :critical, reason}}

  defp build_taint_metadata(data, opts) do
    case Keyword.get(opts, :taint) do
      nil ->
        {:ok, %{}}

      taint ->
        case Arbor.Signals.Taint.bind_durable_provenance(data, taint) do
          {:ok, envelope} when is_map(envelope) ->
            {:ok, %{"taint" => envelope}}

          {:error, reason} when is_atom(reason) ->
            {:error, {:memory_store, :invalid_durable_provenance, reason}}

          _ ->
            {:error, {:memory_store, :invalid_durable_provenance, :invalid_envelope}}
        end
    end
  rescue
    _ -> {:error, {:memory_store, :invalid_durable_provenance, :invalid_envelope}}
  catch
    _, _ -> {:error, {:memory_store, :invalid_durable_provenance, :invalid_envelope}}
  end

  defp tainted_entries(entries) do
    Enum.map(entries, fn {key, %Record{} = record} ->
      {:ok, tainted_value, status} = resolve_tainted_record(record)
      {key, tainted_value, status}
    end)
  end

  defp resolve_tainted_record(%Record{data: data, metadata: metadata}) do
    persisted = persisted_taint(metadata)

    {:ok, taint, status} =
      Arbor.Signals.Taint.resolve_durable_provenance(persisted, data)

    {:ok, Arbor.Contracts.Security.TaintedValue.wrap(data, taint), status}
  end

  defp load_record_with_metadata(composite_key, bare_key) do
    case BufferedStore.get(composite_key, name: @store_name) do
      {:ok, %Record{} = record} ->
        {:ok, record}

      {:error, :not_found} ->
        # Fallback: try bare key
        case BufferedStore.get(bare_key, name: @store_name) do
          {:ok, %Record{} = record} ->
            {:ok, record}

          _ ->
            {:error, :not_found}
        end

      {:error, _} = error ->
        error
    end
  end

  defp persisted_taint(metadata) when is_map(metadata) do
    atom_taint? = Map.has_key?(metadata, :taint)
    string_taint? = Map.has_key?(metadata, "taint")

    cond do
      atom_taint? ->
        :malformed

      legacy_taint_metadata?(metadata) ->
        :malformed

      string_taint? ->
        if legacy_taint_map?(Map.get(metadata, "taint")),
          do: :malformed,
          else: Map.get(metadata, "taint")

      true ->
        :missing
    end
  end

  defp persisted_taint(_metadata), do: :malformed

  defp legacy_taint_map?(value) when is_map(value) do
    Enum.any?(@legacy_taint_keys ++ @legacy_taint_atom_keys, &Map.has_key?(value, &1))
  end

  defp legacy_taint_map?(_value), do: false

  defp legacy_taint_metadata?(metadata) do
    Enum.any?(@legacy_taint_keys ++ @legacy_taint_atom_keys, &Map.has_key?(metadata, &1))
  end

  defp maybe_add_taint_to_embedding(metadata, content, opts) do
    case Keyword.get(opts, :taint) do
      nil ->
        {:ok, metadata}

      taint ->
        case Arbor.Signals.Taint.bind_durable_provenance(content, taint) do
          {:ok, envelope} ->
            {:ok, Map.put(metadata, "taint", envelope)}

          {:error, reason} when is_atom(reason) ->
            {:error, {:memory_store, :invalid_durable_provenance, reason}}

          _ ->
            {:error, {:memory_store, :invalid_durable_provenance, :invalid_envelope}}
        end
    end
  rescue
    _ -> {:error, {:memory_store, :invalid_durable_provenance, :invalid_envelope}}
  catch
    _, _ -> {:error, {:memory_store, :invalid_durable_provenance, :invalid_envelope}}
  end

  defp normalize_embedding_type(nil), do: {:ok, nil}
  defp normalize_embedding_type(type) when is_binary(type), do: {:ok, type}
  defp normalize_embedding_type(type) when is_atom(type), do: {:ok, Atom.to_string(type)}
  defp normalize_embedding_type(type) when is_integer(type), do: {:ok, Integer.to_string(type)}
  defp normalize_embedding_type(type) when is_float(type), do: {:ok, Float.to_string(type)}

  defp normalize_embedding_type(_type),
    do: {:error, {:memory_store, :invalid_request, :invalid_type}}

  defp keyword_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp keyword_options?(_opts), do: false
end
