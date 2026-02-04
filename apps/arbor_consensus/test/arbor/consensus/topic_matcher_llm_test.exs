defmodule Arbor.Consensus.TopicMatcherLlmTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.TopicMatcher
  alias Arbor.Consensus.TopicRule

  # ============================================================================
  # Mock AI modules for testing
  # ============================================================================

  defmodule MockAI do
    @moduledoc false
    def generate_text(_prompt, _opts) do
      {:ok,
       %{
         text:
           Jason.encode!(%{
             "topic" => "security_review",
             "confidence" => 0.9,
             "reasoning" => "Proposal mentions security audit and vulnerability assessment"
           }),
         model: "mock-model",
         provider: :mock,
         usage: %{input_tokens: 50, output_tokens: 30}
       }}
    end
  end

  defmodule LowConfidenceAI do
    @moduledoc false
    def generate_text(_prompt, _opts) do
      {:ok,
       %{
         text:
           Jason.encode!(%{
             "topic" => "security_review",
             "confidence" => 0.3,
             "reasoning" => "Not very confident"
           }),
         model: "mock-model",
         provider: :mock,
         usage: %{}
       }}
    end
  end

  defmodule ErrorAI do
    @moduledoc false
    def generate_text(_prompt, _opts) do
      {:error, :api_error}
    end
  end

  defmodule GarbageResponseAI do
    @moduledoc false
    def generate_text(_prompt, _opts) do
      {:ok,
       %{
         text: "I don't know what topic to pick, sorry!",
         model: "mock-model",
         provider: :mock,
         usage: %{}
       }}
    end
  end

  defmodule UnknownTopicAI do
    @moduledoc false
    def generate_text(_prompt, _opts) do
      {:ok,
       %{
         text:
           Jason.encode!(%{
             "topic" => "nonexistent_topic",
             "confidence" => 0.95,
             "reasoning" => "Made up topic"
           }),
         model: "mock-model",
         provider: :mock,
         usage: %{}
       }}
    end
  end

  defmodule CrashingAI do
    @moduledoc false
    def generate_text(_prompt, _opts) do
      raise "LLM service crashed!"
    end
  end

  # ============================================================================
  # Test helpers
  # ============================================================================

  defp test_topics do
    [
      %TopicRule{
        topic: :security_review,
        match_patterns: ["security", "vulnerability", "audit", "threat"],
        min_quorum: :supermajority
      },
      %TopicRule{
        topic: :code_modification,
        match_patterns: ["code", "refactor", "function", "module"],
        min_quorum: :majority
      },
      %TopicRule{
        topic: :general,
        match_patterns: []
      }
    ]
  end

  # ============================================================================
  # Tests: LLM classification disabled
  # ============================================================================

  describe "match/4 with llm_enabled: false" do
    test "returns pattern match result when above threshold" do
      topics = test_topics()

      # 4/4 patterns match = 1.0 confidence
      result =
        TopicMatcher.match(
          "Security vulnerability audit threat assessment",
          %{},
          topics,
          llm_enabled: false
        )

      assert {matched_topic, confidence} = result
      assert matched_topic == :security_review
      assert confidence >= 0.8
    end

    test "returns best pattern match when below threshold, no LLM fallback" do
      topics = test_topics()

      # Only 1/4 patterns match = 0.25 confidence
      result =
        TopicMatcher.match(
          "Review the security policy",
          %{},
          topics,
          llm_enabled: false
        )

      assert {matched_topic, confidence} = result
      assert matched_topic == :security_review
      assert confidence < 0.8
    end

    test "returns :general when no patterns match" do
      topics = test_topics()

      result =
        TopicMatcher.match(
          "Update the documentation for deployment",
          %{},
          topics,
          llm_enabled: false
        )

      assert {:general, confidence} = result
      assert confidence == 0.0
    end
  end

  # ============================================================================
  # Tests: LLM classification enabled (with mocks)
  # ============================================================================

  describe "match/4 with LLM classification" do
    test "uses LLM when pattern match is below threshold" do
      topics = test_topics()

      # Only 1/4 patterns match, so LLM is triggered
      result =
        TopicMatcher.match(
          "Assess potential weaknesses in the authentication system",
          %{},
          topics,
          llm_enabled: true,
          ai_module: MockAI
        )

      # MockAI returns security_review with 0.9 confidence
      assert {:security_review, 0.9} = result
    end

    test "does not use LLM when pattern match is above threshold" do
      topics = test_topics()

      # 4/4 patterns match = high confidence
      result =
        TopicMatcher.match(
          "Security vulnerability audit threat assessment",
          %{},
          topics,
          llm_enabled: true,
          ai_module: ErrorAI
        )

      # ErrorAI would fail, but LLM shouldn't be called
      assert {matched_topic, confidence} = result
      assert matched_topic == :security_review
      assert confidence >= 0.8
    end

    test "falls back to pattern result when LLM returns low confidence" do
      topics = test_topics()

      result =
        TopicMatcher.match(
          "Review the security policy",
          %{},
          topics,
          llm_enabled: true,
          ai_module: LowConfidenceAI
        )

      # LowConfidenceAI returns 0.3, so we fall back to best pattern match
      assert {matched_topic, confidence} = result
      assert matched_topic == :security_review
      assert confidence < 0.8
    end

    test "falls back to pattern result when LLM errors" do
      topics = test_topics()

      result =
        TopicMatcher.match(
          "Review the security policy",
          %{},
          topics,
          llm_enabled: true,
          ai_module: ErrorAI
        )

      assert {matched_topic, confidence} = result
      assert matched_topic == :security_review
      assert confidence < 0.8
    end

    test "falls back to :general when LLM errors and no pattern match" do
      topics = test_topics()

      result =
        TopicMatcher.match(
          "Upgrade the deployment infrastructure",
          %{},
          topics,
          llm_enabled: true,
          ai_module: ErrorAI
        )

      assert {:general, confidence} = result
      assert confidence == 0.0
    end

    test "handles garbage LLM response gracefully" do
      topics = test_topics()

      result =
        TopicMatcher.match(
          "Improve the login flow security measures",
          %{},
          topics,
          llm_enabled: true,
          ai_module: GarbageResponseAI
        )

      # Should fall back to pattern match
      assert {_topic, _confidence} = result
    end

    test "rejects LLM classification to unknown topic" do
      topics = test_topics()

      result =
        TopicMatcher.match(
          "Update the deployment pipeline",
          %{},
          topics,
          llm_enabled: true,
          ai_module: UnknownTopicAI
        )

      # UnknownTopicAI returns a topic not in the list, should fall back
      assert {:general, confidence} = result
      assert confidence == 0.0
    end

    test "handles LLM crash gracefully" do
      topics = test_topics()

      result =
        TopicMatcher.match(
          "Update the deployment pipeline",
          %{},
          topics,
          llm_enabled: true,
          ai_module: CrashingAI
        )

      assert {:general, confidence} = result
      assert confidence == 0.0
    end
  end

  # ============================================================================
  # Tests: backward compatibility (match/3)
  # ============================================================================

  describe "match/3 backward compatibility" do
    test "works without opts (defaults to LLM disabled in test)" do
      topics = test_topics()

      # In test env, Arbor.AI is not loaded, so llm_available? returns false
      result = TopicMatcher.match("Security audit for all components", %{}, topics)

      assert {_topic, _confidence} = result
    end

    test "handles empty topics list" do
      result = TopicMatcher.match("Something", %{}, [])
      assert {:general, confidence} = result
      assert confidence == 0.0
    end

    test "handles non-string description" do
      result = TopicMatcher.match(nil, %{}, test_topics())
      assert {:general, confidence} = result
      assert confidence == 0.0
    end
  end

  # ============================================================================
  # Tests: context matching still works with LLM
  # ============================================================================

  describe "context-based matching with LLM" do
    test "uses context for pattern matching before LLM" do
      topics = test_topics()

      # Context provides enough signal for pattern matching
      result =
        TopicMatcher.match(
          "Update the component",
          %{type: "security", category: "vulnerability"},
          topics,
          llm_enabled: false
        )

      assert {_topic, confidence} = result
      assert confidence > 0.0
    end
  end
end
