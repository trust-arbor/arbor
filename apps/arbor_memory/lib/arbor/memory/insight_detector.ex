defmodule Arbor.Memory.InsightDetector do
  @moduledoc """
  Detect behavior patterns and generate insight suggestions.

  Analyzes the knowledge graph to find patterns that might indicate
  personality traits, capabilities, values, or preferences.

  ## Insight Categories

  - `:personality` - Traits like curious, methodical, thorough
  - `:capability` - Skills and strengths
  - `:value` - What the agent values or prioritizes
  - `:preference` - Behavioral preferences

  ## Detection Sources

  - **Pattern Analysis** - Recurring themes in stored memories
  - **Node Clusters** - Groups of related knowledge
  - **Type Distribution** - What kinds of knowledge are stored

  ## Usage

      suggestions = Arbor.Memory.InsightDetector.detect("agent_001")
      # => [%{content: "You tend to be thorough...", category: :personality, ...}]

      {:ok, proposals} = Arbor.Memory.InsightDetector.detect_and_queue("agent_001")
  """

  alias Arbor.Memory.{Proposal, Signals}

  @type insight_category :: :personality | :capability | :value | :preference

  @type insight_suggestion :: %{
          content: String.t(),
          category: insight_category(),
          confidence: float(),
          evidence: [String.t()],
          source: :pattern_analysis | :reflection | :feedback
        }

  # Graph ETS table
  @graph_ets :arbor_memory_graphs

  # Minimum nodes to attempt insight detection
  @min_nodes_for_insights 10

  # ============================================================================
  # Main Detection Function
  # ============================================================================

  @doc """
  Detect insights from knowledge graph patterns and agent behavior.

  Returns a list of insight suggestions for agent review.

  ## Options

  - `:include_low_confidence` - Include suggestions below 0.5 confidence (default: false)
  - `:max_suggestions` - Maximum suggestions to return (default: 5)

  ## Examples

      suggestions = InsightDetector.detect("agent_001")
  """
  @spec detect(String.t(), keyword()) :: [insight_suggestion()] | {:error, term()}
  def detect(agent_id, opts \\ []) do
    include_low = Keyword.get(opts, :include_low_confidence, false)
    max_suggestions = Keyword.get(opts, :max_suggestions, 5)
    min_confidence = if include_low, do: 0.0, else: 0.5

    case get_graph(agent_id) do
      {:ok, graph} ->
        if map_size(graph.nodes) < @min_nodes_for_insights do
          []
        else
          insights =
            [
              detect_from_type_distribution(graph),
              detect_from_content_themes(graph),
              detect_from_access_patterns(graph),
              detect_from_node_relationships(graph)
            ]
            |> List.flatten()
            |> Enum.filter(&(&1.confidence >= min_confidence))
            |> Enum.sort_by(& &1.confidence, :desc)
            |> Enum.take(max_suggestions)
            |> deduplicate_similar()

          insights
        end

      error ->
        error
    end
  end

  # ============================================================================
  # Type Distribution Insights
  # ============================================================================

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp detect_from_type_distribution(graph) do
    case __MODULE__.Patterns.type_distribution_impl(graph) do
      %{total: 0} ->
        []

      %{percentages: percentages, total: total} ->
        insights = []

        # Fact-heavy: curious or detail-oriented
        insights =
          case Map.get(percentages, :fact, 0) do
            p when p > 0.6 ->
              [
                %{
                  content:
                    "You store a high proportion of facts (#{Float.round(p * 100, 1)}%). " <>
                      "This suggests a detail-oriented and knowledge-focused approach.",
                  category: :personality,
                  confidence: min(0.8, p),
                  evidence: ["#{Float.round(p * 100, 1)}% of memories are facts"],
                  source: :pattern_analysis
                }
                | insights
              ]

            _ ->
              insights
          end

        # Experience-heavy: reflective
        insights =
          case Map.get(percentages, :experience, 0) do
            p when p > 0.4 ->
              [
                %{
                  content:
                    "You store many experiences (#{Float.round(p * 100, 1)}%). " <>
                      "This suggests a reflective disposition that learns from events.",
                  category: :personality,
                  confidence: min(0.7, p + 0.2),
                  evidence: ["#{Float.round(p * 100, 1)}% of memories are experiences"],
                  source: :pattern_analysis
                }
                | insights
              ]

            _ ->
              insights
          end

        # Skill-heavy: capability-focused
        insights =
          case Map.get(percentages, :skill, 0) do
            p when p > 0.3 ->
              [
                %{
                  content:
                    "You actively track skills and learnings (#{Float.round(p * 100, 1)}%). " <>
                      "This indicates a growth mindset focused on capability development.",
                  category: :value,
                  confidence: min(0.7, p + 0.3),
                  evidence: ["#{Float.round(p * 100, 1)}% of memories are skills"],
                  source: :pattern_analysis
                }
                | insights
              ]

            _ ->
              insights
          end

        # Insight-heavy: self-aware
        insights =
          case Map.get(percentages, :insight, 0) do
            p when p > 0.2 ->
              [
                %{
                  content:
                    "You maintain a strong collection of insights (#{Float.round(p * 100, 1)}%). " <>
                      "This suggests active self-reflection and metacognition.",
                  category: :personality,
                  confidence: min(0.8, p + 0.4),
                  evidence: ["#{Float.round(p * 100, 1)}% of memories are insights"],
                  source: :pattern_analysis
                }
                | insights
              ]

            _ ->
              insights
          end

        # Many memories overall: thorough
        insights =
          if total > 50 do
            [
              %{
                content: "You maintain a substantial knowledge base (#{total} memories). " <>
                  "This indicates a thorough approach to information retention.",
                category: :personality,
                confidence: min(0.7, 0.4 + total / 200),
                evidence: ["#{total} total memories stored"],
                source: :pattern_analysis
              }
              | insights
            ]
          else
            insights
          end

        insights
    end
  end

  # ============================================================================
  # Content Theme Insights
  # ============================================================================

  defp detect_from_content_themes(graph) do
    nodes = Map.values(graph.nodes)

    if length(nodes) < @min_nodes_for_insights do
      []
    else
      # Extract word frequencies from content
      word_freq = build_word_frequencies(nodes)

      # Look for theme patterns
      themes = detect_themes(word_freq)

      Enum.map(themes, fn {theme, count, words} ->
        %{
          content: "Your memories frequently mention #{theme} " <>
            "(#{count} references). This may indicate an interest or focus area.",
          category: :preference,
          confidence: min(0.7, 0.4 + count / 20),
          evidence: ["Common words: #{Enum.join(Enum.take(words, 3), ", ")}"],
          source: :pattern_analysis
        }
      end)
    end
  end

  defp build_word_frequencies(nodes) do
    nodes
    |> Enum.flat_map(fn node ->
      node.content
      |> String.downcase()
      |> String.split(~r/[^\w]+/, trim: true)
      |> Enum.filter(&(String.length(&1) > 3))
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_word, count} -> count >= 3 end)
    |> Map.new()
  end

  # Theme categories with associated keywords
  @theme_keywords %{
    "technical topics" => ~w(code function module api system error debug test),
    "relationships" => ~w(user people person friend colleague team trust),
    "learning" => ~w(learn understand know remember discover explore),
    "organization" => ~w(plan structure organize schedule task goal)
  }

  defp detect_themes(word_freq) do
    @theme_keywords
    |> Enum.map(fn {theme, keywords} ->
      matching_words =
        Enum.filter(keywords, fn kw ->
          Enum.any?(Map.keys(word_freq), &String.contains?(&1, kw))
        end)

      total_count =
        word_freq
        |> Enum.filter(fn {word, _} ->
          Enum.any?(keywords, &String.contains?(word, &1))
        end)
        |> Enum.map(fn {_, count} -> count end)
        |> Enum.sum()

      {theme, total_count, matching_words}
    end)
    |> Enum.filter(fn {_, count, _} -> count >= 5 end)
    |> Enum.sort_by(fn {_, count, _} -> count end, :desc)
    |> Enum.take(3)
  end

  # ============================================================================
  # Access Pattern Insights
  # ============================================================================

  defp detect_from_access_patterns(graph) do
    nodes = Map.values(graph.nodes)

    if length(nodes) < @min_nodes_for_insights do
      []
    else
      insights = []

      # High access concentration
      gini = __MODULE__.Patterns.calculate_gini(Enum.map(nodes, & &1.access_count))

      insights =
        if gini > 0.6 do
          [
            %{
              content:
                "Your memory access is concentrated (Gini: #{gini}). " <>
                  "You rely heavily on a core set of memories, which may indicate strong foundational knowledge.",
              category: :capability,
              confidence: min(0.7, gini),
              evidence: ["Gini coefficient: #{gini}"],
              source: :pattern_analysis
            }
            | insights
          ]
        else
          insights
        end

      # Balanced access
      insights =
        if gini < 0.3 and length(nodes) > 20 do
          [
            %{
              content:
                "Your memory access is well-distributed (Gini: #{gini}). " <>
                  "You actively utilize a broad range of knowledge.",
              category: :personality,
              confidence: 0.6,
              evidence: ["Gini coefficient: #{gini}", "#{length(nodes)} total memories"],
              source: :pattern_analysis
            }
            | insights
          ]
        else
          insights
        end

      # Many highly-accessed memories
      high_access = Enum.filter(nodes, &(&1.access_count > 10))

      insights =
        if length(high_access) > 5 do
          [
            %{
              content:
                "You have #{length(high_access)} frequently-accessed memories. " <>
                  "This suggests strong working knowledge in key areas.",
              category: :capability,
              confidence: min(0.7, 0.5 + length(high_access) / 20),
              evidence: ["#{length(high_access)} memories with 10+ accesses"],
              source: :pattern_analysis
            }
            | insights
          ]
        else
          insights
        end

      insights
    end
  end

  # ============================================================================
  # Relationship/Edge Insights
  # ============================================================================

  defp detect_from_node_relationships(graph) do
    edge_count =
      graph.edges
      |> Map.values()
      |> List.flatten()
      |> length()

    node_count = map_size(graph.nodes)

    if node_count < @min_nodes_for_insights or edge_count == 0 do
      []
    else
      insights = []
      connectivity = edge_count / node_count

      # Highly connected knowledge
      insights =
        if connectivity > 2.0 do
          [
            %{
              content:
                "Your knowledge is highly interconnected (#{Float.round(connectivity, 1)} connections per memory). " <>
                  "This suggests strong associative thinking.",
              category: :capability,
              confidence: min(0.8, 0.5 + connectivity / 5),
              evidence: [
                "#{edge_count} connections",
                "#{node_count} memories",
                "#{Float.round(connectivity, 1)} ratio"
              ],
              source: :pattern_analysis
            }
            | insights
          ]
        else
          insights
        end

      # Check for specific relationship types
      rel_types =
        graph.edges
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.relationship)
        |> Enum.frequencies()

      # Many "supports" relationships
      insights =
        case Map.get(rel_types, :supports, 0) do
          count when count > 5 ->
            [
              %{
                content:
                  "You frequently link supporting evidence (#{count} support relationships). " <>
                    "This indicates rigorous reasoning and evidence-based thinking.",
                category: :personality,
                confidence: min(0.7, 0.5 + count / 15),
                evidence: ["#{count} 'supports' relationships"],
                source: :pattern_analysis
              }
              | insights
            ]

          _ ->
            insights
        end

      insights
    end
  end

  # ============================================================================
  # Deduplication
  # ============================================================================

  defp deduplicate_similar(insights) do
    # Remove insights with very similar content (same category + similar message)
    Enum.uniq_by(insights, fn insight ->
      {insight.category, String.slice(insight.content, 0, 50)}
    end)
  end

  # ============================================================================
  # Integration Functions
  # ============================================================================

  @doc """
  Run detection and queue suggestions as proposals for agent review.

  ## Examples

      {:ok, proposals} = InsightDetector.detect_and_queue("agent_001")
  """
  @spec detect_and_queue(String.t(), keyword()) :: {:ok, [Proposal.t()]} | {:error, term()}
  def detect_and_queue(agent_id, opts \\ []) do
    case detect(agent_id, opts) do
      {:error, _} = error ->
        error

      suggestions when is_list(suggestions) ->
        proposals =
          suggestions
          |> Enum.map(fn suggestion ->
            create_proposal(agent_id, suggestion)
          end)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, proposal} -> proposal end)

        # Emit signal for each detected insight
        Enum.each(suggestions, fn suggestion ->
          Signals.emit_insight_detected(agent_id, suggestion)
        end)

        {:ok, proposals}
    end
  end

  defp create_proposal(agent_id, suggestion) do
    Proposal.create(agent_id, :insight, %{
      content: suggestion.content,
      confidence: suggestion.confidence,
      source: "insight_detector",
      evidence: suggestion.evidence,
      metadata: %{
        category: suggestion.category,
        detection_source: suggestion.source
      }
    })
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_graph(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :graph_not_initialized}
    end
  end

  # Make type_distribution_impl available to this module
  # by copying the logic (avoiding circular dependency)
  defmodule Patterns do
    @moduledoc false

    def type_distribution_impl(graph) do
      nodes = Map.values(graph.nodes)
      total = length(nodes)

      if total == 0 do
        %{counts: %{}, percentages: %{}, total: 0, imbalance_score: 0.0}
      else
        counts = Enum.frequencies_by(nodes, & &1.type)

        percentages =
          Map.new(counts, fn {type, count} ->
            {type, Float.round(count / total, 3)}
          end)

        %{
          counts: counts,
          percentages: percentages,
          total: total,
          imbalance_score: 0.0
        }
      end
    end

    def calculate_gini([]), do: 0.0
    def calculate_gini([_]), do: 0.0

    def calculate_gini(values) do
      sorted = Enum.sort(values)
      n = length(sorted)
      total = Enum.sum(sorted)

      if total == 0 do
        0.0
      else
        weighted_sum =
          sorted
          |> Enum.with_index(1)
          |> Enum.map(fn {value, rank} -> rank * value end)
          |> Enum.sum()

        gini = 2 * weighted_sum / (n * total) - (n + 1) / n
        Float.round(max(0.0, min(1.0, gini)), 3)
      end
    end
  end
end
