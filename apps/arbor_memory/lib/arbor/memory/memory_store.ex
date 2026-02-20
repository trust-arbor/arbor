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

  @doc """
  Persist a record to the durable store (sync).

  Returns `:ok` on success or if the store is unavailable (graceful degradation).

  ## Options

  - `:taint` - A `Arbor.Contracts.Security.Taint` struct to persist alongside
    the data. Stored in `record.metadata["taint"]` as a string-keyed map.
  """
  @spec persist(String.t(), String.t(), map(), keyword()) :: :ok
  def persist(namespace, key, data, opts \\ []) when is_binary(namespace) and is_binary(key) do
    if available?() do
      composite_key = "#{namespace}:#{key}"
      metadata = build_taint_metadata(opts)
      record = Record.new(composite_key, data, id: composite_key, metadata: metadata)
      BufferedStore.put(composite_key, record, name: @store_name)
    end

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.persist failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
      )

      :ok
  end

  @doc """
  Persist a record asynchronously.

  Spawns a Task to write. Failures are logged but don't affect the caller.
  Accepts the same options as `persist/4`.
  """
  @spec persist_async(String.t(), String.t(), map(), keyword()) :: :ok
  def persist_async(namespace, key, data, opts \\ []) do
    Task.start(fn -> persist(namespace, key, data, opts) end)
    :ok
  end

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

  @doc """
  Load a single record with taint metadata as a TaintedValue.

  Unlike `load/2`, this returns the data wrapped in a `TaintedValue` struct
  that carries the persisted taint metadata. Legacy data (without taint metadata)
  gets conservative defaults: `:trusted` level, `:internal` sensitivity,
  `:unverified` confidence.

  Returns `{:ok, TaintedValue.t()}` or `{:error, term()}`.
  """
  @spec load_tainted(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def load_tainted(namespace, key) do
    if available?() do
      composite_key = "#{namespace}:#{key}"

      case load_record_with_metadata(composite_key, key) do
        {:ok, data, metadata} ->
          taint = restore_taint(metadata)
          verify_stored_data_hash(data, metadata, namespace, key)
          tainted_value = wrap_tainted(data, taint)
          {:ok, tainted_value}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  catch
    kind, reason ->
      Logger.warning(
        "MemoryStore.load_tainted failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
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
  failures are logged at debug level and never affect the caller.

  ## Parameters

  - `namespace` - Memory store namespace (e.g., "goals", "thinking")
  - `key` - Record key (e.g., "agent_123:goal_456")
  - `content` - Text content to embed
  - `opts` - Additional metadata for the embedding
    - `:agent_id` - Agent that owns this memory
    - `:type` - Semantic type hint (e.g., :goal, :thought, :intent)
  """
  @spec embed_async(String.t(), String.t(), String.t(), keyword()) :: :ok
  def embed_async(namespace, key, content, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    type = Keyword.get(opts, :type)

    if agent_id && content && content != "" do
      Task.start(fn ->
        try do
          case Arbor.AI.embed(content) do
            {:ok, %{embedding: embedding}} ->
              metadata =
                %{
                  type: type && to_string(type),
                  source: namespace
                }
                |> maybe_add_taint_to_embedding(opts)

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
  end

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

  defp build_taint_metadata(opts) do
    case Keyword.get(opts, :taint) do
      nil ->
        %{}

      taint ->
        if taint_module_available?() do
          hash_opts = case Keyword.get(opts, :data) do
            nil -> []
            data -> [data_hash: apply(Arbor.Signals.Taint, :data_hash, [data])]
          end

          %{"taint" => apply(Arbor.Signals.Taint, :to_persistable, [taint, hash_opts])}
        else
          %{}
        end
    end
  end

  defp restore_taint(metadata) when is_map(metadata) do
    case Map.get(metadata, "taint") do
      nil ->
        # Legacy data — conservative default taint
        default_taint_struct()

      taint_map when is_map(taint_map) ->
        if taint_module_available?() do
          apply(Arbor.Signals.Taint, :from_persistable, [taint_map])
        else
          default_taint_struct()
        end
    end
  end

  defp restore_taint(_), do: default_taint_struct()

  defp default_taint_struct do
    if Code.ensure_loaded?(Arbor.Contracts.Security.Taint) do
      struct(Arbor.Contracts.Security.Taint,
        level: :trusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :unverified
      )
    else
      %{level: :trusted, sensitivity: :internal, sanitizations: 0, confidence: :unverified}
    end
  end

  defp wrap_tainted(data, taint) do
    if Code.ensure_loaded?(Arbor.Contracts.Security.TaintedValue) do
      apply(Arbor.Contracts.Security.TaintedValue, :wrap, [data, taint])
    else
      %{value: data, taint: taint}
    end
  end

  defp load_record_with_metadata(composite_key, bare_key) do
    case BufferedStore.get(composite_key, name: @store_name) do
      {:ok, %Record{data: data, metadata: metadata}} ->
        {:ok, data, metadata || %{}}

      {:error, :not_found} ->
        # Fallback: try bare key
        case BufferedStore.get(bare_key, name: @store_name) do
          {:ok, %Record{data: data, metadata: metadata}} ->
            {:ok, data, metadata || %{}}

          _ ->
            {:error, :not_found}
        end

      {:error, _} = error ->
        error
    end
  end

  defp maybe_add_taint_to_embedding(metadata, opts) do
    case Keyword.get(opts, :taint) do
      nil ->
        metadata

      taint ->
        if taint_module_available?() do
          Map.put(metadata, :taint, apply(Arbor.Signals.Taint, :to_persistable, [taint]))
        else
          metadata
        end
    end
  end

  defp verify_stored_data_hash(data, metadata, namespace, key) do
    with %{"taint" => %{"taint_data_hash" => stored_hash}} when is_binary(stored_hash) <- metadata,
         true <- taint_module_available?(),
         true <- function_exported?(Arbor.Signals.Taint, :verify_data_hash, 2),
         {:error, :hash_mismatch} <- apply(Arbor.Signals.Taint, :verify_data_hash, [data, stored_hash]) do
      Logger.warning(
        "Data hash mismatch for #{namespace}/#{key} — data may have been modified after taint classification"
      )
    else
      _ -> :ok
    end
  end

  defp taint_module_available? do
    Code.ensure_loaded?(Arbor.Signals.Taint) and
      function_exported?(Arbor.Signals.Taint, :to_persistable, 2)
  end
end
