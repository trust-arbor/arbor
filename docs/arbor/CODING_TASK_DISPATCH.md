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
reviewed coding model for this path. Grok does not implement ACP's dynamic
`session/set_config_option` method, so Arbor binds the model in the reviewed
launch command and independently attests the exact `--model grok-4.5` argument
before launch and reconnect. A different explicit Grok model fails before the
CLI starts; Arbor does not treat `Method not found` as successful model
selection.

Arbor launches each worker with a private, ephemeral runtime/config home rather
than the live Arbor home. When the
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

Generic task execution keeps this reuse behavior. A one-shot harness that is
about to remove a task worktree must first call
`Arbor.AI.acp_settle_task_sessions/3` for the exact task and agent. The pool
refuses checked-out matches, closes idle matches outside the pool GenServer,
and reports success only after every detached process is confirmed down. The
harness may settle and remove the workspace lease only after that receipt;
otherwise it retains the workspace and reports cleanup failure.

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

A nonpooled start, explicit resume, or fresh-recovery start must return a
bounded, nonblank provider session ID. The only valid empty provider ID is the
intentional pre-session handle returned by a new pooled worker before its first
prompt lazily creates the provider session.

For a canonical `validation_failed` result, the public `error` field may contain
the exact bounded binary failure reason emitted by the `validate` Engine node.
The Engine projection is capped at 32 failed nodes, 256-byte node ids, and
512-byte UTF-8 reasons; the coding facade consumes only the exact `validate`
entry and revalidates that bound. Raw action output, arbitrary outcome terms,
and unrelated node failures are not copied into the task result.

Provider account exhaustion is terminal for the current route, not evidence of
an uncertain ACP send. The compiled graph requests `delivery_receipt` mode on
both worker-send nodes. `acp_send_message` reports
`worker_provider_account_exhausted` only for a JSON-RPC `-32603` error with a
nested HTTP `402` or `403` and bounded provider text explicitly identifying
exhausted credits or a monthly spending limit. The graph preserves a stable,
bounded `failure_reason`, closes the worker, and settles the workspace without
opening a replacement session. Timeouts, disconnects, generic permission
failures, malformed payloads, and unrecognized provider errors retain the
existing error path and one-shot uncertain-send recovery. Callers that omit
`failure_mode` retain the original `{:error, reason}` action contract.

`validation_capacity_exceeded` is a distinct infrastructure handoff, not a
worker validation failure. It means the complete exact-file batch plan cannot
fit the reviewed aggregate validation budget, either before the first child or
after completed children consume the remaining budget. The workflow bypasses
validation and total rework counters, closes the worker, and retains the
workspace. `validation[0].test.capacity_handoff` is a closed, bounded descriptor
whose ordered batch labels and SHA-256 digests bind the exact unstarted
inventory without copying raw paths into the terminal artifact; an authorized
operator or CI job can reconstruct those paths from the retained workspace and
verify the digest chain.

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
   fresh work. Canonical terminal `no_changes` and `declined` release the
   workspace in `discard` mode: an invocation-owned worktree is removed, and
   the local branch is retired only when this invocation created that exact
   branch and its tip still equals the recorded base. Reused/pre-existing
   branches and uncertain provenance fail closed by preserving the ref. When
   a retained lifecycle marker cannot be deleted (persistence residue), the
   receipt reports `discard_pending` with `cleanup_residue`, never `discarded`.
   A preserved pre-existing branch with a successfully deleted marker is not
   residue — the terminal disposition is `discarded` with no `cleanup_residue`.
4. Worker prompts still request one valid terminal JSON object so resumed
   older graph artifacts that parse prose do not enter protocol-repair loops.
   The current graph ignores that prose for control.

### Terminal workspace and branch evidence

Terminal results retain the closed `artifacts.workspace_release` descriptor.
Its `workspace_release_status` is one of `retained`, `removed`, `discarded`,
or `discard_pending`. The closed, authority-free
`artifacts.branch_lifecycle` descriptor reports:

- `branch_status`: `preserved`, `retired`, or `pending`
- `cleanup_status`: `complete`, `retrying`, or `dormant`
- the exact cleanup retry count and limit, categorical failure (when any),
  and discard phase (when applicable)
- optional `evidence_ref` and `published_commit`

The artifact is canonical. Any compatibility duplicate at the top level must
agree with the corresponding artifact exactly. These descriptors expose no
raw failures, commands, workspace/task/principal identifiers, or mutation
authority. Adoption proof remains in immutable adoption/task evidence;
lifecycle evidence links only closed references and never becomes authority to
adopt, publish, or retry.

The read-only action
`coding_workspace_lifecycle_status` is available at
`arbor://action/coding/workspace/status`. It returns aggregate counts and
retry summaries, with categorical failures sorted deterministically, plus
journal status: `complete`, `degraded`, or `disabled`. It never returns IDs,
principals, paths, refs/OIDs, PIDs, commands, raw failures, or mutation
authority. The action remains available when the journal is degraded.

### Resumable branch audit

Run the read-only Phase 7 branch audit with:

```bash
./bin/mix arbor.coding.branches --repo /path/to/repo --destination main \
  --output /tmp/branch-audit.json --checkpoint /tmp/branch-audit.checkpoint
```

The audit is resumable. With `--output`, `--checkpoint` defaults to
`OUTPUT.checkpoint`; the checkpoint is an atomic `0600` file bound to the
exact repository, destination OID, branch OID, and proof-policy scope. Cached
successful proofs are progress hints and must be live-revalidated within the
normal proof budget before classification. Only exactly bound deterministic
preserve outcomes may be reused without proof work. Transient failures are
retried, progress is reported, and checkpoint writes use a bounded cadence.
Incomplete or uncertain proofs conservatively preserve the branch.

Git patch evidence is batched under the existing byte and deadline bounds. The
exit-137 amplification was fixed without increasing the 30-second proof
deadline.

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
