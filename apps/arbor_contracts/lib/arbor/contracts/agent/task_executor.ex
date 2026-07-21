defmodule Arbor.Contracts.Agent.TaskExecutor do
  @moduledoc """
  Cross-library behaviour for async orchestration task execution.

  This is the seam between `arbor_agent` (outer task record, authorization,
  status, cancellation, executor selection) and executor implementations such
  as the default agent-query runner and, later, the coding-pipeline executor in
  `arbor_orchestrator`.

  ## Production execution context is JSON-clean

  Context that crosses library boundaries in production must be JSON-clean:

  - string-keyed maps and lists of JSON scalars / nested JSON values only
  - known scalar keys such as `task_id`, `timeout`, `caller_id`, and `metadata`

  Do **not** pass PIDs, ports, references, callback functions, monitors, modules
  as authority, capability structs, or private TaskStore options across this
  boundary. Those stay inside the owning library. TaskStore enforces a
  structured JSON round-trip before spawning a production configured executor.

  ## Pending approval

  Executors may return the existing pending-approval shapes so TaskStore can
  mark the outer task as `waiting_approval` without completing or failing it:

  - `{:ok, :pending_approval, approval_id}`
  - `{:error, {:pending_approval, approval_id}}`

  ## Optional progress, cancel, and steering

  Configured executors may implement `task_status/2` and `cancel_task/2`.
  TaskStore best-effort calls them for configured (non-override) executors:

  - `task_status/2` may project only `current_step` and `waiting_on` onto the
    outer status view while the task is running. Non-JSON progress or invalid
    field values are ignored; outer ids/state/timestamps/metadata are never
    overridden.
  - `cancel_task/2` is invoked before the existing cancel-turn bridge and hard
    kill; callback errors/exits/timeouts never block cancellation completion

  Both callbacks are time-bounded (supervised, short timeout, brutal kill on
  hang) so one executor cannot freeze status or prevent cancellation.
  Explicit runner overrides do not use these cross-library callbacks.

  Configured executors may also implement `steer_task/3`. TaskStore writes an
  ordered control record before calling it, then preserves that record across
  runner exits. A steering callback receives the exact JSON-clean control map
  assigned by TaskStore and the original JSON-clean execution context.

  ## Persisted control statuses

  Only these string statuses are ever persisted on a control record:
  `"queued"`, `"deferred"`, `"delivered"`, `"delivery_unconfirmed"`, and
  `"unsupported"`. The evidence atoms `:not_delivered`, `:delivery_unknown`,
  and `:cancelled` are **never** stored as statuses — they drive transitions
  inside TaskStore and then disappear.

  ## Queued is acceptance only

  `{:ok, :queued, mode}` means the executor has durably accepted responsibility
  for later delivery. TaskStore confirms an accepted control by calling
  `steer_task/3` again with the same control. The `control_id`, `task_id`,
  `sequence`, `sender_id`, `message`, `queued_at`, and `target_stage` fields
  are stable across all calls for the same control; only bookkeeping fields
  (`status`, `delivery_mode`, `delivered_at`, `error`) may change between
  calls. Only an explicit `{:ok, mode}` return from a confirmation call sets
  `delivered_at`. A successful `run/3` return does **not** manufacture
  delivery — if the task finishes before an accepted control is confirmed
  delivered, TaskStore terminalizes it as `"delivery_unconfirmed"`.

  ## Evidence atoms

  The executor may return three distinct evidence atoms (as `{:error, atom}`)
  during initial delivery, confirmation, and replay. They are never persisted
  as control statuses — TaskStore translates them into delivery / replay /
  terminalize transitions:

  - `:not_delivered` — positive nondelivery. The executor explicitly asserts
    the control was not delivered, so retrying is safe. During confirmation of
    an accepted control, TaskStore clears accepted ownership and triggers a
    **bounded same-ID replay** (re-delivery of the same control, same
    `control_id`). During initial delivery or replay delivery it is treated
    as a retryable operational error (bounded by the initial delivery budget).
  - `:delivery_unknown` — ambiguous delivery. Unsafe to retry or replay: the
    executor may have already acted. TaskStore terminalizes the control as
    `"delivery_unconfirmed"` with a bounded diagnostic error, whether returned
    during initial delivery, confirmation, or replay.
  - `:cancelled` — explicit cancellation. Same terminalization as
    `:delivery_unknown` with a distinct bounded error.

  Any other operational error during confirmation is retried with the same
    control up to a bounded confirmation budget; exhaustion also terminalizes
    as `"delivery_unconfirmed"`.

  ## FIFO

  Initial callbacks may accept multiple controls in sequence, but only the
  earliest unresolved (accepted, unconfirmed) control may be confirmed or
  replayed. TaskStore schedules the next confirmation only after the current
  one settles (delivered, unsupported, or delivery_unconfirmed), and never
  spends later-control confirmation budget while an earlier control is
  unresolved or still in flight (deferred). No accepted control remains
  stranded behind a terminal predecessor.

  ## Bounds

  TaskStore bounds initial delivery retries, positive-nondelivery replays,
  and queued confirmations independently. `:delivery_unknown` and `:cancelled`
  do not consume any retry budget — they terminalize immediately. At most one
  active confirmation timer is scheduled per eligible control; stale timers
  are harmless no-ops (guarded by task_running + accepted + FIFO).

  ## Hot-state upgrade compatibility

  A TaskStore process whose code was hot-loaded while tasks with accepted
  queued controls were in flight holds records that predate the
  confirmation/replay machinery. TaskStore lazily normalizes such records:
  missing bookkeeping maps are materialized as empty, and legacy accepted
  queued controls are terminalized as `"delivery_unconfirmed"` with the
  bounded diagnostic `"legacy_upgrade_unconfirmed"` so they cannot block
  FIFO indefinitely or manufacture a delivery ACK.

  Explicit runner overrides report steering as unsupported.

  Configured executors may implement `finalize_task/4` for mandatory terminal artifact retention.
  TaskStore calls it only after a successful configured
  executor return and terminal steering reconciliation. It is time-bounded
  separately from status and cancellation; an error, exit, or timeout fails
  the outer task. The callback must preserve and return a JSON-clean result,
  and explicit runner overrides do not invoke this callback.

  Configured executors may also implement `adopt_task/4` for post-terminal task adoption.
  TaskStore invokes it only after a successful configured task is terminal. The adoption request is
  a closed JSON object containing `destination_ref`; the callback must return the complete updated
  JSON-clean executor result. Explicit runner overrides do not invoke this callback.
  Queued steering controls transfer responsibility to the executor; acceptance transfers responsibility
  until delivery is reconciled.

  ## Task kinds

  Plain string tasks and legacy maps with `input` / `prompt` / `message` /
  `task` remain the default agent-query path. A structured map with an explicit
  `kind` selects a configured executor. Unsupported, blank, unavailable, or
  malformed kinds must fail closed and never silently fall back to chat.

  Canonical kind: `"coding_change"`. Trusted in-process callers may pass the
  atom `:coding_change`; TaskStore normalizes it to the string form before
  crossing the boundary. External/JSON surfaces should use the string form.
  """

  @typedoc "Target agent identifier."
  @type agent_id :: String.t()

  @typedoc "JSON scalar values permitted across the executor boundary."
  @type json_scalar :: String.t() | number() | boolean() | nil

  @typedoc "Recursive JSON value: scalar, list, or string-keyed map."
  @type json_value :: json_scalar() | [json_value()] | json_map()

  @typedoc "String-keyed JSON object."
  @type json_map :: %{optional(String.t()) => json_value()}

  @typedoc """
  Task payload.

  Strings are the default chat/query path. Maps may be legacy input maps or
  structured tasks with an explicit `kind`. Production configured executors
  receive a JSON-clean string-keyed map (atom kinds normalized to strings).
  """
  @type task :: String.t() | json_map() | map()

  @typedoc """
  Minimal JSON-clean execution context for production configured executors.

  Preferred shape is a string-keyed map. Known keys include `task_id`,
  `timeout`, `caller_id`, and `metadata`. Values must remain JSON-serializable.
  """
  @type execution_context :: json_map()

  @typedoc """
  Best-effort progress projection from a configured executor.

  JSON-clean string-keyed map. Only `"current_step"` and `"waiting_on"`
  (string or nil) are merged into the outer TaskStore status view. Outer ids,
  state, timestamps, and metadata are never overridden.
  """
  @type progress :: json_map()

  @typedoc "Normalized successful task result payload (see TaskArtifacts)."
  @type result_payload :: map()

  @typedoc "Approval identifier when execution is blocked on human/consensus approval."
  @type approval_id :: String.t()

  @typedoc """
  Executor return contract.

  Success returns a structured result map. Pending approval is preserved as a
  first-class outcome (ok- or error-shaped) so the outer task store can wait
  without treating the task as failed.

  Other failures are open-ended operational errors (`{:error, term()}`): network
  faults, runner crashes, validation failures, provider errors, and similar
  executor-local reasons. Document common cases in the implementing module.
  """
  @type result ::
          {:ok, result_payload()}
          | {:ok, :pending_approval, approval_id()}
          | {:error, {:pending_approval, approval_id()}}
          | {:error, term()}

  @typedoc """
  Cancel callback result.

  `:ok` acknowledges cooperative cancel. `{:error, term()}` is open-ended
  (already finished, unknown id, transport fault); TaskStore still completes
  outer cancellation after a best-effort call.
  """
  @type cancel_result :: :ok | {:error, term()}

  @typedoc "Stable JSON-clean steering control owned by TaskStore."
  @type steering_control :: json_map()

  @typedoc "Delivery modes available to a configured task executor."
  @type steering_delivery_mode ::
          :native_tool_loop | :acp_native | :same_session_follow_up | :next_stage

  @typedoc """
  Result of accepting or confirming a task steering control.

  Evidence atoms `:not_delivered`, `:delivery_unknown`, and `:cancelled` are
  valid error returns during initial delivery, confirmation, and replay.
  They are never persisted as control statuses — TaskStore translates them
  into delivery/replay/terminalize transitions. See `steer_task/3` for the
  full semantics.
  """
  @type steering_result ::
          {:ok, steering_delivery_mode()}
          | {:ok, :queued, steering_delivery_mode()}
          | {:error, :unsupported | term()}

  @typedoc "Ordered, terminally reconciled steering controls."
  @type reconciled_steering_controls :: [steering_control()]

  @doc """
  Execute a task for `agent_id` with the given task payload and context.

  Production paths without an explicit runner override (configured default and
  explicit-kind executors) receive a JSON-clean map context. Trusted explicit
  runner overrides may pass keyword options for test/internal compatibility
  (for example `manager_module`); private TaskStore options must not cross the
  production JSON-clean boundary.
  """
  @callback run(agent_id(), task(), execution_context() | keyword()) :: result()

  @doc """
  Optional best-effort progress probe for a running configured task.

  Called by TaskStore while the outer task is `:running`. Must accept the same
  JSON-clean context passed to `run/3`. Return a JSON-clean progress map; only
  `current_step` and `waiting_on` are projected onto the outer status.
  """
  @callback task_status(agent_id(), execution_context()) ::
              {:ok, progress()} | {:error, term()}

  @doc """
  Optional cooperative cancel hook for a configured task.

  Called by TaskStore before the cancel-turn bridge and hard kill. Must accept
  the same JSON-clean context passed to `run/3`. Errors and exits are ignored
  by TaskStore so outer cancellation always completes.
  """
  @callback cancel_task(agent_id(), execution_context()) :: cancel_result()

  @doc """
  Optionally accept a persisted steering control for a running task.

  The control map contains only JSON values and always includes the stable
  `control_id`, `task_id`, `sequence`, `status`, `sender_id`, `message`, and
  timestamp fields.

  ## Return values

  - `{:ok, mode}` — delivered immediately. TaskStore sets `delivered_at`.
  - `{:ok, :queued, mode}` — accepted only. TaskStore later **confirms** by
    calling `steer_task/3` again with the same control. Queued acceptance
    transfers responsibility to the executor; only an explicit `{:ok, mode}`
    from a confirmation call sets `delivered_at`.
  - `{:error, :unsupported}` — this executor cannot steer. Terminal.
  - `{:error, :not_delivered}` — positive nondelivery. When returned while
    confirming an accepted control, TaskStore clears accepted ownership and
    triggers a bounded same-ID replay (same `control_id`). When returned
    during initial delivery or replay delivery it is treated as a retryable
    operational error.
  - `{:error, :delivery_unknown}` — ambiguous delivery. Unsafe to retry or
    replay. TaskStore terminalizes the control as `"delivery_unconfirmed"`
    with a bounded diagnostic error, whether returned during initial delivery,
    confirmation, or replay.
  - `{:error, :cancelled}` — explicit cancellation. Same terminalization as
    `:delivery_unknown` with a distinct bounded error.
  - `{:error, term()}` — other operational errors (transport, timeout,
    not-ready). Retained by TaskStore as deferred controls for bounded retry.

  The same callback is used for initial delivery, confirmation, and replay.
  The `control_id` and steering payload (`message`, `sender_id`,
  `target_stage`, `sequence`) are stable across all calls for the same
  control; only bookkeeping fields (`status`, `delivery_mode`, `delivered_at`,
  `error`) may differ. Do not rely on the full control map being byte-for-byte
  identical across retries.
  """
  @callback steer_task(agent_id(), steering_control(), execution_context()) :: steering_result()

  @doc """
  Optionally finalize a successful configured executor result.

  TaskStore calls this only for a successful configured executor return, after
  terminal steering reconciliation. The callback is time-bounded separately
  from status and cancellation callbacks. An implementing executor uses it for
  mandatory terminal artifact retention and must preserve and return a
  JSON-clean result payload. An error, exit, or timeout makes the outer task
  fail. Explicit runner overrides do not invoke this callback.
  """
  @callback finalize_task(
              agent_id(),
              result_payload(),
              reconciled_steering_controls(),
              execution_context()
            ) :: {:ok, result_payload()} | {:error, term()}

  @doc """
  Optionally adopt a successful terminal task into a destination reference.

  TaskStore invokes this only for successful configured JSON-clean tasks, after
  terminalization and any configured `finalize_task/4` callback. The adoption
  request is a closed JSON object containing `destination_ref`. The callback
  must return the complete updated JSON-clean executor result; partial patches,
  structs, and non-JSON values are invalid. Explicit runner overrides do not
  invoke this callback.
  """
  @callback adopt_task(
              agent_id(),
              result_payload(),
              json_map(),
              execution_context()
            ) :: {:ok, result_payload()} | {:error, term()}

  @optional_callbacks task_status: 2,
                      cancel_task: 2,
                      steer_task: 3,
                      finalize_task: 4,
                      adopt_task: 4
end
