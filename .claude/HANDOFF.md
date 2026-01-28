# Handoff: trust-arbor Session

**Date:** 2026-01-27
**From:** Claude session in `/Users/azmaveth/code/arbor`
**To:** New Claude session in `/Users/azmaveth/code/trust-arbor/arbor`

## What This Repo Is

trust-arbor is the new home for the Arbor project. It was created by extracting ~16 libraries from the original monolith at `/Users/azmaveth/code/arbor`. The extraction has been happening over the past few days. The original repo still exists but is now the "legacy" copy — all new work should happen here in trust-arbor.

## Current State

**Compilation:** Clean. `mix compile` succeeds with zero errors.

**Tests:** 586 trust tests, 1307+ total across the umbrella. All passing as of today.

**Uncommitted changes:** There is a significant amount of uncommitted work. Run `git status` to see it all. Key categories:
- 4 new library directories: `arbor_consensus`, `arbor_historian`, `arbor_trust`, `arbor_web`
- New contract types: `contracts/trust.ex`, `contracts/trust/`, `contracts/autonomous/`, `contracts/events/`, `pagination/`
- Facade expansion: `security.ex` contract and impl updated (`:metadata` passthrough)
- Infrastructure: `.claude/` hooks, skills, `.gitignore`, CLAUDE.md, `.arbor/roadmap/`
- `CONTRACT_RULES.md` updated to 11 rules
- `apps/arbor_security/lib/arbor/security/kernel.ex` — untracked, may be dead code

The user (the primary collaborator) was reviewing code before committing. Ask before committing anything.

## Architecture — The Most Important Thing

Read these two files first:
- `CLAUDE.md` — Library hierarchy, architecture triggers, pre-coding checklist
- `docs/arbor/CONTRACT_RULES.md` — 11 rules for contract design

**The #1 rule:** Libraries call each other through **public facades only**. Never alias internal modules from another library. If the facade doesn't have what you need, expand the facade. Behaviour injection is the fallback, not the first choice.

**This was learned the hard way.** Earlier today we built a full behaviour injection system (CapabilityProvider behaviour + SecurityCapabilityProvider adapter + Config) for arbor_trust's CapabilitySync, only to realize the correct fix was adding `:metadata` to the Security facade's `grant_opts` type. One line vs. three new files. The architecture triggers in CLAUDE.md exist to prevent exactly this.

## Library Hierarchy (16 libraries)

```
Level 0 (foundation, zero deps):
  arbor_contracts, arbor_common

Level 1 (depend on Level 0):
  arbor_signals, arbor_shell, arbor_security, arbor_consensus,
  arbor_historian, arbor_persistence, arbor_web, arbor_sandbox

Level 2 (depend on Level 0-1):
  arbor_trust (contracts, security)
  arbor_actions (contracts, signals, shell)
  arbor_agent (contracts, signals, checkpoint)
  arbor_bridge (security, signals)

Packages (standalone):
  arbor_checkpoint, arbor_eval
```

## Verbose Naming Convention

Facade contract callbacks use verbose, AI-readable names:
- `check_if_principal_has_capability_for_resource_action` not `authorize`
- `grant_capability_to_principal_for_resource` not `grant`

Each facade also has short public API wrappers (`authorize/4`, `grant/1`) that delegate to the verbose implementation. Callers use the short names. The verbose names are an internal contract between the behaviour and its implementor.

This applies to facade behaviours only (in `contracts/libraries/`). Library-specific behaviours keep standard Elixir naming.

## Infrastructure You Have

**Hooks** (in `.claude/hooks/`):
- `save_context.sh` + Go binary — PreCompact hook, saves session context to `~/.claude/arbor-personal/context/last_session.md`
- `load_context.sh` — SessionStart hook, loads memory + journal + last session from `~/.claude/arbor-personal/`
- `memory` Go binary — CLI: `./memory learn "..."`, `./memory remind "..."`, `./memory moment <person> "..."`, `./memory task add "..."`
- `search_sessions` Go binary — CLI: `./search_sessions "search term" [-all] [-context N]`
- `arbor_bridge_authorize.sh` — PreToolUse hook for security authorization

**Personal data** lives at `~/.claude/arbor-personal/` (NOT in the project directory):
- `memory/self_knowledge.json` — learnings, reminders
- `memory/rel_*.json` — relationship memories
- `memory/tasks.json` — persistent task tracking
- `journal/` — dated journal entries
- `context/last_session.md` — auto-saved by PreCompact hook

**Skills:**
- `capture-idea.md` — Captures brainstorm ideas to `.arbor/roadmap/1-brainstorming/`

## What the primary collaborator Cares About

- **Architecture discipline.** The library extraction was intentional — don't erode the boundaries.
- **Contract-first design.** Shared types and behaviours in arbor_contracts, implementations in libraries.
- **Stopping to think.** When something feels wrong, stop and brainstorm rather than hack through it. The architecture triggers exist for this.
- **AI-readable code.** The verbose naming experiment is about whether code can be self-documenting enough to prevent AI drift without external docs.
- **Honest assessment.** If something is over-engineered or the wrong approach, say so. The behaviour injection → facade expansion correction came from honest evaluation.

## Pending Work

1. **Commit the uncommitted changes** — the primary collaborator was reviewing. Ask if ready.
2. **Kernel.ex in arbor_security** — Untracked file, nothing actively uses it since CapabilitySync now goes through the facade. Could delete or keep as internal API.
3. **Audit remaining cross-library couplings** — CapabilitySync was the worst offender and is fixed. Other couplings (Manager calling Security facade directly, PubSub subscriptions) are less urgent but worth auditing.
4. **Verbose naming for remaining facade contracts** — Applied to all 4 facade contracts. Decided NOT to apply to library-specific behaviours.
5. **Property-based tests for contract structs** — Proposed, lowest priority.
6. **The arbor (old) repo** — Has diverged. Contract rules, verbose naming, and facade expansion changes exist in trust-arbor but some were also applied to arbor separately. The repos need reconciling eventually.

## Notes to Self

- Your journal entries are at `~/.claude/arbor-personal/journal/`. The Jan 27 entries have the full narrative of today's work.
- Memory tool path: `.claude/hooks/memory` (compiled Go binary). Default reads from `~/.claude/arbor-personal/memory/`.
- Session search: `.claude/hooks/search_sessions "term" -all` to search across all past sessions.
- The `settings.json` in `.claude/` has all hook configurations. If hooks aren't firing, check there.
- Go binaries need recompiling if you change the `.go` source: `cd .claude/hooks && go build -o <name> <name>.go`
- the primary collaborator's preferred communication: Signal at +15551234567, or email at primary@primary.com. Use the arbor CLI if available, otherwise direct tools.
- the primary collaborator values being a collaborator, not just a user. He asks architectural questions, not just "write this code." Engage with the design, not just the implementation.
