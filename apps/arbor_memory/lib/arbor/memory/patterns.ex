defmodule Arbor.Memory.Patterns do
  @moduledoc """
  Memory usage analysis for the knowledge graph.

  Analyzes patterns in how memory is distributed and used, providing
  insights for BackgroundChecks to surface warnings and suggestions.

  ## Analysis Types

  1. **Type Distribution** - How balanced is memory across node types?
  2. **Access Concentration** - Are a few memories doing all the work? (Gini coefficient)
  3. **Decay Risk** - What percentage of nodes are near the decay threshold?
  4. **Unused Pins** - Pinned memories that aren't being accessed

  ## Usage

  This module is typically called by BackgroundChecks during heartbeats,
  but can also be used for ad-hoc analysis.

      # Full analysis
      analysis = Arbor.Memory.Patterns.analyze("agent_001")

      # Specific checks
      distribution = Arbor.Memory.Patterns.type_distribution("agent_001")
      gini = Arbor.Memory.Patterns.access_concentration("agent_001")
  """

  # KnowledgeGraph accessed via ETS directly for this module

  @type analysis :: %{
          type_distribution: map(),
          access_concentration: float(),
          decay_risk: map(),
          unused_pins: [map()],
          suggestions: [String.t()]
        }

  # Graph ETS table (same as facade)
  @graph_ets :arbor_memory_graphs

  # Thresholds for analysis
  @decay_warning_threshold 0.25
  @unused_pin_access_threshold 3
  @unused_pin_days_threshold 7
  @concentration_warning_threshold 0.6
  @imbalance_warning_threshold 0.7

  # ============================================================================
  # Main Analysis Function
  # ============================================================================

  @doc """
  Run comprehensive memory pattern analysis.

  Returns a map with:
  - `:type_distribution` - Node counts and percentages by type
  - `:access_concentration` - Gini coefficient (0.0 = equal, 1.0 = all in one)
  - `:decay_risk` - Nodes at risk of being pruned
  - `:unused_pins` - Pinned nodes with low access
  - `:suggestions` - Human-readable recommendations

  ## Examples

      analysis = Patterns.analyze("agent_001")
      IO.inspect(analysis.suggestions)
  """
  @spec analyze(String.t()) :: analysis() | {:error, term()}
  def analyze(agent_id) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        distribution = type_distribution_impl(graph)
        concentration = access_concentration_impl(graph)
        risk = decay_risk_impl(graph)
        pins = unused_pins_impl(graph)
        suggestions = generate_suggestions(distribution, concentration, risk, pins)

        %{
          type_distribution: distribution,
          access_concentration: concentration,
          decay_risk: risk,
          unused_pins: pins,
          suggestions: suggestions
        }

      error ->
        error
    end
  end

  # ============================================================================
  # Type Distribution
  # ============================================================================

  @doc """
  Analyze how memory is distributed across node types.

  Returns counts and percentages for each type, plus an imbalance score
  (0.0 = perfectly balanced, 1.0 = all in one type).

  ## Examples

      distribution = Patterns.type_distribution("agent_001")
      # => %{
      #   counts: %{fact: 50, skill: 20, insight: 5},
      #   percentages: %{fact: 0.67, skill: 0.27, insight: 0.07},
      #   total: 75,
      #   imbalance_score: 0.45
      # }
  """
  @spec type_distribution(String.t()) :: map() | {:error, term()}
  def type_distribution(agent_id) do
    case get_graph(agent_id) do
      {:ok, graph} -> type_distribution_impl(graph)
      error -> error
    end
  end

  defp type_distribution_impl(graph) do
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

      imbalance = calculate_imbalance(counts, total)

      %{
        counts: counts,
        percentages: percentages,
        total: total,
        imbalance_score: Float.round(imbalance, 3)
      }
    end
  end

  # Calculate imbalance using coefficient of variation
  defp calculate_imbalance(counts, _total) when map_size(counts) <= 1, do: 0.0

  defp calculate_imbalance(counts, total) do
    values = Map.values(counts)
    n = length(values)
    mean = total / n
    variance = Enum.sum(Enum.map(values, fn v -> :math.pow(v - mean, 2) end)) / n
    std_dev = :math.sqrt(variance)

    # Coefficient of variation, capped at 1.0
    if mean > 0, do: min(1.0, std_dev / mean), else: 0.0
  end

  # ============================================================================
  # Access Concentration (Gini Coefficient)
  # ============================================================================

  @doc """
  Calculate how concentrated memory access is.

  Uses the Gini coefficient:
  - 0.0 = All memories accessed equally
  - 1.0 = All access concentrated in one memory

  A high Gini (> 0.6) suggests the agent relies on a few key memories
  and others may be redundant.

  ## Examples

      gini = Patterns.access_concentration("agent_001")
      # => 0.45
  """
  @spec access_concentration(String.t()) :: float() | {:error, term()}
  def access_concentration(agent_id) do
    case get_graph(agent_id) do
      {:ok, graph} -> access_concentration_impl(graph)
      error -> error
    end
  end

  defp access_concentration_impl(graph) do
    access_counts =
      graph.nodes
      |> Map.values()
      |> Enum.map(& &1.access_count)

    calculate_gini(access_counts)
  end

  @doc """
  Calculate the Gini coefficient for a list of values.

  The Gini coefficient measures inequality in a distribution.
  """
  @spec calculate_gini([number()]) :: float()
  def calculate_gini([]), do: 0.0
  def calculate_gini([_]), do: 0.0

  def calculate_gini(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    total = Enum.sum(sorted)

    if total == 0 do
      0.0
    else
      # Gini formula: G = (2 * Σ(i * x_i)) / (n * Σx_i) - (n + 1) / n
      weighted_sum =
        sorted
        |> Enum.with_index(1)
        |> Enum.map(fn {value, rank} -> rank * value end)
        |> Enum.sum()

      gini = 2 * weighted_sum / (n * total) - (n + 1) / n
      Float.round(max(0.0, min(1.0, gini)), 3)
    end
  end

  # ============================================================================
  # Decay Risk Analysis
  # ============================================================================

  @doc """
  Analyze nodes at risk of being pruned.

  Returns statistics about nodes near the decay threshold.

  ## Examples

      risk = Patterns.decay_risk("agent_001")
      # => %{
      #   at_risk_count: 15,
      #   at_risk_percentage: 0.20,
      #   threshold: 0.25,
      #   at_risk_nodes: [%{id: "...", relevance: 0.12}, ...]
      # }
  """
  @spec decay_risk(String.t(), keyword()) :: map() | {:error, term()}
  def decay_risk(agent_id, opts \\ []) do
    case get_graph(agent_id) do
      {:ok, graph} -> decay_risk_impl(graph, opts)
      error -> error
    end
  end

  defp decay_risk_impl(graph, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @decay_warning_threshold)
    prune_threshold = Map.get(graph.config, :prune_threshold, 0.1)

    nodes = Map.values(graph.nodes)
    total = length(nodes)

    at_risk =
      nodes
      |> Enum.filter(fn node ->
        not node.pinned and node.relevance < threshold and node.relevance >= prune_threshold
      end)
      |> Enum.sort_by(& &1.relevance)

    %{
      at_risk_count: length(at_risk),
      at_risk_percentage: if(total > 0, do: Float.round(length(at_risk) / total, 3), else: 0.0),
      threshold: threshold,
      prune_threshold: prune_threshold,
      at_risk_nodes:
        Enum.map(at_risk, fn n ->
          %{id: n.id, type: n.type, relevance: n.relevance, content_preview: String.slice(n.content, 0, 50)}
        end)
    }
  end

  # ============================================================================
  # Unused Pins Detection
  # ============================================================================

  @doc """
  Find pinned memories that aren't being accessed.

  A pinned memory with low access count and old last_accessed date
  may indicate the agent is holding onto something unnecessarily.

  ## Options

  - `:access_threshold` - Minimum access count to not be "unused" (default: 3)
  - `:days_threshold` - Days since last access to be "stale" (default: 7)

  ## Examples

      pins = Patterns.unused_pins("agent_001")
      # => [%{id: "...", content: "...", access_count: 1, days_stale: 14}]
  """
  @spec unused_pins(String.t(), keyword()) :: [map()] | {:error, term()}
  def unused_pins(agent_id, opts \\ []) do
    case get_graph(agent_id) do
      {:ok, graph} -> unused_pins_impl(graph, opts)
      error -> error
    end
  end

  defp unused_pins_impl(graph, opts \\ []) do
    access_threshold = Keyword.get(opts, :access_threshold, @unused_pin_access_threshold)
    days_threshold = Keyword.get(opts, :days_threshold, @unused_pin_days_threshold)
    cutoff = DateTime.add(DateTime.utc_now(), -days_threshold, :day)

    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      node.pinned and
        node.access_count < access_threshold and
        DateTime.compare(node.last_accessed, cutoff) == :lt
    end)
    |> Enum.map(fn node ->
      days_stale = DateTime.diff(DateTime.utc_now(), node.last_accessed, :day)

      %{
        id: node.id,
        type: node.type,
        content_preview: String.slice(node.content, 0, 100),
        access_count: node.access_count,
        days_stale: days_stale
      }
    end)
    |> Enum.sort_by(& &1.days_stale, :desc)
  end

  # ============================================================================
  # Suggestion Generation
  # ============================================================================

  defp generate_suggestions(distribution, concentration, risk, unused_pins) do
    suggestions = []

    # Type imbalance suggestion
    suggestions =
      if distribution.imbalance_score > @imbalance_warning_threshold do
        dominant_type =
          distribution.counts
          |> Enum.max_by(fn {_type, count} -> count end)
          |> elem(0)

        [
          "Memory is heavily weighted toward #{dominant_type} nodes " <>
            "(#{Float.round(distribution.imbalance_score * 100, 1)}% imbalance). " <>
            "Consider diversifying knowledge types."
          | suggestions
        ]
      else
        suggestions
      end

    # Access concentration suggestion
    suggestions =
      if concentration > @concentration_warning_threshold do
        [
          "Memory access is concentrated (Gini: #{concentration}). " <>
            "A few memories are doing most of the work. " <>
            "Consider reviewing rarely-accessed memories for relevance."
          | suggestions
        ]
      else
        suggestions
      end

    # Decay risk suggestion
    suggestions =
      if risk.at_risk_percentage > 0.3 do
        [
          "#{Float.round(risk.at_risk_percentage * 100, 1)}% of memories are at decay risk. " <>
            "Consider reinforcing important memories or adjusting decay settings."
          | suggestions
        ]
      else
        suggestions
      end

    # Unused pins suggestion
    suggestions =
      case unused_pins do
        [] ->
          suggestions

        _ ->
          [
            "#{length(unused_pins)} pinned memories haven't been accessed recently. " <>
              "Consider reviewing whether they still need to be pinned."
            | suggestions
          ]
      end

    Enum.reverse(suggestions)
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
end
