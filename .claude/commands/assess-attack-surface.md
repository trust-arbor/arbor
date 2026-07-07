---
description: >
  Thoroughly assess ONE attack surface from .security/attacksurface.md — its exposure,
  auth, defenses, and platform-specific weaknesses — and recommend a testing cadence
  based on criticality × cost. Authorized, own-infrastructure assessment only.
argument-hint: "<asset name> (or 'all' for a triage pass)"
---

# /assess-attack-surface — Assess one owned asset

**Target:** $ARGUMENTS

## Rules of engagement (non-negotiable)

- **Only assets Hysun owns/operates and has authorized.** Confirm the target is in
  `.security/attacksurface.md` before proceeding. If it fronts a third party
  (a vendor's API you consume), you assess YOUR config against it, never their side.
- **Default to passive.** Configuration review, exposure reconciliation, and
  known-issue checks against documented state are the baseline and are always safe.
  **Any active testing** (auth probing, header scans, fuzzing, a real request to a
  live endpoint) requires an explicit go from Hysun in this session, one asset at a
  time — never batch-authorized, never inferred from "assess everything."
- **Read-only by default.** Propose fixes; do not change firewall rules, rotate
  keys, or edit live config without explicit approval per change.
- **Prohibited-action rules still apply** — no entering credentials, no destructive
  ops, no bypassing controls even in a test.

## Assessment procedure (per asset)

1. **Pull the record** from `.security/attacksurface.md`. If absent, run the
   AttackSurface skill's discovery to create it first, then assess.
2. **Reconcile documented vs. actual** (passive): does the record's exposure/auth/
   defenses still match repo config, firewall files, DNS, deploy manifests? Flag drift.
3. **Walk the platform's vuln-class list** (from the skill's class library). For
   each class: state whether the asset's documented defenses address it, and
   whether verification requires active testing (→ ask before doing it).
4. **Trace blast radius:** if owned, what's the next hop? Does a defense actually
   contain it, or is it convention (in-process check) vs. architecture (firewall,
   no NIC)? Name the difference — this is the project's own core distinction.
5. **Score residual risk** per class: likelihood × blast radius, given current
   defenses. Rank findings; separate "misconfig to fix now" from "design gap."
6. **Recommend a testing cadence** (below).
7. **Write the assessment note** to `.security/assessments/<asset>-<date>.md`
   (gitignored), and update the asset record's `Last assessed` + any changed
   exposure/defenses. Report findings ranked by residual risk.

## Testing-cadence model (criticality × cost)

Recommend a frequency per asset from these inputs:
- **Criticality** (from the record): crown-jewel / high / medium / low.
- **Change rate:** how often the asset's config/exposure actually changes.
- **Assessment cost:** passive-only (cheap, automatable) vs. needs active testing
  (expensive, manual, higher blast risk).
- **Exposure:** public > VPN-only > internal > localhost.

Default matrix (tune per asset; state the reasoning, not just the cell):

| Criticality | Public | VPN/internal-only |
|---|---|---|
| **Crown-jewel** (signing keys, core zone, DNS registrar, prod DB) | passive: continuous/CI-gated · active: monthly | passive: monthly · active: quarterly |
| **High** (gateway, edge node, CI/git, public site) | passive: weekly · active: quarterly | passive: monthly · active: semi-annual |
| **Medium** (compute nodes, vendor accounts) | passive: monthly · active: semi-annual | passive: quarterly · active: annual |
| **Low** (lab/disposable, localhost inference) | passive: quarterly | on-change only |

Cadence adjusters:
- **Cheap + automatable → do it more often** (fold passive checks into CI:
  header scan, TLS grade, exposed-port diff, secret-scan). Automation collapses
  cost, so frequency can rise for free — prefer this over manual heroics.
- **On-change always wins:** any asset gets an immediate passive pass when its
  config/exposure/DNS changes, regardless of the scheduled cadence.
- **Crown-jewels get a tripwire, not just a schedule:** continuous telemetry
  (the gate-liveness canary, cert-expiry monitor, CT-log watch for cwf.farm,
  new-open-port alert) beats any periodic scan for the assets that matter most.

## Output

- Findings ranked by residual risk, each: class · documented defense · gap ·
  passive-verifiable vs. needs-active-test · fix.
- One recommended cadence line for the asset, with the reasoning.
- Offer to schedule the recurring passive pass (mix arbor scheduler / cron) and
  to wire the cheap checks into CI.
