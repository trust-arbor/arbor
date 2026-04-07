# CLAUDE.md

Arbor is a distributed AI agent orchestration system built on Elixir/OTP. Umbrella project with capability-based security and contract-first design.

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

For writing and running orchestrator DOT pipelines, see [DOT_PIPELINE_GUIDE.md](docs/arbor/DOT_PIPELINE_GUIDE.md).

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
