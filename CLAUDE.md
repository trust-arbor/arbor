# CLAUDE.md

Arbor is a distributed AI agent orchestration system built on Elixir/OTP. Umbrella project with capability-based security and contract-first design.

## Core Concepts

- **Agent**: A supervised entity with a cryptographic Ed25519 identity, trust profile, and granted capabilities. Created via `Arbor.Agent.Lifecycle.create/2`. Runs as a `BranchSupervisor` (rest_for_one) with children: APIAgent host, Executor, and Session.
- **Session**: GenServer in `arbor_orchestrator` that drives agent turns (user messages → LLM responses) and heartbeats (autonomous cycles) by executing DOT graph pipelines via the Engine.
- **Heartbeat**: An autonomous ~30-second cycle where the agent runs a DOT pipeline to check goals, select a cognitive mode (goal pursuit / reflection / plan execution / consolidation), optionally call an LLM, update memory, and execute pending actions — all without human input.
- **DOT Pipeline**: A directed graph written in DOT/Graphviz syntax defining a workflow of typed nodes connected by edges. Node types:
  - `exec` — runs a Jido Action (pure business logic) via ExecHandler
  - `compute` — makes an LLM call via LlmHandler/ComputeHandler
  - `diamond` (shape=diamond) — conditional routing based on a context key
  - `start` (shape=Mdiamond) / `done` (shape=Msquare) — entry/exit sentinels
  - `compose` / `invoke` — embed or call sub-pipelines via SubgraphHandler
  Edges can be conditional (`condition="context.key=value"`), enabling branching and retry loops. A shared key-value **context** flows through the graph — nodes read from and write to it. The graph is a static definition; the Engine provides dynamic execution.
- **Engine** (`Arbor.Orchestrator.Engine`): Executes DOT pipeline graphs by traversing nodes in topological order, dispatching each to the appropriate handler, managing checkpoints for resume, and emitting lifecycle events. The Engine is the core execution loop — it calls handlers, collects results, evaluates conditional edges to pick the next node, and tracks node durations. Live runs are tracked through process-local `RunState` plus the `PipelineStatus` ETS facade; convergence with the legacy `JobRegistry` recovery path and durable pre-effect intent remain in progress — see `.arbor/roadmap/3-in-progress/engine-lifecycle-convergence-and-crash-consistency.md`.
- **CRC Pattern (Construct-Reduce-Convert)**: Pure functional modules that separate business logic from side effects. `new/1` constructs from input, operations transform state, `show/1` formats for output. All functions are pure — no DB, no GenServer calls, no IO. Used extensively in dashboard cores. See [`.claude/skills/functional-core.md`](.claude/skills/functional-core.md).
- **Socket-First Component**: Dashboard pattern replacing LiveComponent with plain Phoenix.Component modules that manage state on the parent LiveView's socket via delegate functions. Events namespaced as `"component:action"`. See [`.claude/skills/socket-component.md`](.claude/skills/socket-component.md).
- **LLM Plug Pipeline**: Cross-cutting LLM-call concerns (record/replay, cost tracking, telemetry, throttling, retry) compose as `Arbor.LLM.Plug` modules piped through an `Arbor.LLM.Call` struct. Mirrors `Plug.Conn` semantics with halted-passthrough; threaded through the four `Arbor.LLM.Adapter.ReqLLM` dispatch points. Add a new concern as a plug, not as a mode flag or wrapper function. See [`.claude/skills/llm-plug-pipeline.md`](.claude/skills/llm-plug-pipeline.md).
- **Granular Trust Policies (earned autonomy)**: Per-task/tool autonomy earned through demonstrated reliability — URI-prefix rules with block/ask/allow/auto modes, longest-prefix match, system-enforced ceilings. Managed by `arbor_trust`. **The scalar trust-tier model (untrusted→autonomous, 0–100) is RETIRED (2026-06/07)**: tier language survives only in historical docs — do not design against it or teach it as current. A derived display score may exist for UI purposes only.
- **Capability**: An unforgeable, signed token granting a specific permission on a resource URI (e.g., `arbor://fs/read/`, `arbor://shell/exec/git`). Granted via `Arbor.Security.grant/1`, checked via `Arbor.Security.authorize/4`. Supports delegation, expiry, constraints (rate limits), and revocation.
- **Identity**: Ed25519 + X25519 keypair. Agent ID is `"agent_" <> hex(SHA-256(public_key))` — deterministically derived, unforgeable. Private keys stored encrypted at rest via `SigningKeyStore`. External agents authenticate via per-request `SignedRequest` signatures verified by `Arbor.Gateway.SignedRequestAuth`.
- **Signal**: Fire-and-forget pub/sub event, mostly for observability. Emitted via `Arbor.Signals`, consumed by dashboards, event stores, and monitoring. NOT used for lifecycle tracking or execution control. Historical exception: `arbor_security` currently uses cluster-scoped security signals for distributed nonce, capability, and identity state sync; treat those as load-bearing security transport until they are replaced by an explicit sync transport.
- **Memory**: Per-agent working memory (ETS-backed `MemoryStore`), knowledge graph, and background health checks. Managed by `arbor_memory`. Goals and intents persisted via `BufferedStore` (ETS + optional Postgres backend).

## Fix the Root Cause

Don't perform actions just to unblock something immediately so you can move on. Always fix the root cause.

## Two-Way vs One-Way Doors (don't block on reversible decisions)

Classify every "should I check with the human?" moment by **reversibility**, not
importance (Amazon's framing):

- **Two-way door (reversible) — the default.** Config, opts, a policy default, a
  doc, a refactor, a fix — anything a later commit can undo. Make the best call
  you can, **record it for review** (state what you decided and why; a decision
  doc if it's weighty), and **move on** — don't wait. A reversible decision is
  wrong at worst for one iteration; waiting spends the human's decision bandwidth,
  which is the real bottleneck (see Applied Learning on decision bandwidth).
- **One-way door (irreversible / expensive to reverse).** Deleting or overwriting
  data, force-pushing history, outward-facing messages, spending money,
  publishing — real blast radius. These need human sign-off. Surface + recommend,
  then **work on something else while you wait** — don't idle.

The test is not "is this important?" — security-relevant reconcile *policy* is
important yet reversible (adjust the opts, re-run the table-tests). The test is
"if I'm wrong, how expensive is the fix?" Cheap → decide, record, proceed.

## Security Bug Fixes Need Regression Tests

When you fix a security bug — anything where a check failed open, an authorization gate was bypassed, an invariant was silently violated — the diff MUST include a committed test that:

- **fails on `git checkout HEAD~1`** (proves the bug existed)
- **passes on `HEAD`** (proves the fix closes it)

A live verification via tidewave / iex is not enough. It tells you the gate is closed *today*. It does not tell you the gate stays closed when someone refactors the auth pipeline six months from now. Without a committed test, every security fix is a one-shot — the next refactor can silently re-open the hole and nothing will catch it.

The test should:
- Live in the same library as the fix (so it runs when that library's tests run)
- Have a name that includes "security regression" or the bug's nature (so future-you knows not to delete it as "redundant")
- Assert behaviorally — call the public API (`Security.authorize/4`, `Shell.authorize_and_execute/3`, etc.) and assert the gate fires, not internal helpers

This rule exists because of the 2026-04-07 shell auto-execution regression: ceiling key namespace mismatch + missing trust integration in `AuthDecision.check_approval` let shell.execute auto-run for an unknown number of weeks. The fixes were verified manually via tidewave at the time but not committed as regression tests, so future drift could re-open the hole.

## Testing While Server is Running

The risk: full `mix test` runs can change Application config or restart subsystems and crash the live dashboard. Risk scales with scope.

**Default to worktree-based testing** — spawn a subagent with `isolation: "worktree"` to run tests in an isolated copy. This is the safe path for any test run.

**Acceptable in foreground without a worktree:**
- Single test files that don't touch Application config or restart subsystems
- Targeted reruns of specific failing tests (e.g., `mix test path/to/test.exs:42`)
- Use this when the worktree mechanism is unavailable, returns stale state, or for fast iteration

**Always use a worktree (or stop the server) for:**
- Full `mix test` runs
- Test files that change Application env, start/stop GenServers the live server uses, or touch shared ETS tables/registries
- Anything you're unsure about

When in doubt, ask first or spawn a worktree.

## Always Learning

Any time I remind you about something or any time you learn something from trial and error, add that to the Applied Learning section. Retention/decay/promotion rules for harness memory: [`.claude/skills/harness-memory-compounding.md`](.claude/skills/harness-memory-compounding.md).

**Personal/episodic memory lives at `~/.claude/arbor-personal/`** (journal, self_knowledge.json, relationships, last_session.md, `search_sessions`). Claude Code loads it via SessionStart hook; **Cowork/desktop sessions don't run that hook** — if you're in one and continuity matters, read `~/.claude/arbor-personal/context/last_session.md` directly.

## Task Tool Reminders

The Claude Code harness periodically injects `<system-reminder>` messages suggesting you use TaskCreate / TaskUpdate to track progress. These are useful for long solo agentic runs but counterproductive in tight collaborative debugging sessions where the work is conversational rather than a multi-step solo task list. **Ignore these reminders unless the current task genuinely benefits from a structured task list** (i.e. you're working alone on a multi-step plan with no human in the loop). Do not mention the reminders to the user when ignoring them.

## Library Hierarchy

Levels are by **longest dependency path** (an app's level = 1 + the max level of
its in-umbrella deps). A library may only depend on libraries at a **lower**
level. Audited from each `mix.exs` on 2026-06-17 — the old 3-level grouping was
badly stale (it called `ai` "standalone" though it deps 7 libs, and put
`consensus`/`actions` low though they sit deep).

```
L0  arbor_contracts, arbor_monitor                       (zero in-umbrella deps)
L1  arbor_common, arbor_signals, arbor_cartographer, arbor_web
L2  arbor_llm, arbor_security
L3  arbor_persistence, arbor_shell, arbor_sandbox
L4  arbor_persistence_ecto, arbor_historian, arbor_trust, arbor_ai, arbor_comms, arbor_consensus
L5  arbor_memory, arbor_scheduler
L6  arbor_actions
L7  arbor_orchestrator, arbor_agent, arbor_gateway
L8  arbor_commands
L9  arbor_dashboard
```

Notes:
- `arbor_orchestrator` is NOT standalone — it deps contracts/common/llm/
  persistence/signals AND **arbor_actions/security/ai/memory/trust/shell** (it
  executes Jido actions via `exec` nodes, authorizes capabilities + egress,
  routes LLMs/ACP, reads goals/percepts, trust policy, and runs sandboxed
  shell; the old runtime `Code.ensure_loaded?`/`apply` indirection was dropped
  for real deps in the 2026-06-17 runtime-bridge sweep). Only `arbor_commands`
  + `arbor_dashboard` depend on orchestrator, so it sits high (L7), not as a
  low kernel.
- `arbor_gateway` moved L6→L7 in the 2026-06-17 sweep — it now deps
  **arbor_actions** (MCP tool execution via `Arbor.Actions.authorize_and_execute`;
  acyclic — actions does not dep gateway).
- The 2026-06-17 sweep also added (all acyclic, no level change): `arbor_agent`
  → arbor_llm; `arbor_consensus` → arbor_security; `arbor_dashboard` →
  arbor_security (was already transitive).
- `arbor_ai` (L4) and `arbor_consensus` (L4) are deep, not standalone.
  (`arbor_consensus` is L4, not L5: its `mix.exs` does NOT declare `arbor_ai` —
  that dep is commented out / optional-at-runtime via a DI seam — so ai doesn't
  raise its compile-time level. The drift-guard test computes from real mix.exs.)
- `arbor_monitor` is the only truly dep-free app besides `arbor_contracts`.
- `apps/arbor_integrations/` exists on dev machines but is **gitignored** (private
  business integrations) — intentionally NOT part of the committed umbrella, so it
  is excluded from this hierarchy. The drift-guard test parses git-TRACKED mix.exs
  only, so don't add it here (it would re-break the guard in CI).

No cycles. Deps point only to lower levels. Always check each library's `mix.exs`
for the exact, current deps — this graph is a snapshot.

## Key Patterns

- **Contract-First**: Shared types and behaviours in `arbor_contracts`. Read [CONTRACT_RULES.md](docs/arbor/CONTRACT_RULES.md) before modifying contracts.
- **Facade Pattern**: Each library exposes one public facade (e.g., `Arbor.Security`). Never alias internal modules from another library.
- **CRC (Construct-Reduce-Convert)**: Pure functional cores in `cores/` directories. Business logic with zero side effects — see Core Concepts above and [`.claude/skills/functional-core.md`](.claude/skills/functional-core.md). The core's counterpart — the thin impure boundary that performs the core's decided effects — is [`.claude/skills/imperative-shell.md`](.claude/skills/imperative-shell.md). Reducer cores return **effects as data**; the shell interprets them. Time/randomness are impure (inject them); purity is mechanically enforced by a lint test over `*_core.ex`. Extract a core when a pure decision lacks a unit test — not to chase coverage.
- **Socket-First Components**: Dashboard components in `components/` directories with namespaced events — see [`.claude/skills/socket-component.md`](.claude/skills/socket-component.md).
- **LLM Plug Pipeline**: Cross-cutting LLM concerns wrap `Arbor.LLM.Adapter.ReqLLM`'s dispatch via `Arbor.LLM.Plug` modules — see [`.claude/skills/llm-plug-pipeline.md`](.claude/skills/llm-plug-pipeline.md).
- **SafeAtom**: Never use `String.to_atom/1` with untrusted input (DoS risk). Use `Arbor.Common.SafeAtom` instead:
  - `to_existing/1` — only converts if atom already exists
  - `to_allowed/2` — only converts if in allowed list
  - `atomize_keys/2` — safely atomize known map keys
- **SafePath**: Never trust user-provided paths. Use `Arbor.Common.SafePath` for path traversal protection:
  - `resolve_within/2` — resolve path and verify it stays within allowed root
  - `safe_join/2` — join paths without allowing escape
  - `sanitize_filename/1` — clean user-provided filenames
- **FileGuard**: For capability-based file access, use `Arbor.Security.FileGuard`:
  - `authorize/3` — verify agent has capability and path is within bounds
  - `can?/3` — boolean check for file access authorization
- **Agent Security Gates**: Arbor (the product) fails **closed** — a missing grant or
  wrong trust mode doesn't error loudly; it denies or escalates to an `:ask` an
  autonomous run can't answer (so the agent loops/times out). **One deliberate
  exception, scoped to dev tooling:** the Claude Code harness bridge
  (`.claude/hooks/arbor_bridge_authorize.sh`) fails *open* (`passthrough`) when the
  gateway is unreachable, so local development isn't blocked — see the header comment
  there. The in-process `authorize/4` path this rule governs is unaffected. Before
  wiring an agent to run tools,
  subscribe to signals, or egress, consult [`.claude/skills/agent-security-gates.md`](.claude/skills/agent-security-gates.md)
  — a living checklist of each gate (restricted `security.*` topics, shell's `:ask`
  ceiling, path-scoped fs caps, trust-mode `:allow` vs `:ask`, the enforcing egress
  gate, `discover_tools` `:auto`, exposure-vs-authorization, the URI registry) with
  the symptom + the action for each. **Add an entry whenever you hit a new gate.**
- Search existing facades before writing new code. Expand a facade rather than reaching into internals.

## Choosing the Right Grain

When building a feature, pick the mechanism that matches its **grain**. Forcing one
mechanism everywhere (especially "make it a DOT graph") is the recurring mistake.
The orchestrator is the kernel for *cognition and genuinely program-shaped flows* —
not for mechanical glue. (Full rationale: `.arbor/decisions/2026-06-15-orchestrator-as-pipeline-kernel.md`.)

| Grain of the work | Mechanism |
|---|---|
| Coarse, **branchy / multi-step / durable / agent-authored / per-node-gated** flow | **DOT graph** on the orchestrator (e.g. turn *cognition*, heartbeat) |
| Mechanical state transform or commit inside a GenServer (e.g. `apply_result` / persist / adopt, normalize) | **Functional core (CRC) + imperative shell** — pure decision in a `*Core`, GenServer does the side effects. **NOT a graph.** |
| New *generic* execution primitive | **handler (opcode)** — generic, **zero business logic**. Adding one is rare; STOP and justify. |
| Side-effecting business op | **Jido action (syscall)** — capability-gated, invoked via an `exec` node |
| Cross-cutting concern spanning a whole graph | **Engine middleware** (capability / taint / telemetry / egress) |
| Wrapping one external op with cross-cutting concerns | **`Arbor.LLM.Plug` pipeline** — *inside* a compute node |
| Light synchronous value transform | **plain function** |

Load-bearing invariants (these are *why* the table is shaped this way):
- **Handlers are opcodes; Jido actions are syscalls.** The handler set was
  deliberately kept small — never bake business logic into a handler. Business
  logic lives in actions (side-effecting) or pure cores (decisions), composed by
  the graph or the shell.
- **Graph it only if it's genuinely program-shaped.** Mechanical commits
  (apply/persist/emit) gain nothing from being a program — no branching, no
  agent-authoring, run in-process in ms. They are CRC core + shell.
- **The engine context is a JSON serialization boundary** (the Engine checkpoints
  after every node). Never put rich typed structs in the context; keep it
  JSON-clean and reconstruct typed envelopes at the GenServer boundary.

## Architecture Triggers

**STOP and brainstorm** (create `.arbor/roadmap/0-inbox/` item if unclear):

| Trigger | What to do |
|---------|------------|
| **Importing an internal module from another library** | Use the public facade. Expand it if needed. |
| **Facade doesn't have what you need** | Propose expanding it, or use behaviour injection ([CONTRACT_RULES.md §9](docs/arbor/CONTRACT_RULES.md)). |
| **Adding a dependency between libraries** | Must follow hierarchy. Cycles or skipped layers = wrong design. |
| **Hardcoding a module name for cross-library calls** | Use the library's `Config` module ([CONTRACT_RULES.md §8-9](docs/arbor/CONTRACT_RULES.md)). |
| **Duplicating logic from another library** | That library should expose it via its facade. |
| **Creating or modifying contracts** | Read [CONTRACT_RULES.md](docs/arbor/CONTRACT_RULES.md) first. |

## DOT Pipelines

See Core Concepts above for the conceptual overview (node types, handlers, execution model). The full syntax reference with attribute tables and examples is at `docs/arbor/DOT_PIPELINE_GUIDE.md`.

## Custom Aliases

```bash
mix quality    # format --check-formatted + credo --strict
mix test.fast  # unit tests only (--only fast)
```

## Test Tagging

Use consistent tags for test categorization. See [TEST_TAGGING.md](docs/arbor/TEST_TAGGING.md) for full guidelines.

Quick reference:
- `:fast` / `:slow` — speed
- `:integration` — crosses boundaries
- `:database`, `:external`, `:llm` — external dependencies

## Roadmap

Ideas and work items go in `.arbor/roadmap/` (`0-inbox/` → `1-brainstorming/` → `2-planned/` → `3-in-progress/` → `5-completed/`). Design decisions go in `.arbor/decisions/`.

## Applied Learning

**Do not run Mix commands in the main worktree while a compiled DOT task is
active.** Even a targeted test may recompile transitive modules on disk while
the running server still has the previous BEAM loaded. A task whose execution
manifest was already bound can then fail later with
`execution_module_loaded_code_mismatch` / `handler_binding_mismatch`; if its
retain node is rejected, owner-death cleanup can remove the dirty worktree.
Use an isolated worktree for every Mix command while delegated pipelines are
running, then hot-reload deliberately between tasks (found 2026-07-13 during
Phase 6 spawn/lifecycle delegation).

**LLM usage cost may be a nested breakdown map, not a number.** Logging and
aggregation code must normalize a recognized numeric total before doing any
arithmetic. A logging-only `:badarith` can otherwise turn a successful model
response into an apparent provider failure (found 2026-07-13 in council
perspective calls through `Arbor.Consensus.LLMBridge`).

**A coding task's public result may omit the actionable validation failure.**
The canonical task result can report only `validation_failed` and even an empty
`files` list after retaining a real candidate. Read the task artifact's
`validate/status.json` for the exact action failure before diagnosing or
redispatching; for example, Phase 6 cross-app validation correctly recorded
`{:spawn_backend_unavailable, :production_backend_missing}` only there (found
2026-07-13 reviewing retained Grok candidates).

**Test applications can be running while required children are deliberately
absent.** `MIX_ENV=test` commonly starts an application supervisor with
`start_children: false`; a direct diagnostic that needs a child such as
`Arbor.Shell.ExecutionRegistry` must start that test-owned child explicitly.
Checking only `Application.started_applications/0` can misdiagnose a missing
child as a broken API (found 2026-07-13 during Phase 6 shell diagnostics).

**Run Postgres-specific tests with the Postgres test adapter.** Arbor defaults
to SQLite in `config/test.exs`, even for files whose module name says
`Postgres`. Use `ARBOR_DB=postgres MIX_ENV=test`, migrate only the isolated test
database, and then run the `:database` file. Enabling the tag under SQLite
mostly proves dialect mismatch, not a Postgres regression (found 2026-07-13
verifying the persistence CAS foundation).

**Do not reuse a delegated worktree build across compile-time adapter modes.**
`ARBOR_DB=postgres` compiles `:arbor_persistence, :repo_adapter` differently
from the default SQLite test mode, and Mix will reject a later run whose runtime
adapter no longer matches that retained build. Use a fresh named
`MIX_BUILD_PATH` for each adapter mode (or explicitly keep `ARBOR_DB` identical)
instead of treating a worker's `_build_*` directory as mode-agnostic (found
2026-07-13 rerunning the lifecycle suite after Grok's Postgres validation).

**One-shot stdin needs an explicit EOF, and tests must assert termination.**
Writing bytes to a child pipe without closing the writer lets programs such as
`cat` and `git hash-object --stdin` produce output and then wait forever. A test
that asserts only captured output can therefore pass while every real call
times out. One-shot execution must close stdin after its optional payload;
interactive sessions must keep a separate open-input protocol, and regressions
must assert normal terminal status as well as exact bytes (found 2026-07-13 in
`Arbor.Shell.ProcessGroup`).

**Always search for all occurrences before using `replace_all: true`.** The string may appear in alias declarations, comments, or other contexts where replacement breaks things.

**Verify "X doesn't exist" claims in roadmap docs against source before designing.** Roadmap/brainstorming docs frequently understate what's built (2026-07-04 session found three in one day: ACP delegation actions existed, Goal `parent_id` hierarchy existed, the interview-agent's trust actions existed — each doc claimed otherwise). The docs age; the code is the truth. One grep before design saves a redesign. The drift runs both directions: "implemented" claims can also be stale or refer to pre-decision-era artifacts (2026-07-12: `jobs-mailbox-sessions-design.md` claimed Jobs *actions* existed; they were actually Mix tasks from a personal task system predating the everything-is-a-Jido-action decision, never generalized, and not in the tracked tree). Verify what was built AND in what form.

**The recurring Arbor bug pattern is built-but-unwired, not broken.** When auditing a subsystem, check the LAST MILE first: recall computed then dropped before the prompt (memory), eval data persisted then never read back (compaction thresholds), signing primitives complete but never verified in the engine path. The machinery is usually sound; the wiring and the end-to-end behavior test are what's missing. Audit by tracing one value from producer to consumer before reading any implementation.

**Hysun's estimates run 2–4x conservative; the real constraint is decision bandwidth, not implementation speed.** Measured (June–July 2026): all 14 H1 items landed at 2–4x estimated speed at ~13 commits/day sustained, while the inbox grew — ideas arrive faster than decisions clear. When planning with him, don't pad implementation estimates, and bias session effort toward design/audit/decision support over code generation; that's where the leverage is.

**Use absolute dates in docs, never relative time-anchors.** "Born last March," "left the company a few days ago," "deadline likely next month" all silently rot into wrong once the doc ages — and roadmap/persona docs age for months. Write `2026-03`, `early April 2026`, `2025`. Exception: verbatim quotes from published material keep their original phrasing (don't edit a quote), but any NEW prose uses absolute dates. (Found 2026-07-06: brand-voice persona anchors and a "TBD deadline" conference doc had both drifted.)

**Don't prematurely cap `max_tokens`.** Let `max_tokens` be whatever the model supports; lower it only when you need faster/cheaper responses, and only *after measuring* that a lower cap doesn't hurt the task. A too-low cap is a silent failure mode with **reasoning models** (e.g. `qwen-agentworld-35b`, `qwen3.5-122b`): they spend the budget on hidden reasoning (`reasoning_content`) and emit the real answer in `content` only *after* reasoning finishes — so a small `max_tokens` yields **empty `content`** that looks like "the model can't answer," a "streaming bug," or "the agent loops," when the real fix is just a bigger budget (verified 2026-07-01: identical empty output on BOTH streaming and non-streaming at 512 tokens; a correct answer at 3000). The turn's `max_tokens` is a `compute`-node attr defaulting to `nil` (provider's full budget) with a session-level fallback (`config["max_tokens"]` → `session.max_tokens`); prefer leaving it unset over guessing a low number.

**Use `./bin/mix`, not ad hoc `mise exec`, for project Mix commands.** `./bin/mix` is the repo wrapper that runs Mix through the Erlang + Elixir versions pinned in `.tool-versions` (currently Erlang `28.4.1`, Elixir `1.19.5-otp-28`). The original footgun still applies: `mise exec elixir@... -- mix ...` pins Elixir only and can fall through to the system Erlang, producing spurious OTP/type failures (`@type record` rejected as a built-in; a type-checker crash compiling `Arbor.Monitor.Diagnostics.top_processes_by/2`). Prefer `./bin/mix test`, `./bin/mix compile --warnings-as-errors`, `./bin/mix arbor.start`, etc.; update `.tool-versions` and let the wrapper pick it up when the project toolchain changes.

**Elixir `Keyword` APIs require atom keys.** Do not call `Keyword.fetch/2`, `Keyword.get/3`, or friends with string keys while trying to support mixed atom/string option data; it raises instead of returning a miss. For mixed option-like data, use atom-keyed `Keyword` access first and a separate `List.keyfind(opts, string_key, 0)` fallback, or normalize to a map before lookup (found 2026-07-08 while threading approval-context opts).

**In Elixir map literals, place every `key => value` entry before keyword-style atom entries.** A map that starts with `foo: value` and later adds `dynamic_key => value` is a syntax error; either order all association entries first or use `Map.put/3` for dynamic keys (found 2026-07-14 during delegated Apple admission-core review).

**For local diagnostic Mix tasks, start the narrow app, not the whole umbrella.** `Mix.Task.run("app.start")` in an umbrella task starts every app and can bring up Gateway/Dashboard, pollers, memory loaders, etc. (2026-07-07: a local trust-profile audit accidentally started HTTP endpoints and loaded unrelated subsystems). Plain `./bin/mix run -e ...` also starts the application; use `./bin/mix run --no-start -e ...` for one-off module introspection that only needs compiled code. For offline/local diagnostics that only need one subsystem, use `Application.ensure_all_started(:target_app)` after compilation/loadpaths, and leave the default task path as live RPC when it needs the running server's state.

**Avoid escaped map-key syntax inside interpolated `mix run -e` snippets.** An expression such as `"#{map[\"key\"]}"` passed through shell quoting is rejected by Elixir before the diagnostic runs. Bind the value with `Map.fetch!/2` first, then interpolate the bound variable (found 2026-07-10 while checking the live coding-plan action catalog).

**Do not compile or test the active checkout while a subagent is midway through a shared-file edit.** Multi-agent commits share the parent workspace, so another focused test can observe a transient state between a new call site and its helper definitions and report unrelated compile errors. Wait for the owning worker to finish or test an isolated committed worktree (found 2026-07-10 during CodingPlan executor integration).

**Test downstream config guards with values that survive the Config accessor.** Some accessors intentionally normalize malformed or blank Application env values back to a packaged default, so a downstream test that injects `nil` or whitespace may exercise the fallback rather than the guard under test. Read the accessor first and use a value such as invalid UTF-8 or NUL-containing binary when verifying the downstream boundary (found 2026-07-10 in the CodingPlan facade test).

**Isolated worktree formatting needs the dependency path too.** The umbrella formatter imports dependency formatter configuration (for example Phoenix), so `mix format --check-formatted` in a clean worktree fails with an unknown `:import_deps` dependency unless `MIX_DEPS_PATH` points at fetched dependencies. Use the same shared `MIX_DEPS_PATH` setup as isolated compile/test commands (found 2026-07-10 during Phase 4 verification).

**Schema-negative tests must target attributes the compiler does not intentionally normalize.** A reviewed-template compiler may restore mandatory parameters before schema validation, so injecting a bad value into one of those parameters proves normalization rather than rejection. Test the restored invariant separately, and use an untouched action parameter to exercise the generic schema failure path (found 2026-07-10 after making default validation warnings mandatory).

**Revalidate compiler output against the normalized plan at the execution boundary.** A compiler is a trusted module seam, but a bug or malformed replacement can reintroduce unchecked execution values after input scope validation. Bind every path/provider/model/test selector the generated graph will consume back to the canonical Plan before archiving or running it (found 2026-07-10 when review reproduced a worktree-root redirect through `initial_values`).

**A hashed child name does not make an artifact root safe from symlinks.** Deriving `trusted_base/task-<sha256>` prevents textual traversal, but a pre-created symlink at that child can still redirect all writes. Canonicalize/create the base, reject symlink children, create the task directory explicitly, and verify segment-aware containment before writing artifacts or Engine logs (found 2026-07-10 during CodingPlan executor review).

**A declared workflow profile is not executable until every claimed invariant is mechanically enforced.** Running a selected `_test.exs` file against the candidate does not prove a security regression fails against the base revision and passes against the candidate. Keep the profile discoverable but fail closed with a precise missing-primitive reason until both sides of the claim are enforced (found 2026-07-10 reviewing the initial `security_regression` compiler profile).

**Node/action inventory checks do not prove graph policy.** A graph can retain every mandatory node and action name while rewiring conditions to bypass them. Inventory is useful Phase 4 template drift detection; publish/review/validation dominance and edge-order invariants require semantic preflight before custom or agent-authored DOT is executable (confirmed 2026-07-10 in the CodingPlan compiler review).

**`mix arbor.eval` is the eval harness, not a lightweight RPC evaluator.** For running-node diagnostics, use a purpose-built RPC task such as `arbor.recompile` or a task-specific command, or add/use an explicit `arbor.eval.rpc`-style task. Otherwise `arbor.eval` starts evaluation infrastructure and can fail on missing `--model` / `--models` before running the intended diagnostic (found 2026-07-08 while checking registry ETS state).

**Preflight database migrations before a clean server restart after persistence schema changes.** Historian rehydration reads the current EventLog schema during application startup, so restarting new code against an old database can take the entire Gateway/Dashboard down before an operator can use live RPC. Run `./bin/mix ecto.migrations -r Arbor.Persistence.Repo` first and audit any data-checking migration before applying it. For destructive or expensive repair rehearsal, boot against a disposable database selected with `ARBOR_DB_NAME` (PostgreSQL) or `ARBOR_SQLITE_PATH` (SQLite) rather than modifying the development database (found 2026-07-13 while validating EventLog protocol migrations).

**Do not raw-recompile the umbrella to repair stale live code.** Calling `IEx.Helpers.recompile/0` through Tidewave can stop dependency applications and leave long-lived signer closures paired with newly loaded modules, producing mixed signing credentials and unavailable security state. Prefer the supported RPC recompile task; if distribution addressing makes that task unreachable, perform a clean restart after the migration preflight instead (found 2026-07-13 while restoring MCP coding delegation).

**`.arbor/` is its own Git repository.** Roadmap files are tracked inside `.arbor`, not in the parent repo, so never `git add -f .arbor/...` from the parent. Commit roadmap changes with `git -C .arbor ...`, and stage only the specific roadmap files for the current slice because `.arbor` often has many unrelated local notes and planning edits.

**URI prefix checks must be segment-aware, never raw `String.starts_with?/2`.** A registry prefix like `arbor://action` raw-matches the retired plural namespace `arbor://actions/execute/...`; `arbor://fs/read` raw-matches `arbor://fs/reader/...`. That is the same footgun class as trust prefix-vs-glob, but at the namespace boundary. Use `Arbor.Contracts.Security.CapabilityUri.prefix_match?/2` for registry-style prefix checks so matching happens on parsed URI segments (found 2026-07-07 during Ring B/B1: `UriRegistry` accepted retired plural action URIs because of a raw prefix match).

**Do not telemetry-invert distributed security state sync.** Security observability can emit `:telemetry` and let `arbor_signals` bridge it back to signals, but nonce, capability, and identity sync are load-bearing cross-node security state. `NonceCache` uses `security.nonce_seen` to block replay against peer nodes; `CapabilityStore` uses revocation signals to evict revoked grants on peers; `Identity.Registry` uses identity lifecycle signals to keep peer caches current. Telemetry is in-process and synchronous, so it cannot replace node-hop transport. B9 extraction needs an injected sync transport (likely Phoenix.PubSub or `Arbor.Signals` behind a behaviour), not a telemetry bridge, before dropping the `arbor_signals` dependency.

**Template capability grants may need runtime URI expansion.** Agent templates and trust presets can declare the human-readable coarse gate (`arbor://orchestrator/execute`), but mandatory Engine middleware authorizes per-node runtime resources like `arbor://orchestrator/execute/exec`. A trust rule prefix can stay bare, but a capability grant must be subtree-scoped (`/**`) or the session pipeline fails closed after `classify` with an empty CLI response. Diagnose by inspecting the node status checkpoint, not just the top-level turn summary (found 2026-07-07 while debugging `arbor.agent chat` for coding agents).

**File tools need both exposure and FileGuard scope grants.** `file_read` / `file_list` are selected via the bare action URI (`arbor://fs/read`, `arbor://fs/list`), but the final file gate authorizes the path-embedded URI synthesized from `file_path:` (for example `arbor://fs/read/Users/.../repo/file.ex`). For least-privilege repo access, use template shorthands like `arbor://fs/read/repo` only if lifecycle expands them into both the bare tool URI and an absolute repo-root `/**` scope, and make sure `ActionsExecutor` resolves relative LLM paths against the tool workdir before signing/authorization; otherwise chat can expose the tool but still deny the action at runtime (found 2026-07-07 while auditing Security Auditor and Test Agent).

**Glob is a file read and must have an authorized base.** `file_glob` shares the bare `arbor://fs/read` exposure URI with `file_read`, but its user-controlled path can live in `pattern` rather than `path`. A missing `base_path` used to skip FileGuard entirely: a repo-scoped read-only agent could glob `/private/tmp/...` because the action layer authorized only the bare `arbor://fs/read`. Agent/tool execution must inject an effective base path (normally the tool workdir), plumb `base_path` into fs auth, and reject absolute or `..` patterns when a base/workspace is set (found and reproduced 2026-07-07 via Security Auditor Eval).

**DBConnection `:timeout` does not bound time already spent in the pool queue.** The connection deadline timer starts when a queued checkout finally receives a connection, so a caller can wait through the pool's queue interval before the timeout is observed. For a hard caller-owned deadline, use `queue: false`, retry checkout in the caller with bounded backoff, and pass the same absolute `:deadline` to the transaction and every query (found 2026-07-11 while testing EventLog append deadlines with an exhausted one-connection PostgreSQL pool).

**Nested action approvals must be awaited by the owner action.** `ActionsExecutor` can wait/retry top-level `{:ok, :pending_approval, irq}` results, but a composite action that calls another action directly must handle that nested approval itself. `coding_produce_reviewable_change` initially converted validation shell approvals into `validation_failed`, leaving stale `irq_*` records the MCP approval tool could answer but not resume. The fix is owner-side wait/retry plus an exact approved-invocation marker, and every hop (`Shell.Execute` context -> `authorize_command` -> `ApprovalGuard`) must forward that marker.

**MCP approval answering is explicit capability authority, not trust-profile graduation.** `arbor_answer_approval` authorizes `arbor://approval/answer/<principal-or-agent>` through `Arbor.Security.authorize/4` before it mutates the IRQ. A scoped capability grant with no `requires_approval` constraint is enough for that security check; `Arbor.Trust.authorize/4` would still gate it because the high-risk profile projects `arbor://approval/answer` to a `:ask` ceiling. Do not try to relax this with an `:auto` trust rule. Give the local approver an explicit scoped answer capability for the delegated worker/owner approval principal, or a global `arbor://approval/answer` cap only for trusted operator surfaces. When listing pending approvals, filter on the stored coarse `resource_uri` (for example `arbor://shell/exec`) rather than the command-specific target URI.

**Native Hermes ACP edit approval can fail before Arbor validation.** A `coding_produce_reviewable_change` run with `acp_agent: "hermes"` may return `status: "declined"` with `Edit approval denied by ACP client; file was not modified`. That is Hermes' ACP edit gate, not Arbor's validation approval loop, so no `arbor_list_pending_approvals` item will appear for the validation command.

**Stdio MCP servers must keep stdout JSON-RPC clean during startup.** Launching Arbor's stdio signing proxy through Mix while Mix recompiles can print `==> ...`, `Compiling ...`, or `Generated ... app` on stdout. Hermes then tries to parse those compiler lines as JSON-RPC and can hit `init_timeout` before the ACP session starts. Warm the compile cache or keep compiler/log output off stdout before diagnosing the downstream MCP tool path.

**Basic-shell sandbox checks the command string even after argument escaping.** `ShellEscape` single-quotes dangerous commit-message text correctly, but `Arbor.Shell.Sandbox` still rejects metacharacters like backticks inside the assembled command string. Git actions that run via `Shell.execute(..., sandbox: :basic)` need to normalize user/task-derived arguments such as commit messages before constructing the shell command, or use a non-shell argv execution path.

**Schema-bounded Mix actions must stay within the basic shell sandbox's allowed flag set.** `Mix.Compile` cannot expose `--force` while it runs through `Shell.execute(..., sandbox: :basic)`: the sandbox rejects that flag before Mix starts. Add flags only after checking the sandbox policy or moving the action to a non-shell argv execution path (found 2026-07-09 while routing coding-agent validation through `arbor://action/mix/compile`).

**Static DOT action parameters arrive as strings.** Attributes such as `param.all="true"` cross the parser/context boundary as string values even when the action schema declares a boolean. Schema-bounded actions that are valid DOT targets must normalize their accepted serialized boolean forms at the action boundary; testing only direct Elixir calls with `true` can leave the live pipeline taking a different branch (found 2026-07-10 when `git.commit` skipped staging after a successful Grok edit).

**Canonical DOT serialization must preserve value types, not just text.** A binary attribute value such as `fan_out="false"` must remain quoted when a graph is serialized; emitting bare `fan_out=false` makes the parser coerce it to boolean `false`, while runtime code may deliberately distinguish the string form. That type drift silently re-enabled fan-out, queued a protocol-repair branch, and later blocked a security-profile join on impossible fan-in predecessors. Roundtrip tests must assert parsed value types as well as canonical bytes (found 2026-07-10 while enabling the reviewed security-regression profile).

**Budget multi-leg action timeouts against the enclosing wall clock.** A timeout on a two-revision validator is per revision, so setting each leg to 600,000ms permits 1,200,000ms of work and exceeds a 900,000ms plan budget. Prefer the measured/default per-leg timeout when it fits the aggregate budget, and name profile metadata explicitly as per-leg default/max rather than presenting one ambiguous timeout (found 2026-07-10 during security-regression profile activation).

**`arbor.recompile` can miss already-compiled nested modules during live diagnostics.** After local `./bin/mix compile`, `./bin/mix arbor.recompile` may return `:ok` while the running dev node still uses old nested action code. Verify live behavior, and if needed force a `:code.purge` / `:code.delete` / `:code.load_abs` reload for the specific modules or restart the dev server before concluding a fix failed.

**Do not update the live node's build path during an execution-binding-pinned run.** A coding manifest can correctly pin the module object currently loaded by the server while a foreground Mix command has already written a newer BEAM to the main checkout's `_build/dev`; a later live reload then changes executable identity mid-run and the Engine correctly rejects the next node with `handler_binding_mismatch`. Run every verification in a worktree with an isolated build path, reconcile or restart the live node before dispatch, and preflight loaded-object versus `:code.which` file identity so stale runtime state fails before the worker starts (found 2026-07-10 while dogfooding the Phase 6 cross-app workflow).

**A bound composite action that launches a nested DOT graph needs both authority propagation and declared child bindings.** Forward the full parent `RunAuthorization` ephemerally through the action/runtime bridge so `Engine.run/2` derives a distinct child authority, and make the reviewed parent manifest explicitly pin every action/capability/egress binding reachable only inside that child graph. Dropping the parent looks like `:nested_action_binding_removed`; forwarding it without declaring the child action correctly fails the subset check. Never fix this by clearing the active binding, reusing the parent unchanged, or disabling nested authorization (found 2026-07-10 when `council_review_change` completed ten reviewers but could not execute the nested `consensus_decide` node).

**Approval escalation requires a running interaction tracker, not just loaded comms modules.** `Arbor.Comms.InteractionRouter` can be callable while `:arbor_comms`, `InteractionRegistry`, `PresenceTracker`, and PubSub are stopped; an `:ask` gate then fails closed with `:tracker_unavailable`, produces no pending IRQ, and looks like a missing capability. Check the application and tracker processes as part of approval-path health, and ensure the server startup/reload path starts the dependency before dispatching approval-bearing work (found 2026-07-10 when a validated coding task reached `git_commit` but could not publish its approval).

**Hot-loading an action does not refresh a core-locked `ActionRegistry`.** The action facade can expose a newly compiled module while the boot-populated registry still lacks it, causing CodingPlan compilation to reject the action as unknown even though runtime execution has a facade fallback. Production action-catalog discovery must reconcile dynamic/plugin registry entries with the current `Arbor.Actions.list_actions/0` core facade; treating any running registry as the sole inventory makes hot reload require a full node restart (found 2026-07-10 while dogfooding the `cross_app` coding profile).

**Trust-policy rules match by URI PREFIX, not glob — never write `/**` in a trust rule.** A bare `arbor://fs/read` already covers the whole subtree (`ApprovalGuard` longest-prefix match); a literal `arbor://fs/read/**` is a prefix of nothing real, so the rule *silently never fires* and the request falls to the baseline. `/**` is correct for **capabilities** (path scope) but dead in **trust rules** — the two forms look identical, which is the footgun. Failure mode is config-dependent: fail-**closed** under a `block` baseline (the Test Agent selected `file_read` but every read returned `{:error, :policy_denied}` despite the trust profile literally showing `"arbor://fs/read/**" => :allow`; 2026-07-06), but fail-**OPEN** for a `/** block` rule under an `allow` baseline. Diagnose by reproducing the exact `Security.authorize(agent, "arbor://fs/read", :execute, file_path: …)` the action makes, and inspect the profile with `Arbor.Trust.Store.get_profile/1`. (Same day, unrelated: `./bin/mix` served a **stale beam** for an edited *mix task* until an explicit `mix compile` — a first "Unknown provider"/old-behavior right after editing a `Mix.Tasks.*` module is un-recompiled code, not a wrong edit; force the compile before concluding.)

**Search every direct wire-shape match when centralizing a response contract.** Fixing the primary adapter does not cover eval-only or provider-specific HTTP paths that decode the same response independently. Search for structural patterns such as `%{"data" => ...}` and route every caller through one lower-level facade helper. For embeddings, assert indexed ordering before cosine or another symmetric reduction; a reversed pair produces the same cosine score and can hide a silent A/B swap (found 2026-07-11 in the direct embedding-similarity eval HTTP path).

**A timed-out `GenServer.call/3` does not cancel the queued call.** Security-sensitive
acquisition/finalization protocols need request IDs plus ordered acknowledge/cancel
messages whose late processing cannot commit after the caller has returned an error.
Testing only a delayed initial reply misses the equally dangerous delayed-finalize race.

**Opaque authority must stay outside every action-visible context, including nested option maps.**
Removing a top-level `:signing_authority` key is insufficient if `nested_engine_opts` is
passed through `Arbor.Actions.authorize_and_execute/4`. Keep the bearer token at the
orchestrator boundary, project only a fresh exact-resource `SignedRequest` into the
action, and retain a process-local resign path for post-approval retries.

**A cleanup lease needs stable identity, restart semantics, and retryable effects.** A PID-only
temporary lease can die while its owner remains alive, after which treating `:noproc` as
success permanently detaches live authority from revocation. Address leases by a stable
registry key, restart them with recoverable cleanup state, and stop only after authority,
capability, trust, and identity cleanup has succeeded or reached an explicit terminal policy.

**When a supervised child gains a prerequisite, update every manual test stack in dependency order.**
`SigningAuthorityBroker` now depends on `SigningAuthorityStateOwner`; app supervision starts
them correctly, but Orchestrator and Agent tests that manually started only the broker failed
far from setup with `:broker_unavailable`. Search all `start_child` helpers whenever a child
spec gains a sibling prerequisite, and keep isolated test files independent of suite order.
For token-coupled pairs, create one opaque token, pass it to both children under their respective
option names, start the owner first, and restart an existing dependent child through its supervisor.

**Cancellation and verification must not reuse mutating scope allocators.** An execution setup
function that exclusively creates an artifact root is correct for first admission, but calling it
again from a timeout cancel hook turns the expected `:eexist` into a cancellation failure. Split
scope derivation from allocation: execution uses the exclusive allocator once; status, verification,
and cancellation derive the same task/worktree/artifact identities without creating anything. A
cancel request or adapter-task exit is not proof that a delegated worker stopped; retain the exact
artifact lease until worker termination and cleanup are positively confirmed, or a late worker can
mutate a path already reassigned to an identical rerun.

**A private ETS table is not an access-control boundary if a GenServer relays its rows.**
Keeping bearer authority in a `:private` table prevents direct ETS reads, but unrestricted
`fetch`, enumeration, or delete calls on the owning facade still expose or erase that state for
any local process. Authorize every relay operation by the exact lease/owner/reconciler process,
redact diagnostics, and crash-test the table owner itself rather than only its clients.

**Copying a Git repository is not commit provenance.** A clean `git status` does not cover
ignored files, hooks, local config, alternates, or other executable `.git` metadata. For an
attested fixture, reconstruct a neutral repository from bounded OID-verified commit/tree/blob
objects, reject unsupported entries, and re-attest HEAD, tree, ancestry, and cleanliness before
and after execution. Disable replacement objects for every provenance command, and pass explicit
cleanliness flags such as `--untracked-files=all`; repository-local config can otherwise make an
unrelated commit appear ancestral or hide an untracked mutation.

**Deferred lifecycle messages need state-owned, unforgeable settlement records.** A later
`send(self(), ...)` carrying the full settlement payload can be forged and can be lost when the
GenServer terminates before handling it. Store the payload in a ref-keyed private outbox, send only
the fresh ref, accept each ref once, and flush the outbox before every close/owner/client/terminate
path (found 2026-07-12 in ACP timeout task-control settlement).

**Reply-first GenServer cleanup still has to resolve every supported server reference.** Direct
`send/2` and `Process.monitor/1` work for PIDs but regress registered atom or `{:via, ...}` servers,
and a queued caller can die before the server accepts its request. Resolve through
`GenServer.whereis/1`, monitor the resolved PID, and cancel queued pre-accept work as well as active
work (found 2026-07-12 in ACP recovery fencing).

**Protocol cancellation must finish before eager transport teardown.** Starting an asynchronous
ACP cancel callback and immediately disconnecting races the callback against a dead client. For
caller/owner cancellation that terminates the session, run cancel through a bounded owned operation
before disconnect; keep hard/inactivity recovery reply-first when the session must remain resumable.

**Stable review finding IDs cannot include candidate identity or mutable prose.** Rework changes
the commit and diff by design, so IDs derived from either cannot converge across cycles. Derive the
issue key from normalized path/side/line/title plus owner, and treat every field included in that
identity (including title) as immutable. Keep the candidate and evidence in cycle records instead.

**Bounded prompt payloads must remain structurally valid.** Byte-slicing encoded JSON produces an
invalid fragment that downstream workers cannot parse. Bound fields before encoding, then compact
to a smaller valid JSON envelope with an explicit truncation marker if the encoded payload still
exceeds its ceiling (found 2026-07-12 in recovery and review feedback).

**Jido `:map` schemas do not accept dynamic string-keyed JSON maps, and `:any` is not an honest
tool-schema fallback.** Path-keyed values such as `%{"lib/a.ex" => [[1, 2]]}` fail Nimble schema
validation because Jido expects atom map keys, while Jido's JSON-schema converter publishes
Nimble `:any` as `type=string`. Use a terminating Zoi object/array schema with dynamic string-keyed
maps; when strict conversion would close those nested maps, publish the non-strict schema and close
only the fixed root object. Exercise `validate_params/1` with atom top-level keys because string
top-level keys are treated as unknown passthrough fields, and assert both malformed outer types and
the emitted `to_tool/0` schema (found 2026-07-12 with review `delta_ranges` and finding ledgers).

**Changing a reviewed nested DOT action requires updating every action catalog.** Registering the
action in `Arbor.Actions` is not enough: compiler fixtures, executable profile manifests, and nested
graph tests can retain the old static module set and fail with `referenced_action_missing` before
semantic analysis. Search action names across production manifests and test catalogs whenever a
reviewed subgraph changes its exec action.

**DOT `constant` transforms emit strings, even when the expression looks numeric or boolean.** If
the context or downstream contract requires a typed JSON value, put it in a JSON object and extract
it with `json_extract`, or normalize it at the action boundary. A fake executor that accepts the
serialized string can hide a production constructor failure, so executable pipeline fixtures must
exercise the real request/contract constructor for typed action inputs (found 2026-07-12 with
`review_cycle`).

**A semantic retry ceiling must pin the whole counter dataflow.** Checking only category/total gate
conditions does not prove that an admitted retry increments the shared total: a rewired edge or
mutated transform can skip the total counter and preserve every gate node. Pin counter
initialization and writer attributes, exact category-to-total increment chains, and prompt/dispatch
routing; mutation tests must remove or bypass each increment and fail before execution (found
2026-07-12 in coding review convergence preflight).
**Long-running MCP actions need asynchronous task ownership.** Calling `coding_produce_reviewable_change` directly through synchronous `arbor_run` can outlive the HTTP request/session teardown: a Grok ACP session started normally, then the gateway timed out stopping the request-scoped MCP session after about 11 seconds and killed the ACP client with an HTTP 500. Start a persisted coding agent, use `arbor_dispatch_task`, and poll `arbor_task_status` / `arbor_task_result` so the ACP session is owned by the task rather than the request (reproduced 2026-07-09).

**Answering a top-level MCP approval does not currently make a fresh `arbor_run` replay resumable.** `trust_propose_profile` returned a pending IRQ and `arbor_answer_approval` approved it, but calling the same action/params again created a new IRQ because the approved-invocation marker was not carried across requests. Nested owners such as `coding_produce_reviewable_change` work because they remain alive, await the IRQ, and retry with the marker themselves. Top-level gated actions need an async owner or an explicit retry token/context before "answer, then call again" can be relied on (reproduced 2026-07-09).

**Custom coding validation commands must not assume ignored repo tooling exists in a git worktree.** `coding_produce_reviewable_change` routes recognized `mix compile` and bare `mix quality` commands through schema-bounded Mix actions, but `./bin/mix test ...` currently falls back to raw `Shell.Execute`. After approval, that command runs with the generated worktree as `cwd`; because `bin/mix` is not present there, validation fails with `{:executable_not_found, "./bin/mix"}` and no commit is produced. Route test commands through `Mix.Test` with shared host deps/build paths, or resolve the tracked checkout's wrapper explicitly before using shell fallback (reproduced 2026-07-09 with Grok ACP).

**Conserve the local agent's tokens for planning, design, delegation, and review.** As a rule of thumb, delegate substantive implementation to Grok through `coding_produce_reviewable_change`, then have the local agent inspect the diff, verify behavior, and request corrections. This is a heuristic, not a prohibition: make direct edits when delegation is blocked, the change is genuinely tiny, or local intervention is the clearest way to finish safely. The goal is to spend local-agent context on decision quality and integration judgment rather than routine code production (requested 2026-07-09).

**Prefer steering an active delegated ACP worker for review and rework; reserve cancellation for termination.** Steering preserves the model context, worktree, and test state. As of 2026-07-09, `coding_produce_reviewable_change` does not expose nested ACP steering, and Session steering cannot interrupt a blocking nested action, so add an explicit task/ACP steering control instead of simulating rework with cancel-and-redispatch. `arbor_cancel_task` must remain hard, deterministic termination.

**Killing a `GenServer.call` caller does not remove a request already queued in the server mailbox.** Async task cancellation must both tombstone the task at the execution boundary and reject queued work whose caller is already dead; otherwise a busy shared agent can execute cancelled work later. This surfaced on 2026-07-09 while closing the `TaskStore -> APIAgent -> Session` cancellation race.

**Verify the pinned Mix wrapper from inside the actual delegated worktree.** A nested git worktree can inherit a PATH with Homebrew before mise's insertion point; `mise current` still reports the configured versions while `mise exec -- mix` silently selects `/opt/homebrew/bin/mix` and the wrong OTP. `bin/mix` must resolve `mise where erlang` / `mise where elixir`, prepend those exact `bin` directories, and execute that Mix path. Check `./bin/mix --version` in the worktree, not only the parent checkout (found 2026-07-09: parent used Elixir 1.19.5/OTP 28 while the nested worktree used Elixir 1.20.2/OTP 29).

**Git hooks that invoke bare `mix` bypass the repository wrapper.** The local pre-commit hook runs `mix format` and `mix run`; invoking `git commit` from a nested worktree with the ambient Homebrew PATH selected Elixir 1.20.2/OTP 29 and polluted the shared `_build` even though direct project commands correctly used `./bin/mix`. Until the hook itself is installed from a tracked, wrapper-aware script, run such commits with the pinned Erlang/Elixir `bin` directories first in `PATH` and an isolated `MIX_BUILD_PATH`; do not treat a hook-side dependency compile failure as a formatting failure (found 2026-07-09 during the workspace-lease slice).

**Quote shell search patterns so documentation backticks stay literal.** Backticks inside a double-quoted `zsh -c` command are command substitutions, even when they appear only in an `rg` pattern. Use a single-quoted shell pattern (or otherwise escape the backticks) when searching Markdown; otherwise a harmless source search can unexpectedly execute the documented command (found 2026-07-10 while searching for the Mix-wrapper learning).

**A clean coding worktree does not prove the worker made no change.** ACP workers can create a commit even when asked only to edit; `git status --porcelain` is then empty while `HEAD` has advanced. `coding_produce_reviewable_change` currently misclassifies that case as `no_changes` (observed 2026-07-09 on the Grok parity-fixture delegation). Capture the acquired base commit and treat either a dirty tree or `HEAD != base_commit` as a change. Prompt the worker not to commit so the wrapper owns the review commit, but enforce correct detection in code rather than trusting that instruction.

**Gitignore directory patterns with a trailing slash do not cover worktree symlinks.** A delegated worker linked `_build` to the parent checkout; `/_build/` did not ignore the symlink, and `git add -A` committed it. Use `/_build` (and `/deps`) when both real directories and accidental symlinks must stay untracked. Also prefer the existing Mix action shared-path environment over creating links in a coding worktree (found 2026-07-09 during the workspace-lease slice).

**Verify delegated Git refs as exact opaque values before invoking the coding action.** Do not reconstruct, expand, or concatenate a commit hash while relaying it through an agent prompt. Prefer a verified short hash or stable branch name when either is unambiguous, and run `git rev-parse --verify <ref>^{commit}` before dispatch. A 2026-07-09 correction delegation duplicated part of a full SHA, so `coding_produce_reviewable_change` failed before the ACP worker started.

**Approval retries must carry exact one-shot authority, never mint a clean standing capability.** The owner that awaits an IRQ must retry with an `approved_invocation` marker bound to the request ID, principal, and exact resource URI, and both Security's capability gate and Trust's policy gate must honor that marker. Granting a constraint-free capability after approval silently turns "approve once" into durable authority; omitting the marker makes the retry ask again and leaves a stale IRQ. Reproduced 2026-07-10 through `arbor_dispatch_task -> coding-change-v1.dot -> git_commit`.

**Use canonical `/private/tmp` paths for isolated macOS worktrees that share absolute Mix paths.** macOS aliases `/tmp` to `/private/tmp`, but dependency and build symlinks can retain the non-canonical spelling and break when Mix compares or resolves absolute paths. Create the worktree under `/private/tmp` and keep `MIX_BUILD_PATH`, deps paths, and symlink targets in that same canonical namespace (found 2026-07-10 during the Phase 3 combined verification).

**Do not send long newline-delimited MCP JSON frames through a canonical PTY.** A terminal's line buffer can truncate or reject a large JSON-RPC request before the stdio signer reads it, which looks like a malformed or missing MCP response. Use a non-TTY client or an existing MCP tool for long dispatch payloads; reserve interactive signer sessions for short diagnostic calls (found 2026-07-10 during the signed steering proof).

**Accepted queued steering needs an explicit terminal reconciliation contract.** If the worker task succeeds, accepted controls can reconcile to delivered; if the provider or task fails after accepting a control, report delivery unknown or not delivered and never replay the same opaque control ID. Leaving accepted controls permanently queued, or retrying after provider delivery became ambiguous, creates either false status or duplicate instructions (found 2026-07-10 after the live Grok steering task).

**Task cancellation must resolve only approvals carrying that exact task provenance.** A cancelled owner can otherwise leave an answerable stale IRQ behind, but sweeping by agent, principal, or URI could reject unrelated work. After successful cancellation, best-effort reject or cancel only pending interaction/consensus approvals whose stored `task_id` exactly matches; leave missing or different provenance untouched and audit the cleanup (found 2026-07-10 after cancelling the steering setup task).

**Pipeline traversal authority is not resource authority.** A grant such as `arbor://orchestrator/execute/**` may authorize pure graph opcodes, but it must never satisfy bare IR requirements such as `file_write` or `shell_exec`: normalizing those names under the traversal subtree turns a lobby pass into host filesystem and process authority. Map side-effecting handlers to their canonical `arbor://fs/...`, `arbor://shell/...`, or action resource and carry concrete path/task scope into Security (found 2026-07-10 during the DOT coding Phase 5 authorship audit).

**A signed capability manifest must bind the exact executable artifact and inputs.** Signing only a list of allowed capabilities lets the same valid manifest be copied beside different DOT or reused with a different workdir/argument payload. Scheduled/custom graph attestations must cover canonical graph bytes/hash, pipeline identity, fixed workdir, and the reviewed argument contract, then recheck the hash immediately before execution (found 2026-07-10 auditing the scheduler DOT-authorship redesign).

**Execution identity belongs in immutable run authority, never mutable graph context.** `session.agent_id` is useful context provenance, but if middleware or handlers derive the principal from it, a graph, nested run, or initial-values merge can spoof or lose authority while the signer comes from unrelated opts. Bind execution principal, caller/author provenance, task/session scope, graph hash, and fixed workdir in trusted Engine state; context may mirror those fields but must not drive authorization (found 2026-07-10 tracing direct, nested, parallel, and remote DOT execution).

**Approval completion does not preserve caller authority or executable-code identity.** An action can wait minutes between its initial authorization and the approved retry; during that interval the delegator's capability may be revoked or the resolved action module may be reloaded/replaced. Immediately before the one-shot retry, revalidate the caller's exact scoped capability and every pinned module/BEAM binding in addition to checking the approved-invocation marker (found 2026-07-10 reviewing caller-bound DOT action execution).

**An ACP protocol failure does not prove the delegated implementation was lost.** The coding pipeline can reject a worker's final response as invalid JSON after the worker already edited, tested, and committed in its retained branch/worktree. Before redispatching or redoing the task, inspect the task's workspace ID, `git worktree list`, target branch log, and diff; salvage and review the actual commit, then delegate only the missing correction (found 2026-07-10 after Grok completed the pipeline source-file authorization fix but returned invalid terminal protocol JSON).

**An in-process test formatter is not a hostile-code proof channel.** Candidate ExUnit/project code shares the BEAM with a generated formatter, so it can discover or replace formatter state, forge a schema-valid artifact, mutate shared dependencies, or halt with a chosen status. A two-revision coding gate must either run only after binding review of an exact immutable tree and name that limited assurance honestly, or use a genuinely external attested runtime; a random path, custom formatter, or container alone does not establish hostile-runtime integrity (found 2026-07-10 adversarially reviewing the Phase 5 security-regression runner).

**`SafePath.resolve_within/2` is lexical containment, not an existing-file authorization result.** It normalizes `..` but does not return a symlink-resolved target. Before reading a user-selected existing file, resolve and compare the real workdir and real target, authorize the caller-visible path through the fs/FileGuard gate, and read the proven canonical target; otherwise an in-workdir symlink can redirect a read outside the workspace (found 2026-07-10 reviewing Grok's pipeline `source_file` authorization fix).

**Pre/post pathname checks do not bind file bytes across a read.** An attacker can swap a path to alternate same-sized content for `File.read/1` and restore the original inode before the post-check. Security-sensitive source reads must open the canonical regular file once, compare the opened descriptor's identity with the authorized pathname identity, read only from that descriptor, then revalidate both descriptor and pathname before returning bytes (found 2026-07-10 after the first pipeline source-race fix still admitted a restored-path double-swap).

**`File.cp_r/2` preserves symlink targets; a copied tree is not automatically isolated.** Absolute symlinks inside a dependency tree still point back to the original tree after copying. Security-sensitive snapshots must inspect every copied symlink, reject source targets outside the trusted source root, and rewrite allowed internal links to targets inside the destination before treating the copy as private (verified 2026-07-10 while isolating two-revision validation dependencies).

**Reused detached-worktree build paths can retain stale `priv` symlinks.** Mix links an application's `_build/.../priv` back to the source worktree. Reusing `MIX_BUILD_PATH` with `--no-compile` after that worktree is removed can make shipped templates or other assets appear missing even though the target checkout contains them. Before trusting a `:not_found` result in an isolated rerun, inspect the build's `priv` target, rebuild in the target worktree, or deliberately refresh that symlink (found 2026-07-10 while rerunning exact-template policy tests).

**Registry disappearance may lag synchronous process shutdown.** `Supervisor.stop/3` waits for the process tree to terminate, but a `Registry.lookup/2`-backed `whereis/1` can briefly retain the registration until its cleanup notification is processed. Tests that assert absence immediately after shutdown should use a short bounded eventual assertion while still checking security state such as identity suspension and capability revocation directly (found 2026-07-10 in exact-policy fail-closed cleanup tests).

**Tests must explicitly own security children disabled by test config.** `config/test.exs` sets `arbor_security, start_children: false`, so a focused test that calls signing APIs such as `Arbor.Security.grant/1` must start `Identity.Registry` and `SystemAuthority` under ExUnit supervision. Do not rely on another test file to start shared infrastructure. Use `start_supervised!/1` rather than a raw linked `start_link/0` for ordinary test ownership, but do not rely on `on_exit` to call that child: ExUnit teardown can stop it before the callback runs. Restore mutable process state in a `try/after` while the process is still alive, or put the process under a longer-lived supervisor (found 2026-07-10 during Phase 5 isolated verification and confirmed by the stale ActionRegistry catalog regression).

**Run-authorization test fixtures must cross the IR compilation boundary.** `RunAuthorization.new/2` intentionally rejects raw `%Graph{}` values because execution authority binds the compiled graph and its manifest. Tests that construct a graph directly must compile it with `Arbor.Orchestrator.IR.Compiler` and use the enriched nodes from that compiled graph before creating authority or invoking handlers (found 2026-07-10 updating caller-authority regressions after Phase 5 hardening).

**Coding Plan uses reviewed task-class identifiers, not informal scope labels.**
`task_class: "simple"` is invalid. Use `"default"` for a narrow ordinary change;
the current reviewed set is `default`, `security_regression`, `contract_change`,
`frontend_visual`, `docs_only`, `cross_app`, and `database_migration` (found
2026-07-10 when a Phase 6 dogfood dispatch failed normalization before startup).

**Reviewed pipeline assets belong to the lowest library that owns their business operation.** A council-review DOT launched by an `arbor_actions` action cannot live only under `arbor_orchestrator/priv` and be resolved upward with `Application.app_dir(:arbor_orchestrator, ...)`; that creates a hidden L6 -> L7 runtime dependency and breaks standalone/release use. Keep the artifact under the owning lower app, expose it through that app's public facade, and let the higher orchestrator attest and execute the exact facade-provided bytes (found 2026-07-10 while binding the nested coding-review council manifest).

**A bound nested graph is immutable executable input.** Do not rewrite node attributes such as question, mode, or quorum after the parent manifest has attested the child graph; even semantically equivalent mutation changes the compiled object and correctly fails binding verification. Put per-run data in the child's initial context, reject executable overrides on bound paths, and preserve custom graph mutation only for explicitly unbound execution (found 2026-07-10 while dogfooding the bound coding-review council).

**Nested action binding changes need explicit parent-child lineage.** An active action binding cannot accept an arbitrary replacement merely because the child action map is a subset. Project the parent's immutable run-authority digest into the action context, require the child's `parent_binding_digest` to match it, require a distinct child binding digest, and compare every child action descriptor exactly against the parent closure. Missing lineage, sibling lineage, expansion, removal, and code drift must all fail closed (found 2026-07-10 while authorizing a bound council action to launch its reviewed child graph).

**Do not confuse `Arbor.Security.Keychain` with macOS Keychain Services.** Arbor's module is an in-process cryptographic peer/session abstraction and does not invoke the macOS `security` tool or credential store. Repeating macOS prompts for a `Claude Code credentials` item can come from the Claude daemon itself; `~/.claude/daemon.log` reports `auth: no token found, will re-check keychain every 30s` when that happens. Diagnose the requesting process and daemon log before attributing a prompt to Arbor code (found 2026-07-10 while delegated tests were running).

**Hot-loading a GenServer module does not migrate its running state.** A recompiled callback can expect new struct fields while the live process still holds the old map, causing writes to fail long after code loading reports success. Before exercising a hot-loaded stateful subsystem, compare `:sys.get_state/1` keys with the current struct; use an explicit in-place state migration when semantics are clear, or restart under its supervisor only when persisted reconstruction is safe. Do not restart a memory-backed policy store casually (found 2026-07-10 when `Arbor.Trust.Store` lacked newly added durable-backend fields after hot reload).

**Authority-key scanners must distinguish executable control data from declarative schemas.** Recursively flagging every key named `agent_id` or `owner` across a compiler artifact rejects legitimate action JSON Schema properties even though those names never become runtime values. Scan the plan/compiler control envelope, and validate trusted descriptor or execution-manifest subtrees with their exact structural/catalog validators instead of applying control-key heuristics to schema vocabulary (found 2026-07-10 when the live CodingPlan catalog included `council_review_change.agent_id` and `git_pr.owner`).

**Binding reviewers need scoped source evidence, not ambient repository authority.** A diff-only council can correctly abstain when a claim depends on surrounding contracts or call sites, but enabling generic tools under the coding agent's principal exposes more authority than the review needs. Give reviewer compute nodes an explicit, bounded read/search tool set scoped to the candidate project and task; preferably read tracked blobs from the exact reviewed commit/tree so live worktree drift, `.git`, and untracked secrets are outside the evidence boundary. Bind those tool actions into the reviewed child manifest, cap output/turns, taint code as untrusted evidence, and expose no write, shell, network, or approval tools (found 2026-07-10 when five council members abstained because a documentation diff's contract claims could not be verified from the diff alone).

**Prompt-data fencing must reuse one nonce across the system preamble and every tool result.** Wrapping a later tool result with a fresh nonce that the system prompt never introduced gives the model delimiters without the instruction that makes them meaningful. Generate the nonce at the LLM-handler boundary, put its preamble in the system message, and thread that exact nonce through every tool-loop round and error path (found 2026-07-10 while enabling commit-tree evidence for binding reviewers).

**Bound producer output before it enters application memory.** Running `System.cmd/3` and truncating the returned binary still lets an untrusted command allocate its entire output first. For Git search or similar evidence tools, consume a Port incrementally, enforce a byte ceiling while receiving, and close the producer once the bound is reached; regression tests should keep the producer alive long enough to prove it was terminated before later side effects (found 2026-07-10 in `coding_review_tree_search`).

**Tool-loop exhaustion must preserve the conversation's required output format.** A generic final-pass instruction such as "plain text only" or "do not output JSON" can invalidate a council node whose contract requires a structured vote. Remove tools for the wrap-up pass, but tell the model to answer in the format already required by the conversation (found 2026-07-10 after review-tree tools added bounded multi-turn council calls).

**Nested LLM tool calls need the exact child `RunAuthorization`, not only its flattened manifest fields.** A nested council can carry the correct child manifest and action bindings yet still fail every tool call with `:nested_action_binding_lineage_missing` if `LlmHandler` or `ToolLoop` drops the opaque authority term. Thread the validated authority unchanged through both layers into `ActionsExecutor`; that is what projects the distinct child digest and matching parent digest without weakening the action-layer lineage checks (found 2026-07-10 during commit-tree council dogfood).

**Run focused umbrella tests one application at a time when the live server is up.** A single root `mix test` command containing paths from multiple umbrella applications can start the full umbrella, collide with the running Gateway port, consume unbounded aggregate memory, and obscure the actual test result. Validators must invoke one app's test tree per fresh child BEAM under one shared monotonic deadline; use an isolated `MIX_BUILD_PATH`, while sharing only `MIX_DEPS_PATH` to avoid live-service collisions and compile-environment drift (found 2026-07-10 while verifying council lineage; production validator violation reproduced 2026-07-11 as exit 137 across 20 affected apps).

**Mutating actions must declare their conservative static `effect_class`.** `Arbor.Actions.Egress` intentionally defaults an undeclared action to `:read`; that made `git.commit` approval records claim `risk_hints.effect_class=read` even though the trust gate still asked. Declare `:local_write` for actions whose maximum mode mutates local state, including mixed read/write actions such as `Git.Branch`, and regress through the public `Egress.effect_class_for/1` projection (found 2026-07-10 during live approval inspection).

**Long-lived agents do not automatically inherit later template authority changes.** Updating a template's `required_capabilities` and trust preset fixes newly instantiated agents, but an already-running coding agent keeps its persisted grants and profile rules. Before dogfooding a newly enabled validation profile, inspect both `Arbor.Security.list_capabilities/1` and `Arbor.Trust.get_trust_profile/1`; reconcile the existing principal through the public facades or recreate it, otherwise the first profile action can fail `:unauthorized` even though the template and template tests are correct (found 2026-07-10 on the first real `cross_app` run).

**Implicit action directory context must be schema-bound.** `ActionsExecutor` used to inject both `:cwd` and `:workdir` into every action after schema atomization. Strict actions correctly rejected those undeclared keys as `:unsupported_parameter`, so an approved `cross_app` validation never reached compile/xref/tests. Inject only the directory keys declared by the selected action schema, preserve explicit supported values, and regress the public executor-to-action boundary for actions declaring neither, either, and both keys (found 2026-07-10 during executable-profile dogfood).

**Structured coding dispatch requires the task-kind envelope.** Send executable CodingPlan data through `arbor_dispatch_task` as `%{"kind" => "coding_change", "plan" => plan}`. A bare plan map is not selected by TaskStore's coding executor and instead falls through to the ordinary agent-session path, where unrelated turn-graph errors can obscure the malformed dispatch (found 2026-07-11 while retrying security-regression dogfood).

**Long-lived anonymous signer functions can become invalid after hot code purge.** Session and heartbeat state currently retain the closure returned by `Arbor.Security.make_signer/2`; purging that defining module makes the stored function raise `BadFunctionError`, which the authorization boundary correctly projects as `:security_unavailable`. A restart regenerates the closure but is only a workaround. Long-lived owners need a reload-stable signer reference/factory and must refresh the short-lived closure before each turn or heartbeat without placing raw private keys in orchestrator state (found 2026-07-11 after recompiling during Phase 6 dogfood).

**Security-regression plans require explicit reviewed test paths.** The executable `security_regression` profile must receive non-empty `requested_paths` ending in `_test.exs`; an empty selection correctly fails compilation with `{:invalid_security_regression_paths, :empty}` before worker execution. Keep candidate-controlled stdout out of automatic rework prompts and checkpoints; trusted proof uses the formatter artifact, while operator diagnostics need a separate bounded, access-controlled channel (found 2026-07-11 during two-revision dogfood).

**Terminal task cleanup must resolve approvals by exact task provenance.** Ordinary failure or wall-clock timeout can terminate the owner after it created a nested commit/validation IRQ. Revoking the delegator's answer capability is not enough: the stale approval remains visible and answerable even though no owner can resume. Every terminal path, not only explicit cancel, must best-effort close approvals whose stored `task_id` exactly matches and leave unrelated approvals untouched (found 2026-07-11 after `task_1162946` timed out).

**Direct Mix test subprocesses must set `MIX_ENV=test` explicitly.** Project `cli.preferred_envs` can override Mix's usual test-task environment, especially in isolated validators that call the wrapper through `Port`. Default direct `["test" | args]` runs to test env, let an explicit caller environment win, and preserve both the head and failure tail in bounded compile feedback so setup noise cannot hide the actionable error (found 2026-07-11 during cross-app validation).

**Canonicalize temporary resource roots before deriving Mix paths.** On macOS, `System.tmp_dir!/0` can return `/var/folders/...` while Mix and the filesystem resolve the same location as `/private/var/folders/...`. Deriving build and dependency paths from the non-canonical spelling can make Mix create broken relative `include` or `priv` symlinks, causing dependency compilation to fail before project tests start. Resolve the root once with `SafePath.resolve_real/1`, then derive every child path from that canonical root (found 2026-07-11 during security-regression validation).

**Two-revision proof lives only in the plan's immutable requested test paths.** A worker may add excellent regressions elsewhere, but the security validator copies and runs only `requested_paths` against base and candidate. Put every required public behavioral proof in one of those selected files before dispatch, or steer it there before commit; extra tests remain useful coverage but do not establish the pre-fix-fails claim (found 2026-07-11 reviewing shell-bound dogfood before validation).

**Approval `rework` must remain distinct from denial across nested action waits.** The interaction backend may encode rework as a rejected invocation plus `%{decision: :rework, rework: true, note: ...}` metadata, but the owner must retain that metadata and project a nonterminal control outcome. Never retry the rejected invocation as approved; route bounded operator feedback to the same worker session, and require a fresh approval for the next commit attempt. Dropping the metadata turns rework into an ordinary action failure and sends the coding graph to `pipeline_error` (root cause confirmed 2026-07-11 after commit approval `rework` terminated `task_1262403`).

**Caller-configurable resource bounds need a system-enforced ceiling.** Adding `max_output_bytes`, `max_rows`, or a similar positive option does not make execution bounded if an agent can pass an arbitrarily large integer. Define a conservative default and a non-bypassable hard maximum at the enforcing layer, clamp or reject larger values consistently, mirror the maximum in schema-bounded adapters, and classify the parameter as control when it governs termination or resource use (found 2026-07-11 reviewing bounded shell output).

**Audit every runtime dispatch branch when adding a resource bound.** A timeout or output ceiling on the primary executor does not cover an alternate backend selected by syntax, feature flag, agent context, or authorization mode. Trace the public operation through every dispatch branch and either enforce identical bounds there or disable the unbounded branch by default; an action-schema option alone can otherwise advertise protection that the live path ignores (found 2026-07-11 when compound shell commands bypassed `Arbor.Shell.Executor` through `CapShell`).

**Pinned action bindings should fail after a live BEAM implementation reload.** A long-running compiled graph may reach a later action after that action's module has been recompiled and hot-loaded; the current descriptor then differs from the manifest and execution must stop with `action_binding_mismatch`. For live dogfood, compile into an isolated `MIX_BUILD_PATH` and avoid loading bound action modules into the running node mid-task. Recompile or restart before dispatch rather than weakening the binding check (confirmed 2026-07-11 during the shell security-profile replay).

**Do not verify against an active worker's mutable worktree.** A delegated coding loop can rewrite source while an external Mix command is compiling it, producing a mixed-revision build and failures that belong to neither commit. Wait for the worker's committed terminal snapshot or create a detached worktree at the exact commit, then run verification there with an isolated build path (found 2026-07-11 while Grok was applying council rework to security-attestation routing).

**Multi-module hot reload is not a transactional deployment boundary.** A compiler, profile registry, semantic validator, and template can be individually current while one request still crosses a mixed old/new call path at the end of a reload window. After reloading a policy bundle, run one live compile/authorization probe that exercises the whole bundle before dispatching durable work; retry only tasks that failed before acquiring resources (found 2026-07-11 when the first post-reload security-profile dispatch saw new attestation nodes with old topology expectations).

**The Coding Plan data contract is broader than the executable v1 feature set.** `Arbor.Contracts.Coding.Plan.new/1` can normalize optional policy fields that the current compiler intentionally rejects as `{:unsupported_v1_feature, field}`. Before dispatching live work, use only the executable profile subset (or run a compile probe); in particular, leave `rework.stop_conditions` empty until the compiler implements it. A preflight rejection before workspace acquisition is safe to correct and redispatch (found 2026-07-11 when terminal-approval cleanup was rejected before worker startup).

**Private per-dispatch options must not select executable cleanup code.** A caller that can reach a low-level task store directly can supply an arbitrary MFA even when the facade normally constructs that option. Fix stable lifecycle code at the store's trusted initialization boundary (with an explicit test-only seam if needed), and let per-task descriptors carry data only. Launch deferred work with module/function/args APIs rather than storing or spawning anonymous closures (found 2026-07-11 when council review rejected the first terminal-approval cleanup implementation).

**Module atoms are executable selectors, not inert descriptor data.** Moving an MFA out of a per-task record is incomplete if that record still chooses backend or audit modules that trusted cleanup code later invokes. Pin every executable module at the owner process's trusted initialization boundary; normalize per-task lifecycle descriptors to scalar provenance such as caller and trace IDs before storing them (found 2026-07-11 in the second terminal-approval cleanup council review).

**Publish terminal state before invoking optional cleanup infrastructure.** `Task.Supervisor.start_child/5` starts the child body asynchronously, but the call to the supervisor is synchronous and can itself stall. A task owner must commit result/status first, then hand cleanup scheduling to a named, non-closure launcher so an unhealthy cleanup supervisor cannot delay result availability (found 2026-07-11 in the second terminal-approval cleanup council review).

**A key-owning broker must authenticate lease acquisition, not only lease use.** An unguessable bearer token prevents reference forgery after issuance, but `open(agent_id)` still becomes a sign-as-any-principal deputy when the broker can resolve every stored key. Require fresh cryptographic possession proof bound to the principal, purpose, and actual owner at acquisition; verify it through the existing nonce/freshness path, and never retain the proof, signer callback, or raw key in broker state (found 2026-07-11 reviewing the first reload-stable signing-authority slice).

**Process monitors do not require trapping exits.** A GenServer that sets `Process.flag(:trap_exit, true)` only to monitor unrelated owners can convert its supervisor's shutdown signal into an ignored `{:EXIT, ...}` message, delaying termination until the supervisor kills it. Use monitors for owner lifecycle and leave linked supervisor exits at the OTP default unless the process has an explicit linked-exit protocol (found 2026-07-11 reviewing the signing-authority broker).

**An absolute `bin/mix` path does not select that checkout as the project root.** The wrapper inherits the shell's current directory, so invoking `/tmp/worktree/bin/mix test ...` while `cwd` is the main checkout silently tests main and can produce a false base/candidate proof. `cd` into the exact detached worktree (or set the command workdir) before every compile/test, then use an isolated build path tied to that checkout (found 2026-07-11 while proving the signing-authority acquisition regression on its parent).

**Tests must never move or rename live credential stores to simulate missing credentials.** A `try/after` around `~/.codex/auth.json`, `~/.grok/auth.json`, or `~/.arbor/oauth` still strands real credentials if the VM is killed between rename and restore, and can trigger unrelated authentication/keychain behavior while the test runs. Give discovery code an explicit disable flag or injected path/module and test against that seam; leave operator credential files untouched (found 2026-07-11 reviewing the provider-discovery baseline repair).

**When work moves into a shared loader, remove obsolete outer processing passes.** `ensure_graph/2` was changed to perform IR compilation, but public `compile/2` retained its old `IR.Compiler.compile/1` call. The second pass was merely wasteful for untouched graphs but recompiled post-IR custom transforms, restoring alias defaults and changing capability/taint/schema analysis contrary to the documented boundary. Trace the full facade path after centralizing work and add a regression whose transform/output distinguishes one pass from two (found 2026-07-11 while fixing authorized graph loaders).

**Check the current branch after a coding subagent reports completion.** A worker may commit directly to the shared branch rather than returning an external commit for cherry-pick, even when its changes were produced in an isolated execution context. Re-read `git status` and `git log` before integrating another branch so later work is based on the actual HEAD and an incomplete worker commit is corrected forward rather than duplicated (found 2026-07-11 during Agent baseline repair).

**A managed ACP handle lives only as long as its owning action unless an explicit durable owner retains it.** Calling `acp_start_session` as one standalone MCP action can return `status: "ready"` while the action's cleanup closes the worker immediately; a later standalone `acp_send_message` then returns `:not_found`. Multi-turn steering must stay inside the coding task owner (or use a deliberately pooled/durable session contract), and retained work should be resumed by a new task from an exact committed checkpoint rather than assuming the old worker handle survived (found 2026-07-11 after commit-approval rework terminated a coding pipeline).

**Repository Git hooks must use `./bin/mix`, not ambient `mix`.** A pre-commit hook that invokes raw `mix` can select the wrong Elixir/OTP pair and contend on a different build lock than the repository wrapper; it may spend minutes compiling dependencies and never reach the commit even though the staged change is valid. Run the pinned wrapper for format/tests, and fix the hook to use the same wrapper rather than treating `--no-verify` as the normal path (found 2026-07-11 while checkpointing the signing-authority Engine slice).

**Arbor's Git facade rejects configured execution hooks even when they point at Git's default directory.** An explicit local `core.hooksPath=.git/hooks` (or its absolute equivalent) is still executable repository configuration, so `Arbor.Actions.Git.execute/2` fails closed with `{:unsafe_git_configuration, "core.hookspath\n"}` and coding workspace acquisition reports `:invalid_git_repository`. If no global/system hook path overrides the default, remove the redundant local setting; the existing `.git/hooks` remain active through Git's normal lookup. Do not weaken the facade or misdiagnose this as a missing repository (found 2026-07-13 while delegating the Phase 6 fixture-hardening slice).

**Opaque IDs become paths when they are used as filenames.** `Path.join(dir, "#{run_id}.json")` does not make an untrusted run ID safe; `../` segments can escape the fallback store and turn an ordinary get/save operation into an arbitrary JSON read or write. Validate the identifier against a closed filename grammar or resolve the final path through `SafePath` before IO, and regress through the public persistence/action boundary for both reads and writes (found 2026-07-11 while moving eval fallback persistence to its owning library).

**A shared deadline must be checked after every child invocation, including the last one.** Passing the remaining budget into a subprocess is not sufficient if the runner can return a nominal success after that budget; a loop that returns `:complete` when no children remain can then accept an overrun. Measure from before runner setup and reject any result observed after the absolute monotonic deadline, even when it came from the final child (found 2026-07-11 reviewing per-app cross-app validation).

**Process output is arbitrary bytes until proven otherwise.** Shell and Port results can contain invalid UTF-8, so retaining them directly in JSON-clean Engine evidence can make `Jason.encode!/1` crash after the operation completed. Hash the original bytes, convert retained excerpts to valid UTF-8, and apply byte ceilings with boundary-safe truncation rather than `String.length/1` or grapheme slicing (found 2026-07-11 reviewing cross-app validation evidence).

**A `%Struct{}` pattern is not hostile-term shape validation.** A map carrying only `__struct__` and a subset of fields can satisfy the pattern, then raise on dot access or reach a shared broker with malformed data. Reconstruct opaque security references through their validating `new/1` factory using `Map.get/2` before reading fields or calling a broker, and return a shaped fail-closed error for partial struct-tagged maps (found 2026-07-11 reviewing SigningAuthority Engine propagation).

**A conformance harness is not a gate until production adapters and failure exit semantics exist.** Scripted callbacks are useful deterministic unit fixtures, but they do not prove that both real executors ran, selected different implementations, produced correct artifacts, or remained isolated. A benchmark command must invoke pinned production adapters, verify each result against the objective independently of pair equivalence, avoid process-global selector mutation, and exit nonzero when acceptance thresholds fail (found 2026-07-11 reviewing the first coding benchmark foundation).

**Outer task liveness does not imply the ACP worker session is steerable.** Once the implementation node closes its managed ACP session, the task can still be waiting on commit approval while `steer_task` correctly reports `task_terminal` for the worker stage. Deliver steering while the worker session is alive; after it closes, retain or commit an exact checkpoint and start a new delegated revision rather than assuming approval-wait state preserves the ACP handle (found 2026-07-11 trying to steer validator corrections at commit approval).

**`security_regression` coding-plan `requested_paths` are test selectors, not source scopes.** The compiler requires a non-empty list where every path ends in `_test.exs`; passing app directories or implementation files fails before workspace acquisition with `{:invalid_security_regression_paths, ...}`. Put the exact public behavioral regression test paths there and describe implementation ownership in the task prompt instead (found 2026-07-11 while dispatching the signing-authority spine correction).

**Acceptance must be derived from evidence, never trusted from a report summary.** A deterministic benchmark can execute nothing yet pass if `acceptance/1` reads only caller-supplied aggregate counts. Validate a closed, non-empty row/pair schema, recompute every aggregate from status-specific objective/lifecycle/artifact checks, and reject summaries that do not exactly match the derived result (found 2026-07-11 reviewing the coding conformance benchmark).

**Git porcelain is not a cleanliness proof until hidden index flags are neutralized.** `assume-unchanged` and `skip-worktree` can hide modified tracked files from ordinary status/diff checks, allowing false `no_changes`, clean-commit, or failure-side-effect claims. In isolated verification clones, reject or clear non-normal flags before hashing and comparing the actual index/worktree/HEAD state (found 2026-07-11 reviewing benchmark Git invariants).

**Path confinement checks must bind to the opened file, not only the pathname.** `lstat`/`realpath` followed by `File.read` is still check-then-use: a leaf or ancestor can be swapped to a symlink/FIFO between calls. Open once without accepting symlink indirection, inspect the handle's type/device/inode, compare it to the confined path and stable ancestors, read bounded bytes from that same handle, and recheck stability; otherwise fail closed (found 2026-07-11 reviewing benchmark artifact IO).

**Bound retained output and the work required to produce it.** A 2 KB excerpt is not a resource bound if invalid-UTF-8 repair recursively concatenates an 8 MiB stream or suffix extraction builds a codepoint list for the whole input. Hash raw bytes once, then sanitize bounded head/tail windows with linear iodata accumulation and inspect only a small UTF-8 boundary allowance (found 2026-07-11 reviewing cross-app validation evidence).

**A failed outer coding task may still have produced a committed branch.** Pipeline timeout, worker protocol repair failure, or terminal-result transport can occur after the worker committed. Before redispatching or declaring work lost, inspect the requested branch and retained worktree for an immutable commit; review that snapshot independently of the outer task status (found 2026-07-11 recovering cross-app and benchmark corrections).

**Plain detached Git worktrees do not inherit ignored dependency directories.** A manually created proof worktree usually has no `deps/`, so an isolated `MIX_BUILD_PATH` alone fails before tests. Point `MIX_DEPS_PATH` at the trusted main checkout's dependency cache (while keeping the build path isolated), or create the same reviewed dependency links as the workspace manager (found 2026-07-11 running parent security proofs).

**Derived summaries cannot replace independently recorded cleanup evidence.** If run-root cleanup is observed only while building a summary, later acceptance recomputation may incorrectly infer it from pair cleanup and let a coordinated summary rewrite forge success. Retain each security-relevant lifecycle observation outside caller-editable aggregates, require it in the closed report schema, and derive the summary from that evidence (found 2026-07-11 reviewing coding benchmark acceptance integrity).

**Closed JSON schemas need exact scalar types, not only keys and loose equality.** Elixir considers `1 == 1.0`, so a summary cross-check using `!=` can accept float aliases for integer counters. Validate bounded integer fields explicitly and use type-strict comparisons (`!==`) when the serialized contract distinguishes numeric representations (found 2026-07-11 reviewing coding benchmark summary validation).

**Temporary test roots must be collision-safe across BEAM invocations, not only within one VM.** `System.unique_integer/1` restarts with a new VM, so a predictable global `/tmp` path can collide with residue from an interrupted prior run. Allocate an exclusive random/OS-owned directory, register cleanup ownership before partial fixture construction, and regress stale-root behavior deterministically (found 2026-07-11 rerunning coding benchmark tests in an isolated worktree).

**A field accepted by the coding Plan contract may still be unsupported by the v1 compiler.** Non-empty `rework.stop_conditions` and non-nil `budgets.model_cost_usd` normalize successfully but dispatch fails before workspace acquisition with `{:unsupported_v1_feature, field}`; `budgets.parallelism` is executable only at `1`. For executable v1 dispatches, check `CodingPlan.Compiler.validate_supported_v1/1`, omit unsupported fields, and use the reviewed profile plus bounded `max_cycles`, `wall_clock_ms`, and `inactivity_timeout_ms` instead (found 2026-07-11 redispatching Phase 6 corrections).

**`arbor.recompile` cannot repair every loaded-object mismatch.** It delegates to `IEx.Helpers.recompile/0`, which recompiles changed source; if the on-disk BEAM is current but the long-running VM still has an older object loaded, it can return success/noop while execution-manifest checks continue failing with `execution_module_loaded_code_mismatch`. Reload the exact reviewed modules explicitly or use the purpose-built `arbor.restart` between delegated runs when no task is active (found 2026-07-11 after integrating Engine handler changes).

**Approval waiters must subscribe before making a request externally visible.** Creating an InteractionRouter IRQ and only then spawning a PubSub subscriber leaves a lost-response window: a fast MCP approver can resolve and remove the request before the waiter exists, so an approved invocation executes zero times and eventually times out. Subscribe before authorization/request publication or retain a durable resolved response retrievable by request ID; never hide the race with `Process.sleep/1` in tests (found 2026-07-11 reviewing commit-approval rework).

**A rework loop must gate clean self-commits as well as dirty worktrees.** Routing a post-rework clean worktree directly to `adopt_head_commit` lets the delegated worker self-commit and bypass the promised fresh human commit approval. Bind the gate to the candidate revision/adoption outcome on every rework path, enforce it in graph/action semantics, and regress with a worker that commits during the rework turn (found 2026-07-11 reviewing commit-approval rework).

**Do not put workflow-specific result policy in a generic Engine handler.** Teaching `ExecHandler` that a `git_commit` denial can become branchable success violates the handler-as-opcode invariant and creates an author-controlled denial-bypass surface. Put commit approval/deny/rework semantics in a capability-gated Jido action and let the reviewed graph branch on ordinary action data; keep handler schemas generic (found 2026-07-11 reviewing commit-approval rework).

**Starting an agent with `start_session: false` does not disable autonomous heartbeats.** `Lifecycle.start/2` derives HeartbeatService separately and defaults `start_heartbeat` to true, so a coordinator started only for async dispatch can still run background checks and create unrelated shell approvals. For a dispatch-only coding coordinator use both `start_session: false` and `start_heartbeat: false`; do not answer heartbeat approvals as though they belonged to the delegated task (found 2026-07-11 after restarting the local Arbor server).

**A security regression must reach the exact field that was vulnerable.** A nearby counter or earlier closed-schema rejection can make a test fail while never exercising the cleanup flag, scalar alias, or identity check named in the claim. Keep each regression independent, mutate only the vulnerable field where possible, and overlay that exact test on the exact parent so an earlier guard cannot mask the intended failure (found 2026-07-11 reviewing coding benchmark parent evidence).

**Verify static runtime API claims against the pinned toolchain when executable evidence disagrees.** Documentation or memory about an Erlang option can be stale across OTP releases; if a public behavioral test succeeds on the repository's pinned runtime, reproduce the disputed call directly there before redesigning around an assumed incompatibility. Treat the observed pinned behavior as evidence while still checking portability deliberately (found 2026-07-11 reviewing `:file.open` mode handling in eval persistence).

**The public task-control facade remains usable when a client has not exposed a steering MCP tool.** `Arbor.Agent.Orchestration.steer_task/3` still performs exact task/delegator authorization and persists the control through TaskStore; invoke it with the authenticated caller identity through a trusted local RPC surface rather than mutating worker state directly. A control queued as `same_session_follow_up` while ACP is inside a blocking turn is not delivered yet and must remain visibly queued until that session accepts it (found 2026-07-11 steering the commit-approval R3 correction).

**A one-pass green race regression is not evidence of stability.** Concurrency, timeout, cleanup, and mutation tests must run repeatedly with `--repeat-until-failure` (or an equivalent deterministic stress loop) before sign-off. Replace startup sleeps with explicit ready/accepted handshakes and register teardown before the concurrent actor starts; a candidate that passed once returned a hash on the very next repeated run while its file was being rewritten (found 2026-07-11 reviewing eval persistence R3).

**Pinned OTP file timestamps may be too coarse to prove same-read stability.** On OTP 28.4.1, `time: :native` returns `{:error, :badarg}` and `time: :posix` exposes second-resolution mtime/ctime, so full metadata comparison can miss same-second, same-inode rewrites. Under a trusted owner-only root, read/hash the captured exact size twice from the same handle with EOF probes and require identical content digests plus stable metadata; document this as stable-content evidence, not a hostile atomic-snapshot guarantee (found 2026-07-11 after the persistence mutation regression failed under repetition).

**Caller-writable ETS is not independent evidence.** A `:public` cleanup table created by whichever benchmark caller arrives first can be forged, disappears with that owner, and grows without TTL; copying its value into a recomputed summary only moves the trust problem. Security-relevant run evidence needs a dedicated bounded owner, opaque owner-bound lifecycle, proactive expiry, and a fail-closed restart contract (found 2026-07-11 reviewing coding benchmark R6).

**Do not ship production-callable test hooks that alter security observations.** Public `__test_*` setters backed by process dictionaries or ETS can let same-process code replace file identity, random-token, or cleanup evidence in real execution. Thread deterministic callbacks only through an explicitly test-only execution seam that the public production path rejects, or use a separately injected test owner; keep the enforcing module identical in its security decisions (found 2026-07-11 reviewing benchmark inode and run-root tests).

**Test doubles must not create production authorization bypasses.** Never mark a request identity-verified merely because a signer returned a noncanonical map so unit tests can use a stub. Production code must accept and verify the same typed proof it requires in reality; tests should construct a real proof or inject behind an explicitly test-only boundary that runtime input cannot select (found 2026-07-11 while reviewing the coding commit approval redesign).

**Git HEAD does not identify an uncommitted candidate.** Binding approval to `HEAD` alone protects a clean commit/adoption path, but a dirty worktree can change arbitrarily while `HEAD` remains constant. Any approval or attestation over pre-commit content must bind a stable tree/diff fingerprint and reverify it after the wait, or commit first and bind the resulting immutable commit (found 2026-07-11 while reviewing `coding_reviewed_commit`).

**A grapheme-count limit is not a byte or work limit.** One valid Unicode grapheme can contain arbitrarily many combining codepoints, so `String.slice(text, 0, 512)` can retain and traverse many kilobytes while claiming a 512-character bound. Resource ceilings for prompts, diagnostics, and persisted output must check bytes first and truncate on a valid UTF-8 byte boundary; add combining-sequence regressions that assert `byte_size/1` (found 2026-07-11 reviewing AI eval output bounds).

**Arbitrary integers bypass fixed scalar cost estimates.** Treating every number as 32 estimated bytes before JSON encoding still admits a bignum with millions of decimal digits, and converting it with `value * 1.0` can raise before a later clamp. Bound integer bit size before encoding or arithmetic, and compare/reject before float conversion (found 2026-07-11 reviewing eval fingerprints and intent grading).

**Executable v1 coding plans use `workspace_policy.mode="isolated"`.** The intuitive value `"new"` is not part of the closed v1 contract and fails before workspace acquisition. The v1 compiler also requires `task_class` to match `validation_profile` (for example both `"cross_app"`); describe additional security-test obligations in the task rather than mixing profile names (found 2026-07-11 dispatching the approval-authority correction).

**Template trust-policy changes do not retroactively update existing agents.** Restarting an agent preserves its stored `Arbor.Trust` profile, so a long-lived coding coordinator can hold newly granted action capabilities while its older baseline/rules still block them. Before dogfooding a newly added template capability, compare the live stored profile with the shipped template preset and explicitly reconcile through the Trust facade; do not diagnose the resulting capability-granted/trust-denied sequence as a worker or validator failure (found 2026-07-11 when cross-app validation and council review-tree reads failed for a reused coordinator).

**A command-name policy cannot enforce an argument-sensitive shell safety floor.** The pinned Bash `CommandPolicy` callback receives only command name and category, so it cannot see opaque payloads such as `sh -c`, `find -exec`, or `awk system(...)`, nor Arbor's dangerous flags. Do not claim capability-safe compound execution from that callback alone: add an argv-aware runtime gate or reject interpreter/wrapper and dynamically constructed forms fail closed, and keep the feature disabled while that boundary is incomplete (found 2026-07-11 reviewing CapShell resource-bound dogfood).

**Trace the actual external-process owner on every execution branch before claiming tree cleanup.** In the pinned Bash/ExCmd path, the Session owns ordinary foreground `ExCmd.Process` instances, while background jobs introduce a `JobProcess` and a separate worker that creates ExCmd; killing the Session is therefore not one uniform cleanup proof. Timeout/cancellation tests must exercise foreground, pipeline, background, and coprocess branches or reject unsupported branches before launch (found 2026-07-11 reviewing CapShell timeout ownership).

**Dominance over named success terminals does not gate the side effects that precede them.** A semantic preflight can prove that `status_pr_created` is review-dominated while still accepting an allowlisted `git_pr` action injected before validation that rejoins the normal graph afterward. Constrain each side-effecting action to reviewed node identities/topology or prove the relevant gate dominates every occurrence of that action; terminal-only publication checks are insufficient (found 2026-07-11 with an executable early-PR compiler probe).

**A process-dictionary authorization marker is not an opaque capability.** Any code running in the process can reproduce a predictable key/value and call the downstream public facade directly, so an internal `Process.put` preauthorization shortcut can turn double-authorization cleanup into a bypass. Carry owner-bound authority as an unforgeable broker reference, consume it at one explicit boundary, and make nested execution use a non-public owner path rather than a guessable ambient marker (found 2026-07-11 reviewing the one-shot approved-invocation branch).

**A GenServer `from` tuple is protocol data, not authenticated process identity.** Any local process can send a raw `{:\"$gen_call\", from, request}` message containing another PID, so extracting `elem(from, 0)` cannot prove who submitted an admission, result, or evidence mutation. Keep security-relevant authority inside one owner process or use an opaque owner-generated reference bound to a monitored generation; never authorize from caller-supplied GenServer envelope fields (found 2026-07-11 reviewing the coding benchmark coordinator).

**Disable the authority mismatch, not only one compound-shell implementation.** Stubbing CapShell still leaves a bypass if `ExecuteScript`, async/streaming authorization, a DOT shell handler, or `sandbox: :none` authorizes only the leading token and then executes the whole compound string. Agent-facing shell boundaries must reject compound input before authorization, approval creation, temporary files, sessions, or processes until runtime-expanded argv and process ownership can be proven; reserve unchecked compound execution for explicit trusted-system APIs (found 2026-07-11 reviewing the CapShell fail-closed correction).

**A terminal steering control must not remain `queued`.** When an executor accepts a control but the task fails or is cancelled before delivery acknowledgement, the outcome is terminally delivery-unconfirmed, not retryable queue state. Project it under an explicit terminal status and preserve the error/evidence separately; otherwise status counts imply work can still be delivered after the owner has exited (found 2026-07-11 when a queued ACP follow-up ended in `worker_protocol_invalid_json_after_retry`).

**A determinate timeout requires proof that no later commit can occur.** Checking a deadline before a state transform, database lock, or backend mutation is insufficient: the caller can time out while the owner continues and commits afterward. Carry one absolute monotonic deadline through queueing, lock acquisition, work, and commit; post-check before publishing mutable state, use backend-side cancellation for database work, and return an indeterminate outcome whenever commit status cannot be observed exactly (found 2026-07-11 with live Agent, PostgreSQL advisory-lock, and SQLite busy-timeout EventLog probes).

**BEAM references are correlation identifiers, not bearer secrets.** `make_ref/0` values are sequential enough that a nearby exposed timer/monitor reference plus a digest oracle can reveal a worker-completion token on the pinned OTP runtime. Generate completion authority from cryptographically random bytes, keep it out of observable state/timers/logs, bind it to the exact run generation, and consume it once (found 2026-07-11 forging a supervised coding-benchmark result from an adjacent timer reference).

**Cleanup absence checks must distinguish absent from unqueryable.** A boolean helper that maps every failing `git show-ref` or worktree query to `false` can issue a verified receipt while the repository is unavailable. Use tri-state queries, accept only the command's exact not-found outcome as absence, and fail closed on every transport, permission, timeout, or parse error (found 2026-07-11 reviewing workspace cleanup receipts).

**Canonicalize resource identity before deleting the resource.** Realpath behavior changes after removal: on macOS a live `/var/...` path may resolve to `/private/var/...`, then fall back to lexical `/var/...` once absent, allowing a stale Git registration to evade an exact-path comparison. Capture the canonical identity while the path and parent exist, retain it in the lease, and compare later observations against that stable identity (found 2026-07-11 reviewing verified worktree cleanup).

**Verified preservation is not verified cleanup.** Releasing a reused worktree may correctly prove that its path, registration, and branch survived, but that evidence cannot set `cleanup_verified: true` or satisfy a consumer that requires resource removal. Use distinct receipt/status fields and require owned-path absence plus unregistration for cleanup acceptance (found 2026-07-11 reviewing benchmark workspace cleanup evidence).

**Batch response order is not input order when the protocol supplies indices.** Embedding and fan-out APIs must validate response indices as unique, complete, bounded integers and reorder by those indices before associating results with inputs. Preserving wire order can silently attach a valid result to the wrong request even when every vector passes shape validation (found 2026-07-11 reversing an OpenAI-compatible embedding batch response).

**Resource bounds belong at the public facade, not only one adapter.** A bounded Finch/SSE implementation does not protect `generate_object`, tool-argument decoding, OAuth transports, or injected adapters that still call `Jason.decode/1`, buffer an enumerable, or use inactivity timeouts directly. Enforce structural decode, aggregate retention, absolute deadline, and owned-stream teardown at every public entry point; adapters may tighten but never bypass the floor (found 2026-07-11 reviewing the LLM/AI eval boundary).

**Secret-bearing GenServers need explicit status redaction.** Redacted struct `Inspect` implementations do not protect a broker whose raw state map uses bearer tokens as keys or stores session/root private keys. Implement bounded `format_status/2`, keep secrets out of crash metadata and error tuples, and regress `:sys`/status formatting for every authority owner (found 2026-07-11 reviewing verified-request and execution-permit brokers).

**Term serialization bounds must include integer bit size before encoding.** Counting every integer as a fixed scalar lets a hostile bignum allocate megabytes in `term_to_binary/2` before a post-encode byte check can reject it. Bound signed integer magnitude/bit length during the structural walk, then encode only the already bounded term (found 2026-07-11 reviewing execution-proof payloads).

**A bearer stripped from public views can still leak through action results.** Returning a lease credential from a Jido action puts it into Engine context, checkpoints, and node status even if `public_view/1`, receipts, and signals redact it. Keep compatibility credentials inside the owning registry boundary; graph actions should use authenticated task/principal authority and return only non-authority descriptors (found 2026-07-11 reviewing workspace cleanup R2).

**Umbrella runtime config must not execute modules from an optional child app.** `config/runtime.exs` is evaluated when a lower-level child runs independently, so calling `Arbor.Agent.Config` there made `arbor_security` fail before its tests because `arbor_agent` was not compiled or loaded. Keep runtime config data-only; validate an app-specific environment selector inside that app's startup boundary, where the module and its dependencies are guaranteed to exist (found 2026-07-11 running the isolated Security suite).

**A nested map inside action context is still action-visible authority.** Moving a bearer from `context.signing_authority` to `context.nested_engine_opts.signing_authority` does not make it process-private; every Jido action receiving that context can still inspect, return, or log it. Carry secret nested-engine controls through an exact-action private facade/envelope, or expose them only to modules with an explicit facade-owned need declaration; ordinary actions must receive neither the top-level nor nested bearer (found 2026-07-11 from the full Orchestrator signing-authority regression).

**`format_status/2` does not make secret-bearing GenServer state private.** It can redact crash/status formatting, but local code can still call `:sys.get_state/1` and receive the raw state. Do not retain bearer tokens or private authority in long-lived GenServer state at all; keep them in a private owner/ETS boundary or consume them entirely inside the exact request process (found 2026-07-11 probing the MCP verified-request handler).

**A mismatched-reference regression does not cover an exactly copied internal message.** If a completion PID/ref/token is visible in GenServer state, an attacker can copy the entire expected tuple rather than guess one field. Regress the exact copied envelope and raw OTP protocol messages; bind completion to cryptorandom one-shot authority that is absent from observable owner state (found 2026-07-11 forging TaskStore approval-cleanup completion).

**Route-specific proof minting must refine generic authentication, not replace it.** Forcing every signed HTTP request through an MCP POST/body parser broke valid signed GET routes. Verify the generic method/path/body contract first, then mint a specialized one-shot intent only after the exact route/tool operation is identified (found 2026-07-11 reviewing the verified approval-answer boundary).

**Phoenix.Tracker is a distributed projection, not a first-writer CAS.** Concurrent node owners can publish conflicting metadata, tracking failure may be ignored, and lookup order is not a conflict-resolution protocol. Security-relevant answer/idempotence state needs an atomic shared durable backend; use Tracker/PubSub only after the source-of-truth commit and fail closed when that backend is unavailable (found 2026-07-11 reviewing cluster approval answers).

**A persisted fingerprint marker is not proof of persisted content.** A competing or legacy writer can copy an operation ID and claimed digest into metadata while storing different type/data/actor fields. Reconciliation must reconstruct the actual durable row and recompute its fingerprint over every bound field; reserved metadata may locate an operation but must never authenticate it, and all fingerprinted fields must round-trip through every backend (found 2026-07-11 reviewing EventStore append reconciliation).

**Private ETS does not protect authority from its owning GenServer's `:sys` callbacks.** `:sys.replace_state/2` executes the supplied callback inside the target process, where that callback can read the owner's private ETS tables and exfiltrate a token. A plain sensitive owner that does not implement OTP system messages closes this specific introspection path and is useful Layer-0 defense in depth, but it does not satisfy the T4 same-VM-compromise threat: tracing, code loading, or other first-party calls still run inside the same trusted address space. If T4 is the acceptance criterion, move the authority behind an authenticated OS-process or separate-cluster boundary; moving the token to another GenServer or adding `format_status` is insufficient (found 2026-07-11 exploiting the benchmark RunCoordinator; assurance boundary clarified 2026-07-11).

**Every Engine handler must derive principal identity from `RunAuthorization`, not node attributes.** Fixing the action handler is insufficient if `ShellHandler` or `ToolHandler` still prefers author-controlled `agent_id` or falls back to `"system"`; a graph can then move authorization to a different principal. Bind all side-effecting handler branches to the immutable execution principal and reject absent authority on agent-authored runs (found 2026-07-11 reviewing the shell boundary correction).

**A generic Engine node capability does not replace the syscall's exact capability gate.** `ToolHandler` executing a prepared command under `arbor://orchestrator/execute/tool` still bypasses `arbor://shell/exec/<command>` if it calls the shell executor directly. Every handler branch that crosses into a side-effecting subsystem must invoke that subsystem's public authorized facade with the immutable run principal before hooks or execution (found 2026-07-11 reviewing the DOT tool-command path).

**A GenServer wrapper does not make a named DETS table private.** Any same-VM process that knows the table name can call `:dets.lookup/2`, `insert/2`, or `delete/2` directly and bypass the owner's serialized CAS logic. Keep security-authoritative mutable state behind a genuinely private owner boundary, authenticate durable records, and test direct storage mutation; also make record+index transitions reconstructable across crashes (found 2026-07-11 reviewing the local approval backend).

**An absolute deadline needs an owner-stamped completion time.** Checking the clock only when a caller receives a result is not enough: a suspended caller can later accept a success that completed after its deadline, while checking only the receive time can reject a result that completed on time. The operation owner must stamp `completed_mono` before sending the result, and the receiver must compare that immutable timestamp with the original deadline; inactivity timeouts are not a substitute (found 2026-07-11 suspending LLM/eval callers across their deadlines).

**Network destination policy is operator authority, not a request option.** A public helper that accepts caller-defined proxy prefixes, arbitrary OAuth discovery URLs, or widened private-address allowances turns endpoint validation into an SSRF bypass. Keep exact trusted origins and local-provider exceptions in startup configuration, clamp request options to that policy, validate every transport path consistently, and never match credential destinations by hostname substring (found 2026-07-11 reviewing LLM, retrieval, and OAuth endpoint gates).

**Killing a Port owner does not prove its descendants stopped.** Timeout, cancellation, or output-limit code that sends SIGKILL only to the immediate OS PID can return while Git hooks, Mix children, helpers, or detached subprocesses continue side effects. Launch untrusted external work in an owned process group/container, terminate the whole group on every terminal path, await verified group exhaustion, and regress with delayed descendant markers (found 2026-07-11 reviewing the direct-argv shell correction).

**Task and principal IDs are provenance labels, not operation authority.** Requiring an exact non-empty `task_id` plus `principal_id` stops accidental cross-task access, but both values are observable and can be copied into a direct registry call or raw message. The enforcing storage owner must receive an authenticated facade-issued proof bound to that exact operation/task/principal, or perform the mutation inside the authenticated facade; do not treat matching scalar fields as a capability (found 2026-07-11 reviewing workspace cleanup receipts).

**A public trust anchor is security-critical mutable state even though it is not secret.** Keeping a verifier root public key in ordinary GenServer state lets `:sys.replace_state/2` substitute an attacker root and admit an entirely forged proof chain. Pinning trust anchors outside OTP system-message state (or in a plain sensitive owner initialized from trusted static configuration) closes that Layer-0 mutation path; it is not isolation from arbitrary same-VM code. Reject runtime replacement and regress full attacker-root session activation for the assurance layer being claimed; use an external verifier/policy boundary when T4 resistance is required (found 2026-07-11 reviewing pipeline execution provenance; assurance boundary clarified 2026-07-11).

**Label every security regression with the assurance layer it proves.** `docs/arbor/SECURITY_ARCHITECTURE.md` explicitly concedes T4 (arbitrary compromised-agent code inside the BEAM) at current Layer 0 and assigns key isolation to the target external-signer architecture. A malicious graph/tool input, ACP worker, shell child, persisted file, or public API caller is a current-layer adversary; a test that uses `:sys.replace_state`, process tracing, direct internal-module calls, code loading, or arbitrary mailbox injection demonstrates same-VM compromise instead. Opaque refs, private owner protocols, status redaction, and closed facades are still worthwhile defense in depth, but do not describe them as T4 boundaries. When T4 is required, use a separate OS process/UID or a separate cluster behind authenticated non-distribution transport; Erlang distribution mesh membership is code-execution authority, not isolation (clarified 2026-07-11 after Phase 6 corrections were being rejected against target-layer guarantees using Layer-0 mechanisms).

**Long-lived signing roots must not live in the application environment.** `System.get_env/1` is readable by every module in the VM and inherited by ordinary subprocesses, so storing a private root there lets any action certify arbitrary sessions. Arbor should hold only the public key and a non-secret endpoint for an independently launched signer; remove the private value from the Arbor process environment and fail closed when the external authority is unavailable (found 2026-07-11 with a child-process execution-root probe).

**An action cannot self-declare access to private nested authority.** A callback such as `nested_engine_context_keys/0` is implemented by the action module itself, so treating it as an allowlist lets any newly loaded action request signer, permit, or private-key material. Keep the permitted module/operation set in the trusted facade, expose exact closed methods for those operations, and never insert a generic credential bag into action context (found 2026-07-11 stealing nested signing authority from a test action).

**Caller timeout does not cancel a queued owner mutation.** A bounded `GenServer.call/3` can return timeout while its request remains in the mailbox and later consumes a permit or commits state. Put the caller's absolute deadline inside the request, check it in the owner immediately before mutation, and return indeterminate plus exact reconciliation only when the outcome cannot be proven; the call timeout alone is not the operation deadline (found 2026-07-11 suspending the execution-permit broker).

**Make multi-agent rework monotonic with a frozen finding ledger.** Resume the original implementation agent in its existing conversation and worktree so it retains the accepted code and prior reasoning; use fresh reviewers only for independent discovery. For ACP workers, look up the pooled session and durable provider conversation ID first: the pool exists specifically to preserve provider context across follow-up/rework calls, even when the ACP process is reopened. Fall back to worktree + commits + ledger only after that provider session is proven unavailable or expired. After each review, classify findings as fixed, open, new regression, or architectural blocker, freeze the fixed set, and ask the prior reviewer to recheck only the remaining ledger plus regressions introduced by the correction. Preserve additive commits and exact parent probes instead of restarting the slice. After repeated rounds, extract a genuine architectural mismatch into its own tracked item rather than repeatedly weakening or locally patching the same boundary (adopted 2026-07-12 after Phase 6 review rounds showed high rejection counts despite substantial accepted progress; ACP continuity corrected 2026-07-12).

**ACP continuity requires the provider session ID, not only the managed worker handle.** `worker_session_id` (`acp_worker_*`) is an owner-scoped live registry handle; `acp_close_session` or owner death invalidates it. The ACP provider's `worker.session_id` is the durable conversation identity consumed by `load_session`. A coding graph must opt into pooled execution, preserve/project that provider ID before closing or checking in the worker, and pass it through a later authorized start to resume context. Returning only the closed managed handle is not resumability. When diagnosing an older run, recover the provider ID from the `open_worker/status.json` checkpoint if the public result dropped it (found 2026-07-12 tracing `task_167682`, whose non-pooled graph retained provider session `019f52ad-dfb1-7d33-8156-effae2a1c9fa` only in the checkpoint).

**A durable ACP provider session may still be bound to its original workspace.** Reopening a valid Grok provider session from a newly allocated worktree returned `FS_NOT_FOUND` even though the provider conversation ID and both worktrees still existed. Do not equate "new worktree + resume_session_id" with continuity. Reactivate the retained original workspace for follow-up work, or use a provider protocol that explicitly supports rebinding the session cwd; otherwise classify the attempt as resume-unavailable and preserve the candidate commit before falling back to a fresh session (found 2026-07-13 when `task_37699` tried to resume the `task_35331` worker on a review-rework worktree).

**Budget agent work by model/provider, but distinguish native subagents from ACP workers.** Keep the coordinating parent on architecture, delegation, integration, and final judgment; send substantial implementation to resumable ACP workers such as Grok or GPT-5.3-Codex-Spark; use a faster/cheaper native Codex subagent only for bounded mechanical work; reserve stronger agents for security review and cross-library design. Inspect `spawn_agent`'s advertised model overrides before choosing a native subagent, and inspect Arbor's ACP provider registry separately: absence from `spawn_agent` does not imply a subscription-backed model is unavailable through ACP. Limit active concurrency, close completed native agents immediately, reuse author/reviewer threads and provider session IDs with frozen ledgers, and avoid `fork_context: true` unless the worker genuinely needs the full history (adopted 2026-07-12 after repeated parent-model capacity stalls; ACP Spark lane clarified 2026-07-12).

**Model budgeting is a portfolio problem, not a single dollar counter.** Centrally inventory each provider/model route, credential or subscription pool, reset window, concurrency limit, context/output limits, capability/tool support, latency/reliability history, sensitivity ceiling, and marginal cost. Subscription-backed OpenAI, Anthropic, Ollama, xAI, Z.ai, and Google capacity should be tracked as quota pools alongside metered OpenRouter, Groq, Venice, and direct API balances. Route by task requirements and opportunity cost, reserve scarce frontier capacity for architecture/security/final judgment, and record actual usage/outcomes so routing can improve from evidence rather than static model rankings (requested 2026-07-12).

**Arbor's model-budget foundation is built but not yet one routing control plane.** `Arbor.AI.BudgetTracker`, `QuotaTracker`, and `UsageStats` already persist spend, cooldowns, latency, and outcomes, while mandatory Engine budget middleware expects a separate `check_budget/0` + `record_usage/1` tracker contract. `QuotaTracker.check_and_mark/2` has no production error-path caller, and the AI budget tracker infers subscription use from model names such as `-cli`; an ACP Codex subscription model can therefore be classified like a metered OpenAI API call after provider normalization. Extend and reconcile these components rather than creating a fourth tracker: preserve route/credential-pool provenance through every call, feed quota failures into availability, and make routing consume the unified portfolio state (traced 2026-07-12 after discussing multi-provider budgeting).

**Compute-node usage must attribute the resolved request route, not session defaults.** A DOT node can pin `llm_provider` and `llm_model`; `build_llm_request/4` correctly gives those attrs priority, but `LlmHandler` currently logs, signals, and writes `session.usage` from `session.llm_provider` / `session.llm_model`. The multi-model review council therefore executed its pinned Ollama/OpenAI/xAI routes while observability reported blank provider/model fields. Resolve the effective route once (including sensitivity/fallback changes), then thread that identity through telemetry, usage, consultation records, and budgets so portfolio accounting is not silently wrong (found 2026-07-12 auditing council routing).

**A copied OAuth refresh token can be invalidated by its source CLI.** Arbor imports Codex/Grok credentials into `~/.arbor/oauth` and then prefers that copy, but the provider CLI can independently rotate the same single-use refresh-token lineage. The stale Arbor copy then fails with `refresh_token_reused` even while the CLI's newer access token works. Do not delete auth files to unblock a probe. On that explicit rotation error, safely compare/reimport the current CLI token set (without logging secrets), preserve Arbor-owned write permissions, and retry at most once; make the token store/refresh transport injectable so the race and fail-closed behavior have hermetic tests (found 2026-07-12 validating `gpt-5.6-sol` for the review council).

**A userspace deadline check cannot hard-bound a later blocking kernel commit.** Checking `CLOCK_MONOTONIC` immediately before `rename`, `fsync`, ref-CAS, or another syscall still leaves a scheduling/blocking interval before the kernel linearization point; an interposed or stalled syscall can commit after the deadline. Do not respond by adding ever-closer prechecks and claiming a hard guarantee. Either use an OS primitive whose transaction is deadline/cancellation-bound, isolate the operation behind an owner the kernel can terminate before linearization, or define the public result as indeterminate with exact reconciliation/compensation. If none is available, record an assurance-layer architecture blocker rather than repeatedly rejecting otherwise correct local patches (found 2026-07-12 after benchmark R5 passed conservative BEAM/native deadline mapping but a delayed `renameatx_np` still published late).

**Separate source-of-truth commit from derived-state synchronization.** Git ref publication and real-index update are two independent durable resources; no ordinary Git primitive atomically commits both. Pick the authoritative commit, report an indeterminate/reconciliation-required result if the derived update fails, and make repair idempotent. Never return unconditional success after a best-effort derived update, but also do not demand impossible cross-resource atomicity from another local retry loop (clarified 2026-07-12 during reviewed-commit provenance R3).

**Stable structured coding plans require a review-bearing profile and only their executable feature subset.** The compiled `coding_change` path rejects `review_profile: "none"` before workspace allocation. Use `human_required` when the local delegator will perform the binding review, or `binding` when the configured council should decide; do not use a no-review profile merely to save reviewer tokens. Also, contract-valid optional fields are not necessarily executable in v1: custom `rework.stop_conditions` currently fails preflight with `unsupported_v1_feature`, so omit it and use the compiled profile defaults until that feature is implemented (confirmed 2026-07-13 dispatching the eval DOT last-mile slice).

**A Port `:env` option is an override list, not an empty environment.** Variables omitted from `Port.open/2` remain inherited from the Arbor VM, so passing only a pinned `PATH` still exposes ambient credentials to an authorized `printenv` child. Agent-facing sync, async, and streaming execution must force a shared deny-by-default environment that explicitly unsets inherited keys before adding the small internal allowlist; caller options and `sandbox: :none` must not disable it (found 2026-07-13 while designing the spawn-capable containment boundary).

**Consume optional cross-library capabilities through the owning facade and its real contract.** A caller that probes an invented backend callback such as `backend.durability_class/0` can reject a valid Store implementation whose supported contract is exposed as `Arbor.Persistence.durability_class/3`. Check the facade and callback arity before adding capability detection, and keep backend options flowing through that facade (found 2026-07-13 reviewing durable engine lifecycle admission).

**Injected storage identity must thread through every operation, not only capability probes.** Accepting `server:` or backend options for a durability check while later discovery, claim, settlement, or recovery calls silently use the global default creates a split-brain workflow. Carry one normalized store target through every read and mutation, and regress with a non-default store whose global peer contains conflicting data (found 2026-07-13 reviewing RunJournal recovery wiring).

**Preserve a stalled delegated worktree before starting a replacement worker.** When an ACP run exits with useful uncommitted changes, use `git stash create` to capture the tracked work without altering the retained worker directory, then point a named preservation branch at that commit. A correction can start from the exact preserved state while the original workspace remains available for diagnosis and provider-session recovery (adopted 2026-07-13 after the spawn-containment R10 worker transport failed).

**A structured coding dispatch has a closed two-level envelope.** The outer task contains only `kind: "coding_change"` and `plan`; execution policy such as workspace, worker, review, rework, budgets, and output belongs inside the versioned plan. Validate the plan against both `Arbor.Contracts.Coding.Plan` and the current compiler subset: a field may be contract-valid yet still fail preflight as `unsupported_v1_feature` (found 2026-07-13 re-dispatching the spawn-containment correction).

**Containment tests that discover the reviewed Mix wrapper need a worktree-local build path.** Sharing `MIX_DEPS_PATH` into an isolated worktree is safe, but pointing `MIX_BUILD_PATH` outside the repo makes the loaded `arbor_actions` BEAM path lead to that external build root, so `Arbor.Actions.Mix.resolve_mix_wrapper/0` correctly cannot prove the repo-owned `bin/mix` identity and fails closed with `:mix_wrapper_unavailable`. For this suite, leave `_build` inside the isolated worktree and share only dependencies; an external build path is still appropriate for tests that do not intentionally derive a source/runtime root from loaded code (found 2026-07-13 while independently validating Spawn Containment Slice 1 R11).

**Exclusive-create failure does not grant cleanup ownership.** If `File.mkdir/1` returns `:eexist`, the caller must reject or retry without deleting that path; an unconditional `after`/error cleanup can erase an attacker-created or concurrent invocation's directory even though this invocation never owned it. Carry an explicit created/owned identity into cleanup, verify that identity before removal where feasible, and regress a pre-existing path with a marker that must survive the fail-closed result (found 2026-07-13 probing the tree-binding private-root collision path).

**A late identity observation cannot prove exclusive-create ownership.** After creating a cleanup root, capture its stable device/inode/type identity before doing work. If that first capture fails, leave the path in place and fail closed; recapturing an identity during cleanup can observe a replacement path and incorrectly authorize its deletion (found 2026-07-13 proving the tree-binding cleanup regression against its prior revision).

**Apple `container` networking must request the reserved `none` network explicitly.** In `container` 1.1.0, omitting `--network` attaches the built-in `default` NAT network, while `--network none` is a reserved CLI value that sets the container's network attachments to an empty list. For spawn containment, require exactly `--network none` and prove the guest has no network interface; `--no-dns`, an omitted/empty option list, or an `--internal` network is a weaker policy (found 2026-07-13 while designing Spawn Containment Slice 2 against the official sources).

**A public helper that accepts arbitrary paths is an authority surface.** Registry-internal filesystem machinery must stay private or require the same owner-issued lease/capability as its public workflow; module naming and `@doc false` do not prevent in-process candidate code from calling an exported function. Regress by invoking the former export and proving it cannot create the caller-selected destination (found 2026-07-13 reviewing the validation dependency snapshot helper).

**Distribution readiness is not application readiness.** `mix arbor.start` currently reports success when the named BEAM responds to distribution pings, but a later umbrella application can still fail and tear the node down before Gateway binds. After every restart, poll `http://127.0.0.1:4000/health` and inspect the daemon log if the process exits; do not dispatch work from the startup banner alone (found 2026-07-13 recovering the Phase 6 delegator runtime).

**A worktree changes relative durable-store identity.** Arbor Security's JSONFile backend resolves `.arbor/security` from the server process CWD, so a server launched from a disposable worktree sees a new empty identity/capability/signing-key universe even when it uses the normal master key. For an intentional recovery runtime, explicitly bind the canonical project security store before startup; do not weaken signed-request auth or recreate agent authority piecemeal (found 2026-07-13 recovering the Phase 6 delegator runtime).

**Every persistence migration must run on every supported development adapter.** Arbor defaults to SQLite for zero-config development, and `ecto_sqlite3` rejects column `modify` operations that work on Postgres. A migration is not complete after a Postgres-only proof: run the full fresh-schema chain on both adapters, use adapter-specific DDL where necessary, and keep production-like data repair as a separate rehearsal (found 2026-07-13 when the records generation migration stopped a fresh SQLite runtime).

**The coding `security_regression` profile treats `requested_paths` as test paths.** Its compiler requires a non-empty list containing only files ending in `_test.exs`; adding the source file produces `{:invalid_security_regression_paths, ...}` before workspace allocation. Use that profile for its specialized two-revision proof, not merely as a descriptive label for security-sensitive feature work. A feature slice that changes source plus adversarial tests should use an executable general profile and still prove the tests fail against the candidate parent where applicable (found 2026-07-14 while continuing the Apple Container planner).

**Apple `container create` treats tokens after the image as init-process arguments.** A 1.1.0 live probe passed `--network default` after the immutable image while specifying `--network none` before it; `container inspect` recorded the former only in `initProcess.arguments` and kept `networks: []`. Keep every container-management option before the image and the fixed Mix arguments after it, and retain an exact argv test so future CLI/version changes cannot silently reinterpret command flags (verified 2026-07-14 while reviewing the Apple Container planner).

**A Linux containment guest cannot reuse an unfiltered macOS dependency snapshot.** The validation lease currently copies the host `deps/` tree, which can contain Darwin artifacts such as `sqlite_vec/priv/.../vec0.dylib`; rebuilding a missing Linux artifact can then invoke a dependency downloader despite the intended offline contract. Provision an attested Linux-native dependency baseline keyed to the exact `mix.lock` and immutable image digests, clone it into each private writable lease, and keep image/dependency provisioning outside authorized no-network execution (found 2026-07-14 before wiring Apple Container admission).

**Authenticate the control-plane service, not only its CLI.** Apple Container's signed CLI writes a user-owned LaunchAgent for `container-apiserver`, while user configuration can select the VM kernel and vminit image. A containment backend must bind launchd's running program/argv to a separately pinned signed API-server binary and explicitly select root/operator-owned kernel, immutable init image, platform, and runtime values; self-reported health JSON is corroboration, not authority (found 2026-07-14 auditing Apple Container 1.1.0 before the imperative prober).

**A successful ExUnit command can still execute zero regressions.** Arbor's `:database` tag specifically means a test requires PostgreSQL and is excluded by default in `arbor_persistence`; a hermetic temporary-SQLite migration test carrying that tag reported success with every test excluded. Use the tag semantics in `TEST_TAGGING.md`, and verify the final executed test count rather than only the command exit status (found 2026-07-14 reviewing the SQLite migration infrastructure fix).

**A correlation token placed in a timer message is not the cancellation handle.** `make_ref()` put into a `Process.send_after/3` payload cannot be cancelled with `Process.cancel_timer/1` — that API needs the reference *returned by* `send_after/3` (or prefer `:erlang.start_timer/3`, whose delivered `{:timeout, timer_ref, payload}` carries the same cancellable ref). On cleanup/reset, cancel the real handle and non-blockingly flush an already-delivered exact timeout message so completion races do not surface as unexpected `handle_info/2` traffic; regress by suspending after a fast successful prompt and asserting the mailbox is free of hard/inactivity timer messages (found 2026-07-14 in `AcpSession` / live `task_83651`).

**An immutable Apple Container image reference is not a no-pull guarantee.** In Apple Container 1.1.0, `container create` calls `ClientImage.fetch` for the workload and vminit, and the API server fetches vminit again; a missing local reference therefore initiates a registry pull even when it contains `@sha256`. Use operator-provisioned execution aliases under the non-connectable loopback registry sink `127.0.0.1:0/...@sha256:...`, force `--scheme https`, and admit a proxy-free API/plugin launch environment so a missing alias fails locally. Bind each alias's descriptor/index/selected-manifest digests before use; preflight inspect alone does not remove the same-user store race (found 2026-07-14 auditing Apple Container 1.1.0 and containerization 0.35.0).

**Dispatching an agent task does not invoke a named Jido action.** `arbor_dispatch_task` sends work through the target agent's ordinary task/chat path; writing "use `coding_produce_reviewable_change`" in that prompt can still produce a normal model turn with no action call. When the caller needs a specific action deterministically, use `arbor_run` with the exact action and closed params (or a compiled DOT node that invokes it), then use task dispatch only for work whose agent-level routing is intentional (found 2026-07-14 after a coding-agent dispatch took its default chat path instead of ACP delegation).
