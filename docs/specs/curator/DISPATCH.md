# Curator packets — dispatch envelopes

Ready-to-send `arbor_dispatch_task` payloads (see `docs/arbor/CODING_TASK_DISPATCH.md`).
One packet per dispatch, in dependency order (README has the graph). Fill in
`agent_id`; adjust `worker` to taste — these are Sonnet/Haiku-class tasks by design,
so a cheaper provider/model is the point. Packet text is tainted input to the
pipeline (by design); the worker derives no authority from it.

**Sequencing note:** CP-02 → CP-03 → CP-04 must run sequentially (all touch
`apps/arbor_actions/lib/arbor/actions/curator.ex`). CP-05 and CP-06 may run in
parallel after CP-04 merges.

**Shared task preamble** (embedded in each envelope below):

> Implement work packet <ID> exactly as specified in `docs/specs/curator/packets/<ID>.md`.
> First read `docs/specs/curator/README.md` (rules) and the packet's "Read first" files
> in full. Conform to the `CURATE-1.0.md` statements the packet cites and tag each
> proving test `@tag spec: "CURATE-n"`. Respect the packet's Out of scope section.
> Use `./bin/mix`; `./bin/mix compile --warnings-as-errors` and the tests you add
> must pass; format only the files you touch.

## CP-01 — `arbor_curator` app + item schema + store

```json
{"agent_id": "AGENT_ID",
 "task": {"kind": "coding_change", "plan": {
   "version": 1,
   "task": "Implement work packet CP-01 exactly as specified in docs/specs/curator/packets/CP-01.md. First read docs/specs/curator/README.md (rules) and the packet's 'Read first' files in full. Conform to the CURATE-1.0.md statements the packet cites and tag each proving test with '@tag spec:'. Respect the packet's Out of scope section. Use ./bin/mix; compile --warnings-as-errors and the tests you add must pass; format only files you touch.",
   "repo_root": "/Users/azmaveth/code/trust-arbor/arbor",
   "worker": {"provider": "claude", "use_pool": true}
 }}}
```

*Note for the reviewer:* this packet adds a new umbrella app — expect the hierarchy
drift-guard test to pass (L4, deps only downward). CLAUDE.md's hierarchy snapshot is
a human follow-up, not the worker's. It also fixes the `arbor.spec.coverage` glob
(one level → recursive), so the coverage report will newly include VOICE/ENGAGE
statements — expected, not a regression.

## CP-02 — Signal intake action + pipeline

Same envelope; replace both `CP-01` occurrences with `CP-02`. *Requires CP-01
merged.* Adds the `arbor_curator` dep to `arbor_actions` and the first curator
pipeline. Operator follow-up after merge: set `:allowed_senders`, sign
`curator_intake.caps.json` (README "Operator setup").

## CP-03 — fetch batch action

Same envelope, `CP-03`. *Requires CP-02 merged (shared actions file).*
*Review focus:* the egress-declaration decision — the packet requires the worker to
report the authorization-path file:line that justified the shape it shipped. No new
HTTP clients anywhere.

## CP-04 — assessor + assess batch action

Same envelope, `CP-04`. *Requires CP-03 merged (shared actions file).*
*Review focus:* schema format verified against `arbor_llm`'s validator (not
invented), injection-delimiter prompt test present, no hardcoded model strings.

## CP-05 — hourly process pipeline + caps

Same envelope, `CP-05`. *Requires CP-03 + CP-04 merged.* May run in parallel with
CP-06. Operator follow-up: sign `curator_process.caps.json`.

## CP-06 — digest renderer + 06:20 pipeline

Same envelope, `CP-06`. *Requires CP-04 merged.* May run in parallel with CP-05.
Operator follow-up: sign `curator_digest.caps.json`; next morning, confirm the
curator section appears in `~/.arbor/reports/morning-digest/`.
