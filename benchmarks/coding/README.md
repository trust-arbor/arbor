# Coding benchmark catalog (v1)

This directory holds a **tracked, data-only** catalog of pinned Arbor-history
coding tasks for the Phase 6 legacy-vs-pipeline conformance harness.

It does **not** run that benchmark. The Apple Container/Linux validation
baseline was provisioned and passed its live adversarial matrix on 2026-07-16;
real paired execution still requires trusted adapter/runtime configuration and
an operator-started benchmark run.

## Files

| Path | Role |
|------|------|
| `catalog-v1.json` | Closed catalog of fixture pins, task input, and verifier selectors |
| (generated) prepared root | Produced by `mix arbor.coding.benchmark.prepare` — not checked in |

Nested Git fixture repositories must **not** be committed into the parent
source tree. Materialize them into an ignored or temporary output directory.

## Prepare fixtures

From the trusted Arbor repository root:

```bash
./bin/mix arbor.coding.benchmark.prepare \
  --catalog benchmarks/coding/catalog-v1.json \
  --output tmp/coding-benchmark-prepared
```

Optional `--source` must resolve inside the trusted command root and defaults
to that root (the current working repository).

### Generated layout

```text
tmp/coding-benchmark-prepared/
  manifest.json            # arbor.coding_benchmark.manifest.v1
  target-evidence.json     # catalog/manifest-bound target evidence
  publication.json         # written last; marks a complete publication
  fixtures/<fixture_id>/   # standalone base checkout repositories
```

- **manifest.json** is the existing harness input shape. Fixture paths are
  relative to the prepared root. Validate with
  `Arbor.Commands.CodingBenchmark.validate_manifest/1` (the prepare task
  already does this before publish).
- **target-evidence.json** carries catalog and manifest digests plus per-fixture
  base/target OIDs and normalized input hashes for the trusted
  `exact_target_tree` objective verifier. It is not worker-visible answer
  material and does not select modules or commands. After stable sidecar reads
  and closed publication validation, the runner retains only the fixture-bound
  target tree OIDs needed by that built-in verifier.
- **publication.json** is the publication linearization marker. The output root
  is reserved with an exclusive private mkdir before any fixture is written.
  The marker is written and verified under a private temporary name, then
  atomically hard-linked into place as the final fallible operation. The runner
  validates both sidecars and their canonical digests before consuming a
  prepared manifest; a root with only one sidecar is incomplete.
- Each **fixture repository** is reconstructed via the hardened
  OID/tree path in `Arbor.Commands.CodingBenchmark.reconstruct_fixture_repository/5`
  (no linked worktrees, alternates, hooks, replace refs, network, or copied
  source `.git` config).

Publication is no-clobber and marker-atomic: an existing destination is
refused, and failures remove only the exact inode captured when the private
unpublished root was created.

## Catalog trust assumptions

- Pins are **reviewed Arbor commits integrated by 2026-07-16**, not LLM-invented
  synthetic tasks or foreign repositories.
- Each fixture binds exact `base_commit_oid` / `base_tree_oid` and
  `target_commit_oid` / `target_tree_oid`. Prepare re-verifies those OIDs in
  the source repository and requires the target to be the base's direct child
  before writing output.
- `source_repository_label` is reviewed provenance metadata, not an authority
  claim. Immutable commit/tree pins and direct-parent checks bind the history.
- Task objectives and acceptance criteria are derived from the actual diffs
  and tests between those commits.
- `verifier_id` values are **data selectors**. The closed selector
  `exact_target_tree` always resolves to Arbor's built-in verifier when a
  prepared publication is validated; Application config and ordinary runtime
  verifier options cannot override or spoof it. Catalog data cannot name MFA
  callbacks.

## Objective verification (`exact_target_tree`)

For each fixture that selects `exact_target_tree`, the harness compares the
final canonical `HEAD^{tree}` of that executor's isolated workdir with the
`target_tree_oid` bound to the same `fixture_id` in validated target evidence.

- Target OIDs are never sent to coding workers, never included in adapter
  requests, and never appear as answer material in the public report (only the
  closed pass/fail objective status already admitted by the harness).
- Scoring uses the hardened `CodingBenchmark.Git` primitive under one bounded
  verifier deadline; manifests cannot select modules, shell strings, or MFAs.
- Sidecar-free legacy manifests that do not use `exact_target_tree` continue to
  require an explicit trusted verifier registry for their other selectors.

### Operator configuration still required for a full paired run

```bash
# 1) Materialize curated fixtures (once per catalog revision)
./bin/mix arbor.coding.benchmark.prepare \
  --catalog benchmarks/coding/catalog-v1.json \
  --output tmp/coding-benchmark-prepared

# 2) Run the harness against the prepared root (trusted adapters via config)
./bin/mix arbor.coding.benchmark \
  --manifest tmp/coding-benchmark-prepared/manifest.json \
  --acp-agent grok \
  --output reports/coding-benchmark.json
```

Trusted adapter callbacks still come only from Application /
`execute/2` configuration (`:coding_benchmark_adapters`). Do **not** configure
`:coding_benchmark_verifiers` for `exact_target_tree` on prepared publications
— that reserved selector is installed from validated evidence only.

## Review requirements

When editing the catalog:

1. Prefer real history transitions already present in the source repository.
2. Compute tree OIDs with `git rev-parse <commit>^{tree}`; never invent OIDs.
3. Keep the catalog schema closed — no unknown fields, no commands, no module
   names.
4. Re-run pure catalog tests and prepare integration tests after changes.
5. Do not check in prepared nested `.git` fixtures.

The `exact_target_tree` selector measures reproduction of the reviewed
canonical patch, not equivalence of every behaviorally valid implementation.

## Current run status

The host containment and dependency-baseline gate is cleared. The catalog,
materializer, and built-in objective verifier make curated inputs
**reproducible, reviewable, and objectively scorable**. The remaining work is
to install the trusted benchmark roots, adapters, principal, and timeouts in the
running node, execute the prepared legacy/pipeline pairs, and retain the report;
these files do not by themselves constitute a completed scoreboard run.
