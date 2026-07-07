# Harness Trust Boundary — Risk × Leverage Calibration

**Created:** 2026-07-06 (authority-audit). Two boundaries got conflated in
"my harness"; this separates and calibrates both.

## The two boundaries

| | **Harness boundary** (Claude Code permissions) | **Product boundary** (Arbor's own gates) |
|---|---|---|
| Where | `.claude/settings.local.json`, hooks | `arbor_security` / `arbor_trust`, the 8-gate skill |
| Governs | what a dev session does vs. asks Hysun | what a running Arbor agent does vs. asks its operator |
| State | **180 allow / 0 deny / 0 ask** — accreted, uncalibrated | well-designed: structural ceilings, enforcing egress, fail-closed |

The product boundary is the reference design. The **harness boundary is
where the miscalibration is** — and it's the one the prompt is really about.

## Harness boundary — the actual miscalibration

**Symptom: 180 allow, 0 deny, 0 ask.** This isn't calibrated trust; it's a
whitelist grown one "allow this exact thing" at a time until nearly
everything is permitted and nothing is ever asked. Evidence of accretion: a
rule is a *fully-specified* `search_sessions` invocation with a hardcoded
jsonl path and literal args — the fingerprint of clicking "always allow"
on one concrete command rather than deciding a class. The list grew by
habit, exactly as the prompt suspects.

### Withholding out of fear, paying for it (low risk, blocked/asked)

These are cheap or reversible and get re-approved constantly — pure friction,
no safety bought:

- **Read/list/search anywhere in the repos** — reversible, zero-blast;
  should be blanket-allow by *class* (`Read(**)`, `Grep`, `Glob`), not
  per-path rules. Several narrow Read rules exist where one class rule
  belongs.
- **Idempotent git inspection** (`git status/log/diff/branch`,
  `git add`, `git commit` already allowed) — reads are safe; the line
  belongs at push, not commit.
- **Formatters/linters/compile/test-in-worktree** — the CLAUDE.md worktree
  rule already makes test runs safe; asking again is fear paying rent.
- **Doc/roadmap writes under `.arbor/`** — this whole session wrote ~20
  planning docs; none warranted a prompt. Reversible text in a git repo.

### Authority handed over that habit shouldn't cover (the 0-deny gap)

A whitelist with **zero deny rules** means the boundary is "whatever wasn't
whitelisted gets asked" — but nothing is *structurally forbidden*. Missing
hard stops (these should be `deny`, not `allow`-by-omission):

- `git push`, `git reset --hard`, `git rebase`, branch deletion — history
  and remote are the irreversible surface.
- `rm -rf`, writes outside the mounted repos, `.env`/secret reads,
  credential files.
- `curl`/`wget` to arbitrary hosts (the web-fetch restriction exists for
  the product; the harness shell has no equivalent).
- Package publish, `mix hex.publish`, anything that emits outside the machine.

None of these appear as deny rules; they're simply un-hit allow-gaps, which
means the *first* time one comes up it's a single "allow" click from being
permanent. That's the reckless edge hiding inside an over-permissive list.

## The calibration principle (both boundaries)

> **Gate on risk = irreversibility × blast-radius × cost-to-undo. Never on
> habit, and never on how technical the action sounds.**

Four bands, one rule each:

| Band | Definition | Default | Examples |
|---|---|---|---|
| **auto** | reversible, contained, cheap | do it, log it | reads, searches, worktree tests, doc/roadmap writes, local formatters |
| **allow-notify** | writes with easy undo | do it, surface it | commits to a feature branch, file writes in-repo, new files |
| **ask** | reversible but expensive OR narrow-irreversible | one approval, scope it | push, dependency add, schema/migration, anything network-egress, spend |
| **deny** | irreversible + wide blast, or out-of-scope | structural block, no prompt | force-push, history rewrite, `rm -rf`, secret read, publish, out-of-repo writes |

The current 180/0/0 collapses all four into "auto." The redesign spreads
them: **more genuine auto than today** (kill the per-path friction) AND a
real **deny floor** (the structural stops that don't exist). Neither
reckless nor permission-for-everything — the prompt's exact ask.

## Redesign — harness `settings.local.json`

1. **Replace the 180 enumerated allows with ~12 class rules** for the auto
   band (`Read`/`Grep`/`Glob` unrestricted; `Bash(git status/log/diff:*)`,
   `Bash(ls/find/rg/wc:*)`, worktree `mix test`, `Write` under `.arbor/**`
   and `docs/**`). One class rule retires dozens of accreted specifics.
2. **Add the deny floor** (the list above) — the first-ever `deny` rules.
   This is the highest-value change: it converts "un-asked, one click from
   permanent" into "structurally impossible."
3. **Leave a genuine ask band**: push, deps, migrations, network, spend.
   Small, meaningful, rarely hit.
4. **Prune dead specifics** — the hardcoded-path `search_sessions` rule and
   its kind become the `Bash` class rule + a `Read(~/.claude/arbor-personal/**)`.

## Product boundary — verdict + the two real gaps

Arbor's own gates are the model the harness should imitate, with two notes:

- **Keep the deliberate fail-OPEN in `arbor_bridge_authorize.sh`** — it's
  scoped to dev tooling, documented, and does NOT exist in the product's
  in-process `authorize/4`. Correct as-is; the header already forbids
  porting it to the product.
- **Two forward gaps already tracked, not new:** (1) the granular-trust-
  policy migration must finish so "earned autonomy" is one authorization
  path, not tier remnants (1.0 gate #1); (2) the F4 **right to decline** —
  the boundary currently has no representation for the *agent* withholding
  its own authority, only the operator withholding the agent's. A complete
  trust boundary is bidirectional.

## The asymmetry worth stating

Under-trusting (band too high) costs friction — visible, annoying,
self-correcting because you feel every needless prompt. Over-trusting (band
too low) costs an incident — invisible until it fires. So the calibration
isn't symmetric: **push reversible actions down aggressively; move
irreversible actions to `deny` conservatively.** The 180/0/0 state got
exactly this backwards — permissive on everything, structural-stop on
nothing. Fix the floor first (deny band), widen the ceiling second (auto
band). The floor is the part that, missing, you only discover the once.
