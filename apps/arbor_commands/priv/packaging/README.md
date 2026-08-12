# Packaging baselines

## `source_coupling_baseline.v1.json`

Reviewed SPIKE-3B source-coupling baseline, generated from the umbrella tree at
commit `6d9d7b3b6` (see `provenance.tree_oid`). Every undeclared cross-app
occurrence present at that commit is captured in `entries`, and every
unresolved (dynamic-module) reference is captured in `unresolved_entries` with
a reviewed disposition and rationale. Baseline drift — a new undeclared
occurrence, a changed count, or a new unexplained unresolved reference — is a
normal quality-gate failure, not an exception to work around.

The root `quality` alias runs check mode, so `./bin/mix quality` fails on
drift:

```bash
./bin/mix arbor.packaging.source_coupling --check --json
```

### Unresolved dispositions

Each `unresolved_entries` item records why a dynamic `Module.concat`/
`String.to_existing_atom` reference is not a hidden repository-coupling edge:

- `tracked` — bounded dynamic module registries/generation whose resolved
  target space is fixed and gated (e.g. action dispatch by known category/
  action names, agent template resolution by known template names, synthesized
  detector module naming). These are legitimate dynamic dispatch, reviewed and
  accepted as-is.
- `false_positive` — the dynamic module name is derived from code being
  evaluated or submitted at runtime (eval-grader compile/cleanup helpers,
  sandboxed code under policy scanning), not from Arbor's own module graph.
  Because the name originates from evaluated/submitted code, it does not
  represent a static repository source-coupling edge.

### Refreshing the baseline

Only regenerate when a reviewed, intentional change to source coupling has
landed (a new legitimate cross-app reference, a new bounded dynamic-dispatch
site, etc.) — never to silence an unreviewed drift failure.

1. Run a report and inspect what changed:

   ```bash
   ./bin/mix arbor.packaging.source_coupling --json
   ```

2. For every unresolved aggregate entry without a carried-forward disposition,
   author a review file mapping `"file|from_module|reason|kind|expression_digest"`
   to `{"disposition": "tracked" | "false_positive", "rationale": "..."}` with a
   precise, nonblank rationale (see dispositions above).

3. Write the baseline (requires the canonical Git inventory — synthetic
   inventories are refused for this mode):

   ```bash
   ./bin/mix arbor.packaging.source_coupling --write-baseline \
     --unresolved-review path/to/review.json
   ```

4. Verify determinism before committing — two consecutive `--check --json`
   runs must report identical digests/counts with `status: "ok"` and
   `failure_count: 0`:

   ```bash
   ./bin/mix arbor.packaging.source_coupling --check --json
   ./bin/mix arbor.packaging.source_coupling --check --json
   ```

5. Commit the regenerated baseline. Do not hand-edit the generated JSON —
   dispositions and rationales always flow through `--unresolved-review`, and
   the file's `entries_digest` is verified against its own `entries` on read.
