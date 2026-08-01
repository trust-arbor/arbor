# Engagement Substrate Completion — Implementation Handoff

Same handoff format as `docs/specs/voice/` — read that README's "Rules for the
implementing model" and apply them verbatim here (Read-first discipline,
`./bin/mix`, hierarchy is law, CONTRACT_RULES/TEST_TAGGING, spec tags, scope
discipline, result summaries). This file adds only what differs.

## Contents

| File | Purpose |
|---|---|
| `ENGAGE-1.0.md` | Normative spec; tests tag `@tag spec: "ENGAGE-n"`. |
| `packets/EP-01.md` … `EP-08.md` | Work packets, one reviewable change each. |
| `DISPATCH.md` | `coding_change` envelopes in dependency order. |

## Packet order

```
Phase A: EP-01 (resolver + conversation_id + contracts)
         ──► EP-02 (Session-backed responder, retire shared CLI session)
         ──► EP-03 (outbound provenance + canary)
Phase B: EP-04 (ChatLive :acp → Session runtime)     [independent of A]
         EP-05 (task ↔ engagement linkage)           [after EP-01]
Phase C: EP-06 (memory provenance stamping)          [after EP-02]
         ──► EP-07 (recall audience-containment gate)
         EP-08 (interactions into transcripts)       [after EP-01]
```

EP-04 may run parallel to Phase A. EP-05/EP-08 need EP-01's resolver only.
EP-07 strictly follows EP-06.

## Extra rules for this set

1. **The hierarchy trap is the whole game here.** `arbor_comms` (L4) must never
   reference Session/agent modules. Cross-level flow uses the two sanctioned seams
   only: the `ResponseGenerator` config-injected behaviour (comms calls whatever
   module config names — that module lives at L7) and plain
   `GenServer.call(session_pid, {:send_message, msg})` against a pid (no module
   dep — this is exactly how `Arbor.Agent.APIAgent` does it; copy it).
2. **Do not break Signal/Limitless/Email while migrating.** EP-02 keeps the legacy
   responder selectable via `ARBOR_COMMS_RESPONDER=legacy` (mirror the
   `ARBOR_CODING_EXECUTOR` pattern documented in `docs/arbor/CODING_TASK_DISPATCH.md`
   and validated at startup the same way).
3. **Entry shapes are already typed.** Inbound is `Arbor.Contracts.Comms.Message`;
   Session entry is `Arbor.Contracts.Session.UserMessage`. The packets tell you the
   exact constructor conventions — never pass bare strings across the seam.
4. When a packet's "locate" step finds richer machinery than the packet assumes
   (e.g. a real contact-identity module for sender→user mapping), USE the richer
   machinery and say so in the result summary — the packet's fallback is the floor,
   not the ceiling.
