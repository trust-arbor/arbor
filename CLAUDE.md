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
- **Engine** (`Arbor.Orchestrator.Engine`): Executes DOT pipeline graphs by traversing nodes in topological order, dispatching each to the appropriate handler, managing checkpoints for resume, and emitting lifecycle events. The Engine is the core execution loop — it calls handlers, collects results, evaluates conditional edges to pick the next node, and tracks node durations. The execution model itself is sound; the lifecycle tracking infrastructure around it (how completed/failed status is recorded) is being redesigned — see `.arbor/roadmap/2-planned/engine-lifecycle-redesign.md`.
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

**Always search for all occurrences before using `replace_all: true`.** The string may appear in alias declarations, comments, or other contexts where replacement breaks things.

**Verify "X doesn't exist" claims in roadmap docs against source before designing.** Roadmap/brainstorming docs frequently understate what's built (2026-07-04 session found three in one day: ACP delegation actions existed, Goal `parent_id` hierarchy existed, the interview-agent's trust actions existed — each doc claimed otherwise). The docs age; the code is the truth. One grep before design saves a redesign.

**The recurring Arbor bug pattern is built-but-unwired, not broken.** When auditing a subsystem, check the LAST MILE first: recall computed then dropped before the prompt (memory), eval data persisted then never read back (compaction thresholds), signing primitives complete but never verified in the engine path. The machinery is usually sound; the wiring and the end-to-end behavior test are what's missing. Audit by tracing one value from producer to consumer before reading any implementation.

**Hysun's estimates run 2–4x conservative; the real constraint is decision bandwidth, not implementation speed.** Measured (June–July 2026): all 14 H1 items landed at 2–4x estimated speed at ~13 commits/day sustained, while the inbox grew — ideas arrive faster than decisions clear. When planning with him, don't pad implementation estimates, and bias session effort toward design/audit/decision support over code generation; that's where the leverage is.

**Use absolute dates in docs, never relative time-anchors.** "Born last March," "left the company a few days ago," "deadline likely next month" all silently rot into wrong once the doc ages — and roadmap/persona docs age for months. Write `2026-03`, `early April 2026`, `2025`. Exception: verbatim quotes from published material keep their original phrasing (don't edit a quote), but any NEW prose uses absolute dates. (Found 2026-07-06: brand-voice persona anchors and a "TBD deadline" conference doc had both drifted.)

**Don't prematurely cap `max_tokens`.** Let `max_tokens` be whatever the model supports; lower it only when you need faster/cheaper responses, and only *after measuring* that a lower cap doesn't hurt the task. A too-low cap is a silent failure mode with **reasoning models** (e.g. `qwen-agentworld-35b`, `qwen3.5-122b`): they spend the budget on hidden reasoning (`reasoning_content`) and emit the real answer in `content` only *after* reasoning finishes — so a small `max_tokens` yields **empty `content`** that looks like "the model can't answer," a "streaming bug," or "the agent loops," when the real fix is just a bigger budget (verified 2026-07-01: identical empty output on BOTH streaming and non-streaming at 512 tokens; a correct answer at 3000). The turn's `max_tokens` is a `compute`-node attr defaulting to `nil` (provider's full budget) with a session-level fallback (`config["max_tokens"]` → `session.max_tokens`); prefer leaving it unset over guessing a low number.

**Use `./bin/mix`, not ad hoc `mise exec`, for project Mix commands.** `./bin/mix` is the repo wrapper that runs Mix through the Erlang + Elixir versions pinned in `.tool-versions` (currently Erlang `28.4.1`, Elixir `1.19.5-otp-28`). The original footgun still applies: `mise exec elixir@... -- mix ...` pins Elixir only and can fall through to the system Erlang, producing spurious OTP/type failures (`@type record` rejected as a built-in; a type-checker crash compiling `Arbor.Monitor.Diagnostics.top_processes_by/2`). Prefer `./bin/mix test`, `./bin/mix compile --warnings-as-errors`, `./bin/mix arbor.start`, etc.; update `.tool-versions` and let the wrapper pick it up when the project toolchain changes.

**Elixir `Keyword` APIs require atom keys.** Do not call `Keyword.fetch/2`, `Keyword.get/3`, or friends with string keys while trying to support mixed atom/string option data; it raises instead of returning a miss. For mixed option-like data, use atom-keyed `Keyword` access first and a separate `List.keyfind(opts, string_key, 0)` fallback, or normalize to a map before lookup (found 2026-07-08 while threading approval-context opts).

**For local diagnostic Mix tasks, start the narrow app, not the whole umbrella.** `Mix.Task.run("app.start")` in an umbrella task starts every app and can bring up Gateway/Dashboard, pollers, memory loaders, etc. (2026-07-07: a local trust-profile audit accidentally started HTTP endpoints and loaded unrelated subsystems). Plain `./bin/mix run -e ...` also starts the application; use `./bin/mix run --no-start -e ...` for one-off module introspection that only needs compiled code. For offline/local diagnostics that only need one subsystem, use `Application.ensure_all_started(:target_app)` after compilation/loadpaths, and leave the default task path as live RPC when it needs the running server's state.

**`mix arbor.eval` is the eval harness, not a lightweight RPC evaluator.** For running-node diagnostics, use a purpose-built RPC task such as `arbor.recompile` or a task-specific command, or add/use an explicit `arbor.eval.rpc`-style task. Otherwise `arbor.eval` starts evaluation infrastructure and can fail on missing `--model` / `--models` before running the intended diagnostic (found 2026-07-08 while checking registry ETS state).

**`.arbor/` is its own Git repository.** Roadmap files are tracked inside `.arbor`, not in the parent repo, so never `git add -f .arbor/...` from the parent. Commit roadmap changes with `git -C .arbor ...`, and stage only the specific roadmap files for the current slice because `.arbor` often has many unrelated local notes and planning edits.

**URI prefix checks must be segment-aware, never raw `String.starts_with?/2`.** A registry prefix like `arbor://action` raw-matches the retired plural namespace `arbor://actions/execute/...`; `arbor://fs/read` raw-matches `arbor://fs/reader/...`. That is the same footgun class as trust prefix-vs-glob, but at the namespace boundary. Use `Arbor.Contracts.Security.CapabilityUri.prefix_match?/2` for registry-style prefix checks so matching happens on parsed URI segments (found 2026-07-07 during Ring B/B1: `UriRegistry` accepted retired plural action URIs because of a raw prefix match).

**Do not telemetry-invert distributed security state sync.** Security observability can emit `:telemetry` and let `arbor_signals` bridge it back to signals, but nonce, capability, and identity sync are load-bearing cross-node security state. `NonceCache` uses `security.nonce_seen` to block replay against peer nodes; `CapabilityStore` uses revocation signals to evict revoked grants on peers; `Identity.Registry` uses identity lifecycle signals to keep peer caches current. Telemetry is in-process and synchronous, so it cannot replace node-hop transport. B9 extraction needs an injected sync transport (likely Phoenix.PubSub or `Arbor.Signals` behind a behaviour), not a telemetry bridge, before dropping the `arbor_signals` dependency.

**Template capability grants may need runtime URI expansion.** Agent templates and trust presets can declare the human-readable coarse gate (`arbor://orchestrator/execute`), but mandatory Engine middleware authorizes per-node runtime resources like `arbor://orchestrator/execute/exec`. A trust rule prefix can stay bare, but a capability grant must be subtree-scoped (`/**`) or the session pipeline fails closed after `classify` with an empty CLI response. Diagnose by inspecting the node status checkpoint, not just the top-level turn summary (found 2026-07-07 while debugging `arbor.agent chat` for coding agents).

**File tools need both exposure and FileGuard scope grants.** `file_read` / `file_list` are selected via the bare action URI (`arbor://fs/read`, `arbor://fs/list`), but the final file gate authorizes the path-embedded URI synthesized from `file_path:` (for example `arbor://fs/read/Users/.../repo/file.ex`). For least-privilege repo access, use template shorthands like `arbor://fs/read/repo` only if lifecycle expands them into both the bare tool URI and an absolute repo-root `/**` scope, and make sure `ActionsExecutor` resolves relative LLM paths against the tool workdir before signing/authorization; otherwise chat can expose the tool but still deny the action at runtime (found 2026-07-07 while auditing Security Auditor and Test Agent).

**Glob is a file read and must have an authorized base.** `file_glob` shares the bare `arbor://fs/read` exposure URI with `file_read`, but its user-controlled path can live in `pattern` rather than `path`. A missing `base_path` used to skip FileGuard entirely: a repo-scoped read-only agent could glob `/private/tmp/...` because the action layer authorized only the bare `arbor://fs/read`. Agent/tool execution must inject an effective base path (normally the tool workdir), plumb `base_path` into fs auth, and reject absolute or `..` patterns when a base/workspace is set (found and reproduced 2026-07-07 via Security Auditor Eval).

**Nested action approvals must be awaited by the owner action.** `ActionsExecutor` can wait/retry top-level `{:ok, :pending_approval, irq}` results, but a composite action that calls another action directly must handle that nested approval itself. `coding_produce_reviewable_change` initially converted validation shell approvals into `validation_failed`, leaving stale `irq_*` records the MCP approval tool could answer but not resume. The fix is owner-side wait/retry plus an exact approved-invocation marker, and every hop (`Shell.Execute` context -> `authorize_command` -> `ApprovalGuard`) must forward that marker.

**MCP approval answering is explicit capability authority, not trust-profile graduation.** `arbor_answer_approval` authorizes `arbor://approval/answer/<principal-or-agent>` through `Arbor.Security.authorize/4` before it mutates the IRQ. A scoped capability grant with no `requires_approval` constraint is enough for that security check; `Arbor.Trust.authorize/4` would still gate it because the high-risk profile projects `arbor://approval/answer` to a `:ask` ceiling. Do not try to relax this with an `:auto` trust rule. Give the local approver an explicit scoped answer capability for the delegated worker/owner approval principal, or a global `arbor://approval/answer` cap only for trusted operator surfaces. When listing pending approvals, filter on the stored coarse `resource_uri` (for example `arbor://shell/exec`) rather than the command-specific target URI.

**Native Hermes ACP edit approval can fail before Arbor validation.** A `coding_produce_reviewable_change` run with `acp_agent: "hermes"` may return `status: "declined"` with `Edit approval denied by ACP client; file was not modified`. That is Hermes' ACP edit gate, not Arbor's validation approval loop, so no `arbor_list_pending_approvals` item will appear for the validation command.

**Stdio MCP servers must keep stdout JSON-RPC clean during startup.** Launching Arbor's stdio signing proxy through Mix while Mix recompiles can print `==> ...`, `Compiling ...`, or `Generated ... app` on stdout. Hermes then tries to parse those compiler lines as JSON-RPC and can hit `init_timeout` before the ACP session starts. Warm the compile cache or keep compiler/log output off stdout before diagnosing the downstream MCP tool path.

**Basic-shell sandbox checks the command string even after argument escaping.** `ShellEscape` single-quotes dangerous commit-message text correctly, but `Arbor.Shell.Sandbox` still rejects metacharacters like backticks inside the assembled command string. Git actions that run via `Shell.execute(..., sandbox: :basic)` need to normalize user/task-derived arguments such as commit messages before constructing the shell command, or use a non-shell argv execution path.

**Schema-bounded Mix actions must stay within the basic shell sandbox's allowed flag set.** `Mix.Compile` cannot expose `--force` while it runs through `Shell.execute(..., sandbox: :basic)`: the sandbox rejects that flag before Mix starts. Add flags only after checking the sandbox policy or moving the action to a non-shell argv execution path (found 2026-07-09 while routing coding-agent validation through `arbor://action/mix/compile`).

**`arbor.recompile` can miss already-compiled nested modules during live diagnostics.** After local `./bin/mix compile`, `./bin/mix arbor.recompile` may return `:ok` while the running dev node still uses old nested action code. Verify live behavior, and if needed force a `:code.purge` / `:code.delete` / `:code.load_abs` reload for the specific modules or restart the dev server before concluding a fix failed.

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
