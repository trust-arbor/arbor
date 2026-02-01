defmodule Arbor.Memory.BackgroundChecks do
  @moduledoc """
  The subconscious orchestrator — runs all background checks during heartbeats.

  This module does NOT own the heartbeat or run as a GenServer. It exports
  analysis that the agent (or arbor_agent/bridged host) calls during heartbeats
  or on signal triggers.

  ## Check Types

  1. **Consolidation** - Should we consolidate the knowledge graph?
  2. **Unused Pins** - Any pinned memories with low access count?
  3. **Decay Status** - Too many nodes near decay threshold?
  4. **Action Patterns** - Tool usage patterns detected?
  5. **Introspection** - Pending facts/learnings piling up?
  6. **Insights** - Behavioral patterns worth surfacing?

  ## Result Structure

  ```elixir
  %{
    actions: [action()],        # things that should happen now
    warnings: [warning()],      # things the agent should know about
    suggestions: [suggestion()] # proposals for the agent to review
  }
  ```

  ## Usage

      # Run all checks
      result = Arbor.Memory.BackgroundChecks.run("agent_001")

      # Run with action history for pattern detection
      result = Arbor.Memory.BackgroundChecks.run("agent_001",
        action_history: history,
        last_consolidation: datetime
      )

      # Run specific check
      result = Arbor.Memory.BackgroundChecks.check_consolidation("agent_001")
  """

  alias Arbor.Memory.{
    ActionPatterns,
    Consolidation,
    InsightDetector,
    Patterns,
    Proposal,
    Signals
  }

  require Logger

  @type action :: %{
          type: atom(),
          description: String.t(),
          priority: :high | :medium | :low,
          data: map()
        }

  @type warning :: %{
          type: atom(),
          message: String.t(),
          severity: :critical | :warning | :info,
          data: map()
        }

  @type suggestion :: %{
          type: atom(),
          content: String.t(),
          confidence: float(),
          proposal_id: String.t() | nil
        }

  @type check_result :: %{
          actions: [action()],
          warnings: [warning()],
          suggestions: [suggestion()]
        }

  # Graph ETS table
  @graph_ets :arbor_memory_graphs

  # Thresholds
  @pending_pileup_threshold 10
  @decay_risk_warning_threshold 0.3
  @unused_pin_warning_threshold 5

  # ============================================================================
  # Main Entry Point
  # ============================================================================

  @doc """
  Run all background checks for an agent.

  Call this during heartbeats or on scheduled intervals.

  ## Options

  - `:action_history` - List of recent tool actions for pattern detection
  - `:last_consolidation` - DateTime of last consolidation (for timing)
  - `:skip_consolidation` - Skip consolidation check (default: false)
  - `:skip_patterns` - Skip action pattern detection (default: false)
  - `:skip_insights` - Skip insight detection (default: false)

  ## Returns

  A map with three lists:
  - `:actions` - Things that should happen now (e.g., run consolidation)
  - `:warnings` - Things the agent should know about
  - `:suggestions` - Proposals created for agent review

  ## Examples

      result = BackgroundChecks.run("agent_001")
      if result.actions != [], do: handle_actions(result.actions)
      if result.warnings != [], do: notify_agent(result.warnings)
  """
  @spec run(String.t(), keyword()) :: check_result()
  def run(agent_id, opts \\ []) do
    Signals.emit_background_checks_started(agent_id)

    start_time = System.monotonic_time(:millisecond)

    # Gather results from all checks
    consolidation_result = maybe_check_consolidation(agent_id, opts)
    pins_result = check_unused_pins(agent_id)
    decay_result = check_decay_status(agent_id)
    patterns_result = maybe_check_patterns(agent_id, opts)
    introspection_result = suggest_introspection(agent_id)
    insights_result = maybe_check_insights(agent_id, opts)

    # Merge all results
    result = merge_results([
      consolidation_result,
      pins_result,
      decay_result,
      patterns_result,
      introspection_result,
      insights_result
    ])

    duration_ms = System.monotonic_time(:millisecond) - start_time

    Signals.emit_background_checks_completed(agent_id, %{
      action_count: length(result.actions),
      warning_count: length(result.warnings),
      suggestion_count: length(result.suggestions),
      duration_ms: duration_ms
    })

    Logger.debug(
      "BackgroundChecks for #{agent_id}: " <>
        "#{length(result.actions)} actions, #{length(result.warnings)} warnings, " <>
        "#{length(result.suggestions)} suggestions (#{duration_ms}ms)"
    )

    result
  end

  # ============================================================================
  # Individual Checks
  # ============================================================================

  @doc """
  Check if consolidation should run.

  Returns an action if consolidation is needed.
  """
  @spec check_consolidation(String.t(), keyword()) :: check_result()
  def check_consolidation(agent_id, opts \\ []) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        if Consolidation.should_consolidate?(graph, opts) do
          preview = Consolidation.preview(graph, opts)

          %{
            actions: [
              %{
                type: :run_consolidation,
                description: "Knowledge graph needs consolidation",
                priority: :medium,
                data: %{
                  node_count: preview.current_node_count,
                  would_prune: preview.would_prune_count
                }
              }
            ],
            warnings: [],
            suggestions: []
          }
        else
          empty_result()
        end

      {:error, _} ->
        empty_result()
    end
  end

  @doc """
  Check for unused pinned memories.

  Returns warnings if pinned memories aren't being accessed.
  """
  @spec check_unused_pins(String.t(), keyword()) :: check_result()
  def check_unused_pins(agent_id, opts \\ []) do
    case Patterns.unused_pins(agent_id, opts) do
      {:error, _} ->
        empty_result()

      pins when is_list(pins) ->
        if length(pins) >= @unused_pin_warning_threshold do
          %{
            actions: [],
            warnings: [
              %{
                type: :unused_pins,
                message:
                  "#{length(pins)} pinned memories haven't been accessed recently. " <>
                    "Consider reviewing if they still need to be pinned.",
                severity: :warning,
                data: %{
                  count: length(pins),
                  pins: Enum.take(pins, 5)
                }
              }
            ],
            suggestions: []
          }
        else
          empty_result()
        end
    end
  end

  @doc """
  Check decay status of the knowledge graph.

  Returns warnings if too many nodes are at risk of being pruned.
  """
  @spec check_decay_status(String.t(), keyword()) :: check_result()
  def check_decay_status(agent_id, opts \\ []) do
    case Patterns.decay_risk(agent_id, opts) do
      {:error, _} ->
        empty_result()

      risk when is_map(risk) ->
        if risk.at_risk_percentage >= @decay_risk_warning_threshold do
          %{
            actions: [],
            warnings: [
              %{
                type: :decay_risk,
                message:
                  "#{Float.round(risk.at_risk_percentage * 100, 1)}% of memories are at decay risk. " <>
                    "Consider reinforcing important memories or running consolidation.",
                severity: if(risk.at_risk_percentage > 0.5, do: :critical, else: :warning),
                data: %{
                  at_risk_count: risk.at_risk_count,
                  at_risk_percentage: risk.at_risk_percentage,
                  threshold: risk.threshold
                }
              }
            ],
            suggestions: []
          }
        else
          empty_result()
        end
    end
  end

  @doc """
  Check for action patterns in tool usage history.

  Requires `:action_history` in opts.
  """
  @spec check_action_patterns(String.t(), keyword()) :: check_result()
  def check_action_patterns(agent_id, opts \\ []) do
    action_history = Keyword.get(opts, :action_history, [])

    if length(action_history) < 5 do
      empty_result()
    else
      case ActionPatterns.analyze_and_queue(agent_id, action_history, opts) do
        {:ok, proposals} when proposals != [] ->
          %{
            actions: [],
            warnings: [],
            suggestions:
              Enum.map(proposals, fn proposal ->
                %{
                  type: :learning,
                  content: proposal.content,
                  confidence: proposal.confidence,
                  proposal_id: proposal.id
                }
              end)
          }

        _ ->
          empty_result()
      end
    end
  end

  @doc """
  Suggest introspection if pending queues are piling up.

  Returns warnings when there are too many unreviewed proposals.
  """
  @spec suggest_introspection(String.t()) :: check_result()
  def suggest_introspection(agent_id) do
    pending_count = Proposal.count_pending(agent_id)

    if pending_count >= @pending_pileup_threshold do
      %{
        actions: [],
        warnings: [
          %{
            type: :pending_pileup,
            message:
              "#{pending_count} proposals are waiting for review. " <>
                "Consider taking time to review pending facts, learnings, and insights.",
            severity: :info,
            data: %{
              pending_count: pending_count,
              stats: Proposal.stats(agent_id)
            }
          }
        ],
        suggestions: []
      }
    else
      empty_result()
    end
  end

  @doc """
  Check for behavioral insights from knowledge graph patterns.
  """
  @spec check_insights(String.t(), keyword()) :: check_result()
  def check_insights(agent_id, opts \\ []) do
    case InsightDetector.detect_and_queue(agent_id, opts) do
      {:ok, proposals} when proposals != [] ->
        %{
          actions: [],
          warnings: [],
          suggestions:
            Enum.map(proposals, fn proposal ->
              %{
                type: :insight,
                content: proposal.content,
                confidence: proposal.confidence,
                proposal_id: proposal.id
              }
            end)
        }

      _ ->
        empty_result()
    end
  end

  # ============================================================================
  # Memory Pattern Analysis
  # ============================================================================

  @doc """
  Run comprehensive memory pattern analysis.

  Returns the full Patterns.analyze result along with any warnings.
  """
  @spec analyze_patterns(String.t()) :: {map(), check_result()}
  def analyze_patterns(agent_id) do
    case Patterns.analyze(agent_id) do
      {:error, _} = error ->
        {error, empty_result()}

      analysis when is_map(analysis) ->
        warnings =
          analysis.suggestions
          |> Enum.map(fn suggestion ->
            %{
              type: :pattern_analysis,
              message: suggestion,
              severity: :info,
              data: %{}
            }
          end)

        result = %{
          actions: [],
          warnings: warnings,
          suggestions: []
        }

        {analysis, result}
    end
  end

  # ============================================================================
  # Cognitive Adjustments
  # ============================================================================

  @doc """
  Emit a cognitive adjustment signal.

  Called by external systems when they detect the need for agent adjustment.
  """
  @spec emit_cognitive_adjustment(String.t(), atom(), map()) :: :ok
  def emit_cognitive_adjustment(agent_id, adjustment_type, details) do
    Signals.emit_cognitive_adjustment(agent_id, adjustment_type, details)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp maybe_check_consolidation(agent_id, opts) do
    if Keyword.get(opts, :skip_consolidation, false) do
      empty_result()
    else
      check_consolidation(agent_id, opts)
    end
  end

  defp maybe_check_patterns(agent_id, opts) do
    if Keyword.get(opts, :skip_patterns, false) do
      empty_result()
    else
      check_action_patterns(agent_id, opts)
    end
  end

  defp maybe_check_insights(agent_id, opts) do
    if Keyword.get(opts, :skip_insights, false) do
      empty_result()
    else
      check_insights(agent_id, opts)
    end
  end

  defp empty_result do
    %{actions: [], warnings: [], suggestions: []}
  end

  defp merge_results(results) do
    Enum.reduce(results, empty_result(), fn result, acc ->
      %{
        actions: acc.actions ++ result.actions,
        warnings: acc.warnings ++ result.warnings,
        suggestions: acc.suggestions ++ result.suggestions
      }
    end)
  end

  defp get_graph(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :graph_not_initialized}
    end
  end
end
