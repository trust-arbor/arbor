defmodule Arbor.Memory.DurableStore do
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
  """
  @spec persist(String.t(), String.t(), map()) :: :ok
  def persist(namespace, key, data) when is_binary(namespace) and is_binary(key) do
    if available?() do
      composite_key = "#{namespace}:#{key}"
      record = Record.new(key, data, id: composite_key)
      BufferedStore.put(composite_key, record, name: @store_name)
    end

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "DurableStore.persist failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
      )

      :ok
  end

  @doc """
  Persist a record asynchronously.

  Spawns a Task to write. Failures are logged but don't affect the caller.
  """
  @spec persist_async(String.t(), String.t(), map()) :: :ok
  def persist_async(namespace, key, data) do
    Task.start(fn -> persist(namespace, key, data) end)
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
        {:ok, %Record{data: data}} -> {:ok, data}
        {:error, :not_found} -> {:error, :not_found}
        {:error, _} = error -> error
      end
    else
      {:error, :not_found}
    end
  catch
    kind, reason ->
      Logger.warning(
        "DurableStore.load failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
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

      case BufferedStore.list(name: @store_name) do
        {:ok, keys} ->
          records =
            keys
            |> Enum.filter(&String.starts_with?(&1, prefix))
            |> Enum.reduce([], fn composite_key, acc ->
              case BufferedStore.get(composite_key, name: @store_name) do
                {:ok, %Record{key: k, data: data}} -> [{k, data} | acc]
                _ -> acc
              end
            end)

          {:ok, Enum.reverse(records)}

        {:error, _} ->
          {:ok, []}
      end
    else
      {:ok, []}
    end
  catch
    kind, reason ->
      Logger.warning("DurableStore.load_all failed for #{namespace}: #{inspect({kind, reason})}")
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

      case BufferedStore.list(name: @store_name) do
        {:ok, keys} ->
          records =
            keys
            |> Enum.filter(&String.starts_with?(&1, full_prefix))
            |> Enum.reduce([], fn composite_key, acc ->
              case BufferedStore.get(composite_key, name: @store_name) do
                {:ok, %Record{key: k, data: data}} -> [{k, data} | acc]
                _ -> acc
              end
            end)

          {:ok, Enum.reverse(records)}

        {:error, _} ->
          {:ok, []}
      end
    else
      {:ok, []}
    end
  catch
    kind, reason ->
      Logger.warning(
        "DurableStore.load_by_prefix failed for #{namespace}/#{prefix}: #{inspect({kind, reason})}"
      )

      {:ok, []}
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
        "DurableStore.delete failed for #{namespace}/#{key}: #{inspect({kind, reason})}"
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
              metadata = %{
                type: type && to_string(type),
                source: namespace
              }

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

  defp do_semantic_search(query_text, agent_id, namespace, opts) do
    case Arbor.AI.embed(query_text) do
      {:ok, %{embedding: embedding}} ->
        search_opts = [
          limit: Keyword.get(opts, :limit, 10),
          threshold: Keyword.get(opts, :threshold, 0.3),
          type_filter: namespace
        ]

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
end
