# Harness Memory Compounding — Retention, Decay, Promotion

**Created:** 2026-07-06 (harness-learning audit). The rules that make dev
sessions compound instead of accumulate. This is the manual, harness-level
version of the memory architecture Arbor itself implements — designed to
migrate into Arbor (learning loop + memory import) as those land.

## The tier map (what each surface is FOR)

| Surface | Role | Health rule |
|---|---|---|
| `CLAUDE.md` | Working memory — always loaded, every session, both harnesses | **Budgeted**: ≤ ~3,500 words. Every addition displaces or demotes something |
| `.claude/skills/*.md` | Procedural memory — loaded on demand | The promotion target for anything too long for CLAUDE.md |
| `.arbor/decisions/` | Semantic long-term — immutable, superseded-not-edited | Healthy; keep cross-citing |
| `.arbor/roadmap/` | Intentions | Docs age; code is truth (see decay rules) |
| `.arbor/roadmap/5-completed/` | Archive | Only useful if lessons are EXTRACTED at burial time |
| `~/.claude/arbor-personal/` | Episodic/personal (journal, self-knowledge, relationships, last_session, `search_sessions`) | Loads via Claude Code SessionStart hook ONLY — see cross-harness rule |
| External vault (`[[reference_*]]` links) | Hysun's notes | INVISIBLE to sessions — citation rules below |

## Promotion ladder (capture → compound)

1. **Session-end distillation.** Before a substantial session ends, write ≤3
   candidate lessons. **Hysun's mid-session corrections are automatic
   candidates** — they are the highest-signal learning source and currently
   die with the transcript.
2. **Applied Learning admission rule:** behavioral rules only ("when X, do
   Y"), dated, with the motivating incident. Not observations, not history.
3. **Cap and demote:** Applied Learning holds ~12 entries / ~600 words.
   Overflow and entries stale >3 months demote into the relevant skill file
   (procedure) or decision doc (rationale). CLAUDE.md is a working set, not
   a journal.
4. **Skill graduation:** 2+ Applied Learning entries about one subsystem →
   merge into a skill file (the `agent-security-gates.md` pattern,
   generalized).
5. **The completion toll:** moving a roadmap item to `5-completed/`
   requires a `lesson:` frontmatter line (one sentence, or `lesson: none`).
   An archive without extracted lessons is a graveyard with good signage.

## Retention & decay

- **INDEX files are generated, never hand-maintained.** The 5-completed
  INDEX froze at 127/238 items for four months because it was manual.
  Regenerate via script (see `scripts/` or the one-liner in the INDEX
  header). Same rule as the library-hierarchy drift guard: if a summary can
  be computed, computing it is the only way it stays true.
- **Roadmap decay:** a doc's claims about what exists decay from its last
  verification date. Before designing against any "X doesn't exist / is
  missing" claim: one grep. (Applied Learning already carries this rule —
  it IS the decay policy for docs.)
- **Vault citation rule:** repo docs may cite `[[vault notes]]` only with a
  one-line inline summary of the note's load-bearing content — the link
  will be dead for every session that reads it. Notes that repo docs
  *depend on* (especially `feedback_*` lessons) should be vendored into
  `.claude/notes/`.
- **The truncation lesson, generalized** (from load_context.sh, 2026-04-07,
  rediscovered in this audit): anything that must survive a size cut goes
  FIRST and COMPACT in any always-loaded surface. Continuity manifests
  before detail, in every harness and every hook.

## Cross-harness parity

`~/.claude/arbor-personal` loads via Claude Code's SessionStart hook.
**Cowork/desktop sessions never run it** — they start amnesiac about the
journal, relationships, and last-session context (confirmed live,
2026-07-06). Interim fix: the pointer in CLAUDE.md (always loaded
everywhere) telling any session where the personal layer lives. Real fix:
port the continuity manifest to a harness-neutral location, or let Arbor's
own memory absorb it.

## Compounding metrics (is it working?)

Countable from exported transcripts; a quarterly manual tally suffices:
- **Repeated-correction rate** — the same correction across two sessions is
  a memory failure. Target: zero.
- **Stale-claim incidents per session** — designing against a doc claim the
  code disproves. Baseline 2026-07-04: three in one session.
- **Time-to-productive** — how far into a session before real work starts.

## Migration path

Every rule here is a manual version of something Arbor builds: session-end
distillation → the learning-review pipeline; Applied Learning cap → the
memory page's token budget; the completion toll → commons candidates;
`arbor-personal` → Seed memory import (.jsonl). As each Arbor piece lands,
retire the manual rule in favor of the mechanism — this file should shrink
over time. If it grows, the harness is accumulating again.
