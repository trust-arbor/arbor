# Plugin packets — dispatch envelopes

Ready-to-send `arbor_dispatch_task` payloads (see `docs/arbor/CODING_TASK_DISPATCH.md`).
One packet per dispatch, in dependency order (README has the graph). Fill in
`agent_id`; adjust `worker` to taste — these are Sonnet/Haiku-class tasks by
design. Packet text is tainted input to the pipeline (by design); the worker
derives no authority from it.

**Shared task preamble** (embedded in each envelope below):

> Implement work packet <ID> exactly as specified in `docs/specs/plugins/packets/<ID>.md`.
> First read `docs/specs/plugins/README.md` (rules) and the packet's "Read first"
> files in full. Conform to the `PLUGIN-1.0.md` statements the packet cites and
> tag each proving test `@tag spec: "PLUGIN-n"`. Respect the packet's Out of
> scope section. Use `./bin/mix`; `./bin/mix compile --warnings-as-errors` and
> the tests you add must pass; format only the files you touch.

## PP-01 — artifact contracts

```json
{"agent_id": "AGENT_ID",
 "task": {"kind": "coding_change", "plan": {
   "version": 1,
   "task": "Implement work packet PP-01 exactly as specified in docs/specs/plugins/packets/PP-01.md. First read docs/specs/plugins/README.md (rules) and the packet's 'Read first' files in full. Conform to the PLUGIN-1.0.md statements the packet cites and tag each proving test with '@tag spec:'. Respect the packet's Out of scope section. Use ./bin/mix; compile --warnings-as-errors and the tests you add must pass; format only files you touch.",
   "repo_root": "/Users/azmaveth/code/trust-arbor/arbor",
   "worker": {"provider": "claude", "use_pool": true}
 }}}
```

## PP-02 — artifact signing (arbor_security)

Same envelope; replace both `PP-01` occurrences with `PP-02`.
*Security-relevant:* review verdict before merge; key material must never
appear in returns/logs — grep the diff for `private_key` leakage.

## PP-03 — Engine verification (fail-closed)

Same envelope, `PP-03`. *Blast radius:* run-authorization path — the whole
orchestrator suite is the regression anchor. Default stays `:log_only` here;
signed sidecars for stdlib/session DOTs are expected in the diff.

## PP-04 — revocation + enforce flip

Same envelope, `PP-04`. *This flips verification to `:enforce` by default* —
expect CI to prove boot-with-enforcement. If boot breaks on unsigned stray
DOTs, sign them (`mix arbor.pipeline.sign_stdlib`), don't weaken the default.

## PP-05 — arbor_artifacts app + Registry

Same envelope, `PP-05`. New umbrella app at L8 — hierarchy drift-guard must
stay green. CLAUDE.md hierarchy snapshot update is a human follow-up, not the
worker's.

## PP-06 — Activator

Same envelope, `PP-06`. *Most design-sensitive packet.* If review flags
rollback/receipt drift vs the packet, prefer rework over spec deviation. The
TemplateRegistry overlay is the only orchestrator change allowed.

## PP-07 — install/uninstall pipelines

Same envelope, `PP-07`. Two new stdlib DOTs + their signed sidecars in the
diff; `mix arbor.pipeline.validate` on both is part of acceptance.

## PP-08 — council admission gate

Same envelope, `PP-08`. Consensus is faked in tests — no `:llm` tags.

## PP-09 — browser plugin migration (1.0 exit A)

Same envelope, `PP-09`. *Behavior-preserving by default* (bootstrap
auto-activates). The dangerous diff is `list_actions/0` — reviewer should
verify ONLY the browser group moved.

## PP-10 — dashboard dispatch + nav (parallel-safe with PP-09)

Same envelope, `PP-10`. Route-order guard test is the regression anchor
(catch-all must not shadow core routes).

## PP-11 — observability plugin (1.0 exit B)

Same envelope, `PP-11`. Big move diff (4 LiveViews + cores) — review for
reference leaks from core into the bundle subtree (the isolation guard test
enforces it).

## PP-12 — bundle format

Same envelope, `PP-12`. Hostile-archive fixtures are part of the diff; import
must verify BEFORE any side effect.

## PP-13 — AST static gate (post-1.0 flag; parallel-safe with PP-14)

Same envelope, `PP-13`. Pure static analysis — the suite must never compile
hostile fixtures. Defaults keep generative installs disabled.

## PP-14 — node isolation seam

Same envelope, `PP-14`. `:external`-tagged peer-node tests; default config
`:none`. The hidden-node runtime guard (not in `Node.list()`) is the
security-relevant assertion — read the review verdict before merge.

## PP-15 — shared library + publish (Stage 2)

Same envelope, `PP-15`. Embeddings faked deterministic; degraded-mode fallback
tested.
