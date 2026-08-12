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
  @default_runtime_admission_call_timeout_ms 120_000

  alias Arbor.Agent.Config
  alias Arbor.Agent.Orchestration.{TaskArtifacts, TaskControlLease, TaskInventoryProjection}
  alias Arbor.Agent.RuntimeAdmission.IntentCore
  alias Arbor.Agent.RuntimeAdmission.IntentOwner
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RuntimeAdmissionSupervisor

  alias Arbor.Contracts.Coding.{
    AdmissionFailure,
    ReadinessReport,
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
  completed.
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
    GenServer.call(
      store_name(opts),
      {:admit_ordinary_runtime_start, target_agent_id, fingerprint, validated_opts},
      runtime_admission_call_timeout(opts)
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
  Adopt the calling IntentOwner against the current fence and intent map.

  Source-owned: the GenServer caller pid is the only accepted owner identity
  (caller-supplied PIDs are never trusted). Late owners must re-enter here
  before launching work.
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

  defp runtime_admission_call_timeout(opts) do
    opts
    |> normalize_opts()
    |> Keyword.get(:timeout, @default_runtime_admission_call_timeout_ms)
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
      runtime_admission_owner_monitors: %{},
      runtime_admission_worker_monitors: %{},
      runtime_admission_reconcile: %{status: :pending},
      max_runtime_admission_intents:
        Keyword.get(opts, :max_runtime_admission_intents, @default_max_runtime_admission_intents),
      runtime_admission_admit_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_admit_timeout_ms,
          @default_runtime_admission_admit_timeout_ms
        ),
      runtime_admission_reconcile_timeout_ms:
        Keyword.get(
          opts,
          :runtime_admission_reconcile_timeout_ms,
          @default_runtime_admission_reconcile_timeout_ms
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

    cond do
      state.target_fence_ready? != true ->
        {:reply, {:error, :fence_not_ready}, state}

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

    cond do
      state.target_fence_ready? != true ->
        {:reply, {:error, :fence_not_ready}, state}

      true ->
        with {:ok, target} <- validate_fence_target(target_agent_id),
             {:ok, op} <- validate_fence_operation_id(operation_id) do
          case Map.get(state.target_fences, target) do
            ^op ->
              state = put_in(state, [:target_fences], Map.delete(state.target_fences, target))
              {:reply, :ok, state}

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
        {:admit_ordinary_runtime_start, target_agent_id, fingerprint, validated_opts},
        from,
        state
      ) do
    state = ensure_fence_shape(state)
    state = ensure_runtime_admission_shape(state)

    case validate_fence_target(target_agent_id) do
      {:ok, target} ->
        do_admit_ordinary_runtime_start(state, target, fingerprint, validated_opts, from)

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

    # Source-owned: caller pid is the only accepted owner identity.
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
            mon = Process.monitor(caller_pid)

            state =
              state
              |> put_in([:runtime_admission_intents], intents)
              |> put_in([:runtime_admission_by_id, intent_id], target)
              |> put_in([:runtime_admission_owner_monitors, mon], {intent_id, target, caller_pid})

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
        case authorize_and_settle_runtime_admission(
               state,
               target,
               intent_id,
               outcome,
               caller_pid
             ) do
          {:ok, new_state} ->
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

    {:noreply, handle_normal_down(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    state = ensure_adoption_state_shape(state)
    state = ensure_lease_retirement_shape(state)
    state = ensure_recovery_shape(state)

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

  def handle_info({:runtime_admission_owner_launched, intent_id, owner_pid}, state)
      when is_binary(intent_id) and is_pid(owner_pid) do
    # Owner will adopt via call; nothing to do beyond tracking if needed.
    {:noreply, state}
  end

  def handle_info({:runtime_admission_owner_launch_failed, intent_id, reason}, state)
      when is_binary(intent_id) do
    state = ensure_runtime_admission_shape(state)

    case Map.get(state.runtime_admission_by_id, intent_id) do
      target when is_binary(target) ->
        {:noreply, force_settle_runtime_admission_intent(state, target, intent_id, {:error, reason})}

      _ ->
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

      {:runtime_admission_owner, intent_id, target, _owner_pid} ->
        handle_runtime_admission_owner_down(state, ref, intent_id, target)

      {:runtime_admission_worker, intent_id, target, worker_pid} ->
        handle_runtime_admission_worker_monitor_down(state, ref, intent_id, target, worker_pid)

      {:runtime_admission_reconcile_launcher, rec} ->
        handle_runtime_admission_reconcile_launcher_down(state, rec)

      {:runtime_admission_reconcile_worker, rec} ->
        handle_runtime_admission_reconcile_worker_down(state, rec)

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

      {:runtime_admission_owner, intent_id, target, _owner_pid} ->
        handle_runtime_admission_owner_down(state, ref, intent_id, target)

      {:runtime_admission_worker, intent_id, target, worker_pid} ->
        handle_runtime_admission_worker_monitor_down(state, ref, intent_id, target, worker_pid)

      {:runtime_admission_reconcile_launcher, rec} ->
        handle_runtime_admission_reconcile_launcher_down(state, rec)

      {:runtime_admission_reconcile_worker, rec} ->
        handle_runtime_admission_reconcile_worker_down(state, rec)

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
    state = ensure_runtime_admission_shape(state)

    case Map.get(state.runtime_admission_owner_monitors, ref) do
      {intent_id, target, owner_pid} ->
        {:runtime_admission_owner, intent_id, target, owner_pid}

      nil ->
        case Map.get(state.runtime_admission_worker_monitors, ref) do
          {intent_id, target, worker_pid} ->
            {:runtime_admission_worker, intent_id, target, worker_pid}

          nil ->
            case find_runtime_admission_reconcile_monitor(state, ref) do
              {:launcher, rec} -> {:runtime_admission_reconcile_launcher, rec}
              {:worker, rec} -> {:runtime_admission_reconcile_worker, rec}
              :error -> classify_reservation_monitor(state, ref)
            end
        end
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

  defp ensure_runtime_admission_shape(state) do
    state
    |> Map.put_new(:store_ref, @default_name)
    |> Map.put_new(:runtime_admission_supervisor, @default_runtime_admission_supervisor)
    |> Map.put_new(:runtime_admission_ready?, false)
    |> Map.put_new(:runtime_admission_intents, %{})
    |> Map.put_new(:runtime_admission_by_id, %{})
    |> Map.put_new(:runtime_admission_waiters, %{})
    |> Map.put_new(:runtime_admission_owner_monitors, %{})
    |> Map.put_new(:runtime_admission_worker_monitors, %{})
    |> Map.put_new(:runtime_admission_reconcile, %{status: :pending})
    |> Map.put_new(:max_runtime_admission_intents, @default_max_runtime_admission_intents)
    |> Map.put_new(
      :runtime_admission_admit_timeout_ms,
      @default_runtime_admission_admit_timeout_ms
    )
    |> Map.put_new(
      :runtime_admission_reconcile_timeout_ms,
      @default_runtime_admission_reconcile_timeout_ms
    )
  end

  defp do_admit_ordinary_runtime_start(state, target, fingerprint, validated_opts, from) do
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
        state =
          state
          |> put_in([:runtime_admission_intents], intents)
          |> add_runtime_admission_waiter(intent.intent_id, from)

        {:noreply, state}

      {:ok, :admitted, intent, intents, effects} ->
        state =
          state
          |> put_in([:runtime_admission_intents], intents)
          |> put_in([:runtime_admission_by_id, intent.intent_id], target)
          |> add_runtime_admission_waiter(intent.intent_id, from)

        state =
          Enum.reduce(effects, state, fn
            {:launch_owner, launched}, acc ->
              launch_runtime_admission_owner(acc, launched, validated_opts)

            _, acc ->
              acc
          end)

        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp add_runtime_admission_waiter(state, intent_id, from) do
    waiters = Map.get(state.runtime_admission_waiters, intent_id, [])
    put_in(state, [:runtime_admission_waiters, intent_id], [from | waiters])
  end

  defp mint_runtime_admission_intent_id do
    "rai_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp launch_runtime_admission_owner(state, intent, validated_opts) do
    store_ref = Map.get(state, :store_ref, @default_name)
    supervisor = Map.get(state, :runtime_admission_supervisor, @default_runtime_admission_supervisor)
    task_supervisor = Map.get(state, :task_supervisor, @default_task_supervisor)

    # Fixed launcher MFA — never captures store pid; uses stable store_ref.
    _ =
      spawn(__MODULE__, :runtime_admission_owner_launcher, [
        store_ref,
        supervisor,
        task_supervisor,
        intent.intent_id,
        intent.target_agent_id,
        intent.fingerprint,
        validated_opts
      ])

    intents =
      Map.update!(state.runtime_admission_intents, intent.target_agent_id, fn i ->
        %{i | phase: :owner_launching}
      end)

    %{state | runtime_admission_intents: intents}
  end

  @doc false
  def runtime_admission_owner_launcher(
        store_ref,
        supervisor,
        task_supervisor,
        intent_id,
        target,
        fingerprint,
        validated_opts
      ) do
    start_opts = [
      intent_id: intent_id,
      target_agent_id: target,
      fingerprint: fingerprint,
      validated_opts: validated_opts,
      store_ref: store_ref,
      task_supervisor: task_supervisor
    ]

    case RuntimeAdmissionSupervisor.start_owner(start_opts, supervisor) do
      {:ok, owner_pid} when is_pid(owner_pid) ->
        send(store_ref, {:runtime_admission_owner_launched, intent_id, owner_pid})

      {:ok, owner_pid, _} when is_pid(owner_pid) ->
        send(store_ref, {:runtime_admission_owner_launched, intent_id, owner_pid})

      {:error, reason} ->
        send(store_ref, {:runtime_admission_owner_launch_failed, intent_id, reason})

      other ->
        send(store_ref, {:runtime_admission_owner_launch_failed, intent_id, other})
    end

    :ok
  rescue
    _ ->
      send(store_ref, {:runtime_admission_owner_launch_failed, intent_id, :launcher_exception})
      :ok
  catch
    :exit, _ ->
      send(store_ref, {:runtime_admission_owner_launch_failed, intent_id, :launcher_exit})
      :ok
  end

  # Caller-facing settle: only the registered worker may settle.
  defp authorize_and_settle_runtime_admission(state, target, intent_id, outcome, caller_pid) do
    intent = Map.get(state.runtime_admission_intents, target)

    cond do
      not is_map(intent) ->
        {:error, :not_found, state}

      intent.intent_id != intent_id ->
        {:error, :conflict, state}

      intent.phase == :terminal ->
        {:error, :not_found, state}

      intent.worker_pid != caller_pid ->
        {:error, :not_owner, state}

      true ->
        {:ok, force_settle_runtime_admission_intent(state, target, intent_id, outcome)}
    end
  end

  # Internal TaskStore-owned settlement (owner/worker monitor paths). Not a public API.
  defp force_settle_runtime_admission_intent(state, target, intent_id, outcome) do
    state = ensure_runtime_admission_shape(state)
    intent = Map.get(state.runtime_admission_intents, target)

    cond do
      not is_map(intent) ->
        state

      intent.intent_id != intent_id ->
        state

      intent.phase == :terminal ->
        state

      true ->
        reply = settlement_reply(outcome)
        waiters = Map.get(state.runtime_admission_waiters, intent_id, [])
        Enum.each(waiters, fn from -> GenServer.reply(from, reply) end)

        if is_pid(intent.owner_pid) and Process.alive?(intent.owner_pid) do
          Process.exit(intent.owner_pid, :normal)
        end

        state =
          case IntentCore.settle(state.runtime_admission_intents, target, intent_id, outcome) do
            {:ok, _done, intents} ->
              put_in(state, [:runtime_admission_intents], intents)

            _ ->
              put_in(
                state,
                [:runtime_admission_intents],
                Map.delete(state.runtime_admission_intents, target)
              )
          end

        state
        |> update_in([:runtime_admission_by_id], &Map.delete(&1, intent_id))
        |> update_in([:runtime_admission_waiters], &Map.delete(&1, intent_id))
        |> drop_owner_monitors_for(intent_id)
        |> drop_worker_monitors_for(intent_id)
    end
  end

  defp settlement_reply({:applied, pid}) when is_pid(pid), do: {:ok, pid}
  defp settlement_reply({:error, reason}), do: {:error, reason}
  defp settlement_reply({:conflict, reason}), do: {:error, {:conflict, reason}}
  defp settlement_reply(other), do: {:error, other}

  defp drop_owner_monitors_for(state, intent_id) do
    mons =
      state.runtime_admission_owner_monitors
      |> Enum.reject(fn {_mon, {id, _t, _p}} -> id == intent_id end)
      |> Map.new()

    %{state | runtime_admission_owner_monitors: mons}
  end

  defp drop_worker_monitors_for(state, intent_id) do
    mons =
      Map.get(state, :runtime_admission_worker_monitors, %{})
      |> Enum.reject(fn {_mon, {id, _t, _p}} -> id == intent_id end)
      |> Map.new()

    %{state | runtime_admission_worker_monitors: mons}
  end

  defp handle_runtime_admission_owner_down(state, mon, intent_id, target) do
    state = ensure_runtime_admission_shape(state)
    state = update_in(state, [:runtime_admission_owner_monitors], &Map.delete(&1, mon))
    intent = Map.get(state.runtime_admission_intents, target)

    if is_map(intent) and intent.intent_id == intent_id and intent.phase != :terminal do
      classify_or_mark_unknown(state, target, intent)
    else
      state
    end
  end

  defp handle_runtime_admission_worker_monitor_down(state, mon, intent_id, target, worker_pid) do
    state = ensure_runtime_admission_shape(state)
    state = update_in(state, [:runtime_admission_worker_monitors], &Map.delete(&1, mon))
    intent = Map.get(state.runtime_admission_intents, target)

    # Authentic worker-down only: monitor identity + recorded worker_pid match.
    if is_map(intent) and intent.intent_id == intent_id and intent.worker_pid == worker_pid and
         intent.phase != :terminal do
      classify_or_mark_unknown(state, target, intent)
    else
      state
    end
  end

  defp classify_or_mark_unknown(state, target, intent) do
    fact = witness_fact(target, intent.intent_id)

    case IntentCore.classify_unknown_start(intent.intent_id, fact) do
      :applied ->
        case Arbor.Agent.BranchSupervisor.whereis(target) do
          pid when is_pid(pid) ->
            force_settle_runtime_admission_intent(
              state,
              target,
              intent.intent_id,
              {:applied, pid}
            )

          _ ->
            force_settle_runtime_admission_intent(
              state,
              target,
              intent.intent_id,
              {:error, :branch_missing_after_witness}
            )
        end

      :conflict ->
        force_settle_runtime_admission_intent(
          state,
          target,
          intent.intent_id,
          {:conflict, :witness_mismatch}
        )

      :not_applied ->
        case IntentCore.mark_outcome_unknown(state.runtime_admission_intents, target) do
          {:ok, intents} -> put_in(state, [:runtime_admission_intents], intents)
          _ -> state
        end
    end
  end

  defp witness_fact(target, intent_id) do
    case Arbor.Agent.BranchSupervisor.ordinary_admission_witness(target) do
      {:ok, %{intent_id: ^intent_id}} -> {:exact, intent_id}
      {:ok, %{intent_id: other}} when is_binary(other) -> {:other, other}
      :none -> :bare
      :not_running -> :not_running
      _ -> :bare
    end
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
    supervisor = Map.get(state, :runtime_admission_supervisor, @default_runtime_admission_supervisor)
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
        timeout + 1_000
      ])

    rec = %{
      status: :admitting,
      ref: ref,
      launcher_pid: launcher_pid,
      launcher_mon: launcher_mon,
      worker_pid: nil,
      worker_mon: nil,
      timer: timer,
      attempts: Map.get(state.runtime_admission_reconcile, :attempts, 0)
    }

    put_in(state, [:runtime_admission_reconcile], rec)
  end

  @doc false
  def runtime_admission_reconcile_launcher(store_ref, ref, task_supervisor, owner_supervisor, begin_wait_ms) do
    case Task.Supervisor.start_child(
           task_supervisor,
           __MODULE__,
           :run_runtime_admission_reconcile_worker,
           [store_ref, ref, owner_supervisor, begin_wait_ms],
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
  def run_runtime_admission_reconcile_worker(store_ref, ref, owner_supervisor, begin_wait_ms) do
    receive do
      {:runtime_admission_reconcile_begin, ^ref} ->
        result = inventory_runtime_admission_owners(owner_supervisor)
        send(store_ref, {:runtime_admission_reconcile_complete, ref, result})
        :ok
    after
      begin_wait_ms ->
        :ok
    end
  end

  defp inventory_runtime_admission_owners(owner_supervisor) do
    case RuntimeAdmissionSupervisor.which_children(owner_supervisor) do
      {:ok, children} ->
        snapshots =
          children
          |> Enum.flat_map(fn
            {_id, pid, :worker, _} when is_pid(pid) ->
              case IntentOwner.snapshot(pid) do
                {:ok, snap} -> [snap]
                _ -> []
              end

            _ ->
              []
          end)

        # Repair RuntimeAdmissionRegistry from owner snapshots.
        repair_runtime_admission_registry(snapshots)
        {:ok, snapshots}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :inventory_exception}
  catch
    :exit, _ -> {:error, :inventory_exit}
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
      if is_pid(launcher_pid) and Process.alive?(launcher_pid), do: Process.exit(launcher_pid, :kill)
      state = cleanup_runtime_admission_reconcile(state, rec)
      schedule_runtime_admission_reconcile_retry(state)
    else
      state
    end
  end

  defp handle_runtime_admission_reconcile_complete(state, ref, result) do
    state = ensure_runtime_admission_shape(state)
    rec = state.runtime_admission_reconcile

    if Map.get(rec, :ref) == ref and Map.get(rec, :status) == :running do
      state = cleanup_runtime_admission_reconcile(state, rec)

      case result do
        {:ok, snapshots} when is_list(snapshots) ->
          case IntentCore.rebind_owners(%{}, snapshots) do
            {:ok, intents} ->
              by_id =
                Enum.reduce(intents, %{}, fn {target, intent}, acc ->
                  Map.put(acc, intent.intent_id, target)
                end)

              # Monitor rebound owners.
              {state, mon_map} =
                Enum.reduce(intents, {state, %{}}, fn {_t, intent}, {st, mons} ->
                  if is_pid(intent.owner_pid) and Process.alive?(intent.owner_pid) do
                    mon = Process.monitor(intent.owner_pid)

                    {st,
                     Map.put(mons, mon, {intent.intent_id, intent.target_agent_id, intent.owner_pid})}
                  else
                    {st, mons}
                  end
                end)

              %{
                state
                | runtime_admission_intents: intents,
                  runtime_admission_by_id: by_id,
                  runtime_admission_owner_monitors: mon_map,
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
                   :invalid_inventory
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

        _ ->
          schedule_runtime_admission_reconcile_retry(state)
      end
    else
      state
    end
  end

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
    if is_reference(Map.get(rec, :launcher_mon)), do: Process.demonitor(rec.launcher_mon, [:flush])
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
