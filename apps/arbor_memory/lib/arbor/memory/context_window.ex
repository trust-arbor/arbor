defmodule Arbor.Memory.ContextWindow do
  @moduledoc """
  Sliding window context management with progressive summarization support.

  ContextWindow manages a bounded conversation history that can be progressively
  summarized as it grows. This implements the core progressive summarization
  capability: old entries get summarized and compressed, recent entries stay
  full-fidelity.

  ## How It Works

  1. Messages are added as full-fidelity entries
  2. When the window approaches its token limit (summary_threshold), summarization is triggered
  3. Old entries are replaced with a summary, freeing space for new content
  4. The agent "intentionally loses details based on recency, but keeps the main thread"

  ## Entry Types

  - `:message` - Full message content
  - `:summary` - Compressed representation of older messages

  ## Examples

      # Create a context window
      window = ContextWindow.new("agent_001", max_tokens: 10_000)

      # Add messages
      window = ContextWindow.add_entry(window, :message, "User: Hello!")
      window = ContextWindow.add_entry(window, :message, "Assistant: Hi there!")

      # Check if summarization is needed
      if ContextWindow.should_summarize?(window) do
        summary = "User greeted assistant who responded warmly."
        window = ContextWindow.apply_summary(window, summary)
      end

      # Render for LLM
      text = ContextWindow.to_prompt_text(window)
  """

  alias Arbor.Memory.TokenBudget

  @type entry_type :: :message | :summary
  @type entry :: {entry_type(), String.t(), DateTime.t()}

  @type t :: %__MODULE__{
          agent_id: String.t(),
          entries: [entry()],
          max_tokens: pos_integer(),
          summary_threshold: float(),
          model_id: String.t() | nil
        }

  defstruct [
    :agent_id,
    entries: [],
    max_tokens: 10_000,
    summary_threshold: 0.7,
    model_id: nil
  ]

  @default_max_tokens 10_000
  @default_summary_threshold 0.7

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new context window for an agent.

  ## Options

  - `:max_tokens` - Maximum tokens in the window (default: 10,000)
  - `:summary_threshold` - Fraction of max_tokens at which to trigger summarization (default: 0.7)
  - `:model_id` - Model ID for token estimation (optional)

  ## Examples

      window = ContextWindow.new("agent_001")
      window = ContextWindow.new("agent_001", max_tokens: 20_000, summary_threshold: 0.8)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    max_tokens =
      case Keyword.get(opts, :model_id) do
        nil ->
          Keyword.get(opts, :max_tokens, @default_max_tokens)

        model_id ->
          budget = Keyword.get(opts, :budget, {:percentage, 0.10})
          TokenBudget.resolve_for_model(budget, model_id)
      end

    %__MODULE__{
      agent_id: agent_id,
      max_tokens: max_tokens,
      summary_threshold: Keyword.get(opts, :summary_threshold, @default_summary_threshold),
      model_id: Keyword.get(opts, :model_id)
    }
  end

  # ============================================================================
  # Entry Management
  # ============================================================================

  @doc """
  Add an entry to the context window.

  Entries are appended (newest last) for chronological ordering.
  """
  @spec add_entry(t(), entry_type(), String.t()) :: t()
  def add_entry(window, type, content) when type in [:message, :summary] do
    entry = {type, content, DateTime.utc_now()}
    %{window | entries: window.entries ++ [entry]}
  end

  @doc """
  Add multiple entries at once.
  """
  @spec add_entries(t(), [{entry_type(), String.t()}]) :: t()
  def add_entries(window, entries) do
    now = DateTime.utc_now()

    new_entries =
      Enum.map(entries, fn {type, content} ->
        {type, content, now}
      end)

    %{window | entries: window.entries ++ new_entries}
  end

  @doc """
  Clear all entries from the window.
  """
  @spec clear(t()) :: t()
  def clear(window) do
    %{window | entries: []}
  end

  @doc """
  Get the number of entries in the window.
  """
  @spec entry_count(t()) :: non_neg_integer()
  def entry_count(window) do
    length(window.entries)
  end

  # ============================================================================
  # Token Management
  # ============================================================================

  @doc """
  Get the current token usage of the window.
  """
  @spec token_usage(t()) :: non_neg_integer()
  def token_usage(window) do
    text = to_prompt_text(window)
    TokenBudget.estimate_tokens(text)
  end

  @doc """
  Check if the window should be summarized.

  Returns true when token usage exceeds threshold * max_tokens.
  """
  @spec should_summarize?(t()) :: boolean()
  def should_summarize?(window) do
    threshold_tokens = trunc(window.max_tokens * window.summary_threshold)
    token_usage(window) >= threshold_tokens
  end

  @doc """
  Get remaining token capacity.
  """
  @spec remaining_capacity(t()) :: non_neg_integer()
  def remaining_capacity(window) do
    max(0, window.max_tokens - token_usage(window))
  end

  # ============================================================================
  # Summarization
  # ============================================================================

  @doc """
  Apply a summary to compress old entries.

  This replaces entries older than the most recent N entries with a summary.
  The summary becomes the first entry, followed by the kept entries.

  ## Options

  - `:keep_recent` - Number of recent entries to keep unchanged (default: 3)

  ## Examples

      window = ContextWindow.apply_summary(window, "Summary of earlier conversation...")
      window = ContextWindow.apply_summary(window, "Summary...", keep_recent: 5)
  """
  @spec apply_summary(t(), String.t(), keyword()) :: t()
  def apply_summary(window, summary, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, 3)

    if length(window.entries) <= keep_recent do
      # Not enough entries to summarize
      window
    else
      # Keep the most recent entries
      kept_entries = Enum.take(window.entries, -keep_recent)

      # Create summary entry
      summary_entry = {:summary, summary, DateTime.utc_now()}

      %{window | entries: [summary_entry | kept_entries]}
    end
  end

  @doc """
  Get entries that would be summarized (older entries that would be replaced).

  ## Options

  - `:keep_recent` - Number of recent entries to keep (default: 3)
  """
  @spec entries_to_summarize(t(), keyword()) :: [entry()]
  def entries_to_summarize(window, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, 3)
    entries_count = length(window.entries)

    if entries_count <= keep_recent do
      []
    else
      Enum.take(window.entries, entries_count - keep_recent)
    end
  end

  @doc """
  Get the text content of entries that would be summarized.

  This is useful for passing to a summarization model.
  """
  @spec content_to_summarize(t(), keyword()) :: String.t()
  def content_to_summarize(window, opts \\ []) do
    window
    |> entries_to_summarize(opts)
    |> Enum.map(fn {_type, content, _ts} -> content end)
    |> Enum.join("\n\n")
  end

  # ============================================================================
  # Rendering
  # ============================================================================

  @doc """
  Render the context window as text for LLM consumption.

  Entries are rendered chronologically with type prefixes for summaries.
  """
  @spec to_prompt_text(t()) :: String.t()
  def to_prompt_text(window) do
    window.entries
    |> Enum.map(&format_entry/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Get entries as a list of maps (for structured contexts).
  """
  @spec to_entries_list(t()) :: [map()]
  def to_entries_list(window) do
    Enum.map(window.entries, fn {type, content, timestamp} ->
      %{
        type: type,
        content: content,
        timestamp: DateTime.to_iso8601(timestamp)
      }
    end)
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  @doc """
  Get statistics about the context window.
  """
  @spec stats(t()) :: map()
  def stats(window) do
    current_usage = token_usage(window)
    threshold_tokens = trunc(window.max_tokens * window.summary_threshold)

    message_count =
      Enum.count(window.entries, fn {type, _, _} -> type == :message end)

    summary_count =
      Enum.count(window.entries, fn {type, _, _} -> type == :summary end)

    %{
      agent_id: window.agent_id,
      entry_count: length(window.entries),
      message_count: message_count,
      summary_count: summary_count,
      token_usage: current_usage,
      max_tokens: window.max_tokens,
      threshold_tokens: threshold_tokens,
      utilization: if(window.max_tokens > 0, do: current_usage / window.max_tokens, else: 0.0),
      should_summarize: should_summarize?(window),
      model_id: window.model_id
    }
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  @doc """
  Serialize the context window to a JSON-safe map.
  """
  @spec serialize(t()) :: map()
  def serialize(window) do
    %{
      "agent_id" => window.agent_id,
      "entries" =>
        Enum.map(window.entries, fn {type, content, timestamp} ->
          %{
            "type" => to_string(type),
            "content" => content,
            "timestamp" => DateTime.to_iso8601(timestamp)
          }
        end),
      "max_tokens" => window.max_tokens,
      "summary_threshold" => window.summary_threshold,
      "model_id" => window.model_id
    }
  end

  @doc """
  Deserialize a JSON-safe map back to a ContextWindow.
  """
  @spec deserialize(map()) :: t()
  def deserialize(data) when is_map(data) do
    get_field = fn key ->
      Map.get(data, key) || Map.get(data, to_string(key))
    end

    entries =
      (get_field.(:entries) || [])
      |> Enum.map(fn entry ->
        type = parse_entry_type(entry["type"] || Map.get(entry, :type))
        content = entry["content"] || Map.get(entry, :content)

        timestamp =
          case entry["timestamp"] || Map.get(entry, :timestamp) do
            nil -> DateTime.utc_now()
            ts when is_binary(ts) -> DateTime.from_iso8601(ts) |> elem(1)
            %DateTime{} = dt -> dt
          end

        {type, content, timestamp}
      end)

    %__MODULE__{
      agent_id: get_field.(:agent_id),
      entries: entries,
      max_tokens: get_field.(:max_tokens) || @default_max_tokens,
      summary_threshold: get_field.(:summary_threshold) || @default_summary_threshold,
      model_id: get_field.(:model_id)
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp format_entry({:summary, content, _timestamp}) do
    "[Previous Context Summary]\n#{content}"
  end

  defp format_entry({:message, content, _timestamp}) do
    content
  end

  defp parse_entry_type("message"), do: :message
  defp parse_entry_type("summary"), do: :summary
  defp parse_entry_type(:message), do: :message
  defp parse_entry_type(:summary), do: :summary
  defp parse_entry_type(_), do: :message
end
