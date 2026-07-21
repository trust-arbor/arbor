defmodule Arbor.Agent.Orchestration.TaskStore do
  @moduledoc """
  In-memory async task registry for the shared orchestration facade.

  The store owns task lifecycle state and result retention. It does not decide
  authorization; callers perform capability checks before dispatching or reading.

  ## Executor selection

  Before spawning work, the store selects an executor:

  * plain strings and legacy maps (`input` / `prompt` / `message` / `task`) use
    `Arbor.Agent.Config.default_task_executor/0` (validated before spawn)
  * structured maps with an explicit `kind` resolve a configured executor via
    `Arbor.Agent.Config` (fail closed on blank/unknown/invalid mappings)
  * per-dispatch `:runner` and store-start `:runner` overrides remain a
    test/internal compatibility seam and skip cross-library progress/cancel
    callbacks

  When there is no explicit runner override, **both** the configured default
  path and the explicit-kind path use the JSON-clean boundary: plain string
  tasks remain strings, maps are string-keyed JSON, and only `task_id` /
  `timeout` / `caller_id` / `metadata` are forwarded. Private TaskStore
  options never cross that boundary. Trusted explicit runner overrides may
  still receive full keyword opts. Non-JSON values, structs, PIDs, functions,
  references, unsupported atoms, and conflicting kind declarations fail before
  any task process starts.

  Optional `task_status/2`, `cancel_task/2`, and `steer_task/3` callbacks are best-effort and
  time-bounded under the task supervisor (see Config
  `executor_callback_timeout_ms/0`); hung callbacks are killed and status falls
  back to the stored view while cancel continues with the turn bridge + hard kill.
  An opted-in `finalize_task/4` callback is different: TaskStore calls it after
  terminal steering reconciliation but before publishing success, and failure or
  timeout fails the outer task so required evidence is never silently omitted.
  """

  use GenServer

  @default_name __MODULE__
  @default_task_supervisor Arbor.Agent.Orchestration.TaskSupervisor
  @default_runner Arbor.Agent.Orchestration.TaskRunner
  @default_approval_cleanup_mfa {Arbor.Agent.Orchestration, :cleanup_approvals_for_task, 2}
  @default_approval_cleanup_consensus Arbor.Consensus
  # Avoid a hard compile-time dep edge on arbor_comms; call only its public facade.
  @default_approval_cleanup_interaction_router Module.concat([:Arbor, :Comms])
  @default_approval_cleanup_audit Arbor.Security
  @default_max_tasks 1_000
  @default_steer_retry_delay_ms 100
  @default_max_steer_retry_delay_ms 5_000
  @default_max_controls_per_task 100
  @default_max_steer_retries 7
  @default_max_steering_confirmations 5
  @default_max_steering_replays 3
  @max_steering_message_bytes 4_000

  alias Arbor.Agent.Config
  alias Arbor.Agent.Orchestration.TaskArtifacts

  @type task_id :: String.t()
  # :waiting_approval is retained for status projection / facade enrichment
  # (Orchestration.task_status/2 still surfaces it for running tasks with a
  # pending approval). Ownerless runner pending-approval results fail closed to
  # :failed — they must not leave a terminal task stuck waiting.
  @type state_name :: :running | :waiting_approval | :done | :failed | :cancelled

  @type task_status :: %{
          task_id: task_id(),
          agent_id: String.t(),
          state: state_name(),
          current_step: String.t() | nil,
          waiting_on: String.t() | nil,
          started_at: DateTime.t(),
          updated_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          metadata: map(),
          steering: map()
        }

  @type task_result ::
          {:ok, map()}
          | {:error,
             :not_found
             | :not_ready
             | :cancelled
             | {:waiting_approval, String.t()}
             | {:failed, term()}}

  @type steering_control :: %{required(String.t()) => term()}

  @doc false
  def start_link(opts \\ []) do
    # Validate store-start cleanup MFA in the caller before linking a child,
    # so bad shapes raise ArgumentError at the init boundary (not only as a
    # linked GenServer exit reason).
    _ =
      opts
      |> Keyword.get(:approval_cleanup_mfa, @default_approval_cleanup_mfa)
      |> validate_approval_cleanup_mfa!()

    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Dispatch an async task.

  Options:

    * `:name` - task store process name, for tests
    * `:runner` - module implementing `run/3` (test/internal override)
    * `:task_id` - explicit id, for deterministic tests
    * `:metadata` - caller metadata copied into the task record
    * `:timeout` - optional timeout forwarded in JSON-clean executor context
    * `:caller_id` - optional caller id forwarded in JSON-clean executor context
    * `:approval_answer_cap_id` - private temporary approval-answer capability id
    * `:approval_cleanup_descriptor` - private closed scalar lifecycle cleanup
      descriptor only (`caller_id` and optional `trace_id`). Executable
      selectors (MFA, modules, functions, PIDs) are stripped on store and never
      retained. Cleanup MFA, Consensus/Comms/Audit modules, and the
      cleanup supervisor are pinned at TaskStore init (production defaults:
      `Orchestration.cleanup_approvals_for_task/2`, real backends, normal task
      supervisor). Tests may override those only at store start.
  """
  @spec dispatch(String.t(), term(), keyword() | map()) :: {:ok, task_id()} | {:error, term()}
  def dispatch(agent_id, task, opts \\ []) do
    GenServer.call(store_name(opts), {:dispatch, agent_id, task, normalize_opts(opts)})
  end

  @doc "Return current task status."
  @spec status(task_id(), keyword() | map()) :: {:ok, task_status()} | {:error, :not_found}
  def status(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:status, task_id})
  end

  @doc "Return the completed task result."
  @spec result(task_id(), keyword() | map()) :: task_result()
  def result(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:result, task_id})
  end

  @doc "Cancel a running task."
  @spec cancel(task_id(), keyword() | map()) :: {:ok, task_status()} | {:error, term()}
  def cancel(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:cancel, task_id})
  end

  @doc false
  @spec cancel_owns_approval_cleanup?() :: true
  def cancel_owns_approval_cleanup?, do: true

  @doc """
  Persist and attempt delivery of a steering message for one task.

  The returned control is JSON-clean and has a stable `control_id` and
  monotonically increasing per-task `sequence`. Operational delivery failures
  return `"deferred"` and are retried by the store; accepted (`{:ok, :queued,
  mode}`) controls are later **confirmed** by calling `steer_task/3` again
  with the same control (stable `control_id` and immutable steering payload;
  bookkeeping fields such as `status`/`error`/`delivered_at` may differ).
  Only explicit delivered confirmation sets `delivered_at`. Positive
  `:not_delivered` during confirmation clears accepted ownership and
  triggers a bounded same-ID replay; `:delivery_unknown`/`:cancelled`
  terminalize immediately as `"delivery_unconfirmed"` whether returned during
  initial delivery, confirmation, or replay. If a task fails or is cancelled
  before an accepted control is confirmed delivered, the control enters the
  terminal `"delivery_unconfirmed"` state. Initial delivery, confirmation,
  and replay budgets are independent; FIFO ordering is enforced by the store.

  ## Hot-state upgrade compatibility

  A TaskStore process whose code was hot-loaded while tasks with accepted
  queued controls were in flight holds records that predate the
  confirmation/replay machinery. The store lazily normalizes such records at
  the delivery/confirmation/terminal-reconciliation boundary: missing
  bookkeeping maps are materialized as empty, and legacy accepted queued
  controls are terminalized as `"delivery_unconfirmed"` with the bounded
  diagnostic `"legacy_upgrade_unconfirmed"` so they cannot block FIFO or
  manufacture delivery.
  """
  @spec steer(task_id(), String.t(), keyword() | map()) ::
          {:ok, steering_control()} | {:error, term()}
  def steer(task_id, message, opts \\ []) do
    GenServer.call(store_name(opts), {:steer, task_id, message, normalize_opts(opts)})
  end

  @impl true
  def init(opts) do
    approval_cleanup_mfa =
      opts
      |> Keyword.get(:approval_cleanup_mfa, @default_approval_cleanup_mfa)
      |> validate_approval_cleanup_mfa!()

    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    # Optional separate supervisor for cleanup scheduling (tests may suspend it).
    # Production default is the same normal task supervisor.
    cleanup_supervisor = Keyword.get(opts, :cleanup_supervisor, task_supervisor)

    {:ok,
     %{
       task_supervisor: task_supervisor,
       cleanup_supervisor: cleanup_supervisor,
       runner: Keyword.get(opts, :runner, @default_runner),
       # When true, store-level `:runner` overrides kind-based Config selection.
       runner_override: Keyword.has_key?(opts, :runner),
       # Trusted cleanup selectors fixed at store start (not per-dispatch).
       # Tests may override; never accepted via dispatch opts/descriptor.
       approval_cleanup_mfa: approval_cleanup_mfa,
       approval_cleanup_consensus_module:
         Keyword.get(
           opts,
           :approval_cleanup_consensus_module,
           @default_approval_cleanup_consensus
         ),
       approval_cleanup_interaction_router:
         Keyword.get(
           opts,
           :approval_cleanup_interaction_router,
           @default_approval_cleanup_interaction_router
         ),
       approval_cleanup_audit_module:
         Keyword.get(opts, :approval_cleanup_audit_module, @default_approval_cleanup_audit),
       max_tasks: Keyword.get(opts, :max_tasks, @default_max_tasks),
       executor_callback_timeout_ms:
         Keyword.get(opts, :executor_callback_timeout_ms, Config.executor_callback_timeout_ms()),
       executor_finalization_timeout_ms:
         Keyword.get(
           opts,
           :executor_finalization_timeout_ms,
           Config.executor_finalization_timeout_ms()
         ),
       steer_retry_delay_ms:
         Keyword.get(opts, :steer_retry_delay_ms, @default_steer_retry_delay_ms),
       max_steer_retry_delay_ms:
         Keyword.get(opts, :max_steer_retry_delay_ms, @default_max_steer_retry_delay_ms),
       max_controls_per_task:
         Keyword.get(opts, :max_controls_per_task, @default_max_controls_per_task),
       max_steer_retries: Keyword.get(opts, :max_steer_retries, @default_max_steer_retries),
       max_steering_confirmations:
         Keyword.get(
           opts,
           :max_steering_confirmations,
           @default_max_steering_confirmations
         ),
       max_steering_replays:
         Keyword.get(opts, :max_steering_replays, @default_max_steering_replays),
       steer_confirmation_delay_ms:
         Keyword.get(
           opts,
           :steer_confirmation_delay_ms,
           Keyword.get(opts, :steer_retry_delay_ms, @default_steer_retry_delay_ms)
         ),
       # Arity-2: (agent_id, task_id) — task-scoped Session cancel bridge.
       cancel_turn: Keyword.get(opts, :cancel_turn, &default_cancel_turn/2),
       tasks: %{},
       refs: %{}
     }}
  end

  @impl true
  def handle_call({:dispatch, agent_id, task, opts}, _from, state) do
    task_id = task_id(opts)

    case prepare_dispatch(task, opts, state, task_id) do
      {:ok, runner, context_mode, dispatch_task, runner_context} ->
        now = DateTime.utc_now()

        task_ref =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            runner.run(agent_id, dispatch_task, runner_context)
          end)

        record = %{
          task_id: task_id,
          agent_id: agent_id,
          task: dispatch_task,
          state: :running,
          current_step: "running",
          waiting_on: nil,
          result: nil,
          error: nil,
          pid: task_ref.pid,
          ref: task_ref.ref,
          started_at: now,
          updated_at: now,
          completed_at: nil,
          metadata: metadata(opts),
          executor: runner,
          context_mode: context_mode,
          context: runner_context,
          approval_answer_cap_id: Keyword.get(opts, :approval_answer_cap_id),
          approval_answer_security_module:
            Keyword.get(opts, :approval_answer_security_module, Arbor.Security),
          approval_answer_revoke: Keyword.get(opts, :approval_answer_revoke),
          steer_cap_id: Keyword.get(opts, :steer_cap_id),
          steer_security_module: Keyword.get(opts, :steer_security_module, Arbor.Security),
          steer_capability_revoke: Keyword.get(opts, :steer_capability_revoke),
          # Closed scalar only — executable keys are never retained on the record.
          approval_cleanup_descriptor:
            normalize_approval_cleanup_descriptor(Keyword.get(opts, :approval_cleanup_descriptor)),
          controls: [],
          control_retries: %{},
          accepted_control_ids: MapSet.new(),
          confirmation_retries: %{},
          replay_counts: %{},
          cancel_turn: Keyword.get(opts, :cancel_turn)
        }

        next_state =
          state
          |> put_in([:tasks, task_id], record)
          |> put_in([:refs, task_ref.ref], task_id)
          |> prune_tasks()

        {:reply, {:ok, task_id}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    e ->
      {:reply, {:error, {:dispatch_failed, Exception.message(e)}}, state}
  catch
    :exit, reason ->
      {:reply, {:error, {:dispatch_exit, reason}}, state}
  end

  def handle_call({:status, task_id}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        {:reply, {:ok, project_status(record, state)}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:result, task_id}, _from, state) do
    reply =
      case Map.fetch(state.tasks, task_id) do
        {:ok, %{state: :done, result: result}} ->
          {:ok, result}

        {:ok, %{state: :failed, error: error}} ->
          {:error, {:failed, error}}

        {:ok, %{state: :cancelled}} ->
          {:error, :cancelled}

        {:ok, %{state: :waiting_approval, waiting_on: approval_id}} ->
          {:error, {:waiting_approval, approval_id}}

        {:ok, _record} ->
          {:error, :not_ready}

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel, task_id}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, %{state: :running} = record} ->
        now = DateTime.utc_now()

        # Configured executors: cooperative cancel_task/2 first (bounded best-effort).
        maybe_cancel_executor(record, state)

        # Root cleanup: cancel the agent turn *before* killing the TaskRunner
        # wrapper. The real work lives in Orchestrator.Session (and ACP/worktree
        # owners under that turn). Process.exit(..., :kill) skips try/after, so
        # propagation must happen from this surviving store process.
        cancel_active_turn(record, state)

        if is_pid(record.pid) and Process.alive?(record.pid) do
          Process.exit(record.pid, :kill)
        end

        # Consume before scheduling so a late :DOWN cannot double-clean.
        {record, descriptor} = take_approval_cleanup_descriptor(record)

        cancelled_record =
          record
          |> Map.merge(%{
            state: :cancelled,
            current_step: "cancelled",
            waiting_on: nil,
            error: nil,
            updated_at: now,
            completed_at: now
          })
          |> reconcile_terminal_controls()
          |> revoke_task_capabilities()

        next_state =
          state
          |> put_in([:tasks, task_id], cancelled_record)
          |> remove_ref(record.ref)

        next_state =
          launch_approval_cleanup_job(
            next_state,
            cleanup_job(task_id, descriptor, :task_cancellation)
          )

        {:reply, {:ok, status_view(cancelled_record)}, next_state}

      {:ok, record} ->
        {:reply, {:error, {:not_running, record.state}}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:steer, task_id, message, opts}, _from, state) do
    state = ensure_task_record_shape(state, task_id)

    with {:ok, message} <- validate_steering_message(message),
         {:ok, record} <- Map.fetch(state.tasks, task_id),
         :ok <- ensure_control_capacity(record, state) do
      control = new_control(record, message, opts)
      state = put_control(state, task_id, control)
      emit_control_transition(record, control, "queued")
      state = maybe_deliver_new_control(state, task_id, control["control_id"])

      {:reply, {:ok, fetch_control!(state, task_id, control["control_id"])}, state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.fetch(state.refs, ref) do
      {:ok, task_id} ->
        {:noreply, complete_task(state, task_id, ref, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) when is_reference(ref) do
    {:noreply, remove_ref(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.fetch(state.refs, ref) do
      {:ok, task_id} ->
        now = DateTime.utc_now()
        {state, cleanup_job} = terminalize_abnormal_down(state, task_id, reason, now)
        state = launch_approval_cleanup_job(state, cleanup_job)
        {:noreply, remove_ref(state, ref)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_steer, task_id, control_id}, state) do
    state = ensure_task_record_shape(state, task_id)
    state = deliver_control(state, task_id, control_id)
    {:noreply, advance_confirmation_after_delivery(state, task_id, control_id)}
  end

  def handle_info({:confirm_steer, task_id, control_id}, state) do
    state = ensure_task_record_shape(state, task_id)
    {:noreply, confirm_control(state, task_id, control_id)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp complete_task(state, task_id, ref, result) do
    now = DateTime.utc_now()
    {state, cleanup_job} = terminalize_completion(state, task_id, result, now)
    state = launch_approval_cleanup_job(state, cleanup_job)
    remove_ref(state, ref)
  end

  # Finalize opted-in successful results before publishing the terminal record;
  # return optional approval cleanup for a later mailbox drain.
  defp terminalize_completion(state, task_id, result, now) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        if record.state == :cancelled do
          {state, nil}
        else
          # Consume before enqueue so a late :DOWN cannot double-clean.
          {record, descriptor} = take_approval_cleanup_descriptor(record)

          record =
            record
            |> Map.merge(completion_fields(result, now))
            |> Map.put(:updated_at, now)
            |> maybe_reconcile_terminal_controls()
            |> maybe_revoke_completed_task_capabilities()
            |> maybe_finalize_task_result(result, state)

          {put_in(state.tasks[task_id], record),
           cleanup_job(task_id, descriptor, :task_termination)}
        end

      :error ->
        {state, nil}
    end
  end

  defp terminalize_abnormal_down(state, task_id, reason, now) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        cond do
          record.state in [:done, :failed, :cancelled] ->
            # Result path already terminalized; consume any leftover descriptor
            # without rescheduling (exactly-once).
            {record, _descriptor} = take_approval_cleanup_descriptor(record)
            {put_in(state.tasks[task_id], record), nil}

          true ->
            {record, descriptor} = take_approval_cleanup_descriptor(record)

            record =
              record
              |> Map.merge(%{
                state: :failed,
                current_step: "failed",
                waiting_on: nil,
                error: reason,
                updated_at: now,
                completed_at: now
              })
              |> reconcile_terminal_controls()
              |> revoke_task_capabilities()

            {put_in(state.tasks[task_id], record),
             cleanup_job(task_id, descriptor, :task_termination)}
        end

      :error ->
        {state, nil}
    end
  end

  defp cleanup_job(task_id, descriptor, reason) when is_map(descriptor),
    do: {task_id, descriptor, reason}

  defp cleanup_job(_task_id, nil, _reason), do: nil

  defp launch_approval_cleanup_job(state, nil), do: state

  defp launch_approval_cleanup_job(state, {task_id, descriptor, reason}) do
    # The terminal record is already present in `state`. This call only performs
    # a named external spawn; the potentially blocking supervisor call happens
    # in that launcher, never in TaskStore and never through a forgeable mailbox job.
    launch_approval_cleanup(state, task_id, descriptor, reason)
    state
  end

  # A runner that returns pending-approval has already terminated; never leave
  # an ownerless task stuck in :waiting_approval.
  defp completion_fields({:ok, :pending_approval, approval_id}, now)
       when is_binary(approval_id) do
    %{
      state: :failed,
      current_step: "failed",
      waiting_on: nil,
      error: {:approval_owner_terminated, approval_id},
      completed_at: now
    }
  end

  defp completion_fields({:error, {:pending_approval, approval_id}}, now)
       when is_binary(approval_id) do
    %{
      state: :failed,
      current_step: "failed",
      waiting_on: nil,
      error: {:approval_owner_terminated, approval_id},
      completed_at: now
    }
  end

  defp completion_fields({:ok, result}, now) do
    %{
      state: :done,
      current_step: "done",
      waiting_on: nil,
      result: normalize_result(result),
      completed_at: now
    }
  end

  defp completion_fields({:error, reason}, now) do
    %{
      state: :failed,
      current_step: "failed",
      waiting_on: nil,
      error: reason,
      completed_at: now
    }
  end

  defp completion_fields(result, now) do
    %{
      state: :done,
      current_step: "done",
      waiting_on: nil,
      result: normalize_result(result),
      completed_at: now
    }
  end

  defp normalize_result(result), do: TaskArtifacts.normalize(result)

  defp maybe_revoke_completed_task_capabilities(%{state: state} = record)
       when state in [:done, :failed, :cancelled] do
    revoke_task_capabilities(record)
  end

  defp maybe_revoke_completed_task_capabilities(record), do: record

  defp take_approval_cleanup_descriptor(record) do
    case Map.get(record, :approval_cleanup_descriptor) do
      nil ->
        {record, nil}

      descriptor ->
        {Map.put(record, :approval_cleanup_descriptor, nil), descriptor}
    end
  end

  # Closed scalar shape only. Drops MFA/module/function/fun/PID/unknown keys so
  # direct dispatch can neither select nor retain executable cleanup values.
  defp normalize_approval_cleanup_descriptor(nil), do: nil

  defp normalize_approval_cleanup_descriptor(descriptor) when is_map(descriptor) do
    %{}
    |> maybe_put_scalar_id(:caller_id, descriptor_get(descriptor, :caller_id))
    |> maybe_put_scalar_id(:trace_id, descriptor_get(descriptor, :trace_id))
    |> case do
      empty when map_size(empty) == 0 -> nil
      closed -> closed
    end
  end

  defp normalize_approval_cleanup_descriptor(_invalid), do: nil

  defp descriptor_get(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp maybe_put_scalar_id(map, _key, value)
       when not is_binary(value) or value == "",
       do: map

  defp maybe_put_scalar_id(map, key, value) when is_binary(value), do: Map.put(map, key, value)

  # Best-effort lifecycle cleanup. Failures never affect terminal state.
  # Entrypoint + backends + supervisor are store-init only; descriptor is
  # closed scalar data (never code selection).
  defp launch_approval_cleanup(_state, _task_id, nil, _reason), do: :ok

  defp launch_approval_cleanup(state, task_id, descriptor, reason) when is_map(descriptor) do
    # Live code loading does not migrate an already-running GenServer map. Fall
    # back to production defaults so pre-feature TaskStore state terminalizes
    # safely without a process restart.
    supervisor =
      Map.get(
        state,
        :cleanup_supervisor,
        Map.get(state, :task_supervisor, @default_task_supervisor)
      )

    mfa = Map.get(state, :approval_cleanup_mfa, @default_approval_cleanup_mfa)
    cleanup_opts = cleanup_opts_from_state(state, descriptor, reason)

    # Named external launcher (MFA spawn, no anonymous closure). Runs outside
    # the TaskStore process so Task.Supervisor.start_child/5 on an unresponsive
    # cleanup supervisor cannot block status/result availability.
    _ = spawn(__MODULE__, :start_approval_cleanup_child, [supervisor, mfa, task_id, cleanup_opts])
    :ok
  end

  defp launch_approval_cleanup(_state, _task_id, _descriptor, _reason), do: :ok

  @doc false
  def start_approval_cleanup_child(supervisor, {module, function, 2}, task_id, cleanup_opts)
      when is_atom(module) and is_atom(function) do
    _ =
      Task.Supervisor.start_child(
        supervisor,
        module,
        function,
        [task_id, cleanup_opts],
        []
      )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def start_approval_cleanup_child(_supervisor, _mfa, _task_id, _cleanup_opts), do: :ok

  defp validate_approval_cleanup_mfa!({module, function, 2})
       when is_atom(module) and is_atom(function) do
    {module, function, 2}
  end

  defp validate_approval_cleanup_mfa!(invalid) do
    raise ArgumentError,
          "approval_cleanup_mfa must be {module, function, 2}, got: #{inspect(invalid)}"
  end

  defp cleanup_opts_from_state(state, descriptor, reason) when is_map(descriptor) do
    [
      caller_id: Map.get(descriptor, :caller_id),
      consensus_module:
        Map.get(
          state,
          :approval_cleanup_consensus_module,
          @default_approval_cleanup_consensus
        ),
      interaction_router:
        Map.get(
          state,
          :approval_cleanup_interaction_router,
          @default_approval_cleanup_interaction_router
        ),
      audit_module:
        Map.get(state, :approval_cleanup_audit_module, @default_approval_cleanup_audit),
      trace_id: Map.get(descriptor, :trace_id),
      cleanup_reason: reason
    ]
  end

  # ---------------------------------------------------------------------------
  # Steering mailbox
  # ---------------------------------------------------------------------------

  defp validate_steering_message(message) when is_binary(message) do
    cond do
      not String.valid?(message) -> {:error, :invalid_steering_message}
      String.trim(message) == "" -> {:error, :empty_steering_message}
      byte_size(message) > @max_steering_message_bytes -> {:error, :steering_message_too_large}
      true -> {:ok, message}
    end
  end

  defp validate_steering_message(_message), do: {:error, :invalid_steering_message}

  defp ensure_control_capacity(record, state) do
    if length(record.controls) < state.max_controls_per_task do
      :ok
    else
      {:error, :too_many_steering_controls}
    end
  end

  # Fail-closed lazy normalization for running task records hot-loaded from a
  # pre-upgrade code revision. A TaskStore process whose code was replaced
  # while tasks were in flight can hold records created by the old code, which
  # lack :confirmation_retries / :replay_counts (and in older revisions,
  # :accepted_control_ids / :control_retries / :controls). The first
  # post-upgrade delivery/confirmation/terminal-reconciliation work would
  # crash on the missing keys (KeyError / BadMapError). This materializes the
  # maps with empty defaults so FIFO and budgets are not weakened, and
  # terminalizes any legacy accepted queued controls as delivery_unconfirmed
  # with a bounded explicit diagnostic so they cannot block later controls
  # indefinitely or manufacture a delivery ACK.
  defp ensure_task_record_shape(state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        normalized = ensure_record_shape(record)

        if normalized == record do
          state
        else
          put_in(state.tasks[task_id], normalized)
        end

      :error ->
        state
    end
  end

  defp ensure_record_shape(record) do
    pre_upgrade = not Map.has_key?(record, :confirmation_retries)

    record =
      record
      |> Map.put_new(:controls, [])
      |> Map.put_new(:control_retries, %{})
      |> Map.put_new(:accepted_control_ids, MapSet.new())
      |> Map.put_new(:confirmation_retries, %{})
      |> Map.put_new(:replay_counts, %{})

    if pre_upgrade and record.state == :running do
      terminalize_legacy_accepted_controls(record)
    else
      record
    end
  end

  defp terminalize_legacy_accepted_controls(record) do
    accepted_ids = record.accepted_control_ids

    if MapSet.size(accepted_ids) == 0 do
      record
    else
      controls =
        Enum.map(record.controls, fn control ->
          if MapSet.member?(accepted_ids, control["control_id"]) and
               control["status"] == "queued" do
            transition_terminal_control(record, control, %{
              "status" => "delivery_unconfirmed",
              "delivered_at" => nil,
              "error" => "legacy_upgrade_unconfirmed"
            })
          else
            control
          end
        end)

      %{record | controls: controls, accepted_control_ids: MapSet.new()}
    end
  end

  defp new_control(record, message, opts) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    sequence = length(record.controls) + 1

    %{
      "control_id" =>
        "control_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      "task_id" => record.task_id,
      "sequence" => sequence,
      "status" => "queued",
      "sender_id" => Keyword.get(opts, :sender_id),
      "message" => message,
      "queued_at" => now,
      "delivered_at" => nil,
      "target_stage" => normalize_target_stage(Keyword.get(opts, :target_stage)),
      "delivery_mode" => nil,
      "error" => nil
    }
  end

  defp normalize_target_stage(stage) when is_binary(stage) and byte_size(stage) <= 200 do
    if String.valid?(stage), do: stage, else: nil
  end

  defp normalize_target_stage(_stage), do: nil

  defp put_control(state, task_id, control) do
    update_in(state.tasks[task_id], fn record ->
      record
      |> Map.update!(:controls, &(&1 ++ [control]))
      |> Map.update!(:control_retries, &Map.put_new(&1, control["control_id"], 0))
    end)
  end

  defp fetch_control!(state, task_id, control_id) do
    state.tasks
    |> Map.fetch!(task_id)
    |> Map.fetch!(:controls)
    |> Enum.find(&(&1["control_id"] == control_id))
  end

  defp deliver_control(state, task_id, control_id) do
    with {:ok, record} <- Map.fetch(state.tasks, task_id),
         control when not is_nil(control) <- find_control(record, control_id),
         true <- deliverable_control?(record, control),
         true <- first_pending_control(record) == control_id do
      if record.state in [:done, :failed, :cancelled] do
        update_control(state, task_id, control_id, fn control ->
          control
          |> Map.put("status", "unsupported")
          |> Map.put("error", "task_terminal")
        end)
      else
        apply_control_delivery(state, record, control)
      end
    else
      _ -> state
    end
  end

  defp maybe_deliver_new_control(state, task_id, control_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        if first_pending_control(record) == control_id do
          deliver_control(state, task_id, control_id)
        else
          state
        end

      _ ->
        state
    end
  end

  defp apply_control_delivery(state, record, control) do
    result =
      if record.context_mode == :json_clean and is_map(record.context) and
           is_atom(record.executor) and Code.ensure_loaded?(record.executor) and
           function_exported?(record.executor, :steer_task, 3) do
        call_executor_callback(state, fn ->
          record.executor.steer_task(record.agent_id, control, record.context)
        end)
      else
        {:error, :unsupported}
      end

    case normalize_steering_delivery(result) do
      {:accepted, "delivered", mode} ->
        state
        |> accept_control(record.task_id, control["control_id"], "delivered", mode)
        |> advance_mailbox(record.task_id)

      {:accepted, "queued", mode} ->
        state
        |> accept_control(record.task_id, control["control_id"], "queued", mode)
        |> maybe_schedule_confirmation(record.task_id, control["control_id"])
        |> advance_mailbox(record.task_id)

      :unsupported ->
        state
        |> update_control(record.task_id, control["control_id"], fn value ->
          value |> Map.put("status", "unsupported") |> Map.put("error", "executor_unsupported")
        end)
        |> advance_mailbox(record.task_id)

      {:terminalize, error} ->
        state
        |> terminalize_as_unconfirmed(record.task_id, control["control_id"], error)
        |> advance_mailbox(record.task_id)

      {:deferred, error} ->
        defer_control(state, record.task_id, control["control_id"], error)
    end
  end

  @delivery_modes [:native_tool_loop, :acp_native, :same_session_follow_up, :next_stage]

  defp normalize_steering_delivery({:ok, mode})
       when mode in @delivery_modes,
       do: {:accepted, "delivered", mode}

  defp normalize_steering_delivery({:ok, :queued, mode})
       when mode in @delivery_modes,
       do: {:accepted, "queued", mode}

  defp normalize_steering_delivery({:error, :unsupported}), do: :unsupported
  defp normalize_steering_delivery(:unsupported), do: :unsupported

  # :not_delivered is a retryable operational failure during initial delivery
  # (and replay delivery, which uses the same path): the executor positively
  # asserts the control was not delivered, so retrying is safe.
  defp normalize_steering_delivery({:error, :not_delivered}),
    do: {:deferred, "not_delivered"}

  # :delivery_unknown and :cancelled are unsafe to retry or replay: the
  # executor may have already acted or explicitly halted, so re-delivery
  # risks duplicates or contradicts an explicit stop. Terminalize immediately
  # as delivery_unconfirmed with a bounded diagnostic error. Only explicit
  # :not_delivered may enter the confirmation/retry path.
  defp normalize_steering_delivery({:error, :delivery_unknown}),
    do: {:terminalize, "delivery_unknown"}

  defp normalize_steering_delivery({:error, :cancelled}),
    do: {:terminalize, "cancelled"}

  defp normalize_steering_delivery(result), do: {:deferred, bounded_error(result)}

  defp defer_control(state, task_id, control_id, error) do
    record = Map.fetch!(state.tasks, task_id)
    attempts = Map.get(record.control_retries, control_id, 0) + 1
    max_retries = Map.get(state, :max_steer_retries, @default_max_steer_retries)

    if attempts <= max_retries do
      state =
        update_control(state, task_id, control_id, fn value ->
          value |> Map.put("status", "deferred") |> Map.put("error", error)
        end)
        |> update_in([:tasks, task_id, :control_retries], &Map.put(&1, control_id, attempts))

      Process.send_after(
        self(),
        {:retry_steer, task_id, control_id},
        retry_delay_ms(state, attempts)
      )

      state
    else
      # Initial delivery retries exhausted: terminalize as delivery_unconfirmed.
      state
      |> update_control(task_id, control_id, fn value ->
        value
        |> Map.put("status", "delivery_unconfirmed")
        |> Map.put("delivered_at", nil)
        |> Map.put("error", "initial_delivery_retries_exhausted")
      end)
      |> advance_mailbox(task_id)
    end
  end

  defp retry_delay_ms(state, attempts) do
    exponent = min(max(attempts - 1, 0), 6)
    min(state.steer_retry_delay_ms * Integer.pow(2, exponent), state.max_steer_retry_delay_ms)
  end

  defp accept_control(state, task_id, control_id, status, mode) do
    state
    |> update_control(task_id, control_id, fn value ->
      value
      |> Map.put("status", status)
      |> Map.put("delivery_mode", Atom.to_string(mode))
      |> Map.put(
        "delivered_at",
        if(status == "delivered", do: DateTime.utc_now() |> DateTime.to_iso8601())
      )
      |> Map.put("error", nil)
    end)
    |> update_in([:tasks, task_id, :accepted_control_ids], fn
      ids when status == "delivered" -> MapSet.delete(ids, control_id)
      ids -> MapSet.put(ids, control_id)
    end)
    |> update_in([:tasks, task_id, :confirmation_retries], &Map.put(&1, control_id, 0))
  end

  defp advance_mailbox(state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        case first_pending_control(record) do
          nil -> state
          control_id -> deliver_control(state, task_id, control_id)
        end

      :error ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Queued-confirmation lifecycle
  # ---------------------------------------------------------------------------

  defp maybe_schedule_confirmation(state, task_id, control_id) do
    record = Map.fetch!(state.tasks, task_id)

    if task_running?(record) and
         MapSet.member?(record.accepted_control_ids, control_id) and
         first_confirmable_control(record) == control_id do
      schedule_confirmation(state, task_id, control_id, 0)
    else
      state
    end
  end

  defp schedule_confirmation(state, task_id, control_id, attempts) do
    delay = confirmation_delay_ms(state, attempts)

    Process.send_after(
      self(),
      {:confirm_steer, task_id, control_id},
      delay
    )

    state
  end

  defp confirmation_delay_ms(state, attempts) do
    base = Map.get(state, :steer_confirmation_delay_ms, state.steer_retry_delay_ms)
    exponent = min(max(attempts - 1, 0), 6)
    min(base * Integer.pow(2, exponent), state.max_steer_retry_delay_ms)
  end

  # Stale confirmation timers are harmless: every guard below must hold for the
  # confirmation to proceed. If any guard fails (task terminal, control
  # resolved, not the earliest confirmable), the timer is a no-op.
  defp confirm_control(state, task_id, control_id) do
    with {:ok, record} <- Map.fetch(state.tasks, task_id),
         true <- task_running?(record),
         control when not is_nil(control) <- find_control(record, control_id),
         true <- MapSet.member?(record.accepted_control_ids, control_id),
         true <- first_confirmable_control(record) == control_id do
      apply_confirmation(state, record, control)
    else
      _ -> state
    end
  end

  defp apply_confirmation(state, record, control) do
    result =
      if record.context_mode == :json_clean and is_map(record.context) and
           is_atom(record.executor) and Code.ensure_loaded?(record.executor) and
           function_exported?(record.executor, :steer_task, 3) do
        call_executor_callback(state, fn ->
          record.executor.steer_task(record.agent_id, control, record.context)
        end)
      else
        {:error, :unsupported}
      end

    case normalize_confirmation_delivery(result) do
      {:confirmed_delivered, mode} ->
        state
        |> accept_control(record.task_id, control["control_id"], "delivered", mode)
        |> advance_confirmation(record.task_id)

      :still_queued ->
        schedule_next_confirmation(state, record.task_id, control["control_id"])

      {:confirm_deferred, error} ->
        defer_confirmation(state, record.task_id, control["control_id"], error)

      :positive_nondelivery ->
        clear_accepted_and_replay(state, record.task_id, control["control_id"])

      {:terminalize, error} ->
        state
        |> terminalize_as_unconfirmed(record.task_id, control["control_id"], error)
        |> advance_confirmation(record.task_id)
    end
  end

  defp normalize_confirmation_delivery(result) do
    case result do
      {:ok, mode} when mode in @delivery_modes ->
        {:confirmed_delivered, mode}

      {:ok, :queued, mode} when mode in @delivery_modes ->
        :still_queued

      {:error, :not_delivered} ->
        :positive_nondelivery

      {:error, :delivery_unknown} ->
        {:terminalize, "delivery_unknown"}

      {:error, :cancelled} ->
        {:terminalize, "cancelled"}

      {:error, :unsupported} ->
        {:terminalize, "confirmation_unsupported"}

      other ->
        {:confirm_deferred, bounded_error(other)}
    end
  end

  defp schedule_next_confirmation(state, task_id, control_id) do
    record = Map.fetch!(state.tasks, task_id)
    attempts = Map.get(record.confirmation_retries, control_id, 0) + 1

    max_confirmations =
      Map.get(state, :max_steering_confirmations, @default_max_steering_confirmations)

    if attempts < max_confirmations do
      state =
        update_in(
          state,
          [:tasks, task_id, :confirmation_retries],
          &Map.put(&1, control_id, attempts)
        )

      schedule_confirmation(state, task_id, control_id, attempts)
    else
      state
      |> terminalize_as_unconfirmed(task_id, control_id, "confirmation_retries_exhausted")
      |> advance_confirmation(task_id)
    end
  end

  defp defer_confirmation(state, task_id, control_id, error) do
    record = Map.fetch!(state.tasks, task_id)
    attempts = Map.get(record.confirmation_retries, control_id, 0) + 1

    max_confirmations =
      Map.get(state, :max_steering_confirmations, @default_max_steering_confirmations)

    state =
      update_in(
        state,
        [:tasks, task_id, :confirmation_retries],
        &Map.put(&1, control_id, attempts)
      )

    state = update_control(state, task_id, control_id, &Map.put(&1, "error", error))

    if attempts < max_confirmations do
      schedule_confirmation(state, task_id, control_id, attempts)
    else
      state
      |> terminalize_as_unconfirmed(task_id, control_id, "confirmation_retries_exhausted")
      |> advance_confirmation(task_id)
    end
  end

  # Positive nondelivery: clear accepted ownership and re-deliver the exact
  # same control (bounded by max_steering_replays). The replayed control
  # re-enters the initial delivery path; if accepted again, a fresh
  # confirmation cycle starts with reset confirmation_retries.
  defp clear_accepted_and_replay(state, task_id, control_id) do
    record = Map.fetch!(state.tasks, task_id)
    replays = Map.get(record.replay_counts, control_id, 0) + 1
    max_replays = Map.get(state, :max_steering_replays, @default_max_steering_replays)

    if replays <= max_replays do
      state =
        state
        |> update_in([:tasks, task_id, :accepted_control_ids], &MapSet.delete(&1, control_id))
        |> update_in([:tasks, task_id, :replay_counts], &Map.put(&1, control_id, replays))
        |> update_control(task_id, control_id, fn control ->
          control
          |> Map.put("error", nil)
          |> Map.put("delivered_at", nil)
        end)

      # Re-deliver the exact same control (same control_id, same message, etc.)
      state = deliver_control(state, task_id, control_id)
      advance_confirmation_after_delivery(state, task_id, control_id)
    else
      state
      |> terminalize_as_unconfirmed(task_id, control_id, "replay_exhausted")
      |> advance_confirmation(task_id)
    end
  end

  defp terminalize_as_unconfirmed(state, task_id, control_id, error) do
    update_control(state, task_id, control_id, fn control ->
      control
      |> Map.put("status", "delivery_unconfirmed")
      |> Map.put("delivered_at", nil)
      |> Map.put("error", error)
    end)
    |> update_in([:tasks, task_id, :accepted_control_ids], &MapSet.delete(&1, control_id))
  end

  defp advance_confirmation(state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        case first_confirmable_control(record) do
          nil ->
            state

          next_id ->
            schedule_confirmation(state, task_id, next_id, 0)
        end

      :error ->
        state
    end
  end

  # After a replay or deferred-retry delivery settles, advance confirmation to
  # the next eligible accepted control so it is not stranded behind a terminal
  # or in-flight predecessor. If the just-delivered control re-accepted as
  # queued, maybe_schedule_confirmation already scheduled its confirmation and
  # we must not create a duplicate timer (which would double-spend confirmation
  # budget on a :still_queued cycle).
  defp advance_confirmation_after_delivery(state, task_id, control_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        control = find_control(record, control_id)

        if (control && control["status"] == "queued") and
             MapSet.member?(record.accepted_control_ids, control_id) do
          state
        else
          advance_confirmation(state, task_id)
        end

      :error ->
        state
    end
  end

  # FIFO gate: the earliest queued+accepted control is confirmable only if
  # no earlier control is still in flight (deferred or queued-but-unaccepted).
  # An in-flight predecessor blocks confirmation of later accepted controls
  # so their confirmation budget is not spent out of order, and so a replayed
  # predecessor that re-defers does not strand its successors.
  defp first_confirmable_control(record) do
    Enum.reduce_while(record.controls, nil, fn control, _acc ->
      cond do
        control["status"] == "queued" and
            MapSet.member?(record.accepted_control_ids, control["control_id"]) ->
          {:halt, control["control_id"]}

        control["status"] in ["deferred", "queued"] ->
          {:halt, nil}

        true ->
          {:cont, nil}
      end
    end)
  end

  defp task_running?(%{state: state}), do: state == :running

  defp update_control(state, task_id, control_id, fun) do
    update_in(state.tasks[task_id], fn record ->
      controls =
        Enum.map(record.controls, fn
          %{"control_id" => ^control_id} = control ->
            updated = fun.(control)
            emit_control_transition(record, updated, updated["status"])
            updated

          control ->
            control
        end)

      %{record | controls: controls}
    end)
  end

  defp find_control(record, control_id),
    do: Enum.find(record.controls, &(&1["control_id"] == control_id))

  defp first_pending_control(record) do
    record.controls
    |> Enum.find(&deliverable_control?(record, &1))
    |> case do
      nil -> nil
      control -> control["control_id"]
    end
  end

  defp deliverable_control?(_record, %{"status" => "deferred"}), do: true

  defp deliverable_control?(record, %{"status" => "queued", "control_id" => control_id}) do
    not MapSet.member?(record.accepted_control_ids, control_id)
  end

  defp deliverable_control?(_record, _control), do: false

  defp reconcile_terminal_controls(record) do
    record = ensure_record_shape(record)

    controls =
      Enum.map(record.controls, fn
        %{"status" => "deferred"} = control ->
          terminalize_control(record, control)

        %{"status" => "queued", "control_id" => control_id} = control ->
          if MapSet.member?(record.accepted_control_ids, control_id) do
            reconcile_accepted_control(record, control)
          else
            terminalize_control(record, control)
          end

        control ->
          control
      end)

    %{record | controls: controls}
  end

  defp reconcile_accepted_control(%{state: :done} = record, control) do
    transition_terminal_control(record, control, %{
      "status" => "delivery_unconfirmed",
      "delivered_at" => nil,
      "error" => "delivery_unconfirmed_task_succeeded"
    })
  end

  defp reconcile_accepted_control(%{state: :failed} = record, control) do
    transition_terminal_control(record, control, %{
      "status" => "delivery_unconfirmed",
      "delivered_at" => nil,
      "error" => "delivery_unconfirmed_task_failed"
    })
  end

  defp reconcile_accepted_control(%{state: :cancelled} = record, control) do
    transition_terminal_control(record, control, %{
      "status" => "delivery_unconfirmed",
      "delivered_at" => nil,
      "error" => "delivery_unconfirmed_task_cancelled"
    })
  end

  defp terminalize_control(record, control) do
    transition_terminal_control(record, control, %{
      "status" => "unsupported",
      "error" => "task_terminal"
    })
  end

  defp transition_terminal_control(record, control, fields) do
    updated = Map.merge(control, fields)

    if updated != control do
      emit_control_transition(record, updated, updated["status"])
    end

    updated
  end

  defp maybe_reconcile_terminal_controls(%{state: state} = record)
       when state in [:done, :failed, :cancelled],
       do: reconcile_terminal_controls(record)

  defp maybe_reconcile_terminal_controls(record), do: record

  # Configured executors may make terminal evidence retention mandatory. The
  # callback sees the exact successful executor result plus controls only after
  # their terminal states are reconciled. Explicit runner overrides never cross
  # this library boundary.
  defp maybe_finalize_task_result(
         %{state: :done, context_mode: :json_clean} = record,
         runner_result,
         state
       ) do
    module = Map.get(record, :executor)

    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, :finalize_task, 4) do
      finalize_configured_task(record, runner_result, state, module)
    else
      record
    end
  end

  defp maybe_finalize_task_result(record, _runner_result, _state), do: record

  defp finalize_configured_task(record, {:ok, result}, state, module)
       when is_map(result) and not is_struct(result) do
    case canonicalize_and_roundtrip(result) do
      {:ok, clean_result} ->
        invoke_task_finalizer(record, clean_result, state, module)

      {:error, _reason} ->
        finalization_failed(record, :non_json_success_result)
    end
  end

  defp finalize_configured_task(record, _runner_result, _state, _module),
    do: finalization_failed(record, :invalid_success_result)

  defp invoke_task_finalizer(record, result, state, module) do
    timeout =
      Map.get(
        state,
        :executor_finalization_timeout_ms,
        Config.executor_finalization_timeout_ms()
      )

    callback_result =
      call_executor_callback(
        state,
        fn -> module.finalize_task(record.agent_id, result, record.controls, record.context) end,
        timeout
      )

    case callback_result do
      {:ok, finalized} when is_map(finalized) and not is_struct(finalized) ->
        case canonicalize_and_roundtrip(finalized) do
          {:ok, clean} -> Map.put(record, :result, normalize_result(clean))
          {:error, _reason} -> finalization_failed(record, :non_json_finalization_result)
        end

      {:error, reason} ->
        finalization_failed(record, reason)

      _other ->
        finalization_failed(record, :invalid_finalization_result)
    end
  end

  defp finalization_failed(record, reason) do
    record
    |> Map.merge(%{
      state: :failed,
      current_step: "failed",
      waiting_on: nil,
      result: nil,
      error: {:task_finalization_failed, bounded_error(reason)}
    })
  end

  defp bounded_error(result) do
    result
    |> inspect(limit: 10, printable_limit: 160)
    |> String.slice(0, 200)
  end

  defp emit_control_transition(record, control, status) do
    message = control["message"] || ""

    data = %{
      task_id: bounded_value(record.task_id),
      agent_id: bounded_value(record.agent_id),
      control_id: bounded_value(control["control_id"]),
      sequence: control["sequence"],
      status: status,
      delivery_mode: control["delivery_mode"],
      sender_id: bounded_value(control["sender_id"]),
      target_stage: bounded_value(control["target_stage"]),
      queued_at: control["queued_at"],
      delivered_at: control["delivered_at"],
      error: bounded_value(control["error"]),
      message_preview: String.slice(message, 0, 160),
      message_digest: Base.encode16(:crypto.hash(:sha256, message), case: :lower)
    }

    if Code.ensure_loaded?(Arbor.Signals) and function_exported?(Arbor.Signals, :durable_emit, 4) do
      Arbor.Signals.durable_emit(:agent, :task_steering_transition, data,
        stream_id: "agent:task_steering"
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp bounded_value(value) when is_binary(value) do
    if String.valid?(value), do: String.slice(value, 0, 200), else: nil
  end

  defp bounded_value(_value), do: nil

  defp cancel_active_turn(record, state) do
    cancel_fun =
      case Map.get(record, :cancel_turn) do
        fun when is_function(fun, 2) -> fun
        _ -> state.cancel_turn
      end

    if is_function(cancel_fun, 2) do
      cancel_fun.(record.agent_id, record.task_id)
    else
      :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Default: SessionManager facade → Session.cancel_task/2 (task-scoped bridge).
  defp default_cancel_turn(agent_id, task_id)
       when is_binary(agent_id) and agent_id != "" and is_binary(task_id) and task_id != "" do
    session_manager =
      Application.get_env(:arbor_agent, :session_manager, Arbor.Agent.SessionManager)

    if is_atom(session_manager) and Code.ensure_loaded?(session_manager) and
         function_exported?(session_manager, :cancel_task, 2) do
      apply(session_manager, :cancel_task, [agent_id, task_id])
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp default_cancel_turn(_agent_id, _task_id), do: :ok

  defp revoke_approval_answer_capability(%{approval_answer_cap_id: cap_id} = record)
       when is_binary(cap_id) and cap_id != "" do
    record
    |> revoke_approval_answer_capability(cap_id)
    |> Map.put(:approval_answer_cap_id, nil)
  end

  defp revoke_approval_answer_capability(record), do: record

  defp revoke_task_capabilities(record) do
    record
    |> revoke_approval_answer_capability()
    |> revoke_steer_capability()
  end

  defp revoke_approval_answer_capability(%{approval_answer_revoke: revoke_fun} = record, cap_id)
       when is_function(revoke_fun, 1) do
    revoke_fun.(cap_id)
    record
  rescue
    _ -> record
  catch
    :exit, _ -> record
  end

  defp revoke_approval_answer_capability(
         %{approval_answer_security_module: module} = record,
         cap_id
       ) do
    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :revoke, 1) do
      apply(module, :revoke, [cap_id])
    else
      :ok
    end

    record
  rescue
    _ -> record
  catch
    :exit, _ -> record
  end

  defp revoke_steer_capability(%{steer_cap_id: cap_id} = record)
       when is_binary(cap_id) and cap_id != "" do
    record
    |> revoke_steer_capability(cap_id)
    |> Map.put(:steer_cap_id, nil)
  end

  defp revoke_steer_capability(record), do: record

  defp revoke_steer_capability(%{steer_capability_revoke: revoke_fun} = record, cap_id)
       when is_function(revoke_fun, 1) do
    revoke_fun.(cap_id)
    record
  rescue
    _ -> record
  catch
    :exit, _ -> record
  end

  defp revoke_steer_capability(%{steer_security_module: module} = record, cap_id) do
    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :revoke, 1) do
      apply(module, :revoke, [cap_id])
    else
      :ok
    end

    record
  rescue
    _ -> record
  catch
    :exit, _ -> record
  end

  defp project_status(%{state: :running, context_mode: :json_clean} = record, state) do
    status = status_view(record)
    merge_executor_progress(status, record, state)
  end

  defp project_status(record, _state), do: status_view(record)

  defp merge_executor_progress(status, record, state) do
    module = Map.get(record, :executor)
    context = Map.get(record, :context)
    agent_id = Map.get(record, :agent_id)

    if is_atom(module) and is_map(context) and is_binary(agent_id) and
         Code.ensure_loaded?(module) and function_exported?(module, :task_status, 2) do
      case call_executor_callback(state, fn -> module.task_status(agent_id, context) end) do
        {:ok, progress} ->
          case validate_progress(progress) do
            {:ok, clean_progress} ->
              status
              |> put_projected_field(:current_step, clean_progress)
              |> put_projected_field(:waiting_on, clean_progress)

            {:error, _} ->
              status
          end

        _ ->
          status
      end
    else
      status
    end
  end

  defp put_projected_field(status, field, progress) when is_map(progress) do
    value =
      Map.get(progress, Atom.to_string(field), Map.get(progress, field, :__missing__))

    case value do
      :__missing__ ->
        status

      projected when is_binary(projected) or is_nil(projected) ->
        Map.put(status, field, projected)

      _ ->
        status
    end
  end

  defp put_projected_field(status, _field, _progress), do: status

  defp validate_progress(progress) when is_map(progress) and not is_struct(progress) do
    case canonicalize_and_roundtrip(progress) do
      {:ok, clean} -> {:ok, clean}
      {:error, _reason} -> {:error, :non_json_progress}
    end
  end

  defp validate_progress(_progress), do: {:error, :invalid_progress}

  defp maybe_cancel_executor(%{context_mode: :json_clean} = record, state) do
    module = Map.get(record, :executor)
    context = Map.get(record, :context)
    agent_id = Map.get(record, :agent_id)

    if is_atom(module) and is_map(context) and is_binary(agent_id) and
         Code.ensure_loaded?(module) and function_exported?(module, :cancel_task, 2) do
      _ = call_executor_callback(state, fn -> module.cancel_task(agent_id, context) end)
    end

    :ok
  end

  defp maybe_cancel_executor(_record, _state), do: :ok

  # Bounded best-effort: run optional executor callbacks under the task
  # supervisor so a hung callback cannot freeze status or block cancellation.
  defp call_executor_callback(state, fun) when is_function(fun, 0) do
    timeout = Map.get(state, :executor_callback_timeout_ms, Config.executor_callback_timeout_ms())
    call_executor_callback(state, fun, timeout)
  end

  defp call_executor_callback(state, fun, timeout)
       when is_function(fun, 0) and is_integer(timeout) and timeout > 0 do
    supervisor = Map.fetch!(state, :task_supervisor)

    # Rescue/catch inside the task so raises do not log as Task.Supervisor
    # crashes; timeouts still need brutal kill of a live process.
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :executor_callback_exception}
        catch
          :exit, _ -> {:error, :executor_callback_exit}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :executor_callback_exit}

      nil ->
        {:error, :executor_callback_timeout}
    end
  rescue
    _ -> {:error, :executor_callback_failed}
  catch
    :exit, _ -> {:error, :executor_callback_exit}
  end

  defp status_view(record) do
    %{
      task_id: record.task_id,
      agent_id: record.agent_id,
      state: record.state,
      current_step: record.current_step,
      waiting_on: record.waiting_on,
      started_at: record.started_at,
      updated_at: record.updated_at,
      completed_at: record.completed_at,
      metadata: record.metadata,
      steering: steering_summary(record)
    }
  end

  defp steering_summary(record) do
    controls = Map.get(record, :controls, [])

    %{
      "counts" =>
        controls
        |> Enum.frequencies_by(& &1["status"])
        |> Map.take([
          "queued",
          "deferred",
          "delivered",
          "delivery_unconfirmed",
          "unsupported"
        ]),
      "last" =>
        case List.last(controls) do
          nil ->
            nil

          control ->
            Map.take(control, [
              "control_id",
              "sequence",
              "status",
              "delivery_mode",
              "target_stage",
              "queued_at",
              "delivered_at",
              "error"
            ])
        end
    }
  end

  defp remove_ref(state, ref) do
    update_in(state.refs, &Map.delete(&1, ref))
  end

  defp prune_tasks(%{max_tasks: max_tasks, tasks: tasks} = state)
       when map_size(tasks) <= max_tasks do
    state
  end

  defp prune_tasks(%{max_tasks: max_tasks, tasks: tasks} = state) do
    completed =
      tasks
      |> Enum.filter(fn {_id, record} -> record.state in [:done, :failed, :cancelled] end)
      |> Enum.sort_by(fn {_id, record} -> record.updated_at end, DateTime)

    excess = max(map_size(tasks) - max_tasks, 0)

    prune_ids =
      completed
      |> Enum.take(excess)
      |> Enum.map(fn {id, _record} -> id end)

    update_in(state.tasks, &Map.drop(&1, prune_ids))
  end

  defp task_id(opts) do
    Keyword.get(opts, :task_id) ||
      "task_" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp metadata(opts) do
    opts
    |> Keyword.get(:metadata, %{})
    |> case do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Executor selection + JSON-clean boundary
  # ---------------------------------------------------------------------------

  defp prepare_dispatch(task, opts, state, task_id) do
    with {:ok, runner, context_mode} <- resolve_executor(task, opts, state) do
      case context_mode do
        :json_clean ->
          with {:ok, clean_task} <- canonicalize_and_validate_task(task),
               {:ok, clean_context} <- build_and_validate_json_context(opts, task_id) do
            {:ok, runner, :json_clean, clean_task, clean_context}
          end

        :full_opts ->
          # Keep the trusted cleanup descriptor on the store record only; never
          # hand it to the runner (no payload/runner authority over cleanup).
          runner_context =
            opts
            |> Keyword.put(:task_id, task_id)
            |> Keyword.delete(:approval_cleanup_descriptor)

          {:ok, runner, :full_opts, task, runner_context}
      end
    end
  end

  defp resolve_executor(task, opts, state) do
    cond do
      # Trusted explicit runner overrides may receive full keyword opts.
      Keyword.has_key?(opts, :runner) ->
        {:ok, Keyword.fetch!(opts, :runner), :full_opts}

      state.runner_override ->
        {:ok, state.runner, :full_opts}

      true ->
        # Configured default and explicit-kind paths both use JSON-clean.
        case explicit_task_kind(task) do
          :none ->
            case Config.validated_default_task_executor() do
              {:ok, module} -> {:ok, module, :json_clean}
              {:error, _reason} = error -> error
            end

          {:ok, kind} ->
            case Config.task_executor(kind) do
              {:ok, module} -> {:ok, module, :json_clean}
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp explicit_task_kind(task) when is_map(task) do
    atom_kind = Map.fetch(task, :kind)
    string_kind = Map.fetch(task, "kind")

    case {atom_kind, string_kind} do
      {{:ok, atom_raw}, {:ok, string_raw}} ->
        with {:ok, atom_normalized} <- Config.normalize_kind(atom_raw),
             {:ok, string_normalized} <- Config.normalize_kind(string_raw) do
          if atom_normalized == string_normalized do
            {:ok, atom_normalized}
          else
            {:error, :conflicting_task_kind}
          end
        end

      {{:ok, raw}, :error} ->
        Config.normalize_kind(raw)

      {:error, {:ok, raw}} ->
        Config.normalize_kind(raw)

      {:error, :error} ->
        :none
    end
  end

  defp explicit_task_kind(_task), do: :none

  defp build_and_validate_json_context(opts, task_id) do
    context =
      %{}
      |> put_present("task_id", task_id)
      |> put_present("timeout", Keyword.get(opts, :timeout))
      |> put_present("caller_id", caller_id_from_opts(opts))

    context =
      if Keyword.has_key?(opts, :metadata) do
        Map.put(context, "metadata", metadata(opts))
      else
        context
      end

    case canonicalize_and_roundtrip(context) do
      {:ok, clean} -> {:ok, clean}
      {:error, _reason} -> {:error, :non_json_execution_context}
    end
  end

  # Plain string tasks stay strings on the JSON-clean default path.
  defp canonicalize_and_validate_task(task) when is_binary(task), do: {:ok, task}

  defp canonicalize_and_validate_task(task) when is_map(task) do
    case canonicalize_and_roundtrip(task) do
      {:ok, clean} -> {:ok, clean}
      {:error, :conflicting_task_kind} = error -> error
      {:error, _reason} -> {:error, :non_json_task}
    end
  end

  defp canonicalize_and_validate_task(_task), do: {:error, :non_json_task}

  defp canonicalize_and_roundtrip(term) do
    case canonicalize_json(term) do
      {:ok, clean} ->
        case Jason.encode(clean) do
          {:ok, encoded} ->
            case Jason.decode(encoded) do
              {:ok, ^clean} -> {:ok, clean}
              {:ok, _other} -> {:error, :json_roundtrip_mismatch}
              {:error, _} -> {:error, :json_decode_failed}
            end

          {:error, _} ->
            {:error, :json_encode_failed}
        end

      {:error, _} = error ->
        error
    end
  end

  defp canonicalize_json(value) when is_binary(value), do: {:ok, value}
  defp canonicalize_json(value) when is_number(value), do: {:ok, value}
  defp canonicalize_json(value) when is_boolean(value), do: {:ok, value}
  defp canonicalize_json(nil), do: {:ok, nil}

  defp canonicalize_json(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case canonicalize_json(item) do
        {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp canonicalize_json(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, string_key} <- canonicalize_map_key(key),
           {:ok, clean_value} <- canonicalize_map_value(string_key, value) do
        case Map.fetch(acc, string_key) do
          :error ->
            {:cont, {:ok, Map.put(acc, string_key, clean_value)}}

          {:ok, ^clean_value} ->
            {:cont, {:ok, acc}}

          {:ok, _other} when string_key == "kind" ->
            {:halt, {:error, :conflicting_task_kind}}

          {:ok, _other} ->
            {:halt, {:error, {:conflicting_map_keys, string_key}}}
        end
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp canonicalize_json(%_{}), do: {:error, :struct_not_json}
  defp canonicalize_json(value) when is_pid(value), do: {:error, :pid_not_json}
  defp canonicalize_json(value) when is_function(value), do: {:error, :function_not_json}
  defp canonicalize_json(value) when is_reference(value), do: {:error, :reference_not_json}
  defp canonicalize_json(value) when is_port(value), do: {:error, :port_not_json}
  defp canonicalize_json(value) when is_tuple(value), do: {:error, :tuple_not_json}

  defp canonicalize_json(value) when is_atom(value) do
    {:error, {:unsupported_atom_value, value}}
  end

  defp canonicalize_json(_value), do: {:error, :non_json_value}

  defp canonicalize_map_key(key) when is_binary(key), do: {:ok, key}

  defp canonicalize_map_key(key) when is_atom(key) and not is_nil(key),
    do: {:ok, Atom.to_string(key)}

  defp canonicalize_map_key(_key), do: {:error, :invalid_map_key}

  defp canonicalize_map_value("kind", value) do
    case Config.normalize_kind(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :blank_task_kind} -> {:error, :blank_task_kind}
      {:error, :invalid_task_kind} -> {:error, :invalid_task_kind}
    end
  end

  defp canonicalize_map_value(_key, value), do: canonicalize_json(value)

  defp caller_id_from_opts(opts) do
    Keyword.get(opts, :caller_id) ||
      Keyword.get(opts, :actor_id) ||
      Keyword.get(opts, :authenticated_principal_id)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp store_name(opts) do
    opts
    |> opt(:name, @default_name)
  end

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(_opts), do: []

  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts),
    do: Map.get(opts, key, Map.get(opts, to_string(key), default))

  defp opt(_opts, _key, default), do: default
end
