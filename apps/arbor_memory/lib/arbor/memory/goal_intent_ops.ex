defmodule Arbor.Memory.GoalIntentOps do
  @moduledoc """
  Sub-facade for goal management, intent/percept lifecycle, and bridge operations.

  Handles BDI goal store, intent queue with peek-lock-ack pattern,
  percept recording, and Mind-Body bridge communication.

  This module is not intended to be called directly by external consumers.
  Use `Arbor.Memory` as the public API.
  """

  alias Arbor.Memory.{
    Bridge,
    GoalStore,
    IntentStore
  }

  # ============================================================================
  # Goals (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Add a goal for an agent.

  Accepts a `Goal` struct or a description string with options.

  ## Examples

      goal = Goal.new("Fix the login bug", type: :achieve, priority: 80)
      {:ok, goal} = Arbor.Memory.add_goal("agent_001", goal)
  """
  @spec add_goal(String.t(), struct()) :: {:ok, struct()}
  defdelegate add_goal(agent_id, goal), to: GoalStore

  @doc """
  Get all active goals for an agent, sorted by priority.
  """
  @spec get_active_goals(String.t()) :: [struct()]
  defdelegate get_active_goals(agent_id), to: GoalStore

  @doc """
  Get all goals for an agent, regardless of status.
  """
  @spec get_all_goals(String.t()) :: [struct()]
  defdelegate get_all_goals(agent_id), to: GoalStore

  @doc """
  Get a specific goal by ID.
  """
  @spec get_goal(String.t(), String.t()) :: {:ok, struct()} | {:error, :not_found}
  defdelegate get_goal(agent_id, goal_id), to: GoalStore

  @doc """
  Update goal progress (0.0 to 1.0).
  """
  @spec update_goal_progress(String.t(), String.t(), float()) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate update_goal_progress(agent_id, goal_id, progress), to: GoalStore

  @doc """
  Mark a goal as achieved.
  """
  @spec achieve_goal(String.t(), String.t()) :: {:ok, struct()} | {:error, :not_found}
  defdelegate achieve_goal(agent_id, goal_id), to: GoalStore

  @doc """
  Mark a goal as abandoned with an optional reason.
  """
  @spec abandon_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate abandon_goal(agent_id, goal_id, reason \\ nil), to: GoalStore

  @doc """
  Mark a goal as failed with an optional reason.
  """
  @spec fail_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate fail_goal(agent_id, goal_id, reason \\ nil), to: GoalStore

  @doc """
  Update metadata for a goal, merging with existing metadata.

  ## Examples

      {:ok, goal} = Arbor.Memory.update_goal_metadata("agent_001", goal_id, %{decomposition_failed: true})
  """
  @spec update_goal_metadata(String.t(), String.t(), map()) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate update_goal_metadata(agent_id, goal_id, metadata), to: GoalStore

  @doc """
  Add a note to a goal's notes list.
  """
  @spec add_goal_note(String.t(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, :not_found}
  def add_goal_note(agent_id, goal_id, note) do
    GoalStore.add_note(agent_id, goal_id, note)
  end

  @doc """
  Export all goals for an agent as serializable maps.

  Used by Seed capture to snapshot goal state.
  """
  @spec export_all_goals(String.t()) :: [map()]
  defdelegate export_all_goals(agent_id), to: GoalStore

  @doc """
  Import goals from serializable maps.

  Used by Seed restore to restore goal state.
  """
  @spec import_goals(String.t(), [map()]) :: :ok
  defdelegate import_goals(agent_id, goal_maps), to: GoalStore

  @doc """
  Get the goal tree starting from a given goal (with children hierarchy).
  """
  @spec get_goal_tree(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_goal_tree(agent_id, goal_id), to: GoalStore

  # ============================================================================
  # Intents & Percepts (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Record an intent for an agent.

  Intents represent what the Mind has decided to do.
  """
  @spec record_intent(String.t(), struct()) :: {:ok, struct()}
  defdelegate record_intent(agent_id, intent), to: IntentStore

  @doc """
  Get recent intents for an agent.

  ## Options

  - `:limit` -- max intents (default: 10)
  - `:type` -- filter by intent type
  - `:since` -- only intents after this DateTime
  """
  @spec recent_intents(String.t(), keyword()) :: [struct()]
  defdelegate recent_intents(agent_id, opts \\ []), to: IntentStore

  @doc """
  Record a percept for an agent.

  Percepts represent the Body's observation after executing an intent.
  """
  @spec record_percept(String.t(), struct()) :: {:ok, struct()}
  defdelegate record_percept(agent_id, percept), to: IntentStore

  @doc """
  Get recent percepts for an agent.

  ## Options

  - `:limit` -- max percepts (default: 10)
  - `:type` -- filter by percept type
  - `:since` -- only percepts after this DateTime
  """
  @spec recent_percepts(String.t(), keyword()) :: [struct()]
  defdelegate recent_percepts(agent_id, opts \\ []), to: IntentStore

  @doc """
  Get the percept (outcome) for a specific intent.
  """
  @spec get_percept_for_intent(String.t(), String.t()) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate get_percept_for_intent(agent_id, intent_id), to: IntentStore

  @doc """
  Get pending intents linked to a specific goal.

  Returns intents that have the given `goal_id` and are not completed or failed.
  Used by the BDI loop to determine if a goal needs decomposition.
  """
  @spec pending_intents_for_goal(String.t(), String.t()) :: [struct()]
  defdelegate pending_intents_for_goal(agent_id, goal_id), to: IntentStore

  @doc """
  Get a specific intent by ID, with its status info.
  """
  @spec get_intent(String.t(), String.t()) :: {:ok, struct(), map()} | {:error, :not_found}
  defdelegate get_intent(agent_id, intent_id), to: IntentStore

  @doc """
  Get pending intents sorted by urgency (highest first).
  """
  @spec pending_intentions(String.t(), keyword()) :: [{struct(), map()}]
  defdelegate pending_intentions(agent_id, opts \\ []), to: IntentStore

  @doc """
  Lock an intent for execution (peek-lock-ack pattern).
  """
  @spec lock_intent(String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  defdelegate lock_intent(agent_id, intent_id), to: IntentStore

  @doc """
  Mark an intent as completed (terminal state).
  """
  @spec complete_intent(String.t(), String.t()) :: :ok | {:error, :not_found}
  defdelegate complete_intent(agent_id, intent_id), to: IntentStore

  @doc """
  Mark an intent as failed. Increments retry_count, returns to pending.
  """
  @spec fail_intent(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  defdelegate fail_intent(agent_id, intent_id, reason \\ "unknown"), to: IntentStore

  @doc """
  Unlock intents locked longer than timeout_ms (stale lock recovery).
  """
  @spec unlock_stale_intents(String.t(), pos_integer()) :: non_neg_integer()
  defdelegate unlock_stale_intents(agent_id, timeout_ms \\ 60_000), to: IntentStore

  @doc """
  Export non-completed intents with status info for Seed capture.

  Returns serializable maps suitable for `import_intents/2`.
  """
  @spec export_pending_intents(String.t()) :: [map()]
  defdelegate export_pending_intents(agent_id), to: IntentStore

  @doc """
  Import intents from a previous export, restoring pending work.

  Skips intents that already exist (by ID).
  """
  @spec import_intents(String.t(), [map()]) :: :ok
  defdelegate import_intents(agent_id, intent_maps), to: IntentStore

  # ============================================================================
  # Bridge (Seed/Host Phase 4)
  # ============================================================================

  @doc """
  Emit an intent from Mind to Body via the signal bus.
  """
  @spec emit_intent(String.t(), struct()) :: :ok
  defdelegate emit_intent(agent_id, intent), to: Bridge

  @doc """
  Emit a percept from Body to Mind via the signal bus.
  """
  @spec emit_percept(String.t(), struct()) :: :ok
  defdelegate emit_percept(agent_id, percept), to: Bridge

  @doc """
  Execute an intent and wait for the percept response.

  ## Options

  - `:timeout` -- maximum wait time in ms (default: 30_000)
  """
  @spec execute_and_wait(String.t(), struct(), keyword()) ::
          {:ok, struct()} | {:error, :timeout}
  defdelegate execute_and_wait(agent_id, intent, opts \\ []), to: Bridge

  # ============================================================================
  # Bridge Subscriptions (Seed/Host Phase 4)
  # ============================================================================

  @doc """
  Subscribe to intents emitted for a specific agent.

  The handler function receives the full signal when an intent is emitted
  for the given agent_id.

  Returns `{:ok, subscription_id}` or `{:error, reason}`.
  """
  @spec subscribe_to_intents(String.t(), (map() -> :ok)) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate subscribe_to_intents(agent_id, handler), to: Bridge

  @doc """
  Subscribe to percepts emitted for a specific agent.

  The handler function receives the full signal when a percept is emitted
  for the given agent_id.

  Returns `{:ok, subscription_id}` or `{:error, reason}`.
  """
  @spec subscribe_to_percepts(String.t(), (map() -> :ok)) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate subscribe_to_percepts(agent_id, handler), to: Bridge
end
