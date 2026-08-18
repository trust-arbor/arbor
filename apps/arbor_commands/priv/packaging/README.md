# Packaging baselines

## `source_coupling_baseline.v1.json`

Reviewed K5 post-materialization source-coupling baseline, generated from the
Git-tracked umbrella worktree and committed separately as `59a5c8f9f`. The
authoritative source identity is the baseline's own `provenance.tree_oid`
(`2d867fe0ac0f295f31e6d483196ba5119155c11e`), the Git **tree** object id of
the scanned source (distinct from, and not equal to, the commit SHA). Every
undeclared cross-app occurrence present at that scan is captured in `entries`,
and every unresolved (dynamic-module) reference is captured in
`unresolved_entries` with a reviewed disposition and rationale. Baseline drift
- a new undeclared occurrence, a changed count, or a new unexplained unresolved
reference - is a normal quality-gate failure, not an exception to work around.

The K4 package split changes how the direct-application census should be read.
Consumers of active Common, Signals, or Monitor surfaces declare exactly one K
edge to `:arbor_kernel_runtime`; they receive passive `:arbor_kernel`
transitively and deliberately do not declare both applications. The scanner
continues to grade direct application declarations, so 4,040 of the refreshed
baseline's 4,228 undeclared occurrences are downward references to passive
kernel modules through that package relationship. This is not new upward debt.
The physical merge removes all six formerly undeclared K-to-K occurrences,
while production upward findings fall from 57 occurrences in 46 aggregates to
35 occurrences in 24 aggregates. A semantic comparison by source module,
target, kind, and class found zero new upward findings. Eight dynamic references
have explicit dispositions: three bounded registries/generators and five
analyzer or submitted-code false positives.

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

## App-env zero-residue gate

Git-index AST census of retired `:arbor_contracts`, `:arbor_common`,
`:arbor_signals`, and `:arbor_monitor` application-env callers.

The root `quality` alias runs check mode, so `./bin/mix quality` fails while
any indexed residue remains:

```bash
./bin/mix arbor.packaging.app_env_inventory --check
./bin/mix arbor.packaging.app_env_inventory --check --json
```

`--check` never writes. It exits nonzero unless the stage-0 Git blob census
is clean (`production=0 test_support=0 config_block=0 untrusted=0 total=0`)
with verified tree/object provenance. Report mode prints the same census and
exits successfully even if residue is present.

```bash
./bin/mix arbor.packaging.app_env_inventory
./bin/mix arbor.packaging.app_env_inventory --json
```

Grep is supplemental only. K3 mechanical formatting expansion and K4
directory retirement are out of scope for this gate.

## K3B startup-footprint probe

Isolated measurement of the reversible Common / Signals / Monitor merge
proposal. Scenario execution lives in the compiled Commands-owned peer
probe. The accepted decision and regression budgets are checked in as
`startup_footprint_policy.v1.json`.

Not installed in the root `quality` alias. The exact commands are:

```bash
./bin/mix arbor.packaging.startup_footprint
./bin/mix arbor.packaging.startup_footprint --json
./bin/mix arbor.packaging.startup_footprint --check --json
```

Each run measures baseline, proposed-gated, and proposed-eager in three
fresh OS-level BEAM instances controlled by OTP `:peer` over
`standard_io`. Each peer invokes only the fixed Commands-owned probe MFA.
The current pinned Erlang executable and a validated current code path
are the only runtime inputs. There is no nested Mix compile, dependency
cache copy, mise lookup, or temporary probe project.
Baseline starts only passive `arbor_kernel` so eager-start owner
callbacks remain a visible regression. Proposed scenarios start the merged
app's non-owner runtime extras, including `:os_mon`, and load
scenario-specific applications inside the timed action. Retired owner
names, the synthetic proposed owner, and `:arbor_kernel` are excluded
from external runtime evidence.
Comparison uses numeric regression budgets, not byte-identical runtime
samples. Non-empty raw measurement errors and omitted app lists fail closed.
Elapsed time is `boot_time_us` (converted from monotonic native units).
Process and table counts are monotonic for this protocol, so a negative delta
is retained as an error. ETS and BEAM memory are non-monotonic gauges; a
decrease caused by garbage collection is a valid zero positive-footprint
delta, not a measurement error.

Five sequential manager-owned runs on 2026-08-14 produced these ranges:

| Scenario | Processes | Children | ETS tables | ETS words | BEAM bytes | Boot us | Logger / telemetry |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 3 | 0 | 0 | 3,827 | 0 | 6,777-8,576 | 0 / 0 |
| proposed-gated | 55 | 0 | 12 | 45,493 | 2,914,534-2,948,990 | 41,733-48,394 | 0 / 0 |
| proposed-eager | 95 | 29 | 35 | 91,013 | 6,567,698-6,704,058 | 89,394-98,312 | 1 / 1 |

The accepted reversible choice was `split_passive_protocols`. Nested child
gates suppress active services and callbacks, but the single-application
proposal still widened a contracts-only consumer from 3 to 18 started runtime
applications and added 52 processes. K4 therefore preserved passive
protocol/schema ownership behind `:arbor_kernel` and placed active Common,
Signals, and Monitor services in separately started `:arbor_kernel_runtime`.
Regression ceilings keep structural invariants tight while giving memory and
boot-time measurements bounded CI headroom. Generated probe output is never
committed.

K5 repeated five sequential measurements against the materialized applications.
The historical scenario names remain stable for report compatibility;
`proposed_gated` now means the explicit runtime application with optional
children disabled.

| Scenario | Processes | Children | ETS tables | ETS words | BEAM bytes | Boot us | Logger / telemetry |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 3 | 0 | 0 | 3,038 | 0 | 6,040-6,783 | 0 / 0 |
| proposed-gated | 63 | 4 | 15 | 70,658 | 3,711,488-4,575,624 | 50,152-52,479 | 1 / 0 |
| proposed-eager | 95 | 29 | 35 | 91,749-92,020 | 6,520,194-7,763,044 | 84,697-88,802 | 1 / 1 |

The gated runtime's four children are structural: three empty nested subsystem
supervisors plus the OAuth HTTP pool. Common installs its redaction filter when
the runtime starts, while the optional service children and Signals telemetry
bridge remain disabled. These exact values do not weaken passive isolation:
contracts-only consumers start `:arbor_kernel`, not the runtime application.

## Safe-recovery profile evidence (E0B1)

Reviewed `safe_recovery` profile intent. Production reads only the fixed
candidate `safe_recovery_profile.v1.json` through a repo-contained,
non-symlink, ceiling-bounded file boundary. There is no caller-selected
profile name, path, MFA, executable, or decoder.

The root `quality` alias runs check mode:

```bash
./bin/mix arbor.packaging.safe_recovery_profile --check
./bin/mix arbor.packaging.safe_recovery_profile --check --json
```

`--check` never writes. It exits successfully only after the exact fixed
candidate is admitted. `evidence_status=conformant` with
`architecture_status=blocked` is a successful E0B1 evidence check, not
architecture readiness. The frozen blocker set remaining exact is what
check verifies; it does not promote the architecture to ready.

```bash
./bin/mix arbor.packaging.safe_recovery_profile
./bin/mix arbor.packaging.safe_recovery_profile --json
```

Report mode prints the same admitted evidence. Missing, malformed, stale,
widened, reordered, or unreadable candidates fail closed in both modes.

The `profile_digest` is the lowercase 64-hex SHA-256 of the
domain-separated canonical profile bytes. It is computed after admission
and is not stored on the candidate. Two consecutive `--json` renders must
be byte-identical and bind the same digest.

E0B1 is profile-intent evidence only. E0B2 binds exact artifact payload
identity; E0B3 measures fresh-VM executable closure. This command does
not implement either, and a passing E0B1 check is not an E0B2 or E0B3
result.

## Safe-recovery artifact evidence (E0B2C3c1)

Committed two-build artifact evidence for the C3c0 child-project build.
Exactly two committed paths carry it, and both are excluded from
SourcePolicy selection so the artifact never becomes an input to its own
build:

- `apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json` —
  a closed bounded envelope (schema
  `arbor.packaging.safe_recovery_artifact.envelope.v1`) holding only the
  payload file's schema, path, byte size, and plain SHA-256. It is a
  descriptor plus digest, never a second unsigned payload.
- `apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json` —
  the canonical `arbor.packaging.safe_recovery_artifact.payload.v1`
  manifest produced by the production two-build compose
  (`Arbor.Commands.SafeRecoveryArtifact.compose/1`).

The closed CLI (a thin Mix surface over the public facade, never a second
builder) exposes four mutually exclusive modes:

```bash
./bin/mix arbor.packaging.safe_recovery_artifact            # report
./bin/mix arbor.packaging.safe_recovery_artifact --check
./bin/mix arbor.packaging.safe_recovery_artifact --build-verify
./bin/mix arbor.packaging.safe_recovery_artifact --write
```

- **report** reads and admits only the two committed files (envelope
  binding plus full payload validation). It never writes and never nests
  a trusted-build.
- **check** is the cheap, complete gate: report admission, a required
  `identical` two-build reproducibility result, the frozen lock
  cross-bindings, and an exact digest binding of EVERY fixed
  first-party/config/build input consumed by the C3c0 child-project build —
  every SourcePolicy-selected HEAD blob (the five child applications'
  sources plus the required config/build files, including `mix.lock`,
  `.tool-versions`, `bin/mix`, `config/*`, and
  `build_support/mix_project_paths.exs`) plus the pinned sqlite_vec native
  overlay. Nothing is downgraded to build-verify-only evidence: a missing,
  extra, or digest-mismatched input fails check.
  `architecture_status=blocked` passes check only because the recomputed
  findings equal the unchanged reviewed blocker set; evidence
  incompleteness or a reproducibility mismatch fails check rather than
  being relabeled architecture debt. Check never compiles, never writes,
  and never nests a trusted-build.
- **build-verify** is the expensive manager-owned mode: it composes a
  fresh production two-build via the public facade and requires the fresh
  evidence to equal the committed evidence (only the Git provenance
  pointers `source.commit`/`source.tree` are excluded from comparison).
  It never writes and is never run by the root quality alias.
- **write** is the only mutator, manager-owned: it composes a fresh
  two-build, requires `identical` reproducibility, and creates or replaces
  exactly the two committed paths above — payload first, then envelope,
  then a full readback admission. There is no caller-selected destination,
  executable, MFA, digest, sandbox rule, or hook anywhere on the surface;
  every other destination, symlinked destination, symlinked parent, or
  extra path fails closed.

The root `quality` alias runs only the cheap check:

```bash
./bin/mix arbor.packaging.safe_recovery_artifact --check
```

`--build-verify` and `--write` are never invoked by quality; quality never
composes and never nests a release build.

The committed artifact pair landed on 2026-08-17 (`b1ed199a2`) after
a live `--write` / `--build-verify` produced identical two-build
payloads from `fe0ed0a9d`. `--check` now admits those files. It is
still not an E0B3 result.

E0B3 (ephemeral `RELEASE_COOKIE` and fresh-VM executable closure) is a
separate proof from the artifact pair.

```bash
./bin/mix arbor.packaging.safe_recovery_closure
./bin/mix arbor.packaging.safe_recovery_closure --check
./bin/mix arbor.packaging.safe_recovery_closure --check --json
```

Report and check read only
`apps/arbor_commands/priv/packaging/safe_recovery_closure.v1.json`.
They never start a peer, inject a cookie, or compose a release. Check
admits the committed document; a reviewed blocked-open finding set is
not a check failure. `architecture_status=blocked` is not architecture
readiness. The root `quality` alias runs only the cheap check.

A live `--write` on 2026-08-17 from `217da8713` produced
`closure_status=open` with digest
`9af47b51246c98173cc66c7059399c40cabbf7366546501c47bf8f7a9fe3c9d1`.
Selected `arbor_security` / `arbor_trust` failed to start in the fresh
VM (`security_sync_subscription_failed`); third-party and forbidden
facility growth is recorded.

A live `--write` on 2026-08-18 from `dbec397bc` produced
`closure_status=open` with digest
`27b9b4db7150f4a1128618980d12b7660489e1c58455ee2d3ba19229279e20ac`
and 117 findings. Selected `arbor_kernel`, `arbor_kernel_runtime`,
`arbor_security`, and `arbor_trust` started. `arbor_persistence`
started as unexpected first-party. Remaining blockers are
`os_mon`, the postgres/sqlite/vector stack, third-party starts, and
unexplained modules. There is no `selected_start_failed` finding.

`--measure` and `--write` are manager-owned. They stage one trusted
source lease, run one `arbor_trust` trusted-build, remove
`releases/COOKIE`, pin the lease-owned `rel/arbor_trust` directory,
inject a process-private `RELEASE_COOKIE`, probe in a fresh OTP
`:peer` over `standard_io`, then always release the lease. Production
does not accept a caller-selected executable, cookie, MFA, or artifact
path. `--write` publishes exactly
`apps/arbor_commands/priv/packaging/safe_recovery_closure.v1.json`.
A passing artifact `--check` is not an E0B3 result.

## Retired K migration gates

The PK-K0 migration census and K4 materialization plan were one-time proof
machinery, not permanent architecture guards. K4's final materialized check was
repeated during K5 on the exact K4 tree plus the post-move root-discovery fix. It
admitted plan digest
`5a2cedf23de88acfbf2591f69b3f1e6b41853030efd33adc633cf4c09383469b`
with 640 source entries, 568 exact moves, 72 transform inputs, four collision
destinations, and zero failures.

K5 removed both Mix tasks, their implementation modules, frozen manifests, and
tests. The materialization evidence binds destination blob IDs, so retaining it
would reject every legitimate edit to a moved file after the migration. The K0
gate likewise describes pre-migration paths and dispositions that no longer
exist. Their accepted history remains recoverable from the K0 through K4 commits
and the packaging roadmap; do not regenerate those artifacts against later
trees.

The durable post-migration controls remain active:

- source-coupling baseline and drift detection;
- app-env zero-residue detection for the four retired application keys;
- startup-footprint regression budgets;
- machine-checked dependency hierarchy and strict Boundary declarations; and
- warning-strict compilation, xref, release, and package test evidence.
