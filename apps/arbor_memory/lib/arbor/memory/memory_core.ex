defmodule Arbor.Memory.MemoryCore do
  @moduledoc """
  Pure CRC module for working memory and goal operations.

  All functions are pure — they take memory state in, return memory state out.
  No ETS, no GenServer calls, no persistence. The GenServer wrappers
  (GoalStore, IntentStore, WorkingMemory GenServer) handle side effects.

  ## CRC Pattern

  - **Construct**: `normalize_thought/1`, `normalize_goal/1` — coerce inputs
  - **Reduce**: `add_thought/2`, `update_goal_progress/3`, `complete_goal/2`, etc.
  - **Convert**: `for_prompt/2`, `for_dashboard/1`, `for_persistence/1`, etc.

  ## Pipeline Composability

      wm
      |> MemoryCore.add_thought("Learned something new")
      |> MemoryCore.update_goal_progress("goal_1", 0.75)
      |> MemoryCore.for_prompt(max_thoughts: 3)   # → prompt text for LLM
  """

  @default_max_thoughts 20

  # ===========================================================================
  # Construct — Normalize Inputs
  # ===========================================================================

  @doc "Normalize a thought to a structured record."
  @spec normalize_thought(String.t() | map()) :: map()
  def normalize_thought(thought) when is_binary(thought) do
    %{
      content: thought,
      timestamp: DateTime.utc_now(),
      cached_tokens: estimate_tokens(thought),
      referenced_date: nil
    }
  end

  def normalize_thought(%{content: _} = thought) do
    thought
    |> Map.put_new(:timestamp, DateTime.utc_now())
    |> Map.put_new(:cached_tokens, estimate_tokens(thought[:content] || ""))
    |> Map.put_new(:referenced_date, nil)
  end

  def normalize_thought(%{"content" => content} = thought) do
    %{
      content: content,
      timestamp: thought["timestamp"] || DateTime.utc_now(),
      cached_tokens: thought["cached_tokens"] || estimate_tokens(content),
      referenced_date: thought["referenced_date"]
    }
  end

  def normalize_thought(other), do: normalize_thought(inspect(other))

  @doc "Normalize a goal to a structured map with required fields."
  @spec normalize_goal(String.t() | map()) :: map()
  def normalize_goal(goal) when is_binary(goal) do
    %{
      id: generate_id("goal"),
      description: goal,
      type: :achieve,
      status: :active,
      priority: 50,
      progress: 0.0,
      added_at: DateTime.utc_now(),
      notes: [],
      metadata: %{}
    }
  end

  def normalize_goal(%{description: _} = goal) do
    goal
    |> Map.put_new(:id, generate_id("goal"))
    |> Map.put_new(:type, :achieve)
    |> Map.put_new(:status, :active)
    |> Map.put_new(:priority, 50)
    |> Map.put_new(:progress, 0.0)
    |> Map.put_new(:added_at, DateTime.utc_now())
    |> Map.put_new(:notes, [])
    |> Map.put_new(:metadata, %{})
  end

  def normalize_goal(%{"description" => desc} = goal) do
    normalize_goal(%{
      description: desc,
      type: safe_atom(goal["type"], :achieve),
      priority: goal["priority"] || 50,
      id: goal["id"]
    })
  end

  def normalize_goal(other), do: normalize_goal(inspect(other))

  # ===========================================================================
  # Reduce — Working Memory State Transitions
  # ===========================================================================

  @doc """
  Add a thought to working memory, trimming to max.

  Returns updated thoughts list.
  """
  @spec add_thought([map()], String.t() | map(), keyword()) :: [map()]
  def add_thought(thoughts, thought, opts \\ []) do
    record = normalize_thought(thought)
    max = Keyword.get(opts, :max_thoughts, @default_max_thoughts)
    Enum.take([record | thoughts], max)
  end

  @doc "Update concerns list."
  @spec set_concerns([String.t()], [String.t()]) :: [String.t()]
  def set_concerns(_old, new) when is_list(new), do: new

  @doc "Update curiosity list."
  @spec set_curiosity([String.t()], [String.t()]) :: [String.t()]
  def set_curiosity(_old, new) when is_list(new), do: new

  @doc "Add a concern if not already present."
  @spec add_concern([String.t()], String.t()) :: [String.t()]
  def add_concern(concerns, concern) when is_binary(concern) do
    if concern in concerns, do: concerns, else: [concern | concerns]
  end

  @doc "Add a curiosity item if not already present."
  @spec add_curiosity([String.t()], String.t()) :: [String.t()]
  def add_curiosity(curiosity, item) when is_binary(item) do
    if item in curiosity, do: curiosity, else: [item | curiosity]
  end

  # ===========================================================================
  # Reduce — Goal State Transitions
  # ===========================================================================

  @doc "Update goal progress (0.0 to 1.0, bounds-checked)."
  @spec update_goal_progress([map()], String.t(), number()) :: [map()]
  def update_goal_progress(goals, goal_id, progress) when is_number(progress) do
    progress = max(0.0, min(1.0, progress))

    Enum.map(goals, fn goal ->
      if goal[:id] == goal_id or goal.id == goal_id do
        Map.put(goal, :progress, progress)
      else
        goal
      end
    end)
  end

  @doc "Mark a goal as achieved."
  @spec achieve_goal([map()], String.t()) :: {[map()], map() | nil}
  def achieve_goal(goals, goal_id) do
    case Enum.split_with(goals, fn g -> g[:id] == goal_id end) do
      {[goal], rest} ->
        achieved = %{goal | status: :achieved, progress: 1.0}
        {rest, achieved}

      _ ->
        {goals, nil}
    end
  end

  @doc "Mark a goal as abandoned."
  @spec abandon_goal([map()], String.t(), String.t() | nil) :: {[map()], map() | nil}
  def abandon_goal(goals, goal_id, reason \\ nil) do
    case Enum.split_with(goals, fn g -> g[:id] == goal_id end) do
      {[goal], rest} ->
        abandoned =
          goal
          |> Map.put(:status, :abandoned)
          |> then(fn g ->
            if reason, do: Map.update(g, :notes, [reason], &[reason | &1]), else: g
          end)

        {rest, abandoned}

      _ ->
        {goals, nil}
    end
  end

  @doc "Mark a goal as failed."
  @spec fail_goal([map()], String.t(), String.t() | nil) :: {[map()], map() | nil}
  def fail_goal(goals, goal_id, reason \\ nil) do
    case Enum.split_with(goals, fn g -> g[:id] == goal_id end) do
      {[goal], rest} ->
        failed =
          goal
          |> Map.put(:status, :failed)
          |> then(fn g ->
            if reason, do: Map.update(g, :notes, [reason], &["Failed: #{reason}" | &1]), else: g
          end)

        {rest, failed}

      _ ->
        {goals, nil}
    end
  end

  @doc "Add a note to a goal."
  @spec add_goal_note([map()], String.t(), String.t()) :: [map()]
  def add_goal_note(goals, goal_id, note) do
    Enum.map(goals, fn goal ->
      if goal[:id] == goal_id do
        Map.update(goal, :notes, [note], &[note | &1])
      else
        goal
      end
    end)
  end

  @doc "Sort goals by priority (highest first) then progress (lowest first)."
  @spec sort_goals([map()]) :: [map()]
  def sort_goals(goals) do
    Enum.sort_by(goals, fn g -> {-(g[:priority] || 0), g[:progress] || 0.0} end)
  end

  @doc """
  Merge LLM goal updates into existing goals.

  Handles: new goals, progress updates, status changes.
  """
  @spec apply_goal_changes([map()], [map()]) :: [map()]
  def apply_goal_changes(existing, updates) when is_list(updates) do
    Enum.reduce(updates, existing, fn update, goals ->
      case find_matching_goal(goals, update) do
        nil ->
          # New goal
          [normalize_goal(update) | goals]

        {idx, _existing_goal} ->
          # Update existing
          List.update_at(goals, idx, fn g ->
            g
            |> maybe_update(:progress, update[:progress] || update["progress"])
            |> maybe_update(:status, safe_atom(update[:status] || update["status"], nil))
            |> maybe_update(:priority, update[:priority] || update["priority"])
          end)
      end
    end)
  end

  def apply_goal_changes(existing, _), do: existing

  # ===========================================================================
  # Reduce — Intent Filtering
  # ===========================================================================

  @doc "Filter intents by type."
  @spec filter_by_type([map()], atom()) :: [map()]
  def filter_by_type(intents, type) do
    Enum.filter(intents, &(&1[:type] == type or &1.type == type))
  end

  @doc "Filter intents created since a given time."
  @spec filter_since([map()], DateTime.t()) :: [map()]
  def filter_since(intents, since) do
    Enum.filter(intents, fn intent ->
      ts = intent[:created_at] || intent.created_at
      ts && DateTime.compare(ts, since) in [:gt, :eq]
    end)
  end

  @doc "Filter intents for a specific goal."
  @spec filter_by_goal([map()], String.t()) :: [map()]
  def filter_by_goal(intents, goal_id) do
    Enum.filter(intents, &(&1[:goal_id] == goal_id))
  end

  # ===========================================================================
  # Convert — Consumer-Specific Views
  # ===========================================================================

  @doc """
  Format working memory for LLM prompt injection.

  Returns a structured text block with thoughts, goals, concerns, curiosity.
  """
  @spec for_prompt(map(), keyword()) :: String.t()
  def for_prompt(wm, opts \\ []) do
    max_thoughts = Keyword.get(opts, :max_thoughts, 5)

    sections = []

    sections =
      case wm[:recent_thoughts] || wm.recent_thoughts do
        thoughts when is_list(thoughts) and thoughts != [] ->
          text =
            thoughts
            |> Enum.take(max_thoughts)
            |> Enum.map(fn t -> "- #{thought_content(t)}" end)
            |> Enum.join("\n")

          ["## Recent Thoughts\n#{text}" | sections]

        _ ->
          sections
      end

    sections =
      case wm[:active_goals] || wm.active_goals do
        goals when is_list(goals) and goals != [] ->
          text =
            goals
            |> Enum.map(fn g ->
              progress = Float.round((g[:progress] || 0.0) * 100, 0)
              "- [#{progress}%] #{g[:description] || g.description}"
            end)
            |> Enum.join("\n")

          ["## Active Goals\n#{text}" | sections]

        _ ->
          sections
      end

    sections =
      case wm[:concerns] || wm.concerns do
        concerns when is_list(concerns) and concerns != [] ->
          text = Enum.map_join(concerns, "\n", &"- #{&1}")
          ["## Concerns\n#{text}" | sections]

        _ ->
          sections
      end

    sections =
      case wm[:curiosity] || wm.curiosity do
        curiosity when is_list(curiosity) and curiosity != [] ->
          text = Enum.map_join(curiosity, "\n", &"- #{&1}")
          ["## Curiosity\n#{text}" | sections]

        _ ->
          sections
      end

    sections |> Enum.reverse() |> Enum.join("\n\n")
  end

  @doc "Format working memory for dashboard display."
  @spec for_dashboard(map()) :: map()
  def for_dashboard(wm) do
    %{
      agent_id: wm[:agent_id] || wm.agent_id,
      thought_count: length(wm[:recent_thoughts] || []),
      goal_count: length(wm[:active_goals] || []),
      active_goals:
        (wm[:active_goals] || [])
        |> Enum.filter(&(&1[:status] == :active))
        |> Enum.map(fn g ->
          %{
            id: g[:id],
            description: g[:description],
            progress: g[:progress] || 0.0,
            priority: g[:priority] || 50
          }
        end),
      concerns: wm[:concerns] || [],
      curiosity: wm[:curiosity] || [],
      engagement_level: wm[:engagement_level] || 0.5
    }
  end

  @doc "Format working memory for persistence (JSON-safe map)."
  @spec for_persistence(map()) :: map()
  def for_persistence(wm) do
    %{
      "agent_id" => wm[:agent_id] || wm.agent_id,
      "recent_thoughts" => Enum.map(wm[:recent_thoughts] || [], &serialize_thought/1),
      "active_goals" => Enum.map(wm[:active_goals] || [], &serialize_goal/1),
      "concerns" => wm[:concerns] || [],
      "curiosity" => wm[:curiosity] || [],
      "engagement_level" => wm[:engagement_level] || 0.5,
      "thought_count" => wm[:thought_count] || length(wm[:recent_thoughts] || [])
    }
  end

  @doc "Format condensed context for heartbeat pipeline."
  @spec for_heartbeat(map(), keyword()) :: map()
  def for_heartbeat(wm, opts \\ []) do
    max_thoughts = Keyword.get(opts, :max_thoughts, 3)

    %{
      recent_thoughts:
        (wm[:recent_thoughts] || [])
        |> Enum.take(max_thoughts)
        |> Enum.map(&thought_content/1),
      active_goals:
        (wm[:active_goals] || [])
        |> Enum.filter(&(&1[:status] == :active))
        |> Enum.map(fn g -> %{id: g[:id], description: g[:description], progress: g[:progress]} end),
      concerns: Enum.take(wm[:concerns] || [], 3),
      curiosity: Enum.take(wm[:curiosity] || [], 3)
    }
  end

  @doc "Summarize goals for telemetry."
  @spec goal_summary([map()]) :: map()
  def goal_summary(goals) when is_list(goals) do
    active = Enum.filter(goals, &(&1[:status] == :active))
    achieved = Enum.filter(goals, &(&1[:status] == :achieved))

    avg_progress =
      if active != [] do
        active |> Enum.map(&(&1[:progress] || 0.0)) |> Enum.sum() |> Kernel./(length(active))
      else
        0.0
      end

    %{
      total: length(goals),
      active: length(active),
      achieved: length(achieved),
      failed: Enum.count(goals, &(&1[:status] == :failed)),
      abandoned: Enum.count(goals, &(&1[:status] == :abandoned)),
      avg_progress: Float.round(avg_progress, 2)
    }
  end

  def goal_summary(_), do: %{total: 0, active: 0, achieved: 0, failed: 0, abandoned: 0, avg_progress: 0.0}

  # ===========================================================================
  # Private
  # ===========================================================================

  defp thought_content(%{content: c}), do: c
  defp thought_content(%{"content" => c}), do: c
  defp thought_content(t) when is_binary(t), do: t
  defp thought_content(t), do: inspect(t)

  defp estimate_tokens(text) when is_binary(text), do: div(String.length(text), 4) + 1
  defp estimate_tokens(_), do: 0

  defp generate_id(prefix) do
    "#{prefix}_#{:erlang.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()}"
  end

  defp safe_atom(nil, default), do: default
  defp safe_atom(a, _default) when is_atom(a), do: a
  defp safe_atom(s, default) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> default
    end
  end
  defp safe_atom(_, default), do: default

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  defp find_matching_goal(goals, update) do
    id = update[:id] || update["id"]
    desc = update[:description] || update["description"]

    goals
    |> Enum.with_index()
    |> Enum.find(fn {g, _idx} ->
      (id != nil and g[:id] == id) or (desc != nil and g[:description] == desc)
    end)
    |> case do
      {goal, idx} -> {idx, goal}
      nil -> nil
    end
  end

  defp serialize_thought(%{content: c, timestamp: ts}) do
    %{"content" => c, "timestamp" => to_string(ts)}
  end

  defp serialize_thought(%{"content" => _} = t), do: t
  defp serialize_thought(t) when is_binary(t), do: %{"content" => t}
  defp serialize_thought(t), do: %{"content" => inspect(t)}

  defp serialize_goal(goal) when is_map(goal) do
    Map.new(goal, fn
      {k, v} when is_atom(k) -> {to_string(k), serialize_value(v)}
      {k, v} -> {k, serialize_value(v)}
    end)
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(a) when is_atom(a), do: to_string(a)
  defp serialize_value(v), do: v
end
