defmodule Arbor.Memory.Reflection.GoalProcessor do
  @moduledoc """
  Processes goal updates and new goals from reflection responses.

  Extracted from `Arbor.Memory.ReflectionProcessor` — handles applying
  goal progress updates, status changes, and creating new goals from
  LLM reflection output.
  """

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Memory.{GoalStore, Signals}
  alias Arbor.Memory.Reflection.PromptBuilder

  require Logger

  @doc """
  Process goal updates from a reflection response.

  Applies progress changes, status transitions, and notes to existing goals.
  """
  def process_goal_updates(agent_id, goal_updates) do
    Enum.each(goal_updates, fn update ->
      goal_id = update["goal_id"]

      if goal_id do
        process_single_goal_update(agent_id, goal_id, update)
      end
    end)
  end

  @doc """
  Process new goals from a reflection response.

  Creates new goals from LLM suggestions, filtering out invalid entries.
  """
  def process_new_goals(agent_id, new_goals) do
    new_goals
    |> Enum.filter(&valid_goal_description?/1)
    |> Enum.each(&create_goal_from_data(agent_id, &1))
  end

  # ── Single Goal Update ─────────────────────────────────────────────

  defp process_single_goal_update(agent_id, goal_id, update) do
    # Update progress
    if update["new_progress"] do
      progress = min(1.0, max(0.0, update["new_progress"]))
      GoalStore.update_goal_progress(agent_id, goal_id, progress)
    end

    # Update status
    case update["status"] do
      "achieved" ->
        GoalStore.achieve_goal(agent_id, goal_id)

      "abandoned" ->
        GoalStore.abandon_goal(agent_id, goal_id, update["note"])

      "blocked" ->
        GoalStore.block_goal(agent_id, goal_id, update["blockers"])

      "failed" ->
        GoalStore.fail_goal(agent_id, goal_id, update["note"])

      _ ->
        :ok
    end

    # Store notes in goal metadata if present
    if update["note"] do
      accumulate_goal_note(agent_id, goal_id, update["note"])
    end

    Signals.emit_reflection_goal_update(agent_id, goal_id, update)

    Logger.debug("Goal updated via reflection",
      agent_id: agent_id,
      goal_id: goal_id,
      progress: update["new_progress"],
      status: update["status"]
    )
  rescue
    ArgumentError ->
      Logger.debug("Invalid goal update data",
        agent_id: agent_id,
        goal_id: goal_id
      )
  end

  # ── Goal Creation ──────────────────────────────────────────────────

  defp valid_goal_description?(goal_data) do
    desc = goal_data["description"]
    desc != nil and desc != ""
  end

  defp create_goal_from_data(agent_id, goal_data) do
    goal =
      Goal.new(goal_data["description"],
        type: PromptBuilder.atomize_type(goal_data["type"]),
        priority: PromptBuilder.atomize_priority_to_int(goal_data["priority"]),
        success_criteria: goal_data["success_criteria"],
        notes: if(goal_data["note"], do: [goal_data["note"]], else: [])
      )

    goal = maybe_set_parent(goal, goal_data["parent_goal_id"])

    case GoalStore.add_goal(agent_id, goal) do
      {:ok, saved_goal} ->
        Signals.emit_reflection_goal_created(agent_id, saved_goal.id, goal_data)

        Logger.info("New goal created via reflection",
          agent_id: agent_id,
          goal_id: saved_goal.id,
          description: goal_data["description"]
        )

      _ ->
        :ok
    end
  end

  defp accumulate_goal_note(agent_id, goal_id, note) do
    timestamped_note = "#{DateTime.utc_now() |> DateTime.to_iso8601()}: #{note}"
    GoalStore.add_note(agent_id, goal_id, timestamped_note)
  end

  defp maybe_set_parent(goal, nil), do: goal
  defp maybe_set_parent(goal, parent_id), do: %{goal | parent_id: parent_id}
end
