# Paired Trust/Historian cold qualification

Each acceptance attempt requires reviewed sources, an immutable candidate and
retained preparation/build/runtime receipts. This document defines the required
gates; qualification status belongs to the receipts for that specific attempt.

`qualify_paired.py` and local `cold_support.py` are self-contained stdlib code.
The runner pins its archive/source/operator guard helpers and copies only public source
files from the pinned read-only cache, creates real Hex archives with exact
metadata/member/source-hash checks, and builds three independent consumers with
fresh private deps/build/runtime paths. No shared warm output or first-party BEAM
is seeded. SQL forces compilation of Exqlite's pinned bundled sqlite3.c with the
pinned C compiler and make; no system SQLite or precompiled download fallback.

Trust needs seven canonical apps and 13 public prod sources; Historian four and
four; composed nine and 22. Optional OIDC and test-only dependencies stay absent.
Every unpacked package and consumer is compiled strictly. Consumer configuration
is explicitly loaded for strict SQL compilation so SQLite's compile-time Repo
selection matches the ordinary public consumer. Public operations run before
release assembly. After all releases exist, only owned producer/tool/source
copies are moved to source-hidden directories; ERTS releases repeat probes with
Mix absent, non-distribution and one launcher cookie. Operator HOME is never
changed. Logs are separate, private and retained; first failure holds with no
retry, fetch, repair or evidence deletion.

Canonical fixture locations are closed and explicit:

| Context | Source under `--fixtures-root` |
| --- | --- |
| Trust leaf | `packages/arbor_trust/examples/standalone` |
| Historian leaf | `packages/arbor_historian/examples/standalone` |
| Composed | `examples/trust_historian` |

`--fixtures-root` is the same reviewed repository root supplied to `--repository`.
The Python modules and fixed native probe live at
`packages/arbor_trust/scripts/{qualify_paired.py,cold_support.py,native_header_link_probe.c}`.
The runner hashes these inputs and each context's actual source files, resolves only the
three constants above, rejects source symlinks, and guards original/copy bytes
before and after commands. No Historian consumer copy belongs below Trust.
The per-attempt input manifest must bind the exact canonical source paths and
SHA-256 digests before any compilation or runtime gate.

Main's ignored build uses `--main-build-policy strict` by default. That policy
retains the original `build_metadata` fingerprint and refuses any recorded
metadata change. A fresh, reviewed attempt may explicitly select
`--main-build-policy reviewed-boundary-view-v2` at preparation. The choice is
pinned in the arguments, input manifest and initial snapshot; `--run` refuses a
different choice before starting the attempt. There is no environment override
or arbitrary path list. Existing strict HOLD receipts keep their original meaning.

The reviewed policy classifies only these seven existing operational cache files
under Main's `_build`:

```text
dev/lib/arbor_support/.mix/compile.boundary_view_v2
dev/lib/arbor_kernel/.mix/compile.boundary_view_v2
dev/lib/arbor_signals/.mix/compile.boundary_view_v2
dev/lib/arbor_oauth/.mix/compile.boundary_view_v2
dev/lib/arbor_capabilities_oidc/.mix/compile.boundary_view_v2
dev/lib/arbor_capabilities/.mix/compile.boundary_view_v2
dev/lib/arbor_capabilities_signals/.mix/compile.boundary_view_v2
```

Only their content, `mtime` and `ctime` may differ. Each must remain the same
single-link regular file with unchanged device, inode, type, mode, owner, group,
size and link count. The root and its ancestors must be canonical directories;
cache symlinks, hard links, missing files, replacement files and changing reads
refuse the snapshot. All other build entries and directory metadata remain strict,
including BEAMs, app metadata, native libraries, resources and other manifests.
These seven Main caches are never inputs to private qualification builds. This
classification is limited to the reviewed Boundary writer and complete seven-file
delta identified during the earlier attempts; it grants no credit to those attempts.

Every labeled run guard retains an exclusive `main-build-guards/NNNN.json`
receipt with the immutable preparation snapshot, current snapshot, accepted flag,
reasons and full before/after SHA-256 and stat records for all seven caches under
the reviewed policy. It writes the receipt before checking acceptance, including
when another build entry changed. If a safe snapshot cannot be captured, the
receipt retains all initial records and records unavailable current evidence and
the capture error; the guard refuses without following an unsafe replacement.
`results.json` pins each receipt's path and hash. Comparisons always use the
original preparation snapshot. Main/candidate Git, index, stash, dotenv,
operator, tools, archives, sources and private runtime gates remain separate and
unchanged. The policy adds no retry, rebase, pacing change or weaker workload.

The native lane requires explicit `--sdk-root` (the pinned `MacOSX27.0.sdk`)
and `--developer-dir` inputs. Preparation records the SDK settings, critical C
headers and libSystem linker-stub hashes, plus the exact harmless C probe source.
Each guard rechecks these inputs. Before the first Hex/package or dependency
compilation, the runner directly compiles, links and executes the fixed
header-only `return 0` probe with the pinned compiler, explicit `SDKROOT` and
`DEVELOPER_DIR`. Both logs and the binary/source/SDK digests are retained. This
uses the same bounded preflight method as the actual predecessor producer;
it does not claim to fingerprint every transitive system header or native SDK
input. The compiler directory is placed on the private command PATH so Support's
`cc` lookup resolves to the same explicit compiler pin. There is no global
compiler configuration, retry, build seed, system SQLite or precompiled fallback.

The runnable invocation requires absolute pins for every tool/input, a fresh
attempt label, exact committed candidate and Main heads, initial-manifest SHA,
and the reviewed actual predecessor driver manifest. Run `--prepare`, review its
source-manifest.json, then invoke the identical arguments with `--run`. Neither
mode may overwrite an existing/running/failed attempt. Example argument shape:

```sh
python3 /absolute/clean-candidate/packages/arbor_trust/scripts/qualify_paired.py --prepare \
  --repository /absolute/clean-candidate --head FULL_CANDIDATE_SHA \
  --branch codex/adopt-trust-historian --main-root /absolute/arbor \
  --main-head fafa2689158f29f6aa20ccc03ad8b41052a900b6 \
  --work-dir /absolute/ignored/fresh-cold-label --fixtures-root /absolute/clean-candidate \
  --initial-manifest /absolute/initial-manifest.json --initial-manifest-sha256 SHA256 \
  --deps-source-cache /absolute/read-only/deps --mix /absolute/pinned/bin/mix \
  --erlang-root /absolute/pinned/erlang --elixir-root /absolute/pinned/elixir \
  --hex-archive /absolute/pinned/hex-VERSION --cc /absolute/pinned/cc \
  --make /absolute/pinned/make --rebar3 /absolute/pinned/rebar3 \
  --sdk-root /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk \
  --developer-dir /Library/Developer/CommandLineTools \
  --rollback-manifest /absolute/reviewed-predecessor-driver.json
```

Rollback uses actual fafa PROD code, with its original source and build provenance.
Its schema `arbor.trust-historian.rollback.v1` binds full head/tree/source/PROD
BEAM/driver/fixed-config hashes, clean predecessor checkout, absolute cwd and
fixed argv, and explicit `prod_compiled: true` / `driver_compiled: true` sealing.
Producer metadata or an uncompiled driver cannot satisfy this gate. The coordinator appends only `--state-root OWNED_COPY --phase verify`.
The driver must output exactly one `PAIRED_ROLLBACK_RESULT=` JSON object with true
same_authority, same_profiles, same_audit_receipts, revoked_authority_refused,
production_owners_proven and quiescent, plus exact head=fafa2689158f29f6aa20ccc03ad8b41052a900b6
and mix_available=false. Before copying the entire private state, the runner
requires prior VMs to have exited, journal pending count zero and a completed
SQL WAL checkpoint. The candidate ERTS release must then reopen the exact predecessor-touched
copy and repeat its refusal/receipt checks. Missing manifest/proof means HOLD.

Acceptance requires the 2300-pair retirement workload, independent conflict and
namespace-only attack branches, actual predecessor rollback, source/API review,
strict compilation, runtime receipts and complete-slice Grok review. These
consumer gates provide no M2 product-release, power-loss or distributed Trust
qualification.

The long retirement callback retains one real persistent `:session` authority
inside its live supervised provisioner. In current production code, public open
finalizes and acknowledges the acquisition request; that expiring request is
removed. The live authority entry is owner-monitored and has no TTL. Each use
still checks owner liveness, principal/purpose and active identity. Owner death
removes it. No refresh, extended expiry, serialized handle or changed broker
setting is needed. The per-attempt source manifest must bind the exact production bytes;
if future semantics add expiry, qualification must reacquire through the public
owner protocol and revalidate, rather than relax that expiry.
