defmodule Arbor.Memory.Retrieval do
  @moduledoc """
  Unified retrieval API for the memory system.

  Retrieval provides a high-level interface for indexing and recalling memories.
  It delegates to the Index backend (Phase 1) and provides formatting utilities
  for LLM context injection.

  ## Key Functions

  - `index/4` - Index content for later retrieval
  - `recall/3` - Semantic similarity search
  - `let_me_recall/3` - Human-readable formatted retrieval for LLM context

  ## Examples

      # Index some content
      {:ok, id} = Retrieval.index("agent_001", "Important fact", %{type: :fact})

      # Recall similar content
      {:ok, results} = Retrieval.recall("agent_001", "fact query")

      # Get formatted text for LLM injection
      {:ok, text} = Retrieval.let_me_recall("agent_001", "fact query")
      #=> {:ok, "I recall the following relevant memories:\\n- Important fact (similarity: 0.95)"}
  """

  alias Arbor.Memory
  alias Arbor.Memory.TokenBudget

  @type recall_opts :: [
          limit: pos_integer(),
          threshold: float(),
          type: atom(),
          types: [atom()]
        ]

  @type index_opts :: [
          type: atom(),
          source: String.t(),
          embedding: [float()]
        ]

  @default_limit 10
  @default_threshold 0.3

  # ============================================================================
  # Indexing
  # ============================================================================

  @doc """
  Index content for semantic retrieval.

  Delegates to `Arbor.Memory.index/4`.

  ## Options

  - `:type` - Category type for the entry (atom)
  - `:source` - Source of the content
  - `:embedding` - Pre-computed embedding (skips embedding call)

  ## Examples

      {:ok, id} = Retrieval.index("agent_001", "Hello world", %{type: :greeting})
  """
  @spec index(String.t(), String.t(), map(), index_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def index(agent_id, content, metadata \\ %{}, opts \\ []) do
    Memory.index(agent_id, content, metadata, opts)
  end

  @doc """
  Index multiple items in a batch.

  Each item should be a tuple of `{content, metadata}`.

  ## Examples

      items = [
        {"Fact one", %{type: :fact}},
        {"Fact two", %{type: :fact}}
      ]
      {:ok, ids} = Retrieval.batch_index("agent_001", items)
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

  Delegates to `Arbor.Memory.recall/3`.

  ## Options

  - `:limit` - Max results to return (default: 10)
  - `:threshold` - Minimum similarity threshold (default: 0.3)
  - `:type` - Filter by entry type
  - `:types` - Filter by multiple types

  ## Examples

      {:ok, results} = Retrieval.recall("agent_001", "greeting")
      {:ok, facts} = Retrieval.recall("agent_001", "query", type: :fact, limit: 5)
  """
  @spec recall(String.t(), String.t(), recall_opts()) ::
          {:ok, [map()]} | {:error, term()}
  def recall(agent_id, query, opts \\ []) do
    Memory.recall(agent_id, query, opts)
  end

  @doc """
  Semantic recall with human-readable formatting for LLM context injection.

  Returns a formatted text block suitable for including in a system prompt
  or conversation context. The format is designed to be natural for an LLM
  to read and reference.

  ## Options

  Same as `recall/3`, plus:
  - `:max_tokens` - Maximum tokens for the output (default: 500)
  - `:include_similarity` - Include similarity scores (default: true)
  - `:preamble` - Custom preamble text (default: "I recall the following relevant memories:")

  ## Examples

      {:ok, text} = Retrieval.let_me_recall("agent_001", "elixir patterns")
      #=> {:ok, "I recall the following relevant memories:\\n\\n- GenServer patterns... (0.92)"}

      {:ok, text} = Retrieval.let_me_recall("agent_001", "query", max_tokens: 200)
  """
  @spec let_me_recall(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def let_me_recall(agent_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    max_tokens = Keyword.get(opts, :max_tokens, 500)
    include_similarity = Keyword.get(opts, :include_similarity, true)
    preamble = Keyword.get(opts, :preamble, "I recall the following relevant memories:")

    recall_opts =
      opts
      |> Keyword.take([:type, :types])
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

  @doc """
  Check if the index has any content for an agent.
  """
  @spec has_memories?(String.t()) :: boolean()
  def has_memories?(agent_id) do
    case Memory.index_stats(agent_id) do
      {:ok, stats} -> stats.entry_count > 0
      {:error, _} -> false
    end
  end

  @doc """
  Get memory statistics for an agent.
  """
  @spec stats(String.t()) :: {:ok, map()} | {:error, term()}
  def stats(agent_id) do
    Memory.index_stats(agent_id)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

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

  defp format_result(result, false) do
    "- #{result.content}"
  end

  defp join_within_budget(items, max_tokens) do
    items
    |> Enum.reduce_while({"", 0}, fn item, {acc, tokens} ->
      item_tokens = TokenBudget.estimate_tokens(item)
      # +1 for newline
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
