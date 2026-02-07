defmodule Arbor.Memory.FactExtractor do
  @moduledoc """
  Fact extraction from conversation content using LLM analysis with regex fallback.

  FactExtractor identifies structured facts from natural language text. By default,
  it uses LLM-based extraction (via `Arbor.AI.generate_text/2`) for richer, more
  contextual results. If the LLM is unavailable, it falls back to regex pattern
  matching automatically.

  This is a core subconscious capability — the blog describes
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

      # Force specific method
      facts = FactExtractor.extract(text, method: :regex)    # regex only
      facts = FactExtractor.extract(text, method: :llm)      # LLM only
      facts = FactExtractor.extract(text, method: :auto)     # LLM with regex fallback (default)
  """

  require Logger

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
          source: String.t(),
          method: :auto | :llm | :regex,
          model: String.t(),
          provider: atom()
        ]

  # ============================================================================
  # LLM Extraction
  # ============================================================================

  @extraction_system_prompt """
  You are a fact extraction assistant. Your job is to identify important factual information
  from conversation excerpts that should be preserved in long-term memory.

  Output a JSON array of facts. Each fact should have:
  - "content": A clear, standalone statement of the fact
  - "category": One of "person", "project", "technical", "preference", "relationship"
  - "entities": Array of entity names mentioned (people, projects, tools, etc.)
  - "confidence": Your confidence this is worth remembering (0.0-1.0)

  Guidelines:
  - Focus on: user preferences, technical decisions, important observations, named entities
  - Ignore: transient discussion, questions without answers, greetings, filler
  - Make facts standalone - they should make sense without the original context
  - Be selective - only extract truly important information
  - Higher confidence for explicit statements, lower for inferences
  - "person" category: names, roles, locations, employers
  - "project" category: project names, what's being built, goals
  - "technical" category: languages, frameworks, tools, databases, dependencies
  - "preference" category: likes, dislikes, habits, opinions
  - "relationship" category: connections between people, collaboration patterns

  Example output:
  [
    {"content": "User prefers Elixir over Python for backend services", "category": "preference", "entities": ["Elixir", "Python"], "confidence": 0.9},
    {"content": "The Arbor project uses capability-based security", "category": "technical", "entities": ["Arbor"], "confidence": 0.85}
  ]

  Output ONLY valid JSON array, no preamble or explanation.
  If no facts worth extracting, output: []
  """

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
    {~r/(?:uses?|using|written in|built with|developed in|coded in)\s+([A-Z][A-Za-z0-9\+#\.]+)/i,
     :technology, 0.85},
    {~r/(?:runs on|deployed on|hosted on)\s+([A-Z][A-Za-z0-9\s]+)/i, :platform, 0.8},
    {~r/depends on\s+([A-Za-z][A-Za-z0-9\-_]+)/i, :dependency, 0.85},
    {~r/(?:we use|I use|using)\s+([A-Z][A-Za-z0-9]+)\s+(?:for|as)/i, :tool, 0.75},

    # Database patterns
    {~r/(?:uses?|using|with)\s+(PostgreSQL|MySQL|MongoDB|Redis|SQLite|Postgres)/i, :database, 0.9},

    # Framework patterns
    {~r/(?:uses?|using|with|built on)\s+(Phoenix|Rails|Django|Express|Next\.js|React|Vue|Angular)/i,
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

  - `:method` - Extraction method: `:auto` (default), `:llm`, or `:regex`
  - `:categories` - List of categories to extract (default: all)
  - `:min_confidence` - Minimum confidence threshold (default: 0.0)
  - `:source` - Source identifier for extracted facts
  - `:model` - LLM model to use (for `:llm`/`:auto` methods)
  - `:provider` - LLM provider to use (for `:llm`/`:auto` methods)

  ## Examples

      facts = FactExtractor.extract("My name is Alice and I work at Acme")
      facts = FactExtractor.extract(text, min_confidence: 0.7)
      facts = FactExtractor.extract(text, categories: [:person, :technical])
      facts = FactExtractor.extract(text, method: :regex)
  """
  @spec extract(String.t(), extract_opts()) :: [fact()]
  def extract(text, opts \\ []) when is_binary(text) do
    method = Keyword.get(opts, :method, :auto)

    case method do
      :llm -> extract_llm(text, opts)
      :regex -> extract_regex(text, opts)
      :auto -> extract_auto(text, opts)
    end
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

  # ============================================================================
  # LLM Extraction Implementation
  # ============================================================================

  defp extract_auto(text, opts) do
    if llm_available?() do
      extract_llm_with_fallback(text, opts)
    else
      extract_regex(text, opts)
    end
  end

  defp extract_regex(text, opts) do
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

  defp extract_llm_with_fallback(text, opts) do
    case extract_llm(text, opts) do
      [] ->
        # LLM returned nothing, try regex as supplement
        extract_regex(text, opts)

      {:error, _reason} ->
        extract_regex(text, opts)

      facts when is_list(facts) ->
        facts
    end
  end

  defp extract_llm(text, opts) do
    min_confidence = Keyword.get(opts, :min_confidence, 0.0)
    source = Keyword.get(opts, :source, "conversation")

    prompt = """
    Extract important facts from this text:

    #{truncate_text(text, 2000)}

    OUTPUT (JSON array only):
    """

    llm_opts =
      opts
      |> Keyword.take([:model, :provider])
      |> Keyword.put_new(:max_tokens, 1000)
      |> Keyword.put(:system_prompt, @extraction_system_prompt)

    case call_llm(prompt, llm_opts) do
      {:ok, raw_json} ->
        raw_json
        |> parse_llm_facts(source)
        |> Enum.filter(&(&1.confidence >= min_confidence))
        |> deduplicate_facts()

      {:error, reason} ->
        Logger.debug("LLM fact extraction failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp call_llm(prompt, opts) do
    case Arbor.AI.generate_text(prompt, opts) do
      {:ok, %{text: text}} when is_binary(text) ->
        {:ok, String.trim(text)}

      {:ok, response} when is_binary(response) ->
        {:ok, String.trim(response)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc false
  def parse_llm_facts(raw_json, source \\ "conversation") do
    cleaned =
      raw_json
      |> String.trim()
      |> String.replace(~r/^```json\s*/i, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, facts} when is_list(facts) ->
        facts
        |> Enum.map(fn fact ->
          %{
            content: fact["content"] || "",
            category: parse_category(fact["category"]),
            entities: parse_entities(fact["entities"]),
            confidence: parse_confidence(fact["confidence"]),
            source: source,
            subtype: :llm_extracted
          }
        end)
        |> Enum.filter(&valid_fact?/1)

      {:ok, _} ->
        Logger.debug("LLM fact extraction returned non-array JSON")
        []

      {:error, reason} ->
        Logger.debug("Failed to parse LLM facts JSON: #{inspect(reason)}")
        []
    end
  end

  defp parse_category("person"), do: :person
  defp parse_category("project"), do: :project
  defp parse_category("technical"), do: :technical
  defp parse_category("preference"), do: :preference
  defp parse_category("relationship"), do: :relationship
  defp parse_category(_), do: :technical

  defp parse_entities(nil), do: []
  defp parse_entities(entities) when is_list(entities), do: Enum.map(entities, &to_string/1)
  defp parse_entities(_), do: []

  defp parse_confidence(nil), do: 0.5
  defp parse_confidence(c) when is_number(c), do: max(0.0, min(1.0, c))
  defp parse_confidence(_), do: 0.5

  defp valid_fact?(%{content: content}) when is_binary(content) and byte_size(content) > 10, do: true
  defp valid_fact?(_), do: false

  @doc false
  def llm_available? do
    Code.ensure_loaded?(Arbor.AI) and function_exported?(Arbor.AI, :generate_text, 2)
  end

  @doc """
  Format a list of message maps for LLM extraction.

  Each message should have `:role` and `:content` keys.
  """
  @spec format_messages_for_extraction([map()]) :: String.t()
  def format_messages_for_extraction(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      role = msg[:role] || msg["role"] || "unknown"
      content = msg[:content] || msg["content"] || ""
      speaker = msg[:speaker] || msg["speaker"]

      speaker_label =
        case role do
          r when r in [:user, "user"] -> speaker || "Human"
          r when r in [:assistant, "assistant"] -> "Assistant"
          _ -> to_string(role)
        end

      "#{speaker_label}: #{truncate_text(content, 1000)}"
    end)
  end

  defp truncate_text(text, max_length) when byte_size(text) > max_length do
    String.slice(text, 0, max_length) <> "..."
  end

  defp truncate_text(text, _max_length), do: text
end
