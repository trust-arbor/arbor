# Engagement packets — dispatch envelopes

Same conventions as `docs/specs/voice/DISPATCH.md` (one packet = one
`coding_change` dispatch = one reviewable branch; packet text is tainted input).
Fill in `agent_id`; envelopes differ only in the packet id.

**Template:**

```json
{"agent_id": "AGENT_ID",
 "task": {"kind": "coding_change", "plan": {
   "version": 1,
   "task": "Implement work packet EP-NN exactly as specified in docs/specs/engagements/packets/EP-NN.md. First read docs/specs/engagements/README.md AND docs/specs/voice/README.md 'Rules for the implementing model', then the packet's 'Read first' files in full. Conform to the ENGAGE-1.0.md statements the packet cites and tag each proving test with '@tag spec:'. Respect the packet's Out of scope section. Use ./bin/mix; compile --warnings-as-errors and the tests you add must pass; format only files you touch.",
   "repo_root": "/Users/azmaveth/code/trust-arbor/arbor",
   "worker": {"provider": "claude", "use_pool": true}
 }}}
```

## Order & notes

| # | Packet | After | Notes for the operator |
|---|---|---|---|
| 1 | EP-01 | — | Contracts + comms; pure instrumentation, zero behavior change. |
| 2 | EP-02 | EP-01 | **The island-killer.** Behavior change behind `ARBOR_COMMS_RESPONDER`; smoke Signal after merge. Consider watching the review verdict closely — cross-sender isolation is the security payoff. |
| 3 | EP-03 | EP-02 | Adds the no-new-islands canary; expect it to list voice as pending until VP-04 merges. |
| 4 | EP-04 | — (parallel) | Has a STOP condition: if Session's `:acp` runtime is incomplete, the result is a findings report, not code. Treat that outcome as success. |
| 5 | EP-05 | EP-01 | Land before voice VP-10 if possible (VP-10 consumes its signal). Recorder reuse note: whichever of VP-04/EP-05 merges second reuses the first's recorder. |
| 6 | EP-06 | EP-02 | Result summary must enumerate ALL memory-write sites — it is EP-07's input. |
| 7 | EP-07 | EP-06 | Security-relevant; the allow/deny matrix in the result summary is the review artifact. Suggest reviewing with the binding council verdict in hand before merge. |
| 8 | EP-08 | EP-01 | Keep the delivery-preference flag OFF in prod until the convergence decision (brainstorm doc) is made. |

## After each merge

1. `./bin/mix arbor.spec.coverage` — packet's ENGAGE ids move to proven; its
   `(planned)` markers are removed by the packet itself.
2. Tick the phase table in
   `.arbor/roadmap/2-planned/engagement-substrate-completion.md`.
3. After EP-03: the canary is the standing guard — future conversational surfaces
   must register in it (this replaces manual island audits).
