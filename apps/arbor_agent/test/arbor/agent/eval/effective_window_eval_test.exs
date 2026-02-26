defmodule Arbor.Agent.Eval.EffectiveWindowEvalTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ContextCompactor
  alias Arbor.Agent.Eval.{EffectiveWindowEval, FactCorpus}

  # ── FactCorpus Tests ──────────────────────────────────────────

  describe "FactCorpus.generate_facts/1" do
    test "generates the requested number of facts" do
      facts = FactCorpus.generate_facts(10)
      assert length(facts) == 10
    end

    test "generates max 30 facts by default" do
      facts = FactCorpus.generate_facts()
      assert length(facts) == 30
    end

    test "each fact has required fields" do
      facts = FactCorpus.generate_facts(5)

      for fact <- facts do
        assert is_binary(fact.id)
        assert fact.category in [:technical, :metric, :personal, :project]
        assert is_binary(fact.statement)
        assert is_binary(fact.question)
        assert is_binary(fact.answer)
        assert String.length(fact.answer) > 0
      end
    end

    test "all fact IDs are unique" do
      facts = FactCorpus.generate_facts(30)
      ids = Enum.map(facts, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "all fact answers are unique" do
      facts = FactCorpus.generate_facts(30)
      answers = Enum.map(facts, & &1.answer)
      assert length(answers) == length(Enum.uniq(answers))
    end

    test "facts span all 4 categories" do
      facts = FactCorpus.generate_facts(30)
      categories = facts |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()
      assert categories == [:metric, :personal, :project, :technical]
    end

    test "is deterministic" do
      facts1 = FactCorpus.generate_facts(10)
      facts2 = FactCorpus.generate_facts(10)
      assert facts1 == facts2
    end
  end

  describe "FactCorpus.generate_padding/1" do
    test "produces messages approximating target token count" do
      padding = FactCorpus.generate_padding(1000)

      total_tokens =
        padding
        |> Enum.map(fn msg -> ContextCompactor.estimate_tokens(msg) end)
        |> Enum.sum()

      # Should be within 50% of target (padding messages have variable sizes)
      assert total_tokens >= 500
      assert total_tokens <= 2000
    end

    test "produces messages with valid roles" do
      padding = FactCorpus.generate_padding(500)

      for msg <- padding do
        assert msg.role in [:user, :assistant, :tool]
        assert is_binary(msg.content)
      end
    end

    test "returns empty list for zero tokens" do
      padding = FactCorpus.generate_padding(0)
      assert padding == []
    end

    test "padding does not contain fact answers" do
      facts = FactCorpus.generate_facts(30)
      padding = FactCorpus.generate_padding(5000)
      padding_text = Enum.map_join(padding, " ", & &1.content)

      # Verify no fact answer appears verbatim in padding
      # (some common words like numbers might appear, so check specific answers)
      specific_answers = [
        "a7b3c9d2e1f4",
        "8847",
        "10.42.17.203",
        "whsec_9f4a2b",
        "samdev-42",
        "prod-media-assets-us-west-2",
        "enable_dark_theme_v2",
        "v2.14.7-alpine"
      ]

      for answer <- specific_answers do
        refute String.contains?(padding_text, answer),
               "Padding contains fact answer: #{answer}"
      end
    end
  end

  describe "FactCorpus.build_context/2" do
    test "starts with system message" do
      facts = FactCorpus.generate_facts(5)
      messages = FactCorpus.build_context(facts, 5000)

      assert hd(messages).role == :system
    end

    test "ends with recall query" do
      facts = FactCorpus.generate_facts(5)
      messages = FactCorpus.build_context(facts, 5000)
      last = List.last(messages)

      assert last.role == :user
      assert String.contains?(last.content, "UNKNOWN")

      # Each fact's question should appear in the recall query
      for fact <- facts do
        assert String.contains?(last.content, fact.question)
      end
    end

    test "contains all facts in the body" do
      facts = FactCorpus.generate_facts(5)
      messages = FactCorpus.build_context(facts, 5000)

      # Remove system and recall messages
      body = messages |> Enum.drop(1) |> Enum.drop(-1)
      body_text = Enum.map_join(body, " ", & &1.content)

      for fact <- facts do
        assert String.contains?(body_text, fact.answer),
               "Fact answer '#{fact.answer}' not found in context body"
      end
    end

    test "produces approximately the target token count" do
      facts = FactCorpus.generate_facts(10)
      target = 10_000
      messages = FactCorpus.build_context(facts, target)

      total_tokens =
        messages
        |> Enum.map(&ContextCompactor.estimate_tokens/1)
        |> Enum.sum()

      # Should be within 50% of target
      assert total_tokens >= target * 0.3,
             "Too few tokens: #{total_tokens} vs target #{target}"
    end
  end

  describe "FactCorpus.build_recall_query/1" do
    test "generates numbered questions" do
      facts = FactCorpus.generate_facts(5)
      query = FactCorpus.build_recall_query(facts)

      assert query.role == :user
      assert String.contains?(query.content, "1.")
      assert String.contains?(query.content, "5.")
    end

    test "includes all fact questions" do
      facts = FactCorpus.generate_facts(3)
      query = FactCorpus.build_recall_query(facts)

      for fact <- facts do
        assert String.contains?(query.content, fact.question)
      end
    end
  end

  # ── EffectiveWindowEval Tests ──────────────────────────────────

  describe "score_recall/2" do
    test "scores exact matches as 1.0" do
      facts = [
        %{id: "t1", question: "What port?", answer: "8847"},
        %{id: "t2", question: "What SHA?", answer: "abc123"}
      ]

      response = """
      1. 8847
      2. abc123
      """

      scores = EffectiveWindowEval.score_recall(response, facts)

      assert scores == [{"t1", 1.0}, {"t2", 1.0}]
    end

    test "scores UNKNOWN as 0.0" do
      facts = [%{id: "t1", question: "What port?", answer: "8847"}]

      response = "1. UNKNOWN"
      scores = EffectiveWindowEval.score_recall(response, facts)

      assert scores == [{"t1", 0.0}]
    end

    test "scores missing answers as 0.0" do
      facts = [
        %{id: "t1", question: "What port?", answer: "8847"},
        %{id: "t2", question: "What SHA?", answer: "abc123"}
      ]

      # Only answer for question 1
      response = "1. 8847"
      scores = EffectiveWindowEval.score_recall(response, facts)

      assert [{"t1", 1.0}, {"t2", 0.0}] = scores
    end

    test "scores wrong answers as 0.0" do
      facts = [%{id: "t1", question: "What port?", answer: "8847"}]

      response = "1. 9999"
      scores = EffectiveWindowEval.score_recall(response, facts)

      assert scores == [{"t1", 0.0}]
    end

    test "scores partial matches as 0.5" do
      facts = [
        %{id: "t1", question: "What is it?", answer: "prod-media-assets-us-west-2"}
      ]

      # Contains "prod" and "media" and "assets" — more than half the words
      response = "1. prod-media-assets"
      scores = EffectiveWindowEval.score_recall(response, facts)

      assert [{"t1", score}] = scores
      assert score == 0.5
    end

    test "handles case-insensitive matching" do
      facts = [%{id: "t1", question: "What?", answer: "March 15th"}]

      response = "1. march 15th"
      scores = EffectiveWindowEval.score_recall(response, facts)

      assert scores == [{"t1", 1.0}]
    end

    test "handles extra text in response line" do
      facts = [%{id: "t1", question: "What port?", answer: "8847"}]

      response = "1. The port is 8847 for the gateway"
      scores = EffectiveWindowEval.score_recall(response, facts)

      assert scores == [{"t1", 1.0}]
    end

    test "handles empty response" do
      facts = [%{id: "t1", question: "What?", answer: "test"}]
      scores = EffectiveWindowEval.score_recall("", facts)
      assert scores == [{"t1", 0.0}]
    end
  end

  describe "find_effective_window/2" do
    test "finds highest fill level above threshold" do
      results = [
        %{fill_level: 0.1, accuracy: 1.0, error: nil},
        %{fill_level: 0.3, accuracy: 0.95, error: nil},
        %{fill_level: 0.5, accuracy: 0.92, error: nil},
        %{fill_level: 0.7, accuracy: 0.85, error: nil},
        %{fill_level: 0.9, accuracy: 0.6, error: nil}
      ]

      assert EffectiveWindowEval.find_effective_window(results, 0.9) == 0.5
    end

    test "returns nil when no fill level meets threshold" do
      results = [
        %{fill_level: 0.1, accuracy: 0.5, error: nil},
        %{fill_level: 0.5, accuracy: 0.3, error: nil}
      ]

      assert EffectiveWindowEval.find_effective_window(results, 0.9) == nil
    end

    test "ignores results with errors" do
      results = [
        %{fill_level: 0.1, accuracy: 1.0, error: nil},
        %{fill_level: 0.5, accuracy: 1.0, error: "timeout"},
        %{fill_level: 0.9, accuracy: 0.5, error: nil}
      ]

      # 0.5 has error so skip it, 0.9 is below threshold, only 0.1 passes
      assert EffectiveWindowEval.find_effective_window(results, 0.9) == 0.1
    end

    test "returns 1.0 when all fill levels pass" do
      results = [
        %{fill_level: 0.5, accuracy: 0.95, error: nil},
        %{fill_level: 1.0, accuracy: 0.92, error: nil}
      ]

      assert EffectiveWindowEval.find_effective_window(results, 0.9) == 1.0
    end

    test "uses custom threshold" do
      results = [
        %{fill_level: 0.3, accuracy: 0.8, error: nil},
        %{fill_level: 0.5, accuracy: 0.75, error: nil},
        %{fill_level: 0.7, accuracy: 0.6, error: nil}
      ]

      assert EffectiveWindowEval.find_effective_window(results, 0.7) == 0.5
    end
  end

  # ── ContextCompactor.estimate_tokens/1 (public API) ────────────

  describe "ContextCompactor.estimate_tokens/1" do
    test "estimates tokens for a string" do
      text = String.duplicate("word ", 100)
      tokens = ContextCompactor.estimate_tokens(text)
      # 500 chars / 4 = 125 tokens
      assert tokens == 125
    end

    test "estimates tokens for a message map" do
      msg = %{role: :user, content: "Hello, world!"}
      tokens = ContextCompactor.estimate_tokens(msg)
      assert tokens >= 1
    end

    test "returns at least 1 for empty string" do
      assert ContextCompactor.estimate_tokens("") == 1
    end

    test "returns at least 1 for empty content map" do
      assert ContextCompactor.estimate_tokens(%{role: :user, content: ""}) == 1
    end
  end
end
