# Voice packets — dispatch envelopes

Ready-to-send `arbor_dispatch_task` payloads (see `docs/arbor/CODING_TASK_DISPATCH.md`).
One packet per dispatch, in dependency order (README has the graph). Fill in
`agent_id`; adjust `worker` to taste — these are Sonnet/Haiku-class tasks by design,
so a cheaper provider/model is the point. Packet text is tainted input to the
pipeline (by design); the worker derives no authority from it.

**Shared task preamble** (embedded in each envelope below):

> Implement work packet <ID> exactly as specified in `docs/specs/voice/packets/<ID>.md`.
> First read `docs/specs/voice/README.md` (rules) and the packet's "Read first" files
> in full. Conform to the `VOICE-1.0.md` statements the packet cites and tag each
> proving test `@tag spec: "VOICE-n"`. Respect the packet's Out of scope section.
> Use `./bin/mix`; `./bin/mix compile --warnings-as-errors` and the tests you add
> must pass; format only the files you touch.

## VP-01 — contracts: `:voice` transport

```json
{"agent_id": "AGENT_ID",
 "task": {"kind": "coding_change", "plan": {
   "version": 1,
   "task": "Implement work packet VP-01 exactly as specified in docs/specs/voice/packets/VP-01.md. First read docs/specs/voice/README.md (rules) and the packet's 'Read first' files in full. Conform to the VOICE-1.0.md statements the packet cites and tag each proving test with '@tag spec:'. Respect the packet's Out of scope section. Use ./bin/mix; compile --warnings-as-errors and the tests you add must pass; format only files you touch.",
   "repo_root": "/Users/azmaveth/code/trust-arbor/arbor",
   "worker": {"provider": "claude", "use_pool": true}
 }}}
```

## VP-02 — `arbor_voice` app + RealtimeBackend behaviour

Same envelope; replace both `VP-01` occurrences with `VP-02`.
*Note for the reviewer:* this packet adds a new umbrella app — expect the
hierarchy drift-guard test to pass (L8, deps only downward). CLAUDE.md's hierarchy
snapshot is a human follow-up, not the worker's.

## VP-03 — xAI Realtime backend

Same envelope, `VP-03`. *Blast radius note:* protocol extraction from the
prototype; no network tests allowed.

## VP-06 — Speakable renderer (may run after VP-02, parallel to VP-03)

Same envelope, `VP-06`.

## VP-04 — VoiceSession + engagement recorder

Same envelope, `VP-04`. *Requires VP-03 and VP-06 merged.* This is the most
design-sensitive packet; if review flags transcript-shape drift vs
`Session.Persistence`, prefer rework over spec deviation.

## VP-05 — front-desk tools

Same envelope, `VP-05`. *Requires VP-04 merged.*

## VP-07 — desk audio loop + mix task (Phase 1 exit)

Same envelope, `VP-07`. Human runs the live desk check after merge.

## VP-08 — phone loop (Phase 2 exit)

Same envelope, `VP-08`. Human runs the live walk test after merge.

## VP-09 — voice approvals adapter (parallel-safe after VP-04)

Same envelope, `VP-09`. *Security-relevant:* consider
`"review_profile": "binding"` explicitly (it is the default) and read the review
verdict before merging; VOICE-18/19/20 tests are the regression anchor.

## VP-10 — notifications + status/dispatch tools (Phase 4)

Same envelope, `VP-10`. Contains a locate-the-facade step; if the worker reports
the facade missing, that's a real finding — stop and re-plan rather than letting
it invent one.

## After each merge

1. `./bin/mix arbor.spec.coverage` — the packet's spec ids should move to proven;
   `(planned)` markers the packet removes should no longer be excluded.
2. Update the checklist in `.arbor/roadmap/2-planned/voice-first-interface.md`
   (phase gates) as packets land.
