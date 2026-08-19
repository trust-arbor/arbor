# Coding Task Dispatch

Operator guide for the stable structured coding path via signed MCP
`arbor_dispatch_task`. Coding work is reviewable-change production, not
automatic merge or unattended authorization.

**First-run setup** (what the factory is, host/runtime/identity/worker
prerequisites, and a first packet): [SOFTWARE_FACTORY.md](./SOFTWARE_FACTORY.md).

**Council setup** (10 binding review seats, stock provider/model pairs,
and remapping for a new host): [COUNCIL_SETUP.md](./COUNCIL_SETUP.md).

**External MCP client setup:** principal-scoped tools (including this dispatch
path) require the stdio signing proxy, not bare HTTP/Bearer. See
[EXTERNAL_MCP_CLIENT.md](./EXTERNAL_MCP_CLIENT.md).

## Runtime and authentication boundary

The current OAuth coding worker is **Grok 4.6** (`worker.provider: "grok"`,
`worker.model: "grok-4.6"`). Do not select `grok-code-fast`; it is not the
reviewed coding model for this path. Grok does not implement ACP's dynamic
`session/set_config_option` method, so Arbor binds the model in the reviewed
launch command and independently attests the exact `--model grok-4.6` argument
before launch and reconnect. A different explicit Grok model fails before the
CLI starts; Arbor does not treat `Method not found` as successful model
selection.

Arbor launches each worker with a private, ephemeral runtime/config home rather
than the live Arbor home, and never reads or copies the operator's Grok login
state. Immediately before launch, reconnect, and every prompt, Arbor's live BEAM
refreshes a mode-`0600`, access-token-only xAI OAuth projection. Grok 0.2.118
consumes that file through the fixed external provider command
`/bin/cat "$ARBOR_GROK_AUTH_PAYLOAD_PATH"`; access and refresh tokens are absent
from argv and environment values.

Grok's external-provider implementation transiently writes the returned access
token to `auth.json`. After every ACP authentication, Arbor verifies that cache
is a bounded, single-link, mode-`0600` external-auth record whose credential
exactly matches the staged Arbor token, then removes both `auth.json` and
`auth.json.lock` before worker readiness or provider RPC. Unexpected cache
schema, token, path, mode, or link state fails closed. The projection is
re-authenticated and scrubbed before every initial or steered prompt, and the
remaining projection and runtime home are removed at session cleanup.

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

## Caller prerequisites

Dispatch has **two** independent authorization stages. Passing the first and
failing the second is the common first-run experience, and the failure arrives
after `arbor_dispatch_task` has already returned `ok: true`.

### 1. Dispatch authority

`arbor://agent/dispatch` (or the narrower agent-scoped
`arbor://agent/dispatch/<agent_id>`) with `:execute`. The task-control namespace
starts at `arbor://agent/task/read`; there is no registered
`arbor://agent/task/dispatch` URI. Without dispatch authority the tool call
itself is rejected.

### 2. Authority horizon — the caller must hold what the graph will use

Before execution, `AuthorityHorizon.preflight/1` derives the complete resource
set the compiled graph will touch — union of top-level node resources, nested
graph node resources, and the execution manifest's `capability_uris` — and
requires the **calling principal** to hold every one of them for the whole run.
Mid-run renewal is not accepted.

Missing any of them fails admission in `preflight` with:

```json
{"code": "authority_horizon_missing",
 "message": "authenticated_caller missing total_count=29; first=arbor://acp/tool",
 "remediation": "Grant permanent or horizon-covering capabilities for the listed resources"}
```

For the standard `coding-change-v1` graph that set includes `arbor://acp/tool`,
the `arbor://action/coding/*` family (workspace acquire/inspect/release/
committed_change/recovery_summary, review_tree read/search, review/submit,
reviewed_commit, reviewed_validation, worker_terminal/parse,
dependency_baseline/check, and design_checkpoint open/parse/capture/load/await),
the profile-selected validator through the reviewed wrapper's execution
dependencies, `arbor://action/git/commit`, `arbor://action/git/pr`,
`arbor://action/council/review`, `arbor://action/consensus/decide_review`, and
the `arbor://orchestrator/execute/*` handler URIs used by the graph. Do not rely
on a copied count: profile and graph changes alter the exact horizon.

Derive the exact set for a plan rather than copying this list — it changes with
the graph:

```elixir
{:ok, graph} = Arbor.Orchestrator.parse(File.read!("<task_dir>/coding-pipeline.dot"))
manifest = File.read!("<task_dir>/coding-compile-manifest.json") |> Jason.decode!()

{:ok, required} =
  Arbor.Orchestrator.CodingPlan.AuthorityHorizon.derive_required_resources(
    graph, manifest["execution_manifest"])
```

Grant them with `Arbor.Security.grant(principal: principal_id, resource: uri)`.

### 3. Automatic exact-task control lease (observation + control)

Successful public `arbor_dispatch_task` / `Orchestration.dispatch/3` uses a
**collision-safe, server-owned** sequence:

1. **Reject** any caller-selected `task_id` (public dispatch never accepts one).
2. **Reserve** a server-generated unguessable task identity in TaskStore
   (opaque owner-bound reservation token; not exposed on MCP).
3. **Commit** a durable capability-ID-free recovery marker via the
   `Arbor.Persistence` facade with backend acknowledgement **before** any
   grant (fail closed when durability is unavailable).
4. **Grant** the closed six-member **task-control lease** (least-risk order,
   `approval_answer` last).
5. **Activate** the reserved task with the token and closed lease scalar.

Operators do not select capability ids, cleanup code, reservation tokens, or
lease internals; those never appear in MCP responses, status projections, or
audit output. On TaskStore restart, durable markers are replayed through
store-owned workers calling `Arbor.Security.revoke_by_task/1` (not TTL-only
recovery). Marker delete may leave a stale marker (over-revoke OK) but must
never forget live authority.

| Kind | Exact URI | TTL |
|---|---|---|
| task read | `arbor://agent/task/read/<task_id>` | 30 days |
| approval read | `arbor://approval/read/task/<task_id>` | 24 hours |
| steer | `arbor://agent/task/steer/<task_id>` | 24 hours |
| cancel | `arbor://agent/task/cancel/<task_id>` | 24 hours |
| adopt | `arbor://agent/task/adopt/<task_id>` | 30 days |
| approval answer | `arbor://approval/answer/task/<task_id>` | 24 hours |

Every lease capability is exact-task in both its URI and `Capability.task_id`
scope, non-delegable (`delegation_depth: 0`), and unusable for sibling or
prefix-like task ids. Global forms (`arbor://agent/task/read`,
`arbor://approval/read`, agent-scoped ladders, etc.) remain as operator
break-glass fallbacks on the existing exact → agent → global authorization
ladders; they are **not** required for ordinary delegated operation of a task
you dispatched.

`arbor_list_pending_approvals` without a filter still requires global
`arbor://approval/read`. With an exact `task_id` filter, task-scoped
approval-read is tried first, then global compatibility; results are equality-
filtered so unrelated approvals are never disclosed.

Lifecycle (TaskStore-owned reconciled retirement; non-blocking at terminal
publication):

- **running** — all six retained
- **terminal** (success/fail/cancel, including runner owner death) — retires
  approval_read, approval_answer, steer, cancel; **task_read always survives**;
  adopt retained only for successful adoptable results
- **adoption settled** — adopt revoked
- **prune / final disposal** — remaining members (including task_read) revoked

Retirement is an explicit TaskStore reconciliation: phase members are moved into
an internal pending-retirement queue **before** the active lease is reduced
(recovery intent already durable from the pre-mint marker), then revoked under
store-owned attempt references with hard admission/worker deadlines, O(1)
task/monitor indexes, and bounded retry. Authority ids are never forgotten
merely because supervisor admission, a worker, or a revoke call failed;
exhausted work remains internally retained and retryable without exposing
capability ids. Exhausted retirement emits telemetry
`[:arbor, :agent, :task_control_lease, :retire_exhausted]` with measurements
`remaining_count` / `attempt_index` and redacted metadata
(`task_id`, `phase`, `generation`, `retrigger_count`, `last_error_class`) —
no capability ids; exhausted means retry budget spent while authority is
retained, not silent discard and not TTL-only recovery. Recovery obligation
capacity is enforced at **reserve** only so terminal retirement never drops
member ids. Terminal status/result publication does not wait on revoke I/O.
Operators never select capability ids, cleanup code, or lease internals; those
never appear in MCP responses, status projections, or audit output.

Approval-answer authorization uses exact-task scope first, then agent-scoped,
principal-scoped, and global compatibility break-glass.

There is no alternative task-result path: `arbor_status` has no task component.

### If a dispatch fails before you can read it

`arbor_dispatch_task` returns `ok: true` once the task is accepted; admission
failures happen afterwards. When reads are unauthorized, the terminal artifact
is still on disk:

```
<coding_pipeline_logs_root>/task-<sha256(task_id)>/coding-task-terminal.json
```

`Arbor.Orchestrator.coding_pipeline_logs_root/0` returns the root. That
directory also holds `coding-plan.json`, `coding-pipeline.dot`, and
`coding-compile-manifest.json` for the compiled run.

## Computing `work_packet_digest`

Do not hand-compute it. The canonical encoding is owned by
`Arbor.Contracts.Coding.WorkPacket`:

```elixir
{:ok, digest} = Arbor.Contracts.Coding.WorkPacket.digest(%{
  "version" => 1,
  "success_criteria" => ["..."],
  "non_goals" => [],
  "constraints" => [],
  "architecture_refs" => [],
  "required_evidence" => [],
  "checkpoint_policy" => "direct"
})
# => "sha256:966e9d…"
```

`digest/1` normalizes through `new/1` before hashing, so the map you pass must
be the same one you send in the plan. `canonical_bytes/1` returns the exact
bytes hashed if you need to verify externally. `sha256/1` is an alias.

## Pre-dispatch readiness

Call `arbor_coding_dispatch_readiness` **before** `arbor_dispatch_task` with the
**exact same** `agent_id`, structured `task` object, and optional positive
`timeout` you will later send to dispatch. The tool returns a point-in-time
readiness snapshot; it never creates a task, auto-grants capabilities, or
reserves task/workspace/lease state. Dispatch rechecks every authoritative gate.

```json
{
  "agent_id": "agent_...",
  "task": {
    "kind": "coding_change",
    "plan": {
      "version": 2,
      "task": "Implement the requested change with tests",
      "repo_root": "/absolute/path/to/repo",
      "worker": { "provider": "codex" },
      "work_packet": {
        "version": 1,
        "success_criteria": ["Implement the requested change with tests"],
        "non_goals": [],
        "constraints": [],
        "architecture_refs": [],
        "required_evidence": [],
        "checkpoint_policy": "direct"
      },
      "work_packet_digest": "sha256:15070222bcf40d76aecc100d459df6f873178037400e5dfe9e2f9802833ebdae"
    }
  },
  "timeout": 900000
}
```

Authorized responses are successful MCP envelopes (`ok: true`) whose
`readiness` report carries one of:

| Status | Meaning |
| --- | --- |
| `ready` | Planes required for admission look healthy at snapshot time |
| `degraded` | Admission may still succeed, but one or more planes report degraded health |
| `blocked` | At least one plane blocks admission (for example missing authority or template drift) |
| `error` | A plane projection failed; inspect plane diagnostics rather than treating it as a generic transport error |

Inspect `readiness.planes` (security, coordinator, exact_template, task_control,
executor) for plane-level diagnostics. Authentication failures, malformed
`task`/`timeout`, and facade/authorization failures are MCP errors (`isError:
true`), not false-green readiness reports. Because the result is a snapshot,
race conditions remain possible — always re-run readiness if the environment
changed, and treat dispatch as the authoritative recheck.

## Canonical payload

Dispatch with a signed MCP request using the **same** `task` (and `timeout`,
when present) already checked for readiness. The stable coding envelope is:

```json
{
  "agent_id": "agent_...",
  "task": {
    "kind": "coding_change",
    "plan": {
      "version": 2,
      "task": "Implement the requested change with tests",
      "repo_root": "/absolute/path/to/repo",
      "worker": { "provider": "codex" },
      "work_packet": {
        "version": 1,
        "success_criteria": ["Implement the requested change with tests"],
        "non_goals": [],
        "constraints": [],
        "architecture_refs": [],
        "required_evidence": [],
        "checkpoint_policy": "direct"
      },
      "work_packet_digest": "sha256:15070222bcf40d76aecc100d459df6f873178037400e5dfe9e2f9802833ebdae"
    }
  },
  "timeout": 900000
}
```

New plans use version **2**. Omitting `version` also selects version 2; it does
not opt into legacy behavior. Minimally required plan fields:

| Field | Notes |
| --- | --- |
| `task` | Non-blank work description |
| `repo_root` | Absolute repository path inside configured workspace roots |
| `worker.provider` | Worker provider id (for example `codex`) |
| `work_packet` | Canonical bounded work intent; high-risk classes require `checkpoint_policy: "design_required"` |
| `work_packet_digest` | Exact `sha256:` digest of the canonical packet |

Explicit version 1 remains readable and compilable for archived compatibility.
New high-risk version-1 dispatch is rejected before compilation or workspace
acquisition.

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
    "model": "grok-4.6",
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
the CrossApp validation action is capped at `5_400_000` ms for this plan, while
its sequential test stage remains independently hard-capped at `4_200_000` ms.
Both values are derived with `min(reviewed ceiling, budgets.wall_clock_ms)`.

The `cross_app` validation profile compiles three distinct budgets into
`coding_cross_app_validate`:

- `param.timeout` — per contained Mix child process, intensive Shell profile,
  hard maximum `1_200_000` ms (never widens the generic Shell ceiling)
- `param.test_stage_timeout` — aggregate sequential test-stage budget, reviewed
  hard maximum `4_200_000` ms (70 minutes) from the Actions facade, further
  bounded by `budgets.wall_clock_ms`
- `param.stage_timeout` — whole CrossApp validation-action budget across
  compile, xref, test-environment compile, and the test stage; reviewed hard
  maximum `7_800_000` ms, derived as three intensive child ceilings plus the
  aggregate test-stage ceiling, and further bounded by
  `budgets.wall_clock_ms`

Exact `*_test.exs` inventory is preserved (including slow and integration-tagged
files). Paths are partitioned into sequential batches of at most 5 exact files
per child under the existing argv-count and argv-byte ceilings; tags are never
excluded to fit a budget.

The optional top-level MCP dispatch `timeout` is an outer cancellation ceiling.
The executor uses the smaller of that value and `budgets.wall_clock_ms`, so a
larger dispatch timeout cannot extend an omitted or shorter plan budget. Omit
the outer timeout unless a deliberately shorter task-wide limit is required.

Ordinary string prompts and generic object tasks remain valid for non-coding
dispatch. This guide documents the coding envelope only.

## Working inside the task workspace

The worker's worktree contains **tracked files only** — no `deps/`, no
`_build/`. Running anything there naively fails with unresolved dependencies
(`joken`, `ecto_sqlite3`, and so on), and a pre-commit hook will report the
failure as *unformatted files* rather than as missing dependencies.

Point Mix at the canonical checkout's dependencies and give the workspace its
own build directory:

```bash
cd <task_worktree>

# Same prefix for all three gates — tests, formatting, and compilation.
MIX_DEPS_PATH=/absolute/path/to/canonical/arbor/deps \
MIX_BUILD_PATH=/private/tmp/arbor-<task-slug>-build \
  ./bin/mix test path/to/file_test.exs

MIX_DEPS_PATH=... MIX_BUILD_PATH=... ./bin/mix format --check-formatted
MIX_DEPS_PATH=... MIX_BUILD_PATH=... ./bin/mix compile --warnings-as-errors
```

Both variables are required, and three failure modes are worth knowing:

- **Do not share the canonical `_build`.** A worktree building into the parent's
  `_build` recompiles from an incomplete dependency-source projection and fails
  on missing include files (observed with `yamerl`). Always give the workspace
  its own `MIX_BUILD_PATH`.
- **Do not point `MIX_BUILD_PATH` at a bare temp directory that you then move
  or reuse across differently-shaped workspaces.** Dependency `priv` symlinks
  are relative to the worktree's `_build`/`deps` layout; breaking that surfaces
  as missing runtime assets rather than as an invalid cache.
- **Containerized validation needs the mount targets to exist.** Because the
  worktree ships without `deps/` or `_build/`, a read-only repository bind has
  no directory to mount them onto and fails with `errno 30`. Create the empty
  directories in the workspace before attaching the writable mounts.

The same environment is what pre-commit hooks need. A hook run without it
reports formatting failure for what is actually dependency-setup failure.

Sprint evidence: `voice-d2c-sprint-friction-and-orchestration-log.md` F-006
(recurred three times), F-021, F-065.

## Review profiles

`review_profile` selects what must happen to a candidate before it can be
committed. Valid values are exactly:

| Value | Meaning |
| --- | --- |
| `binding` | Multi-perspective council review produces a verdict that gates the commit |
| `human_required` | A human approval is required |
| `none` | No review stage |

`binding` is the normal choice for reviewable change production. Seat
providers and how to remap them: [COUNCIL_SETUP.md](./COUNCIL_SETUP.md).

### Binding review needs its own capabilities

A binding review compiles additional graph branches, and the **caller** must
hold their handler resources like any other part of the graph (see *Caller
prerequisites*). Observed in practice: a review reached the verdict stage and
failed because the signer lacked `arbor://orchestrator/execute/parallel`, and
then every review branch additionally required
`arbor://orchestrator/execute/llm_query`.

Do not infer these from node names — an inferred `.../compute` grant was wrong.
Derive them from the compiled graph with
`AuthorityHorizon.derive_required_resources/2`, exactly as for the main graph.
`arbor://action/council/review` and `arbor://action/consensus/decide_review` are
also required.

### The commit gate is authorization; the council is the reviewer

Two stages are easy to conflate, and they are budgeted separately:

| Stage | Node / action | Budget | What it asks |
| --- | --- | --- | --- |
| approval | `commit_change` / `coding_reviewed_commit` | `interaction_wait_ms`, reserve `approval_ms` | *may this agent commit?* |
| review | `review_change` / `council_review_change` | `review_ms` (180,000 ms desired, cycles 1..3) | *is this change good?* |

The order is `implement → validate → commit_change → council review →
route_validated_review`, and it is the **council** that decides whether a person
needs to look: its `tier_decision` routes to either `human_review` or
`auto_proceed`.

The commit gate calls `Arbor.Trust.authorize/4`. On `:authorized` it commits
with **no wait at all** ("unattended authorize"). It escalates to a person only
on `:pending_approval` — so whether a human is in the loop there is a function of
your trust policy for the commit resource, not of the plan.

Practical consequence: if you find yourself reading a full diff at the commit
prompt, note that the council has not reviewed yet. That prompt is asking
whether the agent may commit, not asking you to be the reviewer.

### Budgeting the operator wait

**Operator wait time is not its own budget — it is the remainder.** The approval
stage gets whatever is left of `budgets.wall_clock_ms` after the worker and
validation finish, minus a settlement reserve. There is a guaranteed floor
underneath (the worker is clamped to leave the tail), but it is small: the whole
tail — validation reserve, approval, council review, cleanup — is capped at 40%
of the wall clock, so at the 900,000 ms default all four stages share 360 s.

Measured on a real run with the default 900,000 ms wall clock:

| | |
| --- | --- |
| Worker + validation consumed | 470 s |
| Left for the approver | 363 s |
| Settlement reserve withheld | 72 s (`approval_completion_reserve_ms`) |

The approval was killed at `run_deadline - approval_completion_reserve_ms` with
`Action coding_reviewed_commit failed: approval timed out`. Six minutes was not
enough to read a 230-line diff, verify that a newly-stricter function head was
safe at its call sites, and re-run the changed tests.

The 363 s was **leftover, not a guarantee** — the worker happened to finish
early. Had it used its full budget, the wait would have collapsed toward the
floor, which under the tail split is a fraction of that.

Note the incentive runs backwards: the slower and more complex the change, the
less time remains at the gate — yet that is exactly the change most likely to
draw an escalation.

Do **not** try to buy operator time by re-slicing the tail. That was attempted
(`82ba95e00`) and reverted (`46f74fa2c`) because the budget it takes from is the
council's, and the council is the reviewer. Raise the wall clock instead.

If you expect an escalation at the commit gate — trust policy returns
`:pending_approval` for the commit resource, or the plan is human-gated
(`review_profile: "human_required"`, or `binding` where you intend to inspect
the candidate) — budget wall clock for **both** phases:

```json
{
  "budgets": {
    "wall_clock_ms": 5400000,
    "inactivity_timeout_ms": 600000
  }
}
```

`BudgetPolicy` caps the desired approval share at 300,000 ms, so a larger wall
clock buys at most five minutes of *guaranteed* wait — but it stops
implementation from eating the window entirely, and it also grows the council's
`review_ms` toward its own 180,000 ms desire.

Nothing is destroyed on timeout: the workspace is `retained` and the branch
`preserved` (24 h expiry), so a timed-out approval costs a worker run, not work.
The candidate can be reviewed offline and integrated manually.

`ReviewedCommit` also carries `@default_approval_timeout 60_000`, but that is a
fallback for non-DOT consumers; the compiled coding path does not use it.

### Reading a council verdict

Two known sharp edges when interpreting results:

- **Aggregate confidence may read `0.0` when it is actually unavailable.** A
  council can return a complete verdict — all perspectives reporting, all
  approvals, no blocking findings, `overall_score: 1.0` — with confidence
  projections at `0.0` because missing evidence is defaulted to numeric zero.
  Treat `0.0` confidence alongside an otherwise complete verdict as *unavailable*,
  not as measured zero, and check the per-perspective `reason_code` values.
- **A reviewer may abstain for protocol reasons rather than on the merits.** The
  ACP terminal protocol rejects multiple non-terminal calls, so a reviewer that
  tries to read repository context before its single verdict can abstain with
  `call_shape=multiple_non_terminal`. That is a lost perspective, not a
  judgement about the change.

Sprint evidence: F-040 (review authority), F-043 (terminal protocol abstention),
F-058 (confidence semantics).

## Status, result, and approvals

After dispatch:

1. Poll `arbor_task_status` with the returned `task_id` (includes
   `waiting_approval` when blocked on an approval).
2. Read the finished artifact with `arbor_task_result`.
3. List visible IRQs with `arbor_list_pending_approvals` and answer them with
   `arbor_answer_approval` when you have approval-answer authority.

The first two operations require task-read, listing requires approval-read, and
answering uses the scoped approval-answer ladder documented under *Caller
prerequisites*. These capabilities are independent even when the same caller
performs all four operations.

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
worker validation failure. Cross-app focused tests run **sequentially under one
shared absolute aggregate deadline**. Each Mix child is capped by
`min(intensive per-operation ceiling, remaining aggregate budget)`. Admission
starts the first reviewed batch whenever residual aggregate budget is
positive — per-batch timeout ceilings are **never** multiplied by batch count
as a predicted total duration.

A capacity handoff is emitted only when residual budget is exhausted
(`available_budget_ms == 0`):

- **structural** — residual is already 0 before the first child launches
- **runtime** — the shared deadline expires after a completed prefix, leaving
  an exact unstarted suffix

The workflow bypasses validation and total rework counters, closes the worker,
and retains the workspace. Live `validation[0].test.capacity_handoff` is schema
**v2**: a closed, bounded descriptor whose ordered batch labels, counts, and
SHA-256 digests bind the exact unstarted inventory without copying raw paths
into the terminal artifact and without encoding ceiling products as required
duration. An authorized operator or CI job can reconstruct paths from the
retained workspace and verify the digest chain. Callers that already read
historical schema-v1 handoffs (which recorded a product-bearing
`required_budget_ms`) can validate them with the explicit archive-only
verifier. Arbor does not currently expose an integrated terminal archive reader
for that helper; live normalize/finalize/write paths accept v2 only.

## Post-integration settlement

`arbor_adopt_task_change` settles an already integrated successful coding
result. It is deliberately not a Git merge command:

1. Inspect the terminal result and independently integrate the reviewed
   candidate into the intended destination by fast-forward, cherry-pick, squash,
   or the repository's normal merge system.
2. Call `arbor_adopt_task_change` with the original `task_id` and the destination
   ref that now contains the change.
3. Arbor proves ancestry or bounded patch equivalence, archives immutable
   adoption evidence, and retires only the exact task-owned workspace and
   branch resources.

Calling settlement before integration fails as not adopted. A slow proof may
return `settlement_status: "pending"` before ExMCP's fixed `tools/call`
deadline; poll `arbor_task_result` until its adoption evidence becomes settled
or failed. The mutation remains owned and exactly once inside `TaskStore`.
Repeating the same task, destination, and result fingerprint coalesces with that
owner; it does not start a second adoption.

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
4. Implementation turns parse the entire bounded terminal message through
   `coding_worker_terminal_parse`. It admits exactly one JSON object with
   `status` equal to `implemented` or `declined` and an optional bounded string
   `summary`; leading/trailing prose, extra objects, unknown fields, malformed
   JSON, invalid UTF-8, and oversized messages are typed protocol failures. The
   graph performs at most one **format-only** retry in the same ACP session and
   then inspects the workspace even if the second envelope is invalid. It never
   replays the implementation task, and worker status remains advisory.
5. Validation runs through `coding_reviewed_validation`, whose outer
   pipeline-internal action is automatic but whose compiler-pinned nested
   validator remains approval-gated. Approve executes that exact validator once
   with a fresh signed request; rework executes it zero times and routes the
   bounded request id/note into the existing same-session validation-rework
   path; deny executes it zero times and fails validation closed. The wrapper
   accepts only the closed profile-owned validator set and never treats an
   operator note as fabricated validation evidence. Compiler-owned Coding Plan
   v2 validation-rework prompts (direct, design-required, and
   `security_regression`) must retain structured validator feedback together
   with `{ctx.approval_note}` and `{ctx.approval_request_id}` so the same-session
   ACP worker prompt receives both; semantic preflight rejects rewrites that
   drop either approval-context placeholder.
6. Terminal verification adapts Engine checkpoint evidence fail-closed. The
   final context is usually flat (`validation.passed`, `validation.exit_code`,
   ...) plus ReviewedValidation's closed success-wrapper fields
   (`validation.interaction_outcome=""`, `validation.request_id`,
   `validation.note=""`) and an optional serialized transport at
   `validation.result`. `CodingTaskExecutor` supplies that complete flat map to
   `CandidateVerificationCore`, which peels **only** the success wrapper and
   then requires the exact compiler-pinned validator envelope for `default`,
   `cross_app`, or `security_regression`. Raw legacy validator results still
   adapt. Denied/rework control payloads never carry nested validator evidence;
   a full envelope fused with either outcome is forged and blocked. When flat
   nested fields are present, verification drops the transport duplicate
   without decoding it; a sole transport layer is byte-bounded before one
   `Jason.decode`, and nested `result` wrappers fail closed. The public task
   result omits the serialized transport duplicate while retaining the flat
   validator and wrapper fields. Malformed metadata, unknown extras, and
   candidate-tree drift remain blocked.

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
