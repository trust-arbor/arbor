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

  A configured executor may also implement `adopt_task/4`. This is a
  post-external-integration proof and settlement step; it does not merge,
  cherry-pick, or otherwise integrate the candidate. TaskStore serializes
  adoption admission and commit, but runs the potentially slow callback under
  the task supervisor so status and result reads remain available. Adoption is
  eligible only for successful terminal JSON-clean tasks; callback errors leave
  the prior result unchanged so callers can retry.

  ## Target dispatch fencing

  Template-authority maintenance installs an operation-owned fence for one
  target through `install_target_fence/3` and removes it through
  `remove_target_fence/3`. Installation and the bounded active/reserved counts
  are one TaskStore linearization point. Reservations, activation, and direct
  dispatch all fail closed while that target is fenced.

  On startup, a supervised worker rebuilds fences from outstanding durable
  template-authority operations. Public `recovery_ready?/1` is therefore the
  conjunction of task-control replay readiness and fence-seed readiness. Until
  both are established, dispatch admission stays closed; verified fence probes
  return `{:error, :fence_not_ready}` rather than treating unknown as absent.
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
  @default_inventory_items 64
  @default_steer_retry_delay_ms 100
  @default_max_steer_retry_delay_ms 5_000
  @default_max_controls_per_task 100
  @default_max_steer_retries 7
  # Bounds only genuine operational confirmation ambiguity (callback
  # exception/exit/timeout, see `defer_confirmation/4`). Explicit still-queued
  # observations do not spend this budget — see "Queued-confirmation
  # lifecycle" below.
  @default_max_steering_confirmations 5
  @default_max_steering_replays 3
  @default_adoption_timeout_ms 120_000
  @default_adoption_wait_timeout_ms 30_000
  @default_adoption_status_timeout_ms 500
  @max_adoption_timeout_ms 300_000
  @max_adoption_wait_timeout_ms 120_000
  @max_adoption_status_timeout_ms 2_000
  @max_adoption_waiters 32
  @max_steering_message_bytes 4_000
  @max_destination_ref_bytes 256
  # Lease retirement reconciliation (store-owned; non-durable).
  @default_lease_retire_admit_timeout_ms 2_000
  @default_lease_retire_worker_timeout_ms 10_000
  @default_lease_retire_base_delay_ms 100
  @default_lease_retire_max_delay_ms 5_000
  @default_lease_retire_max_attempts 8
  @default_lease_retire_max_retrigger_rounds 4
  # Recovery markers / reservation (store-owned workers; never I/O in callbacks).
  @default_recovery_store :arbor_agent_task_control_recovery
  @default_max_recovery_obligations 256
  @default_max_reservations 256
  @default_reservation_deadline_ms 30_000
  @default_recovery_admit_timeout_ms 2_000
  @default_recovery_worker_timeout_ms 10_000
  @default_recovery_call_timeout_ms 15_000
  @default_recovery_replay_batch 64
  @default_recovery_retry_base_ms 200
  @default_recovery_retry_max_ms 5_000
  @default_recovery_max_retries 16
  # Target dispatch fence (Phase 4C C2A). Operation-owned per-target maintenance
  # fence seeded from the durable template-authority operation store on startup.
  # Node-local linearization boundary only.
  @default_fence_seed_facade Arbor.Agent.TemplateAuthorityReconciliationStore
  @default_fence_seed_admit_timeout_ms 2_000
  @default_fence_seed_worker_timeout_ms 10_000
  @max_fence_agent_id_bytes 256
  @max_fence_operation_id_bytes 128
  @fence_agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @fence_operation_id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  # Runtime-admission intents (Phase 4C C3C1a0). Ordinary Lifecycle.start linearization.
  @default_runtime_admission_supervisor Arbor.Agent.RuntimeAdmission.Supervisor
  @default_max_runtime_admission_intents 256
  @default_runtime_admission_admit_timeout_ms 2_000
  @default_runtime_admission_reconcile_timeout_ms 10_000
  # F-575: store-owned waiter deadline default/max; call transport adds reply grace.
  # Hard waiter ceiling is WaiterCore.ceiling() (64); init may lower only.
  @default_max_runtime_admission_waiters 64
  @default_runtime_admission_waiter_deadline_ms 120_000
  @min_runtime_admission_waiter_deadline_ms 1
  @runtime_admission_waiter_reply_grace_ms 500
  # Versioned one-time waiter-map migration (not scanned on every event).
  @runtime_admission_waiter_schema_v 1
  # Closed dual-inventory reconcile result schema (owners + durable claims).
  # Legacy owner-only {:ok, owners} is rejected — hot upgrade / stale workers
  # must not mark ready without a validated claim inventory.
  @runtime_admission_reconcile_result_v 1

  @runtime_admission_reconcile_result_keys MapSet.new([
                                             :v,
                                             :ref,
                                             :attempt,
                                             :worker_pid,
                                             :owners,
                                             :claims
                                           ])
  # Owner retirement barrier: escalate :shutdown → :kill; never finalize on timer.
  @default_runtime_admission_settle_timeout_ms 500
  @default_runtime_admission_observe_timeout_ms 2_000
  # Pre-handoff durable-claim join observer (fixed supervised recovery op).
  @default_runtime_admission_claim_join_timeout_ms 2_000
  @max_runtime_admission_claim_join_attempts 4
  # Unified durable mark/settle shell (fixed supervised recovery op).
  # Attempt is threaded through launcher + retry — never reset to 1 on failure.
  @default_runtime_admission_durable_op_timeout_ms 5_000
  @max_runtime_admission_durable_shell_launch_attempts 4
  @runtime_admission_durable_shell_launch_base_backoff_ms 50
  @runtime_admission_launcher_collision_retries 8
  @runtime_admission_launcher_collision_sleep_ms 25
  @runtime_admission_launcher_max_attempts 8
  @runtime_admission_registry Arbor.Agent.RuntimeAdmissionRegistry

  alias Arbor.Agent.Config
  alias Arbor.Agent.Orchestration.{TaskArtifacts, TaskControlLease, TaskInventoryProjection}
  alias Arbor.Agent.RuntimeAdmission.IntentCore
  alias Arbor.Agent.RuntimeAdmission.IntentOwner
  alias Arbor.Agent.RuntimeAdmission.OperationLauncher
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RuntimeAdmissionSupervisor
  alias Arbor.Agent.RuntimeAdmission.WaiterCore

  alias Arbor.Contracts.Coding.{
    AdmissionFailure,
    ReadinessReport,
    TaskOutcome,
    TaskTerminalEnvelope
  }

  @type task_id :: String.t()
  # :waiting_approval is retained for status projection / facade enrichment
  # (Orchestration.task_status/2 still surfaces it for running tasks with a
  # pending approval). Ownerless runner pending-approval results fail closed to
  # :failed — they must not leave a terminal task stuck waiting.
  @type state_name :: :running | :waiting_approval | :done | :failed | :cancelled

  @type task_status :: %{
          optional(:outcome) => map(),
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

    _ =
      opts
      |> Keyword.get(:task_control_security_module, Arbor.Security)
      |> validate_task_control_security_module!()

    _ =
      opts
      |> Keyword.get(:task_control_revoke)
      |> validate_task_control_revoke!()

    _ =
      opts
      |> Keyword.get(:adoption_timeout_ms, @default_adoption_timeout_ms)
      |> validate_adoption_timeout!()

    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reserve a server-owned task identity bound to one validated target_agent_id.

  Returns `%{task_id: id, reservation_token: token}`. The opaque token is
  owner-bound (calling process) and required for `commit_recovery_marker/3`,
  `activate/5`, and `release/3`. The `target_agent_id` is stored on the
  reservation and re-compared during `activate/5`; a mismatch fails closed
  without consuming or retargeting the reservation. Never accepted from public
  MCP dispatch opts; production task ids are unguessable. Deterministic ids
  only via store-start `:task_id_generator` pin.

  Fails closed for a target that has an installed operation-owned dispatch
  fence (`{:error, :target_fenced}`), and while fence-seed readiness has not
  been established (`{:error, :fence_not_ready}`).
  """
  @spec reserve(String.t(), keyword() | map()) ::
          {:ok, %{task_id: task_id(), reservation_token: String.t()}} | {:error, term()}
  def reserve(target_agent_id, opts \\ []) do
    GenServer.call(
      store_name(opts),
      {:reserve, target_agent_id, normalize_opts(opts)}
    )
  end

  @doc """
  Persist a capability-ID-free recovery marker for a reserved task.

  Backend-acknowledged via store-owned recovery workers (no Persistence I/O in
  the GenServer callback). Must succeed before Orchestration mints lease
  members. Fails closed when durability is unavailable.
  """
  @spec commit_recovery_marker(task_id(), String.t(), keyword() | map()) ::
          :ok | {:error, term()}
  def commit_recovery_marker(task_id, reservation_token, opts \\ [])
      when is_binary(task_id) and is_binary(reservation_token) do
    GenServer.call(
      store_name(opts),
      {:commit_recovery_marker, task_id, reservation_token},
      recovery_call_timeout(opts)
    )
  end

  @doc """
  Activate a reserved task with an optional closed task-control lease.

  Requires the opaque reservation token. Drops the reservation after the task
  record is admitted; retains the durable recovery marker while authority or
  pending retirement remains. A non-nil lease requires a backend-acknowledged
  recovery marker and otherwise returns `{:error, :recovery_marker_required}`.
  """
  @spec activate(String.t(), term(), task_id(), String.t(), keyword() | map()) ::
          {:ok, task_id()} | {:error, term()}
  def activate(agent_id, task, task_id, reservation_token, opts \\ [])
      when is_binary(task_id) and is_binary(reservation_token) do
    GenServer.call(
      store_name(opts),
      {:activate, agent_id, task, task_id, reservation_token, normalize_opts(opts)}
    )
  end

  @doc """
  Release a reservation. When a recovery marker was written, launches
  store-owned reconcile (`revoke_by_task` then conditional marker delete).
  """
  @spec release(task_id(), String.t(), keyword() | map()) :: :ok | {:error, term()}
  def release(task_id, reservation_token, opts \\ [])
      when is_binary(task_id) and is_binary(reservation_token) do
    GenServer.call(
      store_name(opts),
      {:release, task_id, reservation_token},
      recovery_call_timeout(opts)
    )
  end

  @doc """
  Request task-scope recovery reconcile via store-owned workers
  (`Security.revoke_by_task/1` + conditional marker delete). Used after mint
  uncertainty; never runs Persistence/Security I/O in the GenServer callback.
  """
  @spec request_reconcile(task_id(), keyword() | map()) :: :ok | {:error, term()}
  def request_reconcile(task_id, opts \\ []) when is_binary(task_id) do
    GenServer.call(
      store_name(opts),
      {:request_reconcile, task_id},
      recovery_call_timeout(opts)
    )
  end

  @doc "Return whether task-control replay and durable fence seeding are both ready."
  @spec recovery_ready?(keyword() | map()) :: boolean()
  def recovery_ready?(opts \\ []) do
    case GenServer.call(store_name(opts), :recovery_ready?) do
      true -> true
      _ -> false
    end
  end

  @doc """
  Install an operation-owned per-target dispatch fence and report the barrier.

  The fence is owned by exactly one `operation_id` per `target_agent_id`.
  Installing it and observing pre-existing active/reserved work for that
  target are one GenServer linearization point. The reply carries ONLY bounded
  integer counts (`active_count` includes running and waiting_approval tasks;
  `reserved_count` counts target-bound reservations) — never task ids,
  reservation tokens, PIDs, capability ids, or records.

  Same `(target, operation_id)` is idempotent and re-observes counts. A
  different `operation_id` fails `:target_fenced` without changing the owner.
  Fails `:fence_not_ready` while the startup fence seed has not completed.
  Fails `:runtime_admission_not_ready` while runtime-admission/claim inventory
  has not completed — both must be ready so barrier counts include surviving
  intents and fences are not installed/removed against incomplete inventory.
  """
  @spec install_target_fence(String.t(), String.t(), keyword() | map()) ::
          {:ok, %{active_count: non_neg_integer(), reserved_count: non_neg_integer()}}
          | {:error, term()}
  def install_target_fence(target_agent_id, operation_id, opts \\ []) do
    GenServer.call(
      store_name(opts),
      {:install_target_fence, target_agent_id, operation_id}
    )
  end

  @doc """
  Remove an operation-owned per-target dispatch fence.

  Requires the exact `target_agent_id` and `operation_id` that installed it.
  A different owner fails `:target_fenced`; a missing fence fails
  `:not_found`. Fails `:fence_not_ready` while the startup seed has not
  completed, and `:runtime_admission_not_ready` while claim/owner inventory
  is incomplete. Same-operation removal while a non-idle guarded restore
  intent holds the target fails `:fence_held_by_restore`.
  """
  @spec remove_target_fence(String.t(), String.t(), keyword() | map()) ::
          :ok | {:error, term()}
  def remove_target_fence(target_agent_id, operation_id, opts \\ []) do
    GenServer.call(
      store_name(opts),
      {:remove_target_fence, target_agent_id, operation_id}
    )
  end

  @doc "Return verified fence presence without collapsing unknown readiness to absence."
  @spec target_fenced?(String.t(), keyword() | map()) ::
          {:ok, boolean()} | {:error, :fence_not_ready | :invalid_target_agent_id}
  def target_fenced?(target_agent_id, opts \\ []) do
    GenServer.call(store_name(opts), {:target_fenced?, target_agent_id})
  end

  @doc "Verify that an exact operation owns the target's ready dispatch fence."
  @spec verify_target_fence(String.t(), String.t(), keyword() | map()) ::
          :ok
          | {:error,
             :fence_not_ready
             | :invalid_target_agent_id
             | :invalid_operation_id
             | :target_not_fenced
             | :not_owner}
  def verify_target_fence(target_agent_id, operation_id, opts \\ []) do
    GenServer.call(
      store_name(opts),
      {:verify_target_fence, target_agent_id, operation_id}
    )
  end

  @doc """
  Admit or join an ordinary runtime-start intent and await settlement.

  Linearization point with `install_target_fence/3`. Parks the caller until the
  fixed owner/worker settles. No lifecycle I/O in this GenServer callback.
  """
  @spec admit_ordinary_runtime_start(String.t(), String.t(), keyword(), keyword() | map()) ::
          {:ok, pid()} | {:error, term()}
  def admit_ordinary_runtime_start(target_agent_id, fingerprint, validated_opts, opts \\ [])
      when is_binary(target_agent_id) and is_binary(fingerprint) and is_list(validated_opts) do
    wait_ms = runtime_admission_waiter_deadline_ms(opts)
    call_timeout = wait_ms + @runtime_admission_waiter_reply_grace_ms

    GenServer.call(
      store_name(opts),
      {:admit_ordinary_runtime_start, target_agent_id, fingerprint, validated_opts, wait_ms},
      call_timeout
    )
  end

  @doc """
  Admit or join a guarded runtime-restore intent and await settlement.

  Linearization point with ordinary admit and target fences. Requires the exact
  ready fence owned by `operation_id`. No lifecycle I/O in this callback.
  """
  @spec admit_guarded_runtime_restore(
          String.t(),
          String.t(),
          String.t(),
          keyword() | map()
        ) :: {:ok, pid()} | {:error, term()}
  def admit_guarded_runtime_restore(target_agent_id, operation_id, restore_token, opts \\ [])
      when is_binary(target_agent_id) and is_binary(operation_id) and is_binary(restore_token) do
    wait_ms = runtime_admission_waiter_deadline_ms(opts)
    call_timeout = wait_ms + @runtime_admission_waiter_reply_grace_ms

    GenServer.call(
      store_name(opts),
      {:admit_guarded_runtime_restore, target_agent_id, operation_id, restore_token, wait_ms},
      call_timeout
    )
  end

  @doc """
  Source-authenticated effect-handoff ack for guarded restore.

  Must be called by the bound IntentOwner after durable intent bind and worker
  bind, and **before** releasing the worker gate. Sets `effect_handoff?`.
  """
  @spec ack_guarded_restore_effect_handoff(
          String.t(),
          String.t(),
          String.t(),
          keyword() | map()
        ) :: :ok | {:error, term()}
  def ack_guarded_restore_effect_handoff(target_agent_id, intent_id, fingerprint, opts \\ [])
      when is_binary(target_agent_id) and is_binary(intent_id) and is_binary(fingerprint) do
    GenServer.call(
      store_name(opts),
      {:ack_guarded_restore_effect_handoff, target_agent_id, intent_id, fingerprint}
    )
  end

  @doc "Return whether runtime-admission owner reconcile has completed."
  @spec runtime_admission_ready?(keyword() | map()) :: boolean()
  def runtime_admission_ready?(opts \\ []) do
    case GenServer.call(store_name(opts), :runtime_admission_ready?) do
      true -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  Authenticated launch bind for a just-started IntentOwner.

  Called from IntentOwner.init/1 with the TaskStore-minted launch_ref. The
  GenServer caller pid is bound as expected owner only when the launch_ref
  matches the current attempt. Caller-supplied PIDs are never trusted.
  """
  @spec bind_runtime_admission_launch(
          String.t(),
          String.t(),
          String.t(),
          reference(),
          keyword() | map()
        ) :: :ok | {:error, term()}
  def bind_runtime_admission_launch(
        target_agent_id,
        intent_id,
        fingerprint,
        launch_ref,
        opts \\ []
      )
      when is_binary(target_agent_id) and is_binary(intent_id) and is_binary(fingerprint) and
             is_reference(launch_ref) do
    timeout =
      Keyword.get(
        normalize_opts(opts),
        :timeout,
        @default_runtime_admission_admit_timeout_ms
      )

    GenServer.call(
      store_name(opts),
      {:bind_runtime_admission_launch, target_agent_id, intent_id, fingerprint, launch_ref},
      timeout
    )
  end

  @doc """
  Adopt the calling IntentOwner against the current fence and intent map.

  Requires the caller to already be the launch-bound (or restart-rebound)
  owner_pid. Caller-supplied PIDs are never trusted as mint authority.
  """
  @spec adopt_runtime_admission_owner(String.t(), String.t(), String.t(), keyword() | map()) ::
          :ok | {:error, term()}
  def adopt_runtime_admission_owner(target_agent_id, intent_id, fingerprint, opts \\ [])
      when is_binary(target_agent_id) and is_binary(intent_id) and is_binary(fingerprint) do
    GenServer.call(
      store_name(opts),
      {:adopt_runtime_admission_owner, target_agent_id, intent_id, fingerprint}
    )
  end

  @doc """
  Owner-authenticated bind of an exact worker PID against a live intent.

  Caller must be the recorded IntentOwner (`caller_pid == intent.owner_pid`).
  The worker PID is the process the owner just spawned (not a self-claimed
  hijack). TaskStore monitors the bound worker. Settlement and Lifecycle
  effects authenticate to that bound worker only.
  """
  @spec bind_runtime_admission_worker(
          String.t(),
          String.t(),
          String.t(),
          pid(),
          keyword() | map()
        ) :: :ok | {:error, term()}
  def bind_runtime_admission_worker(
        target_agent_id,
        intent_id,
        fingerprint,
        worker_pid,
        opts \\ []
      )
      when is_binary(target_agent_id) and is_binary(intent_id) and is_binary(fingerprint) and
             is_pid(worker_pid) do
    GenServer.call(
      store_name(opts),
      {:bind_runtime_admission_worker, target_agent_id, intent_id, fingerprint, worker_pid}
    )
  end

  @doc """
  Authenticate the calling process as the exact bound worker for
  target+intent_id+fingerprint. Used by Lifecycle before any start effects.
  """
  @spec authenticate_runtime_admission_worker(
          String.t(),
          String.t(),
          String.t(),
          keyword() | map()
        ) :: :ok | {:error, term()}
  def authenticate_runtime_admission_worker(
        target_agent_id,
        intent_id,
        fingerprint,
        opts \\ []
      )
      when is_binary(target_agent_id) and is_binary(intent_id) and is_binary(fingerprint) do
    GenServer.call(
      store_name(opts),
      {:authenticate_runtime_admission_worker, target_agent_id, intent_id, fingerprint}
    )
  end

  @doc """
  Source-owned settlement: only the registered worker pid for the exact intent
  may settle. Rejected transitions return explicit errors and leave waiters live.
  """
  @spec settle_runtime_admission(String.t(), String.t(), term(), keyword() | map()) ::
          :ok | {:error, term()}
  def settle_runtime_admission(target_agent_id, intent_id, outcome, opts \\ [])
      when is_binary(target_agent_id) and is_binary(intent_id) do
    GenServer.call(
      store_name(opts),
      {:settle_runtime_admission, target_agent_id, intent_id, outcome}
    )
  end

  defp runtime_admission_waiter_deadline_ms(opts) do
    opts
    |> normalize_opts()
    |> Keyword.get(:timeout, @default_runtime_admission_waiter_deadline_ms)
    |> clamp_runtime_admission_waiter_deadline_ms()
  end

  defp clamp_runtime_admission_waiter_deadline_ms(raw) do
    cond do
      not is_integer(raw) ->
        @default_runtime_admission_waiter_deadline_ms

      raw < @min_runtime_admission_waiter_deadline_ms ->
        @min_runtime_admission_waiter_deadline_ms

      raw > @default_runtime_admission_waiter_deadline_ms ->
        @default_runtime_admission_waiter_deadline_ms

      true ->
        raw
    end
  end

  @doc """
  Dispatch an async task (store-level / test path).

  Production public dispatch goes through `Arbor.Agent.Orchestration` which
  reserves, commits a recovery marker, grants the lease, then `activate/5`.
  Direct `dispatch/3` remains for store unit tests and internal runners.

  The target is validated before fence lookup. Direct dispatch returns
  `{:error, :fence_not_ready}` until durable fence seeding completes and
  `{:error, :target_fenced}` while an operation owns the target fence; neither
  error starts a runner.

  Options:

    * `:name` - task store process name, for tests
    * `:runner` - module implementing `run/3` (test/internal override)
    * `:task_id` - explicit id for store-level deterministic tests only
      (not accepted through authenticated public Orchestration.dispatch opts)
    * `:metadata` - caller metadata copied into the task record
    * `:timeout` - optional timeout forwarded in JSON-clean executor context
    * `:caller_id` - optional caller id forwarded in JSON-clean executor context
    * `:task_control_lease` - private closed scalar task-control lease only
      (schema version, exact task id, kind→opaque-id map). Executable
      selectors (Security module, revoke funs) are never accepted per dispatch;
      they are pinned at TaskStore init.
    * `:approval_cleanup_descriptor` - private closed scalar lifecycle cleanup
      descriptor only (`caller_id`, delegated `principal_id`, and optional
      `trace_id`). Executable
      selectors (MFA, modules, functions, PIDs) are stripped on store and never
      retained. Cleanup MFA, Consensus/Comms/Audit modules, lease Security
      module, recovery facade/store, optional test lease-revoke seam, and the
      cleanup supervisor are pinned at TaskStore init (production defaults:
      `Orchestration.cleanup_approvals_for_task/2`, real backends, normal task
      supervisor). Tests may override those only at store start.

  ## Recovery and retirement

  Durable capability-ID-free recovery markers are written before grants and
  replayed on startup via store-owned workers calling `Security.revoke_by_task/1`.
  Phase-aware retirement uses O(1) task/monitor indexes. Exhausted retirement
  emits `[:arbor, :agent, :task_control_lease, :retire_exhausted]` with redacted
  measurements/metadata (no capability ids); exhausted means retry budget spent
  while authority is retained — not silent discard and not TTL-only recovery.
  Capacity is enforced at reserve only so terminal retirement never drops IDs.
  """
  @spec dispatch(String.t(), term(), keyword() | map()) :: {:ok, task_id()} | {:error, term()}
  def dispatch(agent_id, task, opts \\ []) do
    GenServer.call(store_name(opts), {:dispatch, agent_id, task, normalize_opts(opts)})
  end

  defp recovery_call_timeout(opts) do
    opt = normalize_opts(opts)

    case Keyword.get(opt, :recovery_call_timeout_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_recovery_call_timeout_ms
    end
  end

  @doc "Return current task status."
  @spec status(task_id(), keyword() | map()) :: {:ok, task_status()} | {:error, :not_found}
  def status(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:status, task_id})
  end

  @doc "Return a bounded, redacted inventory of the volatile task registry."
  @spec inventory(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def inventory(opts \\ []) do
    opts = normalize_opts(opts)
    filters = Map.take(Map.new(opts), [:task_id, :agent_id, :state])
    max_items = opt(opts, :max_items, @default_inventory_items)

    GenServer.call(store_name(opts), {:inventory, filters, max_items})
  end

  @doc "Return the completed task result."
  @spec result(task_id(), keyword() | map()) :: task_result()
  def result(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:result, task_id})
  end

  @doc false
  # ID-free internal/test seam: reopen exhausted retirement buckets for a new
  # bounded retry generation. Reply is counts only — never capability ids.
  @spec retrigger_exhausted_lease_retirements(keyword() | map()) ::
          {:ok, %{retried_tasks: non_neg_integer(), remaining_exhausted: non_neg_integer()}}
          | {:error, term()}
  def retrigger_exhausted_lease_retirements(opts \\ []) do
    GenServer.call(store_name(opts), :retrigger_exhausted_lease_retirements)
  end

  @doc false
  # Redacted retirement observability for tests (no capability ids).
  @spec lease_retirement_snapshot(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def lease_retirement_snapshot(opts \\ []) do
    GenServer.call(store_name(opts), :lease_retirement_snapshot)
  end

  @doc """
  Prove and settle an already externally integrated terminal task change.

  The executor callback runs asynchronously under TaskStore ownership. This
  call waits a bounded amount of time (`:adoption_wait_timeout_ms`, default
  #{@default_adoption_wait_timeout_ms} ms) for the owned operation to settle.
  Timing out the caller does not cancel an adoption that TaskStore already
  admitted; callers can inspect `adoption_status/3` and `result/2` for its
  eventual committed state.

  This operation does not perform the external merge, cherry-pick, or other
  integration represented by `destination_ref`.
  """
  @spec adopt(task_id(), String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def adopt(task_id, destination_ref, opts \\ []) do
    with {:ok, wait_timeout_ms} <- adoption_wait_timeout(opts) do
      deadline_ms = System.monotonic_time(:millisecond) + wait_timeout_ms

      try do
        GenServer.call(
          store_name(opts),
          {:adopt, task_id, destination_ref, deadline_ms},
          wait_timeout_ms
        )
      catch
        :exit, {:timeout, _call} -> {:error, :task_adoption_wait_timeout}
      end
    end
  end

  @doc """
  Return TaskStore's authoritative state for one post-integration settlement.

  The result is `:pending` while the exact TaskStore-owned callback is active,
  `{:settled, result}` after successful settlement, `{:failed, reason}` after a
  failed attempt, or `:not_started` when no matching attempt was admitted.
  """
  @spec adoption_status(task_id(), String.t(), keyword() | map()) ::
          {:ok, :pending | :not_started | {:settled, map()} | {:failed, String.t()}}
          | {:error, term()}
  def adoption_status(task_id, destination_ref, opts \\ []) do
    with {:ok, %{"destination_ref" => destination_ref}} <-
           normalize_adoption_request(destination_ref),
         {:ok, timeout_ms} <- adoption_status_timeout(opts) do
      try do
        GenServer.call(
          store_name(opts),
          {:adoption_status, task_id, destination_ref},
          timeout_ms
        )
      catch
        :exit, {:timeout, _call} -> {:error, :task_adoption_status_timeout}
      end
    end
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
  Only explicit delivered confirmation sets `delivered_at`. A repeated
  explicit `{:ok, :queued, mode}` during confirmation is an authoritative
  still-in-flight signal, not an operational failure (e.g. a managed ACP
  control can legitimately stay queued for many minutes while the
  same-session provider prompt runs): it remains pending and keeps polling at
  a bounded exponential backoff indefinitely, and never spends the
  `max_steering_confirmations` budget or terminalizes on its own. Positive
  `:not_delivered` during confirmation clears accepted ownership and
  triggers a bounded same-ID replay; `:delivery_unknown`/`:cancelled`, and
  any genuine operational ambiguity (callback exception/exit/timeout) once
  `max_steering_confirmations` is exhausted, terminalize immediately as
  `"delivery_unconfirmed"` whether returned during initial delivery,
  confirmation, or replay. If a task fails or is cancelled before an
  accepted control is confirmed delivered, the control enters the terminal
  `"delivery_unconfirmed"` state. Initial delivery, confirmation-error, and
  replay budgets are independent; FIFO ordering is enforced by the store.

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

    task_control_security_module =
      opts
      |> Keyword.get(:task_control_security_module, Arbor.Security)
      |> validate_task_control_security_module!()

    task_control_revoke =
      opts
      |> Keyword.get(:task_control_revoke)
      |> validate_task_control_revoke!()

    recovery_facade =
      opts
      |> Keyword.get(
        :task_control_recovery_facade,
        if(Mix.env() == :test,
          do: Arbor.Agent.Orchestration.TaskControlRecoveryMemory,
          else: Arbor.Agent.Orchestration.TaskControlRecoveryPersistence
        )
      )
      |> validate_task_control_recovery_facade!()

    # Phase 4C C2A: production reconciliation-store collaborator for fence
    # seeding is fixed at store initialization. Test-only injection is allowed
    # solely at store start under MIX_ENV=test; per-reservation and per-dispatch
    # options remain data-only.
    fence_facade =
      opts
      |> Keyword.get(:template_authority_fence_facade, @default_fence_seed_facade)
      |> validate_fence_facade!(opts)

    task_id_generator =
      opts
      |> Keyword.get(:task_id_generator)
      |> validate_task_id_generator!()

    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    # Optional separate supervisor for cleanup scheduling (tests may suspend it).
    # Production default is the same normal task supervisor.
    cleanup_supervisor = Keyword.get(opts, :cleanup_supervisor, task_supervisor)

    recovery_store =
      Keyword.get(opts, :task_control_recovery_store, @default_recovery_store)

    # Production always starts not-ready and replays durable markers via workers.
    # Unit tests default force-ready with the in-memory recovery facade unless
    # a crash-replay test explicitly sets recovery_force_ready: false.
    force_ready? =
      case Keyword.fetch(opts, :recovery_force_ready) do
        {:ok, value} -> value == true
        :error -> Mix.env() == :test
      end

    if Mix.env() == :test and
         recovery_facade == Arbor.Agent.Orchestration.TaskControlRecoveryMemory do
      _ = Arbor.Agent.Orchestration.TaskControlRecoveryMemory.ensure!()
    end

    durable? = recovery_facade_durable?(recovery_facade)
    production_recovery? = production_recovery_facade?(recovery_facade)

    # Phase 4C C2A fence-seed readiness. fence_force_ready is a TEST-ONLY seam:
    # it can never bypass production startup seeding. Unrelated test stores are
    # fence-ready by default (no facade call, no seeding); only explicit seed
    # tests set :fence_force_ready false. Production always seeds via the worker.
    fence_force_ready? = fence_force_ready?(opts)
    runtime_admission_force_ready? = runtime_admission_force_ready?(opts)

    runtime_admission_supervisor =
      Keyword.get(opts, :runtime_admission_supervisor, @default_runtime_admission_supervisor)

    store_ref = Keyword.get(opts, :name, @default_name)

    state = %{
      task_supervisor: task_supervisor,
      cleanup_supervisor: cleanup_supervisor,
      # Stable registered name for launchers/owners (never capture self() pid).
      store_ref: store_ref,
      runtime_admission_supervisor: runtime_admission_supervisor,
      runtime_admission_ready?: runtime_admission_force_ready?,
      runtime_admission_intents: %{},
      runtime_admission_by_id: %{},
      runtime_admission_waiters: %{},
      runtime_admission_waiter_by_mon: %{},
      runtime_admission_waiter_by_deadline: %{},
      # Fresh init is already on the current waiter schema — skip one-time migrate.
      runtime_admission_waiter_schema_v: @runtime_admission_waiter_schema_v,
      runtime_admission_owner_monitors: %{},
      runtime_admission_worker_monitors: %{},
      runtime_admission_launcher_monitors: %{},
      runtime_admission_operation_launches: %{},
      runtime_admission_operation_launcher_monitors: %{},
      runtime_admission_pending_opts: %{},
      runtime_admission_settle_timers: %{},
      # Pending async witness observations / durable mark shells (ref => meta).
      runtime_admission_pending_observe: %{},
      runtime_admission_observe_monitors: %{},
      runtime_admission_pending_durable_mark: %{},
      runtime_admission_durable_mark_monitors: %{},
      # target => %{intent_id, token, status, attempt, last_error} — no secrets in logs/status.
      runtime_admission_durable_mark_progress: %{},
      runtime_admission_pending_durable_settle: %{},
      runtime_admission_durable_settle_monitors: %{},
      runtime_admission_durable_settle_progress: %{},
      # intent_id => settlement reply deferred until durable reobservation
      runtime_admission_deferred_waiter_reply: %{},
      # Pre-handoff claim-join recovery: ref=>meta (pid/mon/timer), mon=>ref, target progress.
      runtime_admission_pending_claim_join: %{},
      runtime_admission_claim_join_monitors: %{},
      runtime_admission_claim_join_progress: %{},
      runtime_admission_reconcile: %{status: :pending},
      max_runtime_admission_waiters: normalize_max_runtime_admission_waiters(opts),
      max_runtime_admission_intents:
        Keyword.get(opts, :max_runtime_admission_intents, @default_max_runtime_admission_intents),
      runtime_admission_admit_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_admit_timeout_ms,
          @default_runtime_admission_admit_timeout_ms
        ),
      runtime_admission_settle_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_settle_timeout_ms,
          @default_runtime_admission_settle_timeout_ms
        ),
      runtime_admission_reconcile_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_reconcile_timeout_ms,
          @default_runtime_admission_reconcile_timeout_ms
        ),
      runtime_admission_observe_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_observe_timeout_ms,
          @default_runtime_admission_observe_timeout_ms
        ),
      runtime_admission_claim_join_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_claim_join_timeout_ms,
          @default_runtime_admission_claim_join_timeout_ms
        ),
      runtime_admission_durable_op_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_durable_op_timeout_ms,
          @default_runtime_admission_durable_op_timeout_ms
        ),
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
      # Lease revoke transport pinned at store start (not per-dispatch).
      task_control_security_module: task_control_security_module,
      task_control_revoke: task_control_revoke,
      # Recovery facade/store pinned at store start only.
      task_control_recovery_facade: recovery_facade,
      task_control_recovery_store: recovery_store,
      task_id_generator: task_id_generator,
      # cache-only/unbacked facades fail closed: never recovery_durable? true.
      recovery_durable?: durable?,
      recovery_ready?: force_ready? and durable? and not production_recovery?,
      recovery_replay: %{phase: :pending, cursor: [], failures: 0, deadline_mono: 0},
      # Phase 4C C2A: operation-owned per-target dispatch fence. The production
      # seed facade and worker supervisor are fixed at init; per-target fence
      # readiness is independent of recovery readiness. Public recovery_ready?/1
      # is the conjunction of both.
      template_authority_fence_facade: fence_facade,
      target_fences: %{},
      target_fence_ready?: fence_force_ready?,
      fence_seed: %{status: :pending},
      fence_seed_admit_timeout_ms:
        Keyword.get(
          opts,
          :fence_seed_admit_timeout_ms,
          @default_fence_seed_admit_timeout_ms
        ),
      fence_seed_worker_timeout_ms:
        Keyword.get(
          opts,
          :fence_seed_worker_timeout_ms,
          @default_fence_seed_worker_timeout_ms
        ),
      reservations: %{},
      reservation_monitor_index: %{},
      recovery_pending: %{},
      recovery_ops: %{},
      recovery_task_index: %{},
      recovery_monitor_index: %{},
      recovery_retry_base_ms:
        Keyword.get(opts, :recovery_retry_base_ms, @default_recovery_retry_base_ms),
      recovery_retry_max_ms:
        Keyword.get(opts, :recovery_retry_max_ms, @default_recovery_retry_max_ms),
      recovery_max_retries:
        Keyword.get(opts, :recovery_max_retries, @default_recovery_max_retries),
      max_recovery_obligations:
        Keyword.get(opts, :max_recovery_obligations, @default_max_recovery_obligations),
      max_reservations: Keyword.get(opts, :max_reservations, @default_max_reservations),
      reservation_deadline_ms:
        Keyword.get(opts, :reservation_deadline_ms, @default_reservation_deadline_ms),
      recovery_admit_timeout_ms:
        Keyword.get(opts, :recovery_admit_timeout_ms, @default_recovery_admit_timeout_ms),
      recovery_worker_timeout_ms:
        Keyword.get(opts, :recovery_worker_timeout_ms, @default_recovery_worker_timeout_ms),
      recovery_replay_batch:
        Keyword.get(opts, :recovery_replay_batch, @default_recovery_replay_batch),
      # Lease retirement reconciliation (volatile; not durable).
      lease_pending_retirement: %{},
      lease_retire_attempts: %{},
      lease_retire_task_index: %{},
      lease_retire_monitor_index: %{},
      lease_retire_admit_timeout_ms:
        Keyword.get(opts, :lease_retire_admit_timeout_ms, @default_lease_retire_admit_timeout_ms),
      lease_retire_worker_timeout_ms:
        Keyword.get(
          opts,
          :lease_retire_worker_timeout_ms,
          @default_lease_retire_worker_timeout_ms
        ),
      lease_retire_base_delay_ms:
        Keyword.get(opts, :lease_retire_base_delay_ms, @default_lease_retire_base_delay_ms),
      lease_retire_max_delay_ms:
        Keyword.get(opts, :lease_retire_max_delay_ms, @default_lease_retire_max_delay_ms),
      lease_retire_max_attempts:
        Keyword.get(opts, :lease_retire_max_attempts, @default_lease_retire_max_attempts),
      lease_retire_max_retrigger_rounds:
        Keyword.get(
          opts,
          :lease_retire_max_retrigger_rounds,
          @default_lease_retire_max_retrigger_rounds
        ),
      max_tasks: Keyword.get(opts, :max_tasks, @default_max_tasks),
      executor_callback_timeout_ms:
        Keyword.get(opts, :executor_callback_timeout_ms, Config.executor_callback_timeout_ms()),
      executor_finalization_timeout_ms:
        Keyword.get(
          opts,
          :executor_finalization_timeout_ms,
          Config.executor_finalization_timeout_ms()
        ),
      adoption_timeout_ms:
        opts
        |> Keyword.get(:adoption_timeout_ms, @default_adoption_timeout_ms)
        |> validate_adoption_timeout!(),
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
      refs: %{},
      adoptions: %{},
      adoption_refs: %{}
    }

    cond do
      force_ready? and durable? and not production_recovery? ->
        state = maybe_begin_runtime_admission_reconcile(state)
        {:ok, state}

      durable? ->
        {:ok, state, {:continue, :start_recovery_replay}}

      true ->
        # Fail closed: no cache-only recovery path can admit reserves/markers.
        state = %{state | recovery_durable?: false, recovery_ready?: false}
        state = maybe_begin_runtime_admission_reconcile(state)
        {:ok, state}
    end
  end

  @impl true
  def handle_continue(:start_recovery_replay, state) do
    state = ensure_recovery_shape(state)
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)
    state = begin_recovery_op(state, :replay_batch, nil, nil, nil)
    state = maybe_begin_fence_seed(state)
    state = maybe_begin_runtime_admission_reconcile(state)
    {:noreply, state}
  end

  def handle_continue(:retry_fence_seed, state) do
    state = ensure_fence_shape(state)

    if state.target_fence_ready? == true do
      {:noreply, state}
    else
      {:noreply, maybe_begin_fence_seed(state)}
    end
  end

  def handle_continue(:retry_recovery_replay, state) do
    state = ensure_recovery_shape(state)

    if state.recovery_ready? do
      {:noreply, state}
    else
      {:noreply, begin_recovery_op(state, :replay_batch, nil, nil, nil)}
    end
  end

  # OTP inspection / crash reports must never expose restore_token, fingerprint
  # (including prefixes), operation/durable Record identity, PIDs, refs,
  # capabilities, callbacks, or private claim payloads (C3C1a1 no-secret-status).
  # Fail closed on every input shape — never return the original status unchanged
  # (OTP may otherwise fall back to raw crash state with secrets).
  @impl true
  def format_status(status) do
    try do
      case status do
        %{state: state} when is_map(state) ->
          status
          |> Map.put(:state, project_public_status(state))
          |> Map.put(:message, :redacted)
          |> Map.put(:log, :redacted)
          |> Map.put(:reason, :redacted)
          |> drop_unknown_status_fields()

        _ ->
          closed_redacted_status()
      end
    rescue
      _ -> closed_redacted_status()
    catch
      kind, _ when kind in [:exit, :throw, :error] -> closed_redacted_status()
    end
  end

  defp closed_redacted_status do
    %{
      state: closed_public_status_skeleton(),
      message: :redacted,
      log: :redacted,
      reason: :redacted
    }
  end

  defp drop_unknown_status_fields(status) when is_map(status) do
    Map.take(status, [:state, :message, :log, :reason])
  end

  defp drop_unknown_status_fields(_), do: closed_redacted_status()

  defp closed_public_status_skeleton do
    %{
      runtime_admission: %{
        ready?: false,
        intent_count: 0,
        waiter_count: 0,
        phase_counts: %{},
        kind_counts: %{},
        pending_observe_count: 0,
        pending_durable_mark_count: 0,
        durable_mark_progress_count: 0,
        pending_claim_join_count: 0,
        claim_join_progress_count: 0,
        owner_monitor_count: 0,
        worker_monitor_count: 0,
        launcher_monitor_count: 0,
        operation_launcher_count: 0,
        settle_timer_count: 0,
        pending_opts_count: 0,
        pending_durable_settle_count: 0
      },
      fence: %{ready?: false, fence_count: 0},
      recovery: %{ready?: false},
      tasks: %{count: 0}
    }
  end

  @impl true
  def handle_call(:recovery_ready?, _from, state) do
    state = ensure_recovery_shape(state)
    state = ensure_fence_shape(state)
    # Public readiness is the conjunction of recovery replay and fence-seed
    # readiness: dispatch admission requires both before it can proceed.
    {:reply, state.recovery_ready? == true and state.target_fence_ready? == true, state}
  end

  def handle_call({:reserve, target_agent_id, _opts}, {owner_pid, _}, state)
      when is_pid(owner_pid) do
    state = ensure_recovery_shape(state)
    state = ensure_lease_retirement_shape(state)
    state = ensure_fence_shape(state)

    case validate_fence_target(target_agent_id) do
      {:ok, target} -> reserve_for_target(state, target, owner_pid)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:commit_recovery_marker, task_id, token}, from, state) do
    state = ensure_recovery_shape(state)
    {owner_pid, _} = from

    cond do
      state.recovery_durable? != true ->
        {:reply, {:error, :recovery_durability_unavailable}, state}

      state.recovery_ready? != true ->
        {:reply, {:error, :recovery_not_ready}, state}

      true ->
        case authorize_reservation(state, task_id, token, owner_pid) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          {:ok, reservation} ->
            case TaskControlLease.marker_new(task_id, DateTime.utc_now()) do
              {:error, reason} ->
                {:reply, {:error, reason}, state}

              {:ok, marker} ->
                state =
                  begin_recovery_op(state, :marker_put, task_id, from, marker,
                    expected_token_hash: reservation.token_hash
                  )

                {:noreply, state}
            end
        end
    end
  end

  def handle_call(
        {:activate, agent_id, task, task_id, token, opts},
        {owner_pid, _} = _from,
        state
      ) do
    state = ensure_recovery_shape(state)
    state = ensure_fence_shape(state)

    cond do
      state.recovery_ready? != true ->
        {:reply, {:error, :recovery_not_ready}, state}

      state.target_fence_ready? != true ->
        {:reply, {:error, :fence_not_ready}, state}

      true ->
        case authorize_reservation(state, task_id, token, owner_pid) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          {:ok, reservation} ->
            activate_reservation(state, reservation, agent_id, task, task_id, opts)
        end
    end
  end

  def handle_call({:release, task_id, token}, from, state) do
    state = ensure_recovery_shape(state)
    {owner_pid, _} = from

    case authorize_reservation(state, task_id, token, owner_pid) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, reservation} ->
        marker_written? = reservation.marker_written? == true
        state = drop_reservation(state, task_id, reservation)

        if marker_written? do
          state =
            put_recovery_pending(state, task_id, :release, true)

          state = begin_recovery_op(state, :reconcile_task, task_id, from, nil)
          {:noreply, state}
        else
          {:reply, :ok, state}
        end
    end
  end

  def handle_call({:request_reconcile, task_id}, from, state) when is_binary(task_id) do
    state = ensure_recovery_shape(state)
    state = put_recovery_pending(state, task_id, :reconcile_request, true)
    state = begin_recovery_op(state, :reconcile_task, task_id, from, nil)
    {:noreply, state}
  end

  def handle_call({:dispatch, agent_id, task, opts}, _from, state) do
    state = ensure_recovery_shape(state)
    state = ensure_fence_shape(state)

    # Validate the target before any fence lookup. A malformed target fails
    # closed with the bounded error and starts no runner.
    case validate_fence_target(agent_id) do
      {:ok, target} -> dispatch_to_target(state, target, task, opts)
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    e ->
      {:reply, {:error, {:dispatch_failed, Exception.message(e)}}, state}
  catch
    :exit, reason ->
      {:reply, {:error, {:dispatch_exit, reason}}, state}
  end

  def handle_call(
        {:install_target_fence, target_agent_id, operation_id},
        _from,
        state
      ) do
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)

    # Fail closed until BOTH fence seed and runtime-admission/claim inventory
    # are ready — otherwise barrier counts undercount surviving intents and a
    # fence can be installed before durable guarded claims are materialized.
    cond do
      state.target_fence_ready? != true ->
        {:reply, {:error, :fence_not_ready}, state}

      state.runtime_admission_ready? != true ->
        {:reply, {:error, :runtime_admission_not_ready}, state}

      true ->
        with {:ok, target} <- validate_fence_target(target_agent_id),
             {:ok, op} <- validate_fence_operation_id(operation_id) do
          case Map.get(state.target_fences, target) do
            ^op ->
              {:reply, {:ok, barrier_counts(state, target)}, state}

            nil ->
              state = put_in(state, [:target_fences, target], op)
              {:reply, {:ok, barrier_counts(state, target)}, state}

            _other_owner ->
              {:reply, {:error, :target_fenced}, state}
          end
        else
          {:error, _reason} = error -> {:reply, error, state}
        end
    end
  end

  def handle_call(
        {:remove_target_fence, target_agent_id, operation_id},
        _from,
        state
      ) do
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)

    cond do
      state.target_fence_ready? != true ->
        {:reply, {:error, :fence_not_ready}, state}

      state.runtime_admission_ready? != true ->
        {:reply, {:error, :runtime_admission_not_ready}, state}

      true ->
        with {:ok, target} <- validate_fence_target(target_agent_id),
             {:ok, op} <- validate_fence_operation_id(operation_id) do
          case Map.get(state.target_fences, target) do
            ^op ->
              if fence_held_by_restore?(state, target) do
                # Live intent OR durable mark/settle/join convergence outstanding.
                {:reply, {:error, :fence_held_by_restore}, state}
              else
                state = put_in(state, [:target_fences], Map.delete(state.target_fences, target))
                {:reply, :ok, state}
              end

            nil ->
              {:reply, {:error, :not_found}, state}

            _other_owner ->
              {:reply, {:error, :target_fenced}, state}
          end
        else
          {:error, _reason} = error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:target_fenced?, target_agent_id}, _from, state) do
    state = ensure_fence_shape(state)

    reply =
      with {:ok, target} <- validate_fence_target(target_agent_id),
           :ok <- ensure_fence_seed_ready(state) do
        {:ok, Map.has_key?(state.target_fences, target)}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:verify_target_fence, target_agent_id, operation_id},
        _from,
        state
      ) do
    state = ensure_fence_shape(state)

    reply =
      with {:ok, target} <- validate_fence_target(target_agent_id),
           {:ok, op} <- validate_fence_operation_id(operation_id),
           :ok <- ensure_fence_seed_ready(state) do
        case Map.get(state.target_fences, target) do
          ^op -> :ok
          nil -> {:error, :target_not_fenced}
          _other_owner -> {:error, :not_owner}
        end
      end

    {:reply, reply, state}
  end

  def handle_call(:runtime_admission_ready?, _from, state) do
    state = ensure_runtime_admission_shape(state)
    {:reply, state.runtime_admission_ready? == true, state}
  end

  def handle_call(
        {:admit_ordinary_runtime_start, target_agent_id, fingerprint, validated_opts, wait_ms},
        from,
        state
      ) do
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)
    # Clamp raw 5-tuple wait_ms inside the store (never trust unclamped caller data).
    wait_ms = clamp_runtime_admission_waiter_deadline_ms(wait_ms)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        do_admit_ordinary_runtime_start(
          state,
          target,
          fingerprint,
          validated_opts,
          from,
          wait_ms
        )

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  # Pre-F-575 call shape (no wait_ms): treat as default deadline for hot-code compat.
  def handle_call(
        {:admit_ordinary_runtime_start, target_agent_id, fingerprint, validated_opts},
        from,
        state
      ) do
    handle_call(
      {:admit_ordinary_runtime_start, target_agent_id, fingerprint, validated_opts,
       @default_runtime_admission_waiter_deadline_ms},
      from,
      state
    )
  end

  def handle_call(
        {:admit_guarded_runtime_restore, target_agent_id, operation_id, restore_token, wait_ms},
        from,
        state
      ) do
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)
    wait_ms = clamp_runtime_admission_waiter_deadline_ms(wait_ms)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        do_admit_guarded_runtime_restore(
          state,
          target,
          operation_id,
          restore_token,
          from,
          wait_ms
        )

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:ack_guarded_restore_effect_handoff, target_agent_id, intent_id, fingerprint},
        {caller_pid, _tag},
        state
      )
      when is_pid(caller_pid) do
    state = ensure_runtime_admission_shape(state)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        case IntentCore.ack_effect_handoff(
               state.runtime_admission_intents,
               target,
               intent_id,
               fingerprint,
               caller_pid
             ) do
          {:ok, intents} ->
            {:reply, :ok, put_in(state, [:runtime_admission_intents], intents)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:bind_runtime_admission_launch, target_agent_id, intent_id, fingerprint, launch_ref},
        {caller_pid, _tag},
        state
      )
      when is_pid(caller_pid) and is_reference(launch_ref) do
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        case IntentCore.bind_launch_owner(
               state.runtime_admission_intents,
               target,
               intent_id,
               fingerprint,
               launch_ref,
               caller_pid
             ) do
          {:ok, _intent, intents} ->
            state =
              state
              |> put_in([:runtime_admission_intents], intents)
              |> clear_launcher_monitor_for_intent(intent_id, target)
              |> ensure_owner_monitor(intent_id, target, caller_pid)
              |> update_in([:runtime_admission_pending_opts], &Map.delete(&1, intent_id))

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:adopt_runtime_admission_owner, target_agent_id, intent_id, fingerprint},
        {caller_pid, _tag} = _from,
        state
      )
      when is_pid(caller_pid) do
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)

    # Caller must already be the launch-bound or restart-rebound owner_pid.
    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        case IntentCore.adopt_owner(
               state.runtime_admission_intents,
               state.target_fences,
               state.target_fence_ready? == true,
               state.runtime_admission_ready? == true,
               target,
               intent_id,
               fingerprint,
               caller_pid
             ) do
          {:ok, :adopted, _intent, intents} ->
            state =
              state
              |> put_in([:runtime_admission_intents], intents)
              |> put_in([:runtime_admission_by_id, intent_id], target)
              |> ensure_owner_monitor(intent_id, target, caller_pid)

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:bind_runtime_admission_worker, target_agent_id, intent_id, fingerprint, worker_pid},
        {caller_pid, _tag},
        state
      )
      when is_pid(caller_pid) and is_pid(worker_pid) do
    state = ensure_runtime_admission_shape(state)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        prev = Map.get(state.runtime_admission_intents, target)

        case IntentCore.bind_worker(
               state.runtime_admission_intents,
               target,
               intent_id,
               fingerprint,
               caller_pid,
               worker_pid
             ) do
          {:ok, intents} ->
            already_monitored? =
              is_map(prev) and prev.worker_pid == worker_pid and prev.phase == :worker_running

            state = put_in(state, [:runtime_admission_intents], intents)

            state =
              if already_monitored? do
                state
              else
                mon = Process.monitor(worker_pid)

                put_in(
                  state,
                  [:runtime_admission_worker_monitors, mon],
                  {intent_id, target, worker_pid}
                )
              end

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:authenticate_runtime_admission_worker, target_agent_id, intent_id, fingerprint},
        {caller_pid, _tag},
        state
      )
      when is_pid(caller_pid) do
    state = ensure_runtime_admission_shape(state)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        reply =
          IntentCore.authenticate_worker(
            state.runtime_admission_intents,
            target,
            intent_id,
            fingerprint,
            caller_pid
          )

        case reply do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:settle_runtime_admission, target_agent_id, intent_id, outcome},
        {caller_pid, _tag},
        state
      )
      when is_pid(caller_pid) do
    state = ensure_runtime_admission_shape(state)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        # Snapshot identity before settle may finalize/delete the intent row.
        pre_intent = Map.get(state.runtime_admission_intents, target)

        case authorize_and_settle_runtime_admission(
               state,
               target,
               intent_id,
               outcome,
               caller_pid
             ) do
          {:ok, new_state} ->
            # W9: close crash-after-accept / before-durable-settle. Fixed shell
            # converges durable claim from source-auth terminal + exact branch
            # observation; does not depend on the worker surviving.
            new_state =
              maybe_launch_guarded_durable_settle_after_accept(
                new_state,
                pre_intent,
                intent_id,
                outcome
              )

            {:reply, :ok, new_state}

          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:status, task_id}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        {:reply, {:ok, project_status(record, state)}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:inventory, filters, max_items}, _from, state) do
    cond do
      not is_integer(max_items) or max_items <= 0 or max_items > state.max_tasks ->
        {:reply, {:error, :invalid_task_inventory_options}, state}

      true ->
        owner_statuses = owner_statuses(state.tasks)

        inventory =
          TaskInventoryProjection.from_state(state, filters, max_items, owner_statuses)

        {:reply, {:ok, inventory}, state}
    end
  rescue
    _ -> {:reply, {:error, :task_inventory_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :task_inventory_unavailable}, state}
  end

  # Inventory messages are data-only. Reject legacy/forged selector-bearing
  # shapes without inspecting or executing the supplied fourth term.
  def handle_call({:inventory, _filters, _max_items, _selector}, _from, state) do
    {:reply, {:error, :invalid_task_inventory_message}, state}
  end

  def handle_call({:result, task_id}, _from, state) do
    reply =
      case Map.fetch(state.tasks, task_id) do
        {:ok, %{state: :done, result: result}} ->
          {:ok, result}

        {:ok, %{state: state, terminal_envelope: envelope}}
        when state in [:failed, :cancelled] and is_map(envelope) ->
          {:ok, envelope}

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

  def handle_call(:retrigger_exhausted_lease_retirements, _from, state) do
    state = ensure_lease_retirement_shape(state)
    {state, reply} = do_retrigger_exhausted_lease_retirements(state)
    {:reply, {:ok, reply}, state}
  end

  def handle_call(:lease_retirement_snapshot, _from, state) do
    state = ensure_lease_retirement_shape(state)
    {:reply, {:ok, redacted_lease_retirement_snapshot(state)}, state}
  end

  def handle_call({:adoption_status, task_id, destination_ref}, _from, state) do
    state = ensure_adoption_state_shape(state)

    reply =
      case normalize_adoption_request(destination_ref) do
        {:ok, %{"destination_ref" => ^destination_ref}} ->
          adoption_status_reply(state, task_id, destination_ref)

        _invalid ->
          {:error, :invalid_destination_ref}
      end

    {:reply, reply, state}
  end

  def handle_call({:adopt, task_id, destination_ref}, from, state) do
    deadline_ms = System.monotonic_time(:millisecond) + @default_adoption_wait_timeout_ms
    handle_call({:adopt, task_id, destination_ref, deadline_ms}, from, state)
  end

  def handle_call({:adopt, task_id, destination_ref, deadline_ms}, from, state) do
    state = ensure_adoption_state_shape(state)

    cond do
      adoption_deadline_expired?(deadline_ms) ->
        {:reply, {:error, :task_adoption_wait_timeout}, state}

      true ->
        case begin_adoption(state, task_id, destination_ref, from) do
          {:wait, next_state} -> {:noreply, next_state}
          {:reply, reply, next_state} -> {:reply, reply, next_state}
        end
    end
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
          |> maybe_finalize_terminal(:task_cancelled, state)

        # Publish terminal state before any Security.revoke I/O.
        {cancelled_record, retire_spec} =
          plan_lease_retire(cancelled_record, :terminal_revoke_set)

        next_state =
          state
          |> put_in([:tasks, task_id], cancelled_record)
          |> remove_ref(record.ref)

        next_state = accept_retire_spec(next_state, retire_spec)

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

  defp reserve_for_target(state, target, owner_pid) do
    cond do
      state.recovery_durable? != true ->
        {:reply, {:error, :recovery_durability_unavailable}, state}

      state.recovery_ready? != true ->
        {:reply, {:error, :recovery_not_ready}, state}

      state.target_fence_ready? != true ->
        {:reply, {:error, :fence_not_ready}, state}

      Map.has_key?(state.target_fences, target) ->
        {:reply, {:error, :target_fenced}, state}

      true ->
        create_target_reservation(state, target, owner_pid)
    end
  end

  defp create_target_reservation(state, target, owner_pid) do
    with :ok <- admit_new_reservation(state),
         {:ok, task_id} <- generate_unique_task_id(state) do
      token = TaskControlLease.generate_reservation_token()
      token_hash = TaskControlLease.token_hash(token)
      owner_mon = Process.monitor(owner_pid)

      deadline_ms =
        Map.get(state, :reservation_deadline_ms, @default_reservation_deadline_ms)

      deadline_timer =
        Process.send_after(self(), {:reservation_deadline, task_id}, deadline_ms)

      reservation = %{
        task_id: task_id,
        target_agent_id: target,
        token_hash: token_hash,
        owner_pid: owner_pid,
        owner_mon: owner_mon,
        deadline_timer: deadline_timer,
        marker_written?: false,
        inserted_at: DateTime.utc_now()
      }

      state =
        state
        |> put_in([:reservations, task_id], reservation)
        |> put_in([:reservation_monitor_index, owner_mon], task_id)

      {:reply, {:ok, %{task_id: task_id, reservation_token: token}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp activate_reservation(state, reservation, agent_id, task, task_id, opts) do
    # Target re-compare: activation must match the reservation's bound target.
    # Legacy reservations with missing or invalid targets fail closed without
    # being consumed or retargeted.
    reservation_target = Map.get(reservation, :target_agent_id)

    with {:ok, target} <-
           validate_reservation_activation_target(agent_id, reservation_target),
         :ok <- ensure_target_unfenced(state, target),
         opts = Keyword.put(opts, :task_id, task_id),
         :ok <- ensure_recovery_marker(reservation, opts),
         {:ok, admitted_task_id, next_state} <-
           do_admit_task(state, target, task, task_id, opts) do
      next_state = drop_reservation(next_state, admitted_task_id, reservation)
      {:reply, {:ok, admitted_task_id}, next_state}
    else
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ensure_target_unfenced(state, target) do
    if Map.has_key?(state.target_fences, target),
      do: {:error, :target_fenced},
      else: :ok
  end

  defp ensure_fence_seed_ready(state) do
    if state.target_fence_ready? == true,
      do: :ok,
      else: {:error, :fence_not_ready}
  end

  defp ensure_recovery_marker(reservation, opts) do
    lease = Keyword.get(opts, :task_control_lease)

    if not is_nil(lease) and Map.get(reservation, :marker_written?) != true,
      do: {:error, :recovery_marker_required},
      else: :ok
  end

  defp dispatch_to_target(state, target, task, opts) do
    cond do
      # Dispatch admission requires both task-control recovery readiness and
      # fence-seed readiness; no runner may start while either gate is closed.
      state.recovery_ready? != true ->
        {:reply, {:error, :recovery_not_ready}, state}

      state.target_fence_ready? != true ->
        {:reply, {:error, :fence_not_ready}, state}

      Map.has_key?(state.target_fences, target) ->
        {:reply, {:error, :target_fenced}, state}

      true ->
        task_id = task_id(opts)

        case do_admit_task(state, target, task, task_id, opts) do
          {:ok, task_id, next_state} -> {:reply, {:ok, task_id}, next_state}
          {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
        end
    end
  end

  defp do_admit_task(state, agent_id, task, task_id, opts) do
    with {:ok, lease} <-
           admit_task_control_lease(Keyword.get(opts, :task_control_lease), task_id),
         {:ok, runner, context_mode, dispatch_task, runner_context} <-
           prepare_dispatch(task, opts, state, task_id) do
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
        terminal_envelope: nil,
        terminal_finalized: false,
        pid: task_ref.pid,
        ref: task_ref.ref,
        started_at: now,
        updated_at: now,
        completed_at: nil,
        metadata: metadata(opts),
        executor: runner,
        context_mode: context_mode,
        context: runner_context,
        # Closed scalar lease only — Security module / revoke funs are store-pinned.
        # New records must not create legacy per-kind cap cleanup fields.
        task_control_lease: lease,
        recovery_marker?: true,
        adoption_destination_ref: nil,
        adoption_last_error: nil,
        # Closed scalar only — executable keys are never retained on the record.
        approval_cleanup_descriptor:
          normalize_approval_cleanup_descriptor(Keyword.get(opts, :approval_cleanup_descriptor)),
        controls: [],
        control_retries: %{},
        accepted_control_ids: MapSet.new(),
        confirmation_retries: %{},
        queued_confirmations: %{},
        replay_counts: %{},
        cancel_turn: Keyword.get(opts, :cancel_turn)
      }

      next_state =
        state
        |> put_in([:tasks, task_id], record)
        |> put_in([:refs, task_ref.ref], task_id)
        |> prune_tasks()

      {:ok, task_id, next_state}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    state = ensure_adoption_state_shape(state)

    case Map.fetch(state.adoption_refs, ref) do
      {:ok, task_id} ->
        Process.demonitor(ref, [:flush])
        {:noreply, complete_adoption(state, task_id, ref, result)}

      :error ->
        Process.demonitor(ref, [:flush])

        case Map.fetch(state.refs, ref) do
          {:ok, task_id} ->
            {:noreply, complete_task(state, task_id, ref, result)}

          :error ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) when is_reference(ref) do
    state = ensure_adoption_state_shape(state)
    state = ensure_lease_retirement_shape(state)
    state = ensure_recovery_shape(state)
    state = ensure_runtime_admission_shape(state)

    {:noreply, handle_normal_down(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    state = ensure_adoption_state_shape(state)
    state = ensure_lease_retirement_shape(state)
    state = ensure_recovery_shape(state)
    state = ensure_runtime_admission_shape(state)

    {:noreply, handle_abnormal_down(state, ref, reason)}
  end

  def handle_info({:reservation_deadline, task_id}, state) when is_binary(task_id) do
    state = ensure_recovery_shape(state)

    case Map.get(state.reservations, task_id) do
      %{deadline_timer: _} = reservation ->
        {:noreply,
         handle_reservation_owner_down(state, task_id, reservation, :reservation_timeout)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:recovery_op_admitted, op_ref, worker_pid}, state)
      when is_reference(op_ref) and is_pid(worker_pid) do
    {:noreply, handle_recovery_op_admitted(state, op_ref, worker_pid)}
  end

  def handle_info({:recovery_op_admission_failed, op_ref, class}, state)
      when is_reference(op_ref) do
    {:noreply, handle_recovery_op_admission_failed(state, op_ref, class)}
  end

  def handle_info({:recovery_op_admit_timeout, op_ref}, state) when is_reference(op_ref) do
    {:noreply, handle_recovery_op_admit_timeout(state, op_ref)}
  end

  def handle_info({:recovery_op_worker_timeout, op_ref}, state) when is_reference(op_ref) do
    {:noreply, handle_recovery_op_worker_timeout(state, op_ref)}
  end

  def handle_info({:recovery_op_complete, op_ref, result}, state) when is_reference(op_ref) do
    {:noreply, handle_recovery_op_complete(state, op_ref, result)}
  end

  # Phase 4C C2A fence-seed worker messages. The durable inventory read
  # (list_outstanding/0) happens only inside the supervised worker, never in
  # this callback.
  def handle_info({:fence_seed_admitted, seed_ref, worker_pid}, state)
      when is_reference(seed_ref) and is_pid(worker_pid) do
    {:noreply, handle_fence_seed_admitted(state, seed_ref, worker_pid)}
  end

  def handle_info({:fence_seed_failed, seed_ref, class}, state)
      when is_reference(seed_ref) do
    {:noreply, handle_fence_seed_failed(state, seed_ref, class)}
  end

  def handle_info({:fence_seed_admit_timeout, seed_ref}, state) when is_reference(seed_ref) do
    {:noreply, handle_fence_seed_admit_timeout(state, seed_ref)}
  end

  def handle_info({:fence_seed_worker_timeout, seed_ref}, state)
      when is_reference(seed_ref) do
    {:noreply, handle_fence_seed_worker_timeout(state, seed_ref)}
  end

  def handle_info({:fence_seed_complete, seed_ref, result}, state)
      when is_reference(seed_ref) do
    {:noreply, handle_fence_seed_complete(state, seed_ref, result)}
  end

  def handle_info(:retry_fence_seed_msg, state) do
    state = ensure_fence_shape(state)

    if state.target_fence_ready? == true do
      {:noreply, state}
    else
      {:noreply, maybe_begin_fence_seed(state)}
    end
  end

  # Phase 4C C3C1a0 runtime-admission reconcile + owner launcher messages.
  def handle_info({:runtime_admission_reconcile_admitted, ref, worker_pid}, state)
      when is_reference(ref) and is_pid(worker_pid) do
    {:noreply, handle_runtime_admission_reconcile_admitted(state, ref, worker_pid)}
  end

  def handle_info({:runtime_admission_reconcile_failed, ref, class}, state)
      when is_reference(ref) do
    {:noreply, handle_runtime_admission_reconcile_failed(state, ref, class)}
  end

  def handle_info({:runtime_admission_reconcile_complete, ref, result}, state)
      when is_reference(ref) do
    {:noreply, handle_runtime_admission_reconcile_complete(state, ref, result)}
  end

  def handle_info({:runtime_admission_reconcile_timeout, ref}, state)
      when is_reference(ref) do
    {:noreply, handle_runtime_admission_reconcile_timeout(state, ref)}
  end

  def handle_info(:retry_runtime_admission_reconcile_msg, state) do
    state = ensure_runtime_admission_shape(state)

    if state.runtime_admission_ready? == true do
      {:noreply, state}
    else
      {:noreply, maybe_begin_runtime_admission_reconcile(state)}
    end
  end

  def handle_info(
        {:runtime_admission_owner_launched, launch_ref, intent_id, _owner_pid},
        state
      )
      when is_reference(launch_ref) and is_binary(intent_id) do
    # Bind happens in IntentOwner.init via authenticated call; success is inert.
    {:noreply, state}
  end

  def handle_info({:runtime_admission_owner_launched, _intent_id, _owner_pid}, state) do
    # Legacy unauthenticated success messages are inert.
    {:noreply, state}
  end

  def handle_info(
        {:runtime_admission_owner_launch_failed, launch_ref, intent_id, reason},
        state
      )
      when is_reference(launch_ref) and is_binary(intent_id) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_authenticated_launch_failure(state, launch_ref, intent_id, reason)}
  end

  def handle_info({:runtime_admission_owner_launch_failed, _intent_id, _reason}, state) do
    # Legacy plain intent_id-only failure is forgeable and must be inert.
    {:noreply, state}
  end

  def handle_info({:runtime_admission_settle_timeout, intent_id, gen}, state)
      when is_binary(intent_id) and is_integer(gen) do
    {:noreply, handle_runtime_admission_settle_timeout(state, intent_id, gen)}
  end

  def handle_info({:runtime_admission_waiter_timeout, deadline_token}, state)
      when is_reference(deadline_token) do
    {:noreply, handle_runtime_admission_waiter_timeout(state, deadline_token)}
  end

  def handle_info(
        {:runtime_admission_operation_admitted, launch_ref, operation_ref, worker_pid},
        state
      )
      when is_reference(launch_ref) and is_reference(operation_ref) and is_pid(worker_pid) do
    state = ensure_runtime_admission_shape(state)

    {:noreply,
     handle_runtime_admission_operation_admitted(
       state,
       launch_ref,
       operation_ref,
       worker_pid
     )}
  end

  def handle_info(
        {:runtime_admission_operation_launch_failed, launch_ref, operation_ref, reason},
        state
      )
      when is_reference(launch_ref) and is_reference(operation_ref) and is_atom(reason) do
    state = ensure_runtime_admission_shape(state)

    {:noreply,
     handle_runtime_admission_operation_launch_failed(
       state,
       launch_ref,
       operation_ref,
       reason
     )}
  end

  def handle_info({:runtime_admission_operation_launch_timeout, launch_ref}, state)
      when is_reference(launch_ref) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_operation_launch_timeout(state, launch_ref)}
  end

  def handle_info({:runtime_admission_witness_observed, observe_ref, observation}, state)
      when is_reference(observe_ref) and is_map(observation) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_witness_observed(state, observe_ref, observation)}
  end

  def handle_info({:runtime_admission_witness_observe_timeout, observe_ref}, state)
      when is_reference(observe_ref) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_witness_observe_timeout(state, observe_ref)}
  end

  def handle_info({:runtime_admission_durable_mark_done, mark_ref, result}, state)
      when is_reference(mark_ref) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_durable_mark_done(state, mark_ref, result)}
  end

  def handle_info({:runtime_admission_durable_mark_timeout, mark_ref}, state)
      when is_reference(mark_ref) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_durable_mark_timeout(state, mark_ref)}
  end

  def handle_info({:runtime_admission_durable_settle_done, settle_ref, result}, state)
      when is_reference(settle_ref) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_durable_settle_done(state, settle_ref, result)}
  end

  def handle_info({:runtime_admission_durable_settle_timeout, settle_ref}, state)
      when is_reference(settle_ref) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_durable_settle_timeout(state, settle_ref)}
  end

  def handle_info({:runtime_admission_claim_joined, join_ref, result}, state)
      when is_reference(join_ref) and is_map(result) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_claim_joined(state, join_ref, result)}
  end

  # Legacy atom-only complete (stale workers / hot upgrade) — inert fail-closed.
  def handle_info({:runtime_admission_claim_joined, join_ref, _classification}, state)
      when is_reference(join_ref) do
    {:noreply, state}
  end

  def handle_info({:runtime_admission_claim_join_timeout, join_ref}, state)
      when is_reference(join_ref) do
    state = ensure_runtime_admission_shape(state)
    {:noreply, handle_runtime_admission_claim_join_timeout(state, join_ref)}
  end

  def handle_info({:runtime_admission_claim_join_retry, request, attempt}, state)
      when is_map(request) and is_integer(attempt) and attempt >= 0 do
    state = ensure_runtime_admission_shape(state)

    if claim_join_retry_current?(state, request, attempt) do
      {:noreply, launch_durable_claim_join_observer(state, request, attempt)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:runtime_admission_durable_mark_retry, target, token, intent_id, attempt},
        state
      )
      when is_binary(target) and is_binary(token) and is_binary(intent_id) and is_integer(attempt) do
    state = ensure_runtime_admission_shape(state)

    if durable_mark_retry_current?(state, target, token, intent_id, attempt) do
      {:ok, intent} = current_durable_mark_intent(state, target, token, intent_id)
      {:noreply, launch_durable_mark_outcome_unknown(state, intent, attempt)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:runtime_admission_durable_settle_retry, request, attempt},
        state
      )
      when is_map(request) and is_integer(attempt) do
    state = ensure_runtime_admission_shape(state)

    if durable_settle_retry_current?(state, request, attempt) do
      {:noreply, launch_guarded_durable_settle_shell(state, request, attempt)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:retry_recovery_replay_msg, state) do
    state = ensure_recovery_shape(state)

    if state.recovery_ready? do
      {:noreply, state}
    else
      {:noreply, begin_recovery_op(state, :replay_batch, nil, nil, nil)}
    end
  end

  def handle_info({:recovery_pending_retry, task_id}, state) when is_binary(task_id) do
    state = ensure_recovery_shape(state)

    case Map.get(Map.get(state, :recovery_pending, %{}), task_id) do
      nil ->
        {:noreply, state}

      pending ->
        pending = %{pending | retry_timer: nil}
        state = put_in(state.recovery_pending[task_id], pending)

        if Map.has_key?(Map.get(state, :recovery_task_index, %{}), task_id) do
          {:noreply, state}
        else
          {:noreply, begin_recovery_op(state, :reconcile_task, task_id, nil, nil)}
        end
    end
  end

  def handle_info({:adoption_timeout, task_id, ref}, state) when is_reference(ref) do
    state = ensure_adoption_state_shape(state)

    case Map.get(state.adoptions, task_id) do
      %{task: %Task{ref: ^ref, pid: pid} = task} when is_pid(pid) ->
        case Task.yield(task, 0) do
          {:ok, result} ->
            {:noreply, complete_adoption(state, task_id, ref, result)}

          {:exit, _reason} ->
            {:noreply, fail_adoption(state, task_id, ref, {:error, :executor_callback_exit})}

          nil ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)
            Process.demonitor(ref, [:flush])

            {:noreply, fail_adoption(state, task_id, ref, {:error, :executor_callback_timeout})}
        end

      _other ->
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

  def handle_info({:lease_retire_admitted, attempt_ref, worker_pid}, state)
      when is_reference(attempt_ref) and is_pid(worker_pid) do
    {:noreply, handle_lease_retire_admitted(state, attempt_ref, worker_pid)}
  end

  def handle_info({:lease_retire_admission_failed, attempt_ref, class}, state)
      when is_reference(attempt_ref) do
    {:noreply, handle_lease_retire_admission_failed(state, attempt_ref, class)}
  end

  def handle_info({:lease_retire_admit_timeout, attempt_ref}, state)
      when is_reference(attempt_ref) do
    {:noreply, handle_lease_retire_admit_timeout(state, attempt_ref)}
  end

  def handle_info({:lease_retire_worker_timeout, attempt_ref}, state)
      when is_reference(attempt_ref) do
    {:noreply, handle_lease_retire_worker_timeout(state, attempt_ref)}
  end

  def handle_info({:lease_retire_complete, attempt_ref, results}, state)
      when is_reference(attempt_ref) do
    {:noreply, handle_lease_retire_complete(state, attempt_ref, results)}
  end

  def handle_info({:lease_retire_retry, attempt_ref}, state) when is_reference(attempt_ref) do
    {:noreply, handle_lease_retire_retry(state, attempt_ref)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> Map.get(:adoptions, %{})
    |> Map.values()
    |> Enum.each(fn
      %{task: %Task{pid: pid}} when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)

      _other ->
        :ok
    end)

    :ok
  end

  defp handle_normal_down(state, ref) do
    case classify_monitored_ref(state, ref) do
      {:lease_launcher, attempt_ref, attempt} ->
        handle_lease_retire_launcher_down(state, attempt_ref, attempt)

      {:lease_worker, attempt_ref, attempt} ->
        handle_lease_retire_worker_down(state, attempt_ref, attempt, :normal)

      {:recovery_launcher, op_ref, op} ->
        handle_recovery_launcher_down(state, op_ref, op)

      {:recovery_worker, op_ref, op} ->
        handle_recovery_worker_down(state, op_ref, op, :normal)

      {:fence_launcher, seed} ->
        handle_fence_seed_launcher_down(state, seed, :normal)

      {:fence_worker, seed} ->
        handle_fence_seed_worker_down(state, seed, :normal)

      {:runtime_admission, monitor} ->
        handle_runtime_admission_monitor_down(state, ref, monitor)

      {:reservation, task_id, reservation} ->
        handle_reservation_owner_down(state, task_id, reservation, :owner_down)

      {:adoption, task_id} ->
        fail_adoption(state, task_id, ref, {:error, :executor_callback_no_result})

      {:task, _task_id} ->
        remove_ref(state, ref)

      :error ->
        remove_ref(state, ref)
    end
  end

  defp handle_abnormal_down(state, ref, reason) do
    case classify_monitored_ref(state, ref) do
      {:lease_launcher, attempt_ref, attempt} ->
        handle_lease_retire_launcher_down(state, attempt_ref, attempt)

      {:lease_worker, attempt_ref, attempt} ->
        handle_lease_retire_worker_down(state, attempt_ref, attempt, reason)

      {:recovery_launcher, op_ref, op} ->
        handle_recovery_launcher_down(state, op_ref, op)

      {:recovery_worker, op_ref, op} ->
        handle_recovery_worker_down(state, op_ref, op, reason)

      {:fence_launcher, seed} ->
        handle_fence_seed_launcher_down(state, seed, reason)

      {:fence_worker, seed} ->
        handle_fence_seed_worker_down(state, seed, reason)

      {:runtime_admission, monitor} ->
        handle_runtime_admission_monitor_down(state, ref, monitor)

      {:reservation, task_id, reservation} ->
        handle_reservation_owner_down(state, task_id, reservation, :owner_down)

      {:adoption, task_id} ->
        fail_adoption(state, task_id, ref, {:error, :executor_callback_exit})

      {:task, task_id} ->
        now = DateTime.utc_now()
        {state, cleanup_job} = terminalize_abnormal_down(state, task_id, reason, now)
        state = launch_approval_cleanup_job(state, cleanup_job)
        remove_ref(state, ref)

      :error ->
        state
    end
  end

  defp classify_monitored_ref(state, ref) do
    case find_lease_retire_monitor(state, ref) do
      {:launcher, attempt_ref, attempt} -> {:lease_launcher, attempt_ref, attempt}
      {:worker, attempt_ref, attempt} -> {:lease_worker, attempt_ref, attempt}
      :error -> classify_recovery_monitor(state, ref)
    end
  end

  defp classify_recovery_monitor(state, ref) do
    case find_recovery_monitor(state, ref) do
      {:launcher, op_ref, op} -> {:recovery_launcher, op_ref, op}
      {:worker, op_ref, op} -> {:recovery_worker, op_ref, op}
      :error -> classify_fence_monitor(state, ref)
    end
  end

  defp classify_fence_monitor(state, ref) do
    case find_fence_seed_monitor(state, ref) do
      {:launcher, seed} -> {:fence_launcher, seed}
      {:worker, seed} -> {:fence_worker, seed}
      :error -> classify_runtime_admission_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_monitor(state, ref) do
    case Map.get(state.runtime_admission_owner_monitors, ref) do
      {intent_id, target, owner_pid} ->
        {:runtime_admission, {:owner, intent_id, target, owner_pid}}

      nil ->
        classify_runtime_admission_worker_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_worker_monitor(state, ref) do
    case Map.get(state.runtime_admission_worker_monitors, ref) do
      {intent_id, target, worker_pid} ->
        {:runtime_admission, {:worker, intent_id, target, worker_pid}}

      nil ->
        classify_runtime_admission_launcher_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_launcher_monitor(state, ref) do
    case Map.get(state.runtime_admission_launcher_monitors, ref) do
      {intent_id, target, launch_ref, _launcher_pid} ->
        {:runtime_admission, {:launcher, intent_id, target, launch_ref}}

      nil ->
        classify_runtime_admission_operation_launcher_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_operation_launcher_monitor(state, ref) do
    launch_mons = Map.get(state, :runtime_admission_operation_launcher_monitors, %{})

    case Map.get(launch_mons, ref) do
      launch_ref when is_reference(launch_ref) ->
        {:runtime_admission, {:operation_launcher, launch_ref}}

      nil ->
        classify_runtime_admission_observe_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_observe_monitor(state, ref) do
    observe_mons = Map.get(state, :runtime_admission_observe_monitors, %{})

    case Map.get(observe_mons, ref) do
      observe_ref when is_reference(observe_ref) ->
        {:runtime_admission, {:observe, observe_ref}}

      nil ->
        classify_runtime_admission_durable_mark_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_durable_mark_monitor(state, ref) do
    mark_mons = Map.get(state, :runtime_admission_durable_mark_monitors, %{})

    case Map.get(mark_mons, ref) do
      mark_ref when is_reference(mark_ref) ->
        {:runtime_admission, {:durable_mark, mark_ref}}

      nil ->
        classify_runtime_admission_claim_join_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_claim_join_monitor(state, ref) do
    join_mons = Map.get(state, :runtime_admission_claim_join_monitors, %{})

    case Map.get(join_mons, ref) do
      join_ref when is_reference(join_ref) ->
        {:runtime_admission, {:claim_join, join_ref}}

      nil ->
        classify_runtime_admission_durable_settle_monitor(state, ref)
    end
  end

  defp classify_runtime_admission_durable_settle_monitor(state, ref) do
    settle_mons = Map.get(state, :runtime_admission_durable_settle_monitors, %{})

    case Map.get(settle_mons, ref) do
      settle_ref when is_reference(settle_ref) ->
        {:runtime_admission, {:durable_settle, settle_ref}}

      nil ->
        case find_runtime_admission_reconcile_monitor(state, ref) do
          {:launcher, rec} -> {:runtime_admission, {:reconcile_launcher, rec}}
          {:worker, rec} -> {:runtime_admission, {:reconcile_worker, rec}}
          :error -> classify_runtime_admission_waiter_monitor(state, ref)
        end
    end
  end

  defp classify_runtime_admission_waiter_monitor(state, ref) do
    case Map.get(state.runtime_admission_waiter_by_mon, ref) do
      {intent_id, waiter_id} ->
        {:runtime_admission, {:waiter, intent_id, waiter_id}}

      nil ->
        classify_reservation_monitor(state, ref)
    end
  end

  defp handle_runtime_admission_monitor_down(state, ref, monitor) do
    case monitor do
      {:waiter, _intent_id, _waiter_id} ->
        handle_runtime_admission_waiter_down(state, ref)

      {:owner, intent_id, target, owner_pid} ->
        handle_runtime_admission_owner_down(state, ref, intent_id, target, owner_pid)

      {:worker, intent_id, target, worker_pid} ->
        handle_runtime_admission_worker_monitor_down(state, ref, intent_id, target, worker_pid)

      {:launcher, intent_id, target, launch_ref} ->
        handle_runtime_admission_launcher_down(state, ref, intent_id, target, launch_ref)

      {:operation_launcher, launch_ref} ->
        handle_runtime_admission_operation_launcher_down(state, ref, launch_ref)

      {:observe, observe_ref} ->
        handle_runtime_admission_observe_monitor_down(state, ref, observe_ref)

      {:durable_mark, mark_ref} ->
        handle_runtime_admission_durable_mark_monitor_down(state, ref, mark_ref)

      {:claim_join, join_ref} ->
        handle_runtime_admission_claim_join_monitor_down(state, ref, join_ref)

      {:durable_settle, settle_ref} ->
        handle_runtime_admission_durable_settle_monitor_down(state, ref, settle_ref)

      {:reconcile_launcher, rec} ->
        handle_runtime_admission_reconcile_launcher_down(state, rec)

      {:reconcile_worker, rec} ->
        handle_runtime_admission_reconcile_worker_down(state, rec)
    end
  end

  defp classify_reservation_monitor(state, ref) do
    case find_reservation_owner_mon(state, ref) do
      {:ok, task_id, reservation} -> {:reservation, task_id, reservation}
      :error -> classify_task_monitor(state, ref)
    end
  end

  defp classify_task_monitor(state, ref) do
    case Map.fetch(state.adoption_refs, ref) do
      {:ok, task_id} -> {:adoption, task_id}
      :error -> classify_runner_monitor(state, ref)
    end
  end

  defp classify_runner_monitor(state, ref) do
    case Map.fetch(state.refs, ref) do
      {:ok, task_id} -> {:task, task_id}
      :error -> :error
    end
  end

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
            |> maybe_finalize_task_result(result, state)

          {record, retire_spec} = plan_completed_lease_retire(record)
          state = put_in(state.tasks[task_id], record)
          state = accept_retire_spec(state, retire_spec)

          {state, cleanup_job(task_id, descriptor, :task_termination)}
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
              |> maybe_finalize_terminal(:task_owner_died, state)

            # Owner/runner DOWN is ordinary terminal failure: retain task_read.
            # Publish reduced record first; revoke I/O is async reconciled.
            {record, retire_spec} = plan_lease_retire(record, :terminal_revoke_set)
            state = put_in(state.tasks[task_id], record)
            state = accept_retire_spec(state, retire_spec)

            {state, cleanup_job(task_id, descriptor, :task_termination)}
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

  defp plan_completed_lease_retire(%{state: task_state} = record)
       when task_state in [:done, :failed, :cancelled] do
    phase =
      case task_state do
        :done ->
          if retain_adoption_capability?(record),
            do: :terminal_revoke_set_keep_adopt,
            else: :terminal_revoke_set

        _ ->
          :terminal_revoke_set
      end

    plan_lease_retire(record, phase)
  end

  defp plan_completed_lease_retire(record), do: {record, nil}

  defp retain_adoption_capability?(%{
         context_mode: :json_clean,
         executor: module,
         result: result
       }) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :adopt_task, 4) and
      is_map(result) and
      is_map(Map.get(result, :raw, Map.get(result, "raw")))
  end

  defp retain_adoption_capability?(_record), do: false

  # Fail closed on invalid/mismatched non-nil leases so lifecycle cannot revoke
  # another task's authority (confused deputy) and minted leases are never dropped.
  defp admit_task_control_lease(nil, _task_id), do: {:ok, nil}

  defp admit_task_control_lease(lease, task_id) do
    case TaskControlLease.normalize_for_task(lease, task_id) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, :task_control_lease_task_id_mismatch} ->
        {:error, :task_control_lease_task_id_mismatch}

      {:error, _reason} ->
        {:error, :invalid_task_control_lease}
    end
  end

  defp validate_task_control_security_module!(module) when is_atom(module) and not is_nil(module),
    do: module

  defp validate_task_control_security_module!(invalid) do
    raise ArgumentError,
          "task_control_security_module must be an atom module, got: #{inspect(invalid)}"
  end

  defp validate_task_control_revoke!(nil), do: nil

  defp validate_task_control_revoke!(fun) when is_function(fun, 1), do: fun

  defp validate_task_control_revoke!(invalid) do
    raise ArgumentError,
          "task_control_revoke must be nil or an arity-1 function, got: #{inspect(invalid)}"
  end

  # ---------------------------------------------------------------------------
  # Lease retirement reconciliation (revoke-set phases)
  #
  # Atomic transfer of retiring ids into store-owned pending buckets happens
  # before reducing the active lease (recovery intent already durable from the
  # pre-mint marker). Forget only after fail-closed completion CAS.
  # Store-owned admit/worker deadlines kill/demonitor hung processes.
  # O(1) task and monitor indexes replace linear scans.
  # ---------------------------------------------------------------------------

  defp ensure_lease_retirement_shape(state) do
    state =
      state
      |> Map.put_new(:lease_pending_retirement, %{})
      |> Map.put_new(:lease_retire_attempts, %{})
      |> Map.put_new(:lease_retire_task_index, %{})
      |> Map.put_new(:lease_retire_monitor_index, %{})
      |> Map.put_new(
        :lease_retire_admit_timeout_ms,
        @default_lease_retire_admit_timeout_ms
      )
      |> Map.put_new(
        :lease_retire_worker_timeout_ms,
        @default_lease_retire_worker_timeout_ms
      )
      |> Map.put_new(:lease_retire_base_delay_ms, @default_lease_retire_base_delay_ms)
      |> Map.put_new(:lease_retire_max_delay_ms, @default_lease_retire_max_delay_ms)
      |> Map.put_new(:lease_retire_max_attempts, @default_lease_retire_max_attempts)
      |> Map.put_new(
        :lease_retire_max_retrigger_rounds,
        @default_lease_retire_max_retrigger_rounds
      )

    rebuild_lease_retire_indexes_if_needed(state)
  end

  defp rebuild_lease_retire_indexes_if_needed(state) do
    attempts = Map.get(state, :lease_retire_attempts, %{})
    task_index = Map.get(state, :lease_retire_task_index, %{})
    mon_index = Map.get(state, :lease_retire_monitor_index, %{})

    if map_size(attempts) > 0 and map_size(task_index) == 0 and map_size(mon_index) == 0 do
      {task_index, mon_index} =
        Enum.reduce(attempts, {%{}, %{}}, fn {ref, attempt}, {ti, mi} ->
          ti =
            if attempt.status in [:admitting, :running, :retry_wait] do
              Map.put(ti, attempt.task_id, ref)
            else
              ti
            end

          mi =
            mi
            |> maybe_put_mon_index(attempt.launcher_mon, {:launcher, ref})
            |> maybe_put_mon_index(attempt.worker_mon, {:worker, ref})

          {ti, mi}
        end)

      state
      |> Map.put(:lease_retire_task_index, task_index)
      |> Map.put(:lease_retire_monitor_index, mon_index)
    else
      state
    end
  end

  defp maybe_put_mon_index(index, mon, value) when is_reference(mon),
    do: Map.put(index, mon, value)

  defp maybe_put_mon_index(index, _, _), do: index

  # Pure plan: transfer phase members out of the active lease map (for the
  # record) and return a retire_spec. Does not perform revoke I/O.
  defp plan_lease_retire(record, phase) do
    task_id = Map.get(record, :task_id)

    case Map.get(record, :task_control_lease) do
      %{"capabilities" => caps} = lease when is_map(caps) ->
        pairs = TaskControlLease.kinds_and_ids_for_phase(lease, phase)

        if pairs == [] do
          # Empty/no-op: preserve record identity (no field mutation).
          {record, nil}
        else
          kinds = TaskControlLease.lifecycle_kinds(phase)
          next_lease = TaskControlLease.drop_kinds(lease, kinds)

          record =
            if TaskControlLease.empty?(next_lease) do
              Map.put(record, :task_control_lease, nil)
            else
              Map.put(record, :task_control_lease, next_lease)
            end

          members =
            Enum.map(pairs, fn {kind, id} ->
              %{kind: kind, id: id}
            end)

          {record, %{task_id: task_id, phase: phase, members: members}}
        end

      _ ->
        plan_legacy_lease_retire(record, phase)
    end
  end

  defp plan_legacy_lease_retire(record, phase) do
    task_id = Map.get(record, :task_id)

    {members, record} =
      case phase do
        :all ->
          collect_and_clear_legacy_caps(record, [:approval_answer, :steer, :adopt])

        :after_adoption ->
          collect_and_clear_legacy_caps(record, [:adopt])

        :terminal_revoke_set_keep_adopt ->
          collect_and_clear_legacy_caps(record, [:approval_answer, :steer])

        :terminal_revoke_set ->
          collect_and_clear_legacy_caps(record, [:approval_answer, :steer, :adopt])

        _ ->
          {[], record}
      end

    if members == [] do
      {record, nil}
    else
      {record, %{task_id: task_id, phase: phase, members: members}}
    end
  end

  defp collect_and_clear_legacy_caps(record, kinds) do
    Enum.reduce(kinds, {[], record}, fn kind, {members, rec} ->
      case kind do
        :approval_answer ->
          case Map.get(rec, :approval_answer_cap_id) do
            id when is_binary(id) and id != "" ->
              {[%{kind: :legacy_approval_answer, id: id} | members],
               Map.put(rec, :approval_answer_cap_id, nil)}

            _ ->
              {members, rec}
          end

        :steer ->
          case Map.get(rec, :steer_cap_id) do
            id when is_binary(id) and id != "" ->
              {[%{kind: :legacy_steer, id: id} | members], Map.put(rec, :steer_cap_id, nil)}

            _ ->
              {members, rec}
          end

        :adopt ->
          case Map.get(rec, :adoption_cap_id) do
            id when is_binary(id) and id != "" ->
              {[%{kind: :legacy_adopt, id: id} | members], Map.put(rec, :adoption_cap_id, nil)}

            _ ->
              {members, rec}
          end
      end
    end)
  end

  # Always returns state (never nil). Empty/no-op specs are identity.
  defp accept_retire_spec(state, nil), do: ensure_lease_retirement_shape(state)

  defp accept_retire_spec(state, %{task_id: task_id, phase: phase, members: members})
       when is_binary(task_id) and is_list(members) do
    state = ensure_lease_retirement_shape(state)

    if members == [] do
      state
    else
      bucket = Map.get(state.lease_pending_retirement, task_id) || new_retirement_bucket(task_id)
      was_exhausted? = Map.get(bucket, :exhausted, false) == true

      merged_members =
        Enum.reduce(members, bucket.members, fn %{id: id} = member, acc ->
          if is_binary(id) and id != "" do
            Map.put(acc, id, %{kind: Map.get(member, :kind, :unknown), id: id})
          else
            acc
          end
        end)

      bucket =
        if was_exhausted? do
          # Reopen exhausted bucket with a new generation ladder.
          %{
            bucket
            | members: merged_members,
              exhausted: false,
              generation: bucket.generation + 1,
              attempt_index: 0
          }
        else
          %{bucket | members: merged_members}
        end

      state = put_in(state.lease_pending_retirement[task_id], bucket)

      if live_retire_attempt_for_task?(state, task_id) do
        state
      else
        begin_retire_attempt(state, task_id, phase)
      end
    end
  end

  defp accept_retire_spec(state, _invalid), do: ensure_lease_retirement_shape(state)

  defp new_retirement_bucket(task_id) do
    %{
      task_id: task_id,
      members: %{},
      exhausted: false,
      generation: 0,
      attempt_index: 0,
      retrigger_count: 0
    }
  end

  defp live_retire_attempt_for_task?(state, task_id) do
    case Map.get(Map.get(state, :lease_retire_task_index, %{}), task_id) do
      nil ->
        false

      attempt_ref ->
        case Map.fetch(Map.get(state, :lease_retire_attempts, %{}), attempt_ref) do
          {:ok, attempt} ->
            attempt.status in [:admitting, :running, :retry_wait]

          :error ->
            false
        end
    end
  end

  defp begin_retire_attempt(state, task_id, phase) do
    state = ensure_lease_retirement_shape(state)
    bucket = Map.get(state.lease_pending_retirement, task_id)

    cond do
      is_nil(bucket) or map_size(bucket.members) == 0 ->
        state

      bucket.exhausted == true ->
        state

      true ->
        attempt_ref = make_ref()
        member_ids = Map.keys(bucket.members)
        security_module = Map.get(state, :task_control_security_module, Arbor.Security)
        revoke_fun = Map.get(state, :task_control_revoke)

        supervisor =
          Map.get(
            state,
            :cleanup_supervisor,
            Map.get(state, :task_supervisor, @default_task_supervisor)
          )

        admit_timeout =
          Map.get(state, :lease_retire_admit_timeout_ms, @default_lease_retire_admit_timeout_ms)

        # Worker must outlive the admit deadline slightly so it can self-expire
        # after a timed-out admission without ever entering revoke I/O.
        begin_wait_ms = admit_timeout + 1_000

        admit_timer =
          Process.send_after(self(), {:lease_retire_admit_timeout, attempt_ref}, admit_timeout)

        store_pid = self()

        {launcher_pid, launcher_mon} =
          spawn_monitor(__MODULE__, :lease_retire_launcher, [
            store_pid,
            attempt_ref,
            supervisor,
            member_ids,
            security_module,
            revoke_fun,
            begin_wait_ms
          ])

        attempt = %{
          attempt_ref: attempt_ref,
          task_id: task_id,
          generation: bucket.generation,
          attempt_index: bucket.attempt_index,
          phase: phase,
          member_ids: member_ids,
          status: :admitting,
          completion_applied?: false,
          launcher_pid: launcher_pid,
          launcher_mon: launcher_mon,
          worker_pid: nil,
          worker_mon: nil,
          admit_timer: admit_timer,
          worker_timer: nil,
          retry_timer: nil,
          admit_deadline_mono: System.monotonic_time(:millisecond) + admit_timeout,
          worker_deadline_mono: nil,
          security_module: security_module,
          revoke_fun: revoke_fun,
          last_error_class: nil
        }

        state
        |> put_in([:lease_retire_attempts, attempt_ref], attempt)
        |> put_in([:lease_retire_task_index, task_id], attempt_ref)
        |> put_in([:lease_retire_monitor_index, launcher_mon], {:launcher, attempt_ref})
    end
  end

  @doc false
  def lease_retire_launcher(
        store_pid,
        attempt_ref,
        supervisor,
        member_ids,
        security_module,
        revoke_fun,
        begin_wait_ms
      )
      when is_pid(store_pid) and is_reference(attempt_ref) and is_list(member_ids) and
             is_integer(begin_wait_ms) and begin_wait_ms > 0 do
    case Task.Supervisor.start_child(
           supervisor,
           __MODULE__,
           :run_lease_retire_worker,
           [store_pid, attempt_ref, member_ids, security_module, revoke_fun, begin_wait_ms],
           []
         ) do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        send(store_pid, {:lease_retire_admitted, attempt_ref, worker_pid})

      {:ok, worker_pid, _info} when is_pid(worker_pid) ->
        send(store_pid, {:lease_retire_admitted, attempt_ref, worker_pid})

      {:error, reason} ->
        send(
          store_pid,
          {:lease_retire_admission_failed, attempt_ref, classify_admission_error(reason)}
        )

      other ->
        send(
          store_pid,
          {:lease_retire_admission_failed, attempt_ref, classify_admission_error(other)}
        )
    end

    :ok
  rescue
    _ ->
      send(store_pid, {:lease_retire_admission_failed, attempt_ref, :launcher_exception})
      :ok
  catch
    :exit, _ ->
      send(store_pid, {:lease_retire_admission_failed, attempt_ref, :launcher_exit})
      :ok

    _, _ ->
      send(store_pid, {:lease_retire_admission_failed, attempt_ref, :launcher_error})
      :ok
  end

  defp classify_admission_error(:noproc), do: :supervisor_unavailable
  defp classify_admission_error({:noproc, _}), do: :supervisor_unavailable
  defp classify_admission_error(:timeout), do: :admission_timeout
  defp classify_admission_error(_), do: :admission_failed

  @doc false
  # Worker must not enter revoke I/O until TaskStore accepts admission and
  # sends {:lease_retire_begin, attempt_ref}. If admission times out (launcher
  # killed, attempt superseded), the worker never receives begin and self-expires
  # so it cannot remain as an unmonitored hung revoke process.
  def run_lease_retire_worker(
        store_pid,
        attempt_ref,
        member_ids,
        security_module,
        revoke_fun,
        begin_wait_ms
      )
      when is_pid(store_pid) and is_reference(attempt_ref) and is_list(member_ids) and
             is_integer(begin_wait_ms) and begin_wait_ms > 0 do
    receive do
      {:lease_retire_begin, ^attempt_ref} ->
        results =
          Enum.map(member_ids, fn id ->
            {id, normalize_revoke_outcome(revoke_one_id(id, security_module, revoke_fun))}
          end)

        send(store_pid, {:lease_retire_complete, attempt_ref, results})
        :ok
    after
      begin_wait_ms ->
        # Never admitted (or admitted after supersede without begin). Exit
        # without revoke I/O and without claiming completion.
        :ok
    end
  end

  defp revoke_one_id(id, _security_module, revoke_fun)
       when is_binary(id) and id != "" and is_function(revoke_fun, 1) do
    revoke_fun.(id)
  rescue
    _ -> {:error, :exception}
  catch
    :exit, _ -> {:error, :exit}
    _, _ -> {:error, :error}
  end

  defp revoke_one_id(id, security_module, _revoke_fun) when is_binary(id) and id != "" do
    if is_atom(security_module) and Code.ensure_loaded?(security_module) and
         function_exported?(security_module, :revoke, 1) do
      apply(security_module, :revoke, [id])
    else
      {:error, :security_unavailable}
    end
  rescue
    _ -> {:error, :exception}
  catch
    :exit, _ -> {:error, :exit}
    _, _ -> {:error, :error}
  end

  defp revoke_one_id(_id, _security_module, _revoke_fun), do: {:error, :invalid_id}

  defp normalize_revoke_outcome(:ok), do: :ok
  defp normalize_revoke_outcome({:ok, _}), do: :ok
  defp normalize_revoke_outcome({:error, :not_found}), do: :ok
  defp normalize_revoke_outcome({:error, :already_revoked}), do: :ok
  defp normalize_revoke_outcome({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_revoke_outcome({:error, _}), do: {:error, :revoke_failed}
  defp normalize_revoke_outcome(_), do: {:error, :unexpected_outcome}

  defp handle_lease_retire_admitted(state, attempt_ref, worker_pid) do
    state = ensure_lease_retirement_shape(state)

    case Map.fetch(state.lease_retire_attempts, attempt_ref) do
      {:ok, %{status: :admitting, generation: gen} = attempt} ->
        bucket = Map.get(state.lease_pending_retirement, attempt.task_id)

        if is_map(bucket) and bucket.generation == gen do
          cancel_timer_safe(attempt.admit_timer)

          if is_reference(attempt.launcher_mon),
            do: Process.demonitor(attempt.launcher_mon, [:flush])

          worker_timeout =
            Map.get(
              state,
              :lease_retire_worker_timeout_ms,
              @default_lease_retire_worker_timeout_ms
            )

          worker_timer =
            Process.send_after(
              self(),
              {:lease_retire_worker_timeout, attempt_ref},
              worker_timeout
            )

          worker_mon = Process.monitor(worker_pid)

          # Acceptance/begin signal: only after store-owned monitor + deadline
          # are armed. Workers that never receive this self-expire.
          send(worker_pid, {:lease_retire_begin, attempt_ref})

          state =
            if is_reference(attempt.launcher_mon) do
              update_in(state.lease_retire_monitor_index, &Map.delete(&1, attempt.launcher_mon))
            else
              state
            end

          attempt = %{
            attempt
            | status: :running,
              launcher_pid: nil,
              launcher_mon: nil,
              admit_timer: nil,
              worker_pid: worker_pid,
              worker_mon: worker_mon,
              worker_timer: worker_timer,
              worker_deadline_mono: System.monotonic_time(:millisecond) + worker_timeout
          }

          state
          |> put_in([:lease_retire_attempts, attempt_ref], attempt)
          |> put_in([:lease_retire_monitor_index, worker_mon], {:worker, attempt_ref})
        else
          # Stale generation / superseded — do not send begin; worker self-expires.
          state
        end

      _ ->
        # Stale/forged/superseded — do not send begin; worker self-expires.
        state
    end
  end

  defp handle_lease_retire_admission_failed(state, attempt_ref, class) do
    state = ensure_lease_retirement_shape(state)

    case Map.fetch(state.lease_retire_attempts, attempt_ref) do
      {:ok, %{status: :admitting} = attempt} ->
        cancel_timer_safe(attempt.admit_timer)

        if is_reference(attempt.launcher_mon),
          do: Process.demonitor(attempt.launcher_mon, [:flush])

        if is_pid(attempt.launcher_pid) and Process.alive?(attempt.launcher_pid) do
          Process.exit(attempt.launcher_pid, :kill)
        end

        state = supersede_attempt(state, attempt_ref)
        schedule_retire_retry(state, attempt.task_id, attempt.phase, class)

      _ ->
        state
    end
  end

  defp handle_lease_retire_admit_timeout(state, attempt_ref) do
    state = ensure_lease_retirement_shape(state)

    case Map.fetch(state.lease_retire_attempts, attempt_ref) do
      {:ok, %{status: :admitting} = attempt} ->
        # Mandatory: kill+demonitor blocked launcher before retry so suspended
        # supervisors cannot accumulate launchers/workers.
        if is_pid(attempt.launcher_pid) and Process.alive?(attempt.launcher_pid) do
          Process.exit(attempt.launcher_pid, :kill)
        end

        if is_reference(attempt.launcher_mon),
          do: Process.demonitor(attempt.launcher_mon, [:flush])

        cancel_timer_safe(attempt.admit_timer)

        state = supersede_attempt(state, attempt_ref)
        schedule_retire_retry(state, attempt.task_id, attempt.phase, :admit_timeout)

      _ ->
        state
    end
  end

  defp handle_lease_retire_worker_timeout(state, attempt_ref) do
    state = ensure_lease_retirement_shape(state)

    case Map.fetch(state.lease_retire_attempts, attempt_ref) do
      {:ok, %{status: :running, completion_applied?: false} = attempt} ->
        if is_pid(attempt.worker_pid) and Process.alive?(attempt.worker_pid) do
          Process.exit(attempt.worker_pid, :kill)
        end

        if is_reference(attempt.worker_mon), do: Process.demonitor(attempt.worker_mon, [:flush])
        cancel_timer_safe(attempt.worker_timer)

        state = supersede_attempt(state, attempt_ref)
        schedule_retire_retry(state, attempt.task_id, attempt.phase, :worker_timeout)

      _ ->
        state
    end
  end

  defp handle_lease_retire_launcher_down(state, attempt_ref, attempt) do
    state = ensure_lease_retirement_shape(state)

    case attempt do
      %{status: :admitting, completion_applied?: false} ->
        cancel_timer_safe(attempt.admit_timer)
        state = supersede_attempt(state, attempt_ref)
        schedule_retire_retry(state, attempt.task_id, attempt.phase, :launcher_down)

      _ ->
        # Already running or completed — ignore launcher death.
        state
    end
  end

  defp handle_lease_retire_worker_down(state, attempt_ref, attempt, _reason) do
    state = ensure_lease_retirement_shape(state)

    case attempt do
      %{status: :running, completion_applied?: false} ->
        cancel_timer_safe(attempt.worker_timer)
        state = supersede_attempt(state, attempt_ref)
        schedule_retire_retry(state, attempt.task_id, attempt.phase, :worker_down)

      %{completion_applied?: true} ->
        # Completion-then-DOWN: ignore.
        state

      _ ->
        state
    end
  end

  defp handle_lease_retire_complete(state, attempt_ref, results) do
    state = ensure_lease_retirement_shape(state)

    case Map.fetch(state.lease_retire_attempts, attempt_ref) do
      {:ok, attempt}
      when attempt.status in [:admitting, :running] and attempt.completion_applied? == false ->
        bucket = Map.get(state.lease_pending_retirement, attempt.task_id)

        cond do
          not is_map(bucket) ->
            supersede_attempt(state, attempt_ref)

          bucket.generation != attempt.generation ->
            # Stale generation.
            supersede_attempt(state, attempt_ref)

          not is_list(results) ->
            state = cleanup_attempt_runtime(state, attempt_ref, attempt)
            state = supersede_attempt(state, attempt_ref)
            schedule_retire_retry(state, attempt.task_id, attempt.phase, :malformed_completion)

          true ->
            case apply_completion_cas(bucket.members, results) do
              {:malformed, _} ->
                state = cleanup_attempt_runtime(state, attempt_ref, attempt)
                state = supersede_attempt(state, attempt_ref)

                schedule_retire_retry(
                  state,
                  attempt.task_id,
                  attempt.phase,
                  :malformed_completion
                )

              {:ok, next_members} ->
                state = cleanup_attempt_runtime(state, attempt_ref, attempt)

                attempt = %{attempt | completion_applied?: true, status: :superseded}
                state = put_in(state.lease_retire_attempts[attempt_ref], attempt)
                state = delete_attempt(state, attempt_ref)

                if map_size(next_members) == 0 do
                  state =
                    update_in(state.lease_pending_retirement, &Map.delete(&1, attempt.task_id))

                  maybe_schedule_marker_delete(state, attempt.task_id)
                else
                  bucket = %{bucket | members: next_members}
                  state = put_in(state.lease_pending_retirement[attempt.task_id], bucket)
                  schedule_retire_retry(state, attempt.task_id, attempt.phase, :partial_revoke)
                end
            end
        end

      _ ->
        # Stale/forged/already applied.
        state
    end
  end

  # Fail-closed completion CAS against authoritative pending members only.
  defp apply_completion_cas(auth_members, results)
       when is_map(auth_members) and is_list(results) do
    {acc, malformed?} =
      Enum.reduce(results, {%{}, false}, fn row, {acc, malformed?} ->
        case parse_completion_row(row) do
          {:ok, id, :ok} ->
            {merge_completion_outcome(acc, id, :ok), malformed?}

          {:ok, id, :error} ->
            {merge_completion_outcome(acc, id, :error), malformed?}

          :malformed ->
            {acc, true}
        end
      end)

    if malformed? do
      {:malformed, auth_members}
    else
      next =
        Enum.reduce(auth_members, auth_members, fn {id, _meta}, members ->
          case Map.get(acc, id, :omitted) do
            :ok -> Map.delete(members, id)
            :omitted -> members
            :error -> members
            :conflict -> members
          end
        end)

      {:ok, next}
    end
  end

  defp apply_completion_cas(auth_members, _results), do: {:malformed, auth_members}

  defp parse_completion_row({id, :ok}) when is_binary(id) and id != "", do: {:ok, id, :ok}

  defp parse_completion_row({id, {:error, reason}})
       when is_binary(id) and id != "" and is_atom(reason),
       do: {:ok, id, :error}

  defp parse_completion_row({id, :error}) when is_binary(id) and id != "", do: {:ok, id, :error}

  defp parse_completion_row(_), do: :malformed

  defp merge_completion_outcome(acc, id, :ok) do
    case Map.get(acc, id) do
      nil -> Map.put(acc, id, :ok)
      :ok -> acc
      :error -> Map.put(acc, id, :conflict)
      :conflict -> acc
    end
  end

  defp merge_completion_outcome(acc, id, :error) do
    case Map.get(acc, id) do
      nil -> Map.put(acc, id, :error)
      :error -> acc
      :ok -> Map.put(acc, id, :conflict)
      :conflict -> acc
    end
  end

  defp handle_lease_retire_retry(state, attempt_ref) do
    state = ensure_lease_retirement_shape(state)

    case Map.fetch(state.lease_retire_attempts, attempt_ref) do
      {:ok, %{status: :retry_wait} = attempt} ->
        state = delete_attempt(state, attempt_ref)
        begin_retire_attempt(state, attempt.task_id, attempt.phase)

      _ ->
        state
    end
  end

  defp schedule_retire_retry(state, task_id, phase, error_class) do
    state = ensure_lease_retirement_shape(state)
    bucket = Map.get(state.lease_pending_retirement, task_id)

    cond do
      is_nil(bucket) or map_size(bucket.members) == 0 ->
        update_in(state.lease_pending_retirement, &Map.delete(&1, task_id))

      true ->
        max_attempts =
          Map.get(state, :lease_retire_max_attempts, @default_lease_retire_max_attempts)

        idx = Map.get(bucket, :attempt_index, 0)

        if idx + 1 >= max_attempts do
          bucket = %{
            bucket
            | exhausted: true,
              attempt_index: idx
          }

          # Redacted observability only — no capability ids.
          _ =
            :telemetry.execute(
              [:arbor, :agent, :task_control_lease, :retire_exhausted],
              %{remaining_count: map_size(bucket.members), attempt_index: idx},
              %{
                task_id: task_id,
                phase: phase,
                generation: bucket.generation,
                retrigger_count: bucket.retrigger_count,
                last_error_class: error_class
              }
            )

          put_in(state.lease_pending_retirement[task_id], bucket)
        else
          next_idx = idx + 1
          bucket = %{bucket | attempt_index: next_idx}
          state = put_in(state.lease_pending_retirement[task_id], bucket)

          base = Map.get(state, :lease_retire_base_delay_ms, @default_lease_retire_base_delay_ms)

          max_delay =
            Map.get(state, :lease_retire_max_delay_ms, @default_lease_retire_max_delay_ms)

          backoff = min(max_delay, base * Integer.pow(2, next_idx))

          attempt_ref = make_ref()

          retry_timer =
            Process.send_after(self(), {:lease_retire_retry, attempt_ref}, backoff)

          attempt = %{
            attempt_ref: attempt_ref,
            task_id: task_id,
            generation: bucket.generation,
            attempt_index: next_idx,
            phase: phase,
            member_ids: Map.keys(bucket.members),
            status: :retry_wait,
            completion_applied?: false,
            launcher_pid: nil,
            launcher_mon: nil,
            worker_pid: nil,
            worker_mon: nil,
            admit_timer: nil,
            worker_timer: nil,
            retry_timer: retry_timer,
            admit_deadline_mono: 0,
            worker_deadline_mono: nil,
            security_module: Map.get(state, :task_control_security_module, Arbor.Security),
            revoke_fun: Map.get(state, :task_control_revoke),
            last_error_class: error_class
          }

          state
          |> put_in([:lease_retire_attempts, attempt_ref], attempt)
          |> put_in([:lease_retire_task_index, task_id], attempt_ref)
        end
    end
  end

  defp do_retrigger_exhausted_lease_retirements(state) do
    state = ensure_lease_retirement_shape(state)

    max_rounds =
      Map.get(
        state,
        :lease_retire_max_retrigger_rounds,
        @default_lease_retire_max_retrigger_rounds
      )

    {state, retried, remaining} =
      Enum.reduce(state.lease_pending_retirement, {state, 0, 0}, fn {task_id, bucket},
                                                                    {st, retried, remaining} ->
        cond do
          bucket.exhausted != true or map_size(bucket.members) == 0 ->
            {st, retried, remaining}

          bucket.retrigger_count >= max_rounds ->
            {st, retried, remaining + 1}

          true ->
            bucket = %{
              bucket
              | exhausted: false,
                generation: bucket.generation + 1,
                attempt_index: 0,
                retrigger_count: bucket.retrigger_count + 1
            }

            st = put_in(st.lease_pending_retirement[task_id], bucket)
            st = begin_retire_attempt(st, task_id, :all)
            {st, retried + 1, remaining}
        end
      end)

    {state, %{retried_tasks: retried, remaining_exhausted: remaining}}
  end

  defp redacted_lease_retirement_snapshot(state) do
    pending =
      state
      |> Map.get(:lease_pending_retirement, %{})
      |> Enum.map(fn {task_id, bucket} ->
        {task_id,
         %{
           remaining_count: map_size(bucket.members),
           exhausted: bucket.exhausted,
           generation: bucket.generation,
           attempt_index: bucket.attempt_index,
           retrigger_count: bucket.retrigger_count
         }}
      end)
      |> Map.new()

    attempts =
      state
      |> Map.get(:lease_retire_attempts, %{})
      |> Enum.map(fn {_ref, attempt} ->
        %{
          task_id: attempt.task_id,
          status: attempt.status,
          generation: attempt.generation,
          attempt_index: attempt.attempt_index,
          last_error_class: attempt.last_error_class,
          member_count: length(attempt.member_ids || [])
        }
      end)

    %{
      pending_tasks: map_size(pending),
      pending: pending,
      active_attempts: length(attempts),
      attempts: attempts
    }
  end

  defp find_lease_retire_monitor(state, mon) when is_reference(mon) do
    case Map.get(Map.get(state, :lease_retire_monitor_index, %{}), mon) do
      {:launcher, ref} ->
        case Map.fetch(Map.get(state, :lease_retire_attempts, %{}), ref) do
          {:ok, attempt} -> {:launcher, ref, attempt}
          :error -> :error
        end

      {:worker, ref} ->
        case Map.fetch(Map.get(state, :lease_retire_attempts, %{}), ref) do
          {:ok, attempt} -> {:worker, ref, attempt}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp cleanup_attempt_runtime(state, _attempt_ref, attempt) do
    cancel_timer_safe(attempt.admit_timer)
    cancel_timer_safe(attempt.worker_timer)
    cancel_timer_safe(attempt.retry_timer)

    if is_reference(attempt.launcher_mon), do: Process.demonitor(attempt.launcher_mon, [:flush])
    if is_reference(attempt.worker_mon), do: Process.demonitor(attempt.worker_mon, [:flush])

    state
  end

  defp supersede_attempt(state, attempt_ref) do
    case Map.fetch(Map.get(state, :lease_retire_attempts, %{}), attempt_ref) do
      {:ok, attempt} ->
        state = cleanup_attempt_runtime(state, attempt_ref, attempt)
        delete_attempt(state, attempt_ref)

      :error ->
        state
    end
  end

  defp delete_attempt(state, attempt_ref) do
    case Map.fetch(Map.get(state, :lease_retire_attempts, %{}), attempt_ref) do
      {:ok, attempt} ->
        state =
          state
          |> update_in([:lease_retire_attempts], &Map.delete(&1, attempt_ref))

        state =
          case Map.get(Map.get(state, :lease_retire_task_index, %{}), attempt.task_id) do
            ^attempt_ref ->
              update_in(state.lease_retire_task_index, &Map.delete(&1, attempt.task_id))

            _ ->
              state
          end

        state
        |> maybe_delete_mon_index(attempt.launcher_mon)
        |> maybe_delete_mon_index(attempt.worker_mon)

      :error ->
        update_in(state.lease_retire_attempts, &Map.delete(&1, attempt_ref))
    end
  end

  defp maybe_delete_mon_index(state, mon) when is_reference(mon) do
    update_in(state.lease_retire_monitor_index, &Map.delete(&1, mon))
  end

  defp maybe_delete_mon_index(state, _), do: state

  # ---------------------------------------------------------------------------
  # Recovery ops (marker put/delete, revoke_by_task, replay)
  # No Persistence/Security I/O in GenServer callbacks — workers only.
  # ---------------------------------------------------------------------------

  defp ensure_recovery_shape(state) do
    state
    |> Map.put_new(:reservations, %{})
    |> Map.put_new(:reservation_monitor_index, %{})
    |> Map.put_new(:recovery_pending, %{})
    |> Map.put_new(:recovery_ops, %{})
    |> Map.put_new(:recovery_task_index, %{})
    |> Map.put_new(:recovery_monitor_index, %{})
    |> Map.put_new(:recovery_ready?, false)
    |> Map.put_new(:recovery_durable?, true)
    |> Map.put_new(:recovery_replay, %{phase: :pending, cursor: [], failures: 0, deadline_mono: 0})
    |> Map.put_new(:max_recovery_obligations, @default_max_recovery_obligations)
    |> Map.put_new(:max_reservations, @default_max_reservations)
    |> Map.put_new(:reservation_deadline_ms, @default_reservation_deadline_ms)
    |> Map.put_new(:recovery_admit_timeout_ms, @default_recovery_admit_timeout_ms)
    |> Map.put_new(:recovery_worker_timeout_ms, @default_recovery_worker_timeout_ms)
    |> Map.put_new(:recovery_replay_batch, @default_recovery_replay_batch)
    |> Map.put_new(:recovery_retry_base_ms, @default_recovery_retry_base_ms)
    |> Map.put_new(:recovery_retry_max_ms, @default_recovery_retry_max_ms)
    |> Map.put_new(:recovery_max_retries, @default_recovery_max_retries)
    |> Map.put_new(
      :task_control_recovery_facade,
      Arbor.Agent.Orchestration.TaskControlRecoveryPersistence
    )
    |> Map.put_new(:task_control_recovery_store, @default_recovery_store)
    |> Map.put_new(:task_control_security_module, Arbor.Security)
  end

  # Production durability is established by the fixed persistence adapter and
  # then attested against the named BufferedStore authority before readiness.
  # Explicit injected facades remain available only in MIX_ENV=test.
  defp recovery_facade_durable?(Arbor.Agent.Orchestration.TaskControlRecoveryPersistence),
    do: true

  defp recovery_facade_durable?(facade) when is_atom(facade) and not is_nil(facade) do
    Mix.env() == :test and Code.ensure_loaded?(facade) and
      function_exported?(facade, :buffered_store_acknowledged_put, 3)
  end

  defp recovery_facade_durable?(_), do: false

  defp production_recovery_facade?(facade),
    do: facade == Arbor.Agent.Orchestration.TaskControlRecoveryPersistence

  defp admit_new_reservation(state) do
    max_res = Map.get(state, :max_reservations, @default_max_reservations)
    max_obl = Map.get(state, :max_recovery_obligations, @default_max_recovery_obligations)
    res_count = map_size(Map.get(state, :reservations, %{}))

    cond do
      res_count >= max_res ->
        {:error, :reservation_capacity_exhausted}

      true ->
        TaskControlLease.admit_reservation?(recovery_obligation_count(state), max_obl)
    end
  end

  defp recovery_obligation_count(state) do
    reservations = map_size(Map.get(state, :reservations, %{}))
    pending_recovery = map_size(Map.get(state, :recovery_pending, %{}))

    active_lease_tasks =
      state
      |> Map.get(:tasks, %{})
      |> Enum.count(fn {_id, rec} ->
        case Map.get(rec, :task_control_lease) do
          %{"capabilities" => caps} when is_map(caps) and map_size(caps) > 0 -> true
          _ -> false
        end
      end)

    retirement_buckets = map_size(Map.get(state, :lease_pending_retirement, %{}))
    reservations + pending_recovery + active_lease_tasks + retirement_buckets
  end

  defp generate_unique_task_id(state) do
    generator = Map.get(state, :task_id_generator)

    Enum.reduce_while(1..8, {:error, :task_id_generation_failed}, fn _, _acc ->
      id =
        cond do
          is_function(generator, 0) ->
            case generator.() do
              id when is_binary(id) -> id
              _ -> Arbor.Identifiers.generate_id("task_")
            end

          true ->
            Arbor.Identifiers.generate_id("task_")
        end

      if TaskControlLease.valid_task_id?(id) and task_id_available?(state, id) do
        {:halt, {:ok, id}}
      else
        {:cont, {:error, :task_id_already_exists}}
      end
    end)
  end

  # Exclude live tasks, reservations, recovery indexes, and pending obligations so
  # a new owner cannot reuse an id that still has stale recovery/retirement work.
  defp task_id_available?(state, id) when is_binary(id) do
    not Map.has_key?(Map.get(state, :tasks, %{}), id) and
      not Map.has_key?(Map.get(state, :reservations, %{}), id) and
      not Map.has_key?(Map.get(state, :recovery_pending, %{}), id) and
      not Map.has_key?(Map.get(state, :recovery_task_index, %{}), id) and
      not Map.has_key?(Map.get(state, :lease_pending_retirement, %{}), id) and
      not Map.has_key?(Map.get(state, :lease_retire_task_index, %{}), id)
  end

  defp authorize_reservation(state, task_id, token, owner_pid) do
    cond do
      not TaskControlLease.valid_reservation_token?(token) ->
        {:error, :invalid_reservation_token}

      not is_pid(owner_pid) ->
        {:error, :invalid_reservation_token}

      true ->
        case Map.get(Map.get(state, :reservations, %{}), task_id) do
          %{token_hash: hash, owner_pid: ^owner_pid} = reservation ->
            if TaskControlLease.token_match?(hash, token) do
              {:ok, reservation}
            else
              {:error, :invalid_reservation_token}
            end

          %{token_hash: _hash} ->
            {:error, :invalid_reservation_token}

          _ ->
            {:error, :invalid_reservation_token}
        end
    end
  end

  defp drop_reservation(state, task_id, reservation) do
    if is_reference(reservation.owner_mon), do: Process.demonitor(reservation.owner_mon, [:flush])
    cancel_timer_safe(Map.get(reservation, :deadline_timer))

    state =
      if is_reference(reservation.owner_mon) do
        update_in(state.reservation_monitor_index, &Map.delete(&1, reservation.owner_mon))
      else
        state
      end

    update_in(state.reservations, &Map.delete(&1, task_id))
  end

  defp put_recovery_pending(state, task_id, reason, marker_written?) do
    existing = Map.get(Map.get(state, :recovery_pending, %{}), task_id)

    pending = %{
      task_id: task_id,
      reason: reason,
      marker_written?: marker_written? == true,
      inserted_at: DateTime.utc_now(),
      retry_count: (existing && Map.get(existing, :retry_count, 0)) || 0,
      retry_timer: existing && Map.get(existing, :retry_timer)
    }

    put_in(state.recovery_pending[task_id], pending)
  end

  # O(1) exact monitor-ref lookup — never scan reservations or match by PID.
  defp find_reservation_owner_mon(state, mon) when is_reference(mon) do
    case Map.get(Map.get(state, :reservation_monitor_index, %{}), mon) do
      task_id when is_binary(task_id) ->
        case Map.get(Map.get(state, :reservations, %{}), task_id) do
          %{owner_mon: ^mon} = reservation ->
            {:ok, task_id, reservation}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp find_reservation_owner_mon(_state, _mon), do: :error

  defp handle_reservation_owner_down(state, task_id, reservation, reason) do
    marker_written? = reservation.marker_written? == true
    state = drop_reservation(state, task_id, reservation)

    if marker_written? do
      state
      |> put_recovery_pending(task_id, reason, true)
      |> begin_recovery_op(:reconcile_task, task_id, nil, nil)
    else
      # No durable marker and no grants yet — drop reservation only.
      state
    end
  end

  defp begin_recovery_op(state, kind, task_id, reply_to, payload, opts \\ []) do
    state = ensure_recovery_shape(state)

    # One live op per task for task-scoped kinds.
    if is_binary(task_id) and Map.has_key?(Map.get(state, :recovery_task_index, %{}), task_id) do
      if reply_to, do: GenServer.reply(reply_to, {:error, :recovery_op_in_flight})
      state
    else
      op_ref = make_ref()

      admit_timeout =
        Map.get(state, :recovery_admit_timeout_ms, @default_recovery_admit_timeout_ms)

      begin_wait_ms = admit_timeout + 1_000
      store_pid = self()

      supervisor =
        Map.get(
          state,
          :cleanup_supervisor,
          Map.get(state, :task_supervisor, @default_task_supervisor)
        )

      facade =
        Map.get(
          state,
          :task_control_recovery_facade,
          Arbor.Agent.Orchestration.TaskControlRecoveryPersistence
        )

      store_name = Map.get(state, :task_control_recovery_store, @default_recovery_store)
      security = Map.get(state, :task_control_security_module, Arbor.Security)

      admit_timer =
        Process.send_after(self(), {:recovery_op_admit_timeout, op_ref}, admit_timeout)

      {launcher_pid, launcher_mon} =
        spawn_monitor(__MODULE__, :recovery_op_launcher, [
          store_pid,
          op_ref,
          supervisor,
          kind,
          task_id,
          payload,
          facade,
          store_name,
          security,
          begin_wait_ms,
          Map.get(state, :recovery_replay_batch, @default_recovery_replay_batch)
        ])

      op = %{
        op_ref: op_ref,
        kind: kind,
        task_id: task_id,
        generation: 0,
        status: :admitting,
        launcher_pid: launcher_pid,
        launcher_mon: launcher_mon,
        worker_pid: nil,
        worker_mon: nil,
        admit_timer: admit_timer,
        worker_timer: nil,
        reply_to: reply_to,
        payload: payload,
        expected_token_hash: Keyword.get(opts, :expected_token_hash)
      }

      state =
        state
        |> put_in([:recovery_ops, op_ref], op)
        |> put_in([:recovery_monitor_index, launcher_mon], {:launcher, op_ref})

      if is_binary(task_id) do
        put_in(state.recovery_task_index[task_id], op_ref)
      else
        state
      end
    end
  end

  @doc false
  def recovery_op_launcher(
        store_pid,
        op_ref,
        supervisor,
        kind,
        task_id,
        payload,
        facade,
        store_name,
        security,
        begin_wait_ms,
        replay_batch
      ) do
    case Task.Supervisor.start_child(
           supervisor,
           __MODULE__,
           :run_recovery_op_worker,
           [
             store_pid,
             op_ref,
             kind,
             task_id,
             payload,
             facade,
             store_name,
             security,
             begin_wait_ms,
             replay_batch
           ],
           []
         ) do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        send(store_pid, {:recovery_op_admitted, op_ref, worker_pid})

      {:ok, worker_pid, _} when is_pid(worker_pid) ->
        send(store_pid, {:recovery_op_admitted, op_ref, worker_pid})

      {:error, reason} ->
        send(store_pid, {:recovery_op_admission_failed, op_ref, classify_admission_error(reason)})

      other ->
        send(store_pid, {:recovery_op_admission_failed, op_ref, classify_admission_error(other)})
    end

    :ok
  rescue
    _ ->
      send(store_pid, {:recovery_op_admission_failed, op_ref, :launcher_exception})
      :ok
  catch
    :exit, _ ->
      send(store_pid, {:recovery_op_admission_failed, op_ref, :launcher_exit})
      :ok

    _, _ ->
      send(store_pid, {:recovery_op_admission_failed, op_ref, :launcher_error})
      :ok
  end

  @doc false
  def run_recovery_op_worker(
        store_pid,
        op_ref,
        kind,
        task_id,
        payload,
        facade,
        store_name,
        security,
        begin_wait_ms,
        replay_batch
      ) do
    receive do
      {:recovery_op_begin, ^op_ref} ->
        result =
          execute_recovery_kind(
            kind,
            task_id,
            payload,
            facade,
            store_name,
            security,
            replay_batch
          )

        send(store_pid, {:recovery_op_complete, op_ref, result})
        :ok
    after
      begin_wait_ms ->
        :ok
    end
  end

  defp execute_recovery_kind(:marker_put, task_id, marker, facade, store_name, _security, _) do
    key = TaskControlLease.marker_key(task_id)

    case apply_recovery_put(facade, store_name, key, marker) do
      {:ok, _} -> {:ok, :marker_put}
      :ok -> {:ok, :marker_put}
      {:error, reason} -> {:error, sanitize_recovery_reason(reason)}
      other -> {:error, sanitize_recovery_reason(other)}
    end
  rescue
    _ -> {:error, :marker_put_exception}
  catch
    :exit, _ -> {:error, :marker_put_exit}
    _, _ -> {:error, :marker_put_error}
  end

  defp execute_recovery_kind(:marker_delete, task_id, _payload, facade, store_name, _security, _) do
    key = TaskControlLease.marker_key(task_id)

    case apply_recovery_delete(facade, store_name, key) do
      :ok -> {:ok, :marker_delete}
      {:ok, _} -> {:ok, :marker_delete}
      {:error, :not_found} -> {:ok, :marker_delete}
      {:error, reason} -> {:error, sanitize_recovery_reason(reason)}
      other -> {:error, sanitize_recovery_reason(other)}
    end
  rescue
    _ -> {:error, :marker_delete_exception}
  catch
    :exit, _ -> {:error, :marker_delete_exit}
    _, _ -> {:error, :marker_delete_error}
  end

  defp execute_recovery_kind(:reconcile_task, task_id, _payload, facade, store_name, security, _) do
    revoke_result =
      if is_atom(security) and Code.ensure_loaded?(security) and
           function_exported?(security, :revoke_by_task, 1) do
        apply(security, :revoke_by_task, [task_id])
      else
        {:error, :security_unavailable}
      end

    case revoke_result do
      {:ok, _count} ->
        key = TaskControlLease.marker_key(task_id)

        case apply_recovery_delete(facade, store_name, key) do
          :ok -> {:ok, :reconciled}
          {:ok, _} -> {:ok, :reconciled}
          {:error, :not_found} -> {:ok, :reconciled}
          {:error, reason} -> {:ok, {:reconciled_marker_stale, sanitize_recovery_reason(reason)}}
          _ -> {:ok, :reconciled_marker_stale}
        end

      {:error, reason} ->
        {:error, sanitize_recovery_reason(reason)}

      other ->
        {:error, sanitize_recovery_reason(other)}
    end
  rescue
    _ -> {:error, :reconcile_exception}
  catch
    :exit, _ -> {:error, :reconcile_exit}
    _, _ -> {:error, :reconcile_error}
  end

  defp execute_recovery_kind(
         :replay_batch,
         _task_id,
         _payload,
         facade,
         store_name,
         security,
         batch
       ) do
    case apply_recovery_list(facade, store_name) do
      {:ok, keys} when is_list(keys) ->
        batch_keys = Enum.take(keys, batch)

        results =
          Enum.map(batch_keys, fn key ->
            case apply_recovery_get(facade, store_name, key) do
              {:ok, raw} ->
                case TaskControlLease.marker_normalize(raw) do
                  {:ok, marker} ->
                    task_id = marker["task_id"]

                    case execute_recovery_kind(
                           :reconcile_task,
                           task_id,
                           nil,
                           facade,
                           store_name,
                           security,
                           batch
                         ) do
                      {:ok, _} -> {:ok, task_id}
                      {:error, reason} -> {:error, {task_id, reason}}
                    end

                  {:error, reason} ->
                    {:error, {key, reason}}
                end

              {:error, :not_found} ->
                {:ok, key}

              {:error, reason} ->
                {:error, {key, sanitize_recovery_reason(reason)}}
            end
          end)

        failures = Enum.count(results, &match?({:error, _}, &1))

        # Authoritative remainder: re-list after the batch. Ready only when an
        # authoritative pass proves zero remaining markers (not merely a
        # zero-failure truncated batch). Never estimate remainder on list failure.
        case apply_recovery_list(facade, store_name) do
          {:ok, after_keys} when is_list(after_keys) ->
            {:ok,
             %{
               processed: length(batch_keys),
               failures: failures,
               remaining: length(after_keys)
             }}

          {:error, reason} ->
            {:error, sanitize_recovery_reason(reason)}

          other ->
            {:error, sanitize_recovery_reason(other)}
        end

      {:error, reason} ->
        {:error, sanitize_recovery_reason(reason)}

      other ->
        {:error, sanitize_recovery_reason(other)}
    end
  rescue
    _ -> {:error, :replay_exception}
  catch
    :exit, _ -> {:error, :replay_exit}
    _, _ -> {:error, :replay_error}
  end

  defp execute_recovery_kind(_, _, _, _, _, _, _), do: {:error, :invalid_recovery_kind}

  defp apply_recovery_put(facade, store_name, key, value) do
    cond do
      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :buffered_store_acknowledged_put, 3) ->
        facade.buffered_store_acknowledged_put(store_name, key, value)

      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :acknowledged_put, 3) ->
        facade.acknowledged_put(store_name, key, value)

      true ->
        {:error, :recovery_facade_unavailable}
    end
  end

  defp apply_recovery_delete(facade, store_name, key) do
    cond do
      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :buffered_store_acknowledged_delete, 2) ->
        facade.buffered_store_acknowledged_delete(store_name, key)

      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :acknowledged_delete, 2) ->
        facade.acknowledged_delete(store_name, key)

      true ->
        {:error, :recovery_facade_unavailable}
    end
  end

  defp apply_recovery_list(facade, store_name) do
    cond do
      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :buffered_store_authoritative_list, 1) ->
        facade.buffered_store_authoritative_list(store_name)

      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :authoritative_list, 1) ->
        facade.authoritative_list(store_name)

      true ->
        {:error, :recovery_facade_unavailable}
    end
  end

  defp apply_recovery_get(facade, store_name, key) do
    cond do
      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :buffered_store_authoritative_get, 2) ->
        facade.buffered_store_authoritative_get(store_name, key)

      is_atom(facade) and Code.ensure_loaded?(facade) and
          function_exported?(facade, :authoritative_get, 2) ->
        facade.authoritative_get(store_name, key)

      true ->
        {:error, :recovery_facade_unavailable}
    end
  end

  defp sanitize_recovery_reason(reason) when is_atom(reason), do: reason
  defp sanitize_recovery_reason(_), do: :recovery_error

  defp handle_recovery_op_admitted(state, op_ref, worker_pid) do
    state = ensure_recovery_shape(state)

    case Map.fetch(state.recovery_ops, op_ref) do
      {:ok, %{status: :admitting} = op} ->
        cancel_timer_safe(op.admit_timer)

        if is_reference(op.launcher_mon), do: Process.demonitor(op.launcher_mon, [:flush])

        state =
          if is_reference(op.launcher_mon) do
            update_in(state.recovery_monitor_index, &Map.delete(&1, op.launcher_mon))
          else
            state
          end

        worker_timeout =
          Map.get(state, :recovery_worker_timeout_ms, @default_recovery_worker_timeout_ms)

        worker_timer =
          Process.send_after(self(), {:recovery_op_worker_timeout, op_ref}, worker_timeout)

        worker_mon = Process.monitor(worker_pid)
        send(worker_pid, {:recovery_op_begin, op_ref})

        op = %{
          op
          | status: :running,
            launcher_pid: nil,
            launcher_mon: nil,
            admit_timer: nil,
            worker_pid: worker_pid,
            worker_mon: worker_mon,
            worker_timer: worker_timer
        }

        state
        |> put_in([:recovery_ops, op_ref], op)
        |> put_in([:recovery_monitor_index, worker_mon], {:worker, op_ref})

      _ ->
        state
    end
  end

  defp handle_recovery_op_admission_failed(state, op_ref, class) do
    state = ensure_recovery_shape(state)

    case Map.fetch(Map.get(state, :recovery_ops, %{}), op_ref) do
      {:ok, op} ->
        # Retry scheduling is owned exclusively by apply_recovery_result/3.
        finish_recovery_op(state, op_ref, op, {:error, class})

      :error ->
        state
    end
  end

  defp handle_recovery_op_admit_timeout(state, op_ref) do
    state = ensure_recovery_shape(state)

    case Map.fetch(Map.get(state, :recovery_ops, %{}), op_ref) do
      {:ok, %{status: :admitting} = op} ->
        if is_pid(op.launcher_pid) and Process.alive?(op.launcher_pid) do
          Process.exit(op.launcher_pid, :kill)
        end

        # Retry scheduling is owned exclusively by apply_recovery_result/3.
        finish_recovery_op(state, op_ref, op, {:error, :admit_timeout})

      _ ->
        state
    end
  end

  defp handle_recovery_op_worker_timeout(state, op_ref) do
    state = ensure_recovery_shape(state)

    case Map.fetch(Map.get(state, :recovery_ops, %{}), op_ref) do
      {:ok, %{status: :running} = op} ->
        if is_pid(op.worker_pid) and Process.alive?(op.worker_pid) do
          Process.exit(op.worker_pid, :kill)
        end

        # Retry scheduling is owned exclusively by apply_recovery_result/3.
        finish_recovery_op(state, op_ref, op, {:error, :worker_timeout})

      _ ->
        state
    end
  end

  defp handle_recovery_launcher_down(state, op_ref, op) do
    case op do
      %{status: :admitting} ->
        # Retry scheduling is owned exclusively by apply_recovery_result/3.
        finish_recovery_op(state, op_ref, op, {:error, :launcher_down})

      _ ->
        state
    end
  end

  defp handle_recovery_worker_down(state, op_ref, op, _reason) do
    case op do
      %{status: :running} ->
        # Retry scheduling is owned exclusively by apply_recovery_result/3.
        finish_recovery_op(state, op_ref, op, {:error, :worker_down})

      _ ->
        state
    end
  end

  defp handle_recovery_op_complete(state, op_ref, result) do
    state = ensure_recovery_shape(state)

    case Map.fetch(Map.get(state, :recovery_ops, %{}), op_ref) do
      {:ok, %{status: status} = op} when status in [:admitting, :running] ->
        finish_recovery_op(state, op_ref, op, result)

      _ ->
        # Stale completion reject.
        state
    end
  end

  defp finish_recovery_op(state, op_ref, op, result) do
    cancel_timer_safe(op.admit_timer)
    cancel_timer_safe(op.worker_timer)
    if is_reference(op.launcher_mon), do: Process.demonitor(op.launcher_mon, [:flush])
    if is_reference(op.worker_mon), do: Process.demonitor(op.worker_mon, [:flush])

    state =
      state
      |> maybe_delete_recovery_mon(op.launcher_mon)
      |> maybe_delete_recovery_mon(op.worker_mon)
      |> update_in([:recovery_ops], &Map.delete(&1, op_ref))

    state =
      if is_binary(op.task_id) do
        case Map.get(Map.get(state, :recovery_task_index, %{}), op.task_id) do
          ^op_ref -> update_in(state.recovery_task_index, &Map.delete(&1, op.task_id))
          _ -> state
        end
      else
        state
      end

    state = apply_recovery_result(state, op, result)

    if op.reply_to do
      reply =
        case result do
          {:ok, _} -> :ok
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, sanitize_recovery_reason(other)}
        end

      GenServer.reply(op.reply_to, reply)
    end

    state
  end

  defp maybe_delete_recovery_mon(state, mon) when is_reference(mon) do
    update_in(state.recovery_monitor_index, &Map.delete(&1, mon))
  end

  defp maybe_delete_recovery_mon(state, _), do: state

  defp apply_recovery_result(
         state,
         %{kind: :marker_put, task_id: task_id, expected_token_hash: expected},
         {:ok, _}
       )
       when is_binary(task_id) and is_binary(expected) do
    # CAS-bound to the reservation token hash captured at admit time. A stale
    # completion must not stamp marker_written? on a replacement reservation.
    case Map.get(state.reservations, task_id) do
      %{token_hash: ^expected} = reservation ->
        put_in(state.reservations[task_id], %{reservation | marker_written?: true})

      _ ->
        state
    end
  end

  defp apply_recovery_result(state, %{kind: :marker_put, task_id: task_id}, {:ok, _})
       when is_binary(task_id) do
    # Missing expected_token_hash — fail closed (no mutation).
    state
  end

  defp apply_recovery_result(state, %{kind: :reconcile_task, task_id: task_id}, {:ok, _})
       when is_binary(task_id) do
    clear_recovery_pending(state, task_id)
  end

  defp apply_recovery_result(
         state,
         %{kind: :reconcile_task, task_id: task_id},
         {:ok, {:reconciled_marker_stale, _}}
       )
       when is_binary(task_id) do
    # Authority reconciled; stale marker may remain for future over-revoke.
    clear_recovery_pending(state, task_id)
  end

  defp apply_recovery_result(state, %{kind: :reconcile_task, task_id: task_id}, {:error, _})
       when is_binary(task_id) do
    # Keep pending and schedule bounded backoff retry — never rely on restart/TTL.
    schedule_recovery_pending_retry(state, task_id)
  end

  defp apply_recovery_result(state, %{kind: :marker_delete, task_id: task_id}, {:ok, _})
       when is_binary(task_id) do
    state
  end

  defp apply_recovery_result(
         state,
         %{kind: :replay_batch},
         {:ok, %{failures: 0, remaining: 0}}
       ) do
    # Authoritative empty remainder — only then mark ready. The production
    # adapter attests node-restart durability before each authoritative list.
    %{state | recovery_ready?: true}
  end

  defp apply_recovery_result(
         state,
         %{kind: :replay_batch},
         {:ok, %{failures: failures, remaining: remaining}}
       )
       when is_integer(failures) and is_integer(remaining) and
              (failures > 0 or remaining > 0) do
    # More markers remain or batch had failures — stay not-ready and continue.
    Process.send_after(self(), :retry_recovery_replay_msg, recovery_retry_delay(state, 0))
    state
  end

  defp apply_recovery_result(state, %{kind: :replay_batch}, {:ok, %{failures: 0}}) do
    # Legacy shape without remaining: re-check via another pass (fail closed).
    Process.send_after(self(), :retry_recovery_replay_msg, recovery_retry_delay(state, 0))
    state
  end

  defp apply_recovery_result(state, %{kind: :replay_batch}, {:error, _}) do
    Process.send_after(self(), :retry_recovery_replay_msg, recovery_retry_delay(state, 1))
    state
  end

  defp apply_recovery_result(state, _op, _result), do: state

  defp clear_recovery_pending(state, task_id) do
    case Map.get(Map.get(state, :recovery_pending, %{}), task_id) do
      %{retry_timer: timer} when is_reference(timer) ->
        cancel_timer_safe(timer)

      _ ->
        :ok
    end

    update_in(state.recovery_pending, &Map.delete(&1, task_id))
  end

  defp schedule_recovery_pending_retry(state, task_id) do
    state = ensure_recovery_shape(state)
    max_retries = Map.get(state, :recovery_max_retries, @default_recovery_max_retries)

    case Map.get(Map.get(state, :recovery_pending, %{}), task_id) do
      nil ->
        # Ensure pending exists so authority is not forgotten.
        state = put_recovery_pending(state, task_id, :reconcile_failed, true)
        schedule_recovery_pending_retry(state, task_id)

      %{retry_count: count} = pending when count >= max_retries ->
        # Exhausted retry budget: keep pending (never drop unreconciled authority).
        put_in(state.recovery_pending[task_id], %{pending | retry_count: count})

      %{retry_count: count, retry_timer: old_timer} = pending ->
        cancel_timer_safe(old_timer)
        delay = recovery_retry_delay(state, count)

        timer =
          Process.send_after(self(), {:recovery_pending_retry, task_id}, delay)

        pending = %{pending | retry_count: count + 1, retry_timer: timer}
        put_in(state.recovery_pending[task_id], pending)

      pending when is_map(pending) ->
        schedule_recovery_pending_retry(
          put_in(state.recovery_pending[task_id], Map.put(pending, :retry_count, 0)),
          task_id
        )
    end
  end

  defp recovery_retry_delay(state, attempt_index) when is_integer(attempt_index) do
    base = Map.get(state, :recovery_retry_base_ms, @default_recovery_retry_base_ms)
    max_delay = Map.get(state, :recovery_retry_max_ms, @default_recovery_retry_max_ms)
    min(max_delay, base * Integer.pow(2, max(attempt_index, 0)))
  end

  # Retries are owned exclusively by apply_recovery_result/3 so each failure
  # schedules exactly one bounded attempt (no double-schedule from handlers).

  defp find_recovery_monitor(state, mon) when is_reference(mon) do
    case Map.get(Map.get(state, :recovery_monitor_index, %{}), mon) do
      {:launcher, ref} ->
        case Map.fetch(Map.get(state, :recovery_ops, %{}), ref) do
          {:ok, op} -> {:launcher, ref, op}
          :error -> :error
        end

      {:worker, ref} ->
        case Map.fetch(Map.get(state, :recovery_ops, %{}), ref) do
          {:ok, op} -> {:worker, ref, op}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp maybe_schedule_marker_delete(state, task_id) when is_binary(task_id) do
    state = ensure_recovery_shape(state)
    state = ensure_lease_retirement_shape(state)

    active? =
      case get_in(state, [:tasks, task_id, :task_control_lease]) do
        %{"capabilities" => caps} when is_map(caps) and map_size(caps) > 0 -> true
        _ -> false
      end

    pending_count =
      case Map.get(Map.get(state, :lease_pending_retirement, %{}), task_id) do
        %{members: members} when is_map(members) -> map_size(members)
        _ -> 0
      end

    recovery_pending? = Map.has_key?(Map.get(state, :recovery_pending, %{}), task_id)

    if TaskControlLease.retain_marker?(active?, pending_count, recovery_pending?) do
      state
    else
      begin_recovery_op(state, :marker_delete, task_id, nil, nil)
    end
  end

  defp maybe_schedule_marker_delete(state, _), do: state

  defp validate_task_control_recovery_facade!(mod) when is_atom(mod), do: mod

  defp validate_task_control_recovery_facade!(invalid) do
    raise ArgumentError,
          "task_control_recovery_facade must be a module, got: #{inspect(invalid)}"
  end

  # ---------------------------------------------------------------------------
  # Phase 4C C2A: operation-owned per-target dispatch fence + supervised seed
  # ---------------------------------------------------------------------------

  defp validate_fence_facade!(facade, opts) when is_atom(facade) and not is_nil(facade) do
    # Production collaborator is fixed at init. An alternate facade may be
    # injected solely at store start under MIX_ENV=test; per-dispatch options
    # remain data-only and can never select it.
    if Mix.env() != :test and
         Keyword.has_key?(opts, :template_authority_fence_facade) and
         facade != @default_fence_seed_facade do
      raise ArgumentError,
            "template_authority_fence_facade is fixed at store initialization " <>
              "and cannot be overridden outside MIX_ENV=test"
    end

    facade
  end

  defp validate_fence_facade!(invalid, _opts) do
    raise ArgumentError,
          "template_authority_fence_facade must be a module, got: #{inspect(invalid)}"
  end

  defp fence_force_ready?(opts) do
    if Mix.env() == :test do
      case Keyword.fetch(opts, :fence_force_ready) do
        {:ok, value} -> value == true
        :error -> true
      end
    else
      false
    end
  end

  defp runtime_admission_force_ready?(opts) do
    if Mix.env() == :test do
      case Keyword.fetch(opts, :runtime_admission_force_ready) do
        {:ok, value} -> value == true
        :error -> true
      end
    else
      false
    end
  end

  # Hot-state upgrade: an upgraded TaskStore process admitting none of the
  # fence fields stays closed until seeded (fail-closed defaults).
  defp ensure_fence_shape(state) do
    state
    |> Map.put_new(:template_authority_fence_facade, @default_fence_seed_facade)
    |> Map.put_new(:target_fences, %{})
    |> Map.put_new(:target_fence_ready?, false)
    |> Map.put_new(:fence_seed, %{status: :pending})
    |> Map.put_new(:fence_seed_admit_timeout_ms, @default_fence_seed_admit_timeout_ms)
    |> Map.put_new(:fence_seed_worker_timeout_ms, @default_fence_seed_worker_timeout_ms)
  end

  # Closed bounded OTP status projection — counts/readiness/phases only.
  # Never includes token, fingerprint, operation_id, PIDs, refs, or claim data.
  # Non-raising: malformed pending fields become zero counts; only allowlisted
  # phase/kind atoms are projected.
  @status_allowed_phases MapSet.new([
                           :admitted,
                           :owner_launching,
                           :owner_live,
                           :worker_running,
                           :outcome_unknown,
                           :settling,
                           :terminal,
                           :unknown
                         ])
  @status_allowed_kinds MapSet.new([:ordinary_start, :guarded_restore, :unknown])

  defp project_public_status(state) when is_map(state) do
    intents = safe_map(Map.get(state, :runtime_admission_intents))
    waiters = safe_map(Map.get(state, :runtime_admission_waiters))
    fences = safe_map(Map.get(state, :target_fences))
    tasks = safe_map(Map.get(state, :tasks))

    {phase_counts, kind_counts} =
      Enum.reduce(Map.values(intents), {%{}, %{}}, fn intent, {phases, kinds} ->
        if is_map(intent) do
          phase = allow_status_phase(Map.get(intent, :phase))
          kind = allow_status_kind(Map.get(intent, :kind))

          {
            Map.update(phases, phase, 1, &(&1 + 1)),
            Map.update(kinds, kind, 1, &(&1 + 1))
          }
        else
          {phases, kinds}
        end
      end)

    %{
      runtime_admission: %{
        ready?: Map.get(state, :runtime_admission_ready?) == true,
        intent_count: safe_map_size(intents),
        waiter_count: safe_map_size(waiters),
        phase_counts: phase_counts,
        kind_counts: kind_counts,
        pending_observe_count: safe_map_size(Map.get(state, :runtime_admission_pending_observe)),
        pending_durable_mark_count:
          safe_map_size(Map.get(state, :runtime_admission_pending_durable_mark)),
        durable_mark_progress_count:
          safe_map_size(Map.get(state, :runtime_admission_durable_mark_progress)),
        pending_claim_join_count:
          safe_map_size(Map.get(state, :runtime_admission_pending_claim_join)),
        claim_join_progress_count:
          safe_map_size(Map.get(state, :runtime_admission_claim_join_progress)),
        owner_monitor_count: safe_map_size(Map.get(state, :runtime_admission_owner_monitors)),
        worker_monitor_count: safe_map_size(Map.get(state, :runtime_admission_worker_monitors)),
        launcher_monitor_count:
          safe_map_size(Map.get(state, :runtime_admission_launcher_monitors)),
        operation_launcher_count:
          safe_map_size(Map.get(state, :runtime_admission_operation_launches)),
        settle_timer_count: safe_map_size(Map.get(state, :runtime_admission_settle_timers)),
        pending_opts_count: safe_map_size(Map.get(state, :runtime_admission_pending_opts)),
        pending_durable_settle_count:
          safe_map_size(Map.get(state, :runtime_admission_pending_durable_settle))
      },
      fence: %{
        ready?: Map.get(state, :target_fence_ready?) == true,
        fence_count: safe_map_size(fences)
      },
      recovery: %{
        ready?: Map.get(state, :recovery_ready?) == true
      },
      tasks: %{
        count: safe_map_size(tasks)
      }
    }
  end

  defp project_public_status(_), do: closed_public_status_skeleton()

  defp safe_map(m) when is_map(m), do: m
  defp safe_map(_), do: %{}

  defp safe_map_size(m) when is_map(m), do: map_size(m)
  defp safe_map_size(_), do: 0

  defp allow_status_phase(phase) when is_atom(phase) do
    if MapSet.member?(@status_allowed_phases, phase), do: phase, else: :unknown
  end

  defp allow_status_phase(_), do: :unknown

  defp allow_status_kind(kind) when is_atom(kind) do
    if MapSet.member?(@status_allowed_kinds, kind), do: kind, else: :unknown
  end

  defp allow_status_kind(_), do: :unknown

  defp ensure_runtime_admission_shape(state) do
    state =
      state
      |> Map.put_new(:store_ref, @default_name)
      |> Map.put_new(:runtime_admission_supervisor, @default_runtime_admission_supervisor)
      |> Map.put_new(:runtime_admission_ready?, false)
      |> Map.put_new(:runtime_admission_intents, %{})
      |> Map.put_new(:runtime_admission_by_id, %{})
      |> Map.put_new(:runtime_admission_waiters, %{})
      |> Map.put_new(:runtime_admission_waiter_by_mon, %{})
      |> Map.put_new(:runtime_admission_waiter_by_deadline, %{})
      # Missing key means pre-F-575 hot state — migrate once, never every event.
      |> Map.put_new(:runtime_admission_waiter_schema_v, 0)
      |> Map.put_new(:runtime_admission_owner_monitors, %{})
      |> Map.put_new(:runtime_admission_worker_monitors, %{})
      |> Map.put_new(:runtime_admission_launcher_monitors, %{})
      |> Map.put_new(:runtime_admission_operation_launches, %{})
      |> Map.put_new(:runtime_admission_operation_launcher_monitors, %{})
      |> Map.put_new(:runtime_admission_pending_opts, %{})
      |> Map.put_new(:runtime_admission_settle_timers, %{})
      |> Map.put_new(:runtime_admission_pending_observe, %{})
      |> Map.put_new(:runtime_admission_observe_monitors, %{})
      |> Map.put_new(:runtime_admission_pending_durable_mark, %{})
      |> Map.put_new(:runtime_admission_durable_mark_monitors, %{})
      |> Map.put_new(:runtime_admission_durable_mark_progress, %{})
      |> Map.put_new(:runtime_admission_pending_durable_settle, %{})
      |> Map.put_new(:runtime_admission_durable_settle_monitors, %{})
      |> Map.put_new(:runtime_admission_durable_settle_progress, %{})
      |> Map.put_new(:runtime_admission_deferred_waiter_reply, %{})
      |> Map.put_new(:runtime_admission_pending_claim_join, %{})
      |> Map.put_new(:runtime_admission_claim_join_monitors, %{})
      |> Map.put_new(:runtime_admission_claim_join_progress, %{})
      |> Map.put_new(:runtime_admission_reconcile, %{status: :pending})
      |> Map.put_new(
        :max_runtime_admission_waiters,
        @default_max_runtime_admission_waiters
      )
      |> Map.put_new(:max_runtime_admission_intents, @default_max_runtime_admission_intents)
      |> Map.put_new(
        :runtime_admission_admit_timeout_ms,
        @default_runtime_admission_admit_timeout_ms
      )
      |> Map.put_new(
        :runtime_admission_settle_timeout_ms,
        @default_runtime_admission_settle_timeout_ms
      )
      |> Map.put_new(
        :runtime_admission_reconcile_timeout_ms,
        @default_runtime_admission_reconcile_timeout_ms
      )
      |> Map.put_new(
        :runtime_admission_observe_timeout_ms,
        @default_runtime_admission_observe_timeout_ms
      )
      |> Map.put_new(
        :runtime_admission_claim_join_timeout_ms,
        @default_runtime_admission_claim_join_timeout_ms
      )
      |> Map.put_new(
        :runtime_admission_durable_op_timeout_ms,
        @default_runtime_admission_durable_op_timeout_ms
      )

    state =
      Map.update!(state, :max_runtime_admission_waiters, &WaiterCore.normalize_max/1)

    case Map.get(state, :runtime_admission_waiter_schema_v, 0) do
      @runtime_admission_waiter_schema_v ->
        state

      version
      when is_integer(version) and version >= 0 and
             version < @runtime_admission_waiter_schema_v ->
        migrate_runtime_admission_waiter_schema(state)

      _unknown ->
        # A downgrade or malformed hot state cannot safely interpret newer
        # monitor/timer authority. Supervised restart recreates the current shape.
        exit(:runtime_admission_waiter_schema_unknown)
    end
  end

  if Mix.env() == :test do
    defp normalize_max_runtime_admission_waiters(opts) when is_list(opts) do
      WaiterCore.normalize_max(
        Keyword.get(opts, :max_runtime_admission_waiters, @default_max_runtime_admission_waiters)
      )
    end
  else
    defp normalize_max_runtime_admission_waiters(_opts),
      do: @default_max_runtime_admission_waiters
  end

  # One-time F-575 waiter schema migration. After this, insert/remove/detach are
  # O(1) index ops — never re-scan all waiters on every event.
  defp migrate_runtime_admission_waiter_schema(state) do
    waiters = Map.get(state, :runtime_admission_waiters, %{})
    by_mon = Map.get(state, :runtime_admission_waiter_by_mon, %{})
    by_dl = Map.get(state, :runtime_admission_waiter_by_deadline, %{})

    # Unrecoverable shapes (no safe from channel) force supervised restart so
    # OrdinaryStart follows the proven store-exit rejoin path rather than
    # silently stranding callers with live mon/timer residue.
    if runtime_admission_waiter_state_corrupt?(waiters) do
      exit(:runtime_admission_waiter_state_corrupt)
    end

    # Drain pre-F-575 raw-from lists once with typed wait_timeout so callers
    # are not stranded; never mutate the underlying intent.
    legacy_drains = WaiterCore.extract_legacy_drains(waiters)

    waiters_without_legacy =
      Enum.reduce(legacy_drains, waiters, fn {intent_id, _froms}, acc ->
        Map.delete(acc, intent_id)
      end)

    # A partial modern triple has ambiguous monitor/timer ownership. Restarting
    # drops all process-local resources atomically and lets OrdinaryStart rejoin.
    if not WaiterCore.correlated?(waiters_without_legacy, by_mon, by_dl) do
      exit(:runtime_admission_waiter_state_corrupt)
    end

    state = %{
      state
      | runtime_admission_waiters: waiters_without_legacy,
        runtime_admission_waiter_by_mon: by_mon,
        runtime_admission_waiter_by_deadline: by_dl,
        runtime_admission_waiter_schema_v: @runtime_admission_waiter_schema_v
    }

    Enum.each(legacy_drains, fn {_intent_id, froms} ->
      Enum.each(froms, fn from ->
        safe_runtime_admission_waiter_reply(from, {:error, :runtime_admission_wait_timeout})
      end)
    end)

    state
  end

  defp runtime_admission_waiter_state_corrupt?(waiters) when is_map(waiters) do
    Enum.any?(waiters, fn
      {intent_id, bucket} when is_binary(intent_id) and is_list(bucket) ->
        WaiterCore.classify_legacy(bucket) == :corrupt

      {intent_id, bucket} when is_binary(intent_id) and is_map(bucket) ->
        Enum.any?(bucket, fn
          {waiter_id, record} when is_reference(waiter_id) and is_map(record) -> false
          _ -> true
        end)

      _ ->
        true
    end)
  end

  defp runtime_admission_waiter_state_corrupt?(_), do: true

  defp do_admit_ordinary_runtime_start(
         state,
         target,
         fingerprint,
         validated_opts,
         from,
         wait_ms
       ) do
    intent_count = map_size(state.runtime_admission_intents)
    max = Map.get(state, :max_runtime_admission_intents, @default_max_runtime_admission_intents)
    intent_id = mint_runtime_admission_intent_id()

    case IntentCore.admit(
           state.runtime_admission_intents,
           state.target_fences,
           state.target_fence_ready? == true,
           state.runtime_admission_ready? == true,
           target,
           fingerprint,
           intent_id,
           intent_count,
           max
         ) do
      {:ok, :joined, intent, intents, _effects} ->
        case accept_runtime_admission_waiter(state, intent.intent_id, from, wait_ms) do
          {:ok, state} ->
            state = put_in(state, [:runtime_admission_intents], intents)
            {:noreply, state}

          {:error, :runtime_admission_waiters_full, state} ->
            {:reply, {:error, :runtime_admission_waiters_full}, state}
        end

      {:ok, :admitted, intent, intents, effects} ->
        case accept_runtime_admission_waiter(state, intent.intent_id, from, wait_ms) do
          {:ok, state} ->
            state =
              state
              |> put_in([:runtime_admission_intents], intents)
              |> put_in([:runtime_admission_by_id, intent.intent_id], target)

            state =
              Enum.reduce(effects, state, fn
                {:launch_owner, launched}, acc ->
                  launch_runtime_admission_owner(acc, launched, {:ordinary_start, validated_opts})

                _, acc ->
                  acc
              end)

            {:noreply, state}

          {:error, :runtime_admission_waiters_full, state} ->
            # Fresh admit with empty waiter set cannot hit full; fail closed.
            {:reply, {:error, :runtime_admission_waiters_full}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Guarded admit scalars: bound before any hash/admission work.
  @max_guarded_operation_id_bytes 128
  @max_guarded_token_bytes 32
  @guarded_operation_id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @guarded_token_re ~r/\Arrt_[A-Za-z0-9_-]{22}\z/

  defp do_admit_guarded_runtime_restore(
         state,
         target,
         operation_id,
         restore_token,
         from,
         wait_ms
       ) do
    with :ok <- validate_guarded_admit_scalars(target, operation_id, restore_token) do
      intent_count = runtime_admission_unresolved_target_count(state)
      max = Map.get(state, :max_runtime_admission_intents, @default_max_runtime_admission_intents)

      # Join first by exact operation+token — do NOT mint intent_id/fingerprint yet.
      case IntentCore.decide_guarded_admit(
             state.runtime_admission_intents,
             state.target_fences,
             state.target_fence_ready? == true,
             state.runtime_admission_ready? == true,
             target,
             operation_id,
             restore_token
           ) do
        {:ok, :joined, intent} ->
          case accept_runtime_admission_waiter(state, intent.intent_id, from, wait_ms) do
            {:ok, state} ->
              {:noreply, state}

            {:error, :runtime_admission_waiters_full, state} ->
              {:reply, {:error, :runtime_admission_waiters_full}, state}
          end

        {:ok, :fresh} ->
          # Mint identity only for a fresh slot.
          intent_id = mint_runtime_admission_intent_id()

          fingerprint =
            Arbor.Agent.RuntimeRestoreAdmissionClaimCore.fingerprint(
              operation_id,
              target,
              operation_id,
              restore_token,
              intent_id
            )

          case IntentCore.admit_guarded_fresh(
                 state.runtime_admission_intents,
                 target,
                 operation_id,
                 restore_token,
                 fingerprint,
                 intent_id,
                 intent_count,
                 max
               ) do
            {:ok, :admitted, intent, intents, effects} ->
              case accept_runtime_admission_waiter(state, intent.intent_id, from, wait_ms) do
                {:ok, state} ->
                  state =
                    state
                    |> put_in([:runtime_admission_intents], intents)
                    |> put_in([:runtime_admission_by_id, intent.intent_id], target)

                  payload =
                    {:guarded_restore,
                     %{
                       operation_id: operation_id,
                       restore_token: restore_token
                     }}

                  state =
                    Enum.reduce(effects, state, fn
                      {:launch_owner, launched}, acc ->
                        launch_runtime_admission_owner(acc, launched, payload)

                      _, acc ->
                        acc
                    end)

                  {:noreply, state}

                {:error, :runtime_admission_waiters_full, state} ->
                  {:reply, {:error, :runtime_admission_waiters_full}, state}
              end

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp validate_guarded_admit_scalars(target, operation_id, restore_token) do
    cond do
      not is_binary(target) or byte_size(target) == 0 or
          byte_size(target) > @max_fence_agent_id_bytes ->
        {:error, :invalid_target}

      not is_binary(operation_id) or byte_size(operation_id) == 0 or
          byte_size(operation_id) > @max_guarded_operation_id_bytes ->
        {:error, :invalid_operation_id}

      not String.valid?(operation_id) or not Regex.match?(@guarded_operation_id_re, operation_id) ->
        {:error, :invalid_operation_id}

      not is_binary(restore_token) or byte_size(restore_token) > @max_guarded_token_bytes ->
        {:error, :invalid_restore_token}

      not String.valid?(restore_token) or not Regex.match?(@guarded_token_re, restore_token) ->
        {:error, :invalid_restore_token}

      true ->
        :ok
    end
  end

  # Exhausted durable shells deliberately retain a fail-closed target hold.
  # Count those dormant targets together with live intents before admitting a
  # fresh guarded restore so retained recovery evidence cannot grow without
  # bound across a stream of unique targets.
  defp runtime_admission_unresolved_target_count(state) do
    intent_targets = Map.keys(Map.get(state, :runtime_admission_intents, %{}))

    progress_targets =
      [
        :runtime_admission_durable_mark_progress,
        :runtime_admission_durable_settle_progress,
        :runtime_admission_claim_join_progress
      ]
      |> Enum.flat_map(fn key ->
        state
        |> Map.get(key, %{})
        |> Enum.flat_map(fn
          {target, %{status: status}}
          when is_binary(target) and
                 status in [:pending, :launch_retry, :shell_error_retry, :retry, :exhausted] ->
            [target]

          _ ->
            []
        end)
      end)

    intent_targets
    |> Kernel.++(progress_targets)
    |> MapSet.new()
    |> MapSet.size()
  end

  # Cap check BEFORE mon/timer allocation. Authority fields are store-minted only.
  defp accept_runtime_admission_waiter(state, intent_id, from, wait_ms)
       when is_binary(intent_id) do
    state = ensure_runtime_admission_shape(state)
    wait_ms = clamp_runtime_admission_waiter_deadline_ms(wait_ms)
    max = Map.get(state, :max_runtime_admission_waiters, @default_max_runtime_admission_waiters)
    count = WaiterCore.intent_count(state.runtime_admission_waiters, intent_id)

    case WaiterCore.can_accept?(count, max) do
      {:error, :runtime_admission_waiters_full} ->
        {:error, :runtime_admission_waiters_full, state}

      :ok ->
        {caller_pid, _tag} = from
        waiter_id = make_ref()
        mon = Process.monitor(caller_pid)
        deadline_token = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:runtime_admission_waiter_timeout, deadline_token},
            wait_ms
          )

        record = %{
          waiter_id: waiter_id,
          intent_id: intent_id,
          from: from,
          caller_pid: caller_pid,
          mon: mon,
          deadline_token: deadline_token,
          timer_ref: timer_ref
        }

        case WaiterCore.insert(
               state.runtime_admission_waiters,
               state.runtime_admission_waiter_by_mon,
               state.runtime_admission_waiter_by_deadline,
               record,
               max
             ) do
          {:ok, waiters, by_mon, by_dl} ->
            state = %{
              state
              | runtime_admission_waiters: waiters,
                runtime_admission_waiter_by_mon: by_mon,
                runtime_admission_waiter_by_deadline: by_dl
            }

            {:ok, state}

          {:error, :runtime_admission_waiters_full} ->
            _ = Process.cancel_timer(timer_ref)
            Process.demonitor(mon, [:flush])
            {:error, :runtime_admission_waiters_full, state}

          {:error, reason} ->
            _ = Process.cancel_timer(timer_ref)
            Process.demonitor(mon, [:flush])
            exit({:runtime_admission_waiter_insert_failed, reason})
        end
    end
  end

  defp release_runtime_admission_waiter_resources(record) when is_map(record) do
    if is_reference(Map.get(record, :timer_ref)) do
      _ = Process.cancel_timer(record.timer_ref)
    end

    if is_reference(Map.get(record, :mon)) do
      Process.demonitor(record.mon, [:flush])
    end

    :ok
  end

  defp safe_runtime_admission_waiter_reply(from, reply) do
    GenServer.reply(from, reply)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp detach_and_reply_runtime_admission_waiters(state, intent_id, reply)
       when is_binary(intent_id) do
    state = ensure_runtime_admission_shape(state)

    {records, waiters, by_mon, by_dl} =
      WaiterCore.detach_all(
        state.runtime_admission_waiters,
        state.runtime_admission_waiter_by_mon,
        state.runtime_admission_waiter_by_deadline,
        intent_id
      )

    # Detach authority first so reentrant/queued stale events observe consumption.
    state = %{
      state
      | runtime_admission_waiters: waiters,
        runtime_admission_waiter_by_mon: by_mon,
        runtime_admission_waiter_by_deadline: by_dl
    }

    Enum.each(records, &release_runtime_admission_waiter_resources/1)
    Enum.each(records, fn rec -> safe_runtime_admission_waiter_reply(rec.from, reply) end)
    state
  end

  defp handle_runtime_admission_waiter_timeout(state, deadline_token)
       when is_reference(deadline_token) do
    state = ensure_runtime_admission_shape(state)

    case WaiterCore.remove_by_deadline(
           state.runtime_admission_waiters,
           state.runtime_admission_waiter_by_mon,
           state.runtime_admission_waiter_by_deadline,
           deadline_token
         ) do
      {:ok, record, waiters, by_mon, by_dl} ->
        state = %{
          state
          | runtime_admission_waiters: waiters,
            runtime_admission_waiter_by_mon: by_mon,
            runtime_admission_waiter_by_deadline: by_dl
        }

        release_runtime_admission_waiter_resources(record)

        safe_runtime_admission_waiter_reply(
          record.from,
          {:error, :runtime_admission_wait_timeout}
        )

        state

      :stale ->
        state
    end
  end

  defp handle_runtime_admission_waiter_down(state, mon) when is_reference(mon) do
    state = ensure_runtime_admission_shape(state)

    case WaiterCore.remove_by_mon(
           state.runtime_admission_waiters,
           state.runtime_admission_waiter_by_mon,
           state.runtime_admission_waiter_by_deadline,
           mon
         ) do
      {:ok, record, waiters, by_mon, by_dl} ->
        state = %{
          state
          | runtime_admission_waiters: waiters,
            runtime_admission_waiter_by_mon: by_mon,
            runtime_admission_waiter_by_deadline: by_dl
        }

        # Caller is dead — cancel timer and flush mon; never reply; never mutate intent.
        release_runtime_admission_waiter_resources(record)
        state

      :stale ->
        state
    end
  end

  defp mint_runtime_admission_intent_id do
    "rai_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp launch_runtime_admission_owner(state, intent, payload) do
    target = intent.target_agent_id
    current = Map.get(state.runtime_admission_intents, target)

    if is_map(current) and is_reference(Map.get(current, :launch_ref)) do
      # One outstanding launch attempt only.
      state
    else
      state =
        put_in(
          state,
          [:runtime_admission_pending_opts, intent.intent_id],
          payload
        )

      do_launch_runtime_admission_owner(state, intent, payload, 1)
    end
  end

  defp do_launch_runtime_admission_owner(state, intent, payload, attempt_index)
       when is_integer(attempt_index) and attempt_index > 0 do
    store_ref = Map.get(state, :store_ref, @default_name)

    supervisor =
      Map.get(state, :runtime_admission_supervisor, @default_runtime_admission_supervisor)

    task_supervisor = Map.get(state, :task_supervisor, @default_task_supervisor)
    launch_ref = make_ref()
    target = intent.target_agent_id

    case IntentCore.begin_owner_launch(
           state.runtime_admission_intents,
           target,
           launch_ref,
           attempt_index
         ) do
      {:ok, _updated, intents} ->
        {launcher_pid, launcher_mon} =
          spawn_monitor(__MODULE__, :runtime_admission_owner_launcher, [
            store_ref,
            launch_ref,
            supervisor,
            task_supervisor,
            intent.intent_id,
            target,
            intent.fingerprint,
            payload
          ])

        case IntentCore.attach_launcher(
               intents,
               target,
               launch_ref,
               launcher_pid,
               launcher_mon
             ) do
          {:ok, intents2} ->
            state
            |> put_in([:runtime_admission_intents], intents2)
            |> put_in(
              [:runtime_admission_launcher_monitors, launcher_mon],
              {intent.intent_id, target, launch_ref, launcher_pid}
            )
            |> put_in([:runtime_admission_by_id, intent.intent_id], target)

          {:error, _} ->
            Process.demonitor(launcher_mon, [:flush])
            if Process.alive?(launcher_pid), do: Process.exit(launcher_pid, :kill)
            put_in(state, [:runtime_admission_intents], intents)
        end

      {:error, _} ->
        state
    end
  end

  @doc false
  def runtime_admission_owner_launcher(
        store_ref,
        launch_ref,
        supervisor,
        task_supervisor,
        intent_id,
        target,
        fingerprint,
        payload
      )
      when is_reference(launch_ref) do
    start_opts = [
      intent_id: intent_id,
      target_agent_id: target,
      fingerprint: fingerprint,
      worker_payload: payload,
      # Back-compat for ordinary path keyword name used by IntentOwner.
      validated_opts: payload,
      store_ref: store_ref,
      task_supervisor: task_supervisor,
      launch_ref: launch_ref
    ]

    case start_owner_with_collision_retry(start_opts, supervisor, target, 0) do
      {:ok, owner_pid} when is_pid(owner_pid) ->
        # Bind already completed inside IntentOwner.init; success is optional/inert.
        send(store_ref, {:runtime_admission_owner_launched, launch_ref, intent_id, owner_pid})

      {:ok, owner_pid, _} when is_pid(owner_pid) ->
        send(store_ref, {:runtime_admission_owner_launched, launch_ref, intent_id, owner_pid})

      {:error, reason} ->
        send(
          store_ref,
          {:runtime_admission_owner_launch_failed, launch_ref, intent_id, reason}
        )

      other ->
        send(
          store_ref,
          {:runtime_admission_owner_launch_failed, launch_ref, intent_id, other}
        )
    end

    :ok
  rescue
    _ ->
      send(
        store_ref,
        {:runtime_admission_owner_launch_failed, launch_ref, intent_id, :launcher_exception}
      )

      :ok
  catch
    :exit, _ ->
      send(
        store_ref,
        {:runtime_admission_owner_launch_failed, launch_ref, intent_id, :launcher_exit}
      )

      :ok
  end

  # External launcher only: retry :target_owner_taken when Registry empty/dead.
  # Never called from TaskStore GenServer callbacks.
  defp start_owner_with_collision_retry(start_opts, supervisor, target, attempt) do
    case RuntimeAdmissionSupervisor.start_owner(start_opts, supervisor) do
      {:ok, _} = ok ->
        ok

      {:ok, _, _} = ok ->
        ok

      {:error, :target_owner_taken} ->
        if attempt < @runtime_admission_launcher_collision_retries and
             registry_owner_absent_or_dead?(target) do
          Process.sleep(@runtime_admission_launcher_collision_sleep_ms)
          start_owner_with_collision_retry(start_opts, supervisor, target, attempt + 1)
        else
          {:error, :target_owner_taken}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp registry_owner_absent_or_dead?(target) do
    case Registry.lookup(@runtime_admission_registry, {:runtime_admission_owner, target}) do
      [] ->
        true

      entries when is_list(entries) ->
        Enum.all?(entries, fn {pid, _} -> not Process.alive?(pid) end)

      _ ->
        false
    end
  end

  # Caller-facing settle: only the exact bound worker may settle (including
  # late terminal while await_worker_down is held).
  defp authorize_and_settle_runtime_admission(state, target, intent_id, outcome, caller_pid) do
    intent = Map.get(state.runtime_admission_intents, target)

    cond do
      not is_map(intent) ->
        {:error, :not_found, state}

      intent.intent_id != intent_id ->
        {:error, :conflict, state}

      intent.phase == :settling ->
        # First terminal already won; idempotent only for the exact worker.
        if intent.worker_pid == caller_pid do
          {:ok, state}
        else
          {:error, :not_owner, state}
        end

      IntentCore.settle_eligible_worker?(intent, caller_pid) ->
        # Propagate transition failure — never reply :ok if no terminal accepted.
        request_runtime_admission_terminal(state, target, intent_id, outcome, :worker_settle)

      intent.worker_pid != caller_pid ->
        {:error, :not_owner, state}

      true ->
        {:error, :conflict, state}
    end
  end

  # Two-phase terminal request: begin settling (retain waiters) then barrier.
  # Returns {:ok, state} | {:error, reason, state}.
  defp request_runtime_admission_terminal(state, target, intent_id, outcome, _source) do
    state = ensure_runtime_admission_shape(state)
    intent = Map.get(state.runtime_admission_intents, target)

    cond do
      not is_map(intent) ->
        {:error, :not_found, state}

      intent.intent_id != intent_id ->
        {:error, :conflict, state}

      true ->
        case IntentCore.begin_settling(
               state.runtime_admission_intents,
               target,
               intent_id,
               outcome
             ) do
          {:ok, :already_settling, _intent, _intents, _} ->
            # First terminal already accepted — idempotent success.
            {:ok, state}

          {:ok, :ownerless_finalize, intent, intents, _} ->
            state = put_in(state, [:runtime_admission_intents], intents)
            # Route through immediate_finalize so guarded durable convergence +
            # deferred waiter reply apply uniformly.
            state =
              immediate_finalize_runtime_admission(state, target, intent_id, :ownerless)

            # immediate_finalize always returns state; surface not_found if gone.
            if is_map(intent) do
              {:ok, state}
            else
              {:ok, state}
            end

          {:ok, :begin, _intent, intents, effects} ->
            state = put_in(state, [:runtime_admission_intents], intents)

            state =
              Enum.reduce(effects, state, fn
                {:shutdown_owner, owner_pid}, acc when is_pid(owner_pid) ->
                  # Never :normal — external normal does not retire IntentOwner.
                  Process.exit(owner_pid, :shutdown)
                  arm_runtime_admission_settle_timer(acc, intent_id, owner_pid)

                _, acc ->
                  acc
              end)

            # Terminal accepted; waiters released only after owner DOWN.
            {:ok, state}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp arm_runtime_admission_settle_timer(state, intent_id, owner_pid) do
    timeout =
      Map.get(
        state,
        :runtime_admission_settle_timeout_ms,
        @default_runtime_admission_settle_timeout_ms
      )

    gen = System.unique_integer([:positive])

    timer_ref =
      Process.send_after(self(), {:runtime_admission_settle_timeout, intent_id, gen}, timeout)

    timers =
      Map.put(Map.get(state, :runtime_admission_settle_timers, %{}), intent_id, %{
        timer_ref: timer_ref,
        gen: gen,
        owner_pid: owner_pid
      })

    %{state | runtime_admission_settle_timers: timers}
  end

  # Timer may escalate to :kill only — never finalize from timer or alive?.
  defp handle_runtime_admission_settle_timeout(state, intent_id, gen) do
    state = ensure_runtime_admission_shape(state)
    entry = Map.get(Map.get(state, :runtime_admission_settle_timers, %{}), intent_id)
    target = Map.get(state.runtime_admission_by_id, intent_id)
    intent = if is_binary(target), do: Map.get(state.runtime_admission_intents, target)

    cond do
      not is_map(entry) or entry.gen != gen ->
        state

      not is_map(intent) or intent.intent_id != intent_id ->
        drop_settle_timer(state, intent_id)

      intent.phase != :settling or Map.get(intent, :retire_barrier) != :await_owner_down ->
        drop_settle_timer(state, intent_id)

      true ->
        owner_pid = Map.get(entry, :owner_pid) || Map.get(intent, :owner_pid)

        if is_pid(owner_pid) do
          Process.exit(owner_pid, :kill)
        end

        # Retain intent, waiters, monitors — await authentic owner DOWN.
        drop_settle_timer(state, intent_id)
    end
  end

  defp drop_settle_timer(state, intent_id) do
    timers = Map.get(state, :runtime_admission_settle_timers, %{})

    case Map.pop(timers, intent_id) do
      {nil, _} ->
        state

      {%{timer_ref: ref}, rest} when is_reference(ref) ->
        _ = Process.cancel_timer(ref)
        %{state | runtime_admission_settle_timers: rest}

      {_, rest} ->
        %{state | runtime_admission_settle_timers: rest}
    end
  end

  # Finalize only when the retirement barrier allows (ownerless or owner DOWN).
  # Mutate pure intent map first; reply waiters only after successful delete —
  # and for guarded restore only after durable settlement is reobserved (or the
  # deferred reply is released by the durable shell).
  # mode:
  #   {:await_owner_down, monitored_owner_pid}
  #   | :ownerless
  #   | {:commit_owner_gone, monitored_owner_pid, terminal}
  #   | {:commit, terminal}  # true ownerless (never had owner)
  #   | {:commit_durable_observed, terminal}  # ownerless; durable already settled/absent
  defp immediate_finalize_runtime_admission(state, target, intent_id, mode) do
    state = ensure_runtime_admission_shape(state)
    pre_intent = Map.get(state.runtime_admission_intents, target)
    durable_already_observed? = match?({:commit_durable_observed, _}, mode)

    case pure_delete_runtime_admission_terminal(state, target, intent_id, mode) do
      {:ok, done, state} ->
        reply = settlement_reply(Map.get(done, :terminal))
        terminal = Map.get(done, :terminal)

        state =
          state
          |> drop_settle_timer(intent_id)
          |> update_in([:runtime_admission_by_id], &Map.delete(&1, intent_id))
          |> flush_monitors_for_intent(intent_id)

        # Launch durable convergence for every source-auth determinate guarded
        # terminal when not already in flight (worker settle may have launched).
        state =
          if durable_already_observed? or
               durable_convergence_outstanding?(state, target, intent_id) do
            state
          else
            maybe_launch_guarded_durable_settle_after_accept(
              state,
              pre_intent,
              intent_id,
              terminal
            )
          end

        if durable_convergence_outstanding?(state, target, intent_id) do
          # Defer waiter success until durable reobservation; fence held by progress.
          put_in(
            state,
            [:runtime_admission_deferred_waiter_reply, intent_id],
            %{reply: reply, target: target, intent_id: intent_id}
          )
        else
          detach_and_reply_runtime_admission_waiters(state, intent_id, reply)
        end

      {:error, _reason, state} ->
        # Fail closed: no waiter reply, no force-delete, retain authority.
        state
    end
  end

  # Fence remains held while a non-idle guarded intent exists OR while durable
  # mark/settle/join convergence for the target is outstanding (including
  # exhausted blocking evidence). Closes the retire-before-durable gap.
  defp fence_held_by_restore?(state, target) when is_binary(target) do
    IntentCore.non_idle_guarded_restore?(state.runtime_admission_intents, target) or
      durable_op_holds_target?(state, target)
  end

  defp durable_op_holds_target?(state, target) when is_binary(target) do
    settle_pending? =
      state
      |> Map.get(:runtime_admission_pending_durable_settle, %{})
      |> Map.values()
      |> Enum.any?(fn
        %{target: ^target} -> true
        %{request: %{target: ^target}} -> true
        meta when is_map(meta) -> Map.get(meta, :target) == target
        _ -> false
      end)

    mark_pending? =
      state
      |> Map.get(:runtime_admission_pending_durable_mark, %{})
      |> Map.values()
      |> Enum.any?(fn
        %{target: ^target} -> true
        _ -> false
      end)

    join_pending? =
      state
      |> Map.get(:runtime_admission_pending_claim_join, %{})
      |> Map.values()
      |> Enum.any?(fn
        %{target: ^target} -> true
        _ -> false
      end)

    settle_progress_hold? =
      case Map.get(Map.get(state, :runtime_admission_durable_settle_progress, %{}), target) do
        %{status: status}
        when status in [:pending, :launch_retry, :shell_error_retry, :exhausted] ->
          true

        _ ->
          false
      end

    mark_progress_hold? =
      case Map.get(Map.get(state, :runtime_admission_durable_mark_progress, %{}), target) do
        %{status: status}
        when status in [:pending, :launch_retry, :shell_error_retry, :exhausted] ->
          true

        _ ->
          false
      end

    join_progress_hold? =
      case Map.get(Map.get(state, :runtime_admission_claim_join_progress, %{}), target) do
        %{status: status} when status in [:pending, :retry, :launch_retry, :exhausted] ->
          true

        _ ->
          false
      end

    settle_pending? or mark_pending? or join_pending? or settle_progress_hold? or
      mark_progress_hold? or join_progress_hold?
  end

  defp durable_convergence_outstanding?(state, target, intent_id)
       when is_binary(target) and is_binary(intent_id) do
    settle_pending? =
      state
      |> Map.get(:runtime_admission_pending_durable_settle, %{})
      |> Map.values()
      |> Enum.any?(fn meta ->
        is_map(meta) and Map.get(meta, :target) == target and
          Map.get(meta, :intent_id) == intent_id
      end)

    settle_progress? =
      case Map.get(Map.get(state, :runtime_admission_durable_settle_progress, %{}), target) do
        %{intent_id: ^intent_id, status: status}
        when status in [:pending, :launch_retry, :shell_error_retry, :exhausted] ->
          true

        _ ->
          false
      end

    settle_pending? or settle_progress?
  end

  # Pure commit+delete. Never replies. Never Map.delete without core success.
  # Never mutates owner_pid outside IntentCore transitions.
  defp pure_delete_runtime_admission_terminal(state, target, intent_id, mode) do
    intents = state.runtime_admission_intents
    intent = Map.get(intents, target)

    cond do
      not is_map(intent) or intent.intent_id != intent_id ->
        {:error, :not_found, state}

      match?({:await_owner_down, pid} when is_pid(pid), mode) ->
        {:await_owner_down, expected_owner} = mode

        case IntentCore.finalize_settled(intents, target, intent_id, expected_owner) do
          {:ok, done, new_intents} ->
            {:ok, done, put_in(state, [:runtime_admission_intents], new_intents)}

          {:error, reason} ->
            {:error, reason, state}
        end

      mode == :ownerless ->
        case IntentCore.finalize_ownerless(intents, target, intent_id) do
          {:ok, done, new_intents} ->
            {:ok, done, put_in(state, [:runtime_admission_intents], new_intents)}

          {:error, reason} ->
            {:error, reason, state}
        end

      match?({:commit_owner_gone, pid, _} when is_pid(pid), mode) ->
        {:commit_owner_gone, expected_owner, terminal} = mode

        case IntentCore.commit_terminal_owner_gone(
               intents,
               target,
               intent_id,
               expected_owner,
               terminal
             ) do
          {:ok, _updated, mid} ->
            case IntentCore.finalize_ownerless(mid, target, intent_id) do
              {:ok, done, new_intents} ->
                {:ok, done, put_in(state, [:runtime_admission_intents], new_intents)}

              {:error, reason} ->
                {:error, reason, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end

      match?({:commit, _}, mode) ->
        {:commit, terminal} = mode

        commit_ownerless_runtime_admission_terminal(state, intents, target, intent_id, terminal)

      match?({:commit_durable_observed, _}, mode) ->
        {:commit_durable_observed, terminal} = mode

        commit_ownerless_runtime_admission_terminal(state, intents, target, intent_id, terminal)

      true ->
        {:error, :invalid_finalize_mode, state}
    end
  end

  defp commit_ownerless_runtime_admission_terminal(
         state,
         intents,
         target,
         intent_id,
         terminal
       ) do
    case IntentCore.begin_settling(intents, target, intent_id, terminal) do
      {:ok, :ownerless_finalize, _intent, mid, _} ->
        case IntentCore.finalize_ownerless(mid, target, intent_id) do
          {:ok, done, new_intents} ->
            {:ok, done, put_in(state, [:runtime_admission_intents], new_intents)}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:ok, :already_settling, already, mid, _} ->
        cond do
          Map.get(already, :retire_barrier) == :await_owner_down and
              is_pid(Map.get(already, :owner_pid)) ->
            case IntentCore.finalize_settled(
                   mid,
                   target,
                   intent_id,
                   already.owner_pid
                 ) do
              {:ok, done, new_intents} ->
                {:ok, done, put_in(state, [:runtime_admission_intents], new_intents)}

              {:error, reason} ->
                {:error, reason, state}
            end

          not is_pid(Map.get(already, :owner_pid)) ->
            case IntentCore.finalize_ownerless(mid, target, intent_id) do
              {:ok, done, new_intents} ->
                {:ok, done, put_in(state, [:runtime_admission_intents], new_intents)}

              {:error, reason} ->
                {:error, reason, state}
            end

          true ->
            {:error, :owner_barrier_outstanding, state}
        end

      {:ok, :begin, _intent, _mid, _effects} ->
        # Live owner barrier still outstanding — fail closed without mutating
        # or replying. Caller must use request_runtime_admission_terminal.
        {:error, :owner_barrier_outstanding, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp settlement_reply({:applied, pid}) when is_pid(pid), do: {:ok, pid}

  defp settlement_reply({:error, reason}),
    do: {:error, bounded_source_terminal_reason(reason)}

  defp settlement_reply({:conflict, reason}),
    do: {:error, {:conflict, bounded_source_terminal_reason(reason)}}

  defp settlement_reply(other), do: {:error, IntentCore.redact_error_reason(other)}

  # Exact source-authenticated atom terminals are already bounded VM values and
  # are part of the existing waiter contract. Structured or textual details can
  # carry secrets and still pass through the closed redactor.
  defp bounded_source_terminal_reason(reason) when is_atom(reason), do: reason
  defp bounded_source_terminal_reason(reason), do: IntentCore.redact_error_reason(reason)

  defp flush_monitors_for_intent(state, intent_id) do
    owner_mons = Map.get(state, :runtime_admission_owner_monitors, %{})
    worker_mons = Map.get(state, :runtime_admission_worker_monitors, %{})
    launcher_mons = Map.get(state, :runtime_admission_launcher_monitors, %{})

    owner_kept =
      owner_mons
      |> Enum.reject(fn {mon, {id, _t, _p}} ->
        if id == intent_id do
          Process.demonitor(mon, [:flush])
          true
        else
          false
        end
      end)
      |> Map.new()

    worker_kept =
      worker_mons
      |> Enum.reject(fn {mon, {id, _t, _p}} ->
        if id == intent_id do
          Process.demonitor(mon, [:flush])
          true
        else
          false
        end
      end)
      |> Map.new()

    launcher_kept =
      launcher_mons
      |> Enum.reject(fn {mon, {id, _t, _ref, launcher_pid}} ->
        if id == intent_id do
          terminate_and_demonitor_launcher(mon, launcher_pid)
          true
        else
          false
        end
      end)
      |> Map.new()

    pending = Map.get(state, :runtime_admission_pending_opts, %{})

    %{
      state
      | runtime_admission_owner_monitors: owner_kept,
        runtime_admission_worker_monitors: worker_kept,
        runtime_admission_launcher_monitors: launcher_kept,
        runtime_admission_pending_opts: Map.delete(pending, intent_id)
    }
  end

  defp ensure_owner_monitor(state, intent_id, target, owner_pid)
       when is_binary(intent_id) and is_binary(target) and is_pid(owner_pid) do
    already? =
      state.runtime_admission_owner_monitors
      |> Map.values()
      |> Enum.any?(fn
        {^intent_id, ^target, ^owner_pid} -> true
        _ -> false
      end)

    if already? do
      state
    else
      mon = Process.monitor(owner_pid)

      put_in(
        state,
        [:runtime_admission_owner_monitors, mon],
        {intent_id, target, owner_pid}
      )
    end
  end

  defp clear_launcher_monitor_for_intent(state, intent_id, target) do
    state = ensure_runtime_admission_shape(state)
    mons = Map.get(state, :runtime_admission_launcher_monitors, %{})

    # Successful bind: flush mon only. Do not kill the launcher while it may
    # still be blocked in start_child returning to the helper.
    kept =
      Enum.reduce(mons, %{}, fn
        {mon, {^intent_id, ^target, _ref, _pid}}, acc ->
          if is_reference(mon), do: Process.demonitor(mon, [:flush])
          acc

        {mon, entry}, acc ->
          Map.put(acc, mon, entry)
      end)

    %{state | runtime_admission_launcher_monitors: kept}
  end

  defp terminate_and_demonitor_launcher(mon, launcher_pid) do
    if is_reference(mon), do: Process.demonitor(mon, [:flush])

    if is_pid(launcher_pid) and Process.alive?(launcher_pid) do
      Process.exit(launcher_pid, :kill)
    end

    :ok
  end

  defp handle_authenticated_launch_failure(state, launch_ref, intent_id, reason)
       when is_reference(launch_ref) and is_binary(intent_id) do
    case Map.get(state.runtime_admission_by_id, intent_id) do
      target when is_binary(target) ->
        case IntentCore.consume_launch_failure(
               state.runtime_admission_intents,
               target,
               intent_id,
               launch_ref
             ) do
          {:ok, intents, launcher_mon} ->
            state =
              state
              |> put_in([:runtime_admission_intents], intents)
              |> terminate_launcher_entry(launcher_mon, intent_id, target)

            maybe_retry_or_terminal_launch(state, target, intent_id, reason)

          {:error, :already_bound} ->
            # Bind won the race — failure is stale.
            state

          {:error, _} ->
            state
        end

      _ ->
        state
    end
  end

  defp handle_runtime_admission_launcher_down(state, mon, intent_id, target, launch_ref)
       when is_reference(mon) and is_binary(intent_id) and is_binary(target) and
              is_reference(launch_ref) do
    state = ensure_runtime_admission_shape(state)
    state = update_in(state, [:runtime_admission_launcher_monitors], &Map.delete(&1, mon))

    case IntentCore.consume_launch_failure(
           state.runtime_admission_intents,
           target,
           intent_id,
           launch_ref
         ) do
      {:ok, intents, _mon} ->
        state = put_in(state, [:runtime_admission_intents], intents)
        maybe_retry_or_terminal_launch(state, target, intent_id, :launcher_exit)

      {:error, :already_bound} ->
        state

      {:error, _} ->
        state
    end
  end

  # Settlement / auth-fail cleanup: kill a blocked launcher so it cannot leak.
  defp terminate_launcher_entry(state, launcher_mon, intent_id, target)
       when is_reference(launcher_mon) do
    mons = Map.get(state, :runtime_admission_launcher_monitors, %{})

    case Map.get(mons, launcher_mon) do
      {^intent_id, ^target, _ref, launcher_pid} ->
        terminate_and_demonitor_launcher(launcher_mon, launcher_pid)
        %{state | runtime_admission_launcher_monitors: Map.delete(mons, launcher_mon)}

      _ ->
        Process.demonitor(launcher_mon, [:flush])
        %{state | runtime_admission_launcher_monitors: Map.delete(mons, launcher_mon)}
    end
  end

  defp terminate_launcher_entry(state, _launcher_mon, _intent_id, _target), do: state

  defp maybe_retry_or_terminal_launch(state, target, intent_id, reason) do
    intent = Map.get(state.runtime_admission_intents, target)
    bounded = IntentCore.redact_error_reason(reason)

    cond do
      not is_map(intent) or intent.intent_id != intent_id ->
        state

      is_pid(Map.get(intent, :owner_pid)) ->
        state

      IntentCore.retryable_launcher_failure?(reason) ->
        attempt = Map.get(intent, :launcher_attempt_index, 1)

        if attempt < @runtime_admission_launcher_max_attempts do
          payload = Map.get(state.runtime_admission_pending_opts, intent_id)

          if valid_owner_payload?(payload) do
            do_launch_runtime_admission_owner(
              state,
              intent,
              payload,
              attempt + 1
            )
          else
            terminalize_launch_failure(state, target, intent_id, bounded)
          end
        else
          terminalize_launch_failure(state, target, intent_id, :launch_retry_exhausted)
        end

      true ->
        terminalize_launch_failure(state, target, intent_id, bounded)
    end
  end

  defp terminalize_launch_failure(state, target, intent_id, bounded) do
    state = update_in(state, [:runtime_admission_pending_opts], &Map.delete(&1, intent_id))

    case request_runtime_admission_terminal(
           state,
           target,
           intent_id,
           {:error, bounded},
           :launch_failed
         ) do
      {:ok, s} -> s
      {:error, _, s} -> s
    end
  end

  defp valid_owner_payload?({:ordinary_start, opts}) when is_list(opts), do: true
  defp valid_owner_payload?({:guarded_restore, map}) when is_map(map), do: true
  # Legacy ordinary path stored bare keyword lists.
  defp valid_owner_payload?(opts) when is_list(opts), do: true
  defp valid_owner_payload?(_), do: false

  defp handle_runtime_admission_owner_down(state, mon, intent_id, target, monitored_owner_pid)
       when is_pid(monitored_owner_pid) do
    state = ensure_runtime_admission_shape(state)
    state = update_in(state, [:runtime_admission_owner_monitors], &Map.delete(&1, mon))
    intent = Map.get(state.runtime_admission_intents, target)

    cond do
      not is_map(intent) or intent.intent_id != intent_id ->
        state

      # Exact monitored owner must match intent.owner_pid — stale DOWN after
      # rebound must not clear or retire the new owner.
      Map.get(intent, :owner_pid) != monitored_owner_pid ->
        state

      intent.phase == :settling and Map.get(intent, :retire_barrier) == :await_owner_down ->
        # Branch A: terminal known; exact owner barrier complete.
        immediate_finalize_runtime_admission(
          state,
          target,
          intent_id,
          {:await_owner_down, monitored_owner_pid}
        )

      true ->
        # Branch B: unexpected owner DOWN (open / not settling with owner barrier).
        handle_unexpected_owner_down(state, target, intent, monitored_owner_pid)
    end
  end

  defp handle_unexpected_owner_down(state, target, intent, monitored_owner_pid)
       when is_pid(monitored_owner_pid) do
    # Registry/branch observation is I/O — fixed async observer only.
    enqueue_runtime_admission_witness_observe(state, %{
      reason: :unexpected_owner_down,
      source: :owner,
      target: target,
      intent_id: intent.intent_id,
      fingerprint: intent.fingerprint,
      kind: Map.get(intent, :kind, :ordinary_start),
      operation_id: Map.get(intent, :operation_id),
      restore_token: Map.get(intent, :restore_token),
      effect_handoff?: Map.get(intent, :effect_handoff?) == true,
      monitored_owner_pid: monitored_owner_pid
    })
  end

  defp park_guarded_outcome_unknown(state, target, intent, monitored_owner_pid) do
    intent_id = intent.intent_id

    state =
      case IntentCore.note_owner_gone_await_worker(
             state.runtime_admission_intents,
             target,
             intent_id,
             monitored_owner_pid
           ) do
        {:ok, _updated, intents, effects} ->
          state
          |> put_in([:runtime_admission_intents], intents)
          |> apply_runtime_admission_effects(effects)

        {:ok, :already_awaiting, _intent, intents, effects} ->
          state
          |> put_in([:runtime_admission_intents], intents)
          |> apply_runtime_admission_effects(effects)

        {:error, :already_settling} ->
          state

        {:error, _} ->
          updated = %{
            intent
            | phase: :outcome_unknown,
              owner_pid: nil,
              retire_barrier: :none,
              effect_handoff?: true
          }

          put_in(state, [:runtime_admission_intents, target], updated)
      end

    # Drive dedicated durable mark outside the callback (retry/reobserve).
    launch_durable_mark_outcome_unknown(state, intent)
  end

  defp apply_runtime_admission_effects(state, effects) when is_list(effects) do
    Enum.reduce(effects, state, fn
      {:kill_worker, pid}, acc when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        acc

      _, acc ->
        acc
    end)
  end

  defp maybe_await_worker_or_finalize(
         state,
         target,
         intent,
         monitored_owner_pid,
         fallback_terminal
       )
       when is_pid(monitored_owner_pid) do
    intent_id = intent.intent_id
    worker_pid = Map.get(intent, :worker_pid)

    if is_pid(worker_pid) do
      case IntentCore.note_owner_gone_await_worker(
             state.runtime_admission_intents,
             target,
             intent_id,
             monitored_owner_pid
           ) do
        {:ok, _updated, intents, effects} ->
          state = put_in(state, [:runtime_admission_intents], intents)

          Enum.each(effects, fn
            {:kill_worker, pid} when is_pid(pid) -> Process.exit(pid, :kill)
            _ -> :ok
          end)

          # Retain waiters and non-idle intent until worker settle or worker DOWN.
          state

        {:ok, :already_awaiting, _intent, intents, effects} ->
          state = put_in(state, [:runtime_admission_intents], intents)

          Enum.each(effects, fn
            {:kill_worker, pid} when is_pid(pid) -> Process.exit(pid, :kill)
            _ -> :ok
          end)

          state

        {:error, :already_settling} ->
          immediate_finalize_runtime_admission(
            state,
            target,
            intent_id,
            {:await_owner_down, monitored_owner_pid}
          )

        {:error, :stale_owner} ->
          # Rebound owner — ignore this DOWN entirely.
          state

        {:error, _} ->
          immediate_finalize_runtime_admission(
            state,
            target,
            intent_id,
            {:commit_owner_gone, monitored_owner_pid, fallback_terminal}
          )
      end
    else
      immediate_finalize_runtime_admission(
        state,
        target,
        intent_id,
        {:commit_owner_gone, monitored_owner_pid, fallback_terminal}
      )
    end
  end

  defp handle_runtime_admission_worker_monitor_down(state, mon, intent_id, target, worker_pid) do
    state = ensure_runtime_admission_shape(state)
    state = update_in(state, [:runtime_admission_worker_monitors], &Map.delete(&1, mon))
    intent = Map.get(state.runtime_admission_intents, target)

    cond do
      not is_map(intent) or intent.intent_id != intent_id ->
        state

      # Exact worker identity required always — including await_worker_down.
      Map.get(intent, :worker_pid) != worker_pid ->
        state

      intent.phase == :settling ->
        # Owner barrier owns finalize; exact worker DOWN is not a finalize path.
        state

      Map.get(intent, :retire_barrier) == :await_worker_down ->
        finalize_from_worker_down_classify(state, target, intent, :worker)

      is_pid(Map.get(intent, :owner_pid)) ->
        finalize_from_worker_down_classify(state, target, intent, :worker)

      true ->
        finalize_from_worker_down_classify(state, target, intent, :worker)
    end
  end

  defp finalize_from_worker_down_classify(state, target, intent, source) do
    # Registry/branch observation is I/O — fixed async observer only.
    enqueue_runtime_admission_witness_observe(state, %{
      reason: :worker_down_classify,
      source: source,
      target: target,
      intent_id: intent.intent_id,
      fingerprint: intent.fingerprint,
      kind: Map.get(intent, :kind, :ordinary_start),
      operation_id: Map.get(intent, :operation_id),
      restore_token: Map.get(intent, :restore_token),
      effect_handoff?: Map.get(intent, :effect_handoff?) == true,
      worker_pid: Map.get(intent, :worker_pid),
      owner_pid: Map.get(intent, :owner_pid),
      retire_barrier: Map.get(intent, :retire_barrier, :none)
    })
  end

  # Task.Supervisor.start_child/5 is a synchronous supervisor call. Every
  # recovery operation therefore enters through this fixed launcher handshake;
  # TaskStore never waits on a potentially suspended supervisor. The admitted
  # worker stays pre-effect until TaskStore has armed its monitor and timeout.
  defp begin_runtime_admission_operation_launch(state, kind, operation_ref, worker_mfa)
       when kind in [:witness_observe, :durable_mark, :durable_settle, :claim_join] and
              is_reference(operation_ref) do
    launch_ref = make_ref()
    store_ref = Map.get(state, :store_ref, @default_name)
    task_supervisor = Map.get(state, :task_supervisor, @default_task_supervisor)

    admit_timeout =
      Map.get(
        state,
        :runtime_admission_admit_timeout_ms,
        @default_runtime_admission_admit_timeout_ms
      )

    begin_wait_ms = admit_timeout + 1_000

    timer =
      Process.send_after(
        self(),
        {:runtime_admission_operation_launch_timeout, launch_ref},
        admit_timeout
      )

    {launcher_pid, launcher_mon} =
      spawn_monitor(OperationLauncher, :launch, [
        store_ref,
        launch_ref,
        operation_ref,
        task_supervisor,
        worker_mfa,
        begin_wait_ms
      ])

    entry = %{
      kind: kind,
      operation_ref: operation_ref,
      launcher_pid: launcher_pid,
      launcher_mon: launcher_mon,
      timer: timer
    }

    state =
      state
      |> put_in([:runtime_admission_operation_launches, launch_ref], entry)
      |> put_in([:runtime_admission_operation_launcher_monitors, launcher_mon], launch_ref)

    {state, launch_ref}
  end

  defp handle_runtime_admission_operation_admitted(
         state,
         launch_ref,
         operation_ref,
         worker_pid
       ) do
    launches = Map.get(state, :runtime_admission_operation_launches, %{})

    case Map.get(launches, launch_ref) do
      %{operation_ref: ^operation_ref, kind: kind} = entry ->
        state = clear_runtime_admission_operation_launcher(state, launch_ref, entry, false)

        case admit_runtime_admission_operation_worker(
               state,
               kind,
               operation_ref,
               launch_ref,
               worker_pid
             ) do
          {:ok, admitted_state} ->
            send(worker_pid, {:runtime_admission_operation_begin, launch_ref})
            admitted_state

          :stale ->
            if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
            state
        end

      _ ->
        # The launch timed out or was superseded. The worker is still blocked,
        # but kill it eagerly rather than waiting for its begin deadline.
        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
        state
    end
  end

  defp handle_runtime_admission_operation_launch_failed(
         state,
         launch_ref,
         operation_ref,
         reason
       ) do
    launches = Map.get(state, :runtime_admission_operation_launches, %{})

    case Map.get(launches, launch_ref) do
      %{operation_ref: ^operation_ref, kind: kind} = entry ->
        state = clear_runtime_admission_operation_launcher(state, launch_ref, entry, true)
        fail_runtime_admission_operation_launch(state, kind, operation_ref, launch_ref, reason)

      _ ->
        state
    end
  end

  defp handle_runtime_admission_operation_launch_timeout(state, launch_ref) do
    launches = Map.get(state, :runtime_admission_operation_launches, %{})

    case Map.get(launches, launch_ref) do
      %{kind: kind, operation_ref: operation_ref} = entry ->
        state = clear_runtime_admission_operation_launcher(state, launch_ref, entry, true)

        fail_runtime_admission_operation_launch(
          state,
          kind,
          operation_ref,
          launch_ref,
          :admission_timeout
        )

      _ ->
        state
    end
  end

  defp handle_runtime_admission_operation_launcher_down(state, mon, launch_ref) do
    launch_mons = Map.get(state, :runtime_admission_operation_launcher_monitors, %{})
    launches = Map.get(state, :runtime_admission_operation_launches, %{})

    case {Map.get(launch_mons, mon), Map.get(launches, launch_ref)} do
      {^launch_ref, %{kind: kind, operation_ref: operation_ref} = entry} ->
        state = clear_runtime_admission_operation_launcher(state, launch_ref, entry, false)

        fail_runtime_admission_operation_launch(
          state,
          kind,
          operation_ref,
          launch_ref,
          :launcher_down
        )

      _ ->
        state
    end
  end

  defp clear_runtime_admission_operation_launcher(state, launch_ref, entry, terminate?) do
    case Map.get(entry, :timer) do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    mon = Map.get(entry, :launcher_mon)
    if is_reference(mon), do: Process.demonitor(mon, [:flush])

    launcher_pid = Map.get(entry, :launcher_pid)

    if terminate? and is_pid(launcher_pid) and Process.alive?(launcher_pid) do
      Process.exit(launcher_pid, :kill)
    end

    state
    |> update_in([:runtime_admission_operation_launches], &Map.delete(&1, launch_ref))
    |> update_in([:runtime_admission_operation_launcher_monitors], &Map.delete(&1, mon))
  end

  defp admit_runtime_admission_operation_worker(
         state,
         :witness_observe,
         observe_ref,
         launch_ref,
         worker_pid
       ) do
    case pending_runtime_admission_operation(
           state,
           :runtime_admission_pending_observe,
           observe_ref,
           launch_ref
         ) do
      {:ok, meta} ->
        {:ok,
         track_witness_observer(
           state,
           observe_ref,
           meta.request,
           worker_pid,
           launch_ref
         )}

      :stale ->
        :stale
    end
  end

  defp admit_runtime_admission_operation_worker(
         state,
         :durable_mark,
         mark_ref,
         launch_ref,
         worker_pid
       ) do
    case pending_runtime_admission_operation(
           state,
           :runtime_admission_pending_durable_mark,
           mark_ref,
           launch_ref
         ) do
      {:ok, meta} ->
        {:ok, track_durable_mark_worker(state, mark_ref, meta, worker_pid, launch_ref)}

      :stale ->
        :stale
    end
  end

  defp admit_runtime_admission_operation_worker(
         state,
         :durable_settle,
         settle_ref,
         launch_ref,
         worker_pid
       ) do
    case pending_runtime_admission_operation(
           state,
           :runtime_admission_pending_durable_settle,
           settle_ref,
           launch_ref
         ) do
      {:ok, meta} ->
        {:ok,
         track_durable_settle_observer(
           state,
           settle_ref,
           meta.request,
           worker_pid,
           meta.launch_attempt,
           launch_ref
         )}

      :stale ->
        :stale
    end
  end

  defp admit_runtime_admission_operation_worker(
         state,
         :claim_join,
         join_ref,
         launch_ref,
         worker_pid
       ) do
    case pending_runtime_admission_operation(
           state,
           :runtime_admission_pending_claim_join,
           join_ref,
           launch_ref
         ) do
      {:ok, meta} ->
        {:ok,
         track_claim_join_observer(
           state,
           join_ref,
           meta.request,
           worker_pid,
           meta.attempt,
           launch_ref
         )}

      :stale ->
        :stale
    end
  end

  defp pending_runtime_admission_operation(state, key, operation_ref, launch_ref) do
    case Map.get(Map.get(state, key, %{}), operation_ref) do
      %{status: :admitting, launch_ref: ^launch_ref} = meta -> {:ok, meta}
      _ -> :stale
    end
  end

  defp fail_runtime_admission_operation_launch(
         state,
         :witness_observe,
         observe_ref,
         launch_ref,
         _reason
       ) do
    case take_admitting_runtime_operation(
           state,
           :runtime_admission_pending_observe,
           observe_ref,
           launch_ref
         ) do
      {:ok, meta, state} ->
        apply_witness_observation(
          state,
          meta.request,
          observe_failed_observation(:launch_failed)
        )

      :stale ->
        state
    end
  end

  defp fail_runtime_admission_operation_launch(
         state,
         :durable_mark,
         mark_ref,
         launch_ref,
         reason
       ) do
    reason = operation_launch_reason(:durable_mark, reason)

    case take_admitting_runtime_operation(
           state,
           :runtime_admission_pending_durable_mark,
           mark_ref,
           launch_ref
         ) do
      {:ok, meta, state} -> fail_durable_mark_launch(state, meta, reason)
      :stale -> state
    end
  end

  defp fail_runtime_admission_operation_launch(
         state,
         :durable_settle,
         settle_ref,
         launch_ref,
         reason
       ) do
    reason = operation_launch_reason(:durable_settle, reason)

    case take_admitting_runtime_operation(
           state,
           :runtime_admission_pending_durable_settle,
           settle_ref,
           launch_ref
         ) do
      {:ok, meta, state} -> fail_durable_settle_launch(state, meta, reason)
      :stale -> state
    end
  end

  defp fail_runtime_admission_operation_launch(
         state,
         :claim_join,
         join_ref,
         launch_ref,
         reason
       ) do
    reason = operation_launch_reason(:claim_join, reason)

    case take_admitting_runtime_operation(
           state,
           :runtime_admission_pending_claim_join,
           join_ref,
           launch_ref
         ) do
      {:ok, meta, state} -> retry_or_exhaust_claim_join(state, meta, reason)
      :stale -> state
    end
  end

  defp take_admitting_runtime_operation(state, key, operation_ref, launch_ref) do
    pending = Map.get(state, key, %{})

    case Map.get(pending, operation_ref) do
      %{status: :admitting, launch_ref: ^launch_ref} = meta ->
        {:ok, meta, put_in(state, [key], Map.delete(pending, operation_ref))}

      _ ->
        :stale
    end
  end

  defp operation_launch_reason(:durable_mark, :supervisor_unavailable),
    do: :durable_mark_supervisor_unavailable

  defp operation_launch_reason(:durable_settle, :supervisor_unavailable),
    do: :durable_settle_supervisor_unavailable

  defp operation_launch_reason(:claim_join, :supervisor_unavailable),
    do: :claim_join_supervisor_unavailable

  defp operation_launch_reason(_kind, reason), do: reason

  # ---------------------------------------------------------------------------
  # Fixed async witness observer (I/O outside TaskStore callbacks)
  #
  # Fail-closed + bounded:
  # - Launch/rescue/catch/malformed never synthesize :not_running (authority-bearing
  #   absence). They emit :observe_failed — never proves absence or applied.
  # - Each launched observer is monitored with a bounded timer; DOWN/timeout
  #   converge so pending observations cannot hang forever.
  # - Delayed facts revalidate exact intent identity before apply; stale → inert.
  # - Branch observation uses BranchSupervisor.observe_admission/1 only (atomic
  #   Registry PID + closed witness from one lookup).
  # ---------------------------------------------------------------------------

  defp enqueue_runtime_admission_witness_observe(state, request) when is_map(request) do
    state = ensure_runtime_admission_shape(state)
    observe_ref = make_ref()
    store_ref = Map.get(state, :store_ref, @default_name)
    closed_request = close_witness_observe_request(request)

    worker_mfa =
      {__MODULE__, :run_runtime_admission_witness_observer,
       [store_ref, observe_ref, closed_request]}

    {state, launch_ref} =
      begin_runtime_admission_operation_launch(
        state,
        :witness_observe,
        observe_ref,
        worker_mfa
      )

    put_in(state, [:runtime_admission_pending_observe, observe_ref], %{
      status: :admitting,
      launch_ref: launch_ref,
      request: closed_request
    })
  end

  defp track_witness_observer(state, observe_ref, closed_request, observer_pid, launch_ref)
       when is_reference(observe_ref) and is_pid(observer_pid) do
    mon = Process.monitor(observer_pid)

    timeout_ms =
      Map.get(
        state,
        :runtime_admission_observe_timeout_ms,
        @default_runtime_admission_observe_timeout_ms
      )

    timer =
      Process.send_after(
        self(),
        {:runtime_admission_witness_observe_timeout, observe_ref},
        timeout_ms
      )

    meta = %{
      status: :running,
      launch_ref: launch_ref,
      request: closed_request,
      mon: mon,
      timer: timer,
      observer_pid: observer_pid,
      worker_pid: observer_pid
    }

    state
    |> put_in([:runtime_admission_pending_observe, observe_ref], meta)
    |> put_in([:runtime_admission_observe_monitors, mon], observe_ref)
  end

  defp close_witness_observe_request(request) do
    %{
      reason: Map.fetch!(request, :reason),
      source: Map.get(request, :source, :owner),
      target: Map.fetch!(request, :target),
      intent_id: Map.fetch!(request, :intent_id),
      fingerprint: Map.get(request, :fingerprint),
      kind: Map.get(request, :kind, :ordinary_start),
      operation_id: Map.get(request, :operation_id),
      restore_token: Map.get(request, :restore_token),
      effect_handoff?: Map.get(request, :effect_handoff?) == true,
      monitored_owner_pid: Map.get(request, :monitored_owner_pid),
      worker_pid: Map.get(request, :worker_pid),
      owner_pid: Map.get(request, :owner_pid),
      retire_barrier: Map.get(request, :retire_barrier, :none)
    }
  end

  defp observe_failed_observation(reason) when is_atom(reason) do
    %{fact: :observe_failed, reason: reason, branch_pid: nil}
  end

  @doc false
  def run_runtime_admission_witness_observer(store_ref, observe_ref, request)
      when is_reference(observe_ref) and is_map(request) do
    # Deterministic MIX_ENV=test hang seam for timeout race coverage.
    maybe_runtime_admission_observe_test_hang(request)

    observation = Map.put(observe_admission_witness_fact(request), :worker_pid, self())

    OperationLauncher.notify(
      store_ref,
      {:runtime_admission_witness_observed, observe_ref, observation}
    )

    :ok
  rescue
    _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_witness_observed, observe_ref,
         observe_failed_observation(:observer_exception) |> Map.put(:worker_pid, self())}
      )

      :ok
  catch
    :exit, _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_witness_observed, observe_ref,
         observe_failed_observation(:observer_exception) |> Map.put(:worker_pid, self())}
      )

      :ok
  end

  defp maybe_runtime_admission_observe_test_hang(request) do
    case Application.get_env(:arbor_agent, :runtime_admission_observe_test_hang) do
      %{timeout_ms: ms, target: target}
      when is_integer(ms) and ms > 0 and is_binary(target) ->
        if Map.get(request, :target) == target, do: Process.sleep(ms)

      %{timeout_ms: ms} when is_integer(ms) and ms > 0 ->
        Process.sleep(ms)

      _ ->
        :ok
    end
  end

  # Fixed observer only — never called from GenServer callbacks.
  # Single atomic BranchSupervisor.observe_admission/1 — no split whereis/witness.
  defp observe_admission_witness_fact(
         %{
           kind: :guarded_restore,
           target: target,
           intent_id: intent_id,
           fingerprint: fingerprint,
           operation_id: operation_id,
           restore_token: token
         } = _request
       )
       when is_binary(target) and is_binary(intent_id) and is_binary(fingerprint) and
              is_binary(operation_id) and is_binary(token) do
    case Arbor.Agent.BranchSupervisor.observe_admission(target) do
      {:running, pid,
       {:ok,
        %{
          kind: :guarded_restore,
          intent_id: ^intent_id,
          fingerprint: ^fingerprint,
          operation_id: ^operation_id,
          token: ^token
        }}}
      when is_pid(pid) ->
        %{fact: {:exact, intent_id}, branch_pid: pid}

      {:running, _pid, {:ok, %{intent_id: other}}} when is_binary(other) ->
        %{fact: {:other, other}, branch_pid: nil}

      {:running, _pid, {:ok, _}} ->
        %{fact: :bare, branch_pid: nil}

      {:running, _pid, :none} ->
        %{fact: :bare, branch_pid: nil}

      :not_running ->
        %{fact: :not_running, branch_pid: nil}
    end
  end

  defp observe_admission_witness_fact(%{
         target: target,
         intent_id: intent_id,
         fingerprint: fingerprint,
         kind: :ordinary_start
       })
       when is_binary(target) and is_binary(intent_id) and is_binary(fingerprint) do
    case Arbor.Agent.BranchSupervisor.observe_admission(target) do
      {:running, pid,
       {:ok, %{kind: :ordinary_start, intent_id: ^intent_id, fingerprint: ^fingerprint}}}
      when is_pid(pid) ->
        %{fact: {:exact, intent_id}, branch_pid: pid}

      {:running, _pid, {:ok, %{intent_id: other}}} when is_binary(other) ->
        %{fact: {:other, other}, branch_pid: nil}

      {:running, _pid, {:ok, _}} ->
        %{fact: :bare, branch_pid: nil}

      {:running, _pid, :none} ->
        %{fact: :bare, branch_pid: nil}

      :not_running ->
        %{fact: :not_running, branch_pid: nil}
    end
  end

  defp observe_admission_witness_fact(_),
    do: observe_failed_observation(:malformed_request)

  defp handle_runtime_admission_witness_observed(state, observe_ref, observation) do
    state = ensure_runtime_admission_shape(state)
    pending = Map.get(state, :runtime_admission_pending_observe, %{})

    case Map.get(pending, observe_ref) do
      nil ->
        # Stale/unknown observe ref (already timed out or never tracked) — inert.
        state

      meta when is_map(meta) ->
        if witness_observation_authentic?(meta, observation) do
          state =
            state
            |> put_in(
              [:runtime_admission_pending_observe],
              Map.delete(pending, observe_ref)
            )
            |> clear_witness_observer_tracking(meta)

          request = Map.get(meta, :request, meta)
          intent = Map.get(state.runtime_admission_intents, Map.get(request, :target))

          if IntentCore.observe_request_current?(intent, request) do
            apply_witness_observation(state, request, observation)
          else
            # Stale after state change — inert (caller already enqueued a fresh observe
            # if the new identity still needs one).
            state
          end
        else
          # Wrong worker / forged observation must not clear the live operation.
          state
        end

      _ ->
        state
    end
  end

  defp witness_observation_authentic?(meta, observation)
       when is_map(meta) and is_map(observation) do
    is_pid(Map.get(meta, :worker_pid)) and
      Map.get(observation, :worker_pid) == Map.get(meta, :worker_pid) and
      (Map.get(observation, :fact) == :not_running or
         Map.get(observation, :fact) == :bare or
         Map.get(observation, :fact) == :observe_failed or
         match?({:exact, id} when is_binary(id), Map.get(observation, :fact)) or
         match?({:other, id} when is_binary(id), Map.get(observation, :fact)))
  end

  defp witness_observation_authentic?(_, _), do: false

  defp handle_runtime_admission_witness_observe_timeout(state, observe_ref)
       when is_reference(observe_ref) do
    state = ensure_runtime_admission_shape(state)
    pending = Map.get(state, :runtime_admission_pending_observe, %{})

    case Map.pop(pending, observe_ref) do
      {nil, _} ->
        state

      {meta, rest} when is_map(meta) ->
        state =
          state
          |> put_in([:runtime_admission_pending_observe], rest)
          |> clear_witness_observer_tracking(meta)

        # Best-effort kill hung observer so it cannot deliver a late fact later.
        case Map.get(meta, :observer_pid) do
          pid when is_pid(pid) ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)

          _ ->
            :ok
        end

        request = Map.get(meta, :request, meta)
        intent = Map.get(state.runtime_admission_intents, Map.get(request, :target))

        if IntentCore.observe_request_current?(intent, request) do
          apply_witness_observation(
            state,
            request,
            observe_failed_observation(:observer_timeout)
          )
        else
          state
        end

      _ ->
        state
    end
  end

  defp handle_runtime_admission_observe_monitor_down(state, mon, observe_ref)
       when is_reference(mon) and is_reference(observe_ref) do
    state = ensure_runtime_admission_shape(state)
    observe_mons = Map.get(state, :runtime_admission_observe_monitors, %{})
    state = put_in(state, [:runtime_admission_observe_monitors], Map.delete(observe_mons, mon))

    pending = Map.get(state, :runtime_admission_pending_observe, %{})

    case Map.get(pending, observe_ref) do
      %{mon: ^mon} = meta ->
        # Observer exited before/without a delivered observation. Prefer the
        # observation message if it races ahead; on pure crash with no message
        # the bounded timer converges. Clear mon only — keep timer/pending.
        updated = %{meta | mon: nil, observer_pid: nil}
        put_in(state, [:runtime_admission_pending_observe, observe_ref], updated)

      _ ->
        # Observation or timeout already converged this ref.
        state
    end
  end

  defp clear_witness_observer_tracking(state, meta) when is_map(meta) do
    state =
      case Map.get(meta, :timer) do
        timer when is_reference(timer) ->
          _ = Process.cancel_timer(timer)
          state

        _ ->
          state
      end

    state =
      case Map.get(meta, :mon) do
        mon when is_reference(mon) ->
          Process.demonitor(mon, [:flush])
          observe_mons = Map.get(state, :runtime_admission_observe_monitors, %{})
          put_in(state, [:runtime_admission_observe_monitors], Map.delete(observe_mons, mon))

        _ ->
          state
      end

    state
  end

  defp apply_witness_observation(state, %{reason: :unexpected_owner_down} = request, observation) do
    target = request.target
    intent = Map.get(state.runtime_admission_intents, target)
    fact = Map.get(observation, :fact, :observe_failed)
    branch_pid = Map.get(observation, :branch_pid)
    monitored_owner_pid = request.monitored_owner_pid

    cond do
      not IntentCore.observe_request_current?(intent, request) ->
        state

      true ->
        case IntentCore.classify_unknown_start(request.intent_id, fact) do
          :applied when is_pid(branch_pid) ->
            immediate_finalize_runtime_admission(
              state,
              target,
              request.intent_id,
              {:commit_owner_gone, monitored_owner_pid, {:applied, branch_pid}}
            )

          :applied ->
            maybe_await_worker_or_finalize(
              state,
              target,
              intent,
              monitored_owner_pid,
              {:error, :branch_missing_after_witness}
            )

          :conflict ->
            maybe_await_worker_or_finalize(
              state,
              target,
              intent,
              monitored_owner_pid,
              {:conflict, :witness_mismatch}
            )

          :observation_failed ->
            # Distinct failure class — never proves absence or applied.
            apply_observation_failed_owner_down(state, request, intent, monitored_owner_pid)

          :not_applied ->
            cond do
              request.kind == :guarded_restore and request.effect_handoff? == true ->
                # Post-handoff: park unknown; never invent not_applied.
                park_guarded_outcome_unknown(state, target, intent, monitored_owner_pid)

              request.kind == :guarded_restore ->
                # Crash after durable bind but before handoff ack: effect_handoff?
                # false is NOT proof of pre-effect. Join durable claim outside
                # the callback; bound → park/hold; minted+no witness → pre-effect.
                enqueue_durable_claim_join(state, request, intent, monitored_owner_pid)

              true ->
                maybe_await_worker_or_finalize(
                  state,
                  target,
                  intent,
                  monitored_owner_pid,
                  {:error, :owner_down}
                )
            end
        end
    end
  end

  defp apply_witness_observation(state, %{reason: :worker_down_classify} = request, observation) do
    target = request.target
    intent = Map.get(state.runtime_admission_intents, target)
    fact = Map.get(observation, :fact, :observe_failed)
    branch_pid = Map.get(observation, :branch_pid)
    source = Map.get(request, :source, :worker)

    cond do
      not IntentCore.observe_request_current?(intent, request) ->
        state

      request.kind == :guarded_restore and request.effect_handoff? != true and
        Map.get(intent, :phase) == :outcome_unknown and
          is_nil(Map.get(intent, :owner_pid)) ->
        # Owner-down convergence already parked this pre-handoff intent and
        # launched a durable claim join. A concurrent worker DOWN observation
        # cannot prove not-applied and must not settle ahead of that join.
        updated = %{intent | worker_pid: nil, retire_barrier: :none}
        put_in(state, [:runtime_admission_intents, target], updated)

      # Observation failure and post-handoff non-exact never prove applied/absence.
      request.kind == :guarded_restore and request.effect_handoff? == true and
          fact != {:exact, request.intent_id} ->
        updated = %{
          intent
          | phase: :outcome_unknown,
            worker_pid: nil,
            retire_barrier: :none,
            effect_handoff?: true
        }

        state = put_in(state, [:runtime_admission_intents, target], updated)
        launch_durable_mark_outcome_unknown(state, intent)

      true ->
        {:settle, terminal} =
          IntentCore.classify_live_down(request.intent_id, fact, source, branch_pid)

        if is_pid(Map.get(intent, :owner_pid)) and
             Map.get(intent, :retire_barrier) != :await_worker_down do
          case request_runtime_admission_terminal(
                 state,
                 target,
                 request.intent_id,
                 terminal,
                 :worker_down
               ) do
            {:ok, s} -> s
            {:error, _, s} -> s
          end
        else
          immediate_finalize_runtime_admission(
            state,
            target,
            request.intent_id,
            {:commit, terminal}
          )
        end
    end
  end

  defp apply_witness_observation(state, _request, _observation), do: state

  defp apply_observation_failed_owner_down(state, request, intent, monitored_owner_pid) do
    target = request.target

    cond do
      request.kind == :guarded_restore ->
        # Without a real observation we cannot prove pre-effect minted absence
        # or applied. Park unknown (hold exclusion/fence); claim join is not
        # triggered from a synthetic absence claim.
        park_guarded_outcome_unknown(state, target, intent, monitored_owner_pid)

      true ->
        maybe_await_worker_or_finalize(
          state,
          target,
          intent,
          monitored_owner_pid,
          {:conflict, :observation_failed}
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Fixed durable mark shell (I/O outside TaskStore callbacks)
  #
  # Launch retries are bounded and attempt-threaded. start_child failure must
  # NEVER reschedule attempt=1 (that loops forever when TaskSupervisor is down).
  # Stale retry/completion messages authenticate against exact target/token/
  # intent_id and current pending phase. Exhaustion leaves the intent blocking.
  # Terminal shell errors are not discarded as if durable convergence occurred.
  # ---------------------------------------------------------------------------

  defp launch_durable_mark_outcome_unknown(state, intent) when is_map(intent) do
    launch_durable_mark_outcome_unknown(state, intent, 0)
  end

  defp launch_durable_mark_outcome_unknown(state, intent, attempt)
       when is_map(intent) and is_integer(attempt) and attempt >= 0 do
    state = ensure_runtime_admission_shape(state)

    token = Map.get(intent, :restore_token)
    target = intent.target_agent_id
    intent_id = intent.intent_id

    progress =
      Map.get(Map.get(state, :runtime_admission_durable_mark_progress, %{}), target)

    cond do
      not (is_binary(token) and is_binary(target) and is_binary(intent_id) and
               Map.get(intent, :kind) == :guarded_restore) ->
        state

      durable_mark_pending_for?(state, target, intent_id) ->
        state

      # Same-identity terminal/exhausted cycles are inert. A distinct intent on
      # the same target owns a fresh progress identity.
      is_map(progress) and progress.intent_id == intent_id and
          progress.status in [:done, :exhausted] ->
        state

      attempt >= @max_runtime_admission_durable_shell_launch_attempts ->
        # Exhausted: keep claim/intent conservatively blocking (outcome_unknown).
        put_durable_mark_progress(
          state,
          target,
          intent_id,
          token,
          :exhausted,
          attempt,
          :launch_exhausted
        )

      true ->
        mark_ref = make_ref()
        store_ref = Map.get(state, :store_ref, @default_name)

        meta = %{
          status: :admitting,
          target: target,
          token: token,
          intent_id: intent_id,
          attempt: attempt,
          expected_phase: :outcome_unknown
        }

        worker_mfa =
          {__MODULE__, :run_runtime_admission_durable_mark_unknown,
           [store_ref, mark_ref, target, token, intent_id]}

        {state, launch_ref} =
          begin_runtime_admission_operation_launch(
            state,
            :durable_mark,
            mark_ref,
            worker_mfa
          )

        state
        |> put_in(
          [:runtime_admission_pending_durable_mark, mark_ref],
          Map.put(meta, :launch_ref, launch_ref)
        )
        |> put_durable_mark_progress(target, intent_id, token, :pending, attempt, nil)
    end
  end

  defp durable_shell_launch_backoff_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    # Linear backoff: 50, 100, 150, 200 ms — bounded and deterministic.
    @runtime_admission_durable_shell_launch_base_backoff_ms * (attempt + 1)
  end

  defp current_durable_mark_intent(state, target, token, intent_id) do
    intent = Map.get(Map.get(state, :runtime_admission_intents, %{}), target)

    if durable_mark_intent_matches?(intent, target, token, intent_id) do
      {:ok, intent}
    else
      :stale
    end
  end

  defp durable_mark_pending_for?(state, target, intent_id) do
    state
    |> Map.get(:runtime_admission_pending_durable_mark, %{})
    |> Map.values()
    |> Enum.any?(fn meta ->
      is_map(meta) and Map.get(meta, :target) == target and
        Map.get(meta, :intent_id) == intent_id
    end)
  end

  defp durable_mark_retry_current?(state, target, token, intent_id, attempt)
       when is_binary(target) and is_binary(token) and is_binary(intent_id) and
              is_integer(attempt) and attempt > 0 do
    not durable_mark_pending_for?(state, target, intent_id) and
      match?({:ok, _}, current_durable_mark_intent(state, target, token, intent_id)) and
      case Map.get(Map.get(state, :runtime_admission_durable_mark_progress, %{}), target) do
        %{
          intent_id: ^intent_id,
          token: ^token,
          status: status,
          attempt: prior_attempt
        }
        when status in [:launch_retry, :shell_error_retry] and attempt == prior_attempt + 1 ->
          true

        _ ->
          false
      end
  end

  defp durable_mark_retry_current?(_, _, _, _, _), do: false

  defp durable_mark_intent_matches?(intent, target, token, intent_id) do
    # Still non-terminal / indeterminate — needs durable mark convergence.
    is_map(intent) and
      Map.get(intent, :kind) == :guarded_restore and
      intent.target_agent_id == target and
      intent.intent_id == intent_id and
      Map.get(intent, :restore_token) == token and
      Map.get(intent, :phase) in [:outcome_unknown, :worker_running, :owner_live, :settling]
  end

  defp put_durable_mark_progress(state, target, intent_id, token, status, attempt, last_error)
       when is_binary(target) and is_binary(intent_id) do
    progress = Map.get(state, :runtime_admission_durable_mark_progress, %{})

    entry = %{
      intent_id: intent_id,
      token: token,
      status: status,
      attempt: attempt,
      last_error: last_error
    }

    put_in(state, [:runtime_admission_durable_mark_progress], Map.put(progress, target, entry))
  end

  defp delete_durable_mark_progress(state, target, intent_id) do
    progress = Map.get(state, :runtime_admission_durable_mark_progress, %{})

    case Map.get(progress, target) do
      %{intent_id: ^intent_id} ->
        put_in(state, [:runtime_admission_durable_mark_progress], Map.delete(progress, target))

      _ ->
        state
    end
  end

  defp track_durable_mark_worker(state, mark_ref, meta, worker_pid, launch_ref)
       when is_reference(mark_ref) and is_map(meta) and is_pid(worker_pid) do
    mon = Process.monitor(worker_pid)

    timeout_ms =
      Map.get(
        state,
        :runtime_admission_durable_op_timeout_ms,
        @default_runtime_admission_durable_op_timeout_ms
      )

    timer =
      Process.send_after(self(), {:runtime_admission_durable_mark_timeout, mark_ref}, timeout_ms)

    updated =
      Map.merge(meta, %{
        status: :running,
        launch_ref: launch_ref,
        worker_pid: worker_pid,
        mon: mon,
        timer: timer
      })

    state
    |> put_in([:runtime_admission_pending_durable_mark, mark_ref], updated)
    |> put_in([:runtime_admission_durable_mark_monitors, mon], mark_ref)
  end

  defp fail_durable_mark_launch(state, meta, reason) when is_map(meta) do
    attempt = Map.get(meta, :attempt, 0)
    next = attempt + 1

    state =
      put_durable_mark_progress(
        state,
        meta.target,
        meta.intent_id,
        meta.token,
        if(next >= @max_runtime_admission_durable_shell_launch_attempts,
          do: :exhausted,
          else: :launch_retry
        ),
        attempt,
        reason
      )

    if next < @max_runtime_admission_durable_shell_launch_attempts do
      Process.send_after(
        self(),
        {:runtime_admission_durable_mark_retry, meta.target, meta.token, meta.intent_id, next},
        durable_shell_launch_backoff_ms(attempt)
      )
    end

    state
  end

  @doc false
  def run_runtime_admission_durable_mark_unknown(store_ref, mark_ref, target, token)
      when is_reference(mark_ref) and is_binary(target) and is_binary(token) do
    maybe_runtime_admission_durable_mark_test_hang(target)
    result = durable_mark_outcome_unknown_with_retry(target, token, 0)

    OperationLauncher.notify(
      store_ref,
      {:runtime_admission_durable_mark_done, mark_ref,
       durable_mark_envelope(target, token, result)}
    )

    :ok
  rescue
    _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_durable_mark_done, mark_ref,
         durable_mark_envelope(target, token, {:error, :mark_exception})}
      )

      :ok
  catch
    :exit, _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_durable_mark_done, mark_ref,
         durable_mark_envelope(target, token, {:error, :mark_exit})}
      )

      :ok
  end

  # 5-arity MFA used by TaskStore launcher (intent_id carried only in pending meta).
  @doc false
  def run_runtime_admission_durable_mark_unknown(store_ref, mark_ref, target, token, _intent_id)
      when is_reference(mark_ref) and is_binary(target) and is_binary(token) do
    run_runtime_admission_durable_mark_unknown(store_ref, mark_ref, target, token)
  end

  defp durable_mark_envelope(target, token, result) do
    %{worker_pid: self(), target: target, token: token, result: result}
  end

  defp maybe_runtime_admission_durable_mark_test_hang(target) when is_binary(target) do
    if Mix.env() == :test do
      case Application.get_env(:arbor_agent, :runtime_admission_test_durable_mark_hang) do
        %{timeout_ms: ms, target: ^target} when is_integer(ms) and ms > 0 ->
          Process.sleep(ms)

        %{timeout_ms: ms} when is_integer(ms) and ms > 0 ->
          Process.sleep(ms)

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp durable_mark_outcome_unknown_with_retry(target, token, attempt)
       when is_integer(attempt) and attempt < 4 do
    # MIX_ENV=test seam: force terminal shell failure (not launch failure).
    if Mix.env() == :test and
         Application.get_env(:arbor_agent, :runtime_admission_test_durable_mark_force_error) ==
           true do
      {:error, :mark_forced_failure}
    else
      case Arbor.Agent.TemplateAuthorityReconciliationStore.mark_runtime_restore_outcome_unknown(
             target,
             token
           ) do
        {:ok, _} = ok ->
          ok

        {:error, reason}
        when reason in [:cas_conflict, :outcome_unknown, :backend_unavailable] and attempt < 3 ->
          Process.sleep(25 * (attempt + 1))
          # Reobserve: if already outcome_unknown, treat as success.
          case Arbor.Agent.TemplateAuthorityReconciliationStore.fetch(target) do
            {:ok, op} ->
              claim = op["runtime_restore_admission"]

              if is_map(claim) and claim["token"] == token and
                   claim["claim_phase"] == "outcome_unknown" do
                {:ok, op}
              else
                durable_mark_outcome_unknown_with_retry(target, token, attempt + 1)
              end

            _ ->
              durable_mark_outcome_unknown_with_retry(target, token, attempt + 1)
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp durable_mark_outcome_unknown_with_retry(_target, _token, _attempt),
    do: {:error, :mark_retry_exhausted}

  defp handle_runtime_admission_durable_mark_done(state, mark_ref, envelope) do
    state = ensure_runtime_admission_shape(state)
    pending = Map.get(state, :runtime_admission_pending_durable_mark, %{})

    case Map.get(pending, mark_ref) do
      nil ->
        # Stale/unknown mark_ref — inert.
        state

      meta when is_map(meta) ->
        target = meta.target
        token = meta.token
        intent_id = meta.intent_id
        attempt = Map.get(meta, :attempt, 0)

        if durable_mark_result_authentic?(meta, envelope) and
             durable_mark_intent_matches?(
               Map.get(Map.get(state, :runtime_admission_intents, %{}), target),
               target,
               token,
               intent_id
             ) do
          state =
            state
            |> put_in(
              [:runtime_admission_pending_durable_mark],
              Map.delete(pending, mark_ref)
            )
            |> clear_durable_mark_worker_tracking(meta)

          result = Map.get(envelope, :result)

          case result do
            {:ok, _} ->
              # Durable converged to outcome_unknown (or already was).
              delete_durable_mark_progress(state, target, intent_id)

            {:error, reason} ->
              # Terminal shell failure is NOT silent convergence. Retry launch if
              # budget remains; otherwise exhaust while keeping intent blocking.
              next = attempt + 1

              state =
                put_durable_mark_progress(
                  state,
                  target,
                  intent_id,
                  token,
                  if(next >= @max_runtime_admission_durable_shell_launch_attempts,
                    do: :exhausted,
                    else: :shell_error_retry
                  ),
                  attempt,
                  reason
                )

              if next < @max_runtime_admission_durable_shell_launch_attempts do
                Process.send_after(
                  self(),
                  {:runtime_admission_durable_mark_retry, target, token, intent_id, next},
                  durable_shell_launch_backoff_ms(attempt)
                )
              end

              # Intent remains non-idle outcome_unknown — never invent applied/not_applied.
              state

            _ ->
              put_durable_mark_progress(
                state,
                target,
                intent_id,
                token,
                :exhausted,
                attempt,
                :invalid_mark_result
              )
          end
        else
          # Wrong worker/identity or stale completion cannot clear pending work.
          state
        end

      _ ->
        state
    end
  end

  defp durable_mark_result_authentic?(meta, envelope)
       when is_map(meta) and is_map(envelope) do
    is_pid(Map.get(meta, :worker_pid)) and
      Map.get(envelope, :worker_pid) == Map.get(meta, :worker_pid) and
      Map.get(envelope, :target) == Map.get(meta, :target) and
      Map.get(envelope, :token) == Map.get(meta, :token) and
      Map.has_key?(envelope, :result)
  end

  defp durable_mark_result_authentic?(_, _), do: false

  defp handle_runtime_admission_durable_mark_timeout(state, mark_ref)
       when is_reference(mark_ref) do
    pending = Map.get(state, :runtime_admission_pending_durable_mark, %{})

    case Map.pop(pending, mark_ref) do
      {nil, _} ->
        state

      {meta, rest} when is_map(meta) ->
        state =
          state
          |> put_in([:runtime_admission_pending_durable_mark], rest)
          |> clear_durable_mark_worker_tracking(meta)

        case Map.get(meta, :worker_pid) do
          pid when is_pid(pid) ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)

          _ ->
            :ok
        end

        fail_durable_mark_launch(state, meta, :worker_timeout)

      _ ->
        state
    end
  end

  defp handle_runtime_admission_durable_mark_monitor_down(state, mon, mark_ref)
       when is_reference(mon) and is_reference(mark_ref) do
    mark_mons = Map.get(state, :runtime_admission_durable_mark_monitors, %{})
    state = put_in(state, [:runtime_admission_durable_mark_monitors], Map.delete(mark_mons, mon))
    pending = Map.get(state, :runtime_admission_pending_durable_mark, %{})

    case Map.get(pending, mark_ref) do
      %{mon: ^mon} = meta ->
        # Prefer a result already sent by the exact worker; timeout converges a
        # pure crash if no result follows.
        updated = %{meta | mon: nil, worker_pid: nil}
        put_in(state, [:runtime_admission_pending_durable_mark, mark_ref], updated)

      _ ->
        state
    end
  end

  defp clear_durable_mark_worker_tracking(state, meta) when is_map(meta) do
    case Map.get(meta, :timer) do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    case Map.get(meta, :mon) do
      mon when is_reference(mon) ->
        Process.demonitor(mon, [:flush])
        mark_mons = Map.get(state, :runtime_admission_durable_mark_monitors, %{})
        put_in(state, [:runtime_admission_durable_mark_monitors], Map.delete(mark_mons, mon))

      _ ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # W9: Fixed durable settle shell after source-auth TaskStore terminal accept
  #
  # Closes crash-after-accept / before-worker-durable-settle:
  # - applied: exact guarded branch observation required (op/token/intent/fp);
  #   mismatch/absence after handoff → outcome_unknown, never invent applied
  # - failed/conflict: source-auth worker terminal is the surviving evidence
  #   (TaskStore only accepted the exact bound worker); settle that terminal
  # - retry + exact successor reobserve (same outcome+reason keeps first at)
  # ---------------------------------------------------------------------------

  defp maybe_launch_guarded_durable_settle_after_accept(state, intent, intent_id, outcome) do
    cond do
      not is_map(intent) ->
        state

      Map.get(intent, :kind) != :guarded_restore ->
        state

      intent.intent_id != intent_id ->
        state

      true ->
        case durable_settle_request_from_terminal(intent, outcome) do
          {:ok, request} ->
            launch_guarded_durable_settle_shell(state, request)

          :skip ->
            state
        end
    end
  end

  defp durable_settle_request_from_terminal(intent, outcome) do
    token = Map.get(intent, :restore_token)
    target = Map.get(intent, :target_agent_id)
    fingerprint = Map.get(intent, :fingerprint)
    operation_id = Map.get(intent, :operation_id)
    intent_id = Map.get(intent, :intent_id)

    if is_binary(token) and is_binary(target) and is_binary(fingerprint) and
         is_binary(operation_id) and is_binary(intent_id) do
      case outcome do
        {:applied, pid} when is_pid(pid) ->
          {:ok,
           %{
             mode: :observe_then_applied,
             target: target,
             token: token,
             intent_id: intent_id,
             fingerprint: fingerprint,
             operation_id: operation_id,
             reason_code: "branch_restored"
           }}

        {:error, reason} ->
          {outcome_s, reason_code} = classify_guarded_worker_terminal_for_durable(reason)

          {:ok,
           %{
             mode: :source_auth_terminal,
             target: target,
             token: token,
             intent_id: intent_id,
             fingerprint: fingerprint,
             operation_id: operation_id,
             outcome: outcome_s,
             reason_code: reason_code
           }}

        {:conflict, reason} ->
          reason_code =
            case reason do
              r when is_atom(r) ->
                s = Atom.to_string(r)

                if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, s) and byte_size(s) <= 64,
                  do: s,
                  else: "conflict"

              _ ->
                "conflict"
            end

          {:ok,
           %{
             mode: :source_auth_terminal,
             target: target,
             token: token,
             intent_id: intent_id,
             fingerprint: fingerprint,
             operation_id: operation_id,
             outcome: "conflict",
             reason_code: reason_code
           }}

        _ ->
          :skip
      end
    else
      :skip
    end
  end

  defp classify_guarded_worker_terminal_for_durable(reason) do
    # Close before durable reason_code — never emit raw binary/tuple prefixes.
    closed = IntentCore.redact_error_reason(reason)

    case closed do
      :witness_mismatch ->
        {"conflict", "witness_mismatch"}

      :conflict ->
        {"conflict", "conflict"}

      :pre_effect_abort ->
        {"not_applied", "pre_effect_abort"}

      :owner_down ->
        {"not_applied", "pre_effect_abort"}

      atom when is_atom(atom) ->
        code = Atom.to_string(atom)

        if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, code) and byte_size(code) <= 64 do
          {"failed", code}
        else
          {"failed", "worker_failed"}
        end
    end
  end

  defp launch_guarded_durable_settle_shell(state, request) when is_map(request) do
    launch_guarded_durable_settle_shell(state, request, 0)
  end

  defp launch_guarded_durable_settle_shell(state, request, attempt)
       when is_map(request) and is_integer(attempt) and attempt >= 0 do
    state = ensure_runtime_admission_shape(state)
    target = Map.get(request, :target)
    intent_id = Map.get(request, :intent_id)

    cond do
      not (is_binary(target) and is_binary(intent_id) and is_binary(Map.get(request, :token))) ->
        state

      # Already tracking a live worker for this identity — do not double-launch.
      durable_settle_pending_for?(state, target, intent_id) ->
        state

      # Same-identity exhausted cycle: inert (no re-launch with attempt>0).
      durable_settle_identity_exhausted?(state, request) and attempt > 0 ->
        state

      attempt >= @max_runtime_admission_durable_shell_launch_attempts ->
        # Exhausted: keep fence held via progress; release waiters with unknown.
        state =
          put_durable_settle_progress(state, request, :exhausted, attempt, :launch_exhausted)

        release_deferred_waiter_reply(state, intent_id, {:error, :outcome_unknown})

      true ->
        settle_ref = make_ref()
        store_ref = Map.get(state, :store_ref, @default_name)
        request = Map.put(request, :launch_attempt, attempt)

        worker_mfa =
          {__MODULE__, :run_runtime_admission_durable_settle, [store_ref, settle_ref, request]}

        {state, launch_ref} =
          begin_runtime_admission_operation_launch(
            state,
            :durable_settle,
            settle_ref,
            worker_mfa
          )

        meta = durable_settle_pending_meta(request, attempt, launch_ref)

        state
        |> put_in([:runtime_admission_pending_durable_settle, settle_ref], meta)
        |> put_durable_settle_progress(request, :pending, attempt, nil)
    end
  end

  defp durable_settle_pending_for?(state, target, intent_id) do
    state
    |> Map.get(:runtime_admission_pending_durable_settle, %{})
    |> Map.values()
    |> Enum.any?(fn meta ->
      is_map(meta) and Map.get(meta, :target) == target and
        Map.get(meta, :intent_id) == intent_id
    end)
  end

  defp durable_settle_identity_exhausted?(state, request) when is_map(request) do
    target = Map.get(request, :target)
    intent_id = Map.get(request, :intent_id)
    token = Map.get(request, :token)
    fingerprint = Map.get(request, :fingerprint)
    operation_id = Map.get(request, :operation_id)
    mode = Map.get(request, :mode)

    case Map.get(Map.get(state, :runtime_admission_durable_settle_progress, %{}), target) do
      %{
        intent_id: ^intent_id,
        token: ^token,
        fingerprint: ^fingerprint,
        operation_id: ^operation_id,
        mode: ^mode,
        status: :exhausted
      } = progress ->
        durable_settle_terminal_matches?(progress, request)

      _ ->
        false
    end
  end

  defp durable_settle_identity_exhausted?(_, _), do: false

  defp durable_settle_pending_meta(request, attempt, launch_ref) do
    %{
      status: :admitting,
      launch_ref: launch_ref,
      target: request.target,
      token: request.token,
      intent_id: request.intent_id,
      fingerprint: Map.get(request, :fingerprint),
      operation_id: Map.get(request, :operation_id),
      mode: Map.get(request, :mode),
      outcome: Map.get(request, :outcome),
      reason_code: Map.get(request, :reason_code),
      launch_attempt: attempt,
      request: request
    }
  end

  defp track_durable_settle_observer(
         state,
         settle_ref,
         request,
         worker_pid,
         attempt,
         launch_ref
       )
       when is_reference(settle_ref) and is_pid(worker_pid) do
    mon = Process.monitor(worker_pid)

    timeout_ms =
      Map.get(
        state,
        :runtime_admission_durable_op_timeout_ms,
        @default_runtime_admission_durable_op_timeout_ms
      )

    timer =
      Process.send_after(
        self(),
        {:runtime_admission_durable_settle_timeout, settle_ref},
        timeout_ms
      )

    meta = %{
      status: :running,
      launch_ref: launch_ref,
      target: request.target,
      token: request.token,
      intent_id: request.intent_id,
      fingerprint: Map.get(request, :fingerprint),
      operation_id: Map.get(request, :operation_id),
      mode: Map.get(request, :mode),
      outcome: Map.get(request, :outcome),
      reason_code: Map.get(request, :reason_code),
      launch_attempt: attempt,
      request: request,
      worker_pid: worker_pid,
      mon: mon,
      timer: timer
    }

    state
    |> put_in([:runtime_admission_pending_durable_settle, settle_ref], meta)
    |> put_in([:runtime_admission_durable_settle_monitors, mon], settle_ref)
    |> put_durable_settle_progress(request, :pending, attempt, nil)
  end

  defp fail_durable_settle_launch(state, meta, reason) when is_map(meta) do
    request = Map.get(meta, :request, meta)
    attempt = Map.get(meta, :launch_attempt, 0)
    next = attempt + 1

    state =
      put_durable_settle_progress(
        state,
        request,
        if(next >= @max_runtime_admission_durable_shell_launch_attempts,
          do: :exhausted,
          else: :launch_retry
        ),
        attempt,
        reason
      )

    if next < @max_runtime_admission_durable_shell_launch_attempts do
      Process.send_after(
        self(),
        {:runtime_admission_durable_settle_retry, request, next},
        durable_shell_launch_backoff_ms(attempt)
      )

      state
    else
      release_deferred_waiter_reply(state, meta.intent_id, {:error, :outcome_unknown})
    end
  end

  # Retry/progress authentication: exact target+token+intent+fingerprint+
  # operation+mode (+ terminal for source_auth). No nil/default-true shortcuts;
  # unknown/stale same-target progress never authorizes a different request.
  defp durable_settle_retry_current?(state, request, attempt)
       when is_map(request) and is_integer(attempt) and attempt > 0 do
    target = Map.get(request, :target)
    token = Map.get(request, :token)
    intent_id = Map.get(request, :intent_id)
    fingerprint = Map.get(request, :fingerprint)
    operation_id = Map.get(request, :operation_id)
    mode = Map.get(request, :mode)

    is_binary(target) and is_binary(token) and is_binary(intent_id) and
      is_binary(fingerprint) and is_binary(operation_id) and is_atom(mode) and
      not durable_settle_pending_for?(state, target, intent_id) and
      case Map.get(Map.get(state, :runtime_admission_durable_settle_progress, %{}), target) do
        %{
          intent_id: ^intent_id,
          token: ^token,
          fingerprint: ^fingerprint,
          operation_id: ^operation_id,
          mode: ^mode,
          status: status,
          attempt: prior_attempt
        } = progress
        when status in [:pending, :launch_retry, :shell_error_retry] and
               attempt == prior_attempt + 1 ->
          durable_settle_terminal_matches?(progress, request)

        # First launches call launch_guarded_durable_settle_shell/2 directly.
        # A retry message without exact prior progress is unauthenticated.
        nil ->
          false

        # Exhausted / done / mismatched identity — never retry.
        _ ->
          false
      end
  end

  defp durable_settle_retry_current?(_, _, _), do: false

  defp durable_settle_terminal_matches?(progress, request) do
    case Map.get(request, :mode) do
      :observe_then_applied ->
        Map.get(progress, :mode) == :observe_then_applied and
          Map.get(progress, :reason_code) == Map.get(request, :reason_code)

      :source_auth_terminal ->
        Map.get(progress, :mode) == :source_auth_terminal and
          Map.get(progress, :outcome) == Map.get(request, :outcome) and
          Map.get(progress, :reason_code) == Map.get(request, :reason_code)

      _ ->
        false
    end
  end

  defp put_durable_settle_progress(state, request, status, attempt, last_error)
       when is_map(request) do
    target = Map.get(request, :target)
    intent_id = Map.get(request, :intent_id)
    token = Map.get(request, :token)
    fingerprint = Map.get(request, :fingerprint)
    operation_id = Map.get(request, :operation_id)
    mode = Map.get(request, :mode)

    if is_binary(target) and is_binary(intent_id) and is_binary(token) and
         is_binary(fingerprint) and is_binary(operation_id) and is_atom(mode) do
      progress = Map.get(state, :runtime_admission_durable_settle_progress, %{})

      entry = %{
        intent_id: intent_id,
        token: token,
        fingerprint: fingerprint,
        operation_id: operation_id,
        mode: mode,
        outcome: Map.get(request, :outcome),
        reason_code: Map.get(request, :reason_code),
        status: status,
        attempt: attempt,
        last_error: last_error
      }

      put_in(
        state,
        [:runtime_admission_durable_settle_progress],
        Map.put(progress, target, entry)
      )
    else
      state
    end
  end

  defp delete_durable_settle_progress(state, request) when is_map(request) do
    target = Map.get(request, :target)
    intent_id = Map.get(request, :intent_id)
    token = Map.get(request, :token)
    progress = Map.get(state, :runtime_admission_durable_settle_progress, %{})

    case Map.get(progress, target) do
      %{intent_id: ^intent_id, token: ^token} ->
        put_in(
          state,
          [:runtime_admission_durable_settle_progress],
          Map.delete(progress, target)
        )

      _ ->
        state
    end
  end

  defp release_deferred_waiter_reply(state, intent_id, reply)
       when is_binary(intent_id) do
    deferred = Map.get(state, :runtime_admission_deferred_waiter_reply, %{})

    case Map.pop(deferred, intent_id) do
      {nil, _} ->
        state

      {_meta, rest} ->
        state = put_in(state, [:runtime_admission_deferred_waiter_reply], rest)
        detach_and_reply_runtime_admission_waiters(state, intent_id, reply)
    end
  end

  @doc false
  def run_runtime_admission_durable_settle(store_ref, settle_ref, request)
      when is_reference(settle_ref) and is_map(request) do
    result = durable_settle_with_retry(request, 0)

    OperationLauncher.notify(
      store_ref,
      {:runtime_admission_durable_settle_done, settle_ref,
       durable_settle_envelope(request, result)}
    )

    :ok
  rescue
    _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_durable_settle_done, settle_ref,
         durable_settle_envelope(request, {:error, :settle_exception})}
      )

      :ok
  catch
    :exit, _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_durable_settle_done, settle_ref,
         durable_settle_envelope(request, {:error, :settle_exit})}
      )

      :ok
  end

  defp durable_settle_envelope(request, result) when is_map(request) do
    %{
      worker_pid: self(),
      target: Map.get(request, :target),
      token: Map.get(request, :token),
      intent_id: Map.get(request, :intent_id),
      fingerprint: Map.get(request, :fingerprint),
      operation_id: Map.get(request, :operation_id),
      mode: Map.get(request, :mode),
      outcome: Map.get(request, :outcome),
      reason_code: Map.get(request, :reason_code),
      result: result
    }
  end

  defp durable_settle_with_retry(request, attempt)
       when is_map(request) and is_integer(attempt) and attempt < 4 do
    case Map.get(request, :mode) do
      :observe_then_applied ->
        durable_settle_applied_after_exact_observation(request, attempt)

      :source_auth_terminal ->
        durable_settle_source_auth_terminal(request, attempt)

      _ ->
        {:error, :invalid_settle_request}
    end
  end

  defp durable_settle_with_retry(_request, _attempt), do: {:error, :settle_retry_exhausted}

  # Applied only after exact guarded branch observation for same op/token/intent/fp.
  # Absence/mismatch after handoff → outcome_unknown (never invent applied).
  # Returns tagged {:ok, :applied | :outcome_unknown | :settled_terminal} so the
  # TaskStore callback need not re-fetch durable state.
  defp durable_settle_applied_after_exact_observation(request, attempt) do
    target = request.target
    token = request.token
    intent_id = request.intent_id
    fingerprint = request.fingerprint
    operation_id = request.operation_id

    case Arbor.Agent.BranchSupervisor.observe_admission(target) do
      {:running, _pid,
       {:ok,
        %{
          kind: :guarded_restore,
          intent_id: ^intent_id,
          fingerprint: ^fingerprint,
          operation_id: ^operation_id,
          token: ^token
        }}} ->
        settlement = %{
          "outcome" => "applied",
          "reason_code" => Map.get(request, :reason_code, "branch_restored"),
          "at_unix_ms" => System.system_time(:millisecond)
        }

        case durable_settle_commit_with_retry(target, token, settlement, attempt) do
          {:ok, _} -> {:ok, :applied}
          {:error, _} = err -> err
        end

      _ ->
        # Post-handoff indeterminate: never applied from absence/mismatch.
        case Arbor.Agent.TemplateAuthorityReconciliationStore.mark_runtime_restore_outcome_unknown(
               target,
               token
             ) do
          {:ok, _} ->
            {:ok, :outcome_unknown}

          {:error, reason}
          when reason in [:cas_conflict, :outcome_unknown, :backend_unavailable] and attempt < 3 ->
            Process.sleep(25 * (attempt + 1))
            durable_settle_with_retry(request, attempt + 1)

          {:error, _} = err ->
            err
        end
    end
  end

  # Source-auth failed/conflict/not_applied: TaskStore accepted only the exact
  # bound worker/monitor terminal. No branch observation invents applied.
  defp durable_settle_source_auth_terminal(request, attempt) do
    settlement = %{
      "outcome" => request.outcome,
      "reason_code" => request.reason_code,
      "at_unix_ms" => System.system_time(:millisecond)
    }

    case durable_settle_commit_with_retry(request.target, request.token, settlement, attempt) do
      {:ok, _} -> {:ok, :settled_terminal}
      {:error, _} = err -> err
    end
  end

  defp durable_settle_commit_with_retry(target, token, settlement, attempt)
       when is_integer(attempt) and attempt < 4 do
    case Arbor.Agent.TemplateAuthorityReconciliationStore.settle_runtime_restore_admission(
           target,
           token,
           settlement
         ) do
      {:ok, _} = ok ->
        ok

      # Same outcome+reason already recorded (first at kept) — exact successor.
      {:error, :already_settled} ->
        case reobserve_durable_settle_successor(target, token, settlement) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> err
        end

      {:error, reason}
      when reason in [:cas_conflict, :outcome_unknown, :backend_unavailable] and attempt < 3 ->
        Process.sleep(25 * (attempt + 1))

        case reobserve_durable_settle_successor(target, token, settlement) do
          {:ok, _} = ok ->
            ok

          _ ->
            durable_settle_commit_with_retry(target, token, settlement, attempt + 1)
        end

      {:error, _} = err ->
        err
    end
  end

  defp durable_settle_commit_with_retry(_target, _token, _settlement, _attempt),
    do: {:error, :settle_retry_exhausted}

  defp reobserve_durable_settle_successor(target, token, expected_settlement) do
    case Arbor.Agent.TemplateAuthorityReconciliationStore.fetch(target) do
      {:ok, op} ->
        case Map.get(op, "runtime_restore_admission") do
          %{
            "token" => ^token,
            "claim_phase" => "settled",
            "settlement" => settlement
          } = _claim
          when is_map(settlement) ->
            if Arbor.Agent.RuntimeRestoreAdmissionClaimCore.settlement_same_terminal?(
                 settlement,
                 expected_settlement
               ) do
              {:ok, op}
            else
              {:error, :already_settled}
            end

          _ ->
            {:error, :not_yet_settled}
        end

      {:error, _} = err ->
        err
    end
  catch
    :exit, _ -> {:error, :fetch_exit}
  end

  defp handle_runtime_admission_durable_settle_done(state, settle_ref, envelope) do
    state = ensure_runtime_admission_shape(state)
    pending = Map.get(state, :runtime_admission_pending_durable_settle, %{})

    case Map.get(pending, settle_ref) do
      nil ->
        # Stale/duplicate — inert.
        state

      meta when is_map(meta) ->
        if not durable_settle_result_authentic?(meta, envelope) do
          # Wrong worker / identity forge — leave pending for real worker/timeout.
          state
        else
          rest = Map.delete(pending, settle_ref)

          state =
            state
            |> put_in([:runtime_admission_pending_durable_settle], rest)
            |> clear_durable_settle_observer_tracking(meta)

          request = Map.get(meta, :request, meta)
          attempt = Map.get(meta, :launch_attempt, 0)
          intent_id = meta.intent_id
          result = if is_map(envelope), do: Map.get(envelope, :result), else: envelope

          case result do
            {:ok, tag} when tag in [:applied, :outcome_unknown, :settled_terminal] ->
              if durable_settle_success_tag_valid?(Map.get(meta, :mode), tag) do
                state = delete_durable_settle_progress(state, request)
                # Tag from outside-callback shell — no durable I/O in this callback.
                deferred = Map.get(state, :runtime_admission_deferred_waiter_reply, %{})

                case Map.get(deferred, intent_id) do
                  %{reply: reply} ->
                    release_reply =
                      if tag == :outcome_unknown,
                        do: {:error, :outcome_unknown},
                        else: reply

                    release_deferred_waiter_reply(state, intent_id, release_reply)

                  _ ->
                    state
                end
              else
                reject_durable_settle_result(state, request, attempt, intent_id)
              end

            {:ok, _unknown_tag} ->
              reject_durable_settle_result(state, request, attempt, intent_id)

            {:error, reason} ->
              # Terminal shell failure is not silent convergence — bounded relaunch.
              next = attempt + 1

              state =
                put_durable_settle_progress(
                  state,
                  request,
                  if(next >= @max_runtime_admission_durable_shell_launch_attempts,
                    do: :exhausted,
                    else: :shell_error_retry
                  ),
                  attempt,
                  reason
                )

              if next < @max_runtime_admission_durable_shell_launch_attempts and
                   durable_settle_retry_current?(state, request, next) do
                Process.send_after(
                  self(),
                  {:runtime_admission_durable_settle_retry, request, next},
                  durable_shell_launch_backoff_ms(attempt)
                )

                state
              else
                # Exhausted: conservative block (fence via progress); no success.
                release_deferred_waiter_reply(state, intent_id, {:error, :outcome_unknown})
              end

            _malformed_result ->
              reject_durable_settle_result(state, request, attempt, intent_id)
          end
        end

      _ ->
        state
    end
  end

  defp durable_settle_success_tag_valid?(:observe_then_applied, tag)
       when tag in [:applied, :outcome_unknown],
       do: true

  defp durable_settle_success_tag_valid?(:source_auth_terminal, :settled_terminal), do: true
  defp durable_settle_success_tag_valid?(_, _), do: false

  defp reject_durable_settle_result(state, request, attempt, intent_id) do
    state
    |> put_durable_settle_progress(request, :exhausted, attempt, :invalid_settle_result)
    |> release_deferred_waiter_reply(intent_id, {:error, :outcome_unknown})
  end

  # Exact identity binding on complete: worker + target/token/intent/fingerprint/
  # operation/mode/outcome/reason. Optional terminal fields must be present even
  # when their exact value is nil; absent keys never default-authenticate.
  defp durable_settle_result_authentic?(meta, envelope)
       when is_map(meta) and is_map(envelope) do
    is_pid(Map.get(meta, :worker_pid)) and
      Map.get(envelope, :worker_pid) == Map.get(meta, :worker_pid) and
      is_binary(meta.target) and Map.get(envelope, :target) == meta.target and
      is_binary(meta.token) and Map.get(envelope, :token) == meta.token and
      is_binary(meta.intent_id) and Map.get(envelope, :intent_id) == meta.intent_id and
      is_binary(Map.get(meta, :fingerprint)) and
      Map.get(envelope, :fingerprint) == Map.get(meta, :fingerprint) and
      is_binary(Map.get(meta, :operation_id)) and
      Map.get(envelope, :operation_id) == Map.get(meta, :operation_id) and
      is_atom(Map.get(meta, :mode)) and
      Map.get(envelope, :mode) == Map.get(meta, :mode) and
      Map.has_key?(envelope, :outcome) and
      Map.get(envelope, :outcome) == Map.get(meta, :outcome) and
      Map.has_key?(envelope, :reason_code) and
      Map.get(envelope, :reason_code) == Map.get(meta, :reason_code)
  end

  # Legacy bare {:ok,_}/{:error,_} results without worker binding — reject.
  defp durable_settle_result_authentic?(_meta, _other), do: false

  defp handle_runtime_admission_durable_settle_timeout(state, settle_ref)
       when is_reference(settle_ref) do
    state = ensure_runtime_admission_shape(state)
    pending = Map.get(state, :runtime_admission_pending_durable_settle, %{})

    case Map.pop(pending, settle_ref) do
      {nil, _} ->
        state

      {meta, rest} when is_map(meta) ->
        state =
          state
          |> put_in([:runtime_admission_pending_durable_settle], rest)
          |> clear_durable_settle_observer_tracking(meta)

        case Map.get(meta, :worker_pid) do
          pid when is_pid(pid) ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)

          _ ->
            :ok
        end

        request = Map.get(meta, :request, meta)
        attempt = Map.get(meta, :launch_attempt, 0)
        next = attempt + 1
        intent_id = meta.intent_id

        state =
          put_durable_settle_progress(
            state,
            request,
            if(next >= @max_runtime_admission_durable_shell_launch_attempts,
              do: :exhausted,
              else: :shell_error_retry
            ),
            attempt,
            :observer_timeout
          )

        if next < @max_runtime_admission_durable_shell_launch_attempts do
          Process.send_after(
            self(),
            {:runtime_admission_durable_settle_retry, request, next},
            durable_shell_launch_backoff_ms(attempt)
          )

          state
        else
          release_deferred_waiter_reply(state, intent_id, {:error, :outcome_unknown})
        end

      _ ->
        state
    end
  end

  defp handle_runtime_admission_durable_settle_monitor_down(state, mon, settle_ref)
       when is_reference(mon) and is_reference(settle_ref) do
    state = ensure_runtime_admission_shape(state)
    settle_mons = Map.get(state, :runtime_admission_durable_settle_monitors, %{})

    state =
      put_in(state, [:runtime_admission_durable_settle_monitors], Map.delete(settle_mons, mon))

    pending = Map.get(state, :runtime_admission_pending_durable_settle, %{})

    case Map.get(pending, settle_ref) do
      %{mon: ^mon} = meta ->
        # Prefer result message if it races; pure crash converges via timer.
        updated = %{meta | mon: nil, worker_pid: nil}
        put_in(state, [:runtime_admission_pending_durable_settle, settle_ref], updated)

      _ ->
        state
    end
  end

  defp clear_durable_settle_observer_tracking(state, meta) when is_map(meta) do
    state =
      case Map.get(meta, :timer) do
        timer when is_reference(timer) ->
          _ = Process.cancel_timer(timer)
          state

        _ ->
          state
      end

    case Map.get(meta, :mon) do
      mon when is_reference(mon) ->
        Process.demonitor(mon, [:flush])
        settle_mons = Map.get(state, :runtime_admission_durable_settle_monitors, %{})
        put_in(state, [:runtime_admission_durable_settle_monitors], Map.delete(settle_mons, mon))

      _ ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Durable claim join after owner death (pre-handoff crash window)
  #
  # Fixed supervised recovery operation (not fire-and-forget):
  # - Pending entry always carries observer PID + monitor + bounded timer
  # - Crash/hang/timeout → bounded retry with evidence; exhaustion parks blocked
  # - Duplicate/stale DOWN/timeout/result messages are inert
  # - minted_pre_effect only after fresh BranchSupervisor.observe_admission/1
  #   in the same outside-callback observer; any branch occupancy holds
  # - No BranchSupervisor / durable-store I/O in TaskStore callbacks
  # ---------------------------------------------------------------------------

  # Keep intent non-idle while a fixed outside-callback observer joins the
  # durable claim. Bound → outcome_unknown hold; minted + fresh not_running →
  # pre-effect. Occupancy / join failure never invents pre-effect.
  defp enqueue_durable_claim_join(state, request, intent, monitored_owner_pid) do
    state = ensure_runtime_admission_shape(state)
    target = request.target
    token = Map.get(request, :restore_token) || Map.get(intent, :restore_token)

    # Park memory immediately so fence removal stays blocked while joining.
    state =
      case IntentCore.note_owner_gone_await_worker(
             state.runtime_admission_intents,
             target,
             intent.intent_id,
             monitored_owner_pid
           ) do
        {:ok, _updated, intents, effects} ->
          state
          |> put_in([:runtime_admission_intents], intents)
          |> apply_runtime_admission_effects(effects)

        {:ok, :already_awaiting, _intent, intents, effects} ->
          state
          |> put_in([:runtime_admission_intents], intents)
          |> apply_runtime_admission_effects(effects)

        {:error, _} ->
          updated = %{
            intent
            | phase: :outcome_unknown,
              owner_pid: nil,
              retire_barrier: :none,
              # Conservative: treat as post-bind capable until claim join says minted.
              effect_handoff?: Map.get(intent, :effect_handoff?) == true
          }

          put_in(state, [:runtime_admission_intents, target], updated)
      end

    if is_binary(token) do
      join_request = %{
        target: target,
        intent_id: intent.intent_id,
        fingerprint: intent.fingerprint,
        token: token,
        operation_id: Map.get(intent, :operation_id) || Map.get(request, :operation_id),
        monitored_owner_pid: monitored_owner_pid
      }

      cond do
        claim_join_already_pending?(state, target, intent.intent_id) ->
          state

        claim_join_exhausted?(state, target, intent.intent_id) ->
          # Prior bounded cycle exhausted — stay conservatively blocked.
          ensure_parked_unknown(
            state,
            target,
            Map.get(state.runtime_admission_intents, target) || intent
          )

        true ->
          launch_durable_claim_join_observer(state, join_request, 0)
      end
    else
      # No token — cannot join claim; keep non-idle park (no pre-effect proof).
      state
    end
  end

  defp claim_join_already_pending?(state, target, intent_id) do
    state
    |> Map.get(:runtime_admission_pending_claim_join, %{})
    |> Map.values()
    |> Enum.any?(fn
      %{target: ^target, intent_id: ^intent_id} -> true
      _ -> false
    end)
  end

  defp claim_join_exhausted?(state, target, intent_id) do
    case Map.get(Map.get(state, :runtime_admission_claim_join_progress, %{}), target) do
      %{intent_id: ^intent_id, status: :exhausted} -> true
      _ -> false
    end
  end

  defp launch_durable_claim_join_observer(state, request, attempt)
       when is_map(request) and is_integer(attempt) and attempt >= 0 do
    state = ensure_runtime_admission_shape(state)
    target = request.target
    intent_id = request.intent_id
    token = request.token

    cond do
      attempt >= @max_runtime_admission_claim_join_attempts ->
        state =
          put_claim_join_progress(
            state,
            request,
            :exhausted,
            attempt,
            :launch_exhausted
          )

        intent = Map.get(state.runtime_admission_intents, target)
        if is_map(intent), do: ensure_parked_unknown(state, target, intent), else: state

      not (is_binary(target) and is_binary(intent_id) and is_binary(token) and
               is_binary(request.fingerprint)) ->
        state

      true ->
        join_ref = make_ref()
        store_ref = Map.get(state, :store_ref, @default_name)

        worker_mfa =
          {__MODULE__, :run_runtime_admission_claim_join_observer, [store_ref, join_ref, request]}

        {state, launch_ref} =
          begin_runtime_admission_operation_launch(
            state,
            :claim_join,
            join_ref,
            worker_mfa
          )

        meta = %{
          status: :admitting,
          launch_ref: launch_ref,
          target: request.target,
          intent_id: request.intent_id,
          fingerprint: request.fingerprint,
          token: request.token,
          operation_id: Map.get(request, :operation_id),
          monitored_owner_pid: Map.get(request, :monitored_owner_pid),
          attempt: attempt,
          request: request
        }

        state
        |> put_in([:runtime_admission_pending_claim_join, join_ref], meta)
        |> put_claim_join_progress(request, :pending, attempt, nil)
    end
  end

  defp track_claim_join_observer(
         state,
         join_ref,
         request,
         observer_pid,
         attempt,
         launch_ref
       )
       when is_reference(join_ref) and is_pid(observer_pid) do
    mon = Process.monitor(observer_pid)

    timeout_ms =
      Map.get(
        state,
        :runtime_admission_claim_join_timeout_ms,
        @default_runtime_admission_claim_join_timeout_ms
      )

    timer =
      Process.send_after(self(), {:runtime_admission_claim_join_timeout, join_ref}, timeout_ms)

    meta = %{
      status: :running,
      launch_ref: launch_ref,
      target: request.target,
      intent_id: request.intent_id,
      fingerprint: request.fingerprint,
      token: request.token,
      operation_id: Map.get(request, :operation_id),
      monitored_owner_pid: Map.get(request, :monitored_owner_pid),
      attempt: attempt,
      request: request,
      worker_pid: observer_pid,
      observer_pid: observer_pid,
      mon: mon,
      timer: timer
    }

    state
    |> put_in([:runtime_admission_pending_claim_join, join_ref], meta)
    |> put_in([:runtime_admission_claim_join_monitors, mon], join_ref)
    |> put_claim_join_progress(request, :pending, attempt, nil)
  end

  defp put_claim_join_progress(state, request, status, attempt, last_error)
       when is_map(request) do
    target = Map.get(request, :target)
    intent_id = Map.get(request, :intent_id)
    progress = Map.get(state, :runtime_admission_claim_join_progress, %{})

    entry = %{
      intent_id: intent_id,
      token: Map.get(request, :token),
      fingerprint: Map.get(request, :fingerprint),
      operation_id: Map.get(request, :operation_id),
      status: status,
      attempt: attempt,
      last_error: last_error
    }

    if is_binary(target) and is_binary(intent_id) do
      put_in(state, [:runtime_admission_claim_join_progress], Map.put(progress, target, entry))
    else
      state
    end
  end

  defp delete_claim_join_progress(state, meta) when is_map(meta) do
    target = Map.get(meta, :target)
    intent_id = Map.get(meta, :intent_id)
    token = Map.get(meta, :token)
    progress = Map.get(state, :runtime_admission_claim_join_progress, %{})

    case Map.get(progress, target) do
      %{intent_id: ^intent_id, token: ^token} ->
        put_in(state, [:runtime_admission_claim_join_progress], Map.delete(progress, target))

      _ ->
        state
    end
  end

  defp claim_join_retry_current?(state, request, attempt)
       when is_map(request) and is_integer(attempt) and attempt > 0 do
    target = Map.get(request, :target)
    intent_id = Map.get(request, :intent_id)
    token = Map.get(request, :token)
    fingerprint = Map.get(request, :fingerprint)
    operation_id = Map.get(request, :operation_id)

    is_binary(target) and is_binary(intent_id) and is_binary(token) and is_binary(fingerprint) and
      is_binary(operation_id) and
      not claim_join_already_pending?(state, target, intent_id) and
      claim_join_intent_current?(
        Map.get(Map.get(state, :runtime_admission_intents, %{}), target),
        %{
          target: target,
          intent_id: intent_id,
          fingerprint: fingerprint,
          token: token,
          operation_id: operation_id
        }
      ) and
      case Map.get(Map.get(state, :runtime_admission_claim_join_progress, %{}), target) do
        %{
          intent_id: ^intent_id,
          token: ^token,
          fingerprint: ^fingerprint,
          operation_id: ^operation_id,
          status: status,
          attempt: prior_attempt
        }
        when status in [:retry, :launch_retry] and attempt == prior_attempt + 1 ->
          true

        _ ->
          false
      end
  end

  defp claim_join_retry_current?(_, _, _), do: false

  @doc false
  def run_runtime_admission_claim_join_observer(store_ref, join_ref, request)
      when is_reference(join_ref) and is_map(request) do
    request = ensure_claim_join_operation_id(request)
    maybe_runtime_admission_claim_join_test_hang(request)
    result = build_claim_join_result(request)
    OperationLauncher.notify(store_ref, {:runtime_admission_claim_joined, join_ref, result})
    :ok
  rescue
    _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_claim_joined, join_ref, claim_join_unavailable_result(request)}
      )

      :ok
  catch
    :exit, _ ->
      OperationLauncher.notify(
        store_ref,
        {:runtime_admission_claim_joined, join_ref, claim_join_unavailable_result(request)}
      )

      :ok
  end

  # Back-compat MFA for direct security-regression calls (legacy 6-arity).
  @doc false
  def run_runtime_admission_claim_join_observer(
        store_ref,
        join_ref,
        target,
        token,
        intent_id,
        fingerprint
      )
      when is_reference(join_ref) and is_binary(target) and is_binary(token) and
             is_binary(intent_id) and is_binary(fingerprint) do
    request = %{
      target: target,
      token: token,
      intent_id: intent_id,
      fingerprint: fingerprint
    }

    run_runtime_admission_claim_join_observer(store_ref, join_ref, request)
  end

  # Compatibility for pre-operation-bound direct worker calls. Production
  # TaskStore launches always carry the exact operation_id in their closed
  # request; a legacy direct call can only recover the current durable identity.
  defp ensure_claim_join_operation_id(%{operation_id: operation_id} = request)
       when is_binary(operation_id),
       do: request

  defp ensure_claim_join_operation_id(%{target: target} = request) when is_binary(target) do
    case Arbor.Agent.TemplateAuthorityReconciliationStore.fetch(target) do
      {:ok, %{"operation_id" => operation_id}} when is_binary(operation_id) ->
        Map.put(request, :operation_id, operation_id)

      _ ->
        request
    end
  end

  defp ensure_claim_join_operation_id(request), do: request

  defp maybe_runtime_admission_claim_join_test_hang(request) when is_map(request) do
    if Mix.env() == :test do
      case Application.get_env(:arbor_agent, :runtime_admission_test_claim_join_hang) do
        %{timeout_ms: ms, target: target}
        when is_integer(ms) and ms > 0 and is_binary(target) ->
          if Map.get(request, :target) == target, do: Process.sleep(ms)

        %{timeout_ms: ms} when is_integer(ms) and ms > 0 ->
          Process.sleep(ms)

        true ->
          # Hold until the test clears the env (timeout/DOWN regressions).
          hang_claim_join_until_released()

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  if Mix.env() == :test do
    defp hang_claim_join_until_released do
      if Application.get_env(:arbor_agent, :runtime_admission_test_claim_join_hang) == true do
        Process.sleep(50)
        hang_claim_join_until_released()
      else
        :ok
      end
    end
  else
    defp hang_claim_join_until_released, do: :ok
  end

  defp claim_join_unavailable_result(request) when is_map(request) do
    %{
      worker_pid: self(),
      target: Map.get(request, :target),
      token: Map.get(request, :token),
      intent_id: Map.get(request, :intent_id),
      fingerprint: Map.get(request, :fingerprint),
      operation_id: Map.get(request, :operation_id),
      classification: :join_unavailable,
      branch_fact: :observe_failed
    }
  end

  defp build_claim_join_result(request) when is_map(request) do
    target = Map.fetch!(request, :target)
    token = Map.fetch!(request, :token)
    intent_id = Map.fetch!(request, :intent_id)
    fingerprint = Map.fetch!(request, :fingerprint)
    operation_id = Map.fetch!(request, :operation_id)

    claim_class =
      classify_durable_claim_phase_for_join(
        target,
        token,
        intent_id,
        fingerprint,
        operation_id
      )

    # Fresh single-read occupancy in THIS observer — never reuse earlier witness.
    branch_fact = fresh_branch_fact_for_claim_join(target)

    classification =
      case {claim_class, branch_fact} do
        {:minted_pre_effect, :not_running} ->
          :minted_pre_effect

        {:minted_pre_effect, _occupied} ->
          # Bare / ordinary / mismatched / exact occupancy blocks pre-effect.
          :occupancy_hold

        {other, _} ->
          other
      end

    %{
      worker_pid: self(),
      target: target,
      token: token,
      intent_id: intent_id,
      fingerprint: fingerprint,
      operation_id: operation_id,
      classification: classification,
      branch_fact: branch_fact
    }
  end

  # Durable claim phase only — no branch I/O here; branch is separate fresh read.
  defp classify_durable_claim_phase_for_join(
         target,
         token,
         intent_id,
         fingerprint,
         operation_id
       ) do
    case Arbor.Agent.TemplateAuthorityReconciliationStore.fetch(target) do
      {:ok, %{"operation_id" => ^operation_id} = op} ->
        case Map.get(op, "runtime_restore_admission") do
          %{
            "operation_id" => ^operation_id,
            "token" => ^token,
            "intent_id" => ^intent_id,
            "fingerprint" => ^fingerprint,
            "claim_phase" => "bound",
            "settlement" => nil
          } ->
            :bound_hold

          %{
            "operation_id" => ^operation_id,
            "token" => ^token,
            "intent_id" => ^intent_id,
            "fingerprint" => ^fingerprint,
            "claim_phase" => "outcome_unknown"
          } ->
            :outcome_unknown_hold

          %{
            "operation_id" => ^operation_id,
            "token" => ^token,
            "intent_id" => nil,
            "fingerprint" => nil,
            "claim_phase" => "minted",
            "settlement" => nil
          } ->
            :minted_pre_effect

          %{
            "operation_id" => ^operation_id,
            "token" => ^token,
            "claim_phase" => "settled",
            "settlement" => %{"outcome" => "applied"}
          } ->
            :settled_applied

          %{
            "operation_id" => ^operation_id,
            "token" => ^token,
            "claim_phase" => "settled"
          } ->
            :settled_other

          nil ->
            :claim_absent

          _ ->
            :claim_mismatch
        end

      {:ok, _other_operation} ->
        :claim_mismatch

      {:error, _} ->
        :join_unavailable
    end
  end

  # Outside-callback only. Any running occupancy prevents minted pre-effect.
  defp fresh_branch_fact_for_claim_join(target) when is_binary(target) do
    case Arbor.Agent.BranchSupervisor.observe_admission(target) do
      :not_running ->
        :not_running

      {:running, _pid, :none} ->
        :bare

      {:running, _pid, {:ok, %{kind: :ordinary_start}}} ->
        :ordinary

      {:running, _pid, {:ok, %{kind: :guarded_restore, intent_id: id}}} when is_binary(id) ->
        {:guarded, id}

      {:running, _pid, {:ok, _}} ->
        :bare

      _ ->
        :observe_failed
    end
  rescue
    _ -> :observe_failed
  catch
    :exit, _ -> :observe_failed
  end

  defp handle_runtime_admission_claim_joined(state, join_ref, result)
       when is_reference(join_ref) and is_map(result) do
    state = ensure_runtime_admission_shape(state)
    pending = Map.get(state, :runtime_admission_pending_claim_join, %{})

    case Map.get(pending, join_ref) do
      nil ->
        # Stale/duplicate result — inert.
        state

      meta when is_map(meta) ->
        # Wrong worker / forged identity must not clear the live pending join.
        if not claim_join_result_authentic?(meta, result) do
          state
        else
          rest = Map.delete(pending, join_ref)

          state =
            state
            |> put_in([:runtime_admission_pending_claim_join], rest)
            |> clear_claim_join_observer_tracking(meta)

          intent = Map.get(state.runtime_admission_intents, meta.target)

          if claim_join_intent_current?(intent, meta) do
            apply_claim_join_classification(state, meta, result)
          else
            # Authentic worker but intent advanced — inert.
            state
          end
        end

      _ ->
        state
    end
  end

  defp handle_runtime_admission_claim_joined(state, _join_ref, _other), do: state

  defp claim_join_result_authentic?(meta, result)
       when is_map(meta) and is_map(result) do
    is_pid(Map.get(meta, :observer_pid)) and
      is_pid(Map.get(meta, :worker_pid)) and
      Map.get(meta, :worker_pid) == Map.get(meta, :observer_pid) and
      Map.get(result, :worker_pid) == Map.get(meta, :observer_pid) and
      Map.get(result, :target) == meta.target and
      Map.get(result, :token) == meta.token and
      Map.get(result, :intent_id) == meta.intent_id and
      Map.get(result, :fingerprint) == meta.fingerprint and
      is_binary(Map.get(meta, :operation_id)) and
      Map.get(result, :operation_id) == meta.operation_id and
      is_atom(Map.get(result, :classification))
  end

  defp claim_join_result_authentic?(_, _), do: false

  defp claim_join_intent_current?(intent, meta) when is_map(intent) and is_map(meta) do
    intent.intent_id == meta.intent_id and
      Map.get(intent, :fingerprint) == meta.fingerprint and
      Map.get(intent, :restore_token) == meta.token and
      Map.get(intent, :operation_id) == Map.get(meta, :operation_id) and
      Map.get(intent, :kind) == :guarded_restore and
      Map.get(intent, :phase) == :outcome_unknown and
      Map.get(intent, :phase) != :terminal and
      Map.get(intent, :phase) != :settling
  end

  defp claim_join_intent_current?(_, _), do: false

  defp handle_runtime_admission_claim_join_timeout(state, join_ref)
       when is_reference(join_ref) do
    state = ensure_runtime_admission_shape(state)
    pending = Map.get(state, :runtime_admission_pending_claim_join, %{})

    case Map.pop(pending, join_ref) do
      {nil, _} ->
        # Stale timeout — inert.
        state

      {meta, rest} when is_map(meta) ->
        state =
          state
          |> put_in([:runtime_admission_pending_claim_join], rest)
          |> clear_claim_join_observer_tracking(meta)

        case Map.get(meta, :observer_pid) do
          pid when is_pid(pid) ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)

          _ ->
            :ok
        end

        retry_or_exhaust_claim_join(state, meta, :observer_timeout)

      _ ->
        state
    end
  end

  defp handle_runtime_admission_claim_join_monitor_down(state, mon, join_ref)
       when is_reference(mon) and is_reference(join_ref) do
    state = ensure_runtime_admission_shape(state)
    join_mons = Map.get(state, :runtime_admission_claim_join_monitors, %{})
    state = put_in(state, [:runtime_admission_claim_join_monitors], Map.delete(join_mons, mon))

    pending = Map.get(state, :runtime_admission_pending_claim_join, %{})

    case Map.get(pending, join_ref) do
      %{mon: ^mon} = meta ->
        # Observer exited before/without a delivered result. Prefer the result
        # message if it races ahead; pure crash converges via bounded timer.
        updated = %{meta | mon: nil, observer_pid: nil, worker_pid: nil}
        put_in(state, [:runtime_admission_pending_claim_join, join_ref], updated)

      _ ->
        # Result or timeout already converged this ref — inert.
        state
    end
  end

  defp clear_claim_join_observer_tracking(state, meta) when is_map(meta) do
    state =
      case Map.get(meta, :timer) do
        timer when is_reference(timer) ->
          _ = Process.cancel_timer(timer)
          state

        _ ->
          state
      end

    case Map.get(meta, :mon) do
      mon when is_reference(mon) ->
        Process.demonitor(mon, [:flush])
        join_mons = Map.get(state, :runtime_admission_claim_join_monitors, %{})
        put_in(state, [:runtime_admission_claim_join_monitors], Map.delete(join_mons, mon))

      _ ->
        state
    end
  end

  defp retry_or_exhaust_claim_join(state, meta, reason) when is_map(meta) do
    attempt = Map.get(meta, :attempt, 0)
    next = attempt + 1
    target = meta.target
    intent = Map.get(state.runtime_admission_intents, target)
    request = claim_join_request_from_meta(meta)

    cond do
      not claim_join_intent_current?(intent, meta) ->
        state

      next >= @max_runtime_admission_claim_join_attempts ->
        state =
          put_claim_join_progress(
            state,
            request,
            :exhausted,
            attempt,
            reason
          )

        # Conservatively blocked — never pre-effect on exhaustion.
        ensure_parked_unknown(state, target, intent)

      true ->
        state = put_claim_join_progress(state, request, :retry, attempt, reason)

        Process.send_after(
          self(),
          {:runtime_admission_claim_join_retry, request, next},
          durable_shell_launch_backoff_ms(attempt)
        )

        state
    end
  end

  defp claim_join_request_from_meta(meta) when is_map(meta) do
    %{
      target: Map.get(meta, :target),
      intent_id: Map.get(meta, :intent_id),
      fingerprint: Map.get(meta, :fingerprint),
      token: Map.get(meta, :token),
      operation_id: Map.get(meta, :operation_id),
      monitored_owner_pid: Map.get(meta, :monitored_owner_pid)
    }
  end

  defp apply_claim_join_classification(state, meta, result)
       when is_map(meta) and is_map(result) do
    target = meta.target
    intent = Map.get(state.runtime_admission_intents, target)
    classification = Map.get(result, :classification)
    branch_fact = Map.get(result, :branch_fact)

    cond do
      not is_map(intent) or intent.intent_id != meta.intent_id ->
        state

      classification == :join_unavailable ->
        retry_or_exhaust_claim_join(state, meta, :join_unavailable)

      classification in [:bound_hold, :outcome_unknown_hold, :claim_mismatch, :occupancy_hold] ->
        # Hold non-idle. Bound → mark durable unknown; occupancy never pre-effect.
        state = delete_claim_join_progress(state, meta)

        state = ensure_parked_unknown(state, target, intent)

        if classification == :bound_hold do
          launch_durable_mark_outcome_unknown(state, intent)
        else
          state
        end

      classification == :minted_pre_effect and branch_fact == :not_running ->
        # TaskStore-auth pre-effect proof: durable settle not_applied then retire.
        state = delete_claim_join_progress(state, meta)

        immediate_finalize_runtime_admission(
          state,
          target,
          intent.intent_id,
          {:commit, {:error, :pre_effect_abort}}
        )

      classification == :minted_pre_effect ->
        # Occupancy / failed observation must not finalize pre-effect.
        state = delete_claim_join_progress(state, meta)

        ensure_parked_unknown(state, target, intent)

      classification == :settled_applied ->
        # Durable already applied without live witness here — keep unknown hold.
        state = delete_claim_join_progress(state, meta)

        ensure_parked_unknown(state, target, intent)

      classification == :settled_other ->
        state = delete_claim_join_progress(state, meta)

        immediate_finalize_runtime_admission(
          state,
          target,
          intent.intent_id,
          {:commit_durable_observed, {:error, :claim_settled_non_applied}}
        )

      classification == :claim_absent ->
        state = delete_claim_join_progress(state, meta)

        immediate_finalize_runtime_admission(
          state,
          target,
          intent.intent_id,
          {:commit_durable_observed, {:error, :owner_down}}
        )

      true ->
        state = delete_claim_join_progress(state, meta)

        ensure_parked_unknown(state, target, intent)
    end
  end

  defp ensure_parked_unknown(state, target, intent) do
    updated = %{
      intent
      | phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: Map.get(intent, :worker_pid),
        retire_barrier: :none,
        effect_handoff?: true
    }

    put_in(state, [:runtime_admission_intents, target], updated)
  end

  # ── Runtime-admission restart reconcile ────────────────────────────

  defp maybe_begin_runtime_admission_reconcile(state) do
    state = ensure_runtime_admission_shape(state)

    cond do
      state.runtime_admission_ready? == true ->
        state

      Map.get(state.runtime_admission_reconcile, :status) in [:admitting, :running] ->
        state

      true ->
        begin_runtime_admission_reconcile(state)
    end
  end

  defp begin_runtime_admission_reconcile(state) do
    state = ensure_runtime_admission_shape(state)
    ref = make_ref()
    store_ref = Map.get(state, :store_ref, @default_name)
    attempts = Map.get(state.runtime_admission_reconcile, :attempts, 0)

    supervisor =
      Map.get(state, :runtime_admission_supervisor, @default_runtime_admission_supervisor)

    task_supervisor = Map.get(state, :task_supervisor, @default_task_supervisor)

    timeout =
      Map.get(
        state,
        :runtime_admission_reconcile_timeout_ms,
        @default_runtime_admission_reconcile_timeout_ms
      )

    timer = Process.send_after(self(), {:runtime_admission_reconcile_timeout, ref}, timeout)

    {launcher_pid, launcher_mon} =
      spawn_monitor(__MODULE__, :runtime_admission_reconcile_launcher, [
        store_ref,
        ref,
        task_supervisor,
        supervisor,
        timeout + 1_000,
        attempts
      ])

    rec = %{
      status: :admitting,
      ref: ref,
      launcher_pid: launcher_pid,
      launcher_mon: launcher_mon,
      worker_pid: nil,
      worker_mon: nil,
      timer: timer,
      attempts: attempts
    }

    put_in(state, [:runtime_admission_reconcile], rec)
  end

  @doc false
  def runtime_admission_reconcile_launcher(
        store_ref,
        ref,
        task_supervisor,
        owner_supervisor,
        begin_wait_ms,
        attempt
      ) do
    case Task.Supervisor.start_child(
           task_supervisor,
           __MODULE__,
           :run_runtime_admission_reconcile_worker,
           [store_ref, ref, owner_supervisor, begin_wait_ms, attempt],
           []
         ) do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        send(store_ref, {:runtime_admission_reconcile_admitted, ref, worker_pid})

      {:ok, worker_pid, _} when is_pid(worker_pid) ->
        send(store_ref, {:runtime_admission_reconcile_admitted, ref, worker_pid})

      {:error, reason} ->
        send(store_ref, {:runtime_admission_reconcile_failed, ref, reason})

      other ->
        send(store_ref, {:runtime_admission_reconcile_failed, ref, other})
    end

    :ok
  rescue
    _ ->
      send(store_ref, {:runtime_admission_reconcile_failed, ref, :launcher_exception})
      :ok
  catch
    :exit, _ ->
      send(store_ref, {:runtime_admission_reconcile_failed, ref, :launcher_exit})
      :ok
  end

  @doc false
  def run_runtime_admission_reconcile_worker(
        store_ref,
        ref,
        owner_supervisor,
        begin_wait_ms,
        attempt
      ) do
    receive do
      {:runtime_admission_reconcile_begin, ^ref} ->
        # I/O outside TaskStore callbacks: live owners + durable restore claims.
        # Success is a closed versioned dual-inventory envelope bound to this
        # attempt/ref/worker — never a bare owner list.
        result =
          case inventory_runtime_admission_owners(owner_supervisor) do
            {:ok, snapshots} ->
              case inventory_runtime_restore_claims() do
                {:ok, claims} ->
                  {:ok,
                   %{
                     v: @runtime_admission_reconcile_result_v,
                     ref: ref,
                     attempt: attempt,
                     worker_pid: self(),
                     owners: snapshots,
                     claims: claims
                   }}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        send(store_ref, {:runtime_admission_reconcile_complete, ref, result})
        :ok
    after
      begin_wait_ms ->
        :ok
    end
  end

  # Fixed production inventory of outstanding restore claims. Runs only in the
  # async reconcile worker — never inside TaskStore.handle_call.
  # Production: every unavailable/malformed durable inventory fails closed
  # (readiness stays false). Never maps authority errors to {:ok, []}.
  defp inventory_runtime_restore_claims do
    # Test hang seam (prod no-op): hold inventory so tests can inject stale results.
    hang_runtime_admission_claim_inventory_if_requested()

    # MIX_ENV=test force-error seam (absent from production call shape defaults).
    if Mix.env() == :test and
         Application.get_env(:arbor_agent, :runtime_admission_test_claim_inventory_force_error) ==
           true do
      {:error, :restore_claim_inventory_unavailable}
    else
      case Arbor.Agent.TemplateAuthorityReconciliationStore.list_outstanding_runtime_restore_claims() do
        {:ok, claims} when is_list(claims) ->
          if Mix.env() == :test and
               Application.get_env(
                 :arbor_agent,
                 :runtime_admission_test_claim_inventory_malformed
               ) == true do
            # Malformed inventory must fail closed at pure merge / readiness.
            {:ok, [%{"claim_phase" => "bound", "target_agent_id" => "agent_malformed_only"}]}
          else
            {:ok, claims}
          end

        {:error, reason} ->
          inventory_runtime_restore_claims_error(reason)

        _ ->
          {:error, :restore_claim_inventory_unavailable}
      end
    end
  rescue
    _ -> {:error, :restore_claim_inventory_unavailable}
  catch
    :exit, _ -> {:error, :restore_claim_inventory_unavailable}
  end

  if Mix.env() == :test do
    # Hold claim inventory so security regressions can inject stale/hot-upgrade
    # reconcile results against a live running attempt. Absent from prod BEAMs
    # as a no-op clause below.
    defp hang_runtime_admission_claim_inventory_if_requested do
      if Application.get_env(
           :arbor_agent,
           :runtime_admission_test_claim_inventory_hang
         ) == true do
        Process.sleep(50)
        hang_runtime_admission_claim_inventory_if_requested()
      else
        :ok
      end
    end

    # Explicit MIX_ENV=test-only bypass — absent from dev/prod BEAMs.
    # Opt-in via Application env; never the default.
    defp inventory_runtime_restore_claims_error(reason)
         when reason in [:authority_not_durable, :authority_unavailable] do
      if Application.get_env(
           :arbor_agent,
           :runtime_admission_empty_claim_inventory_on_authority_error
         ) == true do
        {:ok, []}
      else
        {:error, :restore_claim_inventory_unavailable}
      end
    end

    defp inventory_runtime_restore_claims_error(_reason),
      do: {:error, :restore_claim_inventory_unavailable}
  else
    defp hang_runtime_admission_claim_inventory_if_requested, do: :ok

    defp inventory_runtime_restore_claims_error(_reason),
      do: {:error, :restore_claim_inventory_unavailable}
  end

  defp inventory_runtime_admission_owners(owner_supervisor) do
    case RuntimeAdmissionSupervisor.which_children(owner_supervisor) do
      {:ok, children} ->
        case reduce_owner_inventory_children(children, []) do
          {:ok, snapshots} ->
            # Repair RuntimeAdmissionRegistry from owner snapshots.
            repair_runtime_admission_registry(snapshots)
            {:ok, snapshots}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :inventory_exception}
  catch
    :exit, _ -> {:error, :inventory_exit}
  end

  # Fail closed on any incomplete/unreadable child. Preserve snapshot-claimed
  # owner_pid and attach enumerated child_pid separately so IntentCore can
  # reject mismatch; never overwrite claimed PID before validation.
  defp reduce_owner_inventory_children(children, acc) when is_list(children) do
    result =
      Enum.reduce_while(children, {:ok, acc}, fn
        {_id, child_pid, :worker, _mods}, {:ok, snaps} when is_pid(child_pid) ->
          case IntentOwner.snapshot(child_pid) do
            {:ok, snap} when is_map(snap) ->
              entry = Map.put(snap, :child_pid, child_pid)
              {:cont, {:ok, [entry | snaps]}}

            _ ->
              {:halt, {:error, :incomplete_owner_inventory}}
          end

        {_id, child, _type, _mods}, _acc
        when child in [:undefined, :restarting] or not is_pid(child) ->
          {:halt, {:error, :incomplete_owner_inventory}}

        _other, _acc ->
          {:halt, {:error, :incomplete_owner_inventory}}
      end)

    case result do
      {:ok, snaps} -> {:ok, Enum.reverse(snaps)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repair_runtime_admission_registry(snapshots) when is_list(snapshots) do
    registry = Arbor.Agent.RuntimeAdmissionRegistry

    # Drop stale registry keys not present in live owners.
    live_targets =
      snapshots
      |> Enum.map(& &1.target_agent_id)
      |> MapSet.new()

    try do
      Registry.select(registry, [
        {{{:runtime_admission_owner, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])
      |> Enum.each(fn {target, pid, _val} ->
        if not MapSet.member?(live_targets, target) or not Process.alive?(pid) do
          # Best-effort: cannot unregister other pids; only note absence.
          :ok
        end
      end)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Owners already register themselves; inventory is authoritative for TaskStore rebind.
    :ok
  end

  defp handle_runtime_admission_reconcile_admitted(state, ref, worker_pid) do
    state = ensure_runtime_admission_shape(state)
    rec = state.runtime_admission_reconcile

    if Map.get(rec, :status) == :admitting and Map.get(rec, :ref) == ref do
      cancel_timer_safe(Map.get(rec, :timer))
      launcher_mon = Map.get(rec, :launcher_mon)
      if is_reference(launcher_mon), do: Process.demonitor(launcher_mon, [:flush])

      worker_mon = Process.monitor(worker_pid)
      send(worker_pid, {:runtime_admission_reconcile_begin, ref})

      timeout =
        Map.get(
          state,
          :runtime_admission_reconcile_timeout_ms,
          @default_runtime_admission_reconcile_timeout_ms
        )

      timer = Process.send_after(self(), {:runtime_admission_reconcile_timeout, ref}, timeout)

      put_in(state, [:runtime_admission_reconcile], %{
        rec
        | status: :running,
          launcher_pid: nil,
          launcher_mon: nil,
          worker_pid: worker_pid,
          worker_mon: worker_mon,
          timer: timer
      })
    else
      state
    end
  end

  defp handle_runtime_admission_reconcile_failed(state, ref, _class) do
    state = ensure_runtime_admission_shape(state)
    rec = state.runtime_admission_reconcile

    if Map.get(rec, :ref) == ref and Map.get(rec, :status) in [:admitting, :running] do
      state = cleanup_runtime_admission_reconcile(state, rec)
      schedule_runtime_admission_reconcile_retry(state)
    else
      state
    end
  end

  defp handle_runtime_admission_reconcile_timeout(state, ref) do
    state = ensure_runtime_admission_shape(state)
    rec = state.runtime_admission_reconcile

    if Map.get(rec, :ref) == ref and Map.get(rec, :status) in [:admitting, :running] do
      worker_pid = Map.get(rec, :worker_pid)
      if is_pid(worker_pid) and Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
      launcher_pid = Map.get(rec, :launcher_pid)

      if is_pid(launcher_pid) and Process.alive?(launcher_pid),
        do: Process.exit(launcher_pid, :kill)

      state = cleanup_runtime_admission_reconcile(state, rec)
      schedule_runtime_admission_reconcile_retry(state)
    else
      state
    end
  end

  defp handle_runtime_admission_reconcile_complete(state, ref, result) do
    state = ensure_runtime_admission_shape(state)
    rec = state.runtime_admission_reconcile

    # Bind to the exact in-flight attempt (ref + running worker) before cleanup
    # so identity fields on the result can be checked against rec.
    if Map.get(rec, :ref) == ref and Map.get(rec, :status) == :running do
      case normalize_runtime_admission_reconcile_result(result, rec) do
        {:ok, snapshots, claims} ->
          state = cleanup_runtime_admission_reconcile(state, rec)

          case IntentCore.merge_restore_claim_inventory(%{}, snapshots, claims) do
            {:ok, intents} ->
              by_id =
                Enum.reduce(intents, %{}, fn {target, intent}, acc ->
                  Map.put(acc, intent.intent_id, target)
                end)

              # Re-monitor exact owner and worker identities. Dead PIDs produce
              # immediate DOWN; liveness is never used as authority. Blocking
              # unknown intents (no owner) skip owner monitors.
              {owner_mons, worker_mons} =
                Enum.reduce(intents, {%{}, %{}}, fn {_target, intent}, {owners, workers} ->
                  owners =
                    if is_pid(intent.owner_pid) do
                      owner_mon = Process.monitor(intent.owner_pid)

                      Map.put(
                        owners,
                        owner_mon,
                        {intent.intent_id, intent.target_agent_id, intent.owner_pid}
                      )
                    else
                      owners
                    end

                  workers =
                    if is_pid(intent.worker_pid) do
                      worker_mon = Process.monitor(intent.worker_pid)

                      Map.put(
                        workers,
                        worker_mon,
                        {intent.intent_id, intent.target_agent_id, intent.worker_pid}
                      )
                    else
                      workers
                    end

                  {owners, workers}
                end)

              %{
                state
                | runtime_admission_intents: intents,
                  runtime_admission_by_id: by_id,
                  runtime_admission_owner_monitors: owner_mons,
                  runtime_admission_worker_monitors: worker_mons,
                  runtime_admission_ready?: true,
                  runtime_admission_reconcile: %{
                    status: :done,
                    last_error: nil
                  }
              }

            {:error, reason}
            when reason in [
                   :invalid_snapshot,
                   :duplicate_target,
                   :duplicate_intent_id,
                   :inventory_overflow,
                   :invalid_inventory,
                   :restore_claim_inventory_unavailable
                 ] ->
              # Fail closed: do not mark ready; surface bounded error for diagnostics.
              state =
                put_in(state, [:runtime_admission_reconcile], %{
                  status: :pending,
                  attempts: Map.get(rec, :attempts, 0),
                  last_error: reason
                })

              schedule_runtime_admission_reconcile_retry(state)
          end

        :error ->
          # Owner-only / unknown-version / identity mismatch / unclosed schema.
          state = cleanup_runtime_admission_reconcile(state, rec)

          state =
            put_in(state, [:runtime_admission_reconcile], %{
              status: :pending,
              attempts: Map.get(rec, :attempts, 0),
              last_error: :invalid_reconcile_result
            })

          schedule_runtime_admission_reconcile_retry(state)
      end
    else
      # Stale complete for a prior attempt/ref — ignore without mutating readiness.
      state
    end
  end

  # Dual-inventory only. Rejects legacy owner-only {:ok, owners} and any result
  # that is not the closed versioned schema bound to the current attempt/ref/worker.
  defp normalize_runtime_admission_reconcile_result({:ok, map}, rec)
       when is_map(map) and is_map(rec) do
    with :ok <- require_closed_runtime_admission_reconcile_map(map),
         :ok <- match_runtime_admission_reconcile_identity(map, rec),
         owners when is_list(owners) <- Map.fetch!(map, :owners),
         claims when is_list(claims) <- Map.fetch!(map, :claims) do
      {:ok, owners, claims}
    else
      _ -> :error
    end
  end

  # Explicit fail-closed: hot-upgrade / stale workers that only inventory owners
  # must not synthesize claims=[] and mark ready.
  defp normalize_runtime_admission_reconcile_result({:ok, owners}, _rec)
       when is_list(owners),
       do: :error

  defp normalize_runtime_admission_reconcile_result(_, _), do: :error

  defp require_closed_runtime_admission_reconcile_map(map) when is_map(map) do
    keys = map |> Map.keys() |> MapSet.new()

    if MapSet.equal?(keys, @runtime_admission_reconcile_result_keys) and
         Map.get(map, :v) == @runtime_admission_reconcile_result_v do
      :ok
    else
      :error
    end
  end

  defp require_closed_runtime_admission_reconcile_map(_), do: :error

  defp match_runtime_admission_reconcile_identity(map, rec)
       when is_map(map) and is_map(rec) do
    expected_ref = Map.get(rec, :ref)
    expected_attempt = Map.get(rec, :attempts, 0)
    expected_worker = Map.get(rec, :worker_pid)

    if is_reference(expected_ref) and is_pid(expected_worker) and
         Map.get(map, :ref) == expected_ref and
         Map.get(map, :attempt) == expected_attempt and
         Map.get(map, :worker_pid) == expected_worker do
      :ok
    else
      :error
    end
  end

  defp match_runtime_admission_reconcile_identity(_, _), do: :error

  defp handle_runtime_admission_reconcile_launcher_down(state, rec) do
    if Map.get(rec, :status) == :admitting do
      state = cleanup_runtime_admission_reconcile(state, rec)
      schedule_runtime_admission_reconcile_retry(state)
    else
      state
    end
  end

  defp handle_runtime_admission_reconcile_worker_down(state, rec) do
    if Map.get(rec, :status) == :running do
      state = cleanup_runtime_admission_reconcile(state, rec)
      schedule_runtime_admission_reconcile_retry(state)
    else
      state
    end
  end

  defp cleanup_runtime_admission_reconcile(state, rec) do
    cancel_timer_safe(Map.get(rec, :timer))

    if is_reference(Map.get(rec, :launcher_mon)),
      do: Process.demonitor(rec.launcher_mon, [:flush])

    if is_reference(Map.get(rec, :worker_mon)), do: Process.demonitor(rec.worker_mon, [:flush])

    put_in(state, [:runtime_admission_reconcile], %{
      status: :pending,
      attempts: Map.get(rec, :attempts, 0)
    })
  end

  defp schedule_runtime_admission_reconcile_retry(state) do
    state = ensure_runtime_admission_shape(state)

    if state.runtime_admission_ready? == true do
      state
    else
      attempts = Map.get(state.runtime_admission_reconcile, :attempts, 0) + 1
      delay = min(5_000, 200 * Integer.pow(2, max(attempts - 1, 0)))
      Process.send_after(self(), :retry_runtime_admission_reconcile_msg, delay)
      put_in(state, [:runtime_admission_reconcile, :attempts], attempts)
    end
  end

  defp find_runtime_admission_reconcile_monitor(state, ref) when is_reference(ref) do
    rec = Map.get(state, :runtime_admission_reconcile, %{status: :pending})
    launcher_mon = Map.get(rec, :launcher_mon)
    worker_mon = Map.get(rec, :worker_mon)

    cond do
      is_reference(launcher_mon) and launcher_mon == ref and rec.status == :admitting ->
        {:launcher, rec}

      is_reference(worker_mon) and worker_mon == ref and rec.status == :running ->
        {:worker, rec}

      true ->
        :error
    end
  end

  # Bounded valid UTF-8 identifiers before regex or map insertion. Matches the
  # operation core bounds for target_agent_id and operation_id exactly.
  defp validate_fence_target(target) when is_binary(target) do
    cond do
      byte_size(target) > @max_fence_agent_id_bytes -> {:error, :invalid_target_agent_id}
      not String.valid?(target) -> {:error, :invalid_target_agent_id}
      not Regex.match?(@fence_agent_id_re, target) -> {:error, :invalid_target_agent_id}
      true -> {:ok, target}
    end
  end

  defp validate_fence_target(_), do: {:error, :invalid_target_agent_id}

  defp validate_reservation_activation_target(agent_id, reservation_target) do
    with {:ok, target} <- validate_fence_target(agent_id),
         {:ok, ^target} <- validate_fence_target(reservation_target) do
      {:ok, target}
    else
      _ -> {:error, :reservation_target_mismatch}
    end
  end

  defp validate_fence_operation_id(operation_id) when is_binary(operation_id) do
    cond do
      byte_size(operation_id) > @max_fence_operation_id_bytes ->
        {:error, :invalid_operation_id}

      not String.valid?(operation_id) ->
        {:error, :invalid_operation_id}

      not Regex.match?(@fence_operation_id_re, operation_id) ->
        {:error, :invalid_operation_id}

      true ->
        {:ok, operation_id}
    end
  end

  defp validate_fence_operation_id(_), do: {:error, :invalid_operation_id}

  # Barrier counts are bounded integers ONLY: active includes running and
  # waiting_approval tasks plus non-terminal runtime-admission intents; reserved
  # counts target-bound reservations. Never task ids, tokens, PIDs, capability
  # ids, or records.
  #
  # Callers (install/remove) must only invoke this after dual readiness so
  # non-idle runtime-admission intents from claim inventory are visible.
  defp barrier_counts(state, target) do
    state = ensure_runtime_admission_shape(state)

    task_active =
      state
      |> Map.get(:tasks, %{})
      |> Enum.count(fn {_id, rec} ->
        Map.get(rec, :agent_id) == target and
          Map.get(rec, :state) in [:running, :waiting_approval]
      end)

    intent_active =
      if IntentCore.non_idle?(Map.get(state, :runtime_admission_intents, %{}), target),
        do: 1,
        else: 0

    active_count = task_active + intent_active

    reserved_count =
      state
      |> Map.get(:reservations, %{})
      |> Enum.count(fn {_id, res} -> Map.get(res, :target_agent_id) == target end)

    %{active_count: active_count, reserved_count: reserved_count}
  end

  defp find_fence_seed_monitor(state, ref) when is_reference(ref) do
    seed = Map.get(state, :fence_seed, %{status: :pending})
    launcher_mon = Map.get(seed, :launcher_mon)
    worker_mon = Map.get(seed, :worker_mon)

    cond do
      is_reference(launcher_mon) and launcher_mon == ref and seed.status == :admitting ->
        {:launcher, seed}

      is_reference(worker_mon) and worker_mon == ref and seed.status == :running ->
        {:worker, seed}

      true ->
        :error
    end
  end

  defp maybe_begin_fence_seed(state) do
    state = ensure_fence_shape(state)

    cond do
      state.target_fence_ready? == true ->
        state

      Map.get(state.fence_seed, :status) in [:admitting, :running] ->
        state

      true ->
        begin_fence_seed(state)
    end
  end

  defp begin_fence_seed(state) do
    state = ensure_fence_shape(state)
    seed_ref = make_ref()

    admit_timeout =
      Map.get(state, :fence_seed_admit_timeout_ms, @default_fence_seed_admit_timeout_ms)

    begin_wait_ms = admit_timeout + 1_000

    supervisor =
      Map.get(
        state,
        :cleanup_supervisor,
        Map.get(state, :task_supervisor, @default_task_supervisor)
      )

    facade = Map.get(state, :template_authority_fence_facade, @default_fence_seed_facade)

    admit_timer =
      Process.send_after(self(), {:fence_seed_admit_timeout, seed_ref}, admit_timeout)

    store_pid = self()

    {launcher_pid, launcher_mon} =
      spawn_monitor(__MODULE__, :fence_seed_launcher, [
        store_pid,
        seed_ref,
        supervisor,
        facade,
        begin_wait_ms
      ])

    attempts = Map.get(state.fence_seed, :attempts, 0)

    seed = %{
      status: :admitting,
      seed_ref: seed_ref,
      attempts: attempts,
      launcher_pid: launcher_pid,
      launcher_mon: launcher_mon,
      worker_pid: nil,
      worker_mon: nil,
      admit_timer: admit_timer,
      worker_timer: nil
    }

    put_in(state, [:fence_seed], seed)
  end

  @doc false
  def fence_seed_launcher(store_pid, seed_ref, supervisor, facade, begin_wait_ms)
      when is_pid(store_pid) and is_reference(seed_ref) and is_integer(begin_wait_ms) and
             begin_wait_ms > 0 do
    case Task.Supervisor.start_child(
           supervisor,
           __MODULE__,
           :run_fence_seed_worker,
           [store_pid, seed_ref, facade, begin_wait_ms],
           []
         ) do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        send(store_pid, {:fence_seed_admitted, seed_ref, worker_pid})

      {:ok, worker_pid, _} when is_pid(worker_pid) ->
        send(store_pid, {:fence_seed_admitted, seed_ref, worker_pid})

      {:error, reason} ->
        send(store_pid, {:fence_seed_failed, seed_ref, classify_admission_error(reason)})

      other ->
        send(store_pid, {:fence_seed_failed, seed_ref, classify_admission_error(other)})
    end

    :ok
  rescue
    _ ->
      send(store_pid, {:fence_seed_failed, seed_ref, :launcher_exception})
      :ok
  catch
    :exit, _ ->
      send(store_pid, {:fence_seed_failed, seed_ref, :launcher_exit})
      :ok

    _, _ ->
      send(store_pid, {:fence_seed_failed, seed_ref, :launcher_error})
      :ok
  end

  @doc false
  # The durable inventory read (list_outstanding/0) happens ONLY here, inside
  # the supervised worker process — never inside a TaskStore GenServer callback.
  def run_fence_seed_worker(store_pid, seed_ref, facade, begin_wait_ms)
      when is_pid(store_pid) and is_reference(seed_ref) and is_integer(begin_wait_ms) and
             begin_wait_ms > 0 do
    receive do
      {:fence_seed_begin, ^seed_ref} ->
        result =
          try do
            facade.list_outstanding()
          rescue
            _ -> {:error, :seed_exception}
          catch
            :exit, _ -> {:error, :seed_exit}
            _, _ -> {:error, :seed_error}
          end

        send(store_pid, {:fence_seed_complete, seed_ref, result})
        :ok
    after
      begin_wait_ms ->
        # Never admitted (launcher killed / superseded): no I/O performed.
        :ok
    end
  end

  # All fence-seed handlers read fields with Map.get: a stale completion /
  # failure / timeout / DOWN message may arrive AFTER cleanup_fence_seed/2 has
  # reset :fence_seed to a minimal %{status: :pending, attempts: n} shape, so dot
  # access on :seed_ref / timers / monitors / pids would otherwise raise.
  defp handle_fence_seed_admitted(state, seed_ref, worker_pid) do
    state = ensure_fence_shape(state)
    seed = state.fence_seed

    if Map.get(seed, :status) == :admitting and Map.get(seed, :seed_ref) == seed_ref do
      cancel_timer_safe(Map.get(seed, :admit_timer))

      launcher_mon = Map.get(seed, :launcher_mon)
      if is_reference(launcher_mon), do: Process.demonitor(launcher_mon, [:flush])

      worker_timeout =
        Map.get(state, :fence_seed_worker_timeout_ms, @default_fence_seed_worker_timeout_ms)

      worker_timer =
        Process.send_after(self(), {:fence_seed_worker_timeout, seed_ref}, worker_timeout)

      worker_mon = Process.monitor(worker_pid)
      send(worker_pid, {:fence_seed_begin, seed_ref})

      seed = %{
        seed
        | status: :running,
          launcher_pid: nil,
          launcher_mon: nil,
          admit_timer: nil,
          worker_pid: worker_pid,
          worker_mon: worker_mon,
          worker_timer: worker_timer
      }

      put_in(state, [:fence_seed], seed)
    else
      state
    end
  end

  defp handle_fence_seed_failed(state, seed_ref, class) do
    state = ensure_fence_shape(state)
    seed = state.fence_seed

    if Map.get(seed, :seed_ref) == seed_ref and Map.get(seed, :status) in [:admitting, :running] do
      state = cleanup_fence_seed(state, seed)
      schedule_fence_seed_retry(state, class)
    else
      state
    end
  end

  defp handle_fence_seed_admit_timeout(state, seed_ref) do
    state = ensure_fence_shape(state)
    seed = state.fence_seed

    if Map.get(seed, :seed_ref) == seed_ref and Map.get(seed, :status) == :admitting do
      launcher_pid = Map.get(seed, :launcher_pid)

      if is_pid(launcher_pid) and Process.alive?(launcher_pid) do
        Process.exit(launcher_pid, :kill)
      end

      state = cleanup_fence_seed(state, seed)
      schedule_fence_seed_retry(state, :admit_timeout)
    else
      state
    end
  end

  defp handle_fence_seed_worker_timeout(state, seed_ref) do
    state = ensure_fence_shape(state)
    seed = state.fence_seed

    if Map.get(seed, :seed_ref) == seed_ref and Map.get(seed, :status) == :running do
      worker_pid = Map.get(seed, :worker_pid)

      if is_pid(worker_pid) and Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end

      state = cleanup_fence_seed(state, seed)
      schedule_fence_seed_retry(state, :worker_timeout)
    else
      state
    end
  end

  defp handle_fence_seed_complete(state, seed_ref, result) do
    state = ensure_fence_shape(state)
    seed = state.fence_seed

    if Map.get(seed, :seed_ref) == seed_ref and Map.get(seed, :status) == :running do
      state = cleanup_fence_seed(state, seed)
      apply_fence_seed_result(state, result)
    else
      state
    end
  end

  defp handle_fence_seed_launcher_down(state, seed, _reason) do
    if Map.get(seed, :status) == :admitting do
      state = cleanup_fence_seed(state, seed)
      schedule_fence_seed_retry(state, :launcher_down)
    else
      state
    end
  end

  defp handle_fence_seed_worker_down(state, seed, _reason) do
    if Map.get(seed, :status) == :running do
      state = cleanup_fence_seed(state, seed)
      schedule_fence_seed_retry(state, :worker_down)
    else
      state
    end
  end

  defp cleanup_fence_seed(state, seed) do
    cancel_timer_safe(Map.get(seed, :admit_timer))
    cancel_timer_safe(Map.get(seed, :worker_timer))

    launcher_mon = Map.get(seed, :launcher_mon)
    if is_reference(launcher_mon), do: Process.demonitor(launcher_mon, [:flush])

    worker_mon = Map.get(seed, :worker_mon)
    if is_reference(worker_mon), do: Process.demonitor(worker_mon, [:flush])

    put_in(state, [:fence_seed], %{status: :pending, attempts: Map.get(seed, :attempts, 0)})
  end

  # Validate the COMPLETE seed result before replacing the in-memory fence map.
  # Any malformed list, malformed ids, duplicate target, conflicting operation,
  # backend error, worker exit, or timeout keeps readiness false.
  defp apply_fence_seed_result(state, result) do
    case validate_fence_seed(result) do
      {:ok, fence_map} ->
        %{state | target_fences: fence_map, target_fence_ready?: true}

      {:error, _reason} ->
        schedule_fence_seed_retry(state, :seed_invalid)
    end
  end

  defp validate_fence_seed(result) do
    case require_seed_list(result) do
      {:ok, list} -> build_fence_map(list)
      {:error, _reason} = error -> error
    end
  end

  defp require_seed_list({:ok, list}) when is_list(list), do: {:ok, list}
  defp require_seed_list({:ok, _not_list}), do: {:error, :invalid_record}
  defp require_seed_list({:error, _reason}), do: {:error, :backend_unavailable}
  defp require_seed_list(_other), do: {:error, :backend_unavailable}

  defp build_fence_map(list) do
    Enum.reduce_while(list, {:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, entry} <- require_seed_map(entry),
           target when is_binary(target) <- Map.get(entry, "target_agent_id"),
           operation_id when is_binary(operation_id) <- Map.get(entry, "operation_id"),
           {:ok, target} <- validate_fence_target(target),
           {:ok, operation_id} <- validate_fence_operation_id(operation_id) do
        if Map.has_key?(acc, target) do
          {:halt, {:error, :invalid_record}}
        else
          {:cont, {:ok, Map.put(acc, target, operation_id)}}
        end
      else
        _ -> {:halt, {:error, :invalid_record}}
      end
    end)
  end

  defp require_seed_map(value) when is_map(value), do: {:ok, value}
  defp require_seed_map(_), do: {:error, :invalid_record}

  defp schedule_fence_seed_retry(state, _class) do
    state = ensure_fence_shape(state)

    if state.target_fence_ready? == true do
      state
    else
      attempts = Map.get(state.fence_seed, :attempts, 0) + 1
      delay = fence_seed_retry_delay(state, attempts)
      Process.send_after(self(), :retry_fence_seed_msg, delay)
      put_in(state, [:fence_seed, :attempts], attempts)
    end
  end

  defp fence_seed_retry_delay(state, attempt_index) when is_integer(attempt_index) do
    base = Map.get(state, :recovery_retry_base_ms, @default_recovery_retry_base_ms)
    max_delay = Map.get(state, :recovery_retry_max_ms, @default_recovery_retry_max_ms)
    min(max_delay, base * Integer.pow(2, max(attempt_index, 0)))
  end

  defp validate_task_id_generator!(nil), do: nil
  defp validate_task_id_generator!(fun) when is_function(fun, 0), do: fun

  defp validate_task_id_generator!(invalid) do
    raise ArgumentError,
          "task_id_generator must be nil or an arity-0 function, got: #{inspect(invalid)}"
  end

  defp cancel_timer_safe(nil), do: :ok

  defp cancel_timer_safe(timer_ref) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    # Non-blocking flush of an already-delivered timeout for this exact message
    # is handled by status gates on the attempt; cancel is best-effort.
    :ok
  end

  defp cancel_timer_safe(_), do: :ok

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
    |> maybe_put_scalar_id(:principal_id, descriptor_get(descriptor, :principal_id))
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
      principal_id: Map.get(descriptor, :principal_id),
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
  # lack :confirmation_retries / :queued_confirmations / :replay_counts (and
  # in older revisions, :accepted_control_ids / :control_retries / :controls).
  # The first post-upgrade delivery/confirmation/terminal-reconciliation work
  # would crash on the missing keys (KeyError / BadMapError). This
  # materializes the maps with empty defaults so FIFO and budgets are not
  # weakened, and terminalizes any legacy accepted queued controls as
  # delivery_unconfirmed with a bounded explicit diagnostic so they cannot
  # block later controls indefinitely or manufacture a delivery ACK.
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
      |> Map.put_new(:queued_confirmations, %{})
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
    |> update_in([:tasks, task_id, :queued_confirmations], &Map.put(&1, control_id, 0))
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
  #
  # Two independent, separately-tracked counters gate this cycle:
  #   * `queued_confirmations` — count of explicit still-queued observations
  #     (`{:ok, :queued, mode}`). Authoritative, not an error; only drives
  #     backoff delay and never terminalizes the control.
  #   * `confirmation_retries` — count of genuine operational ambiguity
  #     (`{:confirm_deferred, _}`: callback exception/exit/timeout or any
  #     other unrecognized result). Bounded by `max_steering_confirmations`;
  #     exhausting it terminalizes as `"delivery_unconfirmed"`.
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

  # An explicit `{:ok, :queued, mode}` during confirmation is an authoritative
  # in-flight signal from the executor, not an operational failure: a managed
  # ACP control can legitimately stay queued for many minutes while the
  # same-session provider prompt runs. It must never spend the bounded
  # `max_steering_confirmations` operational-failure budget (see
  # `defer_confirmation/4`) and must never terminalize on its own — only a
  # real delivery-negative result, a confirmation error, or the task itself
  # reaching a terminal state can end it. Polling continues indefinitely at
  # the same capped exponential backoff schedule used for operational
  # retries, tracked in a separate counter (`queued_confirmations`) so
  # repeated still-queued observations cannot exhaust or interact with the
  # operational-failure budget.
  defp schedule_next_confirmation(state, task_id, control_id) do
    record = Map.fetch!(state.tasks, task_id)
    attempts = Map.get(record.queued_confirmations, control_id, 0) + 1

    state =
      update_in(
        state,
        [:tasks, task_id, :queued_confirmations],
        &Map.put(&1, control_id, attempts)
      )

    schedule_confirmation(state, task_id, control_id, attempts)
  end

  # Genuine operational ambiguity during confirmation (callback exception,
  # exit, timeout, or any other unrecognized result — never an explicit
  # still-queued observation, see `schedule_next_confirmation/3`). Bounded by
  # `max_steering_confirmations` via `confirmation_retries` so a control stuck
  # in a real error loop still terminalizes.
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
  # we must not create a duplicate timer (which would double-poll the same
  # control and create unbounded mailbox pressure).
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
         %{context_mode: :json_clean} = record,
         runner_result,
         state
       ) do
    module = Map.get(record, :executor)

    cond do
      Map.get(record, :terminal_finalized, false) ->
        record

      record.state == :done and legacy_finalizer?(module) and all_terminal_finalizer?(module) and
          registered_non_success_outcome?(runner_result) ->
        finalize_all_terminal(record, {:runner_result, runner_result}, state, module)

      record.state == :done and legacy_finalizer?(module) and all_terminal_finalizer?(module) ->
        finalize_legacy_then_all_terminal(record, runner_result, state, module)

      all_terminal_finalizer?(module) ->
        finalize_all_terminal(record, {:runner_result, runner_result}, state, module)

      record.state == :done and legacy_finalizer?(module) ->
        finalize_configured_task(record, runner_result, state, module)

      true ->
        record
    end
  end

  defp maybe_finalize_task_result(record, _runner_result, _state), do: record

  defp maybe_finalize_terminal(%{context_mode: :json_clean} = record, terminal, state) do
    module = Map.get(record, :executor)

    if not Map.get(record, :terminal_finalized, false) and all_terminal_finalizer?(module) do
      finalize_all_terminal(record, terminal, state, module)
    else
      record
    end
  end

  defp maybe_finalize_terminal(record, _terminal, _state), do: record

  defp all_terminal_finalizer?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :finalize_terminal_task, 4)
  end

  defp legacy_finalizer?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :finalize_task, 4)
  end

  defp registered_non_success_outcome?(runner_result) do
    with {:ok, outcome} <- TaskArtifacts.extract_outcome(runner_result),
         {:ok, registered} <- TaskOutcome.validate_registered(outcome) do
      registered.disposition != "succeeded"
    else
      _failure -> false
    end
  end

  defp finalize_legacy_then_all_terminal(record, runner_result, state, module) do
    finalized_record = finalize_configured_task(record, runner_result, state, module)

    if finalized_record.state == :done do
      case finalized_raw_result(finalized_record) do
        {:ok, finalized_result} ->
          finalize_all_terminal(
            finalized_record,
            {:runner_result, {:ok, finalized_result}},
            state,
            module
          )

        {:error, reason} ->
          failed_record = finalization_failed(finalized_record, reason)

          acknowledge_legacy_finalization_failure(
            record,
            failed_record,
            runner_result,
            state,
            module
          )
      end
    else
      acknowledge_legacy_finalization_failure(
        record,
        finalized_record,
        runner_result,
        state,
        module
      )
    end
  end

  defp acknowledge_legacy_finalization_failure(
         original_record,
         failed_record,
         runner_result,
         state,
         module
       ) do
    original_envelope = terminal_envelope(original_record, {:runner_result, runner_result})
    {:ok, failed_envelope} = TaskTerminalEnvelope.finalization_failed(original_envelope)
    acknowledge_all_terminal(failed_record, failed_envelope, state, module)
  end

  defp finalize_all_terminal(record, terminal, state, module) do
    envelope = terminal_envelope(record, terminal)
    acknowledge_all_terminal(record, envelope, state, module)
  end

  defp acknowledge_all_terminal(record, envelope, state, module) do
    record = put_terminal_envelope(record, envelope)

    timeout =
      Map.get(
        state,
        :executor_finalization_timeout_ms,
        Config.executor_finalization_timeout_ms()
      )

    callback_result =
      call_executor_callback(
        state,
        fn ->
          module.finalize_terminal_task(
            record.agent_id,
            envelope,
            record.controls,
            record.context
          )
        end,
        timeout
      )

    case callback_result do
      :ok ->
        Map.put(record, :terminal_finalized, true)

      _failure ->
        failed_envelope = finalization_failure_envelope(envelope)

        record
        |> put_terminal_envelope(failed_envelope)
        |> Map.merge(%{
          state: :failed,
          current_step: "failed",
          waiting_on: nil,
          error: :task_finalization_failed,
          terminal_finalized: true
        })
    end
  end

  defp finalization_failure_envelope(
         %{"outcome" => %{"code" => "task_finalization_failed"}} = envelope
       ),
       do: envelope

  defp finalization_failure_envelope(envelope) do
    {:ok, failed_envelope} = TaskTerminalEnvelope.finalization_failed(envelope)
    failed_envelope
  end

  defp terminal_envelope(record, {:runner_result, {:ok, result}}) do
    with {:ok, clean_result} <- canonicalize_and_roundtrip(result),
         {:ok, outcome} <- TaskArtifacts.extract_outcome(clean_result),
         {:ok, envelope} <-
           TaskTerminalEnvelope.preserve(
             outcome,
             terminal_state(record),
             %{"kind" => "executor_result", "result" => clean_result}
           ) do
      envelope
    else
      _failure -> invalid_terminal_envelope(record, result)
    end
  end

  defp terminal_envelope(record, {:runner_result, {:error, {:pipeline_error, detail}}}) do
    with {:ok, clean_detail} <- canonicalize_and_roundtrip(detail),
         {:ok, outcome} <- TaskArtifacts.extract_outcome(clean_detail),
         {:ok, envelope} <-
           TaskTerminalEnvelope.preserve(
             outcome,
             terminal_state(record),
             %{"kind" => "pipeline_failure", "result" => clean_detail}
           ) do
      envelope
    else
      _failure -> invalid_terminal_envelope(record, detail)
    end
  end

  defp terminal_envelope(
         record,
         {:runner_result, {:error, {:coding_execution_state_drift, report}}}
       ) do
    with {:ok, canonical_report} <- canonical_readiness_report(report),
         optional_outcome_attrs = readiness_outcome_attrs(canonical_report),
         {:ok, envelope} <-
           TaskTerminalEnvelope.from_code(
             "coding_execution_state_drift",
             terminal_state(record),
             %{
               "kind" => "coding_execution_state_drift",
               "result" => canonical_report
             },
             optional_outcome_attrs
           ) do
      envelope
    else
      _failure -> invalid_terminal_envelope(record, nil)
    end
  end

  defp terminal_envelope(
         record,
         {:runner_result, {:error, {:coding_admission_failed, detail}}}
       ) do
    with {:ok, canonical_detail} <- canonical_coding_admission_failure(detail),
         {:ok, envelope} <-
           TaskTerminalEnvelope.preserve(
             canonical_detail["outcome"],
             terminal_state(record),
             %{"kind" => "coding_admission_failure", "result" => canonical_detail}
           ) do
      envelope
    else
      _failure -> invalid_terminal_envelope(record, nil)
    end
  end

  defp terminal_envelope(record, {:runner_result, {:ok, :pending_approval, approval_id}}),
    do: approval_owner_terminated_envelope(record, approval_id)

  defp terminal_envelope(
         record,
         {:runner_result, {:error, {:pending_approval, approval_id}}}
       ),
       do: approval_owner_terminated_envelope(record, approval_id)

  defp terminal_envelope(record, {:runner_result, {:error, _raw_error}}),
    do: lifecycle_envelope!("task_runner_failed", record, %{"kind" => "task_runner_failed"})

  defp terminal_envelope(record, {:runner_result, _malformed}),
    do: invalid_terminal_envelope(record, nil)

  defp terminal_envelope(record, :task_cancelled),
    do: lifecycle_envelope!("task_cancelled", record, %{"kind" => "task_cancelled"})

  defp terminal_envelope(record, :task_owner_died),
    do: lifecycle_envelope!("task_owner_died", record, %{"kind" => "task_owner_died"})

  defp approval_owner_terminated_envelope(record, approval_id) when is_binary(approval_id) do
    case TaskTerminalEnvelope.from_code(
           "approval_owner_terminated",
           terminal_state(record),
           %{
             "kind" => "approval_owner_terminated",
             "approval_id" => approval_id
           }
         ) do
      {:ok, envelope} -> envelope
      {:error, _reason} -> invalid_terminal_envelope(record, nil)
    end
  end

  defp approval_owner_terminated_envelope(record, _approval_id),
    do: invalid_terminal_envelope(record, nil)

  defp canonical_readiness_report(report) when is_map(report) and not is_struct(report) do
    with {:ok, roundtripped} <- canonicalize_and_roundtrip(report),
         {:ok, normalized} <- ReadinessReport.normalize(roundtripped),
         true <- normalized == roundtripped do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_readiness_report}
    end
  end

  defp canonical_readiness_report(_report), do: {:error, :invalid_readiness_report}

  defp canonical_coding_admission_failure(detail) when is_map(detail) and not is_struct(detail) do
    with {:ok, canonical} <- AdmissionFailure.normalize(detail),
         true <- detail == canonical,
         {:ok, ^canonical} <- canonicalize_and_roundtrip(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_coding_admission_failure}
    end
  end

  defp canonical_coding_admission_failure(_detail),
    do: {:error, :invalid_coding_admission_failure}

  defp readiness_outcome_attrs(%{"diagnostics" => diagnostics}) do
    diagnostic_refs =
      diagnostics
      |> Enum.map(&Map.get(&1, "evidence_ref"))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case diagnostic_refs do
      [evidence_ref | _rest] ->
        %{
          "diagnostic_refs" => diagnostic_refs,
          "evidence_ref" => evidence_ref
        }

      [] ->
        %{}
    end
  end

  defp invalid_terminal_envelope(_record, result) do
    evidence =
      case canonicalize_and_roundtrip(result) do
        {:ok, clean} -> %{"kind" => "invalid_terminal_evidence", "result" => clean}
        {:error, _reason} -> %{"kind" => "invalid_terminal_evidence"}
      end

    case TaskTerminalEnvelope.from_code(
           "invalid_terminal_evidence",
           "failed",
           evidence
         ) do
      {:ok, envelope} ->
        envelope

      {:error, _reason} ->
        {:ok, envelope} =
          TaskTerminalEnvelope.from_code(
            "invalid_terminal_evidence",
            "failed",
            %{"kind" => "invalid_terminal_evidence"}
          )

        envelope
    end
  end

  defp lifecycle_envelope!(code, record, evidence) do
    {:ok, envelope} = TaskTerminalEnvelope.from_code(code, terminal_state(record), evidence)
    envelope
  end

  defp terminal_state(%{state: state}) when state in [:done, :failed, :cancelled],
    do: Atom.to_string(state)

  defp put_terminal_envelope(record, envelope) do
    record = Map.put(record, :terminal_envelope, envelope)

    if envelope["outcome"]["code"] == "invalid_terminal_evidence" do
      Map.merge(record, %{
        state: :failed,
        current_step: "failed",
        waiting_on: nil,
        error: :invalid_terminal_evidence
      })
    else
      record
    end
  end

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

  defp adoption_status_reply(state, task_id, destination_ref) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        adoption_status_for_record(
          record,
          Map.get(state.adoptions, task_id),
          destination_ref
        )

      :error ->
        {:error, :not_found}
    end
  end

  defp adoption_status_for_record(record, operation, destination_ref) do
    settled_destination = Map.get(record, :adoption_destination_ref)
    failed_reason = matching_adoption_failure(record, destination_ref)

    cond do
      settled_destination == destination_ref ->
        {:ok, {:settled, record.result}}

      is_binary(settled_destination) ->
        {:error, :task_already_adopted}

      is_map(operation) and get_in(operation, [:request, "destination_ref"]) == destination_ref ->
        {:ok, :pending}

      is_map(operation) ->
        {:error, :task_adoption_in_progress}

      is_binary(failed_reason) ->
        {:ok, {:failed, failed_reason}}

      true ->
        {:ok, :not_started}
    end
  end

  defp matching_adoption_failure(record, destination_ref) do
    with %{request: request, result_fingerprint: result_fingerprint, reason: reason}
         when is_binary(reason) <- Map.get(record, :adoption_last_error),
         {:ok, expected_request} <- normalize_adoption_request(destination_ref),
         true <- request == expected_request,
         {:ok, raw_result} <- finalized_raw_result(record),
         true <- adoption_result_fingerprint(raw_result) == result_fingerprint do
      reason
    else
      _no_matching_snapshot -> nil
    end
  end

  defp begin_adoption(state, task_id, destination_ref, from) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        case prepare_adoption(record, destination_ref) do
          {:ok, input} ->
            begin_prepared_adoption(state, task_id, input, from)

          {:already_adopted, result} ->
            {:reply, {:ok, result}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp prepare_adoption(
         %{state: :done, context_mode: :json_clean} = record,
         destination_ref
       ) do
    module = Map.get(record, :executor)

    cond do
      not (is_atom(module) and Code.ensure_loaded?(module) and
               function_exported?(module, :adopt_task, 4)) ->
        {:error, :task_adoption_unsupported}

      true ->
        with {:ok, request} <- normalize_adoption_request(destination_ref),
             {:ok, raw_result} <- finalized_raw_result(record) do
          requested_destination = Map.fetch!(request, "destination_ref")

          case Map.get(record, :adoption_destination_ref) do
            nil ->
              {:ok,
               %{
                 agent_id: record.agent_id,
                 context: record.context,
                 executor: module,
                 outcome: Map.get(raw_result, "outcome"),
                 request: request,
                 raw_result: raw_result,
                 result_fingerprint: adoption_result_fingerprint(raw_result)
               }}

            ^requested_destination ->
              {:already_adopted, record.result}

            _other_destination ->
              {:error, :task_already_adopted}
          end
        else
          {:error, reason} -> {:error, {:task_adoption_failed, bounded_error(reason)}}
        end
    end
  end

  defp prepare_adoption(%{state: state}, _destination_ref)
       when state != :done,
       do: {:error, {:task_not_adoptable, state}}

  defp prepare_adoption(_record, _destination_ref),
    do: {:error, :task_adoption_unsupported}

  defp begin_prepared_adoption(state, task_id, input, from) do
    case Map.get(state.adoptions, task_id) do
      nil ->
        start_adoption(state, task_id, input, from)

      operation ->
        cond do
          operation.request != input.request or
              operation.result_fingerprint != input.result_fingerprint ->
            {:reply, {:error, :task_adoption_in_progress}, state}

          length(operation.waiters) >= @max_adoption_waiters ->
            {:reply, {:error, :too_many_adoption_waiters}, state}

          true ->
            operation = Map.update!(operation, :waiters, &[from | &1])
            {:wait, put_in(state.adoptions[task_id], operation)}
        end
    end
  end

  defp start_adoption(state, task_id, input, from) do
    case start_adoption_worker(state, input) do
      {:ok, task} ->
        timeout_ref =
          Process.send_after(
            self(),
            {:adoption_timeout, task_id, task.ref},
            state.adoption_timeout_ms
          )

        operation =
          input
          |> Map.take([
            :agent_id,
            :context,
            :executor,
            :outcome,
            :request,
            :result_fingerprint
          ])
          |> Map.merge(%{
            task: task,
            timeout_ref: timeout_ref,
            waiters: [from]
          })

        next_state =
          state
          |> put_in([:tasks, task_id, :adoption_last_error], nil)
          |> put_in([:adoptions, task_id], operation)
          |> put_in([:adoption_refs, task.ref], task_id)

        {:wait, next_state}

      {:error, reason} ->
        {:reply, {:error, {:task_adoption_failed, bounded_error(reason)}}, state}
    end
  end

  defp start_adoption_worker(state, input) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        with_adoption_owner_guard(owner, fn ->
          invoke_adoption_callback(
            input.executor,
            input.agent_id,
            input.raw_result,
            input.request,
            input.context
          )
        end)
      end)

    {:ok, task}
  rescue
    _exception -> {:error, :executor_callback_failed}
  catch
    :exit, _reason -> {:error, :executor_callback_exit}
  end

  defp with_adoption_owner_guard(owner, callback)
       when is_pid(owner) and is_function(callback, 0) do
    worker = self()

    guard =
      spawn_link(fn ->
        owner_ref = Process.monitor(owner)

        receive do
          {:adoption_worker_finished, ^worker} ->
            Process.demonitor(owner_ref, [:flush])

          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            Process.exit(worker, :kill)
        end
      end)

    try do
      callback.()
    after
      send(guard, {:adoption_worker_finished, worker})
    end
  end

  defp invoke_adoption_callback(module, agent_id, raw_result, request, context) do
    module.adopt_task(agent_id, raw_result, request, context)
  rescue
    _exception -> {:error, :executor_callback_exception}
  catch
    :exit, _reason -> {:error, :executor_callback_exit}
    _kind, _reason -> {:error, :executor_callback_exception}
  end

  defp complete_adoption(state, task_id, ref, callback_result) do
    case Map.get(state.adoptions, task_id) do
      %{task: %Task{ref: ^ref}} = operation ->
        state = drop_adoption(state, task_id, operation)
        {reply, state} = commit_adoption_result(state, task_id, operation, callback_result)
        reply_adoption_waiters(operation.waiters, reply)
        state

      _other ->
        state
    end
  end

  defp fail_adoption(state, task_id, ref, callback_result) do
    complete_adoption(state, task_id, ref, callback_result)
  end

  defp drop_adoption(state, task_id, operation) do
    _ = Process.cancel_timer(operation.timeout_ref)

    state
    |> update_in([:adoptions], &Map.delete(&1, task_id))
    |> update_in([:adoption_refs], &Map.delete(&1, operation.task.ref))
  end

  defp commit_adoption_result(state, task_id, operation, callback_result) do
    with {:ok, record} <- Map.fetch(state.tasks, task_id),
         :ok <- validate_adoption_snapshot(record, operation),
         {:ok, updated_raw_result} <- normalize_adoption_callback(callback_result),
         :ok <- preserve_adoption_outcome(operation, updated_raw_result) do
      updated_record =
        record
        |> Map.put(:result, normalize_result(updated_raw_result))
        |> Map.put(:adoption_destination_ref, operation.request["destination_ref"])
        |> Map.put(:adoption_last_error, nil)
        |> Map.put(:updated_at, DateTime.utc_now())

      {updated_record, retire_spec} = plan_lease_retire(updated_record, :after_adoption)
      state = put_in(state.tasks[task_id], updated_record)
      state = accept_retire_spec(state, retire_spec)

      {{:ok, updated_record.result}, state}
    else
      :error ->
        adoption_commit_error(state, task_id, operation, :task_adoption_state_changed)

      {:error, reason} ->
        adoption_commit_error(state, task_id, operation, reason)
    end
  end

  defp adoption_commit_error(state, task_id, operation, reason) do
    bounded_reason = bounded_error(reason)

    state =
      update_in(state.tasks, fn tasks ->
        case Map.fetch(tasks, task_id) do
          {:ok, record} ->
            last_error = %{
              request: operation.request,
              result_fingerprint: operation.result_fingerprint,
              reason: bounded_reason
            }

            Map.put(tasks, task_id, Map.put(record, :adoption_last_error, last_error))

          :error ->
            tasks
        end
      end)

    {{:error, {:task_adoption_failed, bounded_reason}}, state}
  end

  defp validate_adoption_snapshot(
         %{state: :done, context_mode: :json_clean} = record,
         operation
       ) do
    with true <- record.agent_id == operation.agent_id,
         true <- record.executor == operation.executor,
         true <- record.context == operation.context,
         nil <- Map.get(record, :adoption_destination_ref),
         {:ok, raw_result} <- finalized_raw_result(record),
         true <-
           adoption_result_fingerprint(raw_result) == operation.result_fingerprint do
      :ok
    else
      _other -> {:error, :task_adoption_state_changed}
    end
  end

  defp validate_adoption_snapshot(_record, _operation),
    do: {:error, :task_adoption_state_changed}

  defp preserve_adoption_outcome(operation, updated_raw_result) do
    updated_outcome = Map.get(updated_raw_result, "outcome")

    if operation.outcome == updated_outcome,
      do: :ok,
      else: {:error, :adoption_changed_terminal_outcome}
  end

  defp adoption_result_fingerprint(raw_result) do
    raw_result
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp reply_adoption_waiters(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp normalize_adoption_request(destination_ref)
       when is_binary(destination_ref) and
              byte_size(destination_ref) <= @max_destination_ref_bytes do
    destination_ref = String.trim(destination_ref)

    if destination_ref != "" and String.valid?(destination_ref) and
         not String.match?(destination_ref, ~r/[\x00-\x1F\x7F]/) do
      canonicalize_and_roundtrip(%{"destination_ref" => destination_ref})
    else
      {:error, :invalid_destination_ref}
    end
  end

  defp normalize_adoption_request(_destination_ref), do: {:error, :invalid_destination_ref}

  defp finalized_raw_result(record) do
    raw_result =
      case record.result do
        result when is_map(result) -> Map.get(result, :raw, Map.get(result, "raw"))
        _ -> nil
      end

    if is_map(raw_result) and not is_struct(raw_result) do
      canonicalize_and_roundtrip(raw_result)
    else
      {:error, :missing_executor_raw_result}
    end
  end

  defp normalize_adoption_callback({:ok, updated_raw_result})
       when is_map(updated_raw_result) and not is_struct(updated_raw_result) do
    canonicalize_and_roundtrip(updated_raw_result)
  end

  defp normalize_adoption_callback({:error, reason}), do: {:error, reason}
  defp normalize_adoption_callback(_other), do: {:error, :invalid_adoption_result}

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

  # Legacy sync revoke helpers removed: hot-upgrade records with per-kind cap
  # fields are retired through the reconciled pending-bucket path only.

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
    status = %{
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

    case status_outcome(record) do
      {:ok, outcome} -> Map.put(status, :outcome, outcome)
      :error -> status
    end
  end

  defp status_outcome(%{terminal_envelope: %{"outcome" => outcome}}), do: {:ok, outcome}

  defp status_outcome(%{state: :done, result: result}),
    do: TaskArtifacts.extract_outcome(result)

  defp status_outcome(%{state: :failed, error: error}),
    do: TaskArtifacts.extract_outcome(error)

  defp status_outcome(_record), do: :error

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

  defp owner_statuses(tasks) when is_map(tasks) do
    tasks
    |> :maps.iterator()
    |> take_owner_entries(@default_max_tasks)
    |> Enum.reduce(%{}, fn {key, record}, statuses ->
      task_id =
        case record do
          %{task_id: task_id} when is_binary(task_id) -> task_id
          %{"task_id" => task_id} when is_binary(task_id) -> task_id
          _ when is_binary(key) -> key
          _ -> nil
        end

      if is_binary(task_id) do
        pid = record_value(record, :pid)

        Map.put(statuses, task_id, %{
          present: is_pid(pid),
          alive: is_pid(pid) and Process.alive?(pid)
        })
      else
        statuses
      end
    end)
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp owner_statuses(_tasks), do: %{}

  defp take_owner_entries(iterator, limit), do: take_owner_entries(iterator, limit, [])

  defp take_owner_entries(_iterator, 0, acc), do: acc

  defp take_owner_entries(iterator, limit, acc) do
    case :maps.next(iterator) do
      :none ->
        acc

      {key, value, next_iterator} ->
        take_owner_entries(next_iterator, limit - 1, [{key, value} | acc])
    end
  end

  defp record_value(record, key) when is_map(record),
    do: Map.get(record, key, Map.get(record, to_string(key)))

  defp record_value(_record, _key), do: nil

  defp ensure_adoption_state_shape(state) do
    state
    |> Map.put_new(:adoptions, %{})
    |> Map.put_new(:adoption_refs, %{})
    |> Map.put_new(:adoption_timeout_ms, @default_adoption_timeout_ms)
  end

  defp adoption_deadline_expired?(deadline_ms) when is_integer(deadline_ms) do
    System.monotonic_time(:millisecond) >= deadline_ms
  end

  defp adoption_deadline_expired?(_deadline_ms), do: true

  defp adoption_wait_timeout(opts) do
    case opt(opts, :adoption_wait_timeout_ms, @default_adoption_wait_timeout_ms) do
      timeout_ms
      when is_integer(timeout_ms) and timeout_ms > 0 and
             timeout_ms <= @max_adoption_wait_timeout_ms ->
        {:ok, timeout_ms}

      _invalid ->
        {:error, :invalid_adoption_wait_timeout}
    end
  end

  defp adoption_status_timeout(opts) do
    case opt(opts, :adoption_status_timeout_ms, @default_adoption_status_timeout_ms) do
      timeout_ms
      when is_integer(timeout_ms) and timeout_ms > 0 and
             timeout_ms <= @max_adoption_status_timeout_ms ->
        {:ok, timeout_ms}

      _invalid ->
        {:error, :invalid_adoption_status_timeout}
    end
  end

  defp validate_adoption_timeout!(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_adoption_timeout_ms,
       do: timeout_ms

  defp validate_adoption_timeout!(timeout_ms) do
    raise ArgumentError,
          "adoption_timeout_ms must be between 1 and #{@max_adoption_timeout_ms}, got: " <>
            inspect(timeout_ms)
  end

  defp remove_ref(state, ref) do
    update_in(state.refs, &Map.delete(&1, ref))
  end

  defp prune_tasks(%{max_tasks: max_tasks, tasks: tasks} = state)
       when map_size(tasks) <= max_tasks do
    state
  end

  defp prune_tasks(%{max_tasks: max_tasks, tasks: tasks} = state) do
    active_adoptions =
      state
      |> Map.get(:adoptions, %{})
      |> Map.keys()
      |> MapSet.new()

    completed =
      tasks
      |> Enum.filter(fn {id, record} ->
        record.state in [:done, :failed, :cancelled] and
          not MapSet.member?(active_adoptions, id)
      end)
      |> Enum.sort_by(fn {_id, record} -> record.updated_at end, DateTime)

    excess = max(map_size(tasks) - max_tasks, 0)

    prune_ids =
      completed
      |> Enum.take(excess)
      |> Enum.map(fn {id, _record} -> id end)

    # Plan all retires into store-owned pending buckets (authority survives
    # task-record drop), publish by dropping records, then admit reconciliation.
    Enum.reduce(prune_ids, state, fn id, st ->
      record = Map.fetch!(st.tasks, id)
      {_record, spec} = plan_lease_retire(record, :all)
      st = update_in(st.tasks, &Map.delete(&1, id))
      accept_retire_spec(st, spec)
    end)
  end

  defp task_id(opts) do
    Keyword.get(opts, :task_id) ||
      Arbor.Identifiers.generate_id("task_")
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

  defp prepare_dispatch(_task, _opts, %{tasks: tasks}, task_id)
       when is_map_key(tasks, task_id),
       do: {:error, :task_id_already_exists}

  defp prepare_dispatch(task, opts, state, task_id) do
    with {:ok, runner, context_mode} <- resolve_executor(task, opts, state) do
      case context_mode do
        :json_clean ->
          with {:ok, clean_task} <- canonicalize_and_validate_task(task),
               {:ok, clean_context} <- build_and_validate_json_context(opts, task_id) do
            {:ok, runner, :json_clean, clean_task, clean_context}
          end

        :full_opts ->
          # Keep trusted lease/cleanup selectors on the store record only; never
          # hand them to the runner (no payload/runner authority over cleanup).
          runner_context =
            opts
            |> Keyword.put(:task_id, task_id)
            |> Keyword.delete(:approval_cleanup_descriptor)
            |> Keyword.delete(:task_control_lease)
            |> Keyword.delete(:task_control_security_module)
            |> Keyword.delete(:task_control_revoke)
            |> Keyword.delete(:approval_answer_cap_id)
            |> Keyword.delete(:approval_answer_security_module)
            |> Keyword.delete(:approval_answer_revoke)
            |> Keyword.delete(:steer_cap_id)
            |> Keyword.delete(:steer_security_module)
            |> Keyword.delete(:steer_capability_revoke)
            |> Keyword.delete(:adoption_cap_id)
            |> Keyword.delete(:adoption_security_module)
            |> Keyword.delete(:adoption_capability_revoke)

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
