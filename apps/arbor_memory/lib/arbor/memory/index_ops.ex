defmodule Arbor.Memory.IndexOps do
  @moduledoc """
  Sub-facade for index and embedding operations.

  Handles vector-based semantic search via the in-memory ETS index
  and persistent pgvector embeddings.

  This module is not intended to be called directly by external consumers.
  Use `Arbor.Memory` as the public API.
  """

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorRecord}
  alias Arbor.Contracts.Security.TaintEnvelope

  alias Arbor.Memory.{
    Embedding,
    EmbeddingEvidence,
    Index,
    IndexSupervisor,
    Signals,
    StrictEmbeddingInput,
    StrictVectorSeam
  }

  # ============================================================================
  # Index Operations
  # ============================================================================

  @doc """
  Index content for semantic retrieval.

  Stores content with its embedding in the agent's memory index.

  ## Options

  - `:type` - Category type for the entry (atom)
  - `:source` - Source of the content
  - `:embedding` - Pre-computed embedding (skips embedding call)

  ## Examples

      {:ok, entry_id} = Arbor.Memory.index("agent_001", "Hello world", %{type: :fact})
  """
  @spec index(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def index(agent_id, content, metadata \\ %{}, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        result = Index.index(pid, content, metadata, opts)

        case result do
          {:ok, entry_id} ->
            Signals.emit_indexed(agent_id, %{
              entry_id: entry_id,
              type: metadata[:type],
              source: metadata[:source]
            })

            {:ok, entry_id}

          error ->
            error
        end

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  @doc """
  Recall content similar to query.

  Performs semantic search in the agent's memory index.

  ## Options

  - `:limit` - Max results to return (default: 10)
  - `:threshold` - Minimum similarity threshold (default: 0.3)
  - `:type` - Filter by entry type
  - `:types` - Filter by multiple types

  ## Examples

      {:ok, results} = Arbor.Memory.recall("agent_001", "greeting")
      {:ok, facts} = Arbor.Memory.recall("agent_001", "query", type: :fact, limit: 5)
  """
  @spec recall(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def recall(agent_id, query, opts \\ []) do
    with {:ok, pid} <- IndexSupervisor.get_index(agent_id),
         {:ok, results} <- Index.recall(pid, query, opts) do
      emit_recall_signal(agent_id, query, results)
      {:ok, results}
    else
      {:error, :not_found} -> {:error, :index_not_initialized}
      error -> error
    end
  end

  defp emit_recall_signal(agent_id, query, results) do
    top_similarity = if results != [], do: hd(results).similarity, else: nil

    Signals.emit_recalled(agent_id, query, length(results), top_similarity: top_similarity)
  end

  @doc """
  Index multiple items in a batch.

  ## Examples

      items = [{"Fact one", %{type: :fact}}, {"Fact two", %{type: :fact}}]
      {:ok, ids} = Arbor.Memory.batch_index("agent_001", items)
  """
  @spec batch_index(String.t(), [{String.t(), map()}], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def batch_index(agent_id, items, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        Index.batch_index(pid, items, opts)

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  @doc """
  Get statistics for an agent's index.
  """
  @spec index_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def index_stats(agent_id) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} -> {:ok, Index.stats(pid)}
      {:error, :not_found} -> {:error, :index_not_initialized}
    end
  end

  # ============================================================================
  # Persistent Embeddings (Phase 6) — strict owner path
  # ============================================================================

  @doc """
  Store an embedding in the persistent vector store via the strict seam.

  Bypasses the in-memory index. Owner generates a fresh source_key; caller
  metadata `:id` is never authority. Precomputed vectors bind
  `legacy:unspecified` model evidence and missing-label taint.
  """
  @spec store_embedding(String.t(), String.t(), [float()], map()) ::
          {:ok, String.t()} | {:error, term()}
  def store_embedding(agent_id, content, embedding, metadata \\ %{}) do
    with {:ok, evidence} <- EmbeddingEvidence.from_precomputed(embedding),
         entry_id when is_binary(entry_id) <- generate_owner_entry_id(),
         closed <-
           StrictEmbeddingInput.index_insert(%{
             agent_id: agent_id,
             entry_id: entry_id,
             content: content,
             vector: evidence.vector,
             metadata: sanitize_store_metadata(metadata),
             model_evidence: evidence.model_evidence,
             taint: TaintEnvelope.missing_fallback()
           }),
         seam <- StrictVectorSeam.resolve(),
         {:ok, operation, _view} <- safe_vector_call(fn -> seam.encode_operation(closed) end),
         {:ok, receipt} <- execute_or_reconcile(seam, agent_id, operation),
         :ok <-
           validate_receipt_identity(
             receipt,
             agent_id,
             StrictEmbeddingInput.index_namespace(),
             entry_id,
             entry_id
           ) do
      {:ok, entry_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :operation_failed}
    end
  end

  defp execute_or_reconcile(seam, agent_id, operation),
    do: execute_or_reconcile(seam, agent_id, operation, 1)

  defp execute_or_reconcile(seam, agent_id, operation, retries_left) do
    case safe_execute(seam, agent_id, operation) do
      {:ok, receipt} ->
        {:ok, receipt}

      {:error, :indeterminate} ->
        reconcile_or_retry(seam, agent_id, operation, retries_left)

      {:error, reason} ->
        {:error, reason}

      _malformed ->
        {:error, :malformed_persistence_result}
    end
  end

  defp reconcile_or_retry(seam, agent_id, operation, retries_left) do
    case safe_reconcile(seam, agent_id, operation) do
      {:ok, :absent} when retries_left > 0 ->
        execute_or_reconcile(seam, agent_id, operation, retries_left - 1)

      {:ok, :absent} ->
        {:error, :persistence_indeterminate}

      {:ok, receipt} ->
        {:ok, receipt}

      {:error, reason} ->
        {:error, reason}

      _malformed ->
        {:error, :persistence_indeterminate}
    end
  end

  defp safe_execute(seam, agent_id, operation) do
    seam.execute(agent_id, operation, [])
  rescue
    _ -> {:error, :indeterminate}
  catch
    _, _ -> {:error, :indeterminate}
  end

  defp safe_reconcile(seam, agent_id, operation) do
    seam.reconcile(agent_id, operation, [])
  rescue
    _ -> {:error, :indeterminate}
  catch
    _, _ -> {:error, :indeterminate}
  end

  @doc """
  Search the persistent vector store via the strict ANN seam.

  Precomputed query vectors use `legacy:unspecified` model descriptor.
  """
  @spec search_embeddings(String.t(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search_embeddings(agent_id, query_embedding, opts \\ []) do
    with {:ok, evidence} <- EmbeddingEvidence.from_precomputed(query_embedding),
         {:ok, search_opts} <- build_search_opts(evidence, opts),
         seam <- StrictVectorSeam.resolve(),
         {:ok, matches} <-
           safe_vector_call(fn -> seam.search(agent_id, evidence.vector, search_opts) end),
         {:ok, results} <- validate_index_search_matches(agent_id, matches, search_opts) do
      {:ok, results}
    end
  end

  @doc """
  Get statistics for an agent's persistent embeddings.

  Compatibility path: still uses legacy stats aggregate when available.
  """
  @spec embedding_stats(String.t()) :: map()
  def embedding_stats(agent_id) do
    Embedding.stats(agent_id)
  end

  @doc """
  Warm the in-memory index cache from persistent storage.

  Loads recent entries from pgvector into the ETS index.
  Only works when the index is running in `:dual` or `:pgvector` mode.

  ## Options

  - `:limit` -- Maximum entries to load (default: 1000)

  ## Examples

      :ok = Arbor.Memory.warm_index_cache("agent_001")
      :ok = Arbor.Memory.warm_index_cache("agent_001", limit: 500)
  """
  @spec warm_index_cache(String.t(), keyword()) :: :ok | {:error, term()}
  def warm_index_cache(agent_id, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        Index.warm_cache(pid, opts)

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  defp generate_owner_entry_id do
    "mem_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp sanitize_store_metadata(metadata) when is_map(metadata) do
    # Metadata is body data only. Authority-named keys are preserved but never
    # consulted when constructing source_key, id, model evidence, or taint.
    metadata
  end

  defp sanitize_store_metadata(_), do: %{}

  defp build_search_opts(evidence, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         limit when is_integer(limit) and limit > 0 <- Keyword.get(opts, :limit, 10),
         threshold when is_number(threshold) and threshold >= -1.0 and threshold <= 1.0 <-
           Keyword.get(opts, :threshold, 0.3) do
      base = [
        model_id: evidence.model_id,
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        source_namespace: StrictEmbeddingInput.index_namespace(),
        threshold: threshold,
        limit: min(limit, 1000)
      ]

      search_opts =
        case Keyword.get(opts, :type_filter) do
          nil -> base
          type -> Keyword.put(base, :category, StrictEmbeddingInput.category_for_type(type))
        end

      {:ok, search_opts}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp build_search_opts(_evidence, _opts), do: {:error, :invalid_request}

  defp validate_index_search_matches(agent_id, matches, search_opts) when is_list(matches) do
    expected_category = Keyword.get(search_opts, :category)
    expected_model = Keyword.fetch!(search_opts, :model_id)
    expected_dimensions = Keyword.fetch!(search_opts, :dimensions)
    expected_encoding = Keyword.fetch!(search_opts, :encoding)
    ns = StrictEmbeddingInput.index_namespace()

    matches
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case item do
        %{match: view, similarity: sim} when is_map(view) and is_number(sim) ->
          view_agent_id = field(view, :agent_id)
          source_namespace = field(view, :source_namespace)
          source_key = field(view, :source_key)
          row_id = field(view, :id)
          category = field(view, :category)
          model_id = field(view, :model_id)
          dimensions = field(view, :dimensions)
          encoding = field(view, :encoding)
          tombstone = field(view, :tombstone)
          body = field(view, :body)
          provenance_status = field(view, :provenance_status)

          cond do
            view_agent_id != agent_id ->
              {:halt, {:error, :tenant_mismatch}}

            source_namespace != ns ->
              {:halt, {:error, :namespace_mismatch}}

            expected_category != nil and category != expected_category ->
              {:halt, {:error, :category_mismatch}}

            model_id != expected_model or dimensions != expected_dimensions or
                encoding != expected_encoding ->
              {:halt, {:error, :descriptor_mismatch}}

            tombstone != false ->
              {:halt, {:error, :malformed_persistence_result}}

            not valid_similarity?(sim) ->
              {:halt, {:error, :malformed_persistence_result}}

            not is_binary(source_key) or source_key == "" or
              not is_binary(row_id) or row_id != source_key ->
              {:halt, {:error, :malformed_persistence_result}}

            not is_map(body) or not is_binary(Map.get(body, "content")) or
                not is_map(Map.get(body, "metadata", %{})) ->
              {:halt, {:error, :malformed_persistence_result}}

            provenance_status == :invalid_durable_provenance ->
              {:halt, {:error, :invalid_durable_provenance}}

            provenance_status not in [:verified, :legacy_unlabeled] ->
              {:halt, {:error, :malformed_persistence_result}}

            true ->
              result = %{
                id: source_key,
                content: Map.get(body, "content", ""),
                similarity: sim,
                metadata: Map.get(body, "metadata", %{}),
                model_id: model_id,
                provenance_status: provenance_status
              }

              {:cont, {:ok, [result | acc]}}
          end

        _ ->
          {:halt, {:error, :malformed_persistence_result}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp validate_index_search_matches(_agent_id, _matches, _opts),
    do: {:error, :malformed_persistence_result}

  defp validate_receipt_identity(receipt, agent_id, namespace, source_key, row_id) do
    with record when is_map(record) <- field(receipt, :record),
         ^agent_id <- field(record, :agent_id),
         ^namespace <- field(record, :source_namespace),
         ^source_key <- field(record, :source_key),
         ^row_id <- field(record, :id) do
      :ok
    else
      _ -> {:error, :malformed_persistence_result}
    end
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp valid_similarity?(similarity) do
    match?({:ok, _normalized}, VectorMatch.normalize_similarity(similarity))
  end

  defp safe_vector_call(fun) do
    fun.()
  rescue
    _ -> {:error, :indeterminate}
  catch
    _, _ -> {:error, :indeterminate}
  end
end
