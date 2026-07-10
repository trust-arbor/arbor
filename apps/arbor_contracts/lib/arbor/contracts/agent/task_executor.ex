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
  assigned by TaskStore and the original JSON-clean execution context. It may
  report immediate delivery, accepted queued delivery, or terminal unsupported.
  Queued acceptance transfers responsibility for later delivery to the executor;
  a successful `run/3` return confirms all accepted controls have settled.
  Operational errors are retained by TaskStore as deferred controls for bounded
  retry. Explicit runner overrides report steering as unsupported.

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

  @typedoc "Result of accepting a task steering control."
  @type steering_result ::
          {:ok, steering_delivery_mode()}
          | {:ok, :queued, steering_delivery_mode()}
          | {:error, :unsupported | term()}

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
  timestamp fields. Return `{:ok, mode}` once delivered, or
  `{:ok, :queued, mode}` after the executor has durably accepted responsibility
  for later delivery. Queued acceptance transfers responsibility to the executor,
  so TaskStore does not invoke this callback again for that control; a successful
  `run/3` return confirms accepted controls have settled. Return
  `{:error, :unsupported}` when this executor cannot steer the task. Other errors
  are treated as retryable operational failures by TaskStore.
  """
  @callback steer_task(agent_id(), steering_control(), execution_context()) :: steering_result()

  @optional_callbacks task_status: 2, cancel_task: 2, steer_task: 3
end
