defmodule Arbor.Memory.FactExtractorTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.FactExtractor

  @moduletag :fast

  describe "extract/2 - person facts (regex)" do
    test "extracts name from 'my name is X'" do
      facts = FactExtractor.extract("My name is Alice", method: :regex)

      assert facts != []
      name_fact = Enum.find(facts, &(&1.category == :person))
      assert name_fact.content =~ "Alice"
      assert name_fact.confidence >= 0.8
    end

    test "extracts name from 'I am X'" do
      facts = FactExtractor.extract("I am Bob Smith", method: :regex)

      name_fact = Enum.find(facts, &(&1.category == :person))
      assert name_fact != nil
      assert name_fact.content =~ "Bob"
    end

    test "extracts employer from 'I work at X'" do
      facts = FactExtractor.extract("I work at Acme Corporation", method: :regex)

      employer_fact = Enum.find(facts, &(&1.content =~ "Works at"))
      assert employer_fact != nil
      assert employer_fact.content =~ "Acme"
      assert employer_fact.category == :person
    end

    test "extracts role from 'I am a X'" do
      facts = FactExtractor.extract("I'm a senior software engineer", method: :regex)

      role_fact = Enum.find(facts, &(&1.content =~ "Role"))
      assert role_fact != nil
      assert role_fact.content =~ "software engineer"
    end

    test "extracts location from 'I live in X'" do
      facts = FactExtractor.extract("I live in San Francisco, California", method: :regex)

      location_fact = Enum.find(facts, &(&1.content =~ "Located"))
      assert location_fact != nil
      assert location_fact.content =~ "San Francisco"
    end
  end

  describe "extract/2 - project facts (regex)" do
    test "extracts current project from 'working on X'" do
      facts = FactExtractor.extract("I'm working on a new authentication system", method: :regex)

      project_fact = Enum.find(facts, &(&1.category == :project))
      assert project_fact != nil
      assert project_fact.content =~ "authentication"
    end

    test "extracts project name from 'the project is X'" do
      facts = FactExtractor.extract("The project is called Arbor", method: :regex)

      project_fact = Enum.find(facts, &(&1.content =~ "Project"))
      assert project_fact != nil
      assert project_fact.content =~ "Arbor"
    end

    test "extracts project type from 'building a X'" do
      facts = FactExtractor.extract("We are building a distributed system", method: :regex)

      project_fact = Enum.find(facts, &(&1.category == :project))
      assert project_fact != nil
    end
  end

  describe "extract/2 - technical facts (regex)" do
    test "extracts technology from 'using X'" do
      facts = FactExtractor.extract("We are using Elixir for the backend", method: :regex)

      tech_fact = Enum.find(facts, &(&1.category == :technical))
      assert tech_fact != nil
      assert tech_fact.content =~ "Elixir"
    end

    test "extracts database" do
      facts = FactExtractor.extract("The app uses PostgreSQL for persistence", method: :regex)

      db_fact = Enum.find(facts, &(&1.content =~ "Database"))
      assert db_fact != nil
      assert db_fact.content =~ "PostgreSQL"
    end

    test "extracts framework" do
      facts = FactExtractor.extract("Built with Phoenix and LiveView", method: :regex)

      framework_fact = Enum.find(facts, &(&1.content =~ "Framework"))
      assert framework_fact != nil
      assert framework_fact.content =~ "Phoenix"
    end

    test "extracts dependencies" do
      facts = FactExtractor.extract("The project depends on ecto", method: :regex)

      dep_fact = Enum.find(facts, &(&1.content =~ "Depends on"))
      assert dep_fact != nil
      assert dep_fact.content =~ "ecto"
    end
  end

  describe "extract/2 - preference facts (regex)" do
    test "extracts likes" do
      facts = FactExtractor.extract("I prefer functional programming over OOP", method: :regex)

      pref_fact = Enum.find(facts, &(&1.category == :preference))
      assert pref_fact != nil
      assert pref_fact.content =~ "Likes"
    end

    test "extracts dislikes" do
      facts = FactExtractor.extract("I don't like writing boilerplate code", method: :regex)

      pref_fact = Enum.find(facts, &(&1.content =~ "Dislikes"))
      assert pref_fact != nil
    end

    test "extracts favorites" do
      facts = FactExtractor.extract("My favorite language is Elixir", method: :regex)

      fav_fact = Enum.find(facts, &(&1.content =~ "Favorite"))
      assert fav_fact != nil
      assert fav_fact.content =~ "Elixir"
    end
  end

  describe "extract/2 - relationship facts (regex)" do
    test "extracts personal relationship" do
      facts = FactExtractor.extract("Alice is my colleague", method: :regex)

      rel_fact = Enum.find(facts, &(&1.category == :relationship))
      assert rel_fact != nil
      assert rel_fact.content =~ "Alice"
    end

    test "extracts acquaintance" do
      facts = FactExtractor.extract("I know Bob from the conference", method: :regex)

      rel_fact = Enum.find(facts, &(&1.content =~ "Knows"))
      assert rel_fact != nil
      assert rel_fact.content =~ "Bob"
    end

    test "extracts named relationship" do
      facts = FactExtractor.extract("My friend Charlie helped me", method: :regex)

      rel_fact = Enum.find(facts, &(&1.content =~ "Friend"))
      assert rel_fact != nil
    end
  end

  describe "extract/2 - options (regex)" do
    test "filters by categories" do
      text = "My name is Alice and I work at Acme using Elixir"

      person_only = FactExtractor.extract(text, method: :regex, categories: [:person])
      tech_only = FactExtractor.extract(text, method: :regex, categories: [:technical])

      assert Enum.all?(person_only, &(&1.category == :person))
      assert Enum.all?(tech_only, &(&1.category == :technical))
    end

    test "filters by min_confidence" do
      facts = FactExtractor.extract("I think maybe I work somewhere", method: :regex, min_confidence: 0.8)

      assert Enum.all?(facts, &(&1.confidence >= 0.8))
    end

    test "sets custom source" do
      facts = FactExtractor.extract("My name is Alice", method: :regex, source: "conversation_123")

      assert Enum.all?(facts, &(&1.source == "conversation_123"))
    end
  end

  describe "extract_batch/2 (regex)" do
    test "extracts from multiple texts" do
      texts = [
        "My name is Alice",
        "I work at Acme",
        "We use Elixir"
      ]

      facts = FactExtractor.extract_batch(texts, method: :regex)

      assert length(facts) >= 3
      sources = Enum.map(facts, & &1.source) |> Enum.uniq()
      assert "text_1" in sources
      assert "text_2" in sources
      assert "text_3" in sources
    end

    test "accepts custom source prefix" do
      texts = ["My name is Alice", "I work at Acme"]
      facts = FactExtractor.extract_batch(texts, method: :regex, source_prefix: "msg")

      sources = Enum.map(facts, & &1.source) |> Enum.uniq()
      assert "msg_1" in sources
    end

    test "deduplicates across texts" do
      texts = [
        "My name is Alice",
        "My name is Alice"
      ]

      facts = FactExtractor.extract_batch(texts, method: :regex)
      contents = Enum.map(facts, & &1.content)
      unique_contents = Enum.uniq(contents)

      assert length(contents) == length(unique_contents)
    end
  end

  describe "categories/0" do
    test "returns all available categories" do
      categories = FactExtractor.categories()

      assert :person in categories
      assert :project in categories
      assert :technical in categories
      assert :preference in categories
      assert :relationship in categories
    end
  end

  describe "count_by_category/1" do
    test "counts facts by category" do
      facts = [
        %{category: :person, content: "A", confidence: 0.9, source: "x", entities: []},
        %{category: :person, content: "B", confidence: 0.9, source: "x", entities: []},
        %{category: :technical, content: "C", confidence: 0.9, source: "x", entities: []}
      ]

      counts = FactExtractor.count_by_category(facts)

      assert counts[:person] == 2
      assert counts[:technical] == 1
    end
  end

  describe "filter_by_confidence/2" do
    test "filters facts above threshold" do
      facts = [
        %{category: :person, content: "A", confidence: 0.9, source: "x", entities: []},
        %{category: :person, content: "B", confidence: 0.5, source: "x", entities: []},
        %{category: :person, content: "C", confidence: 0.7, source: "x", entities: []}
      ]

      filtered = FactExtractor.filter_by_confidence(facts, 0.6)

      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.confidence >= 0.6))
    end
  end

  describe "entity extraction" do
    test "extracts entities from facts" do
      facts = FactExtractor.extract("My name is Alice and I work at Acme Corp")

      # Find a fact with entities
      fact_with_entities = Enum.find(facts, &(&1.entities != []))
      assert fact_with_entities != nil
      assert is_list(fact_with_entities.entities)
    end
  end

  describe "edge cases (regex)" do
    test "handles empty text" do
      facts = FactExtractor.extract("", method: :regex)
      assert facts == []
    end

    test "handles text with no matches" do
      facts = FactExtractor.extract("Just some random text without patterns", method: :regex)
      # May or may not have matches depending on patterns
      assert is_list(facts)
    end

    test "handles special characters" do
      facts = FactExtractor.extract("I work at Acme & Co. LLC", method: :regex)
      # Should handle & and punctuation
      assert is_list(facts)
    end
  end

  # ============================================================================
  # Method Dispatch Tests
  # ============================================================================

  describe "extract/2 - method dispatch" do
    test "method: :regex uses regex extraction" do
      facts = FactExtractor.extract("My name is Alice", method: :regex)
      assert facts != []
      name_fact = Enum.find(facts, &(&1.category == :person))
      assert name_fact.content =~ "Alice"
    end

    test "method: :auto falls back to regex when LLM unavailable" do
      # In test env, LLM is typically not available
      facts = FactExtractor.extract("My name is Bob", method: :auto)
      assert is_list(facts)
    end

    test "method: :regex respects categories filter" do
      facts = FactExtractor.extract(
        "My name is Alice and I use Elixir",
        method: :regex,
        categories: [:technical]
      )
      assert Enum.all?(facts, &(&1.category == :technical))
    end
  end

  # ============================================================================
  # LLM Parsing Tests
  # ============================================================================

  describe "parse_llm_facts/2" do
    test "parses valid JSON array" do
      json = ~s([{"content": "User prefers Elixir", "category": "preference", "entities": ["Elixir"], "confidence": 0.9}])
      facts = FactExtractor.parse_llm_facts(json, "test")

      assert length(facts) == 1
      fact = hd(facts)
      assert fact.content == "User prefers Elixir"
      assert fact.category == :preference
      assert fact.entities == ["Elixir"]
      assert fact.confidence == 0.9
      assert fact.source == "test"
    end

    test "parses markdown-wrapped JSON" do
      json = """
      ```json
      [{"content": "Uses PostgreSQL database", "category": "technical", "entities": ["PostgreSQL"], "confidence": 0.85}]
      ```
      """
      facts = FactExtractor.parse_llm_facts(json)

      assert length(facts) == 1
      assert hd(facts).category == :technical
    end

    test "returns empty for invalid JSON" do
      facts = FactExtractor.parse_llm_facts("not json at all")
      assert facts == []
    end

    test "returns empty for non-array JSON" do
      facts = FactExtractor.parse_llm_facts(~s({"key": "value"}))
      assert facts == []
    end

    test "filters out facts with content too short" do
      json = ~s([{"content": "short", "category": "technical", "confidence": 0.9}])
      facts = FactExtractor.parse_llm_facts(json)
      assert facts == []
    end

    test "handles missing fields gracefully" do
      json = ~s([{"content": "This is a valid fact with enough content"}])
      facts = FactExtractor.parse_llm_facts(json)

      assert length(facts) == 1
      fact = hd(facts)
      assert fact.category == :technical  # default
      assert fact.confidence == 0.5  # default
      assert fact.entities == []  # default
    end

    test "parses all valid categories" do
      json = ~s([
        {"content": "Person fact with enough content", "category": "person", "confidence": 0.8},
        {"content": "Project fact with enough content", "category": "project", "confidence": 0.8},
        {"content": "Technical fact with enough content", "category": "technical", "confidence": 0.8},
        {"content": "Preference fact with enough content", "category": "preference", "confidence": 0.8},
        {"content": "Relationship fact with enough content", "category": "relationship", "confidence": 0.8}
      ])
      facts = FactExtractor.parse_llm_facts(json)

      categories = Enum.map(facts, & &1.category) |> Enum.sort()
      assert categories == [:person, :preference, :project, :relationship, :technical]
    end

    test "clamps confidence to 0.0-1.0 range" do
      json = ~s([{"content": "Fact with out of range confidence", "category": "technical", "confidence": 1.5}])
      facts = FactExtractor.parse_llm_facts(json)
      assert hd(facts).confidence == 1.0
    end
  end

  # ============================================================================
  # Format Messages Tests
  # ============================================================================

  describe "format_messages_for_extraction/1" do
    test "formats user and assistant messages" do
      messages = [
        %{role: :user, content: "Hello, I'm Alice"},
        %{role: :assistant, content: "Nice to meet you, Alice!"}
      ]

      formatted = FactExtractor.format_messages_for_extraction(messages)
      assert formatted =~ "Human: Hello, I'm Alice"
      assert formatted =~ "Assistant: Nice to meet you"
    end

    test "uses speaker name when available" do
      messages = [
        %{role: :user, content: "Hello", speaker: "Hysun"}
      ]

      formatted = FactExtractor.format_messages_for_extraction(messages)
      assert formatted =~ "Hysun: Hello"
    end

    test "handles string keys" do
      messages = [
        %{"role" => "user", "content" => "Hello from string keys"}
      ]

      formatted = FactExtractor.format_messages_for_extraction(messages)
      assert formatted =~ "Hello from string keys"
    end

    test "truncates long content" do
      long_content = String.duplicate("a", 2000)
      messages = [%{role: :user, content: long_content}]

      formatted = FactExtractor.format_messages_for_extraction(messages)
      assert String.length(formatted) < 2000
      assert formatted =~ "..."
    end
  end

  describe "llm_available?/0" do
    test "returns a boolean" do
      result = FactExtractor.llm_available?()
      assert is_boolean(result)
    end
  end
end
