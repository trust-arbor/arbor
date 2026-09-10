# Morning digest migration: source packet S0

The morning digest graph now invokes `reports.build_morning_digest`, a bounded
local Jido action. It reads only the two named report topics and publishes one
digest for the UTC date at execution. It does not invoke a shell, provider or
external service. The existing version 1 capability file remains unchanged and
rejected. This source change does not activate the configured cron entry.

The review artifact is
`apps/arbor_scheduler/priv/migrations/morning_digest_v2_unsigned.json`. It is not
a loadable capability manifest. It pins the exact new DOT SHA-256, logical root,
relative path and initial arguments. `workdir` and `issuer_id` are deliberately
unresolved. No signing, issuer enrollment, grant, key change or live run occurs
in this packet.

The deployment must select an existing canonical data directory containing
`reports/upstream-deps`, `reports/upstream-deps-summary` and
`reports/morning-digest`. The action creates no directories. The issuer review
must cover the action URI and the three exact absolute filesystem scopes formed
from those relative paths. The write scope covers the digest and its exclusive
temporary file in that same directory. The runner's existing orchestrator lobby
capability is additional traversal authority, not permission to read or write.
The old morning-digest manifest declares no capabilities; copying that empty
list into a version 2 manifest cannot authorize the new action.

The authenticated action principal is required even on direct calls. Each read,
the temporary-file creation, and destination publication pass the existing
filesystem authorization boundary. Paths stay beneath the attested workdir;
canonical parents are checked and symlink/non-regular targets are rejected.
Missing files are reported explicitly after authorization. Inputs are limited
to 256 KiB each and must be UTF-8; output has a 1 MiB ceiling. No arbitrary topic,
directory, date, executable or command parameter is accepted.

Publication opens a fresh same-directory file exclusively, writes and syncs its
contents, then renames it over the checked destination. Success acknowledges
that rename. This is atomic publication on the supported local filesystem, not
directory-fsync durability. It does not provide descriptor-bound protection from
concurrent attacker-controlled directory replacement, a bounded filesystem
latency guarantee, or caller-death rollback. A killed writer can leave an
unpublished temporary file; readers select only the dated `.md` inputs. The
old script remains an unsupported reference and is no longer a graph target.

`Orchestrator.classify_run_result/1` gives lower-level callers a public, pure
classification of typed Engine outcomes. Scheduler admits only `:success`.
`:partial_success`, `:retry`, `:fail` and `:skipped` become explicit discarded
pipeline outcomes; malformed results are discarded as `:invalid_run_result`.
Ordinary infrastructure errors retain their existing retry behavior. No arbitrary
`{:ok, map}` establishes completion.

S1/S2 remain independent work: authenticated owner-bound enqueue/list/cancel,
closed signed job intent, current capability/policy intersection and revocation
at delayed execution, and cancellation acknowledgement. S0 does not claim that
the current issuer-minted run identity is restricted by a scheduling owner.

Validation is through temporary-root public Actions tests, provider-free real
`run_file_as` tests using the exact reference graph, pure outcome-classifier
tests, and the existing signed version 2 runner fixture with explicit failed
outcomes. The retired script smoke test no longer touches `~/.arbor/reports`.
