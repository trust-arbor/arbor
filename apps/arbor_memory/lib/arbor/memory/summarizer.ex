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
  Summarize text.

  **Note:** This is a placeholder that returns an error until LLM integration
  is wired in. The actual implementation will use arbor_ai for LLM calls.

  ## Options

  - `:max_length` - Target summary length in tokens (default: 200)
  - `:focus` - What to prioritize (:facts, :narrative, :technical)
  - `:model_preference` - Specific model to use (overrides auto-selection)

  ## Examples

      {:ok, result} = Summarizer.summarize(text)
      {:error, :llm_not_configured} = Summarizer.summarize(text)  # Until configured
  """
  @spec summarize(String.t(), summarize_opts()) ::
          {:ok, summarize_result()} | {:error, term()}
  def summarize(text, opts \\ []) when is_binary(text) do
    complexity = assess_complexity(text)
    model = Keyword.get(opts, :model_preference) || recommend_model(complexity)

    # Placeholder - actual LLM integration comes when arbor_ai is wired to memory
    # For now, return an error indicating the system is not yet configured
    {:error, {:llm_not_configured, %{complexity: complexity, model_recommendation: model}}}
  end

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
