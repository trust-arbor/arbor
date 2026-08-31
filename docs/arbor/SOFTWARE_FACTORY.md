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
  `$TMPDIR/arbor-coding-worktrees` automatically. On hosts where `/tmp` is
  a small tmpfs (Arch/Omarchy: 8 GB with a user quota), worktrees and
  validation captures fail with `:edquot`; put
  `TMPDIR=/home/<user>/.arbor/tmp` in the repo's `.env` before
  `arbor.start` (every factory root derives from `System.tmp_dir!()`).
- The ACP worker CLI the plan names (`cursor-agent`, `claude`, `codex`, …)
  installed on **this** host and logged in for the operator's account.
  Readiness reports `acp_health: acp_health_degraded` until it is.

### Arbor runtime

- `./bin/mix arbor.setup` has been run at least once.
- The server is up: `./bin/mix arbor.start`. Gateway MCP listens on
  `http://localhost:4000/mcp`. The dashboard (and Tidewave, in dev) listen
  on `http://localhost:4001`.
- Persistence is healthy enough to ack the pre-grant recovery marker.
  Dispatch fail-closes when durability is unavailable.

### Validation runtime

Candidate validation (`mix compile`, tests, the admission probe) runs in an
isolated container against a **reviewed Linux dependency baseline**, not on the
host. Linux uses Podman/OCI. macOS uses Apple Container. Without a pinned
runtime, live readiness stops at `dependency_baseline: runtime_unconfigured`
and nothing can be dispatched.

#### Linux (Podman/OCI)

Follow this install literally on a native-arch Linux host. Written 2026-08-26.

**Prerequisites**

- Distro-packaged **root-owned** `/usr/bin/podman` (do not use a user-local
  binary).
- Rootless user namespaces: `/etc/subuid` and `/etc/subgid` for the Arbor
  service account.
- Native architecture only: `linux/amd64` or `linux/arm64`. No qemu-user
  translation.

**First-time image pull**

`mix arbor.baseline.build` uses `podman build --pull=never` and pre-flights the
pinned `FROM` digest before starting the build. If that image is absent, the
task fails closed with `base_image_missing` and names the exact `podman pull`
command (or `container image pull` on Apple Container) — it does not pull
automatically. Pull the reviewed Debian base once:

```
podman pull debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171
```

**Build and activate**

From a clean checkout of the umbrella:

```
./bin/mix arbor.baseline.build
./bin/mix arbor.baseline.activate <digest>
```

`<digest>` is the baseline tree digest printed by `build`. Activate writes
`$ARBOR_HOME/validation-runtime.json` (default `~/.arbor/validation-runtime.json`)
mode `0400`. Override the path with `ARBOR_VALIDATION_RUNTIME_CONFIG_PATH`.

**Restart Arbor** so `config/runtime.exs` re-pins the activated document.

**Check**

```
./bin/mix arbor.baseline.status
./bin/mix arbor.doctor --validation
./bin/mix arbor.coding.check --live --plan path/to/plan.json --agent-id agent_...
```

`mix arbor.doctor --validation` is the validation-runtime row. It is not
`--runtimes` (LLM `Arbor.AI.Runtime`). Probe failure is
`runtime_probe_failed` and names the `podman` driver; it is not hidden behind
`validation_capacity`.

**Time (measured 2026-08-27 on 10.42.42.42, native, fresh HOME, run 11w)**

- First `./bin/mix arbor.baseline.build` ≈13 min (image + `deps.compile` +
  persist compiled `_build`).
- After activate + restart, a seeded validation unit is ≈170 s (~3 min). A
  cold unit without the compiled `_build` seed is 8–16 min.

#### macOS (Apple Container)

Candidate validation on Darwin runs in an isolated VM against a **reviewed,
root-owned Linux dependency baseline**. That VM is **Apple Container on
macOS**, configured by `ARBOR_APPLE_CONTAINER_CONFIG_PATH` (for example
`/usr/local/etc/arbor/apple-container.json`): the validation image and its
digests, the `vminit` image, toolchain pins, the `mix.lock` / deps-tree
digests, and the baseline `source_root` + `manifest_path`. Building and
promoting that baseline is the procedure in the
`dependency-baseline-release-workflow` roadmap item.

Without it, live readiness stops at `dependency_baseline: runtime_unconfigured`
(or `dependency_baseline_unavailable` when the mix.lock authority is unpinned)
and nothing can be dispatched.

Implementation notes for the Linux Podman path live in
`.arbor/roadmap/5-completed/linux-validation-runtime-for-the-software-factory.md`.

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

**The key must also be registered on the running node.** Dashboard-issued keys
are; the `~/.arbor/identity.key` that `mix arbor.setup` generates is **not**
(as of 2026-08-26 — see the `software-factory-onboarding-friction` roadmap
item). Until that lands, the signer answers every request with
`401 … signature rejected` (`:unknown_agent` in the gateway log). Register it
once, on the live node:

```elixir
kv =
  File.read!(Path.expand("~/.arbor/identity.key"))
  |> String.split("\n", trim: true)
  |> Map.new(fn line -> line |> String.split("=", parts: 2) |> List.to_tuple() end)

seed = kv["private_key_b64"] |> Base.decode64!() |> binary_part(0, 32)
{pub, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
{:ok, id} = Arbor.Contracts.Security.Identity.new(public_key: pub, name: "operator-cli")
true = id.agent_id == kv["agent_id"]   # sanity: derived id must equal the file's
:ok = Arbor.Security.register_identity(id)
```

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

Order matters: the key must be registered on the live node (previous
section — otherwise every signed call is `401 … signature rejected`,
`:unknown_agent` in the gateway log) **and** the caller must already hold
`arbor://agent/dispatch` before the loop can run readiness at all. Without
that first grant the task prints `coding grant: malformed_report` with
`rounds: 1`, because an unauthorized caller gets no authority horizon to
read. Grant it once on the live node:

```bash
./bin/mix arbor.rpc 'Arbor.Security.grant(principal: "agent_<caller_from_key_file>", resource: "arbor://agent/dispatch")'
```

Close the authority-horizon loop with the Mix task. It runs coding dispatch
readiness for the plan against the coordinator, grants the capability URIs
readiness names as missing for the key-file caller through
`Arbor.Security.grant/1`, and repeats until readiness names nothing or the
configured maximum number of readiness rounds is reached.

```bash
./bin/mix arbor.coding.grant --plan /tmp/factory-first-run.json \
  --agent-id agent_<coordinator>
./bin/mix arbor.coding.grant --plan /tmp/factory-first-run.json \
  --agent-id agent_<coordinator> --key-file ~/.arbor/identity.key --max-rounds 5
./bin/mix arbor.coding.grant --plan /tmp/factory-first-run.json \
  --agent-id agent_<coordinator> --dry-run
```

`--dry-run`: every round invokes readiness and emits the full list of caller
URIs named that round (no dedupe). Dry-run never emits a grant. It halts
converged only when a report names nothing; otherwise it ends unconverged at
max-rounds.

Do not copy a URI count from an old session — profile and graph changes
alter the set. The Mix task is the grant loop. If you must do it by hand,
start with dispatch, then grant each exact authenticated-caller missing URI
readiness names (never a wildcard):

```elixir
caller = "agent_<caller_from_key_file>"
target = "agent_<coordinator>"
task = Jason.decode!(File.read!("/tmp/factory-first-run.json"))

{:ok, _} = Arbor.Security.grant(principal: caller, resource: "arbor://agent/dispatch")

{:ok, report} = Arbor.Agent.coding_dispatch_readiness(caller, target, task)
horizon = report["planes"]["executor"]["details"]["projection"]["authority_horizon"]

# Fail closed exactly like the Mix task: every URI must parse as a capability
# URI and must not be a wildcard/root or contain a ".." segment. One bad entry
# means the report is malformed — grant nothing from it.
alias Arbor.Contracts.Security.CapabilityUri

uris =
  for finding <- horizon["findings"],
      finding["principal_role"] == "authenticated_caller",
      finding["classification"] == "missing",
      uri <- List.wrap(finding["resource_uris"]),
      do: uri

admitted =
  Enum.map(uris, fn uri ->
    case is_binary(uri) and CapabilityUri.parse(uri) do
      {:ok, %{segments: segments}} ->
        if Enum.any?(segments, &(&1 in ["*", "**", ".."])) or uri =~ ~r/[*]/,
          do: {:error, {:unsafe_uri, uri}},
          else: {:ok, uri}

      _ ->
        {:error, {:malformed_uri, uri}}
    end
  end)

case Enum.find(admitted, &match?({:error, _}, &1)) do
  nil -> for {:ok, uri} <- admitted, do: {:ok, _} = Arbor.Security.grant(principal: caller, resource: uri)
  {:error, reason} -> raise "malformed readiness report, granting nothing: #{inspect(reason)}"
end
```

The coordinator also needs the template capabilities; `mix arbor.agent start
coding_agent` requests them at creation. If readiness later reports
`authority_horizon_missing`, grant the named URI to the **caller** (horizon
is a caller check) and confirm the coordinator still holds the matching
execution grant. The Mix task is that caller-grant loop.

### Grok worker OAuth

The reviewed coding worker is **Grok 4.6** (`worker.provider: "grok"`,
`worker.model: "grok-4.6"`). Do not select `grok-code-fast`.

Arbor never copies the operator's interactive Grok login. Immediately
before launch it projects an Arbor-owned, mode-`0600`, access-token-only
xAI OAuth file. As of 2026-08-27, log in on the live node with:

```bash
./bin/mix arbor.login xai
./bin/mix arbor.login status
```

The Mix task prints the device URL and user code immediately, then waits for
completion. For OpenAI loopback from another machine, forward the pinned
callback port first:

```bash
ssh -L 1455:localhost:1455 host
./bin/mix arbor.login openai
```

The rpc/manual flow remains the documented fallback. Complete the device
flow in a browser **first** — the verification URL is one line in the rpc
output, so copy it out deliberately. Then:

```elixir
{:ok, prompt} = Arbor.LLM.start_xai_device_login()

Arbor.LLM.OAuth.Login.DevicePrompt.verification_uri_complete(prompt) ||
  Arbor.LLM.OAuth.Login.DevicePrompt.verification_uri(prompt)

Arbor.LLM.OAuth.Login.DevicePrompt.user_code(prompt)
# inspect(prompt) is intentionally redacted — keep prompt.handle yourself.

Arbor.LLM.complete_xai_device_login(prompt.handle)
```

`complete_xai_device_login/1` polls xAI until the browser step is done; called
early it blocks the mix task instead of returning an error. Confirm with
`Arbor.LLM.oauth_health(:xai_oauth)` → `status: "ready"`.

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

1. `./bin/mix arbor.setup` then `./bin/mix arbor.start` (set `TMPDIR` in
   `.env` first if `/tmp` is a small tmpfs — see Host).
2. Confirm `http://localhost:4000/mcp` and `http://localhost:4001`.
3. Validation runtime: pull the pinned base image, then
   `./bin/mix arbor.baseline.build`, `arbor.baseline.activate <digest>`,
   `arbor.restart`, and confirm `arbor.baseline.status` shows
   `image_reachable=true`. A build that fails with only
   `image_build_failed` almost always means the base image was not pulled
   (`--pull=never`); the build's own output is not shown yet.
4. Register an external agent (or generate `~/.arbor/identity.key`),
   `chmod 600` the key file, and **register that key on the live node**
   (Operator identity — the `register_identity` snippet).
5. Start a `coding_agent` coordinator and record its `agent_id` from the
   `Started agent … (agent_…)` line.
6. Grant `arbor://agent/dispatch` to the caller, then run
   `./bin/mix arbor.coding.grant` for the plan until it names nothing.
7. Log the worker CLI in on this host (`cursor-agent login`, `claude`, …)
   and complete the Arbor-owned provider logins on the live node
   (`./bin/mix arbor.login xai`, `arbor.login openai`; `arbor.login status`
   should show `ready`).
8. Point the MCP host at `./bin/mix arbor.signer` with absolute paths.
9. `arbor_status` with `component: "agents"` — you should see the
   coordinator.

## First run

**`mix arbor.coding.run` is the way to run a packet.** It stamps the
digest, validates the plan, closes the grant loop, checks executor
readiness, dispatches, follows status, and answers approvals until a
terminal outcome. The manual digest / readiness / dispatch / approve
steps below stay as reference when you need to inspect a single stage.

```bash
./bin/mix arbor.coding.run /tmp/factory-first-run.json \
  --agent-id agent_<coordinator>
./bin/mix arbor.coding.run /tmp/factory-first-run.json \
  --agent-id agent_<coordinator> \
  --key-file ~/.arbor/identity.key \
  --approve-as-dispatcher \
  --allow-paths '^docs/arbor/SOFTWARE_FACTORY\.md$' \
  --poll-ms 10000 \
  --max-wait-ms 5400000
```

`--max-wait-ms` bounds the **whole** command (grant, readiness, dispatch,
polling, and every RPC). Remaining budget is clamped into each sleep and
RPC timeout; the command exits 1 when none remains. Following is
unconditional. Exit `0` for `change_committed` / `pr_created` /
`no_changes`, `2` for `human_review_required`, and `1` otherwise.

### Running it on another host

The command talks to the Arbor node on the machine where you invoke Mix
(same discovery as `mix arbor.baseline.status`). From a laptop, SSH to
the host that is running `./bin/mix arbor.start` and run the command
there:

```bash
ssh user@factory-host 'cd /absolute/path/to/arbor && \
  ./bin/mix arbor.coding.run /tmp/factory-first-run.json \
    --agent-id agent_<coordinator> \
    --key-file ~/.arbor/identity.key'
```

Do not add a second transport. Signed MCP and this Mix command are the
two supported operator paths.

Two remote-operation traps (2026-08-29):

- Keep the approval watcher **on the factory host** (`nohup`/`tmux`), not in
  your SSH session — a dropped connection mid-run leaves the task waiting at
  a gate with nobody to answer it.
- Arch/Omarchy hosts ship an nftables rule that rejects more than five new
  connections per second per source with `admin-prohibited`, which your
  client shows as `ssh: Connection refused` for about a minute. Poll no
  faster than once a second, or multiplex (`ControlMaster auto` in
  `~/.ssh/config`) so polling reuses one connection.

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

The `security_regression` validation profile also requires a nonempty
`plan.requested_paths` list. Every entry must be a repository-relative path
ending in `_test.exs`; these are the exact candidate test files overlaid onto
the parent for fail-before/pass-after verification. A prose entry under
`work_packet.required_evidence` does not satisfy this executable binding.

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
`Plan.new/1` only checks the interchange contract; the compiler wires
contract-allowed `rework.stop_conditions` (notably `validation_failed`
retargets the first soft validation failure to `status_validation_failed`
without a repair turn) and still rejects overlays, `budgets.model_cost_usd`,
and `budgets.parallelism != 1`.

Local static check:

```bash
./bin/mix arbor.coding.check --plan /tmp/factory-first-run.json --static --json
```

`--static` runs without `config/runtime.exs` applied, so it reports
`trusted_roots: worktree_roots_unconfigured` even on a healthy dev install —
the dev worktree root is created at boot by runtime config, not at compile
time. Treat that specific code as noise from `--static` and confirm with
`--live`, which evaluates against the running node.

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
| `degraded` | Admission may still succeed; inspect `readiness.planes`. A healthy dev host commonly shows `acp_health_degraded` (worker CLI evidence unconfirmed), `validation_capacity_unavailable` (no capacity observer in dev) and `review_panel_degraded` (some council providers not logged in) and still dispatches |
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

{:ok, report} = Arbor.Agent.coding_dispatch_readiness(caller, target, task)
{:ok, task_id} = Arbor.Agent.dispatch_task(caller, target, task)
```

Both take the caller **first** and the target second, as positional arguments —
`coding_dispatch_readiness(caller_id, target_agent_id, task, opts \\ [])` and
`dispatch_task(caller_id, target_agent_id, task, opts \\ [])`. Passing the
caller in `opts` instead returns `{:error, :invalid_agent_id}`, which reads like
a bad agent id rather than a wrong call shape.

`Arbor.Agent.task_status/2` does not exist; status and result live on
`Arbor.Agent.Orchestration`:

```elixir
{:ok, status} = Arbor.Agent.Orchestration.task_status(task_id, caller_id: caller)
{:ok, result} = Arbor.Agent.Orchestration.task_result(task_id, caller_id: caller)
```

ACP evidence capture can be skewed a few seconds after a previous worker;
if readiness flaps on that plane, wait and retry readiness+dispatch in
**one** eval. Long `Process.sleep/1` inside Tidewave can hit the HTTP
timeout — keep evals short.

Do not call `coding_produce_reviewable_change` through synchronous
`arbor_run`. Request teardown kills the ACP session. Structured
`coding_change` dispatch is the durable owner.

### Worker token usage

Every worker prompt records one `arbor.provider_usage.v1` event (task-attributed,
appended to the provider-usage ledger). The usage comes from the ACP prompt
*result* when the provider puts it there (`usage` / `_meta.usage`; the `claude`
runtime does). Providers that report usage only through `session/update`
notifications — cursor-agent is one — are covered by `Arbor.AI.AcpSession`
accumulating recognised usage updates (`usage_update`, plus the `usage` /
`tokenUsage` / `token_usage` extension aliases; numeric input / output / total /
cached tokens only) as `pending_usage` for the prompt in flight. The result's
own usage always wins; the accumulator is recorded and cleared when the prompt
completes, so a follow-up prompt can never inherit it. If the post-completion
drain times out, the queued updates are discarded with a logged count instead
of leaking into the next prompt. Malformed usage payloads are ignored.

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
