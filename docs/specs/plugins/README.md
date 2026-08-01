# Plugin Infrastructure (Unified Artifact Channel) — Implementation Handoff

This directory is a self-contained handoff package: a smaller model (or the DOT
coding pipeline) can implement the plugin infrastructure from these files without
re-deriving the design. Design rationale lives in
`.arbor/roadmap/2-planned/plugin-infrastructure.md` and
`.arbor/decisions/2026-07-13-unified-artifact-channel.md`; do not re-litigate
decisions here.

**Core reframe (vs the old brainstorm):** there is no bespoke plugin subsystem.
There is ONE signed-artifact channel — manifest → review → sign → register →
activate — shared by plugins, DOT templates, and (later) skills. A *plugin* is an
artifact kind whose payload bundles actions, DOT pipelines, signal hooks, and UI
views. This packet series also **subsumes**
`.arbor/roadmap/2-planned/dot-signing-and-verification.md` (PP-01…PP-04).

## Contents

| File | Purpose |
|---|---|
| `PLUGIN-1.0.md` | Normative spec. Numbered RFC 2119 statements; tests tag `@tag spec: "PLUGIN-n"`. |
| `packets/PP-01.md` … `PP-15.md` | Work packets, each sized to ONE reviewable change (one `coding_change` dispatch). |
| `DISPATCH.md` | Ready-to-send `coding_change` plan envelopes per packet, with dependency order. |

## Packet order and dependencies

```
Phase A — signing substrate (subsumes dot-signing-and-verification)
PP-01 (artifact contracts) ──► PP-02 (signing + revocation in arbor_security)
PP-02 ──► PP-03 (Engine verification, fail-closed)
PP-03 ──► PP-04 (revocation enforcement + mix tasks)

Phase B — registry + lifecycle
PP-01 ──► PP-05 (arbor_artifacts app + Registry)
PP-05 + PP-02 ──► PP-06 (Activator: registrations, grants, signal hooks)
PP-06 + PP-03 ──► PP-07 (install/uninstall stdlib pipelines + receipts)
PP-07 ──► PP-08 (council admission gate for shared/stdlib)

Phase C — first plugins + UI
PP-07 ──► PP-09 (browser plugin migration; actions only)   ← 1.0 exit A
PP-05 ──► PP-10 (dashboard runtime dispatch + nav from registry)
PP-10 + PP-06 ──► PP-11 (observability dashboard plugin)   ← 1.0 exit B

Phase D — distribution, isolation, marketplace (post-1.0 except PP-12)
PP-07 ──► PP-12 (bundle format, export/import)
PP-12 ──► PP-13 (generative-path guards: AST gate)         ← post-1.0 flag
PP-12 ──► PP-14 (node isolation seam: hidden node / MCP)   ← post-1.0 flag
PP-12 + PP-08 ──► PP-15 (library index + publish)          ← Stage 2
```

Do not parallelize packets that share files (PP-02/03/04 all touch
`arbor_security` + orchestrator authorization; PP-05/06/07 all touch
`arbor_artifacts`). PP-10 may run in parallel with PP-09. PP-13/PP-14 may run in
parallel after PP-12.

## Rules for the implementing model (read before every packet)

1. **Read first, code second.** Each packet lists "Read first" files. Read all of
   them. The code is the truth; if a packet contradicts the code, follow the code
   and note the discrepancy in your result summary.
2. **Use `./bin/mix`**, never bare `mix`. `./bin/mix compile --warnings-as-errors`
   must pass. `./bin/mix format` only the files you touch.
3. **Library hierarchy is law** (CLAUDE.md "Library Hierarchy"). Placements used
   here: contracts L0, `arbor_security` L2, `arbor_orchestrator` L7, new
   `arbor_artifacts` L8, `arbor_dashboard` L9. Never add a dep from a lower-level
   app to a higher one; never dodge the hierarchy with `Code.ensure_loaded?`/`apply`.
   Corollary baked into the design: **verification/revocation state lives in
   `arbor_security` (L2) so the orchestrator (L7) never depends on the registry (L8).**
4. **Contracts:** read `docs/arbor/CONTRACT_RULES.md` before touching
   `arbor_contracts`. Library-specific behaviours stay in the library.
5. **Tests:** follow `docs/arbor/TEST_TAGGING.md`. Tag conformance tests
   `@tag spec: "PLUGIN-n"` for every statement the packet claims. Run
   `./bin/mix arbor.spec.coverage` to see the proof map. No `:llm`-tagged tests
   unless the packet says so.
6. **Security invariants are non-negotiable:** no raw private keys outside
   `arbor_security`; signer/authority references are opaque
   `Arbor.Contracts.Security.SigningAuthority` values and MUST NEVER be serialized
   into Engine context or checkpoints (JSON-clean boundary).
7. **Don't invent APIs.** If a packet says "locate X by grepping Y", do that. If X
   truly doesn't exist, stop and report — do not stub a fictional module.
8. **Scope discipline.** "Out of scope" sections are binding. Small unavoidable
   adjacent fixes are allowed only when compilation/tests force them; call them out.
9. **When you remove a `(planned)` marker** from `PLUGIN-1.0.md` (your packet says
   which), the same change must add the proving test(s).
10. **Result summary** must list: files changed, spec ids proven (with
    test file:line), commands run, and any deviations from the packet.

## Dispatching via the DOT coding pipeline

Use the envelopes in `DISPATCH.md` with signed MCP `arbor_dispatch_task`
(see `docs/arbor/CODING_TASK_DISPATCH.md`). One packet = one dispatch = one
reviewable branch. Poll `arbor_task_status`, answer approvals with
`arbor_answer_approval`, read `arbor_task_result`.

Manual alternative: give a coding agent the packet file plus this README and let
it work on a feature branch; the packet's Acceptance section is the review checklist.
