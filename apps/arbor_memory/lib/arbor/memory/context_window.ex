defmodule Arbor.Memory.ContextWindow do
  @moduledoc """
  Sliding window context management with progressive summarization support.

  ContextWindow manages a bounded conversation history that can be progressively
  summarized as it grows. Supports two modes:

  ## Legacy Mode (default)

  Simple bounded entry list with external summarization hooks.
  Messages are added as `{type, content, timestamp}` tuples via `add_entry/3`.

  ## Multi-Layer Mode (`multi_layer: true`)

  Progressive summarization with 4-layer context architecture:

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                         Context Window                          │
  │                                                                 │
  │  [DISTANT SUMMARY] Highly compressed. Weeks/months ago.        │
  │  ────────────────────────────────────────────────────────────  │
  │  [RECENT SUMMARY]  Moderately compressed. Days ago.            │
  │  ════════════════════════════════════════════════════════════  │
  │  [CLARITY BOUNDARY] "Memory is hazier before this point"       │
  │  ════════════════════════════════════════════════════════════  │
  │  [FULL DETAIL]     Complete messages. Recent hours.            │
  │  ────────────────────────────────────────────────────────────  │
  │  [RETRIEVED]       Context surfaced from search (optional).    │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Token Budget (Multi-Layer)

  For a ~200k context window:
  - Full detail: ~50% - complete recent messages
  - Recent summary: ~25% - moderately compressed recent
  - Distant summary: ~15% - highly compressed old context
  - Retrieved: ~10% - context surfaced from memory search

  ## Presets

  - `:balanced` - 10k tokens, legacy mode (default)
  - `:conservative` - 5k tokens, legacy mode
  - `:expansive` - 50k tokens, legacy mode
  - `:claude_full` - 180k tokens, multi-layer with summarization
  - `:claude_conservative` - 100k tokens, multi-layer with summarization
  - `:medium_context` - 28k tokens, multi-layer with summarization
  - `:small_context` - 6k tokens, multi-layer with adjusted ratios
  - `:large_context` - 500k tokens, multi-layer with adjusted ratios

  ## Examples

      # Legacy mode (backward compatible)
      window = ContextWindow.new("agent_001", max_tokens: 10_000)
      window = ContextWindow.add_entry(window, :message, "Hello!")

      # Multi-layer mode with preset
      window = ContextWindow.new("agent_001", preset: :claude_full)
      window = ContextWindow.add_message(window, %{role: :user, content: "Hello!"})

      # Check compression
      if ContextWindow.needs_compression?(window) do
        {:ok, window} = ContextWindow.compress_if_needed(window)
      end
  """

  require Logger

  alias Arbor.Memory.ContextWindow.Compression
  alias Arbor.Memory.ContextWindow.Formatting
  alias Arbor.Memory.ContextWindow.Serialization
  alias Arbor.Memory.TokenBudget

  @type entry_type :: :message | :summary
  @type entry :: {entry_type(), String.t(), DateTime.t()}

  @type t :: %__MODULE__{
          agent_id: String.t(),
          # Legacy mode fields
          entries: [entry()],
          max_tokens: pos_integer(),
          summary_threshold: float(),
          model_id: String.t() | nil,
          # Multi-layer mode flag
          multi_layer: boolean(),
          # Summarization layers
          distant_summary: String.t() | nil,
          recent_summary: String.t() | nil,
          # Full detail (complete recent messages as rich maps)
          full_detail: [map()],
          # Clarity boundary - where full detail begins
          clarity_boundary: DateTime.t() | nil,
          # Retrieved context (from memory search)
          retrieved_context: [map()],
          # Token tracking per section
          distant_tokens: non_neg_integer(),
          recent_tokens: non_neg_integer(),
          detail_tokens: non_neg_integer(),
          retrieved_tokens: non_neg_integer(),
          # Budget ratios
          ratios: map(),
          # Summarization config
          summarization_enabled: boolean(),
          summarization_algorithm: atom(),
          # Fact extraction config
          fact_extraction_enabled: boolean(),
          # Summarization model config
          summarization_model: String.t() | nil,
          summarization_provider: atom() | nil,
          fact_extraction_model: String.t() | nil,
          fact_extraction_provider: atom() | nil,
          min_fact_confidence: float(),
          # Compression meta
          last_compression_at: DateTime.t() | nil,
          compression_count: non_neg_integer(),
          version: pos_integer()
        }

  defstruct [
    :agent_id,
    # Legacy mode fields
    entries: [],
    max_tokens: 10_000,
    summary_threshold: 0.7,
    model_id: nil,
    # Multi-layer mode
    multi_layer: false,
    distant_summary: nil,
    recent_summary: nil,
    full_detail: [],
    clarity_boundary: nil,
    retrieved_context: [],
    # Token tracking
    distant_tokens: 0,
    recent_tokens: 0,
    detail_tokens: 0,
    retrieved_tokens: 0,
    # Budget ratios
    ratios: %{full_detail: 0.50, recent_summary: 0.25, distant_summary: 0.15, retrieved: 0.10},
    # Summarization config
    summarization_enabled: false,
    summarization_algorithm: :prose,
    # Fact extraction config
    fact_extraction_enabled: false,
    # Summarization model config
    summarization_model: nil,
    summarization_provider: nil,
    fact_extraction_model: nil,
    fact_extraction_provider: nil,
    min_fact_confidence: 0.7,
    # Compression meta
    last_compression_at: nil,
    compression_count: 0,
    version: 1
  ]

  @default_max_tokens 10_000
  @default_summary_threshold 0.7

  # Default token budget ratios for multi-layer mode
  @default_ratios %{
    full_detail: 0.50,
    recent_summary: 0.25,
    distant_summary: 0.15,
    retrieved: 0.10
  }

  # Common presets for different models/use cases
  @presets %{
    # Legacy mode presets (backward compatible)
    balanced: %{max_tokens: 10_000, multi_layer: false},
    conservative: %{max_tokens: 5_000, multi_layer: false},
    expansive: %{max_tokens: 50_000, multi_layer: false},

    # Multi-layer presets
    claude_full: %{
      max_tokens: 180_000,
      multi_layer: true,
      summarization_enabled: true,
      ratios: @default_ratios
    },
    claude_conservative: %{
      max_tokens: 100_000,
      multi_layer: true,
      summarization_enabled: true,
      ratios: @default_ratios
    },
    medium_context: %{
      max_tokens: 28_000,
      multi_layer: true,
      summarization_enabled: true,
      ratios: @default_ratios
    },
    small_context: %{
      max_tokens: 6_000,
      multi_layer: true,
      summarization_enabled: true,
      ratios: %{
        full_detail: 0.60,
        recent_summary: 0.25,
        distant_summary: 0.10,
        retrieved: 0.05
      }
    },
    large_context: %{
      max_tokens: 500_000,
      multi_layer: true,
      summarization_enabled: true,
      ratios: %{
        full_detail: 0.60,
        recent_summary: 0.20,
        distant_summary: 0.15,
        retrieved: 0.05
      }
    }
  }

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new context window for an agent.

  ## Options

  - `:max_tokens` - Maximum tokens in the window (default: 10,000)
  - `:summary_threshold` - Fraction of max_tokens at which to trigger summarization (default: 0.7)
  - `:model_id` - Model ID for token estimation (optional)
  - `:preset` - Use a named preset (see module doc for available presets)
  - `:multi_layer` - Enable multi-layer progressive summarization (default: false)
  - `:ratios` - Token budget ratios for multi-layer sections
  - `:summarization_enabled` - Enable LLM-based summarization (default: false)
  - `:summarization_algorithm` - `:prose` or `:incremental_bullets` (default: `:prose`)
  - `:fact_extraction_enabled` - Enable fact extraction during compression (default: false)
  - `:summarization_model` - Specific model for summarization LLM calls (optional)
  - `:summarization_provider` - Provider atom for summarization (e.g., `:anthropic`, `:openai`)
  - `:fact_extraction_model` - Specific model for fact extraction (optional)
  - `:fact_extraction_provider` - Provider atom for fact extraction (optional)
  - `:min_fact_confidence` - Minimum confidence threshold for extracted facts (default: 0.7)

  ## Examples

      window = ContextWindow.new("agent_001")
      window = ContextWindow.new("agent_001", max_tokens: 20_000, summary_threshold: 0.8)
      window = ContextWindow.new("agent_001", preset: :claude_full)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    # Resolve preset first, then allow opts to override
    {preset_opts, remaining_opts} = resolve_preset(opts)
    merged_opts = Keyword.merge(preset_opts, remaining_opts)

    max_tokens = resolve_max_tokens(merged_opts)
    multi_layer = Keyword.get(merged_opts, :multi_layer, false)

    base = %__MODULE__{
      agent_id: agent_id,
      max_tokens: max_tokens,
      summary_threshold: Keyword.get(merged_opts, :summary_threshold, @default_summary_threshold),
      model_id: Keyword.get(merged_opts, :model_id),
      multi_layer: multi_layer
    }

    if multi_layer do
      %{
        base
        | ratios: Keyword.get(merged_opts, :ratios, @default_ratios),
          summarization_enabled: Keyword.get(merged_opts, :summarization_enabled, false),
          summarization_algorithm:
            Keyword.get(merged_opts, :summarization_algorithm, :prose),
          summarization_model: Keyword.get(merged_opts, :summarization_model),
          summarization_provider: Keyword.get(merged_opts, :summarization_provider),
          fact_extraction_enabled:
            Keyword.get(merged_opts, :fact_extraction_enabled, false),
          fact_extraction_model: Keyword.get(merged_opts, :fact_extraction_model),
          fact_extraction_provider: Keyword.get(merged_opts, :fact_extraction_provider),
          min_fact_confidence: Keyword.get(merged_opts, :min_fact_confidence, 0.7),
          clarity_boundary: DateTime.utc_now(),
          distant_summary: "",
          recent_summary: ""
      }
    else
      base
    end
  end

  @doc """
  Get available preset names.
  """
  @spec presets() :: [atom()]
  def presets, do: Map.keys(@presets)

  @doc """
  Get configuration for a specific preset.
  """
  @spec preset(atom()) :: map() | nil
  def preset(name), do: Map.get(@presets, name)

  # ============================================================================
  # Entry Management (Legacy Mode)
  # ============================================================================

  @doc """
  Add an entry to the context window.

  In legacy mode, entries are appended (newest last) for chronological ordering.
  In multi-layer mode, `:message` entries are routed to `add_message/2`.
  """
  @spec add_entry(t(), entry_type(), String.t()) :: t()
  def add_entry(%{multi_layer: true} = window, :message, content) do
    add_message(window, %{role: :user, content: content})
  end

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
  def clear(%{multi_layer: true} = window) do
    %{window | full_detail: [], retrieved_context: [], detail_tokens: 0, retrieved_tokens: 0}
  end

  def clear(window) do
    %{window | entries: []}
  end

  @doc """
  Get the number of entries in the window.
  """
  @spec entry_count(t()) :: non_neg_integer()
  def entry_count(%{multi_layer: true} = window) do
    length(window.full_detail)
  end

  def entry_count(window) do
    length(window.entries)
  end

  # ============================================================================
  # Multi-Layer Message Management
  # ============================================================================

  @doc """
  Add a message to the full detail section (multi-layer mode).

  Messages are stored as rich maps with `:role`, `:content`, `:speaker`,
  `:timestamp`, and `:id` fields. Messages are prepended (newest first).

  In legacy mode, falls back to `add_entry/3`.
  """
  @spec add_message(t(), map()) :: t()
  def add_message(%{multi_layer: false} = window, message) do
    content = message[:content] || message["content"] || ""
    add_entry(window, :message, content)
  end

  def add_message(%{multi_layer: true} = window, message) do
    timestamped =
      message
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put_new(:id, generate_id("msg"))

    tokens = Compression.estimate_tokens(timestamped)

    updated = %{
      window
      | full_detail: [timestamped | window.full_detail],
        detail_tokens: window.detail_tokens + tokens
    }

    # If LLM-based summarization is enabled, defer compression to heartbeat
    # to avoid blocking the GenServer during add_message.
    # Phase 1 (no LLM) compression is fast, can run inline.
    if window.summarization_enabled do
      updated
    else
      if needs_compression?(updated) do
        compress(updated)
      else
        updated
      end
    end
  end

  @doc """
  Add a user message to the context.

  ## Options

  - `:speaker` - Name of the person/entity sending the message (default: "Human")
  """
  @spec add_user_message(t(), String.t(), keyword()) :: t()
  def add_user_message(window, content, opts \\ []) do
    speaker = Keyword.get(opts, :speaker, "Human")

    add_message(window, %{
      role: :user,
      content: content,
      speaker: speaker
    })
  end

  @doc """
  Add an assistant response to the context.
  """
  @spec add_assistant_response(t(), String.t()) :: t()
  def add_assistant_response(window, response) do
    add_message(window, %{
      role: :assistant,
      content: response
    })
  end

  @doc """
  Add tool/action results to the context.

  Tool results are formatted as user messages with a special format.

  ## Parameters

  - `results` - List of action results, each with :action, :outcome, and :result
  """
  @spec add_tool_results(t(), list()) :: t()
  def add_tool_results(window, results) when is_list(results) do
    if Enum.empty?(results) do
      window
    else
      formatted = Enum.map_join(results, "\n\n", &Formatting.format_action_result/1)

      add_message(window, %{
        role: :user,
        content: "[Tool Results]\n\n#{formatted}",
        speaker: "System",
        is_tool_result: true
      })
    end
  end

  @doc """
  Add retrieved context from memory search.

  Performs semantic deduplication via embeddings when available,
  falling back to exact-match dedup when embedding service is unavailable.
  """
  @spec add_retrieved(t(), map()) :: t()
  def add_retrieved(%{multi_layer: true} = window, context) do
    content = context[:content] || context["content"] || ""

    if Compression.semantically_duplicate?(window.retrieved_context, content) do
      Logger.debug("ContextWindow dedup: skipping duplicate retrieved context",
        content_preview: String.slice(content, 0, 50)
      )

      window
    else
      timestamped =
        context
        |> Map.put_new(:retrieved_at, DateTime.utc_now())
        |> Compression.maybe_add_embedding(content)

      tokens = Compression.estimate_tokens(timestamped)

      %{
        window
        | retrieved_context: [timestamped | window.retrieved_context],
          retrieved_tokens: window.retrieved_tokens + tokens
      }
    end
  end

  def add_retrieved(window, _context), do: window

  @doc """
  Clear retrieved context (after it's been used).
  """
  @spec clear_retrieved(t()) :: t()
  def clear_retrieved(%{multi_layer: true} = window) do
    %{window | retrieved_context: [], retrieved_tokens: 0}
  end

  def clear_retrieved(window), do: window

  # ============================================================================
  # Token Management
  # ============================================================================

  @doc """
  Get the current token usage of the window.

  In multi-layer mode, returns the sum of all section token counts.
  In legacy mode, estimates from prompt text.
  """
  @spec token_usage(t()) :: non_neg_integer()
  def token_usage(%{multi_layer: true} = window) do
    total_tokens(window)
  end

  def token_usage(window) do
    text = to_prompt_text(window)
    TokenBudget.estimate_tokens(text)
  end

  @doc """
  Get the total token count across all multi-layer sections.
  """
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(%{multi_layer: true} = window) do
    window.distant_tokens + window.recent_tokens +
      window.detail_tokens + window.retrieved_tokens
  end

  def total_tokens(window), do: token_usage(window)

  @doc """
  Check if the window should be summarized.

  In multi-layer mode, delegates to `needs_compression?/1`.
  In legacy mode, checks token usage against threshold.
  """
  @spec should_summarize?(t()) :: boolean()
  def should_summarize?(%{multi_layer: true} = window) do
    needs_compression?(window)
  end

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

  @doc """
  Get token budget info for monitoring (multi-layer mode).
  """
  @spec budget_info(t()) :: map()
  def budget_info(%{multi_layer: true} = window) do
    total = total_tokens(window)

    %{
      total: total,
      max: window.max_tokens,
      utilization: if(window.max_tokens > 0, do: total / window.max_tokens, else: 0.0),
      by_section: %{
        distant: %{used: window.distant_tokens, budget: Compression.distant_summary_budget(window)},
        recent: %{used: window.recent_tokens, budget: Compression.recent_summary_budget(window)},
        detail: %{used: window.detail_tokens, budget: Compression.full_detail_budget(window)},
        retrieved: %{used: window.retrieved_tokens, budget: Compression.retrieved_budget(window)}
      }
    }
  end

  def budget_info(window) do
    usage = token_usage(window)

    %{
      total: usage,
      max: window.max_tokens,
      utilization: if(window.max_tokens > 0, do: usage / window.max_tokens, else: 0.0)
    }
  end

  # ============================================================================
  # Summarization (Legacy Mode)
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
    |> Enum.map_join("\n\n", fn {_type, content, _ts} -> content end)
  end

  # ============================================================================
  # Compression Pipeline (Multi-Layer Mode)
  # ============================================================================

  @doc """
  Check if compression is needed based on token budgets.

  In multi-layer mode, checks if detail_tokens exceeds the full_detail budget.
  In legacy mode, delegates to `should_summarize?/1`.
  """
  @spec needs_compression?(t()) :: boolean()
  def needs_compression?(%{multi_layer: true} = window) do
    budget = Compression.full_detail_budget(window)
    window.detail_tokens > budget
  end

  def needs_compression?(window), do: should_summarize?(window)

  @doc """
  Compress the context window if needed.

  Returns `{:ok, window}` if compression was performed or wasn't needed,
  or `{:error, reason}` if compression failed.
  """
  @spec compress_if_needed(t()) :: {:ok, t()} | {:error, term()}
  def compress_if_needed(%{multi_layer: true} = window) do
    if needs_compression?(window) do
      try do
        compressed = compress(window)
        {:ok, compressed}
      rescue
        e -> {:error, {:compression_failed, e}}
      end
    else
      {:ok, window}
    end
  end

  def compress_if_needed(window), do: {:ok, window}

  @doc """
  Compress the oldest full_detail content into summaries.

  Uses LLM summarization when `summarization_enabled` is true,
  with fallback to simple text concatenation.
  """
  @spec compress(t()) :: t()
  def compress(%{multi_layer: true, full_detail: []} = window), do: window

  def compress(%{multi_layer: true} = window) do
    detail_budget = Compression.full_detail_budget(window)
    recent_budget = Compression.recent_summary_budget(window)

    # Calculate how much to compress
    excess = window.detail_tokens - detail_budget

    # Find messages to demote (oldest first - full_detail is newest-first)
    {to_demote, to_keep} = Compression.split_for_compression(window.full_detail, excess)

    # Run summarization and fact extraction in parallel
    {demoted_text, _demoted_tokens, extracted_facts} =
      Compression.run_compression_pipeline(window, to_demote)

    # Update recent summary
    new_recent = Compression.merge_into_recent_summary(window.recent_summary || "", demoted_text)
    new_recent_tokens = Compression.estimate_tokens_text(new_recent)
    kept_tokens = window.detail_tokens - Compression.tokens_for_messages(to_demote)

    # Check if recent summary needs to flow into distant
    {final_recent, final_distant, recent_toks, distant_toks} =
      if new_recent_tokens > recent_budget do
        Compression.flow_to_distant(window, new_recent, window.distant_summary || "", new_recent_tokens)
      else
        {new_recent, window.distant_summary || "", new_recent_tokens, window.distant_tokens}
      end

    # Update clarity boundary to oldest kept message
    new_boundary =
      case List.last(to_keep) do
        %{timestamp: ts} -> ts
        _ -> window.clarity_boundary
      end

    original_tokens = Compression.tokens_for_messages(to_demote)

    # Emit demotion signal
    Compression.emit_demotion_signal(window, to_demote, Compression.estimate_tokens_text(demoted_text))

    # Emit fact extraction signal if facts were found
    if extracted_facts != [] do
      Compression.emit_fact_extraction_signal(window, extracted_facts)
    end

    # Log compression ratio
    compressed_tokens = Compression.estimate_tokens_text(demoted_text)

    compression_ratio =
      if original_tokens > 0, do: Float.round(compressed_tokens / original_tokens * 100, 1), else: 0

    Logger.debug(
      "Context compression: #{original_tokens} -> #{compressed_tokens} tokens (#{compression_ratio}%)",
      agent_id: window.agent_id,
      compression_count: window.compression_count + 1,
      facts_extracted: length(extracted_facts)
    )

    %{
      window
      | full_detail: to_keep,
        detail_tokens: max(0, kept_tokens),
        recent_summary: final_recent,
        recent_tokens: recent_toks,
        distant_summary: final_distant,
        distant_tokens: distant_toks,
        clarity_boundary: new_boundary,
        last_compression_at: DateTime.utc_now(),
        compression_count: window.compression_count + 1
    }
  end

  def compress(window), do: window

  # ============================================================================
  # Rendering / Context Building (delegated to Formatting)
  # ============================================================================

  @doc """
  Render the context window as text for LLM consumption.

  In multi-layer mode, joins all context sections with headers.
  In legacy mode, renders entries chronologically.
  """
  @spec to_prompt_text(t()) :: String.t()
  def to_prompt_text(window), do: Formatting.to_prompt_text(window)

  @doc """
  Build the full context for an LLM prompt (multi-layer mode).

  Returns a list of context sections in order:
  distant_summary -> recent_summary -> clarity_boundary -> retrieved -> full_detail
  """
  @spec build_context(t()) :: [map()]
  def build_context(window), do: Formatting.build_context(window)

  @doc """
  Build the system prompt portion (distant + recent summaries).

  Useful for placing compressed history in the system message.
  """
  @spec to_system_prompt(t()) :: String.t()
  def to_system_prompt(window), do: Formatting.to_system_prompt(window)

  @doc """
  Build the user context portion (retrieved + full detail).

  Useful for placing recent conversation in user messages.
  """
  @spec to_user_context(t()) :: String.t()
  def to_user_context(window), do: Formatting.to_user_context(window)

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
  def stats(%{multi_layer: true} = window) do
    total = total_tokens(window)

    %{
      agent_id: window.agent_id,
      multi_layer: true,
      entry_count: length(window.full_detail),
      retrieved_count: length(window.retrieved_context),
      token_usage: total,
      max_tokens: window.max_tokens,
      utilization: if(window.max_tokens > 0, do: total / window.max_tokens, else: 0.0),
      needs_compression: needs_compression?(window),
      compression_count: window.compression_count,
      last_compression_at: window.last_compression_at,
      model_id: window.model_id,
      budget: budget_info(window)
    }
  end

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
  # Serialization (delegated to Serialization)
  # ============================================================================

  @doc """
  Serialize the context window to a JSON-safe map.
  """
  @spec serialize(t()) :: map()
  def serialize(window), do: Serialization.serialize(window)

  @doc """
  Deserialize a JSON-safe map back to a ContextWindow.
  """
  @spec deserialize(map()) :: t()
  def deserialize(data), do: Serialization.deserialize(data)

  # ============================================================================
  # Private Helpers - Construction
  # ============================================================================

  defp resolve_preset(opts) do
    case Keyword.pop(opts, :preset) do
      {nil, remaining} ->
        {[], remaining}

      {preset_name, remaining} ->
        case Map.get(@presets, preset_name) do
          nil ->
            Logger.warning("Unknown preset #{inspect(preset_name)}, using defaults")
            {[], remaining}

          preset_config ->
            preset_kw = Map.to_list(preset_config)
            {preset_kw, remaining}
        end
    end
  end

  defp resolve_max_tokens(opts) do
    model_id = Keyword.get(opts, :model_id)

    case Keyword.get(opts, :max_tokens) do
      # Budget spec tuples - resolve against model context or default
      {:percentage, _pct} = spec ->
        resolve_budget_spec(spec, model_id)

      {:min_max, _min, _max, _pct} = spec ->
        resolve_budget_spec(spec, model_id)

      {:fixed, count} ->
        count

      # Direct integer value
      n when is_integer(n) and n > 0 ->
        n

      # No max_tokens specified - infer from model
      nil ->
        resolve_max_tokens_from_model(model_id, opts)

      _ ->
        @default_max_tokens
    end
  end

  defp resolve_max_tokens_from_model(nil, _opts), do: @default_max_tokens

  defp resolve_max_tokens_from_model(model_id, opts) do
    budget = Keyword.get(opts, :budget, {:percentage, 0.10})
    TokenBudget.resolve_for_model(budget, model_id)
  end

  defp resolve_budget_spec(spec, nil) do
    TokenBudget.resolve(spec, TokenBudget.default_context_size())
  end

  defp resolve_budget_spec(spec, model_id) do
    TokenBudget.resolve_for_model(spec, model_id)
  end

  # ============================================================================
  # Private Helpers - ID Generation
  # ============================================================================

  defp generate_id(prefix) do
    "#{prefix}_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end
end
