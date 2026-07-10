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

Unset or `pipeline` keeps the default DOT path. Invalid selector values fail
startup (fail closed).

The legacy executor (`Arbor.Agent.Orchestration.LegacyCodingTaskExecutor`):

- accepts **only** the strict flat `coding_change` envelope
  (`kind`, `task`, `repo_path`, `acp_agent`, plus a small optional flat set);
- **rejects** versioned `plan` objects;
- **rejects** non-default / profile fields (`review_profile`, `profile`, ...);
- invokes `coding_produce_reviewable_change` for compatibility.

Do not nest the composite action inside a structured `coding_change` pipeline
run. Prefer the structured plan envelope unless you are deliberately on the
legacy rollback path.
