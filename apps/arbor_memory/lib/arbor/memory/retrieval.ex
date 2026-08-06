defmodule Arbor.Memory.Retrieval do
  @moduledoc """
  Unified retrieval API for the memory system.

  Retrieval provides a high-level interface for indexing and recalling memories.
  It delegates to the Index backend and provides formatting utilities for LLM
  context injection.

  ## Key Functions

  - `index/4` - Index content for later retrieval
  - `recall/3` - Semantic similarity search
  - `let_me_recall/3` - Human-readable formatted retrieval for LLM context

  ## Backend Options

  The `:backend` option controls where to search:
  - `:memory` — ETS only (fast, in-memory)
  - `:persistent` — strict vector ANN only (persistent)
  - `:auto` — Default. Uses the configured backend mode.
  """

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorRecord}
  alias Arbor.Memory

  alias Arbor.Memory.{
    EmbeddingEvidence,
    Index.Input,
    StrictEmbeddingInput,
    StrictVectorSeam,
    TokenBudget
  }

  @type recall_opts :: [
          limit: pos_integer(),
          threshold: float(),
          type: atom(),
          types: [atom()],
          backend: :memory | :persistent | :auto
        ]

  @type index_opts :: [
          type: atom(),
          source: String.t(),
          embedding: [float()]
        ]

  @default_limit 10
  @default_threshold 0.3
  @default_max_tokens 500
  @index_namespace "memory_index"
  @presentation_keys [:include_similarity, :preamble, :max_tokens]

  # ============================================================================
  # Indexing
  # ============================================================================

  @doc """
  Index content for semantic retrieval.

  Delegates to `Arbor.Memory.index/4`.
  """
  @spec index(String.t(), String.t(), map(), index_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def index(agent_id, content, metadata \\ %{}, opts \\ []) do
    Memory.index(agent_id, content, metadata, opts)
  end

  @doc """
  Index multiple items in a batch.
  """
  @spec batch_index(String.t(), [{String.t(), map()}], index_opts()) ::
          {:ok, [String.t()]} | {:error, term()}
  def batch_index(agent_id, items, opts \\ []) do
    Memory.batch_index(agent_id, items, opts)
  end

  # ============================================================================
  # Recall
  # ============================================================================

  @doc """
  Recall content similar to a query.

  Delegates to `Arbor.Memory.recall/3` by default, or queries the strict
  ANN surface when `:backend` is `:persistent`.
  """
  @spec recall(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def recall(agent_id, query, opts \\ []) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         backend when backend in [:memory, :persistent, :auto] <-
           Keyword.get(opts, :backend, :auto) do
      recall_opts = Keyword.drop(opts, [:backend | @presentation_keys])

      case backend do
        :persistent -> recall_from_persistent(agent_id, query, recall_opts)
        _ -> Memory.recall(agent_id, query, recall_opts)
      end
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp recall_from_persistent(agent_id, query, opts) do
    with {:ok, {query, opts}} <- Input.recall(query, opts),
         {:ok, evidence} <- compute_query_evidence(query, opts) do
      limit = Keyword.get(opts, :limit, @default_limit)
      threshold = Keyword.get(opts, :threshold, @default_threshold)

      type_filter =
        cond do
          type = Keyword.get(opts, :type) -> {:single, type}
          types = Keyword.get(opts, :types) -> {:multiple, types}
          true -> :none
        end

      strict_ann(agent_id, evidence, type_filter, threshold, limit)
    end
  end

  defp compute_query_evidence(query, opts) do
    case Keyword.get(opts, :embedding) do
      nil ->
        case Arbor.AI.embed(query) do
          {:ok, result} ->
            case EmbeddingEvidence.from_provider_result(result) do
              {:ok, evidence} -> {:ok, evidence}
              {:error, _} -> {:ok, EmbeddingEvidence.local_hash_fallback(query)}
            end

          {:error, _} ->
            {:ok, EmbeddingEvidence.local_hash_fallback(query)}
        end

      embedding when is_list(embedding) ->
        EmbeddingEvidence.from_precomputed(embedding)

      _ ->
        {:error, :invalid_embedding}
    end
  end

  defp strict_ann(agent_id, evidence, type_filter, threshold, limit) do
    descriptor = %{
      model_id: evidence.model_id,
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding()
    }

    base_opts = [
      model_id: descriptor.model_id,
      dimensions: descriptor.dimensions,
      encoding: descriptor.encoding,
      source_namespace: @index_namespace,
      threshold: threshold,
      limit: limit
    ]

    seam = StrictVectorSeam.resolve()

    case type_filter do
      :none ->
        search_validate(seam, agent_id, evidence.vector, base_opts, nil, descriptor)

      {:single, type} ->
        cat = StrictEmbeddingInput.category_for_type(type)

        search_validate(
          seam,
          agent_id,
          evidence.vector,
          Keyword.put(base_opts, :category, cat),
          cat,
          descriptor
        )

      {:multiple, types} ->
        fan_out(seam, agent_id, evidence.vector, base_opts, types, limit, descriptor)
    end
  end

  defp fan_out(seam, agent_id, vector, base_opts, types, limit, descriptor) do
    types
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, acc} ->
      cat = StrictEmbeddingInput.category_for_type(type)
      opts = Keyword.put(base_opts, :category, cat)

      case search_validate(seam, agent_id, vector, opts, cat, descriptor) do
        {:ok, results} -> {:cont, {:ok, acc ++ results}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} ->
        deduped =
          results
          |> Enum.reduce(%{}, fn r, acc ->
            case Map.fetch(acc, r.id) do
              :error ->
                Map.put(acc, r.id, r)

              {:ok, existing} ->
                if r.similarity > existing.similarity, do: Map.put(acc, r.id, r), else: acc
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

  defp search_validate(seam, agent_id, vector, opts, expected_category, descriptor) do
    case safe_vector_call(fn -> seam.search(agent_id, vector, opts) end) do
      {:ok, matches} -> validate_matches(agent_id, matches, expected_category, descriptor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_matches(agent_id, matches, expected_category, descriptor) when is_list(matches) do
    matches
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case item do
        %{match: view, similarity: sim} when is_map(view) and is_number(sim) ->
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
            view_agent_id != agent_id ->
              {:halt, {:error, :tenant_mismatch}}

            source_namespace != @index_namespace ->
              {:halt, {:error, :namespace_mismatch}}

            expected_category != nil and category != expected_category ->
              {:halt, {:error, :category_mismatch}}

            model_id != descriptor.model_id ->
              {:halt, {:error, :descriptor_mismatch}}

            dimensions != descriptor.dimensions ->
              {:halt, {:error, :descriptor_mismatch}}

            encoding != descriptor.encoding ->
              {:halt, {:error, :descriptor_mismatch}}

            tombstone != false ->
              {:halt, {:error, :malformed_persistence_result}}

            not valid_similarity?(sim) ->
              {:halt, {:error, :malformed_persistence_result}}

            not is_binary(source_key) or source_key == "" or
              not is_binary(row_id) or row_id != source_key ->
              {:halt, {:error, :malformed_persistence_result}}

            provenance_status == :invalid_durable_provenance ->
              {:halt, {:error, :invalid_durable_provenance}}

            provenance_status not in [:verified, :legacy_unlabeled] ->
              {:halt, {:error, :malformed_persistence_result}}

            not is_map(body) ->
              {:halt, {:error, :malformed_persistence_result}}

            not is_binary(Map.get(body, "content")) ->
              {:halt, {:error, :malformed_persistence_result}}

            not is_map(Map.get(body, "metadata", %{})) ->
              {:halt, {:error, :malformed_persistence_result}}

            true ->
              result = %{
                id: source_key,
                content: Map.get(body, "content", ""),
                similarity: sim,
                metadata: Map.get(body, "metadata", %{}),
                indexed_at: DateTime.utc_now()
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

  defp validate_matches(_agent_id, _matches, _cat, _descriptor),
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

  defp safe_vector_call(fun) do
    fun.()
  rescue
    _ -> {:error, :indeterminate}
  catch
    _, _ -> {:error, :indeterminate}
  end

  @doc """
  Semantic recall with human-readable formatting for LLM context injection.

  Returns a formatted text block suitable for including in a system prompt
  or conversation context. Presentation-only options are not forwarded to the
  underlying recall operation.
  """
  @spec let_me_recall(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def let_me_recall(agent_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    include_similarity = Keyword.get(opts, :include_similarity, true)
    preamble = Keyword.get(opts, :preamble, "I recall the following relevant memories:")

    recall_opts =
      opts
      |> Keyword.take([:type, :types, :backend, :embedding])
      |> Keyword.put(:limit, limit)
      |> Keyword.put(:threshold, threshold)

    case recall(agent_id, query, recall_opts) do
      {:ok, []} ->
        {:ok, ""}

      {:ok, results} ->
        text = format_results(results, preamble, include_similarity, max_tokens)
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Return true when the agent index has at least one entry."
  @spec has_memories?(String.t()) :: boolean()
  def has_memories?(agent_id) do
    case Memory.index_stats(agent_id) do
      {:ok, %{entry_count: count}} when is_integer(count) and count > 0 -> true
      _ -> false
    end
  end

  @doc "Return index statistics for an agent."
  @spec stats(String.t()) :: {:ok, map()} | {:error, term()}
  def stats(agent_id), do: Memory.index_stats(agent_id)

  defp format_results(results, preamble, include_similarity, max_tokens) do
    formatted_items =
      results
      |> Enum.map(&format_result(&1, include_similarity))
      |> join_within_budget(max_tokens - TokenBudget.estimate_tokens(preamble))

    if formatted_items == "" do
      ""
    else
      "#{preamble}\n\n#{formatted_items}"
    end
  end

  defp format_result(result, true) do
    similarity = Float.round(result.similarity, 2)
    "- #{result.content} (#{similarity})"
  end

  defp format_result(result, false), do: "- #{result.content}"

  defp join_within_budget(items, max_tokens) do
    items
    |> Enum.reduce_while({"", 0}, fn item, {acc, tokens} ->
      item_tokens = TokenBudget.estimate_tokens(item)
      new_tokens = tokens + item_tokens + 1

      if new_tokens <= max_tokens do
        new_acc = if acc == "", do: item, else: "#{acc}\n#{item}"
        {:cont, {new_acc, new_tokens}}
      else
        {:halt, {acc, tokens}}
      end
    end)
    |> elem(0)
  end
end
