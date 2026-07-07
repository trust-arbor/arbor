# The Autonomous Loop Prompt Pattern (Arbor-flavored)

A reference for writing wake-and-work loop prompts (maintenance agents,
heartbeat cognition, the blog agent, arbor_jobs workers). Origin: a critique
of Peter Steinberger's repository-maintenance loop prompt (2026-07-06) —
excellent on the happy path, silent on failure, cost, and gaming. This
closes those gaps using invariants Arbor already enforces.

## The eight components every loop prompt needs

A loop prompt is a control loop written in prose. Name all eight or the
unnamed ones get an implicit, usually wrong, default.

1. **Activation** — the condition under which the loop runs at all.
2. **Cadence** — wake interval; ideally adaptive (back off when idle).
3. **State read** — what to inspect each wake before acting.
4. **Selection + scope** — which item, bounded to a finite unit of work,
   with the **value function named** (not left to the model's priors).
5. **Quality gate** — what must be true before work lands, *including
   anti-gaming clauses*.
6. **Boundaries** — permissions, escalation (who/what channel/blocking?),
   and don't-thrash rules.
7. **Failure handling** — attempt ceilings, cost ceilings, what a stuck
   item becomes.
8. **Halting** — the enumerated terminal states. A loop with no defined
   stop is a runaway.

## The five Arbor gaps most loop prompts miss

Stated as the invariants that catch them:

| Gap | Arbor invariant | The clause to add |
|---|---|---|
| No failure ceiling → retries the unwinnable forever | F4 `:declined`/retry-terminal | "After N failed attempts on an item, mark it blocked-needs-human and stop touching it this cycle." |
| No cost ceiling → runaway spend | W4 budget ledger | "Stop when the per-wake or per-day spend budget is reached, even mid-item." |
| "Highest-value" is an unspecified judge → proxy drift | proxy-drift audit (north-star doc) | Name the ranking, or require the loop to record the ranking it used so drift is visible. |
| "Escalate" that doesn't block is just logging | fail-closed posture | "Escalation halts THAT item (it becomes decision-ready) and continues others; it does not proceed past the gate." |
| Green CI is game-able (weaken a test to pass) | CLAUDE.md security-regression rule | "Target test passes AND regression set stays green AND no existing test was weakened, skipped, or deleted to achieve it." |

## Template (fill the bracketed slots)

> While [ACTIVATION CONDITION] holds, wake [CADENCE; back off to
> [MAX INTERVAL] when nothing changed, wake immediately on [EVENT
> TRIGGERS]].
>
> Each wake, read [STATE: the queue/threads/board] and the running spend
> against [DAILY BUDGET]. If the budget is spent, stop.
>
> Select the single highest-value item by this ranking: [EXPLICIT ORDER,
> e.g. failing CI on main > security > broken-release > stale-review >
> chore]; record which ranking drove the choice. Assign one **bounded**
> task within [GRANTED CAPABILITIES] only. Do not interrupt coherent
> active work; do not start an item already attempted twice this cycle.
>
> Before anything lands: the target test passes, the regression suite
> stays green, [LIVE PROOF], and autoreview passes — and no existing test
> was weakened, skipped, or deleted to get there. Spend at most
> [PER-ITEM BUDGET] per item.
>
> Escalate [product | access | security | irreversible] decisions through
> [CHANNEL] to [WHOM]; escalation halts that item (mark it decision-ready)
> and the loop continues on others.
>
> After N=[3] failed attempts on an item, mark it blocked-needs-human and
> stop touching it. Record every meaningful change with its rationale.
>
> Stop this cycle when every item is landed, decision-ready, blocked, or
> has no work left — or the budget is spent.

## Notes

- **Adaptive cadence** (heartbeat review R3): a flat 5-minute wake burns
  identical cost whether or not anything changed. Prefer idle backoff +
  event wake. The blog agent is weekly-cron (no polling); a repo-maintenance
  loop is event-driven-with-a-floor.
- **"Bounded task"** is doing real work in the original prompt — keep it.
  It's what stops an unattended agent electing itself an open-ended
  refactor. In Arbor, "bounded" = a leaf goal (goal-subsystem doc), not an
  umbrella.
- The blog agent template (`priv/templates/blog_agent.md`) is a
  weekly-cadence instance of this pattern with a human review gate as its
  "landing" step. arbor_jobs workers are the multi-agent instance. The
  heartbeat is the cognition instance. Same eight components, different
  slot values.
- **Every added gate is a real cost.** This pattern hardens *unattended*
  loops with spend and write access. A supervised, read-only loop can drop
  the failure/cost ceilings — match the ceremony to the blast radius, same
  as the sandbox-strength-by-risk rule.
