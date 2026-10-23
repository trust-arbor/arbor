# Keyed audit checkpoints (optional, deferred)

**Created:** 2026-10-23
**Status:** deferred
**Severity:** low
**Category:** infrastructure

Official roadmap items live in `.arbor/roadmap/` (`0-inbox/` → …). That nested
Git repository is gitignored from the parent and was not present in this
checkout, so this tracked file is the parent-repo copy.

## Summary

Arbor's Security authority-mutation audit journal is hash-linked
(CRC + SHA-256). It detects accidental corruption. It is unkeyed and unsigned,
so a process running as the same user can rewrite entries and recompute the
hashes. That is a documented non-goal today.

This item records an optional later strengthening: periodically sign or HMAC
the journal's chain head with a key the journal writer cannot read, so a
verifier can detect any rewrite since the last checkpoint.

## Why it is deferred

The file layer already states that it does not claim hostile same-UID tamper
resistance (`audit_journal_file.ex`). The current threat model trusts the host
OS and same-UID code inside the BEAM. Keyed checkpoints would change that
assumption and need a key the writer cannot read (OS keyring or a separate
signer process). Low severity relative to that documented non-goal.

## Motivation

[PerMIT](https://arxiv.org/abs/2610.28987) (Jiang, Bai, Shahriar, Du, and
Swamy, 2026) treats logged, content-bound verdicts as the integrity surface
for persistent agent memory. Arbor already hash-links authority-mutation
records; it does not bind the chain head to a key outside the writer's reach.
The paper is motivation for this optional follow-up, not a claim that Arbor
implements PerMIT.

## If this is ever taken up

- Periodically sign or HMAC the journal's chain head with a key the journal
  writer cannot read (for example the OS keyring or a separate signer process).
- Let a verifier detect any rewrite since the last checkpoint.
- Carry checkpoint anchors across compaction:
  - `Arbor.Security.AuditJournalCore.compact/2` and `compact/3`
    (around lines 342 and 367)
  - `Arbor.Security.AuditJournalFile.compact/2` (around lines 232–251)
- Carry checkpoint anchors across retirement:
  - `Arbor.Security.Contracts.AuditJournal.admit_retirement_batch/1`
    and the `arbor.security.audit_retirement_batch.v1` contract
- Optionally bind memory integrity too.

## Related

- [Durable capability mutation audit](../DURABLE_CAPABILITY_MUTATION_AUDIT.md)
- [Security architecture — authority-mutation audit journal](../SECURITY_ARCHITECTURE.md#authority-mutation-audit-journal)
- `apps/arbor_security/lib/arbor/security/audit_journal_core.ex`
- `apps/arbor_security/lib/arbor/security/audit_journal_file.ex`
