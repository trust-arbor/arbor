# Harness Memory Compounding — Retention, Decay, Promotion

**Created:** 2026-07-06 (harness-learning audit). The rules that make dev
sessions compound instead of accumulate. This is the manual, harness-level
version of the memory architecture Arbor itself implements — designed to
migrate into Arbor (learning loop + memory import) as those land.

## The tier map (what each surface is FOR)

| Surface | Role | Health rule |
|---|---|---|
| `CLAUDE.md` | Working memory — always loaded, every session, both harnesses | **Budgeted and enforced**: ≤ 4,000 words. Every addition displaces or demotes something |
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
3. **Cap and demote:** Applied Learning holds exactly 12 entries, ≤ 950
   words. Overflow and entries stale >3 months demote into the relevant skill
   file (procedure) or decision doc (rationale). CLAUDE.md is a working set,
   not a journal. Skill-file entries leave through the lifecycle below.
4. **Skill graduation:** 2+ Applied Learning entries about one subsystem →
   merge into a skill file (the `agent-security-gates.md` pattern,
   generalized).
5. **The completion toll:** moving a roadmap item to `5-completed/`
   requires a `lesson:` frontmatter line (one sentence, or `lesson: none`).
   An archive without extracted lessons is a graveyard with good signage.

**The budgets above are the only ones.** `.claude/validate_applied_learning.rb`
is the single authority (CLAUDE.md ≤ 4,000 words; working set exactly 12
entries ≤ 950 words) and runs in `.git/hooks/pre-commit` and CI. It existed
unenforced from 2026-07 until 2026-08-06 and was silently red the whole time —
three different word budgets were in circulation (3,500/600 here, 4,000/950 in
the validator, a hand-written "938" in CLAUDE.md). If you want a different
budget, change the validator; do not restate a number in prose.

## Applied Learning lifecycle (adopted 2026-10-16)

The skill files used to be append-only. The 2026-10-16 audit found the same lesson re-learned up to seven times. It
also found that no session had opened the corpus with the Read tool from 2026-08 to 2026-10, and that only 2 entries
had ever been cited by name. The audit and design are in `.arbor/roadmap/0-inbox/applied-learning-audit-2026-10-16.md`.
Hysun approved them on 2026-10-16.

- **Metadata.** Every inventory entry carries `class` (`security-invariant` / `correctness` / `process` / `tooling`),
  `status` (`live` / `retired`), `created`, `scope` (code anchors), `source_session`, and
  `last_confirmed`/`confirmed_by`. Usage counts live in the generated `.claude/skills/applied-learning-usage.json`.
  Nobody hand-edits that file.
- **Recording use.**
  - Cite an entry as `[AL:<slug>]` when it changes what you do, or `[AL:<slug>!]` when you re-verified it against code.
  - A `PostToolUse` hook (`.claude/hooks/al-exposure.sh`) logs reads of these files to the gitignored
    `.claude/state/al-exposure.jsonl`.
  - The review pass harvests citations and exposures from Claude transcripts, Codex rollouts, the hook log and
    `git log`.
- **Admission.** For entries created on or after 2026-10-16, the validator requires:
  - ≤ 400 words, and one rule per marker (no appended dated or "reinforced" paragraphs);
  - no near-duplicate titles;
  - `revisit_when` for gap-shaped wording such as "currently", "not yet" or "until … implemented".
- **Retirement, not deletion.** Retired text moves to `.claude/applied-learning-archive/<topic>.md` with its marker and
  anchor. The inventory row stays, with `retired_on`, `retired_reason` and `superseded_by`. A retired slug that gets
  cited again shows up as a broken citation, which is the revive signal.
- **Monthly pass.** `ruby .claude/applied_learning_review.rb --report` writes a ranked inbox report and a decisions
  JSON. It proposes:
  - decay retirements: non-security, ≥ 90 days old, uncited, never re-learned, not confirmed in 90 days, past a 30-day
    grace;
  - `reconfirm` rows when a scope anchor disappears. A grep miss is a review trigger, never a delete;
  - merges, and retirements under cap pressure.

  Hysun marks rows `approve`. `--apply <decisions.json>` executes only the approved rows, transactionally, and re-runs
  the validator. The validator warns when the pass is more than 35 days overdue.
- **Caps** are warn-only for now (`caps_enforced: false`): 8,000 live words per topic file and 400 words per entry.
- **Splitting.** When a topic file nears the cap, split it by theme into `applied-learning-<topic>-<theme>.md` files
  rather than retiring rules. Use `move` rows, which keep content and digests unchanged. The original file becomes a
  hub that indexes its sub-files, so the `CLAUDE.md` row stays the same. testing-live-runtime and acp-mcp were split
  this way on 2026-10-16.

## What NOT to capture

Adapted from hermes-agent's background-review prompt (`agent/background_review.py`),
which is battle-tested on an automatic capture loop. Every rule written down
becomes a persistent self-imposed constraint that bites later when the
environment changes. Do not capture:

- **Environment-dependent failures** — missing binaries, fresh-install errors,
  post-migration path mismatches, "command not found", unconfigured
  credentials, uninstalled packages. A human can fix these; they are not
  durable rules.
- **Negative claims about tools or features** — "the browser tools don't work",
  "X is broken", "you can't do Y from Z". These harden into refusals the agent
  cites against itself for months after the actual problem was fixed. This is
  the worst failure mode of any accumulating-lesson system and the reason this
  section exists.
- **Session-specific transient errors that resolved before the session ended.**
  If retrying worked, the lesson is the retry pattern, not the original failure.
- **One-off task narratives.** "Audited subsystem X today" is not a class of
  work that warrants a rule.

If a tool failed because of setup state, capture the **fix** (install command,
config step, env var) in the relevant skill file — never "this tool doesn't
work" as a standalone constraint.

Corollary for naming: **if the proposed name only makes sense for today's task,
it's wrong.** Prefer, in order — patch a skill that was actually loaded this
session → patch an existing umbrella file → add a supporting file under it →
only then create a new class-level skill. A library of hundreds of narrow
one-session entries is a failure of the library, not a rich one.

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
