defmodule Arbor.Memory.FactExtractor do
  @moduledoc """
  Regex-based fact extraction from conversation content.

  FactExtractor identifies structured facts from natural language text using
  pattern matching. This is a core subconscious capability — the blog describes
  fact extraction as one of the three things the subconscious notices.

  ## Fact Categories

  - `:person` - Facts about people (names, roles, locations, etc.)
  - `:project` - Facts about projects and work
  - `:technical` - Technical facts (languages, tools, dependencies)
  - `:preference` - User preferences and opinions
  - `:relationship` - Relationship information between entities

  ## Confidence Levels

  - 0.8-0.9: High confidence patterns (explicit statements like "my name is X")
  - 0.6-0.7: Medium confidence patterns (implicit or contextual)
  - 0.4-0.5: Low confidence (ambiguous matches)

  ## Examples

      # Extract facts from text
      facts = FactExtractor.extract("My name is Alice and I work at Acme Corp")
      # => [
      #   %{content: "Alice", category: :person, confidence: 0.9, ...},
      #   %{content: "Works at Acme Corp", category: :person, confidence: 0.8, ...}
      # ]

      # Batch extraction
      facts = FactExtractor.extract_batch([text1, text2, text3])
  """

  @type fact :: %{
          content: String.t(),
          category: :person | :project | :technical | :preference | :relationship,
          confidence: float(),
          source: String.t(),
          entities: [String.t()]
        }

  @type extract_opts :: [
          categories: [:person | :project | :technical | :preference | :relationship],
          min_confidence: float(),
          source: String.t()
        ]

  # ============================================================================
  # Pattern Definitions
  # ============================================================================

  # Person-related patterns
  @person_patterns [
    # Name patterns
    {~r/(?:my name is|I'm called|I am)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)/i, :name, 0.9},
    {~r/(?:call me|they call me)\s+([A-Z][a-z]+)/i, :name, 0.85},

    # Work/role patterns
    {~r/I (?:work at|work for|am employed at|am employed by)\s+([A-Z][A-Za-z\s&]+)/i, :employer,
     0.85},
    {~r/I(?:'m| am) (?:a|an)\s+([A-Za-z\s]+(?:developer|engineer|designer|manager|lead|architect|analyst|consultant))/i,
     :role, 0.85},
    {~r/my (?:job|role|title|position) is\s+([A-Za-z\s]+)/i, :role, 0.8},

    # Location patterns
    {~r/I (?:live in|am from|am based in|reside in)\s+([A-Z][A-Za-z\s,]+)/i, :location, 0.85},
    {~r/(?:I'm|I am) located in\s+([A-Z][A-Za-z\s,]+)/i, :location, 0.8}
  ]

  # Project-related patterns
  @project_patterns [
    {~r/(?:I'm|I am|we're|we are) (?:working on|building|developing|creating)\s+(.+?)(?:\.|,|$)/i,
     :current_project, 0.8},
    {~r/the project is (?:called |named )?([A-Za-z][A-Za-z0-9\-_\s]+)/i, :project_name, 0.85},
    {~r/(?:my|our) project (?:is called |is named )?([A-Za-z][A-Za-z0-9\-_\s]+)/i, :project_name,
     0.8},
    {~r/building\s+(?:a|an)\s+([A-Za-z][A-Za-z0-9\s]+?)(?:\s+(?:with|using|in)|\.|,|$)/i,
     :project_type, 0.7}
  ]

  # Technical patterns
  @technical_patterns [
    # Language/framework usage
    {~r/(?:using|written in|built with|developed in|coded in)\s+([A-Z][A-Za-z0-9\+#\.]+)/i,
     :technology, 0.85},
    {~r/(?:runs on|deployed on|hosted on)\s+([A-Z][A-Za-z0-9\s]+)/i, :platform, 0.8},
    {~r/depends on\s+([A-Za-z][A-Za-z0-9\-_]+)/i, :dependency, 0.85},
    {~r/(?:we use|I use|using)\s+([A-Z][A-Za-z0-9]+)\s+(?:for|as)/i, :tool, 0.75},

    # Database patterns
    {~r/(?:using|with)\s+(PostgreSQL|MySQL|MongoDB|Redis|SQLite|Postgres)/i, :database, 0.9},

    # Framework patterns
    {~r/(?:using|with|built on)\s+(Phoenix|Rails|Django|Express|Next\.js|React|Vue|Angular)/i,
     :framework, 0.9}
  ]

  # Preference patterns
  @preference_patterns [
    {~r/I (?:prefer|like|love|enjoy)\s+(.+?)(?:\s+(?:over|to|more than)|\.|,|$)/i, :likes, 0.8},
    {~r/I (?:don't like|dislike|hate|avoid)\s+(.+?)(?:\.|,|$)/i, :dislikes, 0.8},
    {~r/(?:my|the) favorite\s+([A-Za-z]+)\s+is\s+(.+?)(?:\.|,|$)/i, :favorite, 0.85},
    {~r/I always\s+(.+?)(?:\s+when|\.|,|$)/i, :habit, 0.6},
    {~r/I never\s+(.+?)(?:\.|,|$)/i, :avoidance, 0.6}
  ]

  # Relationship patterns
  @relationship_patterns [
    {~r/([A-Z][a-z]+)\s+is my\s+([A-Za-z\s]+)/i, :personal_relationship, 0.85},
    {~r/I know\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)/i, :acquaintance, 0.6},
    {~r/(?:my|our)\s+(friend|colleague|coworker|partner|mentor|manager)\s+([A-Z][a-z]+)/i,
     :named_relationship, 0.8},
    {~r/([A-Z][a-z]+)\s+(?:works with|collaborates with)\s+me/i, :work_relationship, 0.75}
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Extract facts from a piece of text.

  ## Options

  - `:categories` - List of categories to extract (default: all)
  - `:min_confidence` - Minimum confidence threshold (default: 0.0)
  - `:source` - Source identifier for extracted facts

  ## Examples

      facts = FactExtractor.extract("My name is Alice and I work at Acme")
      facts = FactExtractor.extract(text, min_confidence: 0.7)
      facts = FactExtractor.extract(text, categories: [:person, :technical])
  """
  @spec extract(String.t(), extract_opts()) :: [fact()]
  def extract(text, opts \\ []) when is_binary(text) do
    categories =
      Keyword.get(opts, :categories, [:person, :project, :technical, :preference, :relationship])

    min_confidence = Keyword.get(opts, :min_confidence, 0.0)
    source = Keyword.get(opts, :source, "conversation")

    patterns = get_patterns_for_categories(categories)

    patterns
    |> Enum.flat_map(&extract_with_pattern(text, &1, source))
    |> Enum.filter(&(&1.confidence >= min_confidence))
    |> deduplicate_facts()
  end

  @doc """
  Extract facts from multiple texts.

  Returns a flat list of all facts found across all texts.
  Each fact includes its source text identifier.

  ## Options

  Same as `extract/2`, plus:
  - `:source_prefix` - Prefix for source identifiers (default: "text")

  ## Examples

      texts = ["Message 1", "Message 2", "Message 3"]
      facts = FactExtractor.extract_batch(texts)
  """
  @spec extract_batch([String.t()], extract_opts()) :: [fact()]
  def extract_batch(texts, opts \\ []) when is_list(texts) do
    source_prefix = Keyword.get(opts, :source_prefix, "text")

    texts
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, idx} ->
      source = "#{source_prefix}_#{idx}"
      extract(text, Keyword.put(opts, :source, source))
    end)
    |> deduplicate_facts()
  end

  @doc """
  Get available fact categories.
  """
  @spec categories() :: [atom()]
  def categories do
    [:person, :project, :technical, :preference, :relationship]
  end

  @doc """
  Count facts by category.
  """
  @spec count_by_category([fact()]) :: map()
  def count_by_category(facts) do
    facts
    |> Enum.group_by(& &1.category)
    |> Map.new(fn {cat, items} -> {cat, length(items)} end)
  end

  @doc """
  Filter facts by minimum confidence.
  """
  @spec filter_by_confidence([fact()], float()) :: [fact()]
  def filter_by_confidence(facts, min_confidence) do
    Enum.filter(facts, &(&1.confidence >= min_confidence))
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp get_patterns_for_categories(categories) do
    all_patterns = [
      {:person, @person_patterns},
      {:project, @project_patterns},
      {:technical, @technical_patterns},
      {:preference, @preference_patterns},
      {:relationship, @relationship_patterns}
    ]

    all_patterns
    |> Enum.filter(fn {category, _} -> category in categories end)
    |> Enum.flat_map(fn {category, patterns} ->
      Enum.map(patterns, fn {regex, subtype, confidence} ->
        {category, regex, subtype, confidence}
      end)
    end)
  end

  defp extract_with_pattern(text, {category, regex, subtype, base_confidence}, source) do
    case Regex.scan(regex, text, capture: :all) do
      [] ->
        []

      matches ->
        Enum.map(matches, fn match ->
          # match is [full_match, capture1, capture2, ...]
          captures = Enum.drop(match, 1)
          entities = Enum.map(captures, &String.trim/1)
          content = build_fact_content(category, subtype, entities)

          %{
            content: content,
            category: category,
            confidence: base_confidence,
            source: source,
            entities: entities,
            subtype: subtype
          }
        end)
    end
  end

  defp build_fact_content(:person, :name, [name | _]) do
    "Name is #{name}"
  end

  defp build_fact_content(:person, :employer, [employer | _]) do
    "Works at #{employer}"
  end

  defp build_fact_content(:person, :role, [role | _]) do
    "Role: #{String.trim(role)}"
  end

  defp build_fact_content(:person, :location, [location | _]) do
    "Located in #{String.trim(location)}"
  end

  defp build_fact_content(:project, :current_project, [project | _]) do
    "Working on: #{String.trim(project)}"
  end

  defp build_fact_content(:project, :project_name, [name | _]) do
    "Project: #{String.trim(name)}"
  end

  defp build_fact_content(:project, :project_type, [type | _]) do
    "Building a #{String.trim(type)}"
  end

  defp build_fact_content(:technical, :technology, [tech | _]) do
    "Uses #{tech}"
  end

  defp build_fact_content(:technical, :platform, [platform | _]) do
    "Runs on #{String.trim(platform)}"
  end

  defp build_fact_content(:technical, :dependency, [dep | _]) do
    "Depends on #{dep}"
  end

  defp build_fact_content(:technical, :tool, [tool | _]) do
    "Uses #{tool}"
  end

  defp build_fact_content(:technical, :database, [db | _]) do
    "Database: #{db}"
  end

  defp build_fact_content(:technical, :framework, [fw | _]) do
    "Framework: #{fw}"
  end

  defp build_fact_content(:preference, :likes, [thing | _]) do
    "Likes: #{String.trim(thing)}"
  end

  defp build_fact_content(:preference, :dislikes, [thing | _]) do
    "Dislikes: #{String.trim(thing)}"
  end

  defp build_fact_content(:preference, :favorite, [category, thing | _]) do
    "Favorite #{category}: #{String.trim(thing)}"
  end

  defp build_fact_content(:preference, :habit, [habit | _]) do
    "Habit: always #{String.trim(habit)}"
  end

  defp build_fact_content(:preference, :avoidance, [thing | _]) do
    "Avoids: #{String.trim(thing)}"
  end

  defp build_fact_content(:relationship, :personal_relationship, [person, relationship | _]) do
    "#{person} is #{String.trim(relationship)}"
  end

  defp build_fact_content(:relationship, :acquaintance, [person | _]) do
    "Knows #{person}"
  end

  defp build_fact_content(:relationship, :named_relationship, [type, name | _]) do
    "#{String.capitalize(type)}: #{name}"
  end

  defp build_fact_content(:relationship, :work_relationship, [person | _]) do
    "Works with #{person}"
  end

  defp build_fact_content(category, subtype, entities) do
    # Fallback for any patterns not explicitly handled
    "#{category}/#{subtype}: #{Enum.join(entities, ", ")}"
  end

  defp deduplicate_facts(facts) do
    facts
    |> Enum.uniq_by(fn fact ->
      # Dedupe by normalized content
      String.downcase(fact.content)
    end)
  end
end
