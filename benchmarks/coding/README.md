# Coding benchmark catalog (v1)

This directory holds a **tracked, data-only** catalog of pinned Arbor-history
coding tasks for the Phase 6 legacy-vs-pipeline conformance harness.

It does **not** run that benchmark. Real paired execution still depends on an
externally provisioned Apple/Linux validation baseline and trusted adapter
runtime configuration.

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
  base/target OIDs and normalized input hashes for a **future trusted objective
  verifier**. It is not
  worker-visible answer material, does not select modules or commands, and is
  not yet configured as executable verification.
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
- `verifier_id` values (for example `exact_target_tree`) are **data selectors**
  for a future runtime verifier registry. Catalog data cannot name MFA
  callbacks.

## Review requirements

When editing the catalog:

1. Prefer real history transitions already present in the source repository.
2. Compute tree OIDs with `git rev-parse <commit>^{tree}`; never invent OIDs.
3. Keep the catalog schema closed — no unknown fields, no commands, no module
   names.
4. Re-run pure catalog tests and prepare integration tests after changes.
5. Do not check in prepared nested `.git` fixtures.

The current `exact_target_tree` selector measures reproduction of the reviewed
canonical patch, not equivalence of every behaviorally valid implementation.

## Current external execution blocker

The production coding-benchmark path still requires host Apple/Linux
containment and validation baselines that may be unprovisioned. This catalog
and materializer only make curated inputs **reproducible and reviewable**;
they do not claim a completed legacy-vs-pipeline scoreboard run.
