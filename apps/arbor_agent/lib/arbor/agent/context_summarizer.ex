defmodule Arbor.Agent.ContextSummarizer do
  @moduledoc """
  Intelligent context summarization using dual-model approach.

  Uses a fast/cheap model (Haiku) to summarize old context while
  keeping recent context in full detail. Maintains tiered summaries
  for different time horizons.

  ## Summary Tiers

  - **Recent** (full detail): Last N messages, kept verbatim
  - **Tier 1** (recent summary): 1-24 hours ago, summarized
  - **Tier 2** (distant summary): 24+ hours ago, heavily summarized

  ## Dual-Model Strategy

  The summarizer model is fast and cheap (Haiku), used only for
  compression. The main model never sees the summarization prompts,
  only the results.
  """

  require Logger

  alias Arbor.Agent.SummaryCache

  @type summary_tier :: :recent | :tier_1 | :tier_2

  @type context_window :: %{
          recent: [map()],
          tier_1_summary: String.t() | nil,
          tier_2_summary: String.t() | nil,
          total_tokens: non_neg_integer(),
          last_summarized_at: DateTime.t() | nil
        }

  @doc """
  Check if context needs summarization and summarize if so.

  Returns the context unchanged if below threshold or if
  summarization is disabled.
  """
  @spec maybe_summarize(context_window()) :: {:ok, context_window()} | {:error, term()}
  def maybe_summarize(context) do
    if needs_summarization?(context) do
      summarize(context)
    else
      {:ok, context}
    end
  end

  @doc """
  Force summarization of context regardless of threshold.
  """
  @spec summarize(context_window()) :: {:ok, context_window()} | {:error, term()}
  def summarize(context) do
    with {:ok, {recent, to_summarize}} <- split_context(context),
         {:ok, tier_1} <- summarize_tier(to_summarize, :tier_1, context[:tier_1_summary]),
         {:ok, tier_2} <- maybe_promote_to_tier_2(context, tier_1) do
      new_context = %{
        context
        | recent: recent,
          tier_1_summary: tier_1,
          tier_2_summary: tier_2,
          last_summarized_at: DateTime.utc_now()
      }

      {:ok, new_context}
    end
  end

  @doc """
  Build the prompt context string combining recent messages and summaries.

  Returns a string with tier sections in chronological order
  (oldest tier first).
  """
  @spec build_prompt_context(context_window()) :: String.t()
  def build_prompt_context(context) do
    parts = []

    # Add tier 2 (oldest) first
    parts =
      if context[:tier_2_summary] do
        [build_tier_section(:tier_2, context.tier_2_summary) | parts]
      else
        parts
      end

    # Add tier 1 (recent past)
    parts =
      if context[:tier_1_summary] do
        [build_tier_section(:tier_1, context.tier_1_summary) | parts]
      else
        parts
      end

    # Recent messages handled separately (as actual messages, not summary)
    Enum.join(Enum.reverse(parts), "\n\n")
  end

  @doc """
  Create a new empty context window with summary support.
  """
  @spec new_context_window() :: context_window()
  def new_context_window do
    %{
      recent: [],
      tier_1_summary: nil,
      tier_2_summary: nil,
      total_tokens: 0,
      last_summarized_at: nil
    }
  end

  @doc """
  Check if context is above the summarization threshold.
  """
  @spec needs_summarization?(context_window()) :: boolean()
  def needs_summarization?(context) do
    config(:context_summarization_enabled, true) and
      Map.get(context, :total_tokens, 0) > config(:context_max_tokens, 100_000)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp split_context(context) do
    recent_ratio = config(:context_recent_ratio, 0.7)
    messages = Map.get(context, :recent, [])
    count = length(messages)

    # Keep recent_ratio of messages as recent, rest goes to summarization
    keep_count = max(round(count * recent_ratio), min(count, min_recent_count()))
    split_at = count - keep_count

    {to_summarize, recent} = Enum.split(messages, split_at)
    {:ok, {recent, to_summarize}}
  end

  defp summarize_tier([], _tier, existing_summary), do: {:ok, existing_summary}

  defp summarize_tier(messages, tier, existing_summary) do
    if cache_enabled?() do
      summarize_with_cache(messages, tier, existing_summary)
    else
      do_summarize_tier(messages, tier, existing_summary)
    end
  end

  defp summarize_with_cache(messages, tier, existing_summary) do
    content_hash = SummaryCache.hash_content(messages)

    case SummaryCache.get(content_hash) do
      {:ok, cached_summary} ->
        Logger.debug("Context summarizer: cache hit for tier #{tier}")
        {:ok, cached_summary}

      {:error, _} ->
        case do_summarize_tier(messages, tier, existing_summary) do
          {:ok, summary} = result ->
            if summary, do: SummaryCache.put(content_hash, summary)
            result

          error ->
            error
        end
    end
  end

  defp do_summarize_tier(messages, tier, existing_summary) do
    prompt = build_summarization_prompt(messages, tier, existing_summary)

    case call_summarizer(prompt) do
      {:ok, %{text: summary}} ->
        {:ok, summary}

      {:ok, summary} when is_binary(summary) ->
        {:ok, summary}

      {:error, reason} ->
        Logger.warning("Context summarization failed: #{inspect(reason)}, keeping existing")
        # Graceful degradation: keep existing summary on failure
        {:ok, existing_summary}
    end
  end

  defp call_summarizer(prompt) do
    model = config(:summarizer_model, "claude-haiku")
    provider = config(:summarizer_provider, :anthropic)

    if ai_available?() do
      try do
        Arbor.AI.generate_text(prompt,
          model: model,
          provider: provider,
          max_tokens: 2000,
          backend: :api
        )
      rescue
        e -> {:error, {:summarizer_exception, Exception.message(e)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    else
      {:error, :ai_unavailable}
    end
  end

  defp build_summarization_prompt(messages, tier, existing_summary) do
    messages_text = format_messages_for_summary(messages)

    tier_instruction =
      case tier do
        :tier_1 -> "This is recent context (last 1-24 hours). Preserve detail."
        :tier_2 -> "This is older context (24+ hours). Be more concise, keep only key facts."
      end

    context_addition =
      if existing_summary do
        "\n\nExisting context to integrate:\n#{existing_summary}\n"
      else
        ""
      end

    """
    Summarize the following conversation excerpt concisely.
    Focus on:
    - Key decisions made
    - Important facts learned
    - Action items or commitments
    - Relationships between concepts

    Keep the summary brief but preserve critical context.
    #{tier_instruction}#{context_addition}

    Conversation:
    #{messages_text}
    """
  end

  defp format_messages_for_summary(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      role = msg[:role] || "unknown"
      content = msg[:content] || ""
      # Truncate individual messages to avoid prompt explosion
      truncated = String.slice(to_string(content), 0, 500)
      "[#{role}]: #{truncated}"
    end)
  end

  defp build_tier_section(tier, summary) do
    header =
      case tier do
        :tier_1 -> "## Recent Context (summarized)"
        :tier_2 -> "## Earlier Context (summarized)"
      end

    "#{header}\n\n#{summary}"
  end

  defp maybe_promote_to_tier_2(context, _new_tier_1) do
    tier_2_age = config(:summary_tier_2_age_hours, 24)

    if should_promote_to_tier_2?(context, tier_2_age) do
      # Combine old tier_1 into tier_2
      combined =
        if context[:tier_2_summary] do
          context.tier_2_summary <> "\n\n" <> (context[:tier_1_summary] || "")
        else
          context[:tier_1_summary]
        end

      if combined do
        # Re-summarize the combined tier 2 content
        do_summarize_tier([%{role: "context", content: combined}], :tier_2, nil)
      else
        {:ok, context[:tier_2_summary]}
      end
    else
      {:ok, context[:tier_2_summary]}
    end
  end

  defp should_promote_to_tier_2?(context, hours_threshold) do
    case context[:last_summarized_at] do
      nil -> false
      ts -> DateTime.diff(DateTime.utc_now(), ts, :hour) >= hours_threshold
    end
  end

  defp min_recent_count, do: config(:context_min_recent_messages, 10)

  defp cache_enabled? do
    config(:summary_cache_enabled, true) and cache_available?()
  end

  defp cache_available? do
    case Process.whereis(Arbor.Agent.SummaryCache) do
      nil -> false
      _pid -> true
    end
  end

  defp ai_available? do
    Code.ensure_loaded?(Arbor.AI) and
      function_exported?(Arbor.AI, :generate_text, 2)
  end

  defp config(key, default) do
    Application.get_env(:arbor_agent, key, default)
  end
end
