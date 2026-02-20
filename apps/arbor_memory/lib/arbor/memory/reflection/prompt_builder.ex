defmodule Arbor.Memory.Reflection.PromptBuilder do
  @moduledoc """
  Builds structured reflection prompts for deep reflection.

  Extracted from `Arbor.Memory.ReflectionProcessor` — handles goal formatting,
  self-knowledge formatting, type conversions, and the main reflection prompt
  template assembly.
  """

  alias Arbor.Common.PromptSanitizer

  @doc """
  Build the full reflection prompt from a deep context map.
  """
  def build_reflection_prompt(context) do
    nonce = PromptSanitizer.generate_nonce()

    """
    You are performing a deep reflection on recent experiences. Your PRIMARY PURPOSE is to:
    1. **EVALUATE PROGRESS ON ACTIVE GOALS** - This is your most important task
    2. Identify patterns and connections relevant to your goals
    3. Note relationship dynamics that affect your work
    4. Consolidate learnings
    5. Discover knowledge graph relationships

    #{PromptSanitizer.preamble(nonce)}

    ## Current Identity Context
    #{PromptSanitizer.wrap(context.self_knowledge_text, nonce)}

    ## ACTIVE GOALS - EVALUATE EACH ONE
    #{PromptSanitizer.wrap(context.goals_text, nonce)}

    ## Current Knowledge Graph
    #{PromptSanitizer.wrap(context.knowledge_graph_text, nonce)}

    ## Working Memory
    #{PromptSanitizer.wrap(context.working_memory_text, nonce)}

    ## Recent Thinking
    #{PromptSanitizer.wrap(context.recent_thinking_text, nonce)}

    ## Recent Activity
    #{PromptSanitizer.wrap(context.recent_activity_text, nonce)}

    ## Instructions

    **GOAL EVALUATION IS YOUR TOP PRIORITY.** For each active goal:
    - What progress was made? (estimate new percentage)
    - What blockers or challenges exist?
    - What's the next concrete step?
    - Should this goal be marked achieved, failed, or blocked?

    Also reflect on:
    - Patterns in the ACTUAL WORK being done (not system behavior)
    - Relationship dynamics (what matters to the human you're working with)
    - Technical learnings relevant to the project/codebase
    - New goals that emerged from the work
    - Entities (people, projects, concepts) and their relationships

    **DO NOT** create learnings or insights about:
    - How the system/framework works internally
    - Meta-observations about your own behavior or the heartbeat loop
    - Obvious facts about conversation flow or goal tracking
    - System implementation details

    Respond in JSON format:
    {
      "thinking": "Your reflection process, especially about goal progress...",
      "goal_updates": [
        {
          "goal_id": "the goal ID from above",
          "new_progress": 0.45,
          "status": "active|achieved|failed|blocked|abandoned",
          "note": "What happened with this goal",
          "next_step": "The next concrete action to take",
          "blockers": ["any blockers identified"]
        }
      ],
      "new_goals": [
        {
          "description": "A new goal that emerged",
          "priority": "critical|high|medium|low",
          "type": "achieve|maintain|explore|learn",
          "parent_goal_id": "optional - if this is a subgoal"
        }
      ],
      "insights": [
        {"content": "An insight about patterns or meaning", "importance": 0.7, "related_goal_id": "optional"}
      ],
      "learnings": [
        {"content": "Something meaningful learned", "confidence": 0.8, "category": "technical|relationship|self"}
      ],
      "knowledge_nodes": [
        {"name": "entity name", "type": "person|project|concept|tool|goal", "context": "brief context"}
      ],
      "knowledge_edges": [
        {"from": "entity name", "to": "other entity name", "relationship": "knows|worked_on|uses|advances_goal|blocks_goal|related_to"}
      ],
      "self_insight_suggestions": [
        {
          "content": "I tend to be curious and ask clarifying questions before acting",
          "category": "personality|capability|value|preference",
          "confidence": 0.4,
          "evidence": ["asked 3 questions before starting"]
        }
      ]
    }

    **Important:** Include goal_updates for EVERY active goal, even if just to note "no progress this cycle".
    Link insights and knowledge nodes to goals when relevant.
    """
  end

  # ── Self-Knowledge Formatting ──────────────────────────────────────

  @doc false
  def format_self_knowledge(sk) do
    parts = []

    parts =
      if sk.capabilities != [] do
        caps =
          Enum.map_join(sk.capabilities, "\n", fn c ->
            "  - #{c.name}: #{Float.round(c.proficiency * 100, 0)}%"
          end)

        parts ++ ["## Capabilities\n#{caps}"]
      else
        parts
      end

    parts =
      if sk.personality_traits != [] do
        traits =
          Enum.map_join(sk.personality_traits, "\n", fn t ->
            "  - #{t.trait}: #{Float.round(t.strength * 100, 0)}%"
          end)

        parts ++ ["## Personality Traits\n#{traits}"]
      else
        parts
      end

    parts =
      if sk.values != [] do
        vals =
          Enum.map_join(sk.values, "\n", fn v ->
            "  - #{v.value}: #{Float.round(v.importance * 100, 0)}%"
          end)

        parts ++ ["## Values\n#{vals}"]
      else
        parts
      end

    if parts == [] do
      "(Self-knowledge initialized but no entries yet)"
    else
      Enum.join(parts, "\n\n")
    end
  end

  # ── Goal Formatting ────────────────────────────────────────────────

  @doc false
  def format_goals_for_prompt([]) do
    "(No active goals)"
  end

  def format_goals_for_prompt(goals) do
    {blocked, active} = Enum.split_with(goals, &(&1.status == :blocked))

    sorted_active =
      active
      |> Enum.sort_by(&goal_urgency/1, :desc)

    active_text =
      if sorted_active == [] do
        ""
      else
        Enum.map_join(sorted_active, "\n\n", &format_single_goal/1)
      end

    blocked_text =
      if blocked == [] do
        ""
      else
        header = "\n\n### Blocked Goals\n"
        items = Enum.map_join(blocked, "\n\n", &format_blocked_goal/1)
        header <> items
      end

    (active_text <> blocked_text)
    |> String.trim()
    |> case do
      "" -> "(No active goals)"
      text -> text
    end
  end

  @doc false
  def format_single_goal(goal) do
    emoji = priority_emoji(goal.priority)
    progress_pct = Float.round(goal.progress * 100, 0)
    bar_filled = round(goal.progress * 20)
    bar_empty = 20 - bar_filled
    bar = String.duplicate("█", bar_filled) <> String.duplicate("░", bar_empty)
    deadline = deadline_text(goal)

    base =
      "- #{emoji} [#{goal.id}] #{goal.description}#{deadline}\n" <>
        "  Priority: #{goal.priority} | Type: #{goal.type} | " <>
        "Progress: #{bar} #{progress_pct}%"

    base
    |> maybe_append_criteria(goal)
    |> maybe_append_notes(goal)
  end

  @doc false
  def format_blocked_goal(goal) do
    emoji = priority_emoji(goal.priority)
    blockers = get_in(goal.metadata || %{}, [:blockers]) || []

    blockers_text =
      if blockers == [] do
        ""
      else
        "\n  Blocked by: " <> Enum.join(blockers, ", ")
      end

    "- #{emoji} [BLOCKED] [#{goal.id}] #{goal.description}#{blockers_text}"
  end

  defp maybe_append_criteria(text, goal) do
    criteria = goal.success_criteria || get_in(goal.metadata || %{}, [:success_criteria])

    case criteria do
      nil -> text
      "" -> text
      c -> text <> "\n  Success criteria: #{c}"
    end
  end

  defp maybe_append_notes(text, goal) do
    notes =
      case goal.notes do
        [] -> get_in(goal.metadata || %{}, [:notes]) || []
        n when is_list(n) -> n
        _ -> []
      end

    case notes do
      [] -> text
      ns ->
        recent = Enum.take(ns, -3)
        notes_text = Enum.map_join(recent, "\n", &("    - " <> to_string(&1)))
        text <> "\n  Recent notes:\n#{notes_text}"
    end
  end

  # ── Urgency & Deadline ─────────────────────────────────────────────

  @doc false
  def goal_urgency(goal) do
    deadline = goal.deadline || get_in(goal.metadata || %{}, [:deadline])

    overdue_factor =
      case deadline do
        nil -> 0.0
        d when is_binary(d) ->
          case DateTime.from_iso8601(d) do
            {:ok, dt, _} -> deadline_urgency_factor(dt)
            _ -> 0.0
          end
        %DateTime{} = dt -> deadline_urgency_factor(dt)
        _ -> 0.0
      end

    goal.priority * (1.0 + overdue_factor)
  end

  defp deadline_urgency_factor(deadline) do
    hours = DateTime.diff(deadline, DateTime.utc_now(), :hour)

    cond do
      hours < 0 -> 2.0
      hours < 24 -> 1.0
      hours < 168 -> 0.5
      true -> 0.0
    end
  end

  @doc false
  def priority_emoji(priority) when is_integer(priority) do
    cond do
      priority >= 80 -> "🔴"
      priority >= 60 -> "🟠"
      priority >= 40 -> "🟡"
      true -> "🟢"
    end
  end

  def priority_emoji(_), do: "🟡"

  defp deadline_text(goal) do
    deadline = goal.deadline || get_in(goal.metadata || %{}, [:deadline])

    case deadline do
      nil -> ""
      d when is_binary(d) ->
        case DateTime.from_iso8601(d) do
          {:ok, dt, _} -> format_deadline(dt)
          _ -> ""
        end
      %DateTime{} = dt -> format_deadline(dt)
      _ -> ""
    end
  end

  defp format_deadline(deadline) do
    hours = DateTime.diff(deadline, DateTime.utc_now(), :hour)

    cond do
      hours < 0 -> " ⚠️ OVERDUE"
      hours < 24 -> " ⏰ Due in #{hours}h"
      hours < 168 -> " Due in #{div(hours, 24)}d"
      true -> ""
    end
  end

  # ── Type Conversions ───────────────────────────────────────────────

  @doc """
  Convert string priority to integer (0-100).
  """
  def atomize_priority_to_int(nil), do: 50
  def atomize_priority_to_int("critical"), do: 90
  def atomize_priority_to_int("high"), do: 70
  def atomize_priority_to_int("medium"), do: 50
  def atomize_priority_to_int("low"), do: 30
  def atomize_priority_to_int(_), do: 50

  @doc """
  Convert string goal type to atom.
  """
  def atomize_type(nil), do: :achieve
  def atomize_type("achieve"), do: :achieve
  def atomize_type("achievement"), do: :achieve
  def atomize_type("maintain"), do: :maintain
  def atomize_type("maintenance"), do: :maintain
  def atomize_type("explore"), do: :explore
  def atomize_type("exploration"), do: :explore
  def atomize_type("learn"), do: :learn
  def atomize_type(_), do: :achieve

  @doc """
  Convert string node type to internal knowledge type atom.
  """
  def safe_node_type(nil), do: :concept
  def safe_node_type("person"), do: :relationship
  def safe_node_type("project"), do: :experience
  def safe_node_type("concept"), do: :fact
  def safe_node_type("tool"), do: :skill
  def safe_node_type("goal"), do: :insight
  def safe_node_type(_), do: :fact
end
