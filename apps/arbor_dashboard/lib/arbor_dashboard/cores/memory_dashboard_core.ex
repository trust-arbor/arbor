defmodule Arbor.Dashboard.Cores.MemoryDashboardCore do
  @moduledoc """
  Pure display formatters for the memory_live tab dashboards.

  memory_live has 7 tabs (working memory, identity, goals, knowledge,
  preferences, proposals, code), each previously doing inline data
  shaping in the template. This module exposes a Convert function for
  each tab so the template iterates over already-formatted maps.

  The working_memory tab continues to use `Arbor.Memory.MemoryCore.for_dashboard/1`
  for its core data; this module owns the dashboard-specific shapes for
  the other six tabs and the smaller display helpers (status colors,
  percent formatting, etc).

  ## Convert functions

  - `show_identity_tab/2` — self-knowledge + capability list → display map
  - `show_goals_tab/1` — goal list → display map list
  - `show_knowledge_tab/2` — KG stats + near-threshold nodes → display map
  - `show_preferences_tab/1` — prefs map → display map
  - `show_proposals_tab/2` — proposal list + stats → display map
  - `show_code_tab/1` — code entry list → display map list

  All functions tolerate `nil` and missing fields gracefully.
  """

  alias Arbor.Web.Helpers

  @code_truncate_chars 500
  @proposal_truncate_chars 300

  # ===========================================================================
  # Convert — per tab
  # ===========================================================================

  @doc """
  Format the identity tab: traits, values, granted capabilities.

  Returns a map with:
  - `:has_data?` — false when no self-knowledge is present
  - `:traits` — list of {name, strength_pct} tuples
  - `:values` — list of {name, importance_pct} tuples
  - `:capabilities` — sorted unique URI strings
  """
  @spec show_identity_tab(map() | nil, list(String.t()) | nil) :: map()
  def show_identity_tab(self_knowledge, security_caps) do
    %{
      has_data?: self_knowledge != nil,
      traits: extract_traits(self_knowledge),
      values: extract_values(self_knowledge),
      capabilities: security_caps || []
    }
  end

  @doc """
  Format the goals tab: a list of display-ready goal maps.

  Each goal becomes `%{description, status, status_color, type, priority,
  progress_pct, deadline}`. Empty list when no goals.
  """
  @spec show_goals_tab([map()] | nil) :: [map()]
  def show_goals_tab(nil), do: []
  def show_goals_tab([]), do: []

  def show_goals_tab(goals) when is_list(goals) do
    Enum.map(goals, fn goal ->
      progress = Map.get(goal, :progress, 0) || 0

      %{
        id: Map.get(goal, :id),
        description: Map.get(goal, :description, "—"),
        status: Map.get(goal, :status),
        status_color: goal_color(Map.get(goal, :status)),
        type: Map.get(goal, :type),
        priority: Map.get(goal, :priority),
        progress: progress,
        progress_pct: round(progress * 100),
        deadline: Map.get(goal, :deadline),
        deadline_label: format_deadline(Map.get(goal, :deadline))
      }
    end)
  end

  @doc """
  Format the knowledge graph tab: stat cards + near-threshold node list.

  Returns a map with:
  - `:stats` — node_count, edge_count, active_set_size, pending_count
  - `:near_threshold` — list of {type, content, relevance_rounded} maps
  """
  @spec show_knowledge_tab(map() | nil, [map()] | nil) :: map()
  def show_knowledge_tab(stats, near_threshold) do
    stats_map = stats || %{}

    %{
      stats: %{
        node_count: Map.get(stats_map, :node_count, 0),
        edge_count: Map.get(stats_map, :edge_count, 0),
        active_set_size: Map.get(stats_map, :active_set_size, 0),
        pending_count: Map.get(stats_map, :pending_count, 0)
      },
      near_threshold: format_near_threshold(near_threshold || [])
    }
  end

  @doc """
  Format the preferences tab: stat cards + type quotas + context preferences.

  Returns nil when no preferences exist.
  """
  @spec show_preferences_tab(map() | nil) :: map() | nil
  def show_preferences_tab(nil), do: nil
  def show_preferences_tab(prefs) when map_size(prefs) == 0, do: nil

  def show_preferences_tab(prefs) do
    %{
      decay_rate: Map.get(prefs, :decay_rate, "—"),
      retrieval_threshold: Map.get(prefs, :retrieval_threshold, "—"),
      pinned_count: Map.get(prefs, :pinned_count, 0),
      adjustment_count: Map.get(prefs, :adjustment_count, 0),
      type_quotas: Map.get(prefs, :type_quotas, %{}) |> Enum.to_list(),
      context_preferences: Map.get(prefs, :context_preferences, %{}) |> Enum.to_list()
    }
  end

  @doc """
  Format the proposals tab: stat cards + per-proposal display maps.

  Returns a map with:
  - `:stats` — pending, accepted, rejected, deferred counts
  - `:proposals` — list of display maps with type, confidence, status, content,
    is_pending? flag for action button visibility
  """
  @spec show_proposals_tab([map()] | nil, map() | nil) :: map()
  def show_proposals_tab(proposals, stats) do
    %{
      stats: %{
        pending: get_stat(stats, :pending),
        accepted: get_stat(stats, :accepted),
        rejected: get_stat(stats, :rejected),
        deferred: get_stat(stats, :deferred)
      },
      proposals: format_proposals(proposals || [])
    }
  end

  @doc """
  Format the code tab: a list of display-ready code entry maps.

  Each entry becomes `%{purpose, language, code, code_truncated}`.
  """
  @spec show_code_tab([map()] | nil) :: [map()]
  def show_code_tab(nil), do: []
  def show_code_tab([]), do: []

  def show_code_tab(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        id: Map.get(entry, :id),
        purpose: Map.get(entry, :purpose, "untitled"),
        language: Map.get(entry, :language),
        code: Map.get(entry, :code, ""),
        code_truncated: truncate_text(Map.get(entry, :code, ""), @code_truncate_chars)
      }
    end)
  end

  # ===========================================================================
  # Pure Helpers (visible for testing and reuse)
  # ===========================================================================

  @doc "Color for a goal status badge."
  @spec goal_color(atom() | nil) :: atom()
  def goal_color(:active), do: :green
  def goal_color(:achieved), do: :blue
  def goal_color(:abandoned), do: :red
  def goal_color(:failed), do: :red
  def goal_color(_), do: :gray

  @doc "Color for a proposal status badge (handles both atoms and strings)."
  @spec proposal_status_color(atom() | String.t() | nil) :: atom()
  def proposal_status_color(:pending), do: :yellow
  def proposal_status_color("pending"), do: :yellow
  def proposal_status_color(:accepted), do: :green
  def proposal_status_color("accepted"), do: :green
  def proposal_status_color(:rejected), do: :red
  def proposal_status_color("rejected"), do: :red
  def proposal_status_color(:deferred), do: :gray
  def proposal_status_color("deferred"), do: :gray
  def proposal_status_color(_), do: :gray

  @doc "Format a number 0..1 as a percent string."
  @spec format_pct(number() | nil) :: String.t()
  def format_pct(nil), do: "—"
  def format_pct(n) when is_number(n), do: "#{round(n * 100)}%"
  def format_pct(other), do: to_string(other)

  @doc "Format a deadline DateTime as YYYY-MM-DD."
  @spec format_deadline(DateTime.t() | nil | term()) :: String.t() | nil
  def format_deadline(nil), do: nil
  def format_deadline(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  def format_deadline(other), do: to_string(other)

  @doc "Tab label for a tab id."
  @spec tab_label(String.t()) :: String.t()
  def tab_label("working_memory"), do: "💭 Working Memory"
  def tab_label("identity"), do: "🪞 Identity"
  def tab_label("goals"), do: "🎯 Goals"
  def tab_label("knowledge"), do: "🕸️ Knowledge"
  def tab_label("preferences"), do: "⚙️ Preferences"
  def tab_label("proposals"), do: "📋 Proposals"
  def tab_label("code"), do: "💻 Code"
  def tab_label(other), do: other

  @doc """
  Extract personality traits from a self-knowledge map as `[{name, strength}]`.

  Handles both atom-keyed and string-keyed input variants.
  """
  @spec extract_traits(map() | nil) :: [{String.t(), number()}]
  def extract_traits(nil), do: []

  def extract_traits(sk) do
    Map.get(sk, :personality_traits, [])
    |> Enum.map(fn
      %{trait: name, strength: s} -> {to_string(name), s}
      %{"trait" => name, "strength" => s} -> {to_string(name), s}
      other -> {inspect(other), 0.5}
    end)
  end

  @doc """
  Extract values from a self-knowledge map as `[{name, importance}]`.
  """
  @spec extract_values(map() | nil) :: [{String.t(), number()}]
  def extract_values(nil), do: []

  def extract_values(sk) do
    Map.get(sk, :values, [])
    |> Enum.map(fn
      %{value: name, importance: i} -> {to_string(name), i}
      %{"value" => name, "importance" => i} -> {to_string(name), i}
      other -> {inspect(other), 0.5}
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp get_stat(nil, _key), do: 0
  defp get_stat(stats, key) when is_map(stats), do: Map.get(stats, key, 0)

  defp format_near_threshold(nodes) when is_list(nodes) do
    Enum.map(nodes, fn node ->
      %{
        type: Map.get(node, :type, :unknown),
        content: Map.get(node, :content) || Map.get(node, :name) || "—",
        relevance: Map.get(node, :relevance, 0) || 0,
        relevance_rounded: Float.round((Map.get(node, :relevance, 0) || 0) * 1.0, 3)
      }
    end)
  end

  defp format_proposals(proposals) when is_list(proposals) do
    Enum.map(proposals, fn proposal ->
      content = Map.get(proposal, :content) || Map.get(proposal, :description, "")
      status = Map.get(proposal, :status)
      confidence = Map.get(proposal, :confidence)

      %{
        id: Map.get(proposal, :id),
        type: Map.get(proposal, :type),
        confidence: confidence,
        confidence_pct: format_confidence(confidence),
        status: status,
        status_color: proposal_status_color(status),
        content: content,
        content_truncated: truncate_text(content, @proposal_truncate_chars),
        is_pending?: status == :pending or status == "pending"
      }
    end)
  end

  defp format_confidence(nil), do: nil
  defp format_confidence(c) when is_number(c), do: "#{round(c * 100)}%"
  defp format_confidence(_), do: nil

  defp truncate_text(text, limit) when is_binary(text) do
    Helpers.truncate(text, limit)
  end

  defp truncate_text(_, _), do: ""
end
