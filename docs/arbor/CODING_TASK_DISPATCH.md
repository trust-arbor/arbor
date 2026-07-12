# Coding Task Dispatch

Operator guide for the stable structured coding path via signed MCP
`arbor_dispatch_task`. Coding work is reviewable-change production, not
automatic merge or unattended authorization.

## Canonical payload

Dispatch with a signed MCP request. The stable coding envelope is:

```json
{
  "agent_id": "agent_...",
  "task": {
    "kind": "coding_change",
    "plan": {
      "version": 1,
      "task": "Implement the requested change with tests",
      "repo_root": "/absolute/path/to/repo",
      "worker": { "provider": "codex" }
    }
  }
}
```

Plan version is **1**. Minimally required plan fields:

| Field | Notes |
| --- | --- |
| `task` | Non-blank work description |
| `repo_root` | Absolute repository path inside configured workspace roots |
| `worker.provider` | Worker provider id (for example `codex`) |

Reviewed coding plans use the ACP pool by default (`worker.use_pool: true`).
The workflow returns a pooled process after use while invalidating its
per-run managed handle.
The worker object also accepts:

- `model` - explicit provider model override
- `permission_mode` - reviewed adapter mode (`default` or `deny`)
- `use_pool` - boolean; set `false` only when a fresh managed process is required
- `resume_provider` - provider that issued `resume_session_id`; required with it
- `resume_session_id` - non-blank provider conversation ID returned by an
  earlier coding task; required with `resume_provider`

For example, to continue the provider conversation from an earlier task while
keeping the new task's authorization and execution identity independent:

```json
{
  "worker": {
    "provider": "grok",
    "model": "grok-code-fast",
    "use_pool": true,
    "resume_provider": "grok",
    "resume_session_id": "provider-session-id-from-prior-result"
  }
}
```

`resume_provider` must match `worker.provider` exactly. Both resume fields are
required together, and the plan is rejected before compilation if either is
missing or the providers differ. Arbor never infers a provider from opaque
session ID text.

The compiler maps `resume_session_id` only to `acp_start_session.session_id`.
It does not replace the Engine session, task principal, signer, or verified run
authorization.

Optional reviewed selectors on the plan:

- `validation_profile` - reviewed validation profile id
- `review_profile` - reviewed review profile id (`binding`, `human_required`)

Ordinary string prompts and generic object tasks remain valid for non-coding
dispatch. This guide documents the coding envelope only.

## Status, result, and approvals

After dispatch:

1. Poll `arbor_task_status` with the returned `task_id` (includes
   `waiting_approval` when blocked on an approval).
2. Read the finished artifact with `arbor_task_result`.
3. List visible IRQs with `arbor_list_pending_approvals` and answer them with
   `arbor_answer_approval` when you have approval-answer authority.

Approvals stay human-visible and capability-gated. Dispatch does **not** grant
merge authority or unattended authorization.

Successful results and failures reached after worker startup may include both
`worker_session_id` and `worker_provider_session_id`, plus `worker_provider`.
The former ID is an opaque managed handle retained for compatibility and is no
longer usable after the workflow closes it. To resume later, copy
`worker_provider` to `worker.resume_provider` and
`worker_provider_session_id` to `worker.resume_session_id`; keep
`worker.provider` equal to that provider. The later dispatch must pass normal
authorization again. Provider-session continuity does not currently reuse the
retained Git worktree automatically.

## Default execution path

Structured `coding_change` dispatch runs the **compiled DOT pipeline** by
default (`Arbor.Orchestrator.CodingTaskExecutor`). The plan is normalized,
compiled to an immutable graph, archived with a compile manifest, and executed
under the target agent's identity and capabilities.

## Rollback (legacy executor)

Rollback is operator-only, temporary for **one release window**, and selected
before process startup; never by task payload:

```bash
export ARBOR_CODING_EXECUTOR=legacy
# then start the Arbor node / release
```

Unset or `pipeline` keeps the default DOT path. Runtime config stores the raw
operator value without loading optional umbrella child modules; `arbor_agent`
validates it before starting children. Invalid selector values fail agent
startup (fail closed), while lower-level apps remain independently bootable.

The legacy executor (`Arbor.Agent.Orchestration.LegacyCodingTaskExecutor`):

- accepts **only** the strict flat `coding_change` envelope
  (`kind`, `task`, `repo_path`, `acp_agent`, plus a small optional flat set);
- **rejects** versioned `plan` objects;
- **rejects** non-default / profile fields (`review_profile`, `profile`, ...);
- invokes `coding_produce_reviewable_change` for compatibility.

Do not nest the composite action inside a structured `coding_change` pipeline
run. Prefer the structured plan envelope unless you are deliberately on the
legacy rollback path.
