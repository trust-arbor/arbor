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

  alias Arbor.Common.SafeAtom
  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.Memory.{MemoryStore, Provenance, Signals}

  require Logger

  @ets_table :arbor_memory_goals
  @namespace "goals"
  @goal_fields [
    :id,
    :description,
    :type,
    :status,
    :priority,
    :parent_id,
    :progress,
    :created_at,
    :achieved_at,
    :deadline,
    :success_criteria,
    :notes,
    :assigned_by,
    :metadata,
    :referenced_date
  ]
  @goal_types [:achieve, :maintain, :explore, :learn, :avoid]
  @goal_statuses [:active, :achieved, :failed, :abandoned, :blocked]
  @max_identifier_bytes 256
  @max_goal_text_bytes 1_048_576
  @max_goal_note_bytes 65_536
  @max_goal_notes 128
  @max_projected_goals_per_agent 512
  @critical_write_attempts 12

  @type provenance_status ::
          :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type tainted_goal :: {TaintedValue.t(), provenance_status()}

  # Per-agent hard cap on goal count. Configurable via Application config:
  #
  #     config :arbor_memory, :goal_limit_per_agent, 50
  #
  # Defense in depth against runaway goal creation. The diagnostician can
  # accumulate hundreds of goals when dedup logic upstream has bugs and the
  # LLM keeps proposing new variants. With a cap, the worst-case is "agent
  # has 50 goals and refuses to add more" instead of "78KB prompt, LLM
  # timeouts, signal storm." See `.arbor/roadmap/0-inbox/` for the deeper
  # discussion.
  @default_goal_limit 50

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

  @doc "Per-agent goal limit. Reads from Application config, defaults to 50."
  @spec goal_limit() :: pos_integer()
  def goal_limit do
    Application.get_env(:arbor_memory, :goal_limit_per_agent, @default_goal_limit)
  end

  @doc """
  Add a goal for an agent.

  Accepts a `Goal` struct or a keyword list of options passed to `Goal.new/2`.

  Returns `{:error, :goal_limit_reached}` if the agent is already at the
  per-agent goal cap (see `goal_limit/0`).

  ## Examples

      goal = Goal.new("Fix the login bug", type: :achieve, priority: 80)
      {:ok, goal} = GoalStore.add_goal("agent_001", goal)

      {:ok, goal} = GoalStore.add_goal("agent_001", "Fix the login bug", type: :achieve)
  """
  @spec add_goal(String.t(), Goal.t()) ::
          {:ok, Goal.t()} | {:error, :goal_limit_reached | :invalid_provenance}
  def add_goal(agent_id, %Goal{} = goal) do
    add_goal_tainted(agent_id, goal, TaintEnvelope.missing_fallback())
  end

  @spec add_goal(String.t(), String.t(), keyword()) ::
          {:ok, Goal.t()}
          | {:error, :empty_description | :goal_limit_reached | :invalid_provenance}
  def add_goal(agent_id, description, opts \\ []) when is_binary(description) do
    if String.trim(description) == "" do
      {:error, :empty_description}
    else
      goal = Goal.new(description, opts)
      add_goal(agent_id, goal)
    end
  end

  @doc """
  Add a goal with an explicit provenance label.

  The label is validated against the exact serialized goal payload and the
  embedded description before any live or durable state is changed.
  """
  @spec add_goal_tainted(String.t(), Goal.t(), Taint.t()) ::
          {:ok, Goal.t()}
          | {:error,
             :goal_limit_reached | :invalid_provenance | :persistence_failed | :store_unavailable}
  def add_goal_tainted(agent_id, %Goal{} = goal, taint) do
    with true <- valid_identifier?(agent_id),
         true <- valid_identifier?(goal.id),
         {:ok, payload, taint} <- prepare_labeled_goal(goal, taint) do
      call_owner({:add_goal, agent_id, goal, payload, taint})
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  def add_goal_tainted(_agent_id, _goal, _taint), do: {:error, :invalid_provenance}

  @spec add_goal_tainted(String.t(), String.t(), keyword(), Taint.t()) ::
          {:ok, Goal.t()}
          | {:error, :empty_description | :goal_limit_reached | :invalid_provenance}
  def add_goal_tainted(agent_id, description, opts, taint)
      when is_binary(description) and is_list(opts) do
    if String.trim(description) == "" do
      {:error, :empty_description}
    else
      add_goal_tainted(agent_id, Goal.new(description, opts), taint)
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  def add_goal_tainted(_agent_id, _description, _opts, _taint),
    do: {:error, :invalid_provenance}

  @doc """
  Get a goal by ID.
  """
  @spec get_goal(String.t(), String.t()) :: {:ok, Goal.t()} | {:error, :not_found}
  def get_goal(agent_id, goal_id) do
    if valid_identifier?(agent_id) and valid_identifier?(goal_id) do
      case :ets.lookup(@ets_table, {agent_id, goal_id}) do
        [{{^agent_id, ^goal_id}, %Goal{} = goal}] -> {:ok, goal}
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  rescue
    # Missing ETS table (arbor_memory not booted) — treat as no goals
    # present. Mirrors the resilience pattern in `at_goal_limit?` above
    # so isolated test envs (where arbor_memory is a sibling that doesn't
    # start) and transient ETS issues don't crash the read path.
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  Get a goal with its live provenance and explicit provenance status.

  The sidecar is verified against the exact serialized goal payload. Missing
  provenance remains legacy-unlabeled; malformed or mismatched provenance is
  returned with the hostile invalid-durable-provenance label.
  """
  @spec get_goal_tainted(String.t(), String.t()) ::
          {:ok, TaintedValue.t(), provenance_status()}
          | {:error, :not_found | :invalid_provenance}
  def get_goal_tainted(agent_id, goal_id)
      when is_binary(agent_id) and is_binary(goal_id) do
    if valid_identifier?(agent_id) and valid_identifier?(goal_id),
      do: call_owner({:get_goal_tainted, agent_id, goal_id}),
      else: {:error, :invalid_provenance}
  end

  def get_goal_tainted(_agent_id, _goal_id), do: {:error, :invalid_provenance}

  @doc """
  Update goal progress (0.0 to 1.0).

  Emits a `{:memory, :goal_progress}` signal.
  """
  @spec update_goal_progress(String.t(), String.t(), float()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def update_goal_progress(agent_id, goal_id, progress)
      when is_float(progress) and progress >= 0.0 and progress <= 1.0 do
    update_goal_progress_tainted(
      agent_id,
      goal_id,
      progress,
      TaintEnvelope.missing_fallback()
    )
  end

  @doc "Update goal progress while monotonically joining an explicit label."
  @spec update_goal_progress_tainted(String.t(), String.t(), float(), Taint.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def update_goal_progress_tainted(agent_id, goal_id, progress, taint)
      when is_float(progress) and progress >= 0.0 and progress <= 1.0 do
    mutate_goal(agent_id, goal_id, taint, {:progress, progress})
  end

  def update_goal_progress_tainted(_agent_id, _goal_id, _progress, _taint),
    do: {:error, :invalid_provenance}

  @doc """
  Mark a goal as achieved.

  Sets progress to 1.0, status to `:achieved`, and records the timestamp.
  Emits a `{:memory, :goal_achieved}` signal.
  """
  @spec achieve_goal(String.t(), String.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def achieve_goal(agent_id, goal_id) do
    achieve_goal_tainted(agent_id, goal_id, TaintEnvelope.missing_fallback())
  end

  @doc "Mark a goal achieved while monotonically joining an explicit label."
  @spec achieve_goal_tainted(String.t(), String.t(), Taint.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def achieve_goal_tainted(agent_id, goal_id, taint) do
    mutate_goal(agent_id, goal_id, taint, :achieve)
  end

  @doc """
  Mark a goal as abandoned with an optional reason.

  Emits a `{:memory, :goal_abandoned}` signal.
  """
  @spec abandon_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def abandon_goal(agent_id, goal_id, reason \\ nil) do
    abandon_goal_tainted(agent_id, goal_id, reason, TaintEnvelope.missing_fallback())
  end

  @doc "Abandon a goal while monotonically joining an explicit label."
  @spec abandon_goal_tainted(String.t(), String.t(), String.t() | nil, Taint.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def abandon_goal_tainted(agent_id, goal_id, reason, taint) do
    mutate_goal(agent_id, goal_id, taint, {:abandon, reason})
  end

  @doc """
  Mark a goal as failed with an optional reason.

  Sets status to `:failed` and prepends a "Failed: reason" note.
  Emits a `{:memory, :goal_failed}` signal.
  """
  @spec fail_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def fail_goal(agent_id, goal_id, reason \\ nil) do
    fail_goal_tainted(agent_id, goal_id, reason, TaintEnvelope.missing_fallback())
  end

  @doc "Fail a goal while monotonically joining an explicit label."
  @spec fail_goal_tainted(String.t(), String.t(), String.t() | nil, Taint.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def fail_goal_tainted(agent_id, goal_id, reason, taint) do
    mutate_goal(agent_id, goal_id, taint, {:fail, reason})
  end

  @doc """
  Add a note to a goal's notes list.

  Prepends the note to the goal's notes field.
  """
  @spec add_note(String.t(), String.t(), String.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def add_note(agent_id, goal_id, note) when is_binary(note) do
    add_note_tainted(agent_id, goal_id, note, TaintEnvelope.missing_fallback())
  end

  @doc "Add a note while monotonically joining an explicit label."
  @spec add_note_tainted(String.t(), String.t(), String.t(), Taint.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def add_note_tainted(agent_id, goal_id, note, taint) when is_binary(note) do
    mutate_goal(agent_id, goal_id, taint, {:note, note})
  end

  @doc """
  Mark a goal as blocked with optional blocker descriptions.

  Sets status to `:blocked` and stores blockers in `metadata.blockers`.

  ## Examples

      {:ok, goal} = GoalStore.block_goal("agent_001", goal_id, ["waiting on API key"])
  """
  @spec block_goal(String.t(), String.t(), [String.t()] | nil) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def block_goal(agent_id, goal_id, blockers \\ nil) do
    block_goal_tainted(agent_id, goal_id, blockers, TaintEnvelope.missing_fallback())
  end

  @doc "Block a goal while monotonically joining an explicit label."
  @spec block_goal_tainted(String.t(), String.t(), [String.t()] | nil, Taint.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def block_goal_tainted(agent_id, goal_id, blockers, taint) do
    mutate_goal(agent_id, goal_id, taint, {:block, blockers})
  end

  @doc """
  Update metadata for a goal, merging with existing metadata.

  ## Examples

      {:ok, goal} = GoalStore.update_goal_metadata("agent_001", goal_id, %{decomposition_failed: true})
  """
  @spec update_goal_metadata(String.t(), String.t(), map()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def update_goal_metadata(agent_id, goal_id, new_metadata) when is_map(new_metadata) do
    update_goal_metadata_tainted(
      agent_id,
      goal_id,
      new_metadata,
      TaintEnvelope.missing_fallback()
    )
  end

  @doc "Update metadata while monotonically joining an explicit label."
  @spec update_goal_metadata_tainted(String.t(), String.t(), map(), Taint.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :invalid_provenance}
  def update_goal_metadata_tainted(agent_id, goal_id, new_metadata, taint)
      when is_map(new_metadata) do
    mutate_goal(agent_id, goal_id, taint, {:metadata, new_metadata})
  end

  @doc """
  Get all active goals for an agent, sorted by priority (highest first).
  """
  @spec get_active_goals(String.t()) :: [Goal.t()]
  def get_active_goals(agent_id) do
    if valid_identifier?(agent_id) do
      match_spec = [{{{agent_id, :_}, :"$1"}, [], [:"$1"]}]

      @ets_table
      |> :ets.select(match_spec)
      |> Enum.filter(&match?(%Goal{status: :active}, &1))
      |> Enum.sort_by(& &1.priority, :desc)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Get active goals with per-goal taint and explicit provenance status."
  @spec get_active_goals_tainted(String.t()) ::
          {:ok, [tainted_goal()]} | {:error, :invalid_provenance}
  def get_active_goals_tainted(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:get_goal_list_tainted, agent_id, :active}),
      else: {:error, :invalid_provenance}
  end

  @doc """
  Get all goals for an agent (any status).
  """
  @spec get_all_goals(String.t()) :: [Goal.t()]
  def get_all_goals(agent_id) do
    if valid_identifier?(agent_id) do
      match_spec = [{{{agent_id, :_}, :"$1"}, [], [:"$1"]}]
      @ets_table |> :ets.select(match_spec) |> Enum.filter(&match?(%Goal{}, &1))
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Get all goals with per-goal taint and explicit provenance status."
  @spec get_all_goals_tainted(String.t()) ::
          {:ok, [tainted_goal()]} | {:error, :invalid_provenance}
  def get_all_goals_tainted(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:get_goal_list_tainted, agent_id, :all}),
      else: {:error, :invalid_provenance}
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
  @spec delete_goal(String.t(), String.t()) ::
          :ok | {:error, :invalid_provenance | :persistence_failed | :store_unavailable}
  def delete_goal(agent_id, goal_id) do
    if valid_identifier?(agent_id) and valid_identifier?(goal_id),
      do: call_owner({:delete_goal, agent_id, goal_id}),
      else: {:error, :invalid_provenance}
  end

  @doc """
  Delete all goals for an agent.
  """
  @spec clear_goals(String.t()) ::
          :ok | {:error, :invalid_provenance | :persistence_failed | :store_unavailable}
  def clear_goals(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:clear_goals, agent_id}),
      else: {:error, :invalid_provenance}
  end

  defp safe_ets_delete(key) do
    :ets.delete(@ets_table, key)
  rescue
    ArgumentError -> :ok
  end

  # ============================================================================
  # Temporal / Deadline-Aware Retrieval
  # ============================================================================

  @doc """
  Get active goals sorted by urgency (highest first).

  Uses `Goal.urgency/1` which factors in both priority and deadline proximity.
  Overdue goals sort highest, then deadline proximity, then raw priority.
  """
  @spec goals_by_urgency(String.t()) :: [Goal.t()]
  def goals_by_urgency(agent_id) do
    get_active_goals(agent_id)
    |> Enum.sort_by(&Goal.urgency/1, :desc)
  end

  @doc """
  Get active goals that are past their deadline.
  """
  @spec overdue_goals(String.t()) :: [Goal.t()]
  def overdue_goals(agent_id) do
    get_active_goals(agent_id)
    |> Enum.filter(&Goal.overdue?/1)
    |> Enum.sort_by(&Goal.urgency/1, :desc)
  end

  @doc """
  Get active goals with a deadline within the given window from now.

  ## Options (one required)

  - `:hours` — deadline within N hours
  - `:days` — deadline within N days
  """
  @spec goals_due_within(String.t(), keyword()) :: [Goal.t()]
  def goals_due_within(agent_id, opts) do
    cutoff = compute_deadline_cutoff(opts)

    get_active_goals(agent_id)
    |> Enum.filter(fn goal ->
      case goal.deadline do
        nil -> false
        deadline -> DateTime.compare(deadline, cutoff) in [:eq, :lt]
      end
    end)
    |> Enum.sort_by(&Goal.urgency/1, :desc)
  end

  defp compute_deadline_cutoff(opts) do
    cond do
      hours = Keyword.get(opts, :hours) ->
        DateTime.add(DateTime.utc_now(), hours * 3600, :second)

      days = Keyword.get(opts, :days) ->
        DateTime.add(DateTime.utc_now(), days * 86_400, :second)

      true ->
        DateTime.utc_now()
    end
  end

  @doc """
  Reload goals for a specific agent from Postgres into ETS.

  Ensures persisted goals are available after agent restart, even if
  GoalStore's init didn't find them (e.g., MemoryStore wasn't available).
  """
  @spec reload_for_agent(String.t()) ::
          :ok | {:error, :invalid_provenance | :store_unavailable}
  def reload_for_agent(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:reload_for_agent, agent_id}),
      else: {:error, :invalid_provenance}
  rescue
    _ ->
      Logger.warning("[GoalStore] reload_for_agent failed for #{agent_id}")
      {:error, :store_unavailable}
  end

  @doc false
  @spec reload_goal_from_durable(String.t(), String.t()) ::
          :ok | {:error, :invalid_provenance | :store_unavailable}
  def reload_goal_from_durable(agent_id, goal_id)
      when is_binary(agent_id) and is_binary(goal_id) do
    if valid_identifier?(agent_id) and valid_identifier?(goal_id),
      do: call_owner({:reload_goal, agent_id, goal_id}),
      else: {:error, :invalid_provenance}
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  def reload_goal_from_durable(_agent_id, _goal_id), do: {:error, :invalid_provenance}

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
    |> Enum.flat_map(fn goal ->
      case serialize_goal(goal) do
        {:ok, payload} -> [payload]
        {:error, _reason} -> []
      end
    end)
  end

  @doc """
  Import goals from serializable maps.

  Used by `Arbor.Agent.Seed.restore/2` to restore goal state.
  """
  @spec import_goals(String.t(), [map()]) ::
          :ok | {:error, :invalid_provenance | :persistence_failed | :store_unavailable}
  def import_goals(agent_id, goal_maps) when is_list(goal_maps) do
    cond do
      not valid_identifier?(agent_id) ->
        {:error, :invalid_provenance}

      Enum.any?(goal_maps, &ambiguous_import_goal_identifier?/1) ->
        {:error, :invalid_provenance}

      true ->
        case prepare_import_goals(goal_maps) do
          [] -> :ok
          entries -> call_owner({:import_goals, agent_id, entries})
        end
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  def import_goals(_agent_id, _goal_maps), do: :ok

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_table()
    projected_ids = load_goals_from_authoritative_store()
    {:ok, %{projected_ids: projected_ids}}
  end

  @impl true
  def handle_call({:add_goal, agent_id, goal, _payload, taint}, _from, state) do
    with :ok <- ensure_projection_slot(state, agent_id, goal.id) do
      result = do_add_goal(agent_id, goal, taint, true)
      {reply, state} = track_goal_write_result(result, state, agent_id, goal.id)
      {:reply, reply, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get_goal_tainted, agent_id, goal_id}, _from, state) do
    with :ok <- ensure_projection_slot(state, agent_id, goal_id) do
      result = do_get_goal_tainted(agent_id, goal_id)
      {reply, state} = track_goal_read_result(result, state, agent_id, goal_id)
      {:reply, reply, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get_goal_list_tainted, agent_id, scope}, _from, state) do
    case do_get_goal_list_tainted(agent_id, scope) do
      {:reconciled, reply, goal_ids} ->
        {reply, state} = reconcile_projected_ids(reply, state, agent_id, goal_ids)
        {:reply, reply, state}

      {:error, _reason} = error ->
        {:reply, error, state}

      _ ->
        {:reply, {:error, :invalid_provenance}, state}
    end
  end

  def handle_call({:mutate_goal, agent_id, goal_id, taint, operation}, _from, state) do
    with :ok <- ensure_projection_slot(state, agent_id, goal_id) do
      result = do_mutate_goal(agent_id, goal_id, taint, operation)
      {reply, state} = track_goal_write_result(result, state, agent_id, goal_id)
      {:reply, reply, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:import_goals, agent_id, entries}, _from, state) do
    {reply, state} = do_import_goals(agent_id, entries, state)
    {:reply, reply, state}
  end

  def handle_call({:delete_goal, agent_id, goal_id}, _from, state) do
    case do_delete_goal(agent_id, goal_id) do
      :ok -> {:reply, :ok, untrack_projected_id(state, agent_id, goal_id)}
      {:error, _reason} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :persistence_failed}, state}
    end
  end

  def handle_call({:clear_goals, agent_id}, _from, state) do
    {reply, state} = do_clear_goals(agent_id, state)
    {:reply, reply, state}
  end

  def handle_call({:reload_for_agent, agent_id}, _from, state) do
    case do_reload_for_agent(agent_id) do
      {:reconciled, reply, goal_ids} ->
        {reply, state} = reconcile_projected_ids(reply, state, agent_id, goal_ids)
        {:reply, reply, state}

      {:error, _reason} = error ->
        {:reply, error, state}

      _ ->
        {:reply, {:error, :invalid_provenance}, state}
    end
  end

  def handle_call({:reload_goal, agent_id, goal_id}, _from, state) do
    with :ok <- ensure_projection_slot(state, agent_id, goal_id) do
      case do_reload_goal(agent_id, goal_id) do
        {:reloaded, :present} ->
          {:reply, :ok, track_projected_id(state, agent_id, goal_id)}

        {:reloaded, :absent} ->
          {:reply, :ok, untrack_projected_id(state, agent_id, goal_id)}

        {:error, reason} = error when reason in [:invalid_provenance, :projection_failed] ->
          {:reply, error, untrack_projected_id(state, agent_id, goal_id)}

        {:error, _reason} = error ->
          {:reply, error, state}

        _ ->
          {:reply, {:error, :invalid_provenance}, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
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

  defp call_owner(message) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, message, :infinity)
      nil -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :store_unavailable}
    _, _ -> {:error, :store_unavailable}
  end

  defp ensure_projection_slot(state, agent_id, goal_id) do
    with true <- valid_identifier?(agent_id),
         true <- valid_identifier?(goal_id) do
      projected_ids = projected_ids_for_agent(state, agent_id)

      if MapSet.member?(projected_ids, goal_id) or
           MapSet.size(projected_ids) < @max_projected_goals_per_agent do
        :ok
      else
        {:error, :projection_failed}
      end
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp track_goal_write_result(result, state, agent_id, goal_id) do
    case result do
      {:ok, %Goal{}} ->
        {result, track_projected_id(state, agent_id, goal_id)}

      {:error, reason} when reason in [:not_found, :invalid_provenance, :projection_failed] ->
        _ = remove_live_goal(agent_id, goal_id)
        {result, untrack_projected_id(state, agent_id, goal_id)}

      _ ->
        {result, state}
    end
  end

  defp track_goal_read_result(result, state, agent_id, goal_id) do
    case result do
      {:ok, %TaintedValue{}, _status} ->
        {result, track_projected_id(state, agent_id, goal_id)}

      {:error, reason} when reason in [:not_found, :invalid_provenance, :projection_failed] ->
        _ = remove_live_goal(agent_id, goal_id)
        {result, untrack_projected_id(state, agent_id, goal_id)}

      _ ->
        {result, state}
    end
  end

  defp reconcile_projected_ids(reply, state, agent_id, goal_ids) do
    with {:ok, next_ids} <- bounded_projected_id_set(goal_ids) do
      previous_ids = projected_ids_for_agent(state, agent_id)

      previous_ids
      |> MapSet.difference(next_ids)
      |> Enum.each(&remove_live_goal(agent_id, &1))

      {reply, put_projected_ids(state, agent_id, next_ids)}
    else
      _ ->
        projected_ids_for_agent(state, agent_id)
        |> Enum.each(&remove_live_goal(agent_id, &1))

        {{:error, :projection_failed}, clear_projected_ids(state, agent_id)}
    end
  end

  defp bounded_projected_id_set(goal_ids) when is_list(goal_ids) do
    collect_projected_ids(goal_ids, MapSet.new(), 0)
  end

  defp bounded_projected_id_set(_goal_ids), do: {:error, :projection_failed}

  defp collect_projected_ids([], ids, _count), do: {:ok, ids}

  defp collect_projected_ids([goal_id | rest], ids, count)
       when count < @max_projected_goals_per_agent do
    if valid_identifier?(goal_id) do
      collect_projected_ids(rest, MapSet.put(ids, goal_id), count + 1)
    else
      {:error, :projection_failed}
    end
  end

  defp collect_projected_ids(_goal_ids, _ids, _count), do: {:error, :projection_failed}

  defp projected_ids_for_agent(%{projected_ids: projected_ids}, agent_id)
       when is_map(projected_ids) do
    Map.get(projected_ids, agent_id, MapSet.new())
  end

  defp projected_ids_for_agent(_state, _agent_id), do: MapSet.new()

  defp track_projected_id(%{projected_ids: projected_ids} = state, agent_id, goal_id) do
    ids = projected_ids |> Map.get(agent_id, MapSet.new()) |> MapSet.put(goal_id)
    %{state | projected_ids: Map.put(projected_ids, agent_id, ids)}
  end

  defp untrack_projected_id(%{projected_ids: projected_ids} = state, agent_id, goal_id) do
    ids = projected_ids |> Map.get(agent_id, MapSet.new()) |> MapSet.delete(goal_id)
    put_projected_ids(state, agent_id, ids)
  end

  defp put_projected_ids(%{projected_ids: projected_ids} = state, agent_id, ids) do
    next =
      if MapSet.size(ids) == 0,
        do: Map.delete(projected_ids, agent_id),
        else: Map.put(projected_ids, agent_id, ids)

    %{state | projected_ids: next}
  end

  defp clear_projected_ids(%{projected_ids: projected_ids} = state, agent_id) do
    %{state | projected_ids: Map.delete(projected_ids, agent_id)}
  end

  defp do_add_goal(agent_id, %Goal{} = goal, supplied_taint, enforce_limit?) do
    with {:ok, taint, existing?} <- join_existing_goal_taint(agent_id, goal.id, supplied_taint),
         :ok <- check_goal_limit(agent_id, existing?, enforce_limit?),
         {:ok, payload, taint} <- prepare_labeled_goal(goal, taint),
         {:ok, committed} <-
           commit_labeled_goal(agent_id, goal, payload, taint, {:upsert, goal}) do
      emit_after_commit(fn -> Signals.emit_goal_created(agent_id, committed) end)
      Logger.debug("Goal added for #{agent_id}: #{committed.id}")
      {:ok, committed}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp check_goal_limit(_agent_id, true, _enforce_limit?), do: :ok
  defp check_goal_limit(_agent_id, _existing?, false), do: :ok

  defp check_goal_limit(agent_id, false, true) do
    with {:ok, records} <- load_authoritative_goal_records(agent_id),
         :ok <- bounded_authoritative_records(records) do
      if length(records) >= goal_limit() do
        Logger.warning(
          "[GoalStore] Refusing to add goal for #{agent_id}: at limit (#{goal_limit()})"
        )

        {:error, :goal_limit_reached}
      else
        :ok
      end
    end
  end

  defp mutate_goal(agent_id, goal_id, supplied_taint, operation) do
    with true <- valid_identifier?(agent_id),
         true <- valid_identifier?(goal_id),
         {:ok, supplied_taint} <- canonical_taint(supplied_taint) do
      call_owner({:mutate_goal, agent_id, goal_id, supplied_taint, operation})
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp do_mutate_goal(agent_id, goal_id, supplied_taint, operation) do
    with {:ok, %TaintedValue{value: durable_payload}, _status} <-
           load_authoritative_goal(agent_id, goal_id),
         {:ok, %Goal{} = goal} <- goal_from_map(durable_payload),
         {:ok, payload, supplied_taint} <- prepare_labeled_goal(goal, supplied_taint),
         {:ok, updated} <-
           commit_labeled_goal(
             agent_id,
             goal,
             payload,
             supplied_taint,
             {:mutate, operation}
           ) do
      emit_mutation_signal(agent_id, goal_id, operation)
      {:ok, updated}
    else
      {:error, :not_found} = error -> error
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp apply_goal_update(%Goal{} = goal, {:progress, progress}),
    do: {:ok, Goal.update_progress(goal, progress)}

  defp apply_goal_update(%Goal{} = goal, :achieve), do: {:ok, Goal.achieve(goal)}

  defp apply_goal_update(%Goal{} = goal, {:abandon, reason}),
    do: {:ok, Goal.abandon(goal, reason)}

  defp apply_goal_update(%Goal{} = goal, {:fail, reason}), do: {:ok, Goal.fail(goal, reason)}
  defp apply_goal_update(%Goal{} = goal, {:note, note}), do: {:ok, Goal.add_note(goal, note)}

  defp apply_goal_update(%Goal{} = goal, {:block, blockers}) do
    metadata = Map.put(goal.metadata || %{}, :blockers, blockers || [])
    {:ok, %{goal | status: :blocked, metadata: metadata}}
  end

  defp apply_goal_update(%Goal{} = goal, {:metadata, metadata}) do
    {:ok, %{goal | metadata: Map.merge(goal.metadata || %{}, metadata)}}
  end

  defp apply_goal_update(_goal, _operation), do: {:error, :invalid_goal}

  defp emit_mutation_signal(agent_id, goal_id, {:progress, progress}),
    do: emit_after_commit(fn -> Signals.emit_goal_progress(agent_id, goal_id, progress) end)

  defp emit_mutation_signal(agent_id, goal_id, :achieve),
    do: emit_after_commit(fn -> Signals.emit_goal_achieved(agent_id, goal_id) end)

  defp emit_mutation_signal(agent_id, goal_id, {:abandon, reason}),
    do: emit_after_commit(fn -> Signals.emit_goal_abandoned(agent_id, goal_id, reason) end)

  defp emit_mutation_signal(agent_id, goal_id, {:fail, reason}),
    do:
      emit_after_commit(fn ->
        Signals.emit_goal_abandoned(agent_id, goal_id, reason || "failed")
      end)

  defp emit_mutation_signal(agent_id, goal_id, {:block, _blockers}),
    do: emit_after_commit(fn -> Signals.emit_goal_abandoned(agent_id, goal_id, "blocked") end)

  defp emit_mutation_signal(_agent_id, _goal_id, _operation), do: :ok

  defp emit_after_commit(fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp prepare_labeled_goal(%Goal{} = goal, taint) do
    with {:ok, payload} <- serialize_goal(goal),
         {:ok, taint} <- canonical_taint(taint),
         {:ok, _goal_envelope} <- TaintEnvelope.new(payload, taint),
         {:ok, _embedding_envelope} <- TaintEnvelope.new(goal.description, taint) do
      {:ok, payload, taint}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp canonical_taint(taint) do
    case Taint.canonicalize(taint) do
      {:ok, %Taint{} = canonical} -> {:ok, canonical}
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp join_existing_goal_taint(agent_id, goal_id, supplied_taint) do
    join_authoritative_goal_taint(agent_id, goal_id, supplied_taint)
  end

  defp commit_labeled_goal(agent_id, %Goal{} = goal, payload, %Taint{} = taint, transition) do
    with {:ok, committed_goal, committed_payload, committed_taint} <-
           commit_goal_record(agent_id, goal, payload, taint, transition),
         :ok <-
           install_live_goal(agent_id, committed_goal, committed_payload, committed_taint) do
      queue_goal_embedding(agent_id, committed_goal, committed_taint)
      {:ok, committed_goal}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :persistence_failed}
    end
  end

  defp commit_goal_record(agent_id, %Goal{} = goal, payload, %Taint{} = taint, transition) do
    compare_and_swap_goal(
      agent_id,
      goal,
      payload,
      taint,
      transition,
      @critical_write_attempts
    )
  end

  defp compare_and_swap_goal(
         _agent_id,
         _goal,
         _payload,
         _taint,
         _transition,
         0
       ),
       do: {:error, :persistence_failed}

  defp compare_and_swap_goal(
         agent_id,
         %Goal{} = candidate_goal,
         candidate_payload,
         %Taint{} = supplied_taint,
         transition,
         attempts
       ) do
    logical_key = durable_key(agent_id, candidate_goal.id)

    with {:ok, current} <- load_named_goal_context(agent_id, candidate_goal.id),
         {:ok, goal, payload} <-
           transition_candidate(candidate_goal, candidate_payload, transition, current),
         {:ok, taint} <- join_context_taint(candidate_goal.id, current, supplied_taint),
         expected <- context_expected(current) do
      commit_named_goal_candidate(
        agent_id,
        logical_key,
        goal,
        payload,
        taint,
        expected,
        candidate_goal,
        candidate_payload,
        supplied_taint,
        transition,
        attempts
      )
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid_provenance} ->
        {:error, :invalid_provenance}

      {:error, {:memory_store, :critical, reason}}
      when reason in [:durable_unavailable, :insufficient_durability] ->
        {:error, :store_unavailable}

      {:error, _reason} ->
        {:error, :persistence_failed}

      _ ->
        {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp commit_named_goal_candidate(
         agent_id,
         logical_key,
         %Goal{} = goal,
         payload,
         %Taint{} = taint,
         expected,
         candidate_goal,
         candidate_payload,
         supplied_taint,
         transition,
         attempts
       ) do
    case MemoryStore.compare_and_swap_tainted(@namespace, logical_key, expected, payload,
           taint: taint
         ) do
      {:ok, _record} ->
        {:ok, goal, payload, taint}

      {:error, {:memory_store, :critical, :conflict}} ->
        compare_and_swap_goal(
          agent_id,
          candidate_goal,
          candidate_payload,
          supplied_taint,
          transition,
          attempts - 1
        )

      {:error, {:memory_store, :critical, reason}}
      when reason in [:durable_unavailable, :insufficient_durability] ->
        {:error, :store_unavailable}

      {:error, _reason} ->
        {:error, :persistence_failed}

      _ ->
        {:error, :persistence_failed}
    end
  end

  defp load_named_goal_context(agent_id, goal_id) do
    case MemoryStore.load_tainted_authoritative_with_status(
           @namespace,
           durable_key(agent_id, goal_id)
         ) do
      {:ok, %TaintedValue{} = value, status, %Record{} = record, location}
      when status in [:verified, :legacy_unlabeled, :invalid_durable_provenance] and
             location in [:namespaced, :legacy_bare] ->
        {:ok, %{value: value, status: status, record: record, location: location}}

      {:error, :not_found} ->
        {:ok, :not_found}

      {:error, {:memory_store, :critical, reason}}
      when reason in [:durable_unavailable, :insufficient_durability] ->
        {:error, :store_unavailable}

      {:error, _reason} ->
        {:error, :invalid_provenance}

      _ ->
        {:error, :invalid_provenance}
    end
  end

  defp transition_candidate(_goal, _payload, {:upsert, %Goal{} = replacement}, _current),
    do: serialize_transition_goal(replacement)

  defp transition_candidate(_goal, _payload, {:mutate, _operation}, :not_found),
    do: {:error, :not_found}

  defp transition_candidate(
         _goal,
         _payload,
         {:mutate, operation},
         %{value: %TaintedValue{value: durable_payload}}
       ) do
    with {:ok, %Goal{} = current_goal} <- goal_from_map(durable_payload),
         {:ok, updated} <- apply_goal_update(current_goal, operation) do
      serialize_transition_goal(updated)
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp transition_candidate(_goal, _payload, _transition, _current),
    do: {:error, :invalid_provenance}

  defp serialize_transition_goal(%Goal{} = goal) do
    with {:ok, payload} <- serialize_goal(goal) do
      {:ok, goal, payload}
    end
  end

  defp join_context_taint(_goal_id, :not_found, %Taint{} = supplied_taint),
    do: {:ok, supplied_taint}

  defp join_context_taint(
         goal_id,
         %{value: %TaintedValue{value: payload, taint: durable_taint}, status: status},
         %Taint{} = supplied_taint
       ) do
    prior_taint = authoritative_existing_taint(goal_id, payload, durable_taint, status)
    Taint.join(prior_taint, supplied_taint)
  end

  defp context_expected(:not_found), do: :not_found
  defp context_expected(%{record: %Record{} = record}), do: record

  defp install_live_goal(agent_id, %Goal{} = goal, payload, %Taint{} = taint) do
    case Provenance.put(:goal, agent_id, goal.id, payload, taint) do
      :ok -> insert_live_goal(agent_id, goal)
      {:error, _reason} -> fail_live_projection(agent_id, goal.id)
      _ -> fail_live_projection(agent_id, goal.id)
    end
  rescue
    _ -> fail_live_projection(agent_id, goal.id)
  catch
    _, _ -> fail_live_projection(agent_id, goal.id)
  end

  defp insert_live_goal(agent_id, %Goal{} = goal) do
    if :ets.insert(@ets_table, {{agent_id, goal.id}, goal}) do
      :ok
    else
      fail_live_projection(agent_id, goal.id)
    end
  rescue
    _ -> fail_live_projection(agent_id, goal.id)
  catch
    _, _ -> fail_live_projection(agent_id, goal.id)
  end

  defp fail_live_projection(agent_id, goal_id) do
    _ = safe_ets_delete({agent_id, goal_id})
    _ = Provenance.delete(:goal, agent_id, goal_id)
    {:error, :projection_failed}
  end

  defp queue_goal_embedding(agent_id, %Goal{} = goal, %Taint{} = taint) do
    _ =
      MemoryStore.embed_async(@namespace, durable_key(agent_id, goal.id), goal.description,
        agent_id: agent_id,
        type: :goal,
        taint: taint
      )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_get_goal_tainted(agent_id, goal_id) do
    case load_authoritative_goal(agent_id, goal_id) do
      {:ok, %TaintedValue{} = value, status} ->
        project_authoritative_goal(agent_id, goal_id, value, status)

      {:error, :not_found} ->
        remove_live_goal(agent_id, goal_id)
        {:error, :not_found}

      {:error, _reason} = error ->
        error

      _ ->
        invalidate_live_goal(agent_id, goal_id)
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp do_get_goal_list_tainted(agent_id, scope) when scope in [:active, :all] do
    with true <- valid_identifier?(agent_id),
         {:ok, records} <- load_authoritative_goal_records(agent_id),
         :ok <- bounded_authoritative_records(records),
         {:ok, entries, errors} <- reconcile_authoritative_goal_records(agent_id, records) do
      selected =
        case scope do
          :active ->
            entries
            |> Enum.filter(fn {%TaintedValue{value: goal}, _status} -> goal.status == :active end)
            |> Enum.sort_by(fn {%TaintedValue{value: goal}, _status} -> goal.priority end, :desc)

          :all ->
            entries
        end

      reply =
        cond do
          :projection_failed in errors -> {:error, :projection_failed}
          errors != [] -> {:error, :invalid_provenance}
          true -> {:ok, selected}
        end

      {:reconciled, reply, projected_goal_ids(entries)}
    else
      false -> {:error, :invalid_provenance}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp project_authoritative_goal(agent_id, goal_id, %TaintedValue{} = value, status) do
    case decode_authoritative_goal(goal_id, value, status) do
      {:ok, %Goal{} = goal, payload, taint, provenance_status} ->
        case install_live_goal(agent_id, goal, payload, taint) do
          :ok -> {:ok, TaintedValue.wrap(goal, taint), provenance_status}
          {:error, _reason} = error -> error
          _ -> fail_live_projection(agent_id, goal_id)
        end

      {:error, _reason} ->
        invalidate_live_goal(agent_id, goal_id)
    end
  end

  defp project_authoritative_goal(agent_id, goal_id, _value, _status) do
    invalidate_live_goal(agent_id, goal_id)
  end

  defp decode_authoritative_goal(
         goal_id,
         %TaintedValue{value: goal_map, taint: durable_taint},
         durable_status
       )
       when durable_status in [:verified, :legacy_unlabeled, :invalid_durable_provenance] do
    with {:ok, %Goal{id: ^goal_id} = goal} <- goal_from_map(goal_map),
         {:ok, payload} <- serialize_goal(goal),
         {:ok, taint} <- reload_taint(goal_map, payload, durable_taint, durable_status),
         {:ok, ^payload, ^taint} <- prepare_labeled_goal(goal, taint) do
      {:ok, goal, payload, taint, provenance_status(taint, durable_status)}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp decode_authoritative_goal(_goal_id, _value, _status),
    do: {:error, :invalid_provenance}

  defp join_authoritative_goal_taint(agent_id, goal_id, supplied_taint) do
    case load_authoritative_goal(agent_id, goal_id) do
      {:ok, %TaintedValue{value: payload, taint: durable_taint}, status} ->
        prior_taint = authoritative_existing_taint(goal_id, payload, durable_taint, status)

        case Taint.join(prior_taint, supplied_taint) do
          {:ok, %Taint{} = taint} -> {:ok, taint, true}
          _ -> {:error, :invalid_provenance}
        end

      {:error, :not_found} ->
        {:ok, supplied_taint, false}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :invalid_provenance}
    end
  end

  defp authoritative_existing_taint(goal_id, payload, durable_taint, status) do
    with {:ok, %Goal{id: ^goal_id} = goal} <- goal_from_map(payload),
         {:ok, canonical_payload} <- serialize_goal(goal),
         {:ok, taint} <- reload_taint(payload, canonical_payload, durable_taint, status) do
      taint
    else
      _ -> TaintEnvelope.invalid_fallback()
    end
  end

  defp load_goals_from_authoritative_store do
    case load_authoritative_goal_records(nil) do
      {:ok, records} ->
        {projected_ids, loaded} =
          Enum.reduce(records, {%{}, 0}, fn record, {projected_ids, loaded} ->
            with %{logical_key: key} <- record,
                 {:ok, agent_id, goal_id} <- agent_and_goal_from_key(key),
                 ids <- Map.get(projected_ids, agent_id, MapSet.new()),
                 true <- MapSet.size(ids) < @max_projected_goals_per_agent,
                 {:ok, ^agent_id, ^goal_id} <- restore_goal_record(record) do
              {Map.put(projected_ids, agent_id, MapSet.put(ids, goal_id)), loaded + 1}
            else
              _ -> {projected_ids, loaded}
            end
          end)

        Logger.info("GoalStore: loaded #{loaded} goals from authoritative store")
        projected_ids

      _ ->
        %{}
    end
  rescue
    _ ->
      Logger.warning("GoalStore: failed to load goals from authoritative store")
      %{}
  catch
    _, _ ->
      Logger.warning("GoalStore: failed to load goals from authoritative store")
      %{}
  end

  defp restore_goal_record(%{logical_key: key, value: value, status: status}) do
    with %TaintedValue{} <- value,
         {:ok, agent_id, goal_id} <- agent_and_goal_from_key(key),
         :ok <- restore_tainted_goal(agent_id, goal_id, value, status) do
      {:ok, agent_id, goal_id}
    else
      _ ->
        with {:ok, agent_id, goal_id} <- agent_and_goal_from_key(key) do
          invalidate_live_goal(agent_id, goal_id)
        else
          _ -> {:error, :invalid_provenance}
        end
    end
  end

  defp restore_goal_record(_entry), do: {:error, :invalid_provenance}

  defp restore_tainted_goal(agent_id, goal_id, %TaintedValue{} = value, status) do
    case project_authoritative_goal(agent_id, goal_id, value, status) do
      {:ok, %TaintedValue{}, _provenance_status} -> :ok
      {:error, _reason} = error -> error
      _ -> invalidate_live_goal(agent_id, goal_id)
    end
  rescue
    _ -> invalidate_live_goal(agent_id, goal_id)
  catch
    _, _ -> invalidate_live_goal(agent_id, goal_id)
  end

  defp restore_tainted_goal(agent_id, goal_id, _value, _status) do
    invalidate_live_goal(agent_id, goal_id)
  end

  defp remove_live_goal(agent_id, goal_id) do
    _ = safe_ets_delete({agent_id, goal_id})
    _ = Provenance.delete(:goal, agent_id, goal_id)
    :ok
  end

  defp invalidate_live_goal(agent_id, goal_id) do
    _ = remove_live_goal(agent_id, goal_id)
    {:error, :invalid_provenance}
  end

  defp reload_taint(_durable_payload, _canonical_payload, _taint, :legacy_unlabeled),
    do: {:ok, TaintEnvelope.missing_fallback()}

  defp reload_taint(
         _durable_payload,
         _canonical_payload,
         _taint,
         :invalid_durable_provenance
       ),
       do: {:ok, TaintEnvelope.invalid_fallback()}

  defp reload_taint(durable_payload, canonical_payload, taint, :verified) do
    with {:ok, durable_digest} <- TaintEnvelope.payload_sha256(durable_payload),
         {:ok, canonical_digest} <- TaintEnvelope.payload_sha256(canonical_payload) do
      if durable_digest == canonical_digest do
        canonical_taint(taint)
      else
        {:ok, TaintEnvelope.invalid_fallback()}
      end
    else
      _ -> {:ok, TaintEnvelope.invalid_fallback()}
    end
  end

  defp prepare_import_goals(goal_maps) do
    Enum.reduce(goal_maps, [], fn goal_map, acc ->
      with {:ok, goal} <- goal_from_map(goal_map),
           {:ok, payload, taint} <-
             prepare_labeled_goal(goal, TaintEnvelope.missing_fallback()) do
        [{goal, payload, taint} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp ambiguous_import_goal_identifier?(goal_map) when is_map(goal_map) do
    Enum.any?([Map.get(goal_map, :id), Map.get(goal_map, "id")], fn
      value when is_binary(value) -> String.contains?(value, ":")
      _ -> false
    end)
  end

  defp ambiguous_import_goal_identifier?(_goal_map), do: false

  defp do_import_goals(agent_id, entries, state) do
    Enum.reduce_while(entries, {:ok, state}, fn
      {%Goal{} = goal, _payload, %Taint{} = taint}, {:ok, state} ->
        with :ok <- ensure_projection_slot(state, agent_id, goal.id) do
          result = do_add_goal(agent_id, goal, taint, false)
          {reply, state} = track_goal_write_result(result, state, agent_id, goal.id)

          case reply do
            {:ok, %Goal{}} -> {:cont, {:ok, state}}
            {:error, _reason} = error -> {:halt, {error, state}}
            _ -> {:halt, {{:error, :invalid_provenance}, state}}
          end
        else
          {:error, _reason} = error -> {:halt, {error, state}}
        end

      _invalid, {:ok, state} ->
        {:halt, {{:error, :invalid_provenance}, state}}
    end)
    |> case do
      {:ok, state} -> {:ok, state}
      {{:error, _reason} = error, state} -> {error, state}
      _ -> {{:error, :invalid_provenance}, state}
    end
  rescue
    _ -> {{:error, :invalid_provenance}, state}
  catch
    _, _ -> {{:error, :invalid_provenance}, state}
  end

  defp do_delete_goal(agent_id, goal_id) do
    with true <- valid_identifier?(agent_id),
         true <- valid_identifier?(goal_id),
         :ok <- delete_goal_record(agent_id, goal_id) do
      converge_deleted_goal(agent_id, goal_id)
    else
      false -> {:error, :invalid_provenance}
      {:error, _reason} = error -> error
      _ -> {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp do_clear_goals(agent_id, state) do
    with true <- valid_identifier?(agent_id),
         {:ok, records} <- load_authoritative_goal_records(agent_id),
         :ok <- bounded_authoritative_records(records),
         {:ok, goal_ids} <- goal_ids_from_records(records, agent_id) do
      case delete_goal_records(agent_id, goal_ids, state) do
        {:ok, state} -> finalize_goal_clear(agent_id, state)
        {{:error, _reason} = error, state} -> {error, state}
        _ -> {{:error, :persistence_failed}, state}
      end
    else
      false -> {{:error, :invalid_provenance}, state}
      {:error, _reason} = error -> {error, state}
      _ -> {{:error, :persistence_failed}, state}
    end
  rescue
    _ -> {{:error, :persistence_failed}, state}
  catch
    _, _ -> {{:error, :persistence_failed}, state}
  end

  defp finalize_goal_clear(agent_id, state) do
    projected_ids_for_agent(state, agent_id)
    |> Enum.each(&remove_live_goal(agent_id, &1))

    state = clear_projected_ids(state, agent_id)

    case Provenance.delete_domain_agent(:goal, agent_id) do
      :ok ->
        emit_after_commit(fn ->
          Signals.emit_memory_signal(
            agent_id,
            :goals_cleared,
            %{cleared_at: DateTime.utc_now()},
            scope: :cluster
          )
        end)

        {:ok, state}

      _ ->
        {{:error, :projection_failed}, state}
    end
  end

  defp converge_deleted_goal(agent_id, goal_id) do
    _ = remove_live_goal(agent_id, goal_id)

    emit_after_commit(fn ->
      Signals.emit_memory_signal(
        agent_id,
        :goal_deleted,
        %{goal_id: goal_id, deleted_at: DateTime.utc_now()},
        scope: :cluster
      )
    end)
  end

  defp delete_goal_record(agent_id, goal_id) do
    case MemoryStore.delete_tainted_authoritative(
           @namespace,
           durable_key(agent_id, goal_id)
         ) do
      :ok ->
        :ok

      {:error, {:memory_store, :critical, reason}}
      when reason in [:durable_unavailable, :insufficient_durability] ->
        {:error, :store_unavailable}

      {:error, _reason} ->
        {:error, :persistence_failed}

      _ ->
        {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp delete_goal_records(_agent_id, [], state), do: {:ok, state}

  defp delete_goal_records(agent_id, [goal_id | rest], state) do
    case delete_goal_record(agent_id, goal_id) do
      :ok ->
        _ = converge_deleted_goal(agent_id, goal_id)
        state = untrack_projected_id(state, agent_id, goal_id)
        delete_goal_records(agent_id, rest, state)

      {:error, _reason} = error ->
        {error, state}

      _ ->
        {{:error, :persistence_failed}, state}
    end
  end

  defp delete_goal_records(_agent_id, _goal_ids, state),
    do: {{:error, :persistence_failed}, state}

  defp do_reload_goal(agent_id, goal_id) do
    case load_authoritative_goal(agent_id, goal_id) do
      {:ok, %TaintedValue{} = value, status} ->
        case project_authoritative_goal(agent_id, goal_id, value, status) do
          {:ok, %TaintedValue{}, _provenance_status} -> {:reloaded, :present}
          {:error, _reason} = error -> error
          _ -> invalidate_live_goal(agent_id, goal_id)
        end

      {:error, :not_found} ->
        _ = remove_live_goal(agent_id, goal_id)
        {:reloaded, :absent}

      {:error, :invalid_provenance} ->
        invalidate_live_goal(agent_id, goal_id)

      {:error, _reason} ->
        {:error, :store_unavailable}

      _ ->
        invalidate_live_goal(agent_id, goal_id)
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp do_reload_for_agent(agent_id) do
    with true <- valid_identifier?(agent_id),
         {:ok, records} <- load_authoritative_goal_records(agent_id),
         :ok <- bounded_authoritative_records(records),
         {:ok, entries, errors} <- reconcile_authoritative_goal_records(agent_id, records) do
      reply = if :projection_failed in errors, do: {:error, :projection_failed}, else: :ok
      {:reconciled, reply, projected_goal_ids(entries)}
    else
      false -> {:error, :invalid_provenance}
      {:error, _reason} = error -> error
      _ -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp reconcile_authoritative_goal_records(agent_id, records) when is_list(records) do
    {entries, errors} =
      Enum.reduce(records, {[], []}, fn record, {entries, errors} ->
        case project_authoritative_goal_record(agent_id, record) do
          {:ok, %TaintedValue{} = value, status} ->
            {[{value, status} | entries], errors}

          {:error, reason} when reason in [:invalid_provenance, :projection_failed] ->
            {entries, [reason | errors]}

          _ ->
            {entries, [:invalid_provenance | errors]}
        end
      end)

    {:ok, Enum.reverse(entries), Enum.uniq(errors)}
  end

  defp reconcile_authoritative_goal_records(_agent_id, _records),
    do: {:error, :invalid_provenance}

  defp project_authoritative_goal_record(
         agent_id,
         %{logical_key: key, value: %TaintedValue{} = value, status: status}
       ) do
    with {:ok, ^agent_id, goal_id} <- agent_and_goal_from_key(key) do
      project_authoritative_goal(agent_id, goal_id, value, status)
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp project_authoritative_goal_record(_agent_id, _record),
    do: {:error, :invalid_provenance}

  defp projected_goal_ids(entries) do
    Enum.map(entries, fn {%TaintedValue{value: %Goal{id: goal_id}}, _status} -> goal_id end)
  end

  defp bounded_authoritative_records(records) when is_list(records),
    do: bounded_authoritative_records(records, 0)

  defp bounded_authoritative_records(_records), do: {:error, :projection_failed}

  defp bounded_authoritative_records([], _count), do: :ok

  defp bounded_authoritative_records([_record | rest], count)
       when count < @max_projected_goals_per_agent,
       do: bounded_authoritative_records(rest, count + 1)

  defp bounded_authoritative_records(_records, _count), do: {:error, :projection_failed}

  defp goal_ids_from_records(records, agent_id) when is_list(records) do
    collect_goal_ids(records, agent_id, [], MapSet.new())
  end

  defp goal_ids_from_records(_records, _agent_id), do: {:error, :invalid_provenance}

  defp collect_goal_ids([], _agent_id, goal_ids, _seen),
    do: {:ok, Enum.reverse(goal_ids)}

  defp collect_goal_ids(
         [%{logical_key: key} | rest],
         agent_id,
         goal_ids,
         seen
       ) do
    with {:ok, ^agent_id, goal_id} <- agent_and_goal_from_key(key),
         false <- MapSet.member?(seen, goal_id) do
      collect_goal_ids(rest, agent_id, [goal_id | goal_ids], MapSet.put(seen, goal_id))
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp collect_goal_ids(_records, _agent_id, _goal_ids, _seen),
    do: {:error, :invalid_provenance}

  defp load_authoritative_goal(agent_id, goal_id) do
    with true <- valid_identifier?(agent_id),
         true <- valid_identifier?(goal_id) do
      case load_named_goal_context(agent_id, goal_id) do
        {:ok, %{value: value, status: status}} -> {:ok, value, status}
        {:ok, :not_found} -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :invalid_provenance}
      {:error, _reason} = error -> error
      _ -> {:error, :store_unavailable}
    end
  end

  defp load_authoritative_goal_records(agent_id) do
    result =
      case agent_id do
        nil -> MemoryStore.load_all_tainted_authoritative(@namespace)
        agent_id -> MemoryStore.load_by_prefix_tainted_authoritative(@namespace, "#{agent_id}:")
      end

    case result do
      {:ok, entries} when is_list(entries) ->
        {:ok,
         Enum.map(entries, fn {logical_key, value, status} ->
           %{logical_key: logical_key, value: value, status: status}
         end)}

      {:error, {:memory_store, :critical, reason}}
      when reason in [:durable_unavailable, :insufficient_durability] ->
        {:error, :store_unavailable}

      {:error, _reason} ->
        {:error, :invalid_provenance}

      _ ->
        {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp durable_key(agent_id, goal_id), do: "#{agent_id}:#{goal_id}"

  defp serialize_goal(%Goal{} = goal) do
    with true <- exact_goal_shape?(goal),
         {:ok, _validated} <- decode_normalized_goal(Map.from_struct(goal)),
         {:ok, created_at} <- serialize_datetime(goal.created_at),
         {:ok, achieved_at} <- serialize_datetime(goal.achieved_at),
         {:ok, deadline} <- serialize_datetime(goal.deadline),
         {:ok, referenced_date} <- serialize_datetime(goal.referenced_date) do
      payload =
        goal
        |> Map.from_struct()
        |> Map.put(:created_at, created_at)
        |> Map.put(:achieved_at, achieved_at)
        |> Map.put(:deadline, deadline)
        |> Map.put(:referenced_date, referenced_date)

      {:ok, payload}
    else
      _ -> {:error, :invalid_goal}
    end
  rescue
    _ -> {:error, :invalid_goal}
  catch
    _, _ -> {:error, :invalid_goal}
  end

  defp serialize_goal(_goal), do: {:error, :invalid_goal}

  defp exact_goal_shape?(%Goal{} = goal) do
    map_size(goal) == length(@goal_fields) + 1 and
      Enum.sort(Map.keys(goal)) == Enum.sort([:__struct__ | @goal_fields])
  end

  defp goal_from_map(%Goal{} = goal) do
    case serialize_goal(goal) do
      {:ok, _payload} -> {:ok, goal}
      {:error, _reason} = error -> error
    end
  end

  defp goal_from_map(map) when is_map(map) and not is_struct(map) do
    with :ok <- validate_goal_map_keys(map),
         normalized <- SafeAtom.atomize_keys(map, @goal_fields),
         {:ok, goal} <- decode_normalized_goal(normalized) do
      {:ok, goal}
    else
      _ -> {:error, :invalid_goal}
    end
  rescue
    _ -> {:error, :invalid_goal}
  catch
    _, _ -> {:error, :invalid_goal}
  end

  defp goal_from_map(_map), do: {:error, :invalid_goal}

  defp validate_goal_map_keys(map) do
    allowed_strings = Enum.map(@goal_fields, &Atom.to_string/1)

    valid_keys? =
      Enum.all?(Map.keys(map), fn key ->
        key in @goal_fields or key in allowed_strings
      end)

    duplicate_alias? =
      Enum.any?(@goal_fields, fn key ->
        Map.has_key?(map, key) and Map.has_key?(map, Atom.to_string(key))
      end)

    if valid_keys? and not duplicate_alias?, do: :ok, else: {:error, :invalid_goal}
  end

  defp decode_normalized_goal(map) do
    with {:ok, id} <- required_field(map, :id, &identifier_value/1),
         {:ok, description} <- required_field(map, :description, &description_value/1),
         {:ok, type} <- optional_field(map, :type, :achieve, &enum_value(&1, @goal_types)),
         {:ok, status} <- optional_field(map, :status, :active, &enum_value(&1, @goal_statuses)),
         {:ok, priority} <- optional_field(map, :priority, 50, &priority_value/1),
         {:ok, parent_id} <- optional_field(map, :parent_id, nil, &optional_identifier_value/1),
         {:ok, progress} <- optional_field(map, :progress, 0.0, &progress_value/1),
         {:ok, created_at} <- required_field(map, :created_at, &datetime_value/1),
         {:ok, achieved_at} <- optional_field(map, :achieved_at, nil, &optional_datetime_value/1),
         {:ok, deadline} <- optional_field(map, :deadline, nil, &optional_datetime_value/1),
         {:ok, success_criteria} <-
           optional_field(map, :success_criteria, nil, &optional_binary_value/1),
         {:ok, notes} <- optional_field(map, :notes, [], &notes_value/1),
         {:ok, assigned_by} <- optional_field(map, :assigned_by, nil, &assigned_by_value/1),
         {:ok, metadata} <- optional_field(map, :metadata, %{}, &metadata_value/1),
         {:ok, referenced_date} <-
           optional_field(map, :referenced_date, nil, &optional_datetime_value/1) do
      {:ok,
       %Goal{
         id: id,
         description: description,
         type: type,
         status: status,
         priority: priority,
         parent_id: parent_id,
         progress: progress,
         created_at: created_at,
         achieved_at: achieved_at,
         deadline: deadline,
         success_criteria: success_criteria,
         notes: notes,
         assigned_by: assigned_by,
         metadata: metadata,
         referenced_date: referenced_date
       }}
    else
      _ -> {:error, :invalid_goal}
    end
  end

  defp required_field(map, key, validator) do
    case Map.fetch(map, key) do
      {:ok, value} -> validator.(value)
      :error -> {:error, :invalid_goal}
    end
  end

  defp optional_field(map, key, default, validator) do
    case Map.fetch(map, key) do
      {:ok, value} -> validator.(value)
      :error -> {:ok, default}
    end
  end

  defp identifier_value(value) when is_binary(value) do
    if byte_size(value) <= @max_identifier_bytes and String.valid?(value) and
         String.trim(value) != "" and not String.contains?(value, ":") do
      {:ok, value}
    else
      {:error, :invalid_goal}
    end
  end

  defp identifier_value(_value), do: {:error, :invalid_goal}

  defp description_value(value) when is_binary(value) do
    if byte_size(value) <= @max_goal_text_bytes and String.valid?(value) and
         String.trim(value) != "" do
      {:ok, value}
    else
      {:error, :invalid_goal}
    end
  end

  defp description_value(_value), do: {:error, :invalid_goal}

  defp optional_identifier_value(nil), do: {:ok, nil}
  defp optional_identifier_value(value), do: identifier_value(value)

  defp optional_binary_value(nil), do: {:ok, nil}

  defp optional_binary_value(value) when is_binary(value) do
    if byte_size(value) <= @max_goal_text_bytes and String.valid?(value),
      do: {:ok, value},
      else: {:error, :invalid_goal}
  end

  defp optional_binary_value(_value), do: {:error, :invalid_goal}

  defp enum_value(value, allowed) do
    case SafeAtom.to_allowed(value, allowed) do
      {:ok, atom} -> {:ok, atom}
      {:error, _reason} -> {:error, :invalid_goal}
    end
  end

  defp priority_value(value) when is_integer(value) and value >= 0 and value <= 100,
    do: {:ok, value}

  defp priority_value(_value), do: {:error, :invalid_goal}

  defp progress_value(value) when is_float(value) and value >= 0.0 and value <= 1.0,
    do: {:ok, value}

  defp progress_value(_value), do: {:error, :invalid_goal}

  defp datetime_value(%DateTime{} = datetime) do
    case serialize_datetime(datetime) do
      {:ok, _serialized} -> {:ok, datetime}
      _ -> {:error, :invalid_goal}
    end
  end

  defp datetime_value(value) when is_binary(value) and byte_size(value) <= 128 do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_goal}
    end
  end

  defp datetime_value(_value), do: {:error, :invalid_goal}

  defp optional_datetime_value(nil), do: {:ok, nil}
  defp optional_datetime_value(value), do: datetime_value(value)

  defp notes_value(value) do
    case validate_notes(value, 0) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp validate_notes([], _count), do: :ok

  defp validate_notes([note | rest], count) when count < @max_goal_notes do
    if is_binary(note) and byte_size(note) <= @max_goal_note_bytes and String.valid?(note) do
      validate_notes(rest, count + 1)
    else
      {:error, :invalid_goal}
    end
  end

  defp validate_notes(_value, _count), do: {:error, :invalid_goal}

  defp assigned_by_value(nil), do: {:ok, nil}

  defp assigned_by_value(value) when is_binary(value) or is_atom(value) do
    case SafeAtom.to_existing(value) do
      {:ok, atom} -> {:ok, atom}
      {:error, _reason} -> {:error, :invalid_goal}
    end
  end

  defp assigned_by_value(_value), do: {:error, :invalid_goal}

  defp metadata_value(value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp metadata_value(_value), do: {:error, :invalid_goal}

  defp serialize_datetime(nil), do: {:ok, nil}
  defp serialize_datetime(%DateTime{} = datetime), do: {:ok, DateTime.to_iso8601(datetime)}
  defp serialize_datetime(_value), do: {:error, :invalid_goal}

  defp provenance_status(taint, status) do
    cond do
      taint == TaintEnvelope.invalid_fallback() -> :invalid_durable_provenance
      taint == TaintEnvelope.missing_fallback() -> :legacy_unlabeled
      true -> status
    end
  end

  defp agent_and_goal_from_key(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [agent_id, goal_id] ->
        if valid_identifier?(agent_id) and valid_identifier?(goal_id),
          do: {:ok, agent_id, goal_id},
          else: {:error, :invalid_key}

      _ ->
        {:error, :invalid_key}
    end
  end

  defp agent_and_goal_from_key(_key), do: {:error, :invalid_key}

  defp valid_identifier?(value) when is_binary(value) do
    match?({:ok, ^value}, identifier_value(value))
  end

  defp valid_identifier?(_value), do: false

  defp build_tree(goal, all_goals) do
    children =
      all_goals
      |> Enum.filter(&(&1.parent_id == goal.id))
      |> Enum.map(&build_tree(&1, all_goals))

    %{goal: goal, children: children}
  end
end
