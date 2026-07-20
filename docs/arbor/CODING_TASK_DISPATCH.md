# Coding Task Dispatch

Operator guide for the stable structured coding path via signed MCP
`arbor_dispatch_task`. Coding work is reviewable-change production, not
automatic merge or unattended authorization.

**External MCP client setup:** principal-scoped tools (including this dispatch
path) require the stdio signing proxy, not bare HTTP/Bearer. See
[EXTERNAL_MCP_CLIENT.md](./EXTERNAL_MCP_CLIENT.md).

## Runtime and authentication boundary

The current OAuth coding worker is **Grok 4.5** (`worker.provider: "grok"`,
`worker.model: "grok-4.5"`). Do not select `grok-code-fast`; it is not the
reviewed coding model for this path. Arbor launches each worker with a private,
ephemeral runtime/config home rather than the live Arbor home. When the
isolated Grok home is first created, Arbor stages only the bounded OAuth
`auth.json` credential into it, preserves mode `0600`, and removes the runtime
home at session cleanup. Authentication staging is not a general-purpose copy
of the operator's configuration directory.

Managed, repository, and plugin MCP discovery is disabled for Grok sessions.
That includes ambient repository files and directories such as `.mcp.json`,
`.grok/config.toml`, `.cursor/mcp.json`, `.grok/plugins`, and
`.claude/plugins`. The only MCP endpoint a session may use is the explicit
Arbor-bound endpoint supplied at session creation. MCP registration is
immutable for the session lifetime and cannot be widened by a later create,
load, resume, or tool call.

The attested Grok profile is an Arbor-owned file with mode `0600`. It exposes
native `read_file`, `search_replace`, `grep`, and `list_dir` tools and denies
`run_terminal_cmd`, `task`, `get_task_output`, and `kill_task`. This profile is
an execution boundary, not a prompt suggestion: launch verification fails
closed if the file, content, mode, command, or isolated home does not match.

## Workspace and Git binding

The plan's `repo_root`, workspace policy, and worker `cwd` are explicit
bindings. They are checked as canonical paths before launch and must remain
consistent through implementation, validation, review, and release. A provider
conversation can continue only when the plan explicitly supplies
`resume_provider` and `resume_session_id`; provider-session continuity does
not imply workspace continuity. A resumed provider session in a new worktree
must not be described as retaining the old worktree, and a missing provider
session may recover only through the documented single fresh-conversation
fallback.

For linked worktrees, the Grok boundary permits the Git common directory only
when the worktree's `.git` metadata resolves to the repository's exact
`--git-common-dir`. The worker's Git environment sets `GIT_OPTIONAL_LOCKS=0`.
This is a narrowly scoped read exception for the validated common directory;
it does not authorize writes, hook execution, arbitrary paths, or sibling
worktrees. Because repository config and hook files live under the common
directory, they are readable metadata inside that exception even though the
worker cannot execute or mutate them.

The owner observes approvals and cancellation. Poll status and pending
approvals through the task-scoped MCP tools, answer only approvals whose
provenance and authority match the task owner, and treat cancellation as a
hard lifecycle operation with bounded worker/resource cleanup. Worker prose,
terminal JSON, provider session identifiers, and a returned cancellation request
are advisory evidence; the owner-observed task/workspace state is authoritative.

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

**Pool reuse is task-scoped and fail-closed.** Managed checkout goes through
`Arbor.AI.acp_checkout/2` into `Arbor.AI.AcpPool`, which matches only on a full
`Arbor.AI.AcpPool.SessionProfile`. **Matching identity fields** (must all agree
for reuse):

| Identity field | Role |
| --- | --- |
| `task_id` | Coding task scope — different tasks never share a pool entry |
| `cwd` | Canonical session working directory |
| `model` | Explicit model override (or absence of one) |
| agent / principal | Owning agent identity |
| workspace plan | Structured form when supplied (see below) |
| tool workspace scope | Binary tool-workspace binding |
| tools / trust domain | Tool modules and trust domain |
| startup fingerprint | Immutable startup configuration digest |

The same coding task may reuse a compatible local `AcpSession` process. A
different task must never inherit a prior task's provider conversation, terminal
cwd, workspace plan, or ToolServer/MCP endpoint merely because an idle pooled
process exists. One-shot steering such as `cd NEW_WORKTREE` is not a workspace
rebind.

This is **session continuity**, not workspace continuity: reuse or explicit
provider resume never changes the owner, run authorization, task binding, or
canonical workspace selected by the new dispatch.

**Structured workspace forms on checkout.** `Arbor.AI.acp_checkout/2` accepts
`:workspace` as either a binary path (legacy cwd/ToolServer alias) or a
structured session plan:

- `{:directory, path}` — bind the session to that absolute directory
- `{:worktree, opts}` — bind to a worktree plan (opts are provider-owned;
  identity is the normalized plan, not a free-form string)

These structured forms participate in `SessionProfile` matching; they are not
advisory metadata.

**Cross-task provider continuity is explicit only.** To continue a prior
provider conversation, set both `resume_provider` and `resume_session_id`. That
path mints a fresh local session/process for the new task, then loads the named
provider conversation; it is never satisfied by silently reusing another task's
idle pool entry. Omitting resume fields always starts a new provider conversation
for the new task.

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
    "model": "grok-4.5",
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

The compiler maps `resume_session_id` only to `acp_start_session.session_id`
on the initial `open_worker` node. It does not replace the Engine session, task
principal, signer, or verified run authorization. Pool affinity never bypasses
profile compatibility: an incompatible affinity key returns a conflict, and a
busy same-affinity checkout returns busy rather than minting a duplicate session.

### Resume unavailable → one fresh-conversation recovery

When the reviewed plan supplies a non-nil `worker.resume_session_id`, the
compiler also sets
`param.fallback_to_fresh_on_resume_unavailable=true` on initial `open_worker`
(and always on `open_recovery_worker`). Ordinary fresh starts omit that flag.
Semantic preflight binds the flag exactly to `worker_resume_session_id`:
required `true` for explicit resume, absent otherwise; forged enable/disable
fails closed.

At runtime, `Arbor.Actions.Acp.StartSession` calls
`Arbor.AI.acp_managed_start_session/2`. If resume was requested, the flag is
true, and `Arbor.AI.classify_resume_unavailability/1` returns
`:resume_unavailable`, StartSession retries **exactly once** without
`session_id` (`create_session: true`), starts a new provider conversation, and
reports:

| Result field | Fresh-recovery value |
| --- | --- |
| `continuity` | `"fresh_recovery"` |
| `session_id` | Replacement provider conversation id |
| `worker_session_id` | New managed handle |

Exact structural resume-unavailable evidence (message/detail text is **never**
inspected):

- `{:unsupported_capability, :load_session}`
- string-keyed wire error `"code" => -32002`
- string-keyed JSON-RPC `"code" => -32603` with nested
  `"data" => %{"code" => "FS_NOT_FOUND"}` (provider session path gone — e.g.
  Grok resume against a newly allocated worktree)

Generic `-32603`, auth, transport, timeout, rate-limit, and atom-keyed
lookalikes stay `:not_resume_unavailable` and do **not** retry. The public
task result still surfaces the replacement `worker_provider_session_id` for a
later explicit resume; Git worktree continuity remains a separate invariant.

Optional reviewed selectors on the plan:

- `task_class` - workload class; must agree with the executable validation
  profile when the compiler requires that binding
- `validation_profile` - reviewed validation profile id
- `review_profile` - reviewed review profile id (`binding`, `human_required`)

Versioned plans are closed at every object boundary. Workspace fields belong
under `workspace_policy`; a top-level `branch_name` is part of the legacy flat
envelope and is rejected in a direct plan. Omit `branch_name` to let Arbor
generate it:

```json
{
  "workspace_policy": {
    "mode": "isolated",
    "branch_name": "feature/reviewable-change"
  }
}
```

Budgets also belong inside the plan. `budgets.wall_clock_ms` bounds the whole
compiled coding graph, including implementation, validation, review, approval,
and rework nodes. It defaults to 900,000 ms. For a deliberately longer
cross-app run, set both graph liveness bounds explicitly:

```json
{
  "task_class": "cross_app",
  "validation_profile": "cross_app",
  "review_profile": "binding",
  "budgets": {
    "wall_clock_ms": 5400000,
    "inactivity_timeout_ms": 600000
  }
}
```

A `5_400_000` ms (90 minute) plan wall clock leaves bounded headroom for
compile, xref, test-environment compile, review, and related non-test stages;
the sequential test stage remains hard-capped at `4_200_000` ms via
`min(aggregate ceiling, budgets.wall_clock_ms)`.

The `cross_app` validation profile compiles two distinct budgets into
`coding_cross_app_validate`:

- `param.timeout` — per contained Mix child process, intensive Shell profile,
  hard maximum `1_200_000` ms (never widens the generic Shell ceiling)
- `param.test_stage_timeout` — aggregate sequential test-stage budget, reviewed
  hard maximum `4_200_000` ms (70 minutes) from the Actions facade, further
  bounded by `budgets.wall_clock_ms`

Exact `*_test.exs` inventory is preserved (including slow and integration-tagged
files). Paths are partitioned into sequential batches of at most 20 exact files
per child under the existing argv-count and argv-byte ceilings; tags are never
excluded to fit a budget.

The optional top-level MCP dispatch `timeout` is an outer cancellation ceiling.
The executor uses the smaller of that value and `budgets.wall_clock_ms`, so a
larger dispatch timeout cannot extend an omitted or shorter plan budget. Omit
the outer timeout unless a deliberately shorter task-wide limit is required.

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

For a canonical `validation_failed` result, the public `error` field may contain
the exact bounded binary failure reason emitted by the `validate` Engine node.
The Engine projection is capped at 32 failed nodes, 256-byte node ids, and
512-byte UTF-8 reasons; the coding facade consumes only the exact `validate`
entry and revalidates that bound. Raw action output, arbitrary outcome terms,
and unrelated node failures are not copied into the task result.

## Default execution path

Structured `coding_change` dispatch runs the **compiled DOT pipeline** by
default (`Arbor.Orchestrator.CodingTaskExecutor`). The plan is normalized,
compiled to an immutable graph, archived with a compile manifest, and executed
under the target agent's identity and capabilities.

### Owner-observed outcomes (worker prose is advisory)

The DOT coding graph (`coding-change-v1`) decides `no_changes`, validation,
review, and commit routing from **owner-observed workspace state**, not from
worker narrative or terminal JSON:

1. Every successful ACP send must report an explicit trusted
   `stop_reason == "end_turn"`. Values such as `max_tokens`, `cancelled`,
   blank, or missing route to `pipeline_error`, retain the workspace, and
   close/check in the worker. The action layer does **not** default a missing
   stop reason to `end_turn`.
2. After a trusted end_turn, `coding_workspace_inspect` must see
   `exists == true`. A missing worktree is `pipeline_error` with retention —
   never `no_changes`.
3. Progress is measured against a bounded workspace fingerprint captured
   immediately before **each** implement/rework send (not only the lease base).
   The digest binds HEAD, staged index identities, and actual content/metadata
   for every changed or untracked path; Git status text alone is not sufficient.
   Inspection fails closed on command, read, race, or configured bound errors.
   Initial no-op => `no_changes`. Rework no-op => `pipeline_error`
   (`worker_turn_no_progress`) so a prior candidate is not re-presented as
   fresh work.
4. Worker prompts still request one valid terminal JSON object so resumed
   older graph artifacts that parse prose do not enter protocol-repair loops.
   The current graph ignores that prose for control.
5. The shared `STATUS: declined` contract remains on the legacy direct
   `coding_produce_reviewable_change` path only.

### ACP transcript artifact

When the coding executor binds its trusted transcript sink, `AcpSession`
appends one record for every prompt it actually sends to the provider. This
includes the action's initial prompt and each queued same-session task-control
follow-up that the session starts internally. Records are written to the
task-owned transcript file under the coding pipeline logs root:

```
<coding_pipeline_logs_root>/task-<sha256(task_id)>/acp-transcript.json
```

Each turn records:

- a bounded text projection of the prompt, with its original byte count,
  truncation flag, and SHA-256
- prompt kind and task-control ID, when applicable
- terminal status plus bounded response, stop-reason, and error facts
- provider / provider-session continuity scalars (observational only)
- the latest bounded normalized streaming updates captured at the ACP
  source (not reconstructed from final prose)
- the Engine-owned action execution ID and deterministic per-prompt capture
  index used for idempotent retry/resume publication

Success, provider error, hard timeout, inactivity timeout, callback timeout,
prompt/client death, and cancellation terminal paths capture the evidence
available at that observation boundary after provider handling. Bounded
projection happens before transcript retention and persistence: retained turn
count, prompt/response/error bytes, retained stream-event count, per-event
bytes, identity count, and aggregate artifact bytes. These artifact limits do
not claim to bound provider, client, or session-wide accumulation. Retention
keeps the latest events and latest turns; seen/retained/omitted counts make
truncation explicit. The file is mode `0600`, published atomically, and digests
its canonical body.

When the runner returns a normalized terminal result, including a later
validation or review failure, the public task result (`arbor_task_result`)
exposes only a bounded descriptor under `artifacts.acp_transcript`:

| Field | Meaning |
| --- | --- |
| `path` | Absolute path to `acp-transcript.json` |
| `sha256` | Digest of the canonical transcript body |
| `byte_size` | On-disk size |
| `turns_retained` | Turns currently retained in the bounded artifact |
| `turns_seen` / `turns_omitted` | Unique captured identities observed and omitted |
| `turns_truncated` / `aggregate_truncated` | Explicit truncation flags |
| `schema_version` | Closed schema id (`1`) |
| `task_id` | Exact task binding verified by the store |

Inline transcript content never appears in the task result or Engine context.
The descriptor is evidence for post-mortem inspection and fresh-session recovery
planning; it does **not** silently replay prompts or grant provider-session
authority. If the sink fails or misses its monitored deadline, the ACP send
fails closed with an explicit durability error rather than claiming success.
That evidence failure does not override prompt lifecycle: cancellation still
tears down the session, and hard/inactivity timeout still enters
`recovery_required` and runs provider-cancellation settlement.

Owner cancellation or process-level runner loss can prevent any normalized
result from returning, so no descriptor can be attached through that result
path even when source capture already persisted the file. In that case the
deterministic task-root path shown above remains the post-mortem lookup.

### Terminal task evidence artifact

Completed coding results expose only the bounded descriptor under
`artifacts.task_evidence`; public results never include the evidence body. The
task-owned private JSON artifact is mode `0600` and contains references to the
plan, DOT graph, and their hashes, plus reconciled steering history, bounded
validation outputs, and the review verdict.

This artifact is post-mortem and audit evidence. It is not execution authority,
does not grant approval or replay capability, and does not claim that
`TaskStore` state or queued controls survive a BEAM restart.

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
