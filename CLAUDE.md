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
- **Engine** (`Arbor.Orchestrator.Engine`): Executes DOT pipeline graphs by traversing nodes in topological order, dispatching each to the appropriate handler, managing checkpoints for resume, and emitting lifecycle events. The Engine is the core execution loop — it calls handlers, collects results, evaluates conditional edges to pick the next node, and tracks node durations. `Engine.run/2` returning `{:ok, run_result}` means that execution produced a result envelope, not that the graph succeeded; callers must inspect `run_result.final_outcome.status` and admit only `:success` or an explicitly supported `:partial_success`. Live runs are tracked through process-local `RunState` plus the `PipelineStatus` ETS facade; lifecycle convergence with the legacy `JobRegistry` recovery path and durable pre-effect intent is complete — see `.arbor/roadmap/5-completed/engine-lifecycle-convergence-and-crash-consistency.md`.
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
./bin/mix quality    # format --check-formatted + credo --strict
./bin/mix test.fast  # unit tests only (--only fast)
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

This section is the always-loaded working set: 12 broad cross-task rules measuring 898 words. The set is deliberately above the roughly 600-word target because these rules recur across roadmap/source verification, planning, toolchain, Git, security URI matching, and patching; subsystem incidents remain behind the index. Read the linked skill before working in a specialized area; the linked files retain every other entry verbatim. The inventory is [`.claude/skills/applied-learning-inventory.json`](.claude/skills/applied-learning-inventory.json), and its validator is [`.claude/validate_applied_learning.rb`](.claude/validate_applied_learning.rb).

| Read when | Load this skill |
| --- | --- |
| ACP/MCP delegation, steering, approvals, coding dispatch, or worker continuity | [ACP/MCP and delegation](.claude/skills/applied-learning-acp-mcp.md) |
| Shell, process, executable, or container containment | [Shell and containment](.claude/skills/applied-learning-shell-containment.md) |
| Mix/test isolation, live runtime reload, or validation harnesses | [Testing and live runtime](.claude/skills/applied-learning-testing-live-runtime.md) |
| OTP ownership, GenServer cancellation, supervision, or cleanup | [OTP ownership and cleanup](.claude/skills/applied-learning-otp-ownership-cleanup.md) |
| Persistence, databases, checkpoints, journals, or recovery | [Persistence and database](.claude/skills/applied-learning-persistence-database.md) |
| LLM providers, OAuth, budgets, quotas, or egress | [Providers and OAuth](.claude/skills/applied-learning-providers-oauth.md) |
| Council, review, approval, findings, or validation rework | [Council and review](.claude/skills/applied-learning-council-review.md) |
| Filesystem, paths, worktrees, Git, indexes, or formatter scope | [Filesystem and Git](.claude/skills/applied-learning-filesystem-git.md) |
| UI, LiveView, socket state, or Phoenix components | [UI components](.claude/skills/socket-component.md) |
| DOT graphs, Engine execution, context, or action bindings | [DOT pipeline authoring](.claude/skills/dot-pipeline-authoring.md) |
| Capabilities, trust, authorization, identity, or egress gates | [Agent security gates](.claude/skills/agent-security-gates.md) |

<!-- applied-learning: always-search-for-all-occurrences-before-using-replace-all-true -->
<a id="applied-learning-always-search-for-all-occurrences-before-using-replace-all-true"></a>
**Always search for all occurrences before using `replace_all: true`.** The string may appear in alias declarations, comments, or other contexts where replacement breaks things.

<!-- applied-learning: checkpoint-proof-cache-boundaries-and-progress -->
<a id="applied-learning-checkpoint-proof-cache-boundaries-and-progress"></a>
**Checkpointed historical proofs are observations, never mutation authority.** Bind every reusable result to the exact repository, destination ref/OID, branch ref/OID, and proof-policy version; persist only closed, sanitized statuses; retry transient failures; and make progress count cache hits, every retry, and budget-skipped targets independently of outcome success.

<!-- applied-learning: unsigned-local-checkpoint-successes-are-revalidation-hints-only -->
<a id="applied-learning-unsigned-local-checkpoint-successes-are-revalidation-hints-only"></a>
**Unsigned local checkpoint successes are revalidation hints, not evidence.** Owner-only file mode provides confidentiality from other users but no authenticity against same-user tampering. A cached success must consume the normal proof budget and pass the live proof boundary again before classification; only exact-scope deterministic preserve outcomes may skip work (found 2026-07-21 reviewing historical branch-audit proof caching).


<!-- applied-learning: anchor-manual-patches-with-unique-surrounding-context -->
<a id="applied-learning-anchor-manual-patches-with-unique-surrounding-context"></a>
**Anchor manual patches with unique surrounding context.** A one-line `apply_patch` hunk can silently match an earlier identical line in the same file; include the enclosing test/function or nearby setup statements, then inspect the resulting location before proceeding (found 2026-07-15 while isolating a coordinator timer test).


<!-- applied-learning: verify-x-doesn-t-exist-claims-in-roadmap-docs-against-source-before-designing -->
<a id="applied-learning-verify-x-doesn-t-exist-claims-in-roadmap-docs-against-source-before-designing"></a>
**Verify "X doesn't exist" claims in roadmap docs against source before designing.** Roadmap/brainstorming docs frequently understate what's built (2026-07-04 session found three in one day: ACP delegation actions existed, Goal `parent_id` hierarchy existed, the interview-agent's trust actions existed — each doc claimed otherwise). The docs age; the code is the truth. One grep before design saves a redesign. The drift runs both directions: "implemented" claims can also be stale or refer to pre-decision-era artifacts (2026-07-12: `jobs-mailbox-sessions-design.md` claimed Jobs *actions* existed; they were actually Mix tasks from a personal task system predating the everything-is-a-Jido-action decision, never generalized, and not in the tracked tree). Verify what was built AND in what form.


<!-- applied-learning: the-recurring-arbor-bug-pattern-is-built-but-unwired-not-broken -->
<a id="applied-learning-the-recurring-arbor-bug-pattern-is-built-but-unwired-not-broken"></a>
**The recurring Arbor bug pattern is built-but-unwired, not broken.** When auditing a subsystem, check the LAST MILE first: recall computed then dropped before the prompt (memory), eval data persisted then never read back (compaction thresholds), signing primitives complete but never verified in the engine path. The machinery is usually sound; the wiring and the end-to-end behavior test are what's missing. Audit by tracing one value from producer to consumer before reading any implementation.


<!-- applied-learning: hysun-s-estimates-run-2-4x-conservative-the-real-constraint-is-decision-bandwidth-not-implementation-speed -->
<a id="applied-learning-hysun-s-estimates-run-2-4x-conservative-the-real-constraint-is-decision-bandwidth-not-implementation-speed"></a>
**Hysun's estimates run 2–4x conservative; the real constraint is decision bandwidth, not implementation speed.** Measured (June–July 2026): all 14 H1 items landed at 2–4x estimated speed at ~13 commits/day sustained, while the inbox grew — ideas arrive faster than decisions clear. When planning with him, don't pad implementation estimates, and bias session effort toward design/audit/decision support over code generation; that's where the leverage is.


<!-- applied-learning: use-absolute-dates-in-docs-never-relative-time-anchors -->
<a id="applied-learning-use-absolute-dates-in-docs-never-relative-time-anchors"></a>
**Use absolute dates in docs, never relative time-anchors.** "Born last March," "left the company a few days ago," "deadline likely next month" all silently rot into wrong once the doc ages — and roadmap/persona docs age for months. Write `2026-03`, `early April 2026`, `2025`. Exception: verbatim quotes from published material keep their original phrasing (don't edit a quote), but any NEW prose uses absolute dates. (Found 2026-07-06: brand-voice persona anchors and a "TBD deadline" conference doc had both drifted.)


<!-- applied-learning: don-t-prematurely-cap-max-tokens -->
<a id="applied-learning-don-t-prematurely-cap-max-tokens"></a>
**Don't prematurely cap `max_tokens`.** Let `max_tokens` be whatever the model supports; lower it only when you need faster/cheaper responses, and only *after measuring* that a lower cap doesn't hurt the task. A too-low cap is a silent failure mode with **reasoning models** (e.g. `qwen-agentworld-35b`, `qwen3.5-122b`): they spend the budget on hidden reasoning (`reasoning_content`) and emit the real answer in `content` only *after* reasoning finishes — so a small `max_tokens` yields **empty `content`** that looks like "the model can't answer," a "streaming bug," or "the agent loops," when the real fix is just a bigger budget (verified 2026-07-01: identical empty output on BOTH streaming and non-streaming at 512 tokens; a correct answer at 3000). The turn's `max_tokens` is a `compute`-node attr defaulting to `nil` (provider's full budget) with a session-level fallback (`config["max_tokens"]` → `session.max_tokens`); prefer leaving it unset over guessing a low number.


<!-- applied-learning: use-bin-mix-not-ad-hoc-mise-exec-for-project-mix-commands -->
<a id="applied-learning-use-bin-mix-not-ad-hoc-mise-exec-for-project-mix-commands"></a>
**Use `./bin/mix`, not ad hoc `mise exec`, for project Mix commands.** `./bin/mix` is the repo wrapper that runs Mix through the Erlang + Elixir versions pinned in `.tool-versions` (currently Erlang `28.4.1`, Elixir `1.19.5-otp-28`). The original footgun still applies: `mise exec elixir@... -- mix ...` pins Elixir only and can fall through to the system Erlang, producing spurious OTP/type failures (`@type record` rejected as a built-in; a type-checker crash compiling `Arbor.Monitor.Diagnostics.top_processes_by/2`). Prefer `./bin/mix test`, `./bin/mix compile --warnings-as-errors`, `./bin/mix arbor.start`, etc.; update `.tool-versions` and let the wrapper pick it up when the project toolchain changes.


<!-- applied-learning: elixir-keyword-apis-require-atom-keys -->
<a id="applied-learning-elixir-keyword-apis-require-atom-keys"></a>
**Elixir `Keyword` APIs require atom keys.** Do not call `Keyword.fetch/2`, `Keyword.get/3`, or friends with string keys while trying to support mixed atom/string option data; it raises instead of returning a miss. For mixed option-like data, use atom-keyed `Keyword` access first and a separate `List.keyfind(opts, string_key, 0)` fallback, or normalize to a map before lookup (found 2026-07-08 while threading approval-context opts).


<!-- applied-learning: arbor-is-its-own-git-repository -->
<a id="applied-learning-arbor-is-its-own-git-repository"></a>
**`.arbor/` is its own Git repository.** Roadmap files are tracked inside `.arbor`, not in the parent repo, so never `git add -f .arbor/...` from the parent. Commit roadmap changes with `git -C .arbor ...`, and stage only the specific roadmap files for the current slice because `.arbor` often has many unrelated local notes and planning edits.


<!-- applied-learning: uri-prefix-checks-must-be-segment-aware-never-raw-string-starts-with-2 -->
<a id="applied-learning-uri-prefix-checks-must-be-segment-aware-never-raw-string-starts-with-2"></a>
**URI prefix checks must be segment-aware, never raw `String.starts_with?/2`.** A registry prefix like `arbor://action` raw-matches the retired plural namespace `arbor://actions/execute/...`; `arbor://fs/read` raw-matches `arbor://fs/reader/...`. That is the same footgun class as trust prefix-vs-glob, but at the namespace boundary. Use `Arbor.Contracts.Security.CapabilityUri.prefix_match?/2` for registry-style prefix checks so matching happens on parsed URI segments (found 2026-07-07 during Ring B/B1: `UriRegistry` accepted retired plural action URIs because of a raw prefix match).

**Opaque identifiers interpolated into capability URIs must not become URI syntax.** A caller-supplied task id such as `**` can turn an intended exact grant like `arbor://agent/task/adopt/<task-id>` into a recursive wildcard capability. Before constructing a scoped capability URI, either encode/digest the opaque id into one safe segment or enforce a bounded single-segment alphabet; reject `/`, `*`, traversal segments, whitespace/control bytes, and invalid UTF-8 before any grant occurs (found 2026-07-21 while reviewing post-terminal coding-task adoption).

<!-- applied-learning: idempotent-side-effects-must-reconstruct-their-full-durable-receipt -->
<a id="applied-learning-idempotent-side-effects-must-reconstruct-their-full-durable-receipt"></a>
**Idempotent side effects must reconstruct their full durable receipt.** An Engine retry can occur after an action's external side effects succeed but before its result is checkpointed. Returning a generic `already_released` response is not enough when downstream logic needs immutable evidence from the original response. Reconstruct the receipt only from durable state and reverify it before reporting success; for workspace publication, the retry carries the repo root and succeeds only when the deterministic task/workspace hidden ref still points to the exact candidate OID. Normalize failed replay proofs so the recovery path does not become a repository-state oracle (found 2026-07-21 while reviewing candidate publication crash replay).


<!-- applied-learning: conserve-the-local-agent-s-tokens-for-planning-design-delegation-and-review -->
<a id="applied-learning-conserve-the-local-agent-s-tokens-for-planning-design-delegation-and-review"></a>
**Conserve the local agent's tokens for planning, design, delegation, and review.** As a rule of thumb, delegate substantive implementation to Grok through `coding_produce_reviewable_change`, then have the local agent inspect the diff, verify behavior, and request corrections. This is a heuristic, not a prohibition: make direct edits when delegation is blocked, the change is genuinely tiny, or local intervention is the clearest way to finish safely. The goal is to spend local-agent context on decision quality and integration judgment rather than routine code production (requested 2026-07-09).
