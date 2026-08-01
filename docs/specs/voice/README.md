# Voice-First Interface — Implementation Handoff

This directory is a self-contained handoff package: a smaller model (or the DOT
coding pipeline) can implement the voice-first interface from these files without
re-deriving the design. Design rationale lives in
`.arbor/roadmap/2-planned/voice-first-interface.md`; do not re-litigate decisions here.

## Contents

| File | Purpose |
|---|---|
| `VOICE-1.0.md` | Normative spec. Numbered RFC 2119 statements; tests tag `@tag spec: "VOICE-n"`. |
| `packets/VP-01.md` … `VP-10.md` | Work packets, each sized to ONE reviewable change (one `coding_change` dispatch). |
| `DISPATCH.md` | Ready-to-send `coding_change` plan envelopes per packet, with the dependency order. |

## Packet order and dependencies

```
VP-01 (contracts)          ──►  VP-02 (arbor_voice app + behaviour)
VP-02 ──► VP-03 (xAI backend)      VP-02 ──► VP-06 (Speakable)
VP-03 + VP-06 ──► VP-04 (VoiceSession + engagement recorder)
VP-04 ──► VP-05 (consult_agent / delegate_to_agent tools)
VP-05 ──► VP-07 (desk audio loop + mix task)      ← Phase 1 exit
VP-07 ──► VP-08 (phone loop)                      ← Phase 2 exit
VP-04 ──► VP-09 (voice approvals adapter)         ← independent after VP-04
VP-05 ──► VP-10 (notifications + status/dispatch) ← Phase 4
```

Do not parallelize packets that share files (VP-03/VP-04 both touch `arbor_voice`).
VP-09 may run in parallel with VP-07/VP-08.

## Rules for the implementing model (read before every packet)

1. **Read first, code second.** Each packet lists "Read first" files. Read all of
   them. The code is the truth; if a packet contradicts the code, follow the code and
   note the discrepancy in your result summary.
2. **Use `./bin/mix`**, never bare `mix`. `./bin/mix compile --warnings-as-errors`
   must pass. `./bin/mix format` the files you touch. Umbrella-wide formatter is
   red on pre-existing files — format only your files.
3. **Library hierarchy is law** (CLAUDE.md "Library Hierarchy"). `arbor_voice` is L8.
   Never add a dep from a lower-level app to a higher one. Never use
   `Code.ensure_loaded?`/`apply` runtime indirection to dodge the hierarchy.
4. **Contracts:** read `docs/arbor/CONTRACT_RULES.md` before touching
   `arbor_contracts`. Library-specific behaviours stay in the library
   (`Arbor.Voice.RealtimeBackend` lives in `arbor_voice`, NOT in contracts).
5. **Tests:** follow `docs/arbor/TEST_TAGGING.md`. Tag conformance tests
   `@tag spec: "VOICE-n"` for every statement the packet claims. No `:llm`-tagged
   tests unless the packet says so; anything touching a live socket, subprocess, or
   the phone is `:external` and must also work as a unit test via the injected fake.
6. **No live-credential tests.** xAI/OAuth interaction is tested through the
   transport seam (fake transport module). Never call `Arbor.LLM.OAuth` in tests.
7. **Don't invent APIs.** If a packet says "locate X by grepping Y", do that. If X
   truly doesn't exist, stop and report — do not stub a fictional module.
8. **Scope discipline.** "Out of scope" sections are binding. Small unavoidable
   adjacent fixes are allowed only when compilation/tests force them; call them out.
9. **When you remove a `(planned)` marker** from `VOICE-1.0.md` (your packet says
   which), the same change must add the proving test(s).
10. **Result summary** must list: files changed, spec ids proven (with test file:line),
    commands run, and any deviations from the packet.

## Dispatching via the DOT coding pipeline

Use the envelopes in `DISPATCH.md` with signed MCP `arbor_dispatch_task`
(see `docs/arbor/CODING_TASK_DISPATCH.md`). One packet = one dispatch = one
reviewable branch. Poll `arbor_task_status`, answer approvals with
`arbor_answer_approval`, read `arbor_task_result`.

Manual alternative: give a coding agent the packet file plus this README and let it
work on a feature branch; the packet's Acceptance section is the review checklist.
