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

  alias Arbor.Memory.FactExtractor
  alias Arbor.Memory.Signals
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

  # Threshold for semantic dedup of retrieved context (cosine similarity)
  @retrieved_dedup_threshold 0.85

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

    tokens = estimate_tokens(timestamped)

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
      formatted = Enum.map_join(results, "\n\n", &format_action_result/1)

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

    if semantically_duplicate?(window.retrieved_context, content) do
      Logger.debug("ContextWindow dedup: skipping duplicate retrieved context",
        content_preview: String.slice(content, 0, 50)
      )

      window
    else
      timestamped =
        context
        |> Map.put_new(:retrieved_at, DateTime.utc_now())
        |> maybe_add_embedding(content)

      tokens = estimate_tokens(timestamped)

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
        distant: %{used: window.distant_tokens, budget: distant_summary_budget(window)},
        recent: %{used: window.recent_tokens, budget: recent_summary_budget(window)},
        detail: %{used: window.detail_tokens, budget: full_detail_budget(window)},
        retrieved: %{used: window.retrieved_tokens, budget: retrieved_budget(window)}
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
    budget = full_detail_budget(window)
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
    detail_budget = full_detail_budget(window)
    recent_budget = recent_summary_budget(window)

    # Calculate how much to compress
    excess = window.detail_tokens - detail_budget

    # Find messages to demote (oldest first - full_detail is newest-first)
    {to_demote, to_keep} = split_for_compression(window.full_detail, excess)

    # Run summarization and fact extraction in parallel
    {demoted_text, _demoted_tokens, extracted_facts} =
      run_compression_pipeline(window, to_demote)

    # Update recent summary
    new_recent = merge_into_recent_summary(window.recent_summary || "", demoted_text)
    new_recent_tokens = estimate_tokens_text(new_recent)
    kept_tokens = window.detail_tokens - tokens_for_messages(to_demote)

    # Check if recent summary needs to flow into distant
    {final_recent, final_distant, recent_toks, distant_toks} =
      if new_recent_tokens > recent_budget do
        flow_to_distant(window, new_recent, window.distant_summary || "", new_recent_tokens)
      else
        {new_recent, window.distant_summary || "", new_recent_tokens, window.distant_tokens}
      end

    # Update clarity boundary to oldest kept message
    new_boundary =
      case List.last(to_keep) do
        %{timestamp: ts} -> ts
        _ -> window.clarity_boundary
      end

    original_tokens = tokens_for_messages(to_demote)

    # Emit demotion signal
    emit_demotion_signal(window, to_demote, estimate_tokens_text(demoted_text))

    # Emit fact extraction signal if facts were found
    if extracted_facts != [] do
      emit_fact_extraction_signal(window, extracted_facts)
    end

    # Log compression ratio
    compressed_tokens = estimate_tokens_text(demoted_text)

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
  # Rendering / Context Building
  # ============================================================================

  @doc """
  Render the context window as text for LLM consumption.

  In multi-layer mode, joins all context sections with headers.
  In legacy mode, renders entries chronologically.
  """
  @spec to_prompt_text(t()) :: String.t()
  def to_prompt_text(%{multi_layer: true} = window) do
    window
    |> build_context()
    |> Enum.map_join("\n\n", & &1.content)
  end

  def to_prompt_text(window) do
    Enum.map_join(window.entries, "\n\n", &format_entry/1)
  end

  @doc """
  Build the full context for an LLM prompt (multi-layer mode).

  Returns a list of context sections in order:
  distant_summary -> recent_summary -> clarity_boundary -> retrieved -> full_detail
  """
  @spec build_context(t()) :: [map()]
  def build_context(%{multi_layer: true} = window) do
    sections = []

    # Distant summary
    sections =
      if (window.distant_summary || "") != "" do
        [
          %{
            type: :distant_summary,
            content: "[DISTANT CONTEXT - weeks/months ago]\n#{window.distant_summary}"
          }
          | sections
        ]
      else
        sections
      end

    # Recent summary
    sections =
      if (window.recent_summary || "") != "" do
        time_label = format_summary_time(window.clarity_boundary)

        [
          %{
            type: :recent_summary,
            content: "[RECENT CONTEXT - #{time_label}]\n#{window.recent_summary}"
          }
          | sections
        ]
      else
        sections
      end

    # Clarity boundary marker
    sections = [
      %{type: :clarity_boundary, content: format_clarity_boundary(window.clarity_boundary)}
      | sections
    ]

    # Retrieved context
    sections =
      if window.retrieved_context != [] do
        retrieved_text = format_retrieved_context(window.retrieved_context)
        [%{type: :retrieved, content: retrieved_text} | sections]
      else
        sections
      end

    # Full detail (most recent)
    sections =
      if window.full_detail != [] do
        detail_text = format_full_detail(window.full_detail)
        [%{type: :full_detail, content: detail_text} | sections]
      else
        sections
      end

    Enum.reverse(sections)
  end

  def build_context(window) do
    [%{type: :entries, content: to_prompt_text(window)}]
  end

  @doc """
  Build the system prompt portion (distant + recent summaries).

  Useful for placing compressed history in the system message.
  """
  @spec to_system_prompt(t()) :: String.t()
  def to_system_prompt(%{multi_layer: true} = window) do
    sections = []

    sections =
      if (window.distant_summary || "") != "" do
        ["[DISTANT CONTEXT - weeks/months ago]\n#{window.distant_summary}" | sections]
      else
        sections
      end

    sections =
      if (window.recent_summary || "") != "" do
        time_label = format_summary_time(window.clarity_boundary)
        ["[RECENT CONTEXT - #{time_label}]\n#{window.recent_summary}" | sections]
      else
        sections
      end

    sections
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  def to_system_prompt(_window), do: ""

  @doc """
  Build the user context portion (retrieved + full detail).

  Useful for placing recent conversation in user messages.
  """
  @spec to_user_context(t()) :: String.t()
  def to_user_context(%{multi_layer: true} = window) do
    sections = []

    boundary_text = format_clarity_boundary(window.clarity_boundary)
    sections = [boundary_text | sections]

    sections =
      if window.retrieved_context != [] do
        [format_retrieved_context(window.retrieved_context) | sections]
      else
        sections
      end

    sections =
      if window.full_detail != [] do
        ["[CONVERSATION]\n#{format_full_detail(window.full_detail)}" | sections]
      else
        sections
      end

    sections
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  def to_user_context(_window), do: ""

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
  # Serialization
  # ============================================================================

  @doc """
  Serialize the context window to a JSON-safe map.
  """
  @spec serialize(t()) :: map()
  def serialize(%{multi_layer: true} = window) do
    %{
      "agent_id" => window.agent_id,
      "multi_layer" => true,
      "version" => window.version,
      "max_tokens" => window.max_tokens,
      "model_id" => window.model_id,
      "distant_summary" => window.distant_summary,
      "recent_summary" => window.recent_summary,
      "full_detail" => window.full_detail,
      "clarity_boundary" => serialize_datetime(window.clarity_boundary),
      "retrieved_context" => window.retrieved_context,
      "distant_tokens" => window.distant_tokens,
      "recent_tokens" => window.recent_tokens,
      "detail_tokens" => window.detail_tokens,
      "retrieved_tokens" => window.retrieved_tokens,
      "ratios" => window.ratios,
      "summarization_enabled" => window.summarization_enabled,
      "summarization_algorithm" => to_string(window.summarization_algorithm),
      "summarization_model" => window.summarization_model,
      "summarization_provider" =>
        if(window.summarization_provider, do: to_string(window.summarization_provider)),
      "fact_extraction_enabled" => window.fact_extraction_enabled,
      "fact_extraction_model" => window.fact_extraction_model,
      "fact_extraction_provider" =>
        if(window.fact_extraction_provider, do: to_string(window.fact_extraction_provider)),
      "min_fact_confidence" => window.min_fact_confidence,
      "last_compression_at" => serialize_datetime(window.last_compression_at),
      "compression_count" => window.compression_count
    }
  end

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
    if flex_field(data, :multi_layer) do
      deserialize_multi_layer(data)
    else
      deserialize_legacy(data)
    end
  end

  defp deserialize_multi_layer(data) do
    base = deserialize_multi_layer_base(data)
    tokens = deserialize_multi_layer_tokens(data)
    summarization = deserialize_multi_layer_summarization(data)
    fact_extraction = deserialize_multi_layer_fact_extraction(data)

    struct!(__MODULE__, Map.merge(base, tokens) |> Map.merge(summarization) |> Map.merge(fact_extraction))
  end

  defp deserialize_multi_layer_base(data) do
    %{
      agent_id: flex_field(data, :agent_id),
      multi_layer: true,
      version: flex_field(data, :version) || 1,
      max_tokens: flex_field(data, :max_tokens) || @default_max_tokens,
      model_id: flex_field(data, :model_id),
      distant_summary: flex_field(data, :distant_summary) || "",
      recent_summary: flex_field(data, :recent_summary) || "",
      full_detail: flex_field(data, :full_detail) || [],
      clarity_boundary: parse_datetime(flex_field(data, :clarity_boundary)),
      retrieved_context: flex_field(data, :retrieved_context) || [],
      ratios: flex_field(data, :ratios) || @default_ratios,
      last_compression_at: parse_datetime(flex_field(data, :last_compression_at)),
      compression_count: flex_field(data, :compression_count) || 0
    }
  end

  defp deserialize_multi_layer_tokens(data) do
    %{
      distant_tokens: flex_field(data, :distant_tokens) || 0,
      recent_tokens: flex_field(data, :recent_tokens) || 0,
      detail_tokens: flex_field(data, :detail_tokens) || 0,
      retrieved_tokens: flex_field(data, :retrieved_tokens) || 0
    }
  end

  defp deserialize_multi_layer_summarization(data) do
    %{
      summarization_enabled: flex_field(data, :summarization_enabled) || false,
      summarization_algorithm:
        parse_atom(flex_field(data, :summarization_algorithm), :prose),
      summarization_model: flex_field(data, :summarization_model),
      summarization_provider:
        parse_atom(flex_field(data, :summarization_provider), nil)
    }
  end

  defp deserialize_multi_layer_fact_extraction(data) do
    %{
      fact_extraction_enabled: flex_field(data, :fact_extraction_enabled) || false,
      fact_extraction_model: flex_field(data, :fact_extraction_model),
      fact_extraction_provider:
        parse_atom(flex_field(data, :fact_extraction_provider), nil),
      min_fact_confidence: flex_field(data, :min_fact_confidence) || 0.7
    }
  end

  defp deserialize_legacy(data) do
    entries =
      (flex_field(data, :entries) || [])
      |> Enum.map(&deserialize_entry/1)

    %__MODULE__{
      agent_id: flex_field(data, :agent_id),
      entries: entries,
      max_tokens: flex_field(data, :max_tokens) || @default_max_tokens,
      summary_threshold: flex_field(data, :summary_threshold) || @default_summary_threshold,
      model_id: flex_field(data, :model_id)
    }
  end

  defp flex_field(data, key) do
    Map.get(data, key) || Map.get(data, to_string(key))
  end

  defp deserialize_entry(entry) do
    type = parse_entry_type(entry["type"] || Map.get(entry, :type))
    content = entry["content"] || Map.get(entry, :content)
    timestamp = parse_timestamp(entry["timestamp"] || Map.get(entry, :timestamp))
    {type, content, timestamp}
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(%DateTime{} = dt), do: dt
  defp parse_timestamp(ts) when is_binary(ts), do: DateTime.from_iso8601(ts) |> elem(1)

  # ============================================================================
  # Private Helpers - Legacy Entry Formatting
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

  # ============================================================================
  # Private Helpers - Multi-Layer Token Budgets
  # ============================================================================

  defp full_detail_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :full_detail, 0.50))
  end

  defp full_detail_budget(_window), do: 0

  defp recent_summary_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :recent_summary, 0.25))
  end

  defp recent_summary_budget(_window), do: 0

  defp distant_summary_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :distant_summary, 0.15))
  end

  defp distant_summary_budget(_window), do: 0

  defp retrieved_budget(%{multi_layer: true, ratios: ratios, max_tokens: max}) do
    trunc(max * Map.get(ratios, :retrieved, 0.10))
  end

  defp retrieved_budget(_window), do: 0

  # ============================================================================
  # Private Helpers - Multi-Layer Token Estimation
  # ============================================================================

  defp estimate_tokens(message) when is_map(message) do
    content = message[:content] || message["content"] || ""
    estimate_tokens_text(content)
  end

  defp estimate_tokens_text(text) when is_binary(text) do
    # Rough approximation: 4 characters per token
    div(String.length(text), 4)
  end

  defp estimate_tokens_text(_), do: 0

  defp tokens_for_messages(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_tokens(msg) end)
  end

  # ============================================================================
  # Private Helpers - Compression Pipeline
  # ============================================================================

  # Run summarization and fact extraction in parallel
  defp run_compression_pipeline(%{multi_layer: true} = window, messages) do
    # Always run summarization
    summarize_task = Task.async(fn -> summarize_messages(window, messages) end)

    # Optionally run fact extraction in parallel
    fact_task =
      if window.fact_extraction_enabled and fact_extractor_available?() do
        Task.async(fn -> extract_facts_from_messages(window, messages) end)
      else
        nil
      end

    # Wait for summarization (required)
    {demoted_text, demoted_tokens} = Task.await(summarize_task, :timer.seconds(30))

    # Wait for fact extraction (optional)
    extracted_facts =
      if fact_task do
        case Task.await(fact_task, :timer.seconds(30)) do
          {:ok, facts} -> facts
          {:error, reason} ->
            Logger.debug("Fact extraction failed during compression",
              reason: inspect(reason),
              agent_id: window.agent_id
            )
            []
        end
      else
        []
      end

    {demoted_text, demoted_tokens, extracted_facts}
  end

  # Extract facts from messages being demoted
  defp extract_facts_from_messages(%{multi_layer: true} = window, messages) do
    texts =
      Enum.map(messages, fn msg ->
        msg[:content] || msg["content"] || ""
      end)
      |> Enum.filter(&(String.length(&1) > 0))

    opts = [
      source: "compression_cycle_#{window.compression_count}",
      min_confidence: window.min_fact_confidence
    ]

    case FactExtractor.extract_batch(texts, opts) do
      facts when is_list(facts) ->
        # Filter by confidence threshold
        filtered = Enum.filter(facts, fn f ->
          (f[:confidence] || f.confidence || 1.0) >= window.min_fact_confidence
        end)
        {:ok, filtered}
      _ -> {:ok, []}
    end
  rescue
    e -> {:error, {:fact_extraction_error, e}}
  end

  defp fact_extractor_available? do
    Code.ensure_loaded?(FactExtractor) and
      function_exported?(FactExtractor, :extract_batch, 2)
  end

  defp split_for_compression(messages, target_tokens) do
    # Messages are in reverse chronological order (newest first)
    # We want to demote from the end (oldest)
    reversed = Enum.reverse(messages)

    {to_demote, to_keep, _} =
      Enum.reduce(reversed, {[], [], 0}, fn msg, {demote, keep, tokens} ->
        msg_tokens = estimate_tokens(msg)

        if tokens < target_tokens do
          {[msg | demote], keep, tokens + msg_tokens}
        else
          {demote, [msg | keep], tokens}
        end
      end)

    # Return in original order (newest first for to_keep)
    {Enum.reverse(to_demote), to_keep}
  end

  # Summarize messages - use LLM when enabled, otherwise simple formatting
  defp summarize_messages(%{summarization_enabled: false}, messages) do
    text = format_messages_for_summary(messages)
    {text, estimate_tokens_text(text)}
  end

  defp summarize_messages(%{summarization_enabled: true} = window, messages) do
    formatted = format_messages_for_summary(messages)
    original_tokens = estimate_tokens_text(formatted)
    llm_opts = summarization_llm_opts(window)

    case window.summarization_algorithm do
      :incremental_bullets ->
        summarize_incremental(formatted, original_tokens, llm_opts)

      _prose ->
        summarize_prose(formatted, original_tokens, llm_opts)
    end
  end

  defp summarize_prose(formatted, original_tokens, llm_opts) do
    target_words = max(100, div(original_tokens, 5))

    prompt =
      "Summarize the following conversation excerpt in approximately #{target_words} words.\n" <>
        "Focus on preserving decisions, outcomes, and important facts.\n\n" <>
        "CONVERSATION TO SUMMARIZE:\n#{formatted}\n\nSUMMARY:"

    case call_summarization_llm(prompt, :prose, llm_opts) do
      {:ok, summary} ->
        summary_tokens = estimate_tokens_text(summary)

        Logger.debug(
          "Context compression (prose): #{original_tokens} -> #{summary_tokens} tokens " <>
            "(#{Float.round(summary_tokens / max(1, original_tokens) * 100, 1)}%)"
        )

        {summary, summary_tokens}

      {:error, _reason} ->
        # Fallback to simple formatting
        {formatted, original_tokens}
    end
  end

  defp summarize_incremental(formatted, original_tokens, llm_opts) do
    target_bullets = max(3, div(original_tokens, 150))

    prompt =
      "Generate #{target_bullets} bullet points summarizing the key information.\n" <>
        "Each bullet should capture one decision, outcome, or important fact.\n\n" <>
        "CONVERSATION TO SUMMARIZE:\n#{formatted}\n\nNEW BULLETS:"

    case call_summarization_llm(prompt, :incremental_bullets, llm_opts) do
      {:ok, bullets} ->
        cleaned = clean_bullet_output(bullets)
        summary_tokens = estimate_tokens_text(cleaned)

        Logger.debug(
          "Context compression (incremental): #{original_tokens} -> #{summary_tokens} tokens " <>
            "(#{Float.round(summary_tokens / max(1, original_tokens) * 100, 1)}%), " <>
            "#{count_bullets(cleaned)} bullets"
        )

        {cleaned, summary_tokens}

      {:error, _reason} ->
        text = format_messages_as_bullets(messages_from_text(formatted))
        {text, estimate_tokens_text(text)}
    end
  end

  defp summarization_llm_opts(window) do
    opts = []
    opts = if window.summarization_model, do: [{:model, window.summarization_model} | opts], else: opts
    opts = if window.summarization_provider, do: [{:provider, window.summarization_provider} | opts], else: opts
    opts
  end

  @summarization_system_prompt """
  You are a context compression assistant. Your job is to summarize conversation history
  while preserving the most important information.

  Guidelines:
  - Preserve key decisions, outcomes, and facts
  - Keep names, specific values, and technical details that might be referenced later
  - Remove redundant back-and-forth, pleasantries, and filler
  - Use concise bullet points or short paragraphs
  - For tool results, keep only the outcome (success/failure) and key data
  - Maintain chronological order
  - Write in third person past tense

  Output ONLY the summary, no preamble or explanation.
  """

  @incremental_bullet_system_prompt """
  You are a context compression assistant that generates structured bullet point summaries.

  Your output format is ALWAYS bullet points, one per line, starting with "- ".

  Guidelines:
  - Each bullet captures ONE key decision, outcome, or fact
  - Include specific names, values, and technical details
  - Use past tense
  - Be concise - aim for 10-20 words per bullet
  - Focus on what happened and what was decided, not the discussion
  - For tool results, capture only the key outcome

  Output ONLY bullet points, no preamble, headers, or explanation.
  """

  defp call_summarization_llm(prompt, algorithm, llm_opts) do
    if Code.ensure_loaded?(Arbor.AI) and function_exported?(Arbor.AI, :generate_text, 2) do
      system_prompt =
        case algorithm do
          :incremental_bullets -> @incremental_bullet_system_prompt
          _ -> @summarization_system_prompt
        end

      opts =
        [system_prompt: system_prompt, max_tokens: 1000]
        |> maybe_add_llm_opt(:model, llm_opts[:model])
        |> maybe_add_llm_opt(:provider, llm_opts[:provider])

      case Arbor.AI.generate_text(prompt, opts) do
        {:ok, %{text: text}} when is_binary(text) ->
          {:ok, String.trim(text)}

        {:ok, response} when is_binary(response) ->
          {:ok, String.trim(response)}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:unexpected_response, other}}
      end
    else
      {:error, :arbor_ai_not_available}
    end
  end

  defp maybe_add_llm_opt(opts, _key, nil), do: opts
  defp maybe_add_llm_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp clean_bullet_output(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      String.starts_with?(line, "- ") or String.starts_with?(line, "* ")
    end)
    |> Enum.map_join("\n", fn line ->
      if String.starts_with?(line, "* ") do
        "- " <> String.slice(line, 2..-1//1)
      else
        line
      end
    end)
  end

  defp count_bullets(text) do
    text
    |> String.split("\n")
    |> Enum.count(fn line -> String.starts_with?(String.trim(line), "- ") end)
  end

  defp merge_into_recent_summary("", new_text), do: new_text

  defp merge_into_recent_summary(existing, new_text) do
    existing_is_bullets = String.starts_with?(String.trim(existing), "- ")
    new_is_bullets = String.starts_with?(String.trim(new_text), "- ")

    cond do
      existing_is_bullets and new_is_bullets ->
        existing <> "\n" <> new_text

      existing_is_bullets ->
        existing <> "\n\n[Additional context]\n" <> new_text

      new_is_bullets ->
        existing <> "\n\n[Key points]\n" <> new_text

      true ->
        existing <> "\n\n" <> new_text
    end
  end

  defp flow_to_distant(window, recent, distant, _recent_tokens) do
    distant_budget = distant_summary_budget(window)

    # Split recent in half - older half flows to distant
    lines = String.split(recent, "\n")
    mid = div(length(lines), 2)
    {to_distant, keep_recent} = Enum.split(lines, mid)

    to_distant_text = Enum.join(to_distant, "\n")
    new_recent_text = Enum.join(keep_recent, "\n")

    summarized_distant = maybe_summarize_for_distant(window, to_distant_text)
    updated_distant = merge_distant_content(window, distant, summarized_distant, distant_budget)

    final_distant = enforce_distant_budget(updated_distant, distant_budget)
    new_recent_tokens = estimate_tokens_text(new_recent_text)

    {new_recent_text, final_distant, new_recent_tokens, estimate_tokens_text(final_distant)}
  end

  # Summarize content flowing to distant if enabled and substantial
  defp maybe_summarize_for_distant(window, text) do
    if window.summarization_enabled and String.length(text) > 500 do
      case summarize_for_distant(window, text) do
        {:ok, summary} -> summary
        {:error, _} -> text
      end
    else
      text
    end
  end

  # Merge new content into existing distant summary, re-summarizing if over budget
  defp merge_distant_content(_window, "", new_content, _budget), do: new_content

  defp merge_distant_content(window, existing, new_content, budget) do
    combined = existing <> "\n\n" <> new_content

    if estimate_tokens_text(combined) > budget do
      case summarize_for_distant(window, combined) do
        {:ok, summary} -> summary
        {:error, _} -> truncate_to_budget(combined, budget)
      end
    else
      combined
    end
  end

  # Ensure final distant text fits within budget
  defp enforce_distant_budget(text, budget) do
    if estimate_tokens_text(text) > budget do
      truncate_to_budget(text, budget)
    else
      text
    end
  end

  # Summarize text for distant memory (very aggressive compression)
  defp summarize_for_distant(%{summarization_enabled: false}, _text) do
    {:error, :summarization_disabled}
  end

  defp summarize_for_distant(%{summarization_enabled: true} = window, text) do
    original_tokens = estimate_tokens_text(text)
    target_words = max(50, div(original_tokens, 7))

    prompt =
      "Create a highly condensed summary of this context in approximately #{target_words} words.\n" <>
        "Keep only the most essential facts, decisions, and outcomes.\n" <>
        "This will be used as distant memory, so focus on what might be referenced later.\n\n" <>
        "CONTENT:\n#{text}\n\nCONDENSED SUMMARY:"

    call_summarization_llm(prompt, :prose, summarization_llm_opts(window))
  end

  defp truncate_to_budget(text, budget_tokens) do
    target_chars = budget_tokens * 4
    String.slice(text, -target_chars, target_chars)
  end

  # ============================================================================
  # Private Helpers - Multi-Layer Formatting
  # ============================================================================

  defp format_messages_for_summary(messages) do
    Enum.map_join(messages, "\n", &format_single_message_for_summary/1)
  end

  defp format_single_message_for_summary(msg) do
    role = msg[:role] || msg["role"] || "unknown"
    content = msg[:content] || msg["content"] || ""
    speaker = msg[:speaker] || msg["speaker"]
    time_str = format_message_time(msg[:timestamp])
    speaker_label = resolve_speaker_label(role, speaker)

    "[#{time_str}] #{speaker_label}: #{truncate_content(content, 500)}"
  end

  defp format_message_time(nil), do: ""
  defp format_message_time(timestamp), do: Calendar.strftime(timestamp, "%Y-%m-%d %H:%M")

  defp resolve_speaker_label(role, speaker) when role in [:user, "user"], do: speaker || "Human"
  defp resolve_speaker_label(role, _speaker), do: to_string(role)

  defp format_messages_as_bullets(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      role = msg[:role] || msg["role"] || "unknown"
      content = msg[:content] || msg["content"] || ""
      truncated = String.slice(content, 0, 100)

      case role do
        r when r in [:user, "user"] -> "- User: #{truncated}"
        r when r in [:assistant, "assistant"] -> "- Agent: #{truncated}"
        _ -> "- #{role}: #{truncated}"
      end
    end)
  end

  # Convert formatted text back to pseudo-messages for bullet fallback
  defp messages_from_text(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line -> %{role: :unknown, content: line} end)
  end

  defp truncate_content(content, max_length) when byte_size(content) > max_length do
    String.slice(content, 0, max_length) <> "..."
  end

  defp truncate_content(content, _), do: content

  defp format_clarity_boundary(nil) do
    "[CLARITY BOUNDARY: Memory begins here. Earlier context is summarized above.]"
  end

  defp format_clarity_boundary(%DateTime{} = dt) do
    time_ago = DateTime.diff(DateTime.utc_now(), dt, :minute)

    period =
      cond do
        time_ago < 60 -> "#{time_ago} minutes ago"
        time_ago < 1440 -> "#{div(time_ago, 60)} hours ago"
        true -> "#{div(time_ago, 1440)} days ago"
      end

    "[CLARITY BOUNDARY: Full detail begins #{period}. Earlier memories are summarized and can be searched if needed.]"
  end

  defp format_summary_time(nil), do: "earlier"

  defp format_summary_time(%DateTime{} = boundary) do
    time_ago = DateTime.diff(DateTime.utc_now(), boundary, :minute)

    cond do
      time_ago < 60 -> "#{time_ago} minutes ago"
      time_ago < 1440 -> "#{div(time_ago, 60)} hours ago"
      true -> "#{div(time_ago, 1440)} days ago"
    end
  end

  defp format_retrieved_context(contexts) do
    header = "[RETRIEVED CONTEXT - surfaced from memory search]\n"

    content =
      Enum.map_join(contexts, "\n", fn ctx ->
        "- #{ctx[:content] || ctx["content"] || inspect(ctx)}"
      end)

    header <> content
  end

  defp format_full_detail(messages) do
    messages
    |> Enum.reverse()
    |> Enum.map_join("\n\n", &format_detail_message/1)
  end

  defp format_detail_message(msg) do
    role = msg[:role] || msg["role"] || "unknown"
    content = msg[:content] || msg["content"] || ""
    speaker = msg[:speaker] || msg["speaker"]
    label = detail_role_label(role, speaker)

    "[#{label}]\n#{content}"
  end

  defp detail_role_label(role, speaker) when role in [:user, "user"], do: speaker || "Human"
  defp detail_role_label(role, _speaker) when role in [:assistant, "assistant"], do: "Assistant"
  defp detail_role_label(role, _speaker) when role in [:system, "system"], do: "System"
  defp detail_role_label(role, _speaker), do: role

  defp format_action_result(%{action: action, outcome: outcome, result: result}) do
    result_text =
      cond do
        is_binary(result) -> result
        is_list(result) -> Enum.join(result, "\n")
        is_map(result) -> json_encode_safe(result)
        true -> inspect(result, pretty: true)
      end

    truncated =
      if String.length(result_text) > 8000 do
        String.slice(result_text, 0, 8000) <>
          "\n... (truncated, #{String.length(result_text)} bytes total)"
      else
        result_text
      end

    "**#{action}** (#{outcome}):\n```\n#{truncated}\n```"
  end

  defp format_action_result(result) do
    inspect(result, pretty: true)
  end

  defp json_encode_safe(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(data, pretty: true)
    end
  end

  # ============================================================================
  # Private Helpers - Signal Emission
  # ============================================================================

  defp emit_demotion_signal(%{agent_id: agent_id}, messages, compressed_tokens) do
    if signals_available?() do
      original_tokens = tokens_for_messages(messages)

      Signals.emit_context_summarized(agent_id, %{
        from_layer: :full_detail,
        to_layer: :recent_summary,
        original_tokens: original_tokens,
        compressed_tokens: compressed_tokens,
        compression_ratio:
          if(original_tokens > 0, do: compressed_tokens / original_tokens, else: 0),
        messages_demoted: length(messages)
      })
    end

    :ok
  end

  defp emit_fact_extraction_signal(%{agent_id: agent_id}, facts) do
    if signals_available?() do
      Signals.emit_facts_extracted(agent_id, %{
        count: length(facts),
        categories: Enum.frequencies_by(facts, fn f -> f[:category] || f.category end),
        source: :compression
      })
    end

    :ok
  end

  defp signals_available? do
    Code.ensure_loaded?(Signals) and
      function_exported?(Signals, :emit_context_summarized, 2)
  end

  # ============================================================================
  # Private Helpers - Deduplication
  # ============================================================================

  # Check if content is semantically similar to any existing retrieved context.
  # Uses embedding-based cosine similarity when available, falls back to exact match.
  defp semantically_duplicate?([], _content), do: false

  defp semantically_duplicate?(existing_contexts, new_content) do
    case compute_embedding(new_content) do
      nil ->
        # No embedding available, fall back to exact match
        Enum.any?(existing_contexts, fn ctx ->
          existing_content = ctx[:content] || ctx["content"] || ""
          existing_content == new_content
        end)

      new_embedding ->
        Enum.any?(existing_contexts, fn ctx ->
          context_exceeds_similarity?(ctx, new_embedding)
        end)
    end
  end

  # Check if a single context item is similar enough to count as a duplicate
  defp context_exceeds_similarity?(ctx, new_embedding) do
    embedding = ctx[:embedding] || compute_context_embedding(ctx)

    case embedding do
      nil -> false
      existing_embedding -> cosine_similarity(new_embedding, existing_embedding) >= @retrieved_dedup_threshold
    end
  end

  defp compute_context_embedding(ctx) do
    existing_content = ctx[:content] || ctx["content"] || ""
    compute_embedding(existing_content)
  end

  # Add embedding to context for future dedup checks
  defp maybe_add_embedding(context, content) do
    case compute_embedding(content) do
      nil -> context
      embedding -> Map.put(context, :embedding, embedding)
    end
  end

  # Compute embedding for content using Arbor.AI.embed/2
  defp compute_embedding(content) when is_binary(content) and byte_size(content) > 0 do
    if embedding_service_available?() do
      case Arbor.AI.embed(content) do
        {:ok, %{embedding: embedding}} -> embedding
        _ -> nil
      end
    else
      nil
    end
  end

  defp compute_embedding(_), do: nil

  defp embedding_service_available? do
    Code.ensure_loaded?(Arbor.AI) and function_exported?(Arbor.AI, :embed, 2)
  end

  # Compute cosine similarity between two embedding vectors
  defp cosine_similarity(emb1, emb2) when is_list(emb1) and is_list(emb2) do
    dot = Enum.zip(emb1, emb2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    norm1 = :math.sqrt(Enum.reduce(emb1, 0.0, fn x, acc -> acc + x * x end))
    norm2 = :math.sqrt(Enum.reduce(emb2, 0.0, fn x, acc -> acc + x * x end))

    if norm1 > 0 and norm2 > 0 do
      dot / (norm1 * norm2)
    else
      0.0
    end
  end

  defp cosine_similarity(_, _), do: 0.0

  # ============================================================================
  # Private Helpers - ID Generation
  # ============================================================================

  defp generate_id(prefix) do
    "#{prefix}_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  # ============================================================================
  # Private Helpers - Serialization
  # ============================================================================

  defp serialize_datetime(nil), do: nil
  defp serialize_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_atom(nil, default), do: default
  defp parse_atom(value, _default) when is_atom(value), do: value

  defp parse_atom(value, default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> default
  end

  defp parse_atom(_, default), do: default
end
