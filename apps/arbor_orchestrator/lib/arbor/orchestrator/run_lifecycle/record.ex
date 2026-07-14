defmodule Arbor.Orchestrator.RunLifecycle.Record do
  @moduledoc """
  Internal typed recovery/lifecycle record for current pipeline runs.

  Privacy by default: metadata only — IDs, status, timestamps, node names,
  durations, recovery pointers (`logs_root`, graph hash/path), and the
  non-secret `execution_principal` used for recovery credential matching.
  Never stores context, prompts, credentials, rich handler outputs,
  functions, or provider sessions.

  Identity and recovery-pointer fields are **invariants**: they must not be
  silently truncated or substituted. Writers validate exact values and
  reject invalid/oversized inputs.

  `spawning_pid` is **runtime-only** (never durably serialized). Durable
  payloads use node/owner metadata plus heartbeat timestamps for liveness.
  """

  use TypedStruct

  @type status ::
          :running
          | :completed
          | :failed
          | :abandoned
          | :suspended
          | :delegated
          | :interrupted
          | :degraded
          | :recovering
          | :unknown

  typedstruct enforce: true do
    field(:run_id, String.t())
    field(:pipeline_id, String.t())
    field(:graph_id, String.t() | nil, default: nil, enforce: false)
    field(:status, status(), default: :running)
    field(:total_nodes, non_neg_integer(), default: 0)
    field(:completed_count, non_neg_integer(), default: 0)
    field(:completed_nodes, [String.t()], default: [])
    field(:current_node, String.t() | nil, default: nil, enforce: false)
    field(:node_durations, %{String.t() => non_neg_integer()}, default: %{})
    field(:started_at, DateTime.t() | nil, default: nil, enforce: false)
    field(:finished_at, DateTime.t() | nil, default: nil, enforce: false)
    field(:duration_ms, non_neg_integer() | nil, default: nil, enforce: false)
    field(:failure_reason, term(), default: nil, enforce: false)
    field(:owner_node, atom() | String.t() | nil, default: nil, enforce: false)
    field(:source_node, atom() | String.t() | nil, default: nil, enforce: false)
    field(:origin_trust_zone, term(), default: nil, enforce: false)
    field(:last_heartbeat, DateTime.t() | nil, default: nil, enforce: false)
    field(:last_ets_sync, DateTime.t() | nil, default: nil, enforce: false)
    # Recovery pointers (bounded metadata, not executable content) — invariants
    field(:graph_hash, String.t() | nil, default: nil, enforce: false)
    field(:dot_source_path, String.t() | nil, default: nil, enforce: false)
    field(:logs_root, String.t() | nil, default: nil, enforce: false)
    # Non-secret principal identity for recovery credential matching (never a credential)
    field(:execution_principal, String.t() | nil, default: nil, enforce: false)
    # Runtime-only — never written to durable backends
    field(:spawning_pid, pid() | nil, default: nil, enforce: false)
  end
end
