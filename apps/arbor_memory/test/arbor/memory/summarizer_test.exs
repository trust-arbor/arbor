defmodule Arbor.Memory.SummarizerTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Summarizer

  @moduletag :fast

  describe "assess_complexity/1" do
    test "returns :simple for short, non-technical text" do
      text = "Hello world. This is a simple message. Nothing complex here."
      assert Summarizer.assess_complexity(text) == :simple
    end

    test "returns :moderate for medium-length text" do
      # ~300 words with some structure
      text = String.duplicate("This is a moderately complex sentence with some content. ", 40)
      complexity = Summarizer.assess_complexity(text)
      assert complexity in [:moderate, :complex]
    end

    test "returns :complex for longer technical text" do
      # Technical text with many tech terms
      text =
        """
        The API server handles requests using a middleware pipeline. The database
        layer uses PostgreSQL with Redis for caching. We deploy to Kubernetes
        clusters with Docker containers. The authentication uses JWT tokens with
        OAuth integration. Tests are written with unit and integration coverage.
        The server processes async requests with promise-based handlers.
        Error handling uses exception middleware with proper logging.
        Config management uses environment variables and secrets.
        """
        |> String.duplicate(5)

      complexity = Summarizer.assess_complexity(text)
      assert complexity in [:complex, :highly_complex]
    end

    test "returns :highly_complex for very long technical content" do
      # Very long text with high technical density
      text =
        """
        The distributed system architecture leverages Elixir and OTP for
        fault-tolerant processing. GenServer and Supervisor trees manage state
        and recovery. Phoenix channels handle WebSocket connections for real-time
        updates. The Ecto query layer interfaces with Postgres using prepared
        statements. Redis provides caching and pubsub functionality. Kubernetes
        orchestration manages container deployment across the cluster. JWT
        authentication secures API endpoints. The test suite covers unit,
        integration, and e2e scenarios with mock fixtures.
        """
        |> String.duplicate(20)

      complexity = Summarizer.assess_complexity(text)
      assert complexity == :highly_complex
    end

    test "handles empty text" do
      assert Summarizer.assess_complexity("") == :simple
    end
  end

  describe "recommend_model/2" do
    test "recommends Haiku for simple complexity" do
      model = Summarizer.recommend_model(:simple)
      assert model =~ "haiku" or model =~ "flash" or model =~ "mini"
    end

    test "recommends capable models for complex content" do
      model = Summarizer.recommend_model(:complex)
      assert model =~ "sonnet" or model =~ "gpt-4o" or model =~ "pro"
    end

    test "recommends most capable for highly_complex" do
      model = Summarizer.recommend_model(:highly_complex)
      assert model =~ "opus" or model =~ "gpt-4" or model =~ "pro"
    end

    test "respects provider preference" do
      openai = Summarizer.recommend_model(:moderate, preference: :openai)
      assert openai =~ "openai"

      google = Summarizer.recommend_model(:moderate, preference: :google)
      assert google =~ "google"

      anthropic = Summarizer.recommend_model(:moderate, preference: :anthropic)
      assert anthropic =~ "anthropic"
    end

    test "respects cost_sensitive option for moderate" do
      cheap = Summarizer.recommend_model(:moderate, cost_sensitive: true)
      _expensive = Summarizer.recommend_model(:moderate, cost_sensitive: false)

      # Cheap should use faster/cheaper models
      assert cheap =~ "haiku" or cheap =~ "mini" or cheap =~ "flash"
    end
  end

  describe "summarize/2" do
    test "returns error when LLM not configured" do
      result = Summarizer.summarize("Some text to summarize")

      assert {:error, {:llm_not_configured, info}} = result
      assert is_atom(info.complexity)
      assert is_binary(info.model_recommendation)
    end

    test "includes complexity and model recommendation in error" do
      {:error, {:llm_not_configured, info}} =
        Summarizer.summarize("Simple short text")

      assert info.complexity == :simple
      assert is_binary(info.model_recommendation)
    end

    test "respects model_preference option" do
      {:error, {:llm_not_configured, info}} =
        Summarizer.summarize("Text", model_preference: "custom:model")

      assert info.model_recommendation == "custom:model"
    end
  end

  describe "get_metrics/1" do
    test "returns detailed text metrics" do
      text = "This is a test sentence. And another one. Technical terms like API and database."
      metrics = Summarizer.get_metrics(text)

      assert is_integer(metrics.word_count)
      assert is_integer(metrics.sentence_count)
      assert is_integer(metrics.technical_terms)
      assert is_float(metrics.tech_density)
      assert is_float(metrics.avg_sentence_length)
      assert is_integer(metrics.estimated_tokens)
    end

    test "counts technical terms" do
      text = "The API uses a database with SQL queries and HTTP requests"
      metrics = Summarizer.get_metrics(text)

      assert metrics.technical_terms > 0
    end

    test "calculates tech density" do
      # High tech density text
      technical = "API database server client function module class async await promise"
      tech_metrics = Summarizer.get_metrics(technical)

      # Low tech density text
      simple = "The quick brown fox jumps over the lazy dog"
      simple_metrics = Summarizer.get_metrics(simple)

      assert tech_metrics.tech_density > simple_metrics.tech_density
    end
  end

  describe "estimate_summary_length/1" do
    test "returns shorter estimate for longer text" do
      short = "Short text"
      long = String.duplicate("Long text with many words. ", 100)

      short_estimate = Summarizer.estimate_summary_length(short)
      long_estimate = Summarizer.estimate_summary_length(long)

      # Short text should still have at least minimal length
      assert short_estimate >= 10

      # Long text summary should be shorter than original
      assert long_estimate > short_estimate
    end

    test "uses lower compression ratio for complex text" do
      # Complex text gets more aggressive compression
      complex = String.duplicate("API database server async process handler ", 200)
      complex_length = Summarizer.estimate_summary_length(complex)

      # The estimate should be a reasonable fraction of original
      original_tokens = Arbor.Memory.TokenBudget.estimate_tokens(complex)
      compression = complex_length / original_tokens

      assert compression <= 0.4
    end

    test "returns at least minimum length" do
      very_short = "Hi"
      estimate = Summarizer.estimate_summary_length(very_short)

      assert estimate >= 10
    end
  end

  describe "complexity thresholds" do
    test "word count affects complexity" do
      # Under 200 words
      short = String.duplicate("word ", 50)
      assert Summarizer.assess_complexity(short) == :simple

      # 200-500 words
      medium = String.duplicate("word ", 300)
      complexity = Summarizer.assess_complexity(medium)
      assert complexity in [:simple, :moderate]

      # 500-1000 words
      long = String.duplicate("word ", 700)
      complexity = Summarizer.assess_complexity(long)
      assert complexity in [:moderate, :complex]
    end

    test "technical density affects complexity" do
      # Same length, different tech density
      plain = String.duplicate("the quick brown fox jumps ", 100)
      technical = String.duplicate("API database server client async ", 100)

      plain_complexity = Summarizer.assess_complexity(plain)
      tech_complexity = Summarizer.assess_complexity(technical)

      # Technical should be same or higher complexity
      complexity_order = [:simple, :moderate, :complex, :highly_complex]
      plain_idx = Enum.find_index(complexity_order, &(&1 == plain_complexity))
      tech_idx = Enum.find_index(complexity_order, &(&1 == tech_complexity))

      assert tech_idx >= plain_idx
    end
  end
end
