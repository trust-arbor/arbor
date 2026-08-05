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
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.Memory.{MemoryStore, Provenance, Signals}

  require Logger

  @ets_table :arbor_memory_goals
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
          {:ok, Goal.t()} | {:error, :goal_limit_reached | :invalid_provenance}
  def add_goal_tainted(agent_id, %Goal{} = goal, taint) do
    with {:ok, _payload, taint} <- prepare_labeled_goal(goal, taint),
         {:ok, taint} <- join_existing_goal_taint(agent_id, goal.id, taint) do
      if at_goal_limit?(agent_id) do
        Logger.warning(
          "[GoalStore] Refusing to add goal for #{agent_id}: at limit (#{goal_limit()})"
        )

        {:error, :goal_limit_reached}
      else
        with {:ok, payload, taint} <- prepare_labeled_goal(goal, taint),
             :ok <- commit_labeled_goal(agent_id, goal, payload, taint) do
          Signals.emit_goal_created(agent_id, goal)
          Logger.debug("Goal added for #{agent_id}: #{goal.id}")
          {:ok, goal}
        end
      end
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

  # Count active goals for an agent and check against the cap.
  defp at_goal_limit?(agent_id) do
    count = :ets.select_count(@ets_table, [{{{agent_id, :_}, :_}, [], [true]}])
    count >= goal_limit()
  rescue
    # If ETS doesn't exist or select_count fails, allow the add (fallback to
    # old behavior so we don't break the system on a transient ETS issue).
    _ -> false
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
    with {:ok, %Goal{} = goal} <- get_goal(agent_id, goal_id),
         {:ok, payload} <- serialize_goal(goal),
         {:ok, taint, status} <- Provenance.resolve(:goal, agent_id, goal_id, payload) do
      {:ok, TaintedValue.wrap(goal, taint), provenance_status(taint, status)}
    else
      {:error, :not_found} = error -> error
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
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
    with {:ok, updated} <-
           mutate_goal(agent_id, goal_id, taint, &Goal.update_progress(&1, progress)) do
      Signals.emit_goal_progress(agent_id, goal_id, progress)
      {:ok, updated}
    end
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
    with {:ok, updated} <- mutate_goal(agent_id, goal_id, taint, &Goal.achieve/1) do
      Signals.emit_goal_achieved(agent_id, goal_id)
      {:ok, updated}
    end
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
    with {:ok, updated} <- mutate_goal(agent_id, goal_id, taint, &Goal.abandon(&1, reason)) do
      Signals.emit_goal_abandoned(agent_id, goal_id, reason)
      {:ok, updated}
    end
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
    with {:ok, updated} <- mutate_goal(agent_id, goal_id, taint, &Goal.fail(&1, reason)) do
      Signals.emit_goal_abandoned(agent_id, goal_id, reason || "failed")
      {:ok, updated}
    end
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
    mutate_goal(agent_id, goal_id, taint, &Goal.add_note(&1, note))
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
    update = fn goal ->
      updated_metadata = Map.put(goal.metadata || %{}, :blockers, blockers || [])
      %{goal | status: :blocked, metadata: updated_metadata}
    end

    with {:ok, updated} <- mutate_goal(agent_id, goal_id, taint, update) do
      Signals.emit_goal_abandoned(agent_id, goal_id, "blocked")
      {:ok, updated}
    end
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
    mutate_goal(agent_id, goal_id, taint, fn goal ->
      %{goal | metadata: Map.merge(goal.metadata || %{}, new_metadata)}
    end)
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
  rescue
    ArgumentError -> []
  end

  @doc "Get active goals with per-goal taint and explicit provenance status."
  @spec get_active_goals_tainted(String.t()) ::
          {:ok, [tainted_goal()]} | {:error, :invalid_provenance}
  def get_active_goals_tainted(agent_id) do
    agent_id
    |> get_active_goals()
    |> taint_goal_list(agent_id)
  end

  @doc """
  Get all goals for an agent (any status).
  """
  @spec get_all_goals(String.t()) :: [Goal.t()]
  def get_all_goals(agent_id) do
    match_spec = [{{{agent_id, :_}, :"$1"}, [], [:"$1"]}]
    :ets.select(@ets_table, match_spec)
  rescue
    ArgumentError -> []
  end

  @doc "Get all goals with per-goal taint and explicit provenance status."
  @spec get_all_goals_tainted(String.t()) ::
          {:ok, [tainted_goal()]} | {:error, :invalid_provenance}
  def get_all_goals_tainted(agent_id) do
    agent_id
    |> get_all_goals()
    |> taint_goal_list(agent_id)
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
    _ = safe_ets_delete({agent_id, goal_id})
    _ = Provenance.delete(:goal, agent_id, goal_id)
    MemoryStore.delete("goals", "#{agent_id}:#{goal_id}")
    :ok
  end

  @doc """
  Delete all goals for an agent.
  """
  @spec clear_goals(String.t()) :: :ok
  def clear_goals(agent_id) do
    goal_ids = goal_ids_for_agent(agent_id)
    match_spec = [{{{agent_id, :_}, :_}, [], [true]}]
    _ = safe_ets_select_delete(match_spec)
    Enum.each(goal_ids, &Provenance.delete(:goal, agent_id, &1))
    MemoryStore.delete_by_prefix("goals", "#{agent_id}:")
    :ok
  end

  defp safe_ets_delete(key) do
    :ets.delete(@ets_table, key)
  rescue
    ArgumentError -> :ok
  end

  defp safe_ets_select_delete(match_spec) do
    :ets.select_delete(@ets_table, match_spec)
  rescue
    ArgumentError -> 0
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
  @spec reload_for_agent(String.t()) :: :ok
  def reload_for_agent(agent_id) do
    if MemoryStore.available?() do
      prefix = "#{agent_id}:"

      case MemoryStore.load_by_prefix_tainted("goals", prefix) do
        {:ok, entries} ->
          Enum.each(entries, fn
            {key, %TaintedValue{} = value, status} ->
              with {:ok, goal_id} <- goal_id_from_agent_key(key, prefix) do
                _ = restore_tainted_goal(agent_id, goal_id, value, status)
              end

            _malformed ->
              :ok
          end)

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ ->
      Logger.warning("[GoalStore] reload_for_agent failed for #{agent_id}")
      :ok
  end

  @doc false
  @spec reload_goal_from_durable(String.t(), String.t()) ::
          :ok | {:error, :invalid_provenance | :store_unavailable}
  def reload_goal_from_durable(agent_id, goal_id)
      when is_binary(agent_id) and is_binary(goal_id) do
    if MemoryStore.available?() do
      key = "#{agent_id}:#{goal_id}"

      case MemoryStore.load_tainted_with_status("goals", key) do
        {:ok, %TaintedValue{} = value, status} ->
          restore_tainted_goal(agent_id, goal_id, value, status)

        {:error, :not_found} ->
          _ = safe_ets_delete({agent_id, goal_id})
          _ = Provenance.delete(:goal, agent_id, goal_id)
          :ok

        {:error, _reason} ->
          {:error, :store_unavailable}

        _ ->
          {:error, :invalid_provenance}
      end
    else
      {:error, :store_unavailable}
    end
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
  @spec import_goals(String.t(), [map()]) :: :ok
  def import_goals(agent_id, goal_maps) when is_list(goal_maps) do
    Enum.each(goal_maps, fn goal_map ->
      with {:ok, goal} <- goal_from_map(goal_map),
           {:ok, payload, taint} <-
             prepare_labeled_goal(goal, TaintEnvelope.missing_fallback()) do
        _ = commit_live_goal(agent_id, goal, payload, taint)
      end
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def import_goals(_agent_id, _goal_maps), do: :ok

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

  defp mutate_goal(agent_id, goal_id, supplied_taint, update) do
    with {:ok, supplied_taint} <- canonical_taint(supplied_taint),
         {:ok, %TaintedValue{value: %Goal{} = goal, taint: prior_taint}, _status} <-
           get_goal_tainted(agent_id, goal_id),
         {:ok, taint} <- Taint.join(prior_taint, supplied_taint),
         {:ok, updated} <- apply_goal_update(goal, update),
         {:ok, payload, taint} <- prepare_labeled_goal(updated, taint),
         :ok <- commit_labeled_goal(agent_id, updated, payload, taint) do
      {:ok, updated}
    else
      {:error, :not_found} = error -> error
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp apply_goal_update(%Goal{} = goal, update) when is_function(update, 1) do
    case update.(goal) do
      %Goal{} = updated -> {:ok, updated}
      _ -> {:error, :invalid_goal}
    end
  rescue
    _ -> {:error, :invalid_goal}
  catch
    _, _ -> {:error, :invalid_goal}
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
    case get_goal_tainted(agent_id, goal_id) do
      {:ok, %TaintedValue{taint: prior_taint}, _status} ->
        case Taint.join(prior_taint, supplied_taint) do
          {:ok, %Taint{} = taint} -> {:ok, taint}
          _ -> {:error, :invalid_provenance}
        end

      {:error, :not_found} ->
        {:ok, supplied_taint}

      _ ->
        {:error, :invalid_provenance}
    end
  end

  defp commit_labeled_goal(agent_id, %Goal{} = goal, payload, %Taint{} = taint) do
    with :ok <- commit_live_goal(agent_id, goal, payload, taint),
         :ok <- persist_goal_async(agent_id, goal, payload, taint) do
      :ok
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp commit_live_goal(agent_id, %Goal{} = goal, payload, %Taint{} = taint) do
    with :ok <- Provenance.put(:goal, agent_id, goal.id, payload, taint),
         true <- :ets.insert(@ets_table, {{agent_id, goal.id}, goal}) do
      :ok
    else
      _ ->
        _ = Provenance.delete(:goal, agent_id, goal.id)
        {:error, :invalid_provenance}
    end
  rescue
    _ ->
      _ = Provenance.delete(:goal, agent_id, goal.id)
      {:error, :invalid_provenance}
  catch
    _, _ ->
      _ = Provenance.delete(:goal, agent_id, goal.id)
      {:error, :invalid_provenance}
  end

  defp persist_goal_async(agent_id, %Goal{} = goal, payload, %Taint{} = taint) do
    key = "#{agent_id}:#{goal.id}"

    with :ok <- MemoryStore.persist_async("goals", key, payload, taint: taint),
         :ok <-
           MemoryStore.embed_async("goals", key, goal.description,
             agent_id: agent_id,
             type: :goal,
             taint: taint
           ) do
      :ok
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp load_goals_from_postgres do
    if MemoryStore.available?() do
      case MemoryStore.load_all_tainted("goals") do
        {:ok, entries} ->
          loaded = Enum.count(entries, &restore_goal_entry/1)
          Logger.info("GoalStore: loaded #{loaded} goals from Postgres")

        _ ->
          :ok
      end
    end
  rescue
    _ -> Logger.warning("GoalStore: failed to load goals from Postgres")
  catch
    _, _ -> Logger.warning("GoalStore: failed to load goals from Postgres")
  end

  defp restore_goal_entry({key, %TaintedValue{} = value, status}) do
    with {:ok, agent_id, goal_id} <- agent_and_goal_from_key(key),
         :ok <- restore_tainted_goal(agent_id, goal_id, value, status) do
      true
    else
      _ -> false
    end
  end

  defp restore_goal_entry(_entry), do: false

  defp restore_tainted_goal(
         agent_id,
         goal_id,
         %TaintedValue{value: goal_map, taint: taint},
         status
       )
       when status in [:verified, :legacy_unlabeled, :invalid_durable_provenance] do
    with {:ok, %Goal{id: ^goal_id} = goal} <- goal_from_map(goal_map),
         {:ok, payload} <- serialize_goal(goal),
         {:ok, taint} <- reload_taint(goal_map, payload, taint, status),
         {:ok, ^payload, ^taint} <- prepare_labeled_goal(goal, taint),
         :ok <- commit_live_goal(agent_id, goal, payload, taint) do
      :ok
    else
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

  defp invalidate_live_goal(agent_id, goal_id) do
    _ = safe_ets_delete({agent_id, goal_id})
    _ = Provenance.delete(:goal, agent_id, goal_id)
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
         String.trim(value) != "" do
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

  defp taint_goal_list(goals, agent_id) when is_list(goals) do
    Enum.reduce_while(goals, {:ok, []}, fn
      %Goal{id: goal_id}, {:ok, acc} ->
        case get_goal_tainted(agent_id, goal_id) do
          {:ok, value, status} -> {:cont, {:ok, [{value, status} | acc]}}
          _ -> {:halt, {:error, :invalid_provenance}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_provenance}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp taint_goal_list(_goals, _agent_id), do: {:error, :invalid_provenance}

  defp goal_ids_for_agent(agent_id) do
    match_spec = [{{{agent_id, :"$1"}, :_}, [], [:"$1"]}]

    @ets_table
    |> :ets.select(match_spec)
    |> Enum.filter(&is_binary/1)
  rescue
    ArgumentError -> []
  end

  defp goal_id_from_agent_key(key, prefix) when is_binary(key) and is_binary(prefix) do
    if String.starts_with?(key, prefix) do
      goal_id = String.replace_prefix(key, prefix, "")
      if valid_identifier?(goal_id), do: {:ok, goal_id}, else: {:error, :invalid_key}
    else
      {:error, :invalid_key}
    end
  end

  defp goal_id_from_agent_key(_key, _prefix), do: {:error, :invalid_key}

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
