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
  Delete a record.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(namespace, key) do
    if available?() do
      composite_key = "#{namespace}:#{key}"
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
