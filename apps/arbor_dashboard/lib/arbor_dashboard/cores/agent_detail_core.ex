defmodule Arbor.Dashboard.Cores.AgentDetailCore do
  @moduledoc """
  Pure display formatters for the agents_live detail panel drill-down sections.

  Each "drill-down" section of the agent detail view (executor, reasoning,
  goals, thinking) is shaped here so the LiveView template just renders
  pre-formatted maps. Domain knowledge — what the canonical metric for an
  executor is, what icon a goal type gets, what color a reasoning status
  should be — lives in one testable module.

  ## Convert functions

  - `show_executor/1` — executor status + stats → display map (or nil)
  - `show_reasoning/1` — reasoning loop state → display map (or nil)
  - `show_goals/1` — list of goals → list of display maps
  - `show_thinking/1` — list of thinking blocks → list of display maps (limited)
  - `show_drilldown/1` — convenience: shape all four sections from a detail map

  Status fields (`summary`, `profile`, `model_summary`, `trust_summary`)
  already have their own Convert functions in `Arbor.Agent`,
  `Arbor.Trust.Authority`, and `Arbor.Agent.ConfigCore`. This module covers
  the four sections that didn't have one.
  """

  alias Arbor.Web.Helpers

  @thinking_display_limit 5
  @thinking_truncate_chars 300

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc """
  Format executor state for display.

  Returns nil when no executor is running. Otherwise returns a map with
  status, status_color, and stat counters.
  """
  @spec show_executor(map() | nil) :: map() | nil
  def show_executor(nil), do: nil

  def show_executor(executor) do
    stats = Map.get(executor, :stats, %{})

    %{
      status: Map.get(executor, :status),
      status_label: format_executor_status(Map.get(executor, :status)),
      status_color: executor_status_color(Map.get(executor, :status)),
      intents_received: Map.get(stats, :intents_received, 0),
      intents_executed: Map.get(stats, :intents_executed, 0),
      intents_blocked: Map.get(stats, :intents_blocked, 0)
    }
  end

  @doc """
  Format reasoning loop state for display.

  Returns nil when no reasoning loop is running.
  """
  @spec show_reasoning(map() | nil) :: map() | nil
  def show_reasoning(nil), do: nil

  def show_reasoning(reasoning) do
    %{
      mode: Map.get(reasoning, :mode),
      mode_label: to_string(Map.get(reasoning, :mode, "—")),
      status: Map.get(reasoning, :status),
      status_label: to_string(Map.get(reasoning, :status, "—")),
      status_color: reasoning_status_color(Map.get(reasoning, :status)),
      iteration: Map.get(reasoning, :iteration, 0)
    }
  end

  @doc """
  Format active goals as a list of display maps.

  Each goal becomes a map with icon, label (description or type), and
  optional priority. Empty list when there are no goals.
  """
  @spec show_goals([map()] | nil) :: [map()]
  def show_goals(nil), do: []
  def show_goals([]), do: []

  def show_goals(goals) when is_list(goals) do
    Enum.map(goals, fn goal ->
      %{
        id: Map.get(goal, :id),
        icon: goal_icon(goal),
        label: goal_label(goal),
        type: Map.get(goal, :type),
        priority: Map.get(goal, :priority),
        progress: Map.get(goal, :progress)
      }
    end)
  end

  @doc """
  Format recent thinking blocks for display.

  Limited to the most recent N blocks (default 5). Each block becomes a
  map with significant flag, truncated text, and a relative timestamp.
  """
  @spec show_thinking([map()] | nil, keyword()) :: [map()]
  def show_thinking(blocks, opts \\ [])
  def show_thinking(nil, _opts), do: []
  def show_thinking([], _opts), do: []

  def show_thinking(blocks, opts) when is_list(blocks) do
    limit = Keyword.get(opts, :limit, @thinking_display_limit)
    truncate_at = Keyword.get(opts, :truncate, @thinking_truncate_chars)

    blocks
    |> Enum.take(limit)
    |> Enum.map(fn block ->
      %{
        significant: Map.get(block, :significant, false),
        text: truncate_text(Map.get(block, :text, ""), truncate_at),
        created_at: Map.get(block, :created_at),
        time_relative: format_relative(Map.get(block, :created_at))
      }
    end)
  end

  @doc """
  Convenience: shape all four drill-down sections from an agent detail map.

  Useful for callers that want one Convert call instead of four. Returns
  a map with `:executor`, `:reasoning`, `:goals`, `:thinking` keys.
  """
  @spec show_drilldown(map()) :: map()
  def show_drilldown(detail) when is_map(detail) do
    %{
      executor: show_executor(Map.get(detail, :executor)),
      reasoning: show_reasoning(Map.get(detail, :reasoning)),
      goals: show_goals(Map.get(detail, :goals)),
      thinking: show_thinking(Map.get(detail, :thinking))
    }
  end

  # ===========================================================================
  # Pure Helpers (visible for testing and reuse)
  # ===========================================================================

  @doc "Display label for an executor status atom."
  @spec format_executor_status(atom() | nil) :: String.t()
  def format_executor_status(nil), do: "—"
  def format_executor_status(status), do: to_string(status)

  @doc "Color atom for an executor status badge."
  @spec executor_status_color(atom() | nil) :: atom()
  def executor_status_color(:running), do: :green
  def executor_status_color(:paused), do: :purple
  def executor_status_color(:stopped), do: :gray
  def executor_status_color(_), do: :gray

  @doc "Color atom for a reasoning status badge."
  @spec reasoning_status_color(atom() | nil) :: atom()
  def reasoning_status_color(:thinking), do: :blue
  def reasoning_status_color(:idle), do: :gray
  def reasoning_status_color(:awaiting_percept), do: :purple
  def reasoning_status_color(_), do: :gray

  @doc "Emoji icon for a goal based on its type."
  @spec goal_icon(map()) :: String.t()
  def goal_icon(%{type: :maintain}), do: "🔄"
  def goal_icon(%{type: :achieve}), do: "🎯"
  def goal_icon(_), do: "⭐"

  @doc "Display label for a goal — description if present, otherwise the type."
  @spec goal_label(map()) :: String.t()
  def goal_label(goal) do
    case Map.get(goal, :description) do
      desc when is_binary(desc) and desc != "" -> desc
      _ -> to_string(Map.get(goal, :type, "goal"))
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp truncate_text(text, length) when is_binary(text) do
    Helpers.truncate(text, length)
  end

  defp truncate_text(_, _), do: ""

  defp format_relative(nil), do: ""
  defp format_relative(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_relative(_), do: ""
end
