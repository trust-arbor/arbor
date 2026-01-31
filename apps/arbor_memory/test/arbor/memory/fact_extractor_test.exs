defmodule Arbor.Memory.FactExtractorTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.FactExtractor

  @moduletag :fast

  describe "extract/2 - person facts" do
    test "extracts name from 'my name is X'" do
      facts = FactExtractor.extract("My name is Alice")

      assert length(facts) >= 1
      name_fact = Enum.find(facts, &(&1.category == :person))
      assert name_fact.content =~ "Alice"
      assert name_fact.confidence >= 0.8
    end

    test "extracts name from 'I am X'" do
      facts = FactExtractor.extract("I am Bob Smith")

      name_fact = Enum.find(facts, &(&1.category == :person))
      assert name_fact != nil
      assert name_fact.content =~ "Bob"
    end

    test "extracts employer from 'I work at X'" do
      facts = FactExtractor.extract("I work at Acme Corporation")

      employer_fact = Enum.find(facts, &(&1.content =~ "Works at"))
      assert employer_fact != nil
      assert employer_fact.content =~ "Acme"
      assert employer_fact.category == :person
    end

    test "extracts role from 'I am a X'" do
      facts = FactExtractor.extract("I'm a senior software engineer")

      role_fact = Enum.find(facts, &(&1.content =~ "Role"))
      assert role_fact != nil
      assert role_fact.content =~ "software engineer"
    end

    test "extracts location from 'I live in X'" do
      facts = FactExtractor.extract("I live in San Francisco, California")

      location_fact = Enum.find(facts, &(&1.content =~ "Located"))
      assert location_fact != nil
      assert location_fact.content =~ "San Francisco"
    end
  end

  describe "extract/2 - project facts" do
    test "extracts current project from 'working on X'" do
      facts = FactExtractor.extract("I'm working on a new authentication system")

      project_fact = Enum.find(facts, &(&1.category == :project))
      assert project_fact != nil
      assert project_fact.content =~ "authentication"
    end

    test "extracts project name from 'the project is X'" do
      facts = FactExtractor.extract("The project is called Arbor")

      project_fact = Enum.find(facts, &(&1.content =~ "Project"))
      assert project_fact != nil
      assert project_fact.content =~ "Arbor"
    end

    test "extracts project type from 'building a X'" do
      facts = FactExtractor.extract("We are building a distributed system")

      project_fact = Enum.find(facts, &(&1.category == :project))
      assert project_fact != nil
    end
  end

  describe "extract/2 - technical facts" do
    test "extracts technology from 'using X'" do
      facts = FactExtractor.extract("We are using Elixir for the backend")

      tech_fact = Enum.find(facts, &(&1.category == :technical))
      assert tech_fact != nil
      assert tech_fact.content =~ "Elixir"
    end

    test "extracts database" do
      facts = FactExtractor.extract("The app uses PostgreSQL for persistence")

      db_fact = Enum.find(facts, &(&1.content =~ "Database"))
      assert db_fact != nil
      assert db_fact.content =~ "PostgreSQL"
    end

    test "extracts framework" do
      facts = FactExtractor.extract("Built with Phoenix and LiveView")

      framework_fact = Enum.find(facts, &(&1.content =~ "Framework"))
      assert framework_fact != nil
      assert framework_fact.content =~ "Phoenix"
    end

    test "extracts dependencies" do
      facts = FactExtractor.extract("The project depends on ecto")

      dep_fact = Enum.find(facts, &(&1.content =~ "Depends on"))
      assert dep_fact != nil
      assert dep_fact.content =~ "ecto"
    end
  end

  describe "extract/2 - preference facts" do
    test "extracts likes" do
      facts = FactExtractor.extract("I prefer functional programming over OOP")

      pref_fact = Enum.find(facts, &(&1.category == :preference))
      assert pref_fact != nil
      assert pref_fact.content =~ "Likes"
    end

    test "extracts dislikes" do
      facts = FactExtractor.extract("I don't like writing boilerplate code")

      pref_fact = Enum.find(facts, &(&1.content =~ "Dislikes"))
      assert pref_fact != nil
    end

    test "extracts favorites" do
      facts = FactExtractor.extract("My favorite language is Elixir")

      fav_fact = Enum.find(facts, &(&1.content =~ "Favorite"))
      assert fav_fact != nil
      assert fav_fact.content =~ "Elixir"
    end
  end

  describe "extract/2 - relationship facts" do
    test "extracts personal relationship" do
      facts = FactExtractor.extract("Alice is my colleague")

      rel_fact = Enum.find(facts, &(&1.category == :relationship))
      assert rel_fact != nil
      assert rel_fact.content =~ "Alice"
    end

    test "extracts acquaintance" do
      facts = FactExtractor.extract("I know Bob from the conference")

      rel_fact = Enum.find(facts, &(&1.content =~ "Knows"))
      assert rel_fact != nil
      assert rel_fact.content =~ "Bob"
    end

    test "extracts named relationship" do
      facts = FactExtractor.extract("My friend Charlie helped me")

      rel_fact = Enum.find(facts, &(&1.content =~ "Friend"))
      assert rel_fact != nil
    end
  end

  describe "extract/2 - options" do
    test "filters by categories" do
      text = "My name is Alice and I work at Acme using Elixir"

      person_only = FactExtractor.extract(text, categories: [:person])
      tech_only = FactExtractor.extract(text, categories: [:technical])

      assert Enum.all?(person_only, &(&1.category == :person))
      assert Enum.all?(tech_only, &(&1.category == :technical))
    end

    test "filters by min_confidence" do
      facts = FactExtractor.extract("I think maybe I work somewhere", min_confidence: 0.8)

      assert Enum.all?(facts, &(&1.confidence >= 0.8))
    end

    test "sets custom source" do
      facts = FactExtractor.extract("My name is Alice", source: "conversation_123")

      assert Enum.all?(facts, &(&1.source == "conversation_123"))
    end
  end

  describe "extract_batch/2" do
    test "extracts from multiple texts" do
      texts = [
        "My name is Alice",
        "I work at Acme",
        "We use Elixir"
      ]

      facts = FactExtractor.extract_batch(texts)

      assert length(facts) >= 3
      sources = Enum.map(facts, & &1.source) |> Enum.uniq()
      assert "text_1" in sources
      assert "text_2" in sources
      assert "text_3" in sources
    end

    test "accepts custom source prefix" do
      texts = ["My name is Alice", "I work at Acme"]
      facts = FactExtractor.extract_batch(texts, source_prefix: "msg")

      sources = Enum.map(facts, & &1.source) |> Enum.uniq()
      assert "msg_1" in sources
    end

    test "deduplicates across texts" do
      texts = [
        "My name is Alice",
        "My name is Alice"
      ]

      facts = FactExtractor.extract_batch(texts)
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
      fact_with_entities = Enum.find(facts, &(length(&1.entities) > 0))
      assert fact_with_entities != nil
      assert is_list(fact_with_entities.entities)
    end
  end

  describe "edge cases" do
    test "handles empty text" do
      facts = FactExtractor.extract("")
      assert facts == []
    end

    test "handles text with no matches" do
      facts = FactExtractor.extract("Just some random text without patterns")
      # May or may not have matches depending on patterns
      assert is_list(facts)
    end

    test "handles special characters" do
      facts = FactExtractor.extract("I work at Acme & Co. LLC")
      # Should handle & and punctuation
      assert is_list(facts)
    end
  end
end
