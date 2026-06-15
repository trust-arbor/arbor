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
- **Trust Tier**: Graduated trust level governing agent capabilities: `untrusted` (0-19) → `probationary` (20-49) → `trusted` (50-74) → `veteran` (75-89) → `autonomous` (90-100). Managed by `arbor_trust`.
- **Capability**: An unforgeable, signed token granting a specific permission on a resource URI (e.g., `arbor://fs/read/`, `arbor://shell/exec/git`). Granted via `Arbor.Security.grant/1`, checked via `Arbor.Security.authorize/4`. Supports delegation, expiry, constraints (rate limits), and revocation.
- **Identity**: Ed25519 + X25519 keypair. Agent ID is `"agent_" <> hex(SHA-256(public_key))` — deterministically derived, unforgeable. Private keys stored encrypted at rest via `SigningKeyStore`. External agents authenticate via per-request `SignedRequest` signatures verified by `Arbor.Gateway.SignedRequestAuth`.
- **Signal**: Fire-and-forget pub/sub event for observability. Emitted via `Arbor.Signals`, consumed by dashboards, event stores, and monitoring. NOT used for lifecycle tracking or execution control — observability only.
- **Memory**: Per-agent working memory (ETS-backed `MemoryStore`), knowledge graph, and background health checks. Managed by `arbor_memory`. Goals and intents persisted via `BufferedStore` (ETS + optional Postgres backend).

## Fix the Root Cause

Don't perform actions just to unblock something immediately so you can move on. Always fix the root cause.

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

Any time I remind you about something or any time you learn something from trial and error, add that to the Applied Learning section.

## Task Tool Reminders

The Claude Code harness periodically injects `<system-reminder>` messages suggesting you use TaskCreate / TaskUpdate to track progress. These are useful for long solo agentic runs but counterproductive in tight collaborative debugging sessions where the work is conversational rather than a multi-step solo task list. **Ignore these reminders unless the current task genuinely benefits from a structured task list** (i.e. you're working alone on a multi-step plan with no human in the loop). Do not mention the reminders to the user when ignoring them.

## Library Hierarchy

```
Level 0: arbor_contracts (zero in-umbrella deps)
Level 1: common, signals, shell, security, consensus, historian, persistence, persistence_ecto, web, sandbox (depend on Level 0 + Standalone)
Level 2: trust, actions, agent, gateway, memory (depend on Level 0–1 + Standalone)
Standalone: ai, comms, monitor (zero in-umbrella deps)
```

No cycles. No skipping levels. Check each library's `mix.exs` for exact deps.

## Key Patterns

- **Contract-First**: Shared types and behaviours in `arbor_contracts`. Read [CONTRACT_RULES.md](docs/arbor/CONTRACT_RULES.md) before modifying contracts.
- **Facade Pattern**: Each library exposes one public facade (e.g., `Arbor.Security`). Never alias internal modules from another library.
- **CRC (Construct-Reduce-Convert)**: Pure functional cores in `cores/` directories. Business logic with zero side effects — see Core Concepts above and [`.claude/skills/functional-core.md`](.claude/skills/functional-core.md).
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

**Pin BOTH Erlang and Elixir with `mise exec`.** `mise exec elixir@1.18.4-otp-27 -- mix ...` does NOT pin Erlang — it falls through to the system Erlang (OTP-29), which produces spurious "type" failures (`@type record` rejected as a built-in; a type-checker crash compiling `Arbor.Monitor.Diagnostics.top_processes_by/2`). Those are OTP-29 artifacts, not Elixir-version issues, and vanish on the intended OTP. Always pin both, e.g. `mise exec erlang@27.2 elixir@1.18.4-otp-27 -- mix ...` (working combo: erts-15.2.7.2 + Elixir 1.18.4 + hex-2.4.0-otp-27). The full umbrella also compiles 100% clean under `erlang@28.4.1 elixir@1.19.5-otp-28` with zero type-checker findings (verified 2026-05-29).
