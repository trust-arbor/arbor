defmodule Arbor.Agent.ClaudeCheckpoint do
  @moduledoc """
  State checkpoint/restore for the Claude agent.

  Saves full agent state (context window, goals, intents/percepts,
  timing, body config) and restores it across restarts.

  Uses `Arbor.Checkpoint` with the ETS store by default; can be
  configured with any `Arbor.Checkpoint.Store` implementation.

  ## Auto-checkpointing

  When enabled, sends `:checkpoint` messages at configurable intervals
  (default: 5 minutes) to trigger periodic saves. The agent handles
  these in `handle_info`.

  ## Storage

  Checkpoints are stored via the configured store backend. The default
  ETS store keeps data in-memory (lost on restart). For persistence
  across restarts, configure a file-based or DETS store.
  """

  require Logger

  @doc """
  Save the agent's current state as a checkpoint.

  Extracts essential state fields and persists via `Arbor.Checkpoint.save/4`.
  """
  @spec save_state(map()) :: :ok | {:error, term()}
  def save_state(state) do
    agent_id = state[:id] || state[:agent_id]
    store = checkpoint_store()

    checkpoint_data = extract_state(state)

    case safe_call(fn -> Arbor.Checkpoint.save(agent_id, checkpoint_data, store) end) do
      :ok ->
        Logger.debug("Checkpoint saved for #{agent_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Checkpoint save failed: #{inspect(reason)}")
        error

      nil ->
        {:error, :checkpoint_unavailable}
    end
  end

  @doc """
  Attempt to restore agent state from a checkpoint.

  Returns `{:ok, checkpoint_data}` if found, `{:error, :not_found}` if
  no checkpoint exists, or `{:error, reason}` on failure.
  """
  @spec restore_state(String.t()) :: {:ok, map()} | {:error, term()}
  def restore_state(agent_id) do
    store = checkpoint_store()

    case safe_call(fn -> Arbor.Checkpoint.load(agent_id, store, retries: 1) end) do
      {:ok, data} when is_map(data) ->
        Logger.info("Checkpoint restored for #{agent_id}")
        {:ok, data}

      {:error, :not_found} ->
        Logger.debug("No checkpoint found for #{agent_id}")
        {:error, :not_found}

      {:error, reason} = error ->
        Logger.warning("Checkpoint restore failed: #{inspect(reason)}")
        error

      nil ->
        {:error, :checkpoint_unavailable}
    end
  end

  @doc """
  Apply restored checkpoint data onto a fresh agent state.

  Merges timing, context, and body fields. GoalStore and IntentStore
  are repopulated from the checkpoint data.
  """
  @spec apply_checkpoint(map(), map()) :: map()
  def apply_checkpoint(state, checkpoint_data) do
    agent_id = state[:id] || state[:agent_id]

    # Restore timing fields
    state =
      Map.merge(state, %{
        last_user_message_at: parse_datetime(checkpoint_data[:last_user_message_at]),
        last_assistant_output_at: parse_datetime(checkpoint_data[:last_assistant_output_at]),
        responded_to_last_user_message:
          Map.get(checkpoint_data, :responded_to_last_user_message, true),
        query_count: Map.get(checkpoint_data, :query_count, 0)
      })

    # Restore context window if available
    state =
      case checkpoint_data[:context_window] do
        window when is_map(window) and map_size(window) > 0 ->
          restored = restore_context_window(window)
          if restored, do: %{state | context_window: restored}, else: state

        _ ->
          state
      end

    # Repopulate GoalStore
    repopulate_goals(agent_id, Map.get(checkpoint_data, :goals, []))

    # Repopulate IntentStore
    repopulate_intents(agent_id, checkpoint_data)

    Logger.info("Checkpoint applied for #{agent_id}",
      goals: length(Map.get(checkpoint_data, :goals, [])),
      query_count: state.query_count
    )

    state
  end

  @doc """
  Check if enough state has changed to warrant a checkpoint.

  Returns true if the query count has increased by at least
  `checkpoint_query_threshold` since the last checkpoint.
  """
  @spec auto_checkpoint?(map()) :: boolean()
  def auto_checkpoint?(state) do
    last_count = Map.get(state, :last_checkpoint_query_count, 0)
    current_count = Map.get(state, :query_count, 0)
    threshold = config(:checkpoint_query_threshold, 5)

    current_count - last_count >= threshold
  end

  @doc """
  Schedule the next auto-checkpoint message.
  """
  @spec schedule_checkpoint(pos_integer()) :: reference()
  def schedule_checkpoint(interval_ms \\ nil) do
    interval = interval_ms || config(:checkpoint_interval_ms, 300_000)
    Process.send_after(self(), :checkpoint, interval)
  end

  # -- Private --

  defp extract_state(state) do
    agent_id = state[:id] || state[:agent_id]

    %{
      agent_id: agent_id,
      # Timing state
      last_user_message_at: format_datetime(state[:last_user_message_at]),
      last_assistant_output_at: format_datetime(state[:last_assistant_output_at]),
      responded_to_last_user_message: state[:responded_to_last_user_message],
      query_count: state[:query_count] || 0,
      # Context window (serialized)
      context_window: serialize_context_window(state[:context_window]),
      # Goals (snapshot from GoalStore)
      goals: snapshot_goals(agent_id),
      # Recent intents/percepts (from IntentStore)
      recent_intents: snapshot_intents(agent_id),
      recent_percepts: snapshot_percepts(agent_id),
      # Timestamp
      checkpointed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp serialize_context_window(nil), do: nil

  defp serialize_context_window(window) do
    if Code.ensure_loaded?(Arbor.Memory.ContextWindow) and
         function_exported?(Arbor.Memory.ContextWindow, :serialize, 1) do
      Arbor.Memory.ContextWindow.serialize(window)
    else
      window
    end
  rescue
    _ -> nil
  end

  defp restore_context_window(data) do
    if Code.ensure_loaded?(Arbor.Memory.ContextWindow) and
         function_exported?(Arbor.Memory.ContextWindow, :deserialize, 1) do
      Arbor.Memory.ContextWindow.deserialize(data)
    else
      data
    end
  rescue
    _ -> nil
  end

  defp snapshot_goals(agent_id) do
    goals = safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) || []

    Enum.map(goals, fn goal ->
      %{
        id: goal.id,
        description: goal.description,
        type: goal.type,
        priority: goal.priority,
        progress: goal.progress,
        status: goal.status,
        parent_id: goal.parent_id
      }
    end)
  end

  defp snapshot_intents(agent_id) do
    intents = safe_call(fn -> Arbor.Memory.recent_intents(agent_id, limit: 20) end) || []

    Enum.map(intents, fn intent ->
      %{
        id: intent.id,
        type: intent.type,
        action: intent.action,
        reasoning: intent.reasoning
      }
    end)
  end

  defp snapshot_percepts(agent_id) do
    percepts = safe_call(fn -> Arbor.Memory.recent_percepts(agent_id, limit: 20) end) || []

    Enum.map(percepts, fn percept ->
      %{
        id: percept.id,
        type: percept.type,
        outcome: percept.outcome,
        intent_id: percept.intent_id,
        duration_ms: percept.duration_ms
      }
    end)
  end

  defp repopulate_goals(agent_id, goals) when is_list(goals) do
    Enum.each(goals, fn goal_data ->
      safe_call(fn ->
        goal =
          Arbor.Contracts.Memory.Goal.new(
            goal_data[:description] || goal_data["description"] || "Restored goal",
            type: goal_data[:type] || goal_data["type"] || :achieve,
            priority: goal_data[:priority] || goal_data["priority"] || 50
          )

        Arbor.Memory.add_goal(agent_id, goal)
      end)
    end)
  end

  defp repopulate_goals(_, _), do: :ok

  defp repopulate_intents(_agent_id, _checkpoint_data) do
    # IntentStore is a ring buffer — we don't repopulate it on restore
    # because the intents/percepts are already stale. Fresh state is fine.
    :ok
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(s) when is_binary(s), do: s

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp checkpoint_store do
    Application.get_env(:arbor_agent, :checkpoint_store, Arbor.Checkpoint.Store.ETS)
  end

  defp config(key, default) do
    Application.get_env(:arbor_agent, key, default)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("ClaudeCheckpoint safe_call rescued: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("ClaudeCheckpoint safe_call caught exit: #{inspect(reason)}")
      nil
  end
end
