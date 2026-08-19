# Software Factory

Operator setup guide for Arbor's reviewed coding factory. Created 2026-08-19.

The factory is how Arbor builds itself: a signed, compiled `coding_change`
run that isolates a worktree, delegates implementation to a bounded ACP
worker, validates the candidate, optionally runs a binding council, and
returns a reviewable change. It does **not** merge, and it does **not**
unattended-authorize.

This document is the factory first-run path. For a fresh clone (mise, SQLite,
free OpenRouter, `arbor.start`, conversationalist) see
[QUICKSTART.md](../QUICKSTART.md). Cloud/onboarding caveats live there — keep
`AGENTS.md` as the `CLAUDE.md` symlink.

The payload contract, authority horizon, budgets, resume rules, and
terminal evidence live in [CODING_TASK_DISPATCH.md](./CODING_TASK_DISPATCH.md).
MCP identity wiring lives in [EXTERNAL_MCP_CLIENT.md](./EXTERNAL_MCP_CLIENT.md).
Checkpoint HMAC identity lives in [IDENTITY.md](./IDENTITY.md). Binding council
seats and provider remaps live in [COUNCIL_SETUP.md](./COUNCIL_SETUP.md).

## What the factory is

A factory run is one structured task:

```json
{
  "kind": "coding_change",
  "plan": {
    "version": 2,
    "task": "...",
    "repo_root": "/absolute/path/to/repo",
    "worker": { "provider": "grok", "model": "grok-4.6" },
    "work_packet": { "...": "..." },
    "work_packet_digest": "sha256:..."
  }
}
```

Arbor normalizes that plan, compiles it to the reviewed `coding-change-v1`
DOT graph, archives the compile manifest, and executes it under the target
agent's identity. Progress is owner-observed workspace state, not worker
prose.

Typical stages:

1. Acquire an isolated worktree (tracked files only; no `deps/` or `_build/`).
2. Open a Grok 4.6 ACP worker with file tools only (`read_file`,
   `search_replace`, `grep`, `list_dir`). Shell, task spawn, and ambient MCP
   are denied.
3. Implement. The worker must return exactly one JSON object:
   `{"status":"implemented"|"declined","summary":"..."}`.
4. Validate through the reviewed wrapper. Nested validators stay
   approval-gated.
5. Binding council review (default) decides `human_review` vs `auto_proceed`.
6. Optionally commit. Merge remains a human Git operation. Settlement is a
   later `arbor_adopt_task_change` call.

## Roles

Three identities are easy to confuse. Keep them separate.

| Role | What it is | What it is not |
| --- | --- | --- |
| **Caller / operator principal** | The Ed25519 identity in the MCP signing-proxy key file. Resolved from the per-request signature. Holds dispatch authority and the authority horizon. | Not an argument you pass as `agent_id`. |
| **Coordinator agent** | A running Arbor agent that *owns* the compiled graph (`mix arbor.agent start coding_agent ...`). Its id is the `agent_id` you dispatch to. | Not `coding_default_acp_agent`. That config key is a provider name. |
| **ACP worker** | An ephemeral Grok (or other reviewed provider) process launched inside the task worktree. | Not the coordinator. Provider-session continuity is not workspace continuity. |

Dispatch has two independent authorization stages:

1. **Dispatch authority** — caller holds `arbor://agent/dispatch` (or the
   narrower `arbor://agent/dispatch/<agent_id>`) with `:execute`.
2. **Authority horizon** — caller already holds every resource the compiled
   graph will touch for the whole run. Mid-run renewal is not accepted.
   Missing any of them fails later as `authority_horizon_missing` even when
   `arbor_dispatch_task` already returned `ok: true`.

On successful public dispatch, Arbor mints a six-member exact-task control
lease (read, approval-read, steer, cancel, adopt, approval-answer). You do
not pick capability ids or the `task_id`.

## Prerequisites

### Host

- macOS or Linux with the repo's pinned toolchain (`.tool-versions`; run
  Mix only through `./bin/mix`).
- A clean clone of the Arbor umbrella you intend to change. That path must
  sit inside the configured coding repo roots.
- Disk space for isolated worktrees. In `MIX_ENV=dev`, Arbor creates
  `$TMPDIR/arbor-coding-worktrees` automatically.

### Arbor runtime

- `./bin/mix arbor.setup` has been run at least once.
- The server is up: `./bin/mix arbor.start`. Gateway MCP listens on
  `http://localhost:4000/mcp`. The dashboard (and Tidewave, in dev) listen
  on `http://localhost:4001`.
- Persistence is healthy enough to ack the pre-grant recovery marker.
  Dispatch fail-closes when durability is unavailable.

### Coding roots

Dev defaults (see `config/dev.exs` and `config/runtime.exs`):

- `coding_repo_roots` — the umbrella source root.
- `coding_worktree_roots` — `$TMPDIR/arbor-coding-worktrees`.

Override with `ARBOR_CODING_REPO_ROOTS` and `ARBOR_CODING_WORKTREE_ROOTS`
(comma-separated absolute paths). Production has no implicit roots; missing
or invalid roots block admission. Do not set
`workspace_policy.worktree_base_dir` to an arbitrary `/tmp/...` path — that
fails `coding_path_outside_roots`.

### Operator identity

A registered Ed25519 agent key, mode `0600`, in one of:

- the dashboard-issued `.arbor.key` from **Settings → external agents**
- `~/.arbor/identity.key` (see [IDENTITY.md](./IDENTITY.md))

The signing proxy uses this key. Arbor does not accept a caller-supplied
`agent_id` as proof of identity.

### Coordinator agent

A running agent created from the `coding_agent` template (or an equivalent
that already holds the coding-action capability set in
`apps/arbor_agent/priv/templates/coding_agent.md`):

```bash
./bin/mix arbor.agent start coding_agent --name factory-coordinator
./bin/mix arbor.agent
```

Copy the printed `agent_...` id. That is the only valid `agent_id` for
dispatch.

### Caller grants

Grant at least dispatch, then derive and grant the horizon. Do not copy a
URI count from an old session — profile and graph changes alter the set.

```elixir
caller = "agent_<caller_from_key_file>"
target = "agent_<coordinator>"

{:ok, _} = Arbor.Security.grant(principal: caller, resource: "arbor://agent/dispatch")

# After you have a plan JSON on disk (see First run):
plan_path = "/tmp/factory-first-run.json"
task = Jason.decode!(File.read!(plan_path))
{:ok, graph} =
  Arbor.Orchestrator.parse(
    File.read!("apps/arbor_orchestrator/priv/pipelines/coding-change-v1.dot")
  )

# Prefer deriving from a compiled plan + execution_manifest when you have one.
# First-run shortcut: grant the coding_agent template URIs to *both* caller
# and coordinator, then let readiness name anything still missing.
```

The coordinator also needs the template capabilities; `mix arbor.agent start
coding_agent` requests them at creation. If readiness later reports
`authority_horizon_missing`, grant the named URI to the **caller** (horizon
is a caller check) and confirm the coordinator still holds the matching
execution grant.

### Grok worker OAuth

The reviewed coding worker is **Grok 4.6** (`worker.provider: "grok"`,
`worker.model: "grok-4.6"`). Do not select `grok-code-fast`.

Arbor never copies the operator's interactive Grok login. Immediately
before launch it projects an Arbor-owned, mode-`0600`, access-token-only
xAI OAuth file. Log in on the live node:

```elixir
{:ok, prompt} = Arbor.LLM.start_xai_device_login()

Arbor.LLM.OAuth.Login.DevicePrompt.verification_uri_complete(prompt) ||
  Arbor.LLM.OAuth.Login.DevicePrompt.verification_uri(prompt)

Arbor.LLM.OAuth.Login.DevicePrompt.user_code(prompt)
# inspect(prompt) is intentionally redacted — keep prompt.handle yourself.
```

Complete the device flow in a browser, then:

```elixir
Arbor.LLM.complete_xai_device_login(prompt.handle)
```

A SuperGrok Heavy subscription can still be rejected as
`xai_oauth_tier_denied` on some accounts. That is terminal for the current
route, not an uncertain ACP send.

### MCP client

Principal-scoped tools require the stdio signing proxy, not bare
HTTP/Bearer. See [EXTERNAL_MCP_CLIENT.md](./EXTERNAL_MCP_CLIENT.md).

Hermes example:

```bash
hermes mcp add arbor \
  --command sh \
  --args '-c' 'cd /absolute/path/to/arbor && exec ./bin/mix arbor.signer --key-file /absolute/path/to/agent.arbor.key --upstream http://localhost:4000/mcp'
hermes mcp test arbor
```

Expected healthy result: 13 tools, including
`arbor_coding_dispatch_readiness`, `arbor_dispatch_task`,
`arbor_task_status`, `arbor_task_result`, `arbor_list_pending_approvals`,
`arbor_answer_approval`, `arbor_steer_task`, `arbor_cancel_task`, and
`arbor_adopt_task_change`.

If Tidewave loads but Arbor tools are missing, diagnose with
`hermes mcp test arbor` and `~/.hermes/logs/mcp-stderr.log`. `Session ID
required` means the signer dropped ExMCP's `mcp-session-id`. After a signer
fix, compile `MIX_ENV=dev` and `/reload-mcp`.

Tidewave (`http://localhost:4001/tidewave/mcp`) is the live-eval sidecar
for `WorkPacket.digest/1`, grants, and the MCP-down fallback. It is not a
substitute identity for dispatch.

## Initial setup checklist

Do these once per machine / identity.

1. `./bin/mix arbor.setup` then `./bin/mix arbor.start`.
2. Confirm `http://localhost:4000/mcp` and `http://localhost:4001`.
3. Register an external agent (or generate `~/.arbor/identity.key`) and
   `chmod 600` the key file.
4. Start a `coding_agent` coordinator and record its `agent_id`.
5. Grant `arbor://agent/dispatch` to the caller. Grant any readiness-named
   horizon URIs the same way.
6. Complete Arbor-owned xAI device login on the live node.
7. Point the MCP host at `./bin/mix arbor.signer` with absolute paths.
8. `arbor_status` with `component: "agents"` — you should see the
   coordinator.

## First run

Use a tiny, reversible packet. The point is to prove admission, worker
launch, validation, and review — not to land a feature.

### 1. Write the plan

```json
{
  "kind": "coding_change",
  "plan": {
    "version": 2,
    "task": "Add one factual sentence to docs/arbor/SOFTWARE_FACTORY.md stating that a first factory run completed on this host. Do not change any other file.",
    "repo_root": "/absolute/path/to/arbor",
    "worker": { "provider": "grok", "model": "grok-4.6" },
    "task_class": "default",
    "validation_profile": "default",
    "review_profile": "binding",
    "workspace_policy": { "mode": "isolated" },
    "budgets": {
      "wall_clock_ms": 5400000,
      "inactivity_timeout_ms": 600000
    },
    "work_packet": {
      "version": 1,
      "success_criteria": [
        "docs/arbor/SOFTWARE_FACTORY.md gains exactly one new sentence recording a successful first factory run",
        "No other tracked file changes"
      ],
      "non_goals": [
        "Do not merge",
        "Do not edit Elixir source",
        "Do not change this plan's review or validation profile"
      ],
      "constraints": [
        "The worker has no shell. Arbor owns validation, review, and commit.",
        "Do not mutate the worktree after owner inspection pins the validation fingerprint."
      ],
      "architecture_refs": ["docs/arbor/SOFTWARE_FACTORY.md"],
      "required_evidence": [
        "Focused format --check-formatted on the touched file"
      ],
      "checkpoint_policy": "direct"
    }
  }
}
```

Omit the outer MCP `timeout` unless you want a *shorter* kill switch than
`budgets.wall_clock_ms`. The executor uses the smaller of the two. 90
minutes leaves room for validation, the commit gate, and council.

High-risk classes need `checkpoint_policy: "design_required"` and a version
2 plan. First run should stay `default` / `direct`.

### 2. Digest the packet on the live node

Never hand-hash. Canonical field order is owned by
`Arbor.Contracts.Coding.WorkPacket`. Generic sorted JSON fails as
`digest_mismatch`.

Tidewave `project_eval` or `./bin/mix arbor.rpc`:

```elixir
alias Arbor.Contracts.Coding.WorkPacket

path = "/tmp/factory-first-run.json"
task = Jason.decode!(File.read!(path))
{:ok, digest} = WorkPacket.digest(task["plan"]["work_packet"])
task = put_in(task, ["plan", "work_packet_digest"], digest)
File.write!(path, Jason.encode!(task))
digest
```

Optionally compile the exact plan with
`Arbor.Orchestrator.CodingPlan.Compiler.compile/1` before dispatch.
`Plan.new/1` only checks the interchange contract; the compiler can still
reject features such as nonempty `rework.stop_conditions`.

Local static check:

```bash
./bin/mix arbor.coding.check --plan /tmp/factory-first-run.json --static --json
```

Live readiness (same payload you will dispatch):

```bash
./bin/mix arbor.coding.check --plan /tmp/factory-first-run.json --live --agent-id agent_<coordinator>
```

### 3. Readiness, then dispatch

Call `arbor_coding_dispatch_readiness` with the **exact** `agent_id`,
`task` object, and optional timeout you will send to
`arbor_dispatch_task`. It never creates a task or grants capabilities.

| `readiness` | Meaning |
| --- | --- |
| `ready` | Admission planes look healthy at snapshot time |
| `degraded` | Admission may still succeed; inspect `readiness.planes` |
| `blocked` | At least one plane will refuse (missing authority, bad roots, template drift) |
| `error` | A plane projection failed; not a transport error |

Then `arbor_dispatch_task` with the same payload. Save the returned
`task_id`. `ok: true` means the store accepted the task, not that the graph
succeeded.

### 4. Operate the run

```
arbor_task_status          { "task_id": "task_..." }
arbor_list_pending_approvals { "task_id": "task_..." }
arbor_answer_approval      { "id": "irq_...", "decision": "approve" }
arbor_steer_task           { "task_id": "task_...", "message": "..." }
arbor_cancel_task          { "task_id": "task_..." }
arbor_task_result          { "task_id": "task_..." }
```

Filter pending approvals by exact `task_id` so the task-scoped lease is
enough. Notes are capped at 1,024 bytes.

Decisions:

- `approve` — run the exact nested validator / commit gate once.
- `rework` — zero validator executions; the note and request id go back to
  the same ACP session.
- `deny` — fail closed.

The commit prompt is *may this agent commit?*, not *please review this
diff*. Council review is a later stage. If trust policy returns
`:authorized`, commit does not wait. If it returns `:pending_approval`,
budget wall clock for a human (raise `budgets.wall_clock_ms`; do not
re-slice the tail).

Prefer `arbor_steer_task` for in-flight correction. Cancel is hard
termination.

### 5. Read the result, then settle

Worker JSON is advisory. Authoritative signals:

- trusted ACP `stop_reason == "end_turn"`
- `coding_workspace_inspect` sees the worktree
- workspace fingerprint changed (or `no_changes` / `worker_turn_no_progress`)
- reviewed validation envelope
- `artifacts.workspace_release` and `artifacts.branch_lifecycle`

If the public result only says `validation_failed`, read
`validate/status.json` under the task log root:

```
<coding_pipeline_logs_root>/task-<sha256(task_id)>/
```

`Arbor.Orchestrator.coding_pipeline_logs_root/0` returns that root. The
same directory holds `coding-plan.json`, `coding-pipeline.dot`,
`coding-compile-manifest.json`, `acp-transcript.json`, and the terminal
artifact.

To land a successful candidate:

1. Independently inspect the worktree / branch.
2. Fast-forward, cherry-pick, or squash onto the destination yourself.
3. `arbor_adopt_task_change` with `destination_ref: "refs/heads/main"`
   (a symbolic ref, not a raw SHA — raw SHAs fail
   `:destination_ref_not_found`).
4. If settlement returns `pending`, poll `arbor_task_result`.

Do not mutate the delegated worktree after owner inspection has pinned the
validation fingerprint. That produces `:validation_tree_mutated`.

## When MCP is down

If signed MCP returns HTTP 404 / `Session not found`, do not invent a
second identity path. Use the live facade on the running node (Tidewave
`project_eval` or `./bin/mix arbor.rpc`) with an explicit `caller_id`
equal to the key-file agent:

```elixir
caller = "agent_<caller>"
target = "agent_<coordinator>"
task = Jason.decode!(File.read!("/tmp/factory-first-run.json"))

{:ok, report} = Arbor.Agent.coding_dispatch_readiness(target, task, caller_id: caller)
{:ok, task_id} = Arbor.Agent.dispatch_task(target, task, caller_id: caller)
```

ACP evidence capture can be skewed a few seconds after a previous worker;
if readiness flaps on that plane, wait and retry readiness+dispatch in
**one** eval. Long `Process.sleep/1` inside Tidewave can hit the HTTP
timeout — keep evals short.

Do not call `coding_produce_reviewable_change` through synchronous
`arbor_run`. Request teardown kills the ACP session. Structured
`coding_change` dispatch is the durable owner.

## Isolated validation (operators, not workers)

The worker has no shell. When *you* run Mix against a retained worktree:

```bash
cd <task_worktree>
MIX_DEPS_PATH=/absolute/path/to/canonical/arbor/deps \
MIX_BUILD_PATH=/private/tmp/arbor-<task-slug>-build \
  ./bin/mix test path/to/file_test.exs
```

Both variables are required. Never share the parent `_build`. Give each
adapter mode (`ARBOR_DB=postgres` vs SQLite) its own `MIX_BUILD_PATH`.

## Related

- [CODING_TASK_DISPATCH.md](./CODING_TASK_DISPATCH.md) — payload, horizon,
  budgets, resume, terminal evidence
- [COUNCIL_SETUP.md](./COUNCIL_SETUP.md) — binding review seats, stock
  provider/model pairs, and how to remap them
- [EXTERNAL_MCP_CLIENT.md](./EXTERNAL_MCP_CLIENT.md) — signing proxy
- [IDENTITY.md](./IDENTITY.md) — operator key and checkpoint HMAC
- `apps/arbor_agent/priv/templates/coding_agent.md` — coordinator
  capability manifest
- `mix arbor.coding.check` — static/live readiness and candidate
  verification
