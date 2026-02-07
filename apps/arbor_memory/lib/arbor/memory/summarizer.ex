defmodule Arbor.Memory.Summarizer do
  @moduledoc """
  Interface for progressive summarization with complexity assessment.

  Summarizer provides complexity assessment and model routing recommendations
  for text summarization. The actual LLM call is deferred — this module
  implements the analysis layer that will drive model selection.

  ## Complexity Levels

  - `:simple` - Short, straightforward text (< 200 words, low term density)
  - `:moderate` - Medium length, some technical content (200-500 words)
  - `:complex` - Long or dense technical content (500-1000 words)
  - `:highly_complex` - Very long or highly technical (> 1000 words)

  ## Model Routing

  Complexity assessment determines which model to use for summarization:
  - Simple queries get fast/cheap models (Haiku, Gemini Flash)
  - Complex content gets capable models (Sonnet, GPT-4)

  ## Examples

      # Assess complexity
      complexity = Summarizer.assess_complexity(text)
      #=> :moderate

      # Get model recommendation
      model = Summarizer.recommend_model(complexity)
      #=> "anthropic:claude-3-5-haiku-20241022"

      # Full summarization (requires LLM integration)
      {:ok, result} = Summarizer.summarize(text)
      #=> {:ok, %{summary: "...", complexity: :moderate, model_used: "..."}}
  """

  alias Arbor.Memory.TokenBudget

  @type complexity :: :simple | :moderate | :complex | :highly_complex

  @type summarize_result :: %{
          summary: String.t(),
          complexity: complexity(),
          model_recommendation: String.t()
        }

  @type summarize_opts :: [
          max_length: pos_integer(),
          focus: :facts | :narrative | :technical,
          model_preference: String.t()
        ]

  # Complexity thresholds
  @word_threshold_simple 200
  @word_threshold_moderate 500
  @word_threshold_complex 1000

  # Technical term density thresholds (terms per 100 words)
  @tech_density_low 2.0
  @tech_density_medium 5.0
  @tech_density_high 10.0

  # Common technical terms for density calculation
  @technical_terms ~w(
    api database server client function module class interface
    async await promise callback thread process memory cpu
    query index cache redis postgres mysql mongodb sql nosql
    http https rest graphql websocket tcp udp protocol
    deploy kubernetes docker container pod cluster node
    git branch commit merge rebase pull push repository
    test unit integration e2e mock stub fixture assert
    error exception handler middleware pipeline router
    config environment variable secret token auth jwt oauth
    json xml yaml toml csv parse serialize deserialize
    regex pattern match filter map reduce fold
    elixir erlang otp genserver supervisor ets mnesia
    phoenix liveview channel socket pubsub
  )

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Assess the complexity of a piece of text.

  Considers:
  - Word count
  - Sentence count
  - Technical term density
  - Average sentence length

  ## Examples

      Summarizer.assess_complexity("Hello world")
      #=> :simple

      Summarizer.assess_complexity(long_technical_doc)
      #=> :highly_complex
  """
  @spec assess_complexity(String.t()) :: complexity()
  def assess_complexity(text) when is_binary(text) do
    metrics = compute_metrics(text)

    cond do
      metrics.word_count < @word_threshold_simple and metrics.tech_density < @tech_density_low ->
        :simple

      metrics.word_count < @word_threshold_moderate and
          metrics.tech_density < @tech_density_medium ->
        :moderate

      metrics.word_count < @word_threshold_complex and
          metrics.tech_density < @tech_density_high ->
        :complex

      true ->
        :highly_complex
    end
  end

  @doc """
  Get a model recommendation based on complexity level.

  ## Options

  - `:preference` - Preferred provider (:anthropic, :openai, :google)
  - `:cost_sensitive` - Prefer cheaper models when possible (default: true)

  ## Examples

      Summarizer.recommend_model(:simple)
      #=> "anthropic:claude-3-5-haiku-20241022"

      Summarizer.recommend_model(:highly_complex, preference: :openai)
      #=> "openai:gpt-4o"
  """
  @spec recommend_model(complexity(), keyword()) :: String.t()
  def recommend_model(complexity, opts \\ []) do
    preference = Keyword.get(opts, :preference, :anthropic)
    cost_sensitive = Keyword.get(opts, :cost_sensitive, true)

    model_for_complexity(complexity, preference, cost_sensitive)
  end

  defp model_for_complexity(:simple, :openai, _), do: "openai:gpt-4o-mini"
  defp model_for_complexity(:simple, :google, _), do: "google:gemini-2.0-flash"
  defp model_for_complexity(:simple, _, _), do: "anthropic:claude-3-5-haiku-20241022"

  defp model_for_complexity(:moderate, :anthropic, false), do: "anthropic:claude-3-5-sonnet-20241022"
  defp model_for_complexity(:moderate, :openai, _), do: "openai:gpt-4o-mini"
  defp model_for_complexity(:moderate, :google, _), do: "google:gemini-1.5-flash"
  defp model_for_complexity(:moderate, _, _), do: "anthropic:claude-3-5-haiku-20241022"

  defp model_for_complexity(:complex, :openai, _), do: "openai:gpt-4o"
  defp model_for_complexity(:complex, :google, _), do: "google:gemini-1.5-pro"
  defp model_for_complexity(:complex, _, _), do: "anthropic:claude-3-5-sonnet-20241022"

  defp model_for_complexity(:highly_complex, :openai, _), do: "openai:gpt-4o"
  defp model_for_complexity(:highly_complex, :google, _), do: "google:gemini-1.5-pro"
  defp model_for_complexity(:highly_complex, _, _), do: "anthropic:claude-opus-4-5-20251101"

  @doc """
  Summarize text using LLM-based summarization.

  Uses `Arbor.AI.generate_text/2` when available. Falls back to
  `{:error, :arbor_ai_not_available}` when the AI module is not loaded.

  ## Options

  - `:max_length` - Target summary length in tokens (default: 200)
  - `:focus` - What to prioritize (:facts, :narrative, :technical)
  - `:model_preference` - Specific model to use (overrides auto-selection)
  - `:algorithm` - Summarization algorithm (`:prose` or `:incremental_bullets`, default: `:prose`)

  ## Examples

      {:ok, result} = Summarizer.summarize(text)
      {:ok, result} = Summarizer.summarize(text, algorithm: :incremental_bullets)
  """
  @spec summarize(String.t(), summarize_opts()) ::
          {:ok, summarize_result()} | {:error, term()}
  def summarize(text, opts \\ []) when is_binary(text) do
    complexity = assess_complexity(text)
    model = Keyword.get(opts, :model_preference) || recommend_model(complexity)
    algorithm = Keyword.get(opts, :algorithm, :prose)

    prompt = build_prompt(text, algorithm, opts)
    system_prompt = system_prompt_for(algorithm)

    result =
      if Code.ensure_loaded?(Arbor.AI) and function_exported?(Arbor.AI, :generate_text, 2) do
        llm_opts = [system_prompt: system_prompt, model: model, max_tokens: 1000]

        case Arbor.AI.generate_text(prompt, llm_opts) do
          {:ok, %{text: summary}} when is_binary(summary) ->
            {:ok, %{summary: String.trim(summary), complexity: complexity, model_used: model}}

          {:ok, summary} when is_binary(summary) ->
            {:ok, %{summary: String.trim(summary), complexity: complexity, model_used: model}}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_response, other}}
        end
      else
        {:error, :arbor_ai_not_available}
      end

    # Graceful fallback: if LLM fails, produce a simple truncation summary
    case result do
      {:ok, _} = success ->
        success

      {:error, _reason} ->
        max_length = Keyword.get(opts, :max_length, 200)
        fallback = fallback_summary(text, max_length)
        {:ok, %{summary: fallback, complexity: complexity, model_used: "fallback"}}
    end
  end

  defp fallback_summary(text, target_tokens) do
    target_chars = target_tokens * 4

    if String.length(text) <= target_chars do
      text
    else
      String.slice(text, 0, target_chars) <> "..."
    end
  end

  defp build_prompt(text, :incremental_bullets, opts) do
    max_length = Keyword.get(opts, :max_length, 200)
    target_bullets = max(3, div(max_length, 30))

    """
    Generate #{target_bullets} bullet points summarizing the key information.
    Each bullet should capture one decision, outcome, or important fact.

    TEXT TO SUMMARIZE:
    #{text}

    NEW BULLETS:
    """
  end

  defp build_prompt(text, _prose, opts) do
    max_length = Keyword.get(opts, :max_length, 200)
    focus = Keyword.get(opts, :focus, :facts)

    focus_instruction =
      case focus do
        :narrative -> "Focus on narrative flow and key events."
        :technical -> "Focus on technical details, APIs, and implementation specifics."
        _ -> "Focus on preserving decisions, outcomes, and important facts."
      end

    """
    Summarize the following text in approximately #{max_length} tokens.
    #{focus_instruction}

    TEXT TO SUMMARIZE:
    #{text}

    SUMMARY:
    """
  end

  @prose_system_prompt """
  You are a context compression assistant. Summarize conversation history while preserving
  the most important information. Keep names, specific values, and technical details.
  Remove redundant back-and-forth and filler. Use concise paragraphs.
  Write in third person past tense. Output ONLY the summary.
  """

  @bullet_system_prompt """
  You are a context compression assistant that generates structured bullet points.
  Output format: one bullet per line, starting with "- ".
  Each bullet captures ONE key decision, outcome, or fact.
  Be concise (10-20 words per bullet). Use past tense.
  Output ONLY bullet points, no preamble.
  """

  defp system_prompt_for(:incremental_bullets), do: @bullet_system_prompt
  defp system_prompt_for(_), do: @prose_system_prompt

  @doc """
  Get detailed metrics for a piece of text.

  Useful for debugging complexity assessment or for custom processing.
  """
  @spec get_metrics(String.t()) :: map()
  def get_metrics(text) when is_binary(text) do
    compute_metrics(text)
  end

  @doc """
  Estimate the summary length for a given text.

  Uses a compression ratio based on complexity.
  """
  @spec estimate_summary_length(String.t()) :: non_neg_integer()
  def estimate_summary_length(text) when is_binary(text) do
    original_tokens = TokenBudget.estimate_tokens(text)
    complexity = assess_complexity(text)

    compression_ratio =
      case complexity do
        :simple -> 0.4
        :moderate -> 0.3
        :complex -> 0.25
        :highly_complex -> 0.2
      end

    max(10, trunc(original_tokens * compression_ratio))
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp compute_metrics(text) do
    words = String.split(text, ~r/\s+/, trim: true)
    word_count = length(words)

    sentences = String.split(text, ~r/[.!?]+/, trim: true)
    sentence_count = max(1, length(sentences))

    technical_terms = count_technical_terms(text)
    tech_density = if word_count > 0, do: technical_terms / word_count * 100, else: 0.0

    avg_sentence_length = word_count / sentence_count

    %{
      word_count: word_count,
      sentence_count: sentence_count,
      technical_terms: technical_terms,
      tech_density: Float.round(tech_density, 2),
      avg_sentence_length: Float.round(avg_sentence_length, 1),
      estimated_tokens: TokenBudget.estimate_tokens(text)
    }
  end

  defp count_technical_terms(text) do
    text_lower = String.downcase(text)

    @technical_terms
    |> Enum.count(fn term ->
      String.contains?(text_lower, term)
    end)
  end
end
