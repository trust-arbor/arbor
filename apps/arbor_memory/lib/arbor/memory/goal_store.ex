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
  @seed_goal_record_version 1
  @goal_snapshot_kind "arbor_goal_provenance"
  @goal_snapshot_version 1
  @goal_snapshot_keys ["goal_store", "outer_envelope", "snapshot_kind", "snapshot_version"]
  @goal_snapshot_payload_keys ["agent_id", "goals"]
  @seed_goal_record_keys ["payload", "provenance", "version"]
  @projection_convergence_attempts 4
  @projection_convergence_delay_ms 25

  @type provenance_status ::
          :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type tainted_goal :: {TaintedValue.t(), provenance_status()}
  @type mutation_error ::
          :not_found
          | persistence_mutation_error()
  @type persistence_mutation_error ::
          :invalid_provenance
          | :persistence_failed
          | :projection_failed
          | :store_unavailable
          | :outcome_unknown

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
    case Application.get_env(:arbor_memory, :goal_limit_per_agent, @default_goal_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_goal_limit
    end
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
          {:ok, Goal.t()}
          | {:error,
             :goal_limit_reached
             | :invalid_provenance
             | :persistence_failed
             | :projection_failed
             | :store_unavailable
             | :outcome_unknown}
  def add_goal(agent_id, %Goal{} = goal) do
    add_goal_tainted(agent_id, goal, TaintEnvelope.missing_fallback())
  end

  @spec add_goal(String.t(), String.t(), keyword()) ::
          {:ok, Goal.t()}
          | {:error,
             :empty_description
             | :goal_limit_reached
             | :invalid_provenance
             | :persistence_failed
             | :projection_failed
             | :store_unavailable
             | :outcome_unknown}
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
             :goal_limit_reached
             | :invalid_provenance
             | :persistence_failed
             | :projection_failed
             | :store_unavailable
             | :outcome_unknown}
  def add_goal_tainted(agent_id, %Goal{} = goal, taint) do
    with true <- valid_identifier?(agent_id),
         true <- valid_identifier?(goal.id),
         {:ok, payload, taint} <- prepare_labeled_goal(goal, taint) do
      call_owner({:add_goal, agent_id, goal, payload, taint}, :mutation)
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
          | {:error,
             :empty_description
             | :goal_limit_reached
             | :invalid_provenance
             | :persistence_failed
             | :projection_failed
             | :store_unavailable
             | :outcome_unknown}
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
  @spec get_goal(String.t(), String.t()) ::
          {:ok, Goal.t()} | {:error, :not_found | :store_unavailable}
  def get_goal(agent_id, goal_id) do
    if valid_identifier?(agent_id) and valid_identifier?(goal_id) do
      case call_owner({:get_goal_tainted, agent_id, goal_id}) do
        {:ok, %TaintedValue{value: %Goal{} = goal}, _status} -> {:ok, goal}
        {:error, :not_found} = error -> error
        {:error, _reason} -> {:error, :store_unavailable}
        _ -> {:error, :store_unavailable}
      end
    else
      {:error, :not_found}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  @doc """
  Get a goal with its live provenance and explicit provenance status.

  The sidecar is verified against the exact serialized goal payload. Missing
  provenance remains legacy-unlabeled; malformed or mismatched provenance is
  returned with the hostile invalid-durable-provenance label.
  """
  @spec get_goal_tainted(String.t(), String.t()) ::
          {:ok, TaintedValue.t(), provenance_status()}
          | {:error, :not_found | :invalid_provenance | :projection_failed | :store_unavailable}
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
          {:ok, Goal.t()} | {:error, mutation_error()}
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
          {:ok, Goal.t()} | {:error, mutation_error()}
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
          {:ok, Goal.t()} | {:error, mutation_error()}
  def achieve_goal(agent_id, goal_id) do
    achieve_goal_tainted(agent_id, goal_id, TaintEnvelope.missing_fallback())
  end

  @doc "Mark a goal achieved while monotonically joining an explicit label."
  @spec achieve_goal_tainted(String.t(), String.t(), Taint.t()) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
  def achieve_goal_tainted(agent_id, goal_id, taint) do
    mutate_goal(agent_id, goal_id, taint, :achieve)
  end

  @doc """
  Mark a goal as abandoned with an optional reason.

  Emits a `{:memory, :goal_abandoned}` signal.
  """
  @spec abandon_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
  def abandon_goal(agent_id, goal_id, reason \\ nil) do
    abandon_goal_tainted(agent_id, goal_id, reason, TaintEnvelope.missing_fallback())
  end

  @doc "Abandon a goal while monotonically joining an explicit label."
  @spec abandon_goal_tainted(String.t(), String.t(), String.t() | nil, Taint.t()) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
  def abandon_goal_tainted(agent_id, goal_id, reason, taint) do
    mutate_goal(agent_id, goal_id, taint, {:abandon, reason})
  end

  @doc """
  Mark a goal as failed with an optional reason.

  Sets status to `:failed` and prepends a "Failed: reason" note.
  Emits a `{:memory, :goal_failed}` signal.
  """
  @spec fail_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
  def fail_goal(agent_id, goal_id, reason \\ nil) do
    fail_goal_tainted(agent_id, goal_id, reason, TaintEnvelope.missing_fallback())
  end

  @doc "Fail a goal while monotonically joining an explicit label."
  @spec fail_goal_tainted(String.t(), String.t(), String.t() | nil, Taint.t()) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
  def fail_goal_tainted(agent_id, goal_id, reason, taint) do
    mutate_goal(agent_id, goal_id, taint, {:fail, reason})
  end

  @doc """
  Add a note to a goal's notes list.

  Prepends the note to the goal's notes field.
  """
  @spec add_note(String.t(), String.t(), String.t()) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
  def add_note(agent_id, goal_id, note) when is_binary(note) do
    add_note_tainted(agent_id, goal_id, note, TaintEnvelope.missing_fallback())
  end

  @doc "Add a note while monotonically joining an explicit label."
  @spec add_note_tainted(String.t(), String.t(), String.t(), Taint.t()) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
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
          {:ok, Goal.t()} | {:error, mutation_error()}
  def block_goal(agent_id, goal_id, blockers \\ nil) do
    block_goal_tainted(agent_id, goal_id, blockers, TaintEnvelope.missing_fallback())
  end

  @doc "Block a goal while monotonically joining an explicit label."
  @spec block_goal_tainted(String.t(), String.t(), [String.t()] | nil, Taint.t()) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
  def block_goal_tainted(agent_id, goal_id, blockers, taint) do
    mutate_goal(agent_id, goal_id, taint, {:block, blockers})
  end

  @doc """
  Update metadata for a goal, merging with existing metadata.

  ## Examples

      {:ok, goal} = GoalStore.update_goal_metadata("agent_001", goal_id, %{decomposition_failed: true})
  """
  @spec update_goal_metadata(String.t(), String.t(), map()) ::
          {:ok, Goal.t()} | {:error, mutation_error()}
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
          {:ok, Goal.t()} | {:error, mutation_error()}
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
      compatibility_goal_list(agent_id, :active)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Get active goals with per-goal taint and explicit provenance status."
  @spec get_active_goals_tainted(String.t()) ::
          {:ok, [tainted_goal()]}
          | {:error, :invalid_provenance | :projection_failed | :store_unavailable}
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
      compatibility_goal_list(agent_id, :all)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Get all goals with per-goal taint and explicit provenance status."
  @spec get_all_goals_tainted(String.t()) ::
          {:ok, [tainted_goal()]}
          | {:error, :invalid_provenance | :projection_failed | :store_unavailable}
  def get_all_goals_tainted(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:get_goal_list_tainted, agent_id, :all}),
      else: {:error, :invalid_provenance}
  end

  @doc """
  Get the goal tree starting from a given goal.

  Returns the goal and all its descendants (children, grandchildren, etc.).
  """
  @spec get_goal_tree(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :store_unavailable}
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
          :ok
          | {:error,
             :invalid_provenance | :persistence_failed | :store_unavailable | :outcome_unknown}
  def delete_goal(agent_id, goal_id) do
    if valid_identifier?(agent_id) and valid_identifier?(goal_id),
      do: call_owner({:delete_goal, agent_id, goal_id}, :mutation),
      else: {:error, :invalid_provenance}
  end

  @doc """
  Delete all goals for an agent.
  """
  @spec clear_goals(String.t()) ::
          :ok
          | {:error,
             :invalid_provenance
             | :persistence_failed
             | :projection_failed
             | :store_unavailable
             | :outcome_unknown}
  def clear_goals(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:clear_goals, agent_id}, :mutation),
      else: {:error, :invalid_provenance}
  end

  @doc """
  Idempotent content-only deletion for exactly one agent.

  Removes durable goal content, ETS projection, and owner-local convergence
  state. Retains every Provenance sidecar byte-for-byte.

  C3I2A precondition (caller-owned, not enforced here): C3I1 mutation gate
  must be closed and drained before invoke. This API is not race-free agent
  destruction.
  """
  @spec delete_agent_content(String.t()) ::
          :ok
          | {:error,
             :invalid_provenance
             | :persistence_failed
             | :projection_failed
             | :store_unavailable
             | :outcome_unknown}
  def delete_agent_content(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:delete_agent_content, agent_id}, :mutation),
      else: {:error, :invalid_provenance}
  end

  @doc """
  Authoritative absence across durable goals, ETS projection, and owner
  deferred convergence state. Returns `{:ok, true}` only when no exact-agent
  content remains.
  """
  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()}
          | {:error,
             :invalid_provenance
             | :projection_failed
             | :store_unavailable}
  def agent_content_absent?(agent_id) do
    if valid_identifier?(agent_id),
      do: call_owner({:agent_content_absent?, agent_id}, :read),
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
          :ok | {:error, :invalid_provenance | :projection_failed | :store_unavailable}
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
          :ok | {:error, :invalid_provenance | :projection_failed | :store_unavailable}
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

  Compatibility projection for callers that still consume the legacy list shape.
  Seed capture uses `export_goal_provenance_snapshot/1` so empty snapshots remain
  agent-bound and authority failures remain distinguishable.
  """
  @spec export_all_goals(String.t()) :: [map()]
  def export_all_goals(agent_id) do
    case export_all_goals_exact(agent_id) do
      {:ok, exported} -> exported
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "Export all goals without collapsing authority or provenance failures to an empty list."
  @spec export_all_goals_exact(String.t()) ::
          {:ok, [map()]} | {:error, :invalid_provenance | :store_unavailable}
  def export_all_goals_exact(agent_id) do
    with true <- valid_identifier?(agent_id),
         {:ok, entries} <- get_all_goals_tainted(agent_id),
         {:ok, exported} <- export_goal_records(entries) do
      {:ok, exported}
    else
      false -> {:error, :invalid_provenance}
      {:error, :invalid_provenance} -> {:error, :invalid_provenance}
      {:error, _reason} -> {:error, :store_unavailable}
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    :exit, _reason -> {:error, :store_unavailable}
    _, _ -> {:error, :invalid_provenance}
  end

  @doc "Export an agent-bound, versioned snapshot of authoritative goal provenance."
  @spec export_goal_provenance_snapshot(String.t()) ::
          {:ok, map()} | {:error, :invalid_provenance | :store_unavailable}
  def export_goal_provenance_snapshot(agent_id) do
    with true <- valid_identifier?(agent_id),
         {:ok, entries} <- get_all_goals_tainted(agent_id),
         :ok <- bounded_goal_snapshot_inventory(entries),
         {:ok, records} <- export_goal_records(entries),
         {:ok, aggregate_taint} <- goal_snapshot_aggregate_taint(entries),
         {:ok, snapshot} <- encode_goal_provenance_snapshot(agent_id, records, aggregate_taint) do
      {:ok, snapshot}
    else
      false -> {:error, :invalid_provenance}
      {:error, :invalid_provenance} -> {:error, :invalid_provenance}
      {:error, _reason} -> {:error, :store_unavailable}
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    :exit, _reason -> {:error, :store_unavailable}
    _, _ -> {:error, :invalid_provenance}
  end

  @doc "Validate an exact goal provenance snapshot without reading or mutating store state."
  @spec validate_goal_provenance_snapshot(String.t(), term()) ::
          :ok | {:error, :invalid_provenance}
  def validate_goal_provenance_snapshot(agent_id, snapshot) do
    with true <- valid_identifier?(agent_id),
         {:ok, _entries} <- decode_goal_provenance_snapshot(agent_id, snapshot) do
      :ok
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  @doc """
  Import an agent-bound goal snapshot using additive/upsert semantics.

  Empty snapshots are explicit no-ops, and goals absent from the snapshot remain
  unchanged. Full replacement requires an atomic durable batch primitive; this
  API does not emulate replacement with destructive clear-then-import behavior.
  """
  @spec import_goal_provenance_snapshot(String.t(), term()) ::
          :ok | {:error, persistence_mutation_error()}
  def import_goal_provenance_snapshot(agent_id, snapshot) do
    with true <- valid_identifier?(agent_id),
         {:ok, entries} <- decode_goal_provenance_snapshot(agent_id, snapshot) do
      case entries do
        [] -> :ok
        _ -> call_owner({:import_goals, agent_id, entries}, :mutation)
      end
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  @doc "Return true when a value declares or resembles the exact goal snapshot format."
  @spec goal_provenance_snapshot?(term()) :: boolean()
  def goal_provenance_snapshot?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(
      [
        "goal_store",
        "outer_envelope",
        "snapshot_kind",
        "snapshot_version",
        :goal_store,
        :outer_envelope,
        :snapshot_kind,
        :snapshot_version
      ],
      &Map.has_key?(value, &1)
    )
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def goal_provenance_snapshot?(_value), do: false

  @doc "Validate legacy or per-record goal import data without performing effects."
  @spec validate_goal_import(String.t(), term()) :: :ok | {:error, :invalid_provenance}
  def validate_goal_import(agent_id, goal_maps) do
    with true <- valid_identifier?(agent_id),
         :ok <- bounded_goal_snapshot_inventory(goal_maps),
         false <- Enum.any?(goal_maps, &ambiguous_import_goal_identifier?/1),
         {:ok, entries} <- prepare_import_goals(goal_maps),
         true <- length(entries) == length(goal_maps) do
      :ok
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  @doc """
  Import goals from serializable maps.

  Used by `Arbor.Agent.Seed.restore/2` to restore goal state.
  """
  @spec import_goals(String.t(), [map()]) ::
          :ok | {:error, persistence_mutation_error()}
  def import_goals(agent_id, goal_maps) do
    with true <- valid_identifier?(agent_id),
         :ok <- bounded_goal_snapshot_inventory(goal_maps),
         false <- Enum.any?(goal_maps, &ambiguous_import_goal_identifier?/1),
         {:ok, entries} <- prepare_import_goals(goal_maps) do
      case entries do
        [] -> :ok
        _ -> call_owner({:import_goals, agent_id, entries}, :mutation)
      end
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_table()
    {projected_ids, pending_convergence} = load_goals_from_authoritative_store()

    state = %{
      projected_ids: projected_ids,
      pending_convergence: pending_convergence,
      scheduled_convergence: MapSet.new(),
      # Agents whose content-only cleanup completed. Queued mark/converge
      # messages for these agents must no-op until new content is projected.
      content_cleaned: MapSet.new()
    }

    {:ok, schedule_pending_convergence(state)}
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
        {:reply, reply, clear_convergence_pending(state, agent_id)}

      {:error, _reason} = error ->
        {:reply, error, fail_agent_projection(state, agent_id)}

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

  def handle_call({:delete_agent_content, agent_id}, _from, state) do
    {reply, state} = do_delete_agent_content(agent_id, state)
    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :outcome_unknown}, state}
  catch
    _, _ -> {:reply, {:error, :outcome_unknown}, state}
  end

  def handle_call({:agent_content_absent?, agent_id}, _from, state) do
    reply = do_agent_content_absent?(agent_id, state)
    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:reload_for_agent, agent_id}, _from, state) do
    case do_reload_for_agent(agent_id) do
      {:reconciled, reply, goal_ids} ->
        {reply, state} = reconcile_projected_ids(reply, state, agent_id, goal_ids)
        {:reply, reply, clear_convergence_pending(state, agent_id)}

      {:error, _reason} = error ->
        {:reply, error, fail_agent_projection(state, agent_id)}

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
          state =
            state
            |> untrack_projected_id(agent_id, goal_id)
            |> mark_convergence_pending(agent_id)

          {:reply, error, state}

        {:error, _reason} = error ->
          {:reply, error, state}

        _ ->
          {:reply, {:error, :invalid_provenance}, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:mark_goal_convergence, agent_id}, state) do
    # Stale after content-only cleanup: do not re-arm convergence that would
    # hydrate via Provenance.delete_domain_agent and wipe retained sidecars.
    if content_cleaned?(state, agent_id) do
      {:noreply, state}
    else
      {:noreply, mark_convergence_pending(state, agent_id)}
    end
  end

  def handle_info({:converge_goal_agent, agent_id, attempts}, state) do
    state = clear_scheduled_convergence(state, agent_id)

    cond do
      content_cleaned?(state, agent_id) ->
        {:noreply, clear_convergence_pending(state, agent_id)}

      convergence_pending?(state, agent_id) ->
        case do_reload_for_agent(agent_id, false) do
          {:reconciled, :ok, goal_ids} ->
            {_reply, state} = reconcile_projected_ids(:ok, state, agent_id, goal_ids)
            {:noreply, clear_convergence_pending(state, agent_id)}

          _failure when attempts > 1 ->
            state =
              state
              |> fail_agent_projection(agent_id, false)
              |> schedule_convergence(agent_id, attempts - 1)

            {:noreply, state}

          _failure ->
            {:noreply, fail_agent_projection(state, agent_id, false)}
        end

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

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

  defp call_owner(message, mode \\ :read) when mode in [:read, :mutation] do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> call_live_owner(pid, message, mode)
      nil -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> owner_exit_result(mode)
    _, _ -> {:error, :store_unavailable}
  end

  defp call_live_owner(pid, message, mode) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _reason -> owner_exit_result(mode)
  end

  defp owner_exit_result(:mutation), do: {:error, :outcome_unknown}
  defp owner_exit_result(:read), do: {:error, :store_unavailable}

  defp compatibility_goal_list(agent_id, scope) when scope in [:active, :all] do
    case call_owner({:get_goal_list_tainted, agent_id, scope}) do
      {:ok, entries} when is_list(entries) -> unwrap_compatibility_goals(entries)
      _ -> []
    end
  end

  defp unwrap_compatibility_goals(entries) do
    Enum.reduce_while(entries, [], fn
      {%TaintedValue{value: %Goal{} = goal}, _status}, goals ->
        {:cont, [goal | goals]}

      _invalid, _goals ->
        {:halt, []}
    end)
    |> Enum.reverse()
  rescue
    _ -> []
  catch
    _, _ -> []
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
      {:ok, %Goal{} = goal, :projected} ->
        {{:ok, goal}, track_projected_id(state, agent_id, goal_id)}

      {:ok, %Goal{} = goal, :convergence_pending} ->
        state =
          state
          |> untrack_projected_id(agent_id, goal_id)
          |> mark_convergence_pending(agent_id)

        {{:ok, goal}, state}

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

  defp track_projected_id(state, agent_id, goal_id) do
    state = clear_content_cleaned(state, agent_id)
    projected_ids = Map.get(state, :projected_ids, %{})
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

    state =
      if MapSet.size(ids) == 0,
        do: state,
        else: clear_content_cleaned(state, agent_id)

    %{state | projected_ids: next}
  end

  defp content_cleaned?(state, agent_id) do
    case Map.get(state, :content_cleaned, MapSet.new()) do
      %MapSet{} = cleaned -> MapSet.member?(cleaned, agent_id)
      _ -> false
    end
  end

  defp mark_content_cleaned(state, agent_id) do
    cleaned =
      case Map.get(state, :content_cleaned, MapSet.new()) do
        %MapSet{} = set -> set
        _ -> MapSet.new()
      end

    Map.put(state, :content_cleaned, MapSet.put(cleaned, agent_id))
  end

  defp clear_content_cleaned(state, agent_id) do
    cleaned =
      case Map.get(state, :content_cleaned, MapSet.new()) do
        %MapSet{} = set -> set
        _ -> MapSet.new()
      end

    Map.put(state, :content_cleaned, MapSet.delete(cleaned, agent_id))
  end

  defp clear_projected_ids(%{projected_ids: projected_ids} = state, agent_id) do
    %{state | projected_ids: Map.delete(projected_ids, agent_id)}
  end

  defp fail_agent_projection(state, agent_id, rearm? \\ true) do
    projected_ids_for_agent(state, agent_id)
    |> Enum.each(&remove_live_goal(agent_id, &1, rearm?))

    state
    |> clear_projected_ids(agent_id)
    |> mark_convergence_pending(agent_id, rearm?)
  end

  defp mark_convergence_pending(state, agent_id, rearm? \\ true)

  defp mark_convergence_pending(%{pending_convergence: pending} = state, agent_id, rearm?) do
    cond do
      not valid_identifier?(agent_id) ->
        state

      true ->
        state = Map.put(state, :pending_convergence, MapSet.put(pending, agent_id))

        if rearm?,
          do: schedule_convergence(state, agent_id, @projection_convergence_attempts),
          else: state
    end
  end

  defp clear_convergence_pending(
         %{pending_convergence: pending, scheduled_convergence: scheduled} = state,
         agent_id
       ) do
    %{
      state
      | pending_convergence: MapSet.delete(pending, agent_id),
        scheduled_convergence: MapSet.delete(scheduled, agent_id)
    }
  end

  defp schedule_pending_convergence(%{pending_convergence: pending} = state) do
    Enum.reduce(pending, state, fn agent_id, state ->
      schedule_convergence(state, agent_id, @projection_convergence_attempts)
    end)
  end

  defp schedule_convergence(
         %{scheduled_convergence: scheduled} = state,
         agent_id,
         attempts
       )
       when is_integer(attempts) and attempts > 0 do
    if MapSet.member?(scheduled, agent_id) do
      state
    else
      _ =
        Process.send_after(
          self(),
          {:converge_goal_agent, agent_id, attempts},
          @projection_convergence_delay_ms
        )

      %{state | scheduled_convergence: MapSet.put(scheduled, agent_id)}
    end
  end

  defp schedule_convergence(state, _agent_id, _attempts), do: state

  defp clear_scheduled_convergence(%{scheduled_convergence: scheduled} = state, agent_id) do
    %{state | scheduled_convergence: MapSet.delete(scheduled, agent_id)}
  end

  defp convergence_pending?(%{pending_convergence: pending}, agent_id) do
    MapSet.member?(pending, agent_id)
  end

  defp request_goal_convergence(agent_id) do
    send(self(), {:mark_goal_convergence, agent_id})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_add_goal(agent_id, %Goal{} = goal, supplied_taint, enforce_limit?) do
    with {:ok, taint, existing?} <- join_existing_goal_taint(agent_id, goal.id, supplied_taint),
         :ok <- check_goal_limit(agent_id, existing?, enforce_limit?),
         {:ok, payload, taint} <- prepare_labeled_goal(goal, taint),
         {:ok, committed, projection_status} <-
           commit_labeled_goal(agent_id, goal, payload, taint, {:upsert, goal}) do
      emit_after_commit(fn -> Signals.emit_goal_created(agent_id, committed) end)
      Logger.debug("Goal added for #{agent_id}: #{committed.id}")
      {:ok, committed, projection_status}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
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
      call_owner({:mutate_goal, agent_id, goal_id, supplied_taint, operation}, :mutation)
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
         {:ok, updated, projection_status} <-
           commit_labeled_goal(
             agent_id,
             goal,
             payload,
             supplied_taint,
             {:mutate, operation}
           ) do
      emit_mutation_signal(agent_id, goal_id, operation)
      {:ok, updated, projection_status}
    else
      {:error, :not_found} = error -> error
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
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

  defp emit_mutation_signal(agent_id, goal_id, {:abandon, _reason}),
    do:
      emit_after_commit(fn ->
        Signals.emit_goal_abandoned(agent_id, goal_id, :abandoned)
      end)

  defp emit_mutation_signal(agent_id, goal_id, {:fail, _reason}),
    do:
      emit_after_commit(fn ->
        Signals.emit_goal_abandoned(agent_id, goal_id, :failed)
      end)

  defp emit_mutation_signal(agent_id, goal_id, {:block, _blockers}),
    do: emit_after_commit(fn -> Signals.emit_goal_abandoned(agent_id, goal_id, :blocked) end)

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
           commit_goal_record(agent_id, goal, payload, taint, transition) do
      projection_status =
        case install_live_goal(agent_id, committed_goal, committed_payload, committed_taint) do
          :ok -> :projected
          {:error, _reason} -> :convergence_pending
          _ -> :convergence_pending
        end

      queue_goal_embedding(agent_id, committed_goal, committed_taint)
      {:ok, committed_goal, projection_status}
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

      {:error, :outcome_unknown} ->
        {:error, :outcome_unknown}

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

      {:error, {:memory_store, :critical, :outcome_unknown}} ->
        {:error, :outcome_unknown}

      {:error, :outcome_unknown} ->
        {:error, :outcome_unknown}

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
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
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

  defp install_live_goal(agent_id, goal, payload, taint),
    do: install_live_goal(agent_id, goal, payload, taint, true)

  defp install_live_goal(
         agent_id,
         %Goal{} = goal,
         payload,
         %Taint{} = taint,
         request_convergence?
       ) do
    with :ok <- Provenance.put(:goal, agent_id, goal.id, payload, taint),
         {:ok, ^taint, :verified} <- Provenance.resolve(:goal, agent_id, goal.id, payload),
         :ok <- insert_live_goal(agent_id, goal) do
      :ok
    else
      _ -> fail_live_projection(agent_id, goal.id, request_convergence?)
    end
  rescue
    _ -> fail_live_projection(agent_id, goal.id, request_convergence?)
  catch
    _, _ -> fail_live_projection(agent_id, goal.id, request_convergence?)
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

  defp fail_live_projection(agent_id, goal_id, request_convergence? \\ true) do
    _ = remove_live_goal(agent_id, goal_id, request_convergence?)
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
         {:ok, entries} <- hydrate_authoritative_goal_records(agent_id, records) do
      selected =
        case scope do
          :active ->
            entries
            |> Enum.filter(fn {%TaintedValue{value: goal}, _status} -> goal.status == :active end)
            |> Enum.sort_by(fn {%TaintedValue{value: goal}, _status} -> goal.priority end, :desc)

          :all ->
            entries
        end

      {:reconciled, {:ok, selected}, projected_goal_ids(entries)}
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

  defp project_authoritative_goal(agent_id, goal_id, value, status),
    do: project_authoritative_goal(agent_id, goal_id, value, status, true)

  defp project_authoritative_goal(
         agent_id,
         goal_id,
         %TaintedValue{} = value,
         status,
         request_convergence?
       ) do
    case decode_authoritative_goal(goal_id, value, status) do
      {:ok, %Goal{} = goal, payload, taint, provenance_status} ->
        case install_live_goal(agent_id, goal, payload, taint, request_convergence?) do
          :ok -> {:ok, TaintedValue.wrap(goal, taint), provenance_status}
          {:error, _reason} = error -> error
          _ -> fail_live_projection(agent_id, goal_id, request_convergence?)
        end

      {:error, _reason} ->
        invalidate_live_goal(agent_id, goal_id, request_convergence?)
    end
  end

  defp project_authoritative_goal(
         agent_id,
         goal_id,
         _value,
         _status,
         request_convergence?
       ) do
    invalidate_live_goal(agent_id, goal_id, request_convergence?)
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
    with {:ok, records} <- load_authoritative_goal_records(nil),
         {:ok, grouped} <- group_authoritative_goal_records(records) do
      {projected_ids, pending, loaded} =
        Enum.reduce(grouped, {%{}, MapSet.new(), 0}, fn
          {agent_id, agent_records}, {projected_ids, pending, loaded} ->
            with :ok <- bounded_authoritative_records(agent_records),
                 {:ok, entries} <- hydrate_authoritative_goal_records(agent_id, agent_records),
                 {:ok, ids} <- bounded_projected_id_set(projected_goal_ids(entries)) do
              {
                Map.put(projected_ids, agent_id, ids),
                pending,
                loaded + MapSet.size(ids)
              }
            else
              _ -> {projected_ids, MapSet.put(pending, agent_id), loaded}
            end
        end)

      Logger.info("GoalStore: loaded #{loaded} goals from authoritative store")
      {projected_ids, pending}
    else
      _ -> {%{}, MapSet.new()}
    end
  rescue
    _ ->
      Logger.warning("GoalStore: failed to load goals from authoritative store")
      {%{}, MapSet.new()}
  catch
    _, _ ->
      Logger.warning("GoalStore: failed to load goals from authoritative store")
      {%{}, MapSet.new()}
  end

  defp group_authoritative_goal_records(records) when is_list(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn
      %{logical_key: key} = record, {:ok, grouped} ->
        case agent_and_goal_from_key(key) do
          {:ok, agent_id, _goal_id} ->
            {:cont, {:ok, Map.update(grouped, agent_id, [record], &[record | &1])}}

          _ ->
            {:halt, {:error, :invalid_provenance}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_provenance}}
    end)
  end

  defp group_authoritative_goal_records(_records), do: {:error, :invalid_provenance}

  defp remove_live_goal(agent_id, goal_id, request_convergence? \\ true) do
    _ = safe_ets_delete({agent_id, goal_id})

    case Provenance.delete(:goal, agent_id, goal_id) do
      :ok ->
        :ok

      _failure ->
        if request_convergence?, do: request_goal_convergence(agent_id)
        {:error, :projection_failed}
    end
  rescue
    _ ->
      if request_convergence?, do: request_goal_convergence(agent_id)
      {:error, :projection_failed}
  catch
    _, _ ->
      if request_convergence?, do: request_goal_convergence(agent_id)
      {:error, :projection_failed}
  end

  defp invalidate_live_goal(agent_id, goal_id, request_convergence? \\ true) do
    _ = remove_live_goal(agent_id, goal_id, request_convergence?)
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

  defp encode_goal_provenance_snapshot(agent_id, records, %Taint{} = aggregate_taint)
       when is_list(records) do
    payload = %{"agent_id" => agent_id, "goals" => records}

    with :ok <- bounded_goal_snapshot_inventory(records),
         {:ok, envelope} <- TaintEnvelope.new(payload, aggregate_taint),
         {:ok, outer_envelope} <- TaintEnvelope.to_map(envelope) do
      {:ok,
       %{
         "snapshot_kind" => @goal_snapshot_kind,
         "snapshot_version" => @goal_snapshot_version,
         "goal_store" => payload,
         "outer_envelope" => outer_envelope
       }}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp encode_goal_provenance_snapshot(_agent_id, _records, _aggregate_taint),
    do: {:error, :invalid_provenance}

  defp decode_goal_provenance_snapshot(agent_id, snapshot) do
    with true <- exact_string_keys?(snapshot, @goal_snapshot_keys),
         @goal_snapshot_kind <- snapshot["snapshot_kind"],
         @goal_snapshot_version <- snapshot["snapshot_version"],
         payload when is_map(payload) <- snapshot["goal_store"],
         true <- exact_string_keys?(payload, @goal_snapshot_payload_keys),
         ^agent_id <- payload["agent_id"],
         records = payload["goals"],
         :ok <- bounded_goal_snapshot_inventory(records),
         {:ok, outer_envelope} <- TaintEnvelope.verify(snapshot["outer_envelope"], payload),
         {:ok, entries} <- prepare_exact_goal_records(records),
         {:ok, aggregate_taint} <- goal_snapshot_aggregate_taint(entries),
         true <- outer_envelope.taint == aggregate_taint do
      {:ok, entries}
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp prepare_exact_goal_records(records) when is_list(records) do
    with :ok <- bounded_goal_snapshot_inventory(records) do
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, entries} ->
        with true <- exact_string_keys?(record, @seed_goal_record_keys),
             {:ok, entry} <- prepare_exact_goal_record(record) do
          {:cont, {:ok, [entry | entries]}}
        else
          _ -> {:halt, {:error, :invalid_provenance}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _reason} = error -> error
      end
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp prepare_exact_goal_records(_records), do: {:error, :invalid_provenance}

  defp prepare_exact_goal_record(record) do
    with @seed_goal_record_version <- record["version"],
         payload when is_map(payload) <- record["payload"],
         provenance when is_map(provenance) <- record["provenance"],
         {:ok, %Goal{} = goal} <- goal_from_map(payload),
         {:ok, canonical_payload} <- serialize_goal(goal),
         :ok <- equivalent_goal_payload(payload, canonical_payload),
         {:ok, envelope} <- TaintEnvelope.verify(provenance, payload),
         {:ok, ^canonical_payload, canonical_taint} <-
           prepare_labeled_goal(goal, envelope.taint) do
      {:ok, {goal, canonical_payload, canonical_taint}}
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp goal_snapshot_aggregate_taint([]), do: {:ok, TaintEnvelope.missing_fallback()}

  defp goal_snapshot_aggregate_taint(entries) when is_list(entries) do
    with :ok <- bounded_goal_snapshot_inventory(entries) do
      entries
      |> Enum.reduce_while({:ok, []}, fn
        {%TaintedValue{taint: %Taint{} = taint}, status}, {:ok, taints}
        when status in [:verified, :legacy_unlabeled, :invalid_durable_provenance] ->
          {:cont, {:ok, [taint | taints]}}

        {%Goal{}, _payload, %Taint{} = taint}, {:ok, taints} ->
          {:cont, {:ok, [taint | taints]}}

        _entry, _acc ->
          {:halt, {:error, :invalid_provenance}}
      end)
      |> case do
        {:ok, taints} -> taints |> Enum.reverse() |> Taint.join_many()
        {:error, _reason} = error -> error
      end
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp goal_snapshot_aggregate_taint(_entries), do: {:error, :invalid_provenance}

  defp exact_string_keys?(value, expected_keys)
       when is_map(value) and not is_struct(value) and is_list(expected_keys) do
    map_size(value) == length(expected_keys) and
      Enum.all?(expected_keys, &Map.has_key?(value, &1))
  end

  defp exact_string_keys?(_value, _expected_keys), do: false

  defp export_goal_records(entries) when is_list(entries) do
    with :ok <- bounded_goal_snapshot_inventory(entries) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, exported} ->
        case export_goal_record(entry) do
          {:ok, record} -> {:cont, {:ok, [record | exported]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, exported} -> {:ok, Enum.reverse(exported)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp export_goal_records(_entries), do: {:error, :invalid_provenance}

  defp export_goal_record({%TaintedValue{value: %Goal{} = goal, taint: %Taint{} = taint}, status})
       when status in [:verified, :legacy_unlabeled, :invalid_durable_provenance] do
    with {:ok, payload} <- serialize_goal(goal),
         {:ok, envelope} <- TaintEnvelope.new(payload, taint),
         {:ok, provenance} <- TaintEnvelope.to_map(envelope) do
      {:ok,
       %{
         "version" => @seed_goal_record_version,
         "payload" => payload,
         "provenance" => provenance
       }}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp export_goal_record(_entry), do: {:error, :invalid_provenance}

  defp prepare_import_goals(goal_maps) do
    with :ok <- bounded_goal_snapshot_inventory(goal_maps) do
      Enum.reduce_while(goal_maps, {:ok, []}, fn goal_map, {:ok, entries} ->
        case prepare_import_goal(goal_map) do
          {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
          :skip -> {:cont, {:ok, entries}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _reason} = error -> error
      end
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp prepare_import_goal(goal_map) when is_map(goal_map) do
    if seed_goal_record?(goal_map) do
      prepare_seed_goal_record(goal_map)
    else
      prepare_legacy_goal_record(goal_map)
    end
  end

  defp prepare_import_goal(_goal_map), do: :skip

  defp prepare_seed_goal_record(record) when is_map(record) and map_size(record) == 3 do
    with {:ok, @seed_goal_record_version} <- reserved_seed_value(record, "version", :version),
         {:ok, payload} <- reserved_seed_value(record, "payload", :payload),
         true <- is_map(payload),
         {:ok, provenance} <- reserved_seed_value(record, "provenance", :provenance),
         {:ok, %Goal{} = goal} <- goal_from_map(payload),
         {:ok, canonical_payload} <- serialize_goal(goal),
         :ok <- equivalent_goal_payload(payload, canonical_payload),
         {:ok, taint, _status} <- TaintEnvelope.resolve(provenance, payload),
         {:ok, ^canonical_payload, ^taint} <- prepare_labeled_goal(goal, taint) do
      {:ok, {goal, canonical_payload, taint}}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp prepare_seed_goal_record(_record), do: {:error, :invalid_provenance}

  defp prepare_legacy_goal_record(goal_map) do
    with {:ok, %Goal{} = goal} <- goal_from_map(goal_map),
         {:ok, payload, taint} <-
           prepare_labeled_goal(goal, TaintEnvelope.missing_fallback()) do
      {:ok, {goal, payload, taint}}
    else
      _ -> :skip
    end
  end

  defp equivalent_goal_payload(payload, canonical_payload) do
    with {:ok, payload_digest} <- TaintEnvelope.payload_sha256(payload),
         {:ok, canonical_digest} <- TaintEnvelope.payload_sha256(canonical_payload),
         true <- payload_digest == canonical_digest do
      :ok
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp seed_goal_record?(goal_map) do
    Enum.any?(
      ["version", "payload", "provenance", :version, :payload, :provenance],
      &Map.has_key?(goal_map, &1)
    )
  end

  defp reserved_seed_value(record, string_key, atom_key) do
    case {Map.fetch(record, string_key), Map.fetch(record, atom_key)} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      _ -> {:error, :invalid_provenance}
    end
  end

  defp ambiguous_import_goal_identifier?(goal_map) when is_map(goal_map) do
    payload = Map.get(goal_map, "payload", Map.get(goal_map, :payload, goal_map))

    Enum.any?([Map.get(payload, :id), Map.get(payload, "id")], fn
      value when is_binary(value) -> String.contains?(value, ":")
      _ -> false
    end)
  end

  defp ambiguous_import_goal_identifier?(_goal_map), do: false

  defp bounded_goal_snapshot_inventory(values) do
    with configured_limit when is_integer(configured_limit) and configured_limit > 0 <-
           goal_limit(),
         taint_limit when is_integer(taint_limit) and taint_limit > 0 <- Taint.max_join_inputs() do
      bounded_proper_list(values, min(configured_limit, taint_limit), 0)
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp bounded_proper_list([], _limit, _count), do: :ok

  defp bounded_proper_list([_value | rest], limit, count) when count < limit,
    do: bounded_proper_list(rest, limit, count + 1)

  defp bounded_proper_list(_values, _limit, _count), do: {:error, :invalid_provenance}

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
    _ -> {{:error, :outcome_unknown}, state}
  catch
    _, _ -> {{:error, :outcome_unknown}, state}
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
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
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
    _ -> {{:error, :outcome_unknown}, state}
  catch
    _, _ -> {{:error, :outcome_unknown}, state}
  end

  # Content-only C3I cleanup: durable first, then ETS + deferred state.
  # Never touches Provenance sidecars (unlike clear_goals/1).
  defp do_delete_agent_content(agent_id, state) do
    with true <- valid_identifier?(agent_id),
         {:ok, records} <- load_authoritative_goal_records(agent_id),
         :ok <- bounded_authoritative_records(records),
         {:ok, goal_ids} <- goal_ids_from_records(records, agent_id) do
      case delete_goal_content_records(agent_id, goal_ids, state) do
        {:ok, state} ->
          state = finalize_goal_content_clear(agent_id, state)
          {:ok, state}

        {{:error, _reason} = error, state} ->
          {error, state}

        _ ->
          {{:error, :persistence_failed}, state}
      end
    else
      false -> {{:error, :invalid_provenance}, state}
      {:error, _reason} = error -> {error, state}
      _ -> {{:error, :persistence_failed}, state}
    end
  rescue
    _ -> {{:error, :outcome_unknown}, state}
  catch
    _, _ -> {{:error, :outcome_unknown}, state}
  end

  defp do_agent_content_absent?(agent_id, state) do
    with true <- valid_identifier?(agent_id),
         {:ok, records} <- load_authoritative_goal_records(agent_id),
         :ok <- bounded_authoritative_records(records),
         {:ok, goal_ids} <- goal_ids_from_records(records, agent_id) do
      durable_absent? = goal_ids == []
      projected_absent? = MapSet.size(projected_ids_for_agent(state, agent_id)) == 0
      deferred_absent? = not convergence_pending?(state, agent_id)
      ets_absent? = exact_agent_ets_absent?(agent_id)

      if durable_absent? and projected_absent? and deferred_absent? and ets_absent? do
        {:ok, true}
      else
        {:ok, false}
      end
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

  defp delete_goal_content_records(_agent_id, [], state), do: {:ok, state}

  defp delete_goal_content_records(agent_id, [goal_id | rest], state) do
    case delete_goal_record(agent_id, goal_id) do
      :ok ->
        _ = safe_ets_delete({agent_id, goal_id})
        state = untrack_projected_id(state, agent_id, goal_id)
        delete_goal_content_records(agent_id, rest, state)

      {:error, _reason} = error ->
        # Conservative projection eviction; provenance intact; partial progress retryable.
        _ = safe_ets_delete({agent_id, goal_id})
        state = untrack_projected_id(state, agent_id, goal_id)
        {error, state}

      _ ->
        _ = safe_ets_delete({agent_id, goal_id})
        state = untrack_projected_id(state, agent_id, goal_id)
        {{:error, :persistence_failed}, state}
    end
  end

  defp delete_goal_content_records(_agent_id, _goal_ids, state),
    do: {{:error, :persistence_failed}, state}

  defp finalize_goal_content_clear(agent_id, state) do
    projected_ids_for_agent(state, agent_id)
    |> Enum.each(fn goal_id -> safe_ets_delete({agent_id, goal_id}) end)

    # Also sweep any orphan ETS rows for this exact agent_id.
    _ = sweep_exact_agent_ets(agent_id)

    state
    |> clear_projected_ids(agent_id)
    |> clear_convergence_pending(agent_id)
    |> mark_content_cleaned(agent_id)
  end

  defp exact_agent_ets_absent?(agent_id) do
    case :ets.match(@ets_table, {{agent_id, :"$1"}, :_}) do
      [] -> true
      _ -> false
    end
  rescue
    ArgumentError -> true
  catch
    _, _ -> false
  end

  defp sweep_exact_agent_ets(agent_id) do
    @ets_table
    |> :ets.match({{agent_id, :"$1"}, :_})
    |> Enum.each(fn [goal_id] -> safe_ets_delete({agent_id, goal_id}) end)

    :ok
  rescue
    ArgumentError -> :ok
  catch
    _, _ -> :ok
  end

  defp finalize_goal_clear(agent_id, state) do
    projected_ids_for_agent(state, agent_id)
    |> Enum.each(&remove_live_goal(agent_id, &1))

    state = clear_projected_ids(state, agent_id)

    emit_after_commit(fn ->
      Signals.emit_memory_signal(
        agent_id,
        :goals_cleared,
        %{status: :cleared},
        scope: :cluster
      )
    end)

    case Provenance.delete_domain_agent(:goal, agent_id) do
      :ok ->
        {:ok, clear_convergence_pending(state, agent_id)}

      _ ->
        {:ok, mark_convergence_pending(state, agent_id)}
    end
  end

  defp converge_deleted_goal(agent_id, goal_id) do
    _ = remove_live_goal(agent_id, goal_id)

    emit_after_commit(fn ->
      Signals.emit_memory_signal(
        agent_id,
        :goal_deleted,
        %{goal_id: goal_id, status: :deleted},
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

      {:error, {:memory_store, :critical, :outcome_unknown}} ->
        {:error, :outcome_unknown}

      {:error, :outcome_unknown} ->
        {:error, :outcome_unknown}

      {:error, {:memory_store, :critical, reason}}
      when reason in [:durable_unavailable, :insufficient_durability] ->
        {:error, :store_unavailable}

      {:error, _reason} ->
        {:error, :persistence_failed}

      _ ->
        {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
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

  defp do_reload_for_agent(agent_id, request_convergence? \\ true) do
    with true <- valid_identifier?(agent_id),
         {:ok, records} <- load_authoritative_goal_records(agent_id),
         :ok <- bounded_authoritative_records(records),
         {:ok, entries} <-
           hydrate_authoritative_goal_records(agent_id, records, request_convergence?) do
      {:reconciled, :ok, projected_goal_ids(entries)}
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

  defp hydrate_authoritative_goal_records(agent_id, records),
    do: hydrate_authoritative_goal_records(agent_id, records, true)

  defp hydrate_authoritative_goal_records(agent_id, records, request_convergence?)
       when is_list(records) do
    case Provenance.delete_domain_agent(:goal, agent_id) do
      :ok -> hydrate_swept_goal_records(agent_id, records, request_convergence?)
      _failure -> {:error, :projection_failed}
    end
  rescue
    _ -> {:error, :projection_failed}
  catch
    _, _ -> {:error, :projection_failed}
  end

  defp hydrate_authoritative_goal_records(_agent_id, _records, _request_convergence?),
    do: {:error, :invalid_provenance}

  defp hydrate_swept_goal_records(agent_id, records, request_convergence?) do
    case reconcile_authoritative_goal_records(agent_id, records, request_convergence?) do
      {:ok, entries, []} ->
        case verify_goal_provenance_inventory(agent_id, entries) do
          :ok ->
            {:ok, entries}

          {:error, _reason} = error ->
            evict_hydrated_goal_entries(agent_id, entries, error, request_convergence?)
        end

      {:ok, entries, errors} when is_list(errors) ->
        reason =
          if :projection_failed in errors, do: :projection_failed, else: :invalid_provenance

        evict_hydrated_goal_entries(
          agent_id,
          entries,
          {:error, reason},
          request_convergence?
        )

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :invalid_provenance}
    end
  end

  defp verify_goal_provenance_inventory(agent_id, entries) do
    expected_ids = entries |> projected_goal_ids() |> Enum.sort()

    case Provenance.list_item_ids(:goal, agent_id) do
      {:ok, actual_ids} when is_list(actual_ids) ->
        if Enum.sort(actual_ids) == expected_ids,
          do: :ok,
          else: {:error, :projection_failed}

      _ ->
        {:error, :projection_failed}
    end
  end

  defp evict_hydrated_goal_entries(agent_id, entries, error, request_convergence?) do
    _ = Provenance.delete_domain_agent(:goal, agent_id)

    Enum.each(entries, fn
      {%TaintedValue{value: %Goal{id: goal_id}}, _status} ->
        _ = remove_live_goal(agent_id, goal_id, request_convergence?)

      _ ->
        :ok
    end)

    error
  end

  defp reconcile_authoritative_goal_records(agent_id, records, request_convergence?)
       when is_list(records) do
    {entries, errors} =
      Enum.reduce(records, {[], []}, fn record, {entries, errors} ->
        case project_authoritative_goal_record(agent_id, record, request_convergence?) do
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

  defp reconcile_authoritative_goal_records(_agent_id, _records, _request_convergence?),
    do: {:error, :invalid_provenance}

  defp project_authoritative_goal_record(
         agent_id,
         %{logical_key: key, value: %TaintedValue{} = value, status: status},
         request_convergence?
       ) do
    with {:ok, ^agent_id, goal_id} <- agent_and_goal_from_key(key) do
      project_authoritative_goal(agent_id, goal_id, value, status, request_convergence?)
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp project_authoritative_goal_record(_agent_id, _record, _request_convergence?),
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
