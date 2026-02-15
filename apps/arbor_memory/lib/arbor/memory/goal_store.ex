defmodule Arbor.Memory.GoalStore do
  @moduledoc """
  GenServer-based storage for agent goals.

  Provides CRUD operations and hierarchy queries for `Arbor.Contracts.Memory.Goal`
  structs. Goals are stored in ETS for fast access and organized per-agent.

  ## Storage

  Goals are kept in a named ETS table (`:arbor_memory_goals`) keyed by
  `{agent_id, goal_id}`. This allows efficient per-agent queries while
  maintaining O(1) lookups by ID.

  ## Signals

  All mutations emit signals via `Arbor.Memory.Signals`:
  - `{:memory, :goal_created}` — new goal added
  - `{:memory, :goal_progress}` — progress updated
  - `{:memory, :goal_achieved}` — goal marked achieved
  - `{:memory, :goal_abandoned}` — goal marked abandoned
  """

  use GenServer

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.Signals

  require Logger

  @ets_table :arbor_memory_goals

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the GoalStore GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Add a goal for an agent.

  Accepts a `Goal` struct or a keyword list of options passed to `Goal.new/2`.

  ## Examples

      goal = Goal.new("Fix the login bug", type: :achieve, priority: 80)
      {:ok, goal} = GoalStore.add_goal("agent_001", goal)

      {:ok, goal} = GoalStore.add_goal("agent_001", "Fix the login bug", type: :achieve)
  """
  @spec add_goal(String.t(), Goal.t()) :: {:ok, Goal.t()}
  def add_goal(agent_id, %Goal{} = goal) do
    :ets.insert(@ets_table, {{agent_id, goal.id}, goal})
    persist_goal_async(agent_id, goal)

    Signals.emit_goal_created(agent_id, goal)
    Logger.debug("Goal added for #{agent_id}: #{goal.id} - #{goal.description}")

    {:ok, goal}
  end

  @spec add_goal(String.t(), String.t(), keyword()) :: {:ok, Goal.t()}
  def add_goal(agent_id, description, opts \\ []) when is_binary(description) do
    goal = Goal.new(description, opts)
    add_goal(agent_id, goal)
  end

  @doc """
  Get a goal by ID.
  """
  @spec get_goal(String.t(), String.t()) :: {:ok, Goal.t()} | {:error, :not_found}
  def get_goal(agent_id, goal_id) do
    case :ets.lookup(@ets_table, {agent_id, goal_id}) do
      [{{^agent_id, ^goal_id}, goal}] -> {:ok, goal}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Update goal progress (0.0 to 1.0).

  Emits a `{:memory, :goal_progress}` signal.
  """
  @spec update_goal_progress(String.t(), String.t(), float()) ::
          {:ok, Goal.t()} | {:error, :not_found}
  def update_goal_progress(agent_id, goal_id, progress)
      when is_float(progress) and progress >= 0.0 and progress <= 1.0 do
    case get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        updated = Goal.update_progress(goal, progress)
        :ets.insert(@ets_table, {{agent_id, goal_id}, updated})
        persist_goal_async(agent_id, updated)

        Signals.emit_goal_progress(agent_id, goal_id, progress)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Mark a goal as achieved.

  Sets progress to 1.0, status to `:achieved`, and records the timestamp.
  Emits a `{:memory, :goal_achieved}` signal.
  """
  @spec achieve_goal(String.t(), String.t()) :: {:ok, Goal.t()} | {:error, :not_found}
  def achieve_goal(agent_id, goal_id) do
    case get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        updated = Goal.achieve(goal)
        :ets.insert(@ets_table, {{agent_id, goal_id}, updated})
        persist_goal_async(agent_id, updated)

        Signals.emit_goal_achieved(agent_id, goal_id)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Mark a goal as abandoned with an optional reason.

  Emits a `{:memory, :goal_abandoned}` signal.
  """
  @spec abandon_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, Goal.t()} | {:error, :not_found}
  def abandon_goal(agent_id, goal_id, reason \\ nil) do
    case get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        updated = Goal.abandon(goal, reason)
        :ets.insert(@ets_table, {{agent_id, goal_id}, updated})
        persist_goal_async(agent_id, updated)

        Signals.emit_goal_abandoned(agent_id, goal_id, reason)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Mark a goal as failed with an optional reason.

  Sets status to `:failed` and prepends a "Failed: reason" note.
  Emits a `{:memory, :goal_failed}` signal.
  """
  @spec fail_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, Goal.t()} | {:error, :not_found}
  def fail_goal(agent_id, goal_id, reason \\ nil) do
    case get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        updated = Goal.fail(goal, reason)
        :ets.insert(@ets_table, {{agent_id, goal_id}, updated})
        persist_goal_async(agent_id, updated)

        Signals.emit_goal_abandoned(agent_id, goal_id, reason || "failed")
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Add a note to a goal's notes list.

  Prepends the note to the goal's notes field.
  """
  @spec add_note(String.t(), String.t(), String.t()) ::
          {:ok, Goal.t()} | {:error, :not_found}
  def add_note(agent_id, goal_id, note) when is_binary(note) do
    case get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        updated = Goal.add_note(goal, note)
        :ets.insert(@ets_table, {{agent_id, goal_id}, updated})
        persist_goal_async(agent_id, updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Mark a goal as blocked with optional blocker descriptions.

  Sets status to `:blocked` and stores blockers in `metadata.blockers`.

  ## Examples

      {:ok, goal} = GoalStore.block_goal("agent_001", goal_id, ["waiting on API key"])
  """
  @spec block_goal(String.t(), String.t(), [String.t()] | nil) ::
          {:ok, Goal.t()} | {:error, :not_found}
  def block_goal(agent_id, goal_id, blockers \\ nil) do
    case get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        updated_metadata = Map.put(goal.metadata || %{}, :blockers, blockers || [])
        updated = %{goal | status: :blocked, metadata: updated_metadata}
        :ets.insert(@ets_table, {{agent_id, goal_id}, updated})
        persist_goal_async(agent_id, updated)

        Signals.emit_goal_abandoned(agent_id, goal_id, "blocked")
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Update metadata for a goal, merging with existing metadata.

  ## Examples

      {:ok, goal} = GoalStore.update_goal_metadata("agent_001", goal_id, %{decomposition_failed: true})
  """
  @spec update_goal_metadata(String.t(), String.t(), map()) ::
          {:ok, Goal.t()} | {:error, :not_found}
  def update_goal_metadata(agent_id, goal_id, new_metadata) when is_map(new_metadata) do
    case get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        merged = Map.merge(goal.metadata || %{}, new_metadata)
        updated = %{goal | metadata: merged}
        :ets.insert(@ets_table, {{agent_id, goal_id}, updated})
        persist_goal_async(agent_id, updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Get all active goals for an agent, sorted by priority (highest first).
  """
  @spec get_active_goals(String.t()) :: [Goal.t()]
  def get_active_goals(agent_id) do
    match_spec = [{{{agent_id, :_}, :"$1"}, [], [:"$1"]}]

    @ets_table
    |> :ets.select(match_spec)
    |> Enum.filter(&(&1.status == :active))
    |> Enum.sort_by(& &1.priority, :desc)
  end

  @doc """
  Get all goals for an agent (any status).
  """
  @spec get_all_goals(String.t()) :: [Goal.t()]
  def get_all_goals(agent_id) do
    match_spec = [{{{agent_id, :_}, :"$1"}, [], [:"$1"]}]
    :ets.select(@ets_table, match_spec)
  end

  @doc """
  Get the goal tree starting from a given goal.

  Returns the goal and all its descendants (children, grandchildren, etc.).
  """
  @spec get_goal_tree(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_goal_tree(agent_id, goal_id) do
    case get_goal(agent_id, goal_id) do
      {:ok, root} ->
        all_goals = get_all_goals(agent_id)
        tree = build_tree(root, all_goals)
        {:ok, tree}

      error ->
        error
    end
  end

  @doc """
  Delete a goal.
  """
  @spec delete_goal(String.t(), String.t()) :: :ok
  def delete_goal(agent_id, goal_id) do
    :ets.delete(@ets_table, {agent_id, goal_id})
    MemoryStore.delete("goals", "#{agent_id}:#{goal_id}")
    :ok
  end

  @doc """
  Delete all goals for an agent.
  """
  @spec clear_goals(String.t()) :: :ok
  def clear_goals(agent_id) do
    match_spec = [{{{agent_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@ets_table, match_spec)
    MemoryStore.delete_by_prefix("goals", agent_id)
    :ok
  end

  # ============================================================================
  # Export / Import (for Seed capture & restore)
  # ============================================================================

  @doc """
  Export all goals for an agent as serializable maps.

  Used by `Arbor.Agent.Seed.capture/2` to snapshot goal state.
  """
  @spec export_all_goals(String.t()) :: [map()]
  def export_all_goals(agent_id) do
    get_all_goals(agent_id)
    |> Enum.map(fn goal ->
      goal
      |> Map.from_struct()
      |> Map.update(:created_at, nil, &maybe_to_iso8601/1)
      |> Map.update(:achieved_at, nil, &maybe_to_iso8601/1)
      |> Map.update(:deadline, nil, &maybe_to_iso8601/1)
    end)
  end

  @doc """
  Import goals from serializable maps.

  Used by `Arbor.Agent.Seed.restore/2` to restore goal state.
  """
  @spec import_goals(String.t(), [map()]) :: :ok
  def import_goals(agent_id, goal_maps) do
    Enum.each(goal_maps, fn goal_map ->
      goal = goal_from_map(goal_map)
      :ets.insert(@ets_table, {{agent_id, goal.id}, goal})
    end)

    :ok
  end

  defp maybe_to_iso8601(nil), do: nil
  defp maybe_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_to_iso8601(other), do: other

  defp goal_from_map(map) do
    map = atomize_keys(map)

    %Goal{
      id: map[:id],
      description: map[:description],
      type: safe_atom(map[:type], :achieve),
      status: safe_atom(map[:status], :active),
      priority: map[:priority] || 50,
      parent_id: map[:parent_id],
      progress: map[:progress] || 0.0,
      created_at: parse_datetime(map[:created_at]),
      achieved_at: parse_datetime(map[:achieved_at]),
      deadline: parse_datetime(map[:deadline]),
      success_criteria: map[:success_criteria],
      notes: map[:notes] || [],
      assigned_by: safe_atom(map[:assigned_by], nil),
      metadata: map[:metadata] || %{}
    }
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  defp safe_atom(val, _default) when is_atom(val), do: val
  defp safe_atom(val, default) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> default
  end
  defp safe_atom(_, default), do: default

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_table()
    load_goals_from_postgres()
    {:ok, %{}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp persist_goal_async(agent_id, %Goal{} = goal) do
    key = "#{agent_id}:#{goal.id}"

    goal_map =
      goal
      |> Map.from_struct()
      |> Map.update(:created_at, nil, &maybe_to_iso8601/1)
      |> Map.update(:achieved_at, nil, &maybe_to_iso8601/1)
      |> Map.update(:deadline, nil, &maybe_to_iso8601/1)

    MemoryStore.persist_async("goals", key, goal_map)
    MemoryStore.embed_async("goals", key, goal.description, agent_id: agent_id, type: :goal)
  end

  defp load_goals_from_postgres do
    if MemoryStore.available?() do
      case MemoryStore.load_all("goals") do
        {:ok, pairs} ->
          Enum.each(pairs, fn {key, goal_map} ->
            case String.split(key, ":", parts: 2) do
              [agent_id, _goal_id] ->
                goal = goal_from_map(goal_map)
                :ets.insert(@ets_table, {{agent_id, goal.id}, goal})

              _ ->
                Logger.warning("GoalStore: invalid key format from Postgres: #{key}")
            end
          end)

          Logger.info("GoalStore: loaded #{length(pairs)} goals from Postgres")

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("GoalStore: failed to load from Postgres: #{inspect(e)}")
  end

  defp build_tree(goal, all_goals) do
    children =
      all_goals
      |> Enum.filter(&(&1.parent_id == goal.id))
      |> Enum.map(&build_tree(&1, all_goals))

    %{goal: goal, children: children}
  end
end
