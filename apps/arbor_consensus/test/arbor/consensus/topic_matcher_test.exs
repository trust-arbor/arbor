defmodule Arbor.Consensus.TopicMatcherTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.{TopicMatcher, TopicRule}

  describe "match/3" do
    test "matches proposal to topic by description pattern" do
      topics = [
        TopicRule.new(
          topic: :security,
          match_patterns: ["security", "vulnerability", "audit"]
        ),
        TopicRule.new(
          topic: :capability,
          match_patterns: ["capability", "grant", "revoke", "permission"]
        ),
        TopicRule.new(
          topic: :general,
          match_patterns: []
        )
      ]

      {topic, confidence} = TopicMatcher.match("Security audit for authentication", %{}, topics)

      assert topic == :security
      assert confidence > 0.0
    end

    test "falls through to :general when no patterns match" do
      topics = [
        TopicRule.new(
          topic: :security,
          match_patterns: ["security", "vulnerability"]
        ),
        TopicRule.new(
          topic: :general,
          match_patterns: []
        )
      ]

      {topic, confidence} = TopicMatcher.match("Update README documentation", %{}, topics)

      assert topic == :general
      assert confidence == 0.0
    end

    test "multiple pattern matches increase confidence" do
      topics = [
        TopicRule.new(
          topic: :security,
          match_patterns: ["security", "vulnerability", "audit", "scan"]
        )
      ]

      # Single match
      {_topic1, conf1} = TopicMatcher.match("security check", %{}, topics)

      # Multiple matches
      {_topic2, conf2} = TopicMatcher.match("security audit and vulnerability scan", %{}, topics)

      assert conf2 > conf1
    end

    test "matches patterns in context values" do
      topics = [
        TopicRule.new(
          topic: :capability,
          match_patterns: ["capability", "grant", "permission"]
        )
      ]

      context = %{
        action: :grant,
        resource: "file_system_capability"
      }

      {topic, confidence} = TopicMatcher.match("Give access to files", context, topics)

      assert topic == :capability
      assert confidence > 0.0
    end

    test "matching is case-insensitive" do
      topics = [
        TopicRule.new(
          topic: :security,
          match_patterns: ["Security", "AUDIT"]
        )
      ]

      {topic, _confidence} = TopicMatcher.match("security AUDIT", %{}, topics)

      assert topic == :security
    end

    test "returns :general with empty topic list" do
      {topic, confidence} = TopicMatcher.match("Some proposal", %{}, [])

      assert topic == :general
      assert confidence == 0.0
    end

    test "returns :general with nil description" do
      topics = [
        TopicRule.new(topic: :security, match_patterns: ["security"])
      ]

      {topic, confidence} = TopicMatcher.match(nil, %{}, topics)

      assert topic == :general
      assert confidence == 0.0
    end

    test "handles special characters in description" do
      topics = [
        TopicRule.new(
          topic: :security,
          match_patterns: ["security"]
        )
      ]

      {topic, _confidence} = TopicMatcher.match("Fix security! (important)", %{}, topics)

      assert topic == :security
    end

    test "word boundary matching prevents partial matches" do
      topics = [
        TopicRule.new(
          topic: :capability,
          match_patterns: ["cap"]
        )
      ]

      # "cap" should not match inside "capability" (disable LLM to test pure pattern matching)
      {topic, confidence} =
        TopicMatcher.match("capability grant", %{}, topics, llm_enabled: false)

      assert topic == :general
      assert confidence == 0.0
    end

    test "returns best matching topic when multiple topics match" do
      topics = [
        TopicRule.new(
          topic: :security,
          match_patterns: ["security", "audit"]
        ),
        TopicRule.new(
          topic: :code_review,
          match_patterns: ["security", "code", "review"]
        )
      ]

      # Both topics have "security" pattern, but "code_review" has more matches
      {topic, _confidence} = TopicMatcher.match("security code review", %{}, topics)

      assert topic == :code_review
    end

    test "confidence is capped at 1.0" do
      topics = [
        TopicRule.new(
          topic: :security,
          match_patterns: ["a"]
        )
      ]

      # Many matches of single pattern
      {_topic, confidence} = TopicMatcher.match("a a a a a a a", %{}, topics)

      assert confidence <= 1.0
    end
  end

  describe "score_topic/3" do
    test "returns 0.0 for empty patterns" do
      rule = TopicRule.new(topic: :general, match_patterns: [])

      score = TopicMatcher.score_topic("some description", %{}, rule)

      assert score == 0.0
    end

    test "returns correct ratio for partial matches" do
      rule =
        TopicRule.new(
          topic: :test,
          match_patterns: ["one", "two", "three", "four"]
        )

      # 2 out of 4 patterns match = 0.5 base + 0.1 bonus = 0.6
      score = TopicMatcher.score_topic("one two", %{}, rule)

      assert score >= 0.5
      assert score <= 0.7
    end

    test "includes context in scoring" do
      rule =
        TopicRule.new(
          topic: :test,
          match_patterns: ["keyword"]
        )

      # Pattern in context, not description
      context = %{type: "keyword"}
      score = TopicMatcher.score_topic("no match here", context, rule)

      assert score > 0.0
    end

    test "handles nested context maps" do
      rule =
        TopicRule.new(
          topic: :test,
          match_patterns: ["nested"]
        )

      context = %{
        outer: %{
          inner: "nested value"
        }
      }

      score = TopicMatcher.score_topic("description", context, rule)

      assert score > 0.0
    end
  end
end
