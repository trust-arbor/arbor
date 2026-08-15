# CONTRACTS-1.0 - `Arbor.Contracts` Admission Control

**Status:** active, with eviction-time requirements explicitly planned

**Canonical since:** 2026-08-12

This is the tracked conformance authority for what may reside in
`apps/arbor_kernel/lib/arbor/contracts`. It amends
`docs/arbor/CONTRACT_RULES.md`; that document
contains the implementation guidance and this document defines the statement
IDs used by `./bin/mix arbor.spec.coverage`.

Local handoff material under nested `docs/specs/` directories is not tracked
conformance authority.

## Normative Statements

- **AC-1** (MUST): A module in the `Arbor.Contracts` namespace MUST be a type referenced by at least two other umbrella apps, an `api/` facade declaring at least one callback, or an explicitly grandfathered exception with a roadmap disposition.
- **AC-2** (MUST): The census MUST independently compute external app consumers and internal `Arbor.Contracts` file consumers from tracked `lib/` and `test/` source, expanding brace aliases and matching declared modules plus descendants.
- **AC-3** (MUST): A zero-consumer static census result MUST NOT by itself authorize deletion; deletion requires corroborating runtime-usage evidence, while one-consumer relocation does not.
- **AC-4** (MUST, planned): An evicted module MUST use the destination app's `<Root>.Contracts.<Leaf>` namespace and matching path, retaining a source segment only to resolve a destination collision.
- **AC-5** (MUST NOT, planned): An eviction MUST NOT leave a compatibility delegate, alias module, or re-export in `Arbor.Contracts`.
- **AC-6** (MUST): The umbrella MUST carry an executable admission guard with `:warn` and `:enforce` modes, and enforce mode MUST reject new inadmissible files while allowing explicitly grandfathered debt.
- **AC-7** (MUST, planned): Contract graduation MUST default to the owning app's `Contracts` namespace and promote into `Arbor.Contracts` in `arbor_kernel` only when AC-1 is satisfied.
- **AC-8** (MUST NOT, planned): An eviction MUST NOT change struct shape, constructor behavior, validation messages, map conversion, or JSON encoding, and missing constructor coverage MUST be added before the move.
- **AC-9** (MUST NOT, planned): An eviction MUST NOT change umbrella dependency declarations or computed hierarchy levels, and every move MUST pass strict umbrella compilation.
- **AC-10** (MUST NOT, planned): A single-consumer callback module MUST NOT be evicted mechanically; injected runtime callers MUST be dispositioned before deciding whether it stays or moves.
- **AC-11** (MUST): A module MUST NOT be classified as movable while a non-exempt file remaining in `Arbor.Contracts` references it; registry references and same-destination co-movers are the only exemptions.
- **AC-12** (MUST NOT, planned): An eviction's destination name MUST NOT be changed to avoid call-site alias shadowing; call sites use explicit alias names, while multi-module files with differing consumers require manual disposition.

## Current Enforcement

`Arbor.Contracts.Census` implements AC-1, AC-2, AC-3, AC-6, and AC-11.
The admission test binds the default to `:warn`, independently asserts the
dated exception inventory exposed by
`Arbor.Contracts.Census.default_grandfathered/0`, and exercises enforce mode
against both new and grandfathered debt.

The executable census is static analysis. Tier D deletion remains blocked on
runtime evidence, and AC-4, AC-5, AC-7 through AC-10, and AC-12 become active
acceptance rules when the associated eviction packets begin.
