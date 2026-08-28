# Arbor Software Factory

**Turn a coding agent into a reviewed branch you can trust.** The agent edits
files; Arbor compiles and tests the result in a throwaway container it
controls; a multi-model review council votes; you get a commit on a branch, a
per-seat verdict, and a cryptographic proof that nothing but the agent's edit
touched it. The agent never gets a shell, never runs the tests it reports on,
and never merges.

This page is the pitch and the map. The operator guide is
[`SOFTWARE_FACTORY.md`](SOFTWARE_FACTORY.md); the dispatch contract is
[`CODING_TASK_DISPATCH.md`](CODING_TASK_DISPATCH.md).

---

## What it does

One task, start to finish:

1. **You write a plan** — a small JSON packet: the repo, the task text, the
   validation profile, budgets. Arbor hashes it; the hash is the task's identity.
2. **Arbor preflights everything** — capability grants, trusted roots, the
   pinned dependency baseline for the exact base commit, worker provider
   health, review-panel providers. Anything missing blocks *before* a worker
   is spawned, with a remedy string.
3. **A worker implements it** in an isolated git worktree, through the Agent
   Client Protocol. File tools only. No terminal, no subprocess, no ambient
   MCP servers, no long-lived credentials on disk.
4. **Arbor validates the candidate** in a container it built from a
   digest-pinned dependency baseline: `mix compile --warnings-as-errors`,
   tests per the profile, network off. The worker gets structured feedback
   and bounded rework turns; it never sees the container.
5. **Arbor commits** only the candidate's changed paths, then a **10-seat
   review council** (correctness, security, tests, scope, API compatibility,
   architecture fit, performance, docs, …) votes with structured reports.
   Prose is an abstention. Security vetoes and blast-radius rules can force a
   human.
6. **You adopt** — merge or cherry-pick the branch yourself, then tell Arbor;
   it proves by ancestry that the destination contains the reviewed commit,
   writes an evidence ref, and retires the branch.

Two approvals sit on that path by default (run the validation; make the
commit). The dispatcher answers them — a signed MCP client, a script, or a
person.

## What you get

- A commit on a named branch (`arbor/coding-agent/<slug>--<n>`) containing
  exactly the files the worker changed.
- A verdict object: per-seat votes and findings, blast radius, `human_required`,
  `security_veto`, quorum, disposition.
- Validation evidence: exit code, bounded stdout/stderr excerpts, the
  candidate tree OID, the baseline digest it ran against.
- An audit trail: `refs/arbor/evidence/<task>/<tree>` after adoption, plus the
  ACP transcript and every pipeline node's status on disk.

## What you need

| | Minimum | Better |
| :-- | :-- | :-- |
| **Worker** | One ACP-capable agent you already pay for — Grok (`grok` CLI, reviewed sandbox), Claude Code, Cursor, Kiro, Gemini, Antigravity | Grok 4.6 is the path exercised in the dogfood runs |
| **Sandbox** | Linux: rootless Podman (distro package) · macOS: Apple Container | — |
| **Baseline** | `mix arbor.baseline.build` once per `mix.lock` change (≈13 min on a 4-vCPU VM) | Keep it; validations then take ≈3 min instead of 8–16 |
| **Reviewers** | Whatever LLM providers you have keys/subscriptions for | The stock 10-seat panel spans OpenAI, xAI and Ollama Cloud — see *Known gaps* |
| **Identity** | An Ed25519 key registered on the node, plus `arbor://agent/dispatch` and the task's authority horizon (readiness names anything missing) | — |

## A real run

Fresh Debian VM, 4 vCPU, rootless Podman, Grok 4.6 as worker. Task: add one
factual sentence to a docs file (the point is the pipeline, not the change).
Times are wall-clock from the run log.

```
18:13:5x  arbor_dispatch_task            → task_97c2…  (plan hash pinned)
18:14:30  implement                       worker turn, 1 file changed
18:15:21  waiting_approval: validate      dispatcher approves at 18:15:45
18:16:23  podman create arbor-v1-e24e…    seeded deps build mounted, --network none
18:19:13  podman died exit=0              mix compile --warnings-as-errors: green (170 s)
18:19:47  waiting_approval: commit_change dispatcher approves at 18:20:09
18:20:17  commit 7f92b666 on arbor/coding-agent/add-one-factual-sentence-…--23458
          (1 file, 2 insertions; runtime placeholders left untracked)
18:20:35  review_change                   10 seats in parallel
18:21:09  done: change_committed          approve 2 · reject 0 · abstain 8 · quorum met
                                          blast_radius low · no veto · no human required
18:2x     git merge --ff-only 7f92b666    (operator, in the destination clone)
          arbor_adopt_task_change main   → adopted (method: ancestry), branch retired,
                                          refs/arbor/evidence/4be1…/9dd5…
```

**7.2 minutes** dispatch → `change_committed`; the worker consumed 101k input /
1.6k output tokens. The eight abstentions are the *Known gaps* item below: six
stock seats point at Ollama Cloud models the VM did not have, and two seats
carried the vote.

## Where it stands (2026-08-27)

- **macOS (Apple Container)**: the original path.
- **Linux (rootless Podman)**: landed 2026-08-27 after a fresh-host dogfood;
  the run above is the definition-of-done run. The completed roadmap item
  lists every bug that was found and fixed on the way.
- Verified worker: Grok 4.6 under its kernel-enforced sandbox. Other ACP
  agents are wired but not all have been through the full loop on Linux.

---

## Under the hood

Everything below is implemented; file paths are repo-relative.

### 1. Three principles

1. **Reviewable change production, no unattended merge.** The factory produces
   validated, council-reviewed branches. Integration into `main` is yours;
   Arbor only *settles* it afterwards.
2. **Owner-observed reality.** Worker prose and its `{"status": "implemented"}`
   envelope are advisory. Progress is decided from workspace fingerprints, the
   git index, compiler artifacts, and test receipts.
3. **Fail closed.** A missing grant, a drifted digest, an untrusted path, a
   vetoing seat — the run halts with a named reason rather than degrading.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 1. Authority horizon & task lease   preflight of every capability URI;   │
│    server-minted task id; 6 exact per-task grants; durable recovery mark │
├──────────────────────────────────────────────────────────────────────────┤
│ 2. Zero-trust ACP worker            ephemeral HOME; JIT credentials,     │
│    scrubbed after auth; file tools only; ambient MCP neutralised         │
├──────────────────────────────────────────────────────────────────────────┤
│ 3. Pinned dependency baseline       SHA-256 tree digest of deps;         │
│    mix.lock digest of the *base commit*; seeded compiled build;          │
│    rootless Podman / Apple Container; boot-epoch poisoning on drift      │
├──────────────────────────────────────────────────────────────────────────┤
│ 4. Verification                     compile + tests in the unit;         │
│    pre/post-turn fingerprints; security-regression 2-revision proof;     │
│    cross-app batches; 10-seat council with structured votes              │
├──────────────────────────────────────────────────────────────────────────┤
│ 5. Blast radius & adoption          security veto; forced human review   │
│    on core modules; ancestry/patch proof at settlement; evidence refs    │
└──────────────────────────────────────────────────────────────────────────┘
```

### 2. Dependency baseline and container sandboxing

Candidate compilation and tests never run on the host.

- **Pinned tree digest** — `apps/arbor_shell/lib/arbor/shell/linux_dependency_baseline_core.ex`
  computes a length-framed SHA-256 over every entry of the deps tree (path,
  mode incl. executable bit, size, content; up to 50,000 files / 512 MiB),
  with canonical ordering and depth limits. The deps tree itself contains no
  links, devices, fifos or sockets (link count must be 1). Rebar build
  artifacts (`<dep>/_build`, `.rebar3`) are stripped before the digest.
- **Seeded compiled build** — `mix arbor.baseline.build` runs `deps.compile`
  (`MIX_ENV=test`, network on, on the host) *before* taking the digest, so
  compile-time downloads (e.g. `sqlite_vec`'s loadable) are pinned too, and
  ships `build/` alongside the tree. Mix's `priv/src/include` links are
  re-created relative to the pinned tree and rewritten to guest paths when a
  unit is seeded; links that resolve anywhere else are refused. Result: a
  validation unit compiles the umbrella in ≈3 minutes instead of rebuilding
  every dep (8–16 minutes cold).
- **Base-commit `mix.lock` gate** — before any worker is spawned the pipeline
  reads `mix.lock` from the *base commit object* (never the worktree) and
  compares its digest to the pinned baseline
  (`apps/arbor_orchestrator/priv/pipelines/coding-change-v1.dot`,
  `check_dependency_baseline`).
- **Boot-epoch poisoning** — `linux_dependency_baseline_authority.ex` pins the
  baseline at node boot; drift or tampering detected later poisons the epoch
  and tears down the execution backends (`rest_for_one`).
- **Rootless Podman (Linux)** — `apps/arbor_shell/lib/arbor/shell/oci_executor.ex`
  and the `oci_*` cores. Pinned `/usr/bin/podman`, reviewed argv only
  (`create --network none --read-only --cap-drop ALL --userns keep-id
  --pull never …`, `start --attach`, `kill`, `rm --force`, `ps`), image
  addressed by digest, closed host env (`HOME`, `XDG_RUNTIME_DIR`,
  `PATH=/usr/bin:/bin`). The image is `debian:bookworm-slim` pinned by
  digest with the exact Erlang/Elixir of the host, built from
  `images/validation-runtime/Containerfile`. The launcher's fork-capable
  `oci-probe`/`oci-unit` modes contain leftover descendants (podman's
  `conmon`) after a normal exit rather than treating them as a cancel.
- **Apple Container (macOS)** — `apple_container_executor.ex`: a Linux
  micro-VM per unit from a root-owned `vminit` image.
- **Materialization leases** — `linux_dependency_baseline_materializer.ex`
  allocates private `candidate`/`base` copies (0600/0700), process-bound,
  with a supervisor that retries cleanup until the directories are proven
  gone.

### 3. Worker containment and credential hygiene

Implementation is delegated over ACP (`apps/arbor_ai/lib/arbor/ai/acp_session.ex`)
to an external agent — Grok (`grok agent stdio` under `--sandbox strict`,
`--deny Bash(*)`, `--deny MCPTool(*)`), Claude Code (via `ex_mcp`), Cursor,
Kiro, Gemini, Antigravity — and kept there:

- **No shell.** The worktree holds tracked files only (no `deps/`,
  `_build/`); the worker gets file tools; terminal and subprocess tools are
  denied at the protocol boundary.
- **Ephemeral runtime home.** `HOME`, `GROK_HOME`, `GEMINI_HOME`, `KIRO_HOME`
  point at a per-launch 0700 directory. The Grok sandbox profile is hosted
  there (not in the worktree) and verified with `grok --sandbox <name>
  inspect` before launch — fail closed if the sandbox could not be applied.
- **Ambient config neutralised.** `.mcp.json`, `.cursor/mcp.json`,
  `.grok/*`, `.claude/plugins` in the worktree are replaced by registered
  placeholders that the commit and fingerprint steps ignore.
- **JIT credentials.** OAuth tokens (e.g. xAI) are projected as a 0600 file
  immediately before launch, consumed by the agent's external-auth hook, and
  scrubbed from the runtime home as soon as authentication is confirmed —
  before the first prompt.

(`docs/arbor/CODING_TASK_DISPATCH.md` has the exact env contract.)

### 4. Guardrails

- **Authority horizon preflight** —
  `apps/arbor_orchestrator/lib/arbor/orchestrator/coding_plan/authority_horizon.ex`
  derives the transitive set of capability URIs the run will need (main graph,
  nested graphs, execution manifest). The caller must hold every grant through
  the run deadline; readiness names each missing URI.
- **Server-owned task lease** — task ids are minted by the server (never
  caller-chosen); dispatch records a durable recovery marker and grants six
  exact per-task capabilities:

  | Capability | URI | TTL |
  | :-- | :-- | :-- |
  | task read | `arbor://agent/task/read/<task_id>` | 30 d |
  | approval read | `arbor://approval/read/task/<task_id>` | 24 h |
  | approval answer | `arbor://approval/answer/task/<task_id>` | 24 h |
  | steer | `arbor://agent/task/steer/<task_id>` | 24 h |
  | cancel | `arbor://agent/task/cancel/<task_id>` | 24 h |
  | adopt | `arbor://agent/task/adopt/<task_id>` | 30 d |

  The lease is revoked at terminal state; a late `list_pending_approvals`
  returns `unauthorized`.
- **Workspace fingerprints** — digests of `HEAD`, index and untracked files
  before and after every worker turn catch no-ops (`no_changes`) and stalled
  rework (`worker_turn_no_progress`, which now carries the prior validation
  cause).
- **Design checkpoints** — `checkpoint_policy: "design_required"` inserts a
  design turn whose proposal is hashed against the work packet and raised as
  an interrupt for human review before any code is written
  (`apps/arbor_actions/lib/arbor/actions/coding/design_checkpoint.ex`).
- **Format-only protocol repair** — a malformed worker envelope gets one
  repair turn that re-asks for the envelope, not the task.
- **Bounded rework** (current defaults, see *Known gaps* for configurability):
  1 protocol repair, 2 validation rework turns, 2 review rework turns,
  1 operator rework, 2 design reworks; budgets split the plan's wall clock
  55/25/15/5 across validation/approval/review/cleanup.

### 5. Verification engines

- **Security-regression profile** —
  `apps/arbor_actions/lib/arbor/actions/coding/security_regression_core.ex`.
  The candidate's tests must pass on the candidate *and*, overlaid onto the
  base commit, must fail there. A test that passes on the unpatched base
  rejects the change (`base_tests_passed`): the bug was not reproduced.

  ```
  candidate code + candidate tests  → must PASS
  base code      + candidate tests  → must FAIL
        passes on base → REJECT (bug not reproduced)
        fails  on base → ACCEPT (fix and proof verified)
  ```
- **Cross-app profile** — `cross_app_core.ex`: compile every umbrella app,
  `mix xref --warnings-as-errors`, then tests in 20-file batches under one
  deadline; timed-out batches are refined rather than retried wholesale.
  Infrastructure limits surface as `validation_capacity_exceeded` (schema v2
  handoff), distinct from test failures; output is projected as a
  three-window diagnostic (head, failure anchor, tail) with secrets redacted.
- **Default profile** — `mix compile --warnings-as-errors` in the unit; the
  candidate's real exit code is what gets projected (a container that exits 0
  is never reported as a capacity problem).

### 6. Review council

After validation and commit, `apps/arbor_actions/priv/pipelines/code-review-council.dot`
runs ten seats in parallel (`docs/arbor/COUNCIL_SETUP.md` for remapping):

| Seat | Focus | Stock model |
| :-- | :-- | :-- |
| `correctness` | control flow, concurrency, edge states | `gpt-5.6-sol` |
| `security` | FileGuard, authorization, egress, fail-closed | `gpt-5.6-sol` |
| `regression_test_coverage` | regression and boundary tests | `kimi-k2.7-code:cloud` |
| `edge_cases_error_handling` | nil safety, timeouts, partial failure | `kimi-k2.7-code:cloud` |
| `simplicity_yagni_scope` | minimal surface, no speculation | `grok-4.6` |
| `readability_maintainability` | idiom, naming, placement | `grok-4.6` |
| `contract_api_compat` | public contracts, compatibility | `glm-5.2:cloud` |
| `architecture_grain_fit` | DOT vs CRC core vs Jido action | `glm-5.2:cloud` |
| `performance_resource` | hot paths, GenServer bottlenecks | `minimax-m3:cloud` |
| `docs_naming` | spec alignment, drift, naming | `minimax-m3:cloud` |

- Votes are structured reports via `coding_submit_review_report`; prose or a
  failed call counts as an abstention.
- Corroborated major findings or a security veto reject or send back for
  rework.
- **Blast radius**: changes under `apps/arbor_security/`, `apps/arbor_trust/`,
  `apps/arbor_kernel/` or the Engine force `human_review` regardless of the
  vote.

### 7. Adoption

1. You integrate the branch (fast-forward, squash or cherry-pick) into the
   destination.
2. `arbor_adopt_task_change {task_id, destination_ref}`.
3. Arbor proves the destination contains the reviewed commit (ancestry, or
   patch equivalence), writes `refs/arbor/evidence/<task>/<tree>`, retires the
   branch and releases the workspace. `mix arbor.coding.branches` audits for
   dangling branches and orphaned workspaces with resumable checkpoints.

---

## Tradeoffs, honestly

| The risk with a permissive agent | What the factory does instead | What it costs you |
| :-- | :-- | :-- |
| It ran a command you did not expect in your checkout | The worker has no shell; Arbor runs compile/tests in a container it controls | The agent cannot poke at your environment or install tools to fix it |
| "Tests pass" — they did not | Arbor runs the validation and projects the real exit code and output | ≈3 min per validation with a seeded baseline (8–16 cold); a ≈13 min baseline build per `mix.lock` change |
| The fix merged with no failing test | Security-regression profile requires the test to fail on the base commit | Some fixes need a test that can be overlaid on the base |
| One model reviewed its own work | Ten seats, structured votes, security veto, forced human review on core modules | Reviewer calls across providers; seats whose provider you lack fall back to your configured providers (readiness says `degraded`) |
| It pushed to `main` | Branch + verdict + evidence; you merge, Arbor settles | One more manual step |
| It half-worked and nobody noticed | Fail closed with a named reason at every gate | A missing grant or drifted digest stops the run instead of warning |

Measured on the run above: 7.2 minutes and ~103k tokens for the worker for a
one-file change; validation is the long pole and it is baseline-bound, not
model-bound.

## When to use it

- You want agent-authored changes to arrive as reviewed branches without
  babysitting the agent.
- You need proof that a security fix actually fixes something.
- You are working in a codebase where "the agent ran something" is not an
  acceptable failure mode.

Skip it for throwaway prototypes, for sub-minute turnarounds, or when you
want an agent to interactively debug your local environment.

## Known gaps (as of 2026-08-27)

- **The council adapts to your providers by fallback, not by design.** Six
  stock seats point at Ollama Cloud models. Since 2026-08-27 a seat whose
  provider this host cannot call is rerouted at call time to the first
  available entry in `config :arbor_orchestrator, :llm_fallback_providers`
  (stock: `openai_oauth`, then `xai_oauth`), the verdict names the provider
  that actually voted, and live readiness carries a `review_panel` plane that
  reports `degraded` with the seat list when any seat falls back or would
  abstain. What you lose is model diversity: two providers may cast ten
  votes. Remap seats per `COUNCIL_SETUP.md` to get real diversity back.
- **Most knobs are constants.** Rework/retry caps, the budget split, approval
  wait timeouts, unit CPU/memory/pids, output bounds and the Mix timeout live
  in code today. Making them plan- and config-level settings is the next
  roadmap item.
- **Cold validation is slow without the seeded build.** Build the baseline
  once; the difference is 3 minutes vs 8–16.

## Related

- [`SOFTWARE_FACTORY.md`](SOFTWARE_FACTORY.md) — operator setup and first run.
- [`CODING_TASK_DISPATCH.md`](CODING_TASK_DISPATCH.md) — dispatch contract, horizon, budgets.
- [`COUNCIL_SETUP.md`](COUNCIL_SETUP.md) — seats, model remapping, blast-radius rules.
- [`IDENTITY.md`](IDENTITY.md) — keys, signing, checkpoint HMAC.
