# Packaging baselines

## `source_coupling_baseline.v1.json`

Reviewed SPIKE-3B source-coupling baseline. Check mode:

```bash
./bin/mix arbor.packaging.source_coupling --check --json
```

Replace only with explicit write (after reviewing unresolved dispositions):

```bash
./bin/mix arbor.packaging.source_coupling --write-baseline \
  --unresolved-review path/to/review.json
```

The seed file ships with empty `entries` so the tool compiles and pure tests pass.
Before CI can stay green, regenerate against the current tree and commit the
reviewed baseline (plus any unresolved disposition review file).
