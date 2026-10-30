# Standalone safety-support consumer

This consumer calls the actual `Arbor.Common.SafePath`, `SafeAtom`,
`SensitiveData`, and `Arbor.Common.Pagination.Cursor` public APIs from
`arbor_support`. It has no Arbor product or
Kernel Runtime dependency. Starting the support package starts no callback,
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
compiled/loaded/started first-party closure stays exactly Support.

Cold qualification builds a real Hex archive containing source and C inputs,
validates its checksums, exact members and metadata, and compiles the unpacked
package and consumer strictly with only a private Boundary source checkout.
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
  --deps-source-cache /absolute/source-cache
```

The pinned `cc` must be the compiler selected by the runner's explicit PATH.
The source cache needs only the unchanged locked Boundary checkout; compiled
inputs are refused. The runner requires clean reviewed Main and candidate
states, creates a fresh private evidence directory and stops on failure. It
never fetches, publishes, changes source checkouts, edits operator homes, or
removes retained evidence. Standard output/error and their hashes are retained
separately for each build and executable probe.
