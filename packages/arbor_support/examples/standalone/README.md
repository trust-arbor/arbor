# Standalone safety-support consumer

This consumer calls the actual `Arbor.Common.SafePath`, `SafeAtom`,
`SensitiveData`, `PromptSanitizer`, `Sanitizers.PromptInjection`,
`SensitivityClassifier` and `Arbor.Common.Pagination.Cursor` public APIs from
`arbor_support`, together with their canonical passive Kernel contracts.
It has no Arbor product or Kernel Runtime dependency. Starting the support package starts no callback,
registered role, HTTP provider, or authority owner.

`SupportStandaloneConsumer.verify!/1` performs descriptor-backed regular-file
reads, validates before data is read, refuses validator denial, rejects escape
and exact-leaf symlinks, and rejects a replaced bound root. Replacing a root or
ancestor after the file descriptor has opened must retain the original safe
bytes. It observes its exact caller-owned native Port while the validator runs
and proves that the helper's executable and directory are already unlinked.
The embedded artifact belongs to `arbor_support`; no executable deputy exists
in `ebin`. Production artifacts expose no test-only race hooks.

The same public fixture checks existing/allowed atom conversion without
creating attacker-selected atoms, known-key map projection, secret and PII
redaction, entropy, and Luhn signatures. Its report contains only check names,
counts, module ownership and artifact/code-path hashes; synthetic data and
file content are not returned.

Seven Cursor acceptance groups run in both the unpacked consumer and the
source-hidden ERTS release. They prove unchanged `timestamp_ms:id` encoding
from integer/DateTime inputs, IDs containing colons, parsing round trips,
millisecond/microsecond precision, strict ascending/descending timestamp and
equal-time ID predicates, stable input order, and nil-cursor passthrough.
Malformed encoded cursor strings fail closed to empty results in both filter
APIs. The fixture exercises the current binary-input DateTime parser contract;
it does not claim a new total API for arbitrary nonbinary DateTime input.
The actual Cursor BEAM must belong to `arbor_support`; the higher-level
`Arbor.Common.Pagination` module and Kernel Runtime remain unavailable, and
compiled/loaded/started first-party closure stays exactly Kernel and Support.
Support's only first-party dependency is Kernel; Kernel has no first-party
backedge. Both applications remain passive. The canonical sanitizer and taint
contracts and `Arbor.Eval.Subject` belong to Kernel; the moved prompt and
sensitivity helpers belong to Support. Three additional public acceptance
groups exercise nonce-tagged prompt handling, existing injection refusal and
taint identity, and deterministic sensitivity classification without changing
those mechanisms.

Cold qualification builds two real Hex archives: `arbor_kernel` at
`2.0.0-dev` and `arbor_support` at `0.1.0-dev`. It validates each archive's
checksums, exact published members and public dependency metadata, then compiles
the unpacked packages and consumer strictly with private Boundary, Jason and
TypedStruct source checkouts. The exact three reviewed Root lock records are
used by the consumer and seeded exclusively into each private producer and
unpacked project. These locks are private qualification inputs, not additions
to either published archive. Later guards reject changed, missing, symlinked,
hardlinked or ambiguous locks, including after source hiding.
The C compiler generates a new embedded artifact in a fresh private build.
An assembled ERTS release repeats the operations with Mix absent and all code
paths inside the release after only copied qualification sources/tools are
hidden. No prebuilt application, native artifact or dependency cache is seeded.

Run `python3 packages/arbor_support/scripts/qualify_standalone.py --help` for
all inputs. The script lives with the source checkout and stays outside the
Hex payload. Supply absolute pinned tool/source paths and full reviewed commit
IDs, for example from an isolated worktree:

```sh
python3 packages/arbor_support/scripts/qualify_standalone.py \
  --repository /absolute/candidate --main-root /absolute/main \
  --head FULL_CANDIDATE_COMMIT --main-head FULL_MAIN_COMMIT --branch REVIEWED_BRANCH \
  --work-dir /absolute/evidence/FRESH_LABEL \
  --mix /absolute/candidate/bin/mix \
  --erlang-root /absolute/pinned/erlang --elixir-root /absolute/pinned/elixir \
  --hex-archive /absolute/pinned/hex-archive --cc /usr/bin/cc \
  --sdk-root /absolute/pinned/SDK --developer-dir /absolute/pinned/developer \
  --deps-source-cache /absolute/source-cache
```

The pinned `cc` must be the compiler selected by the runner's explicit PATH.
The source cache needs the unchanged locked Boundary, Jason and TypedStruct
checkouts; compiled inputs are refused. `ARBOR_KERNEL_PATH` and
`ARBOR_SUPPORT_PATH` select only the verified unpacked archives for compilation.
Both overrides are absent during archive publication metadata generation. The runner requires clean reviewed Main and candidate
states, creates a fresh private evidence directory and stops on failure. It
never fetches, publishes, changes source checkouts, edits operator homes, or
removes retained evidence. Standard output/error and their hashes are retained
separately for each build and executable probe.

The runner passes the explicit SDK and developer roots as `SDKROOT` and
`DEVELOPER_DIR` through its closed environment and records those effective
values in the input manifest. For this family, the enclosing qualification
must first prove the pinned compiler, effective include search, critical SDK
headers/libraries and a fresh compile/link/execute preflight. Recording the
environment is not a standalone SDK qualification. The existing fresh Support
native compilation, embedded source/binary hashes and real descriptor/Port
execution remain required in both the ordinary and source-hidden release checks.

The previous Support and Cursor adoption maps and receipts remain historical.
New family receipts must bind this two-archive fixture and its public lock and
SDK inputs; earlier single-package evidence is not silently reinterpreted.
