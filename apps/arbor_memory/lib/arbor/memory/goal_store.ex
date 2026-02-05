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

        Signals.emit_goal_abandoned(agent_id, goal_id, reason)
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
    :ok
  end

  @doc """
  Delete all goals for an agent.
  """
  @spec clear_goals(String.t()) :: :ok
  def clear_goals(agent_id) do
    match_spec = [{{{agent_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@ets_table, match_spec)
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_table()
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

  defp build_tree(goal, all_goals) do
    children =
      all_goals
      |> Enum.filter(&(&1.parent_id == goal.id))
      |> Enum.map(&build_tree(&1, all_goals))

    %{goal: goal, children: children}
  end
end
