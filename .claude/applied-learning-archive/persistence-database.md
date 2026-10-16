# Applied Learning archive: persistence-database

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: durable-inventory-scans-must-not-run-inside-journal-owner-critical-sections -->
<a id="applied-learning-durable-inventory-scans-must-not-run-inside-journal-owner-critical-sections"></a>
**Durable inventory scans must not run inside journal-owner critical sections.**
Full list/fetch/decode scans grow with history and can exceed ordinary GenServer
call timeouts, starving effect-receipt writes and turning successful execution
into `:journal_unavailable`. Collect and validate in a bounded worker, keep the
owner responsive, then apply conflict-safely against a hot-state snapshot so
concurrent durable-first writes win; regress both responsiveness and stale
overwrite (found 2026-08-26 when a 29,034-row RunJournal refresh took about 5.8
seconds and terminalized P1B-2A).

<!-- applied-learning: a-durable-store-and-its-json-mirror-can-preserve-different-scalar-representations -->
<a id="applied-learning-a-durable-store-and-its-json-mirror-can-preserve-different-scalar-representations"></a>
**A durable store and its JSON mirror can preserve different scalar representations.** Arbor's checkpoint store keeps known outcome-status atoms while `checkpoint.json` encodes them as strings; recursively normalizing map keys does not normalize scalar values. Decode closed enums from both trusted atom and JSON string forms, fail closed on unknown values, and regress both store-backed resume and file round-trips so one path cannot silently turn `:fail` into `:success` (found 2026-07-16 exposing validation failures after terminal recovery).

For atom-keyed settings APIs, accept persisted string keys without creating atoms,
and remove both key forms on update/delete. Test a real cold-store reload:
the live cache can hide unreadable reverse indexes and duplicate JSON keys
(found 2026-09-28 when identity resolution survived restart but alias listing
reported no linked identities).

Normalize producer-owned closed enum values before a strict durable JSON
boundary; key normalization alone does not convert atom values. Preserve the
codec's rejection of arbitrary non-JSON values. On 2026-10-04, real protected
conversation denial reached its public answer path but failed before commit:
the producer emitted `decision: :deny`, and the durable codec correctly rejected
that atom. Cover deny and rework independently, including recovered human,
resource and decision evidence; an approved positive uses different metadata
and cannot prove rejection persistence.

<!-- applied-learning: treat-default-struct-fields-as-receipt-schema-changes -->
<a id="applied-learning-treat-default-struct-fields-as-receipt-schema-changes"></a>
**Treat default struct fields as receipt schema changes.** When receipts hash
a struct using deterministic Erlang external term format, adding an empty
default field changes the digest even if its JSON representation is additive.
Preserve each owner's accepted digest schema; normalize only the exact legacy
default where compatibility requires it, while hashing every nonempty or
malformed value. Prove recovery with independently retained signed checkpoints
and actual predecessor receipts, plus changed-evidence rejection. Do not copy
one owner's normalization into another whose current schema already includes
the field (found 2026-10-06 while backporting Workflow input taint into Main).

<!-- applied-learning: a-distributed-test-must-restore-the-controller-s-original-distribution-state -->
<a id="applied-learning-a-distributed-test-must-restore-the-controller-s-original-distribution-state"></a>
**A distributed test must restore the controller's original distribution state.** `LocalCluster.start/0` can turn the test runner into a named distributed node; leaving that state behind changes `node()` and makes later local-only claim tests fail as cross-node operations. Record whether the suite started distribution, stop every member, and stop LocalCluster/net_kernel only when the suite owns that transition (found 2026-07-15 composing the L4 proof with the fenced-claim suite).

<!-- applied-learning: a-public-resume-must-claim-and-mutate-the-same-canonical-journal-target -->
<a id="applied-learning-a-public-resume-must-claim-and-mutate-the-same-canonical-journal-target"></a>
**A public resume must claim and mutate the same canonical journal target.** Sanitizing alternate-journal lookup is insufficient if caller-provided `journal_opts` or `server` values still reach Engine after the default record is claimed. Remove internal journal-target selectors at the public boundary and regress that an alternate target remains untouched (found 2026-07-15 reviewing Engine lifecycle L3C public settlement).

<!-- applied-learning: durable-evidence-limits-must-be-symmetric-on-write-and-reload-and-a-cache-must-detect-backing-store-drift -->
<a id="applied-learning-durable-evidence-limits-must-be-symmetric-on-write-and-reload-and-a-cache-must-detect-backing-store-drift"></a>
**Durable evidence limits must be symmetric on write and reload, and a cache must detect backing-store drift.** A journal that enforces aggregate bytes or exact inventory only at startup can accept writes that poison its next restart; a cache-only `list` can also hide added, deleted, or corrupted evidence from a fail-closed allocation probe. Bind a bounded on-disk snapshot (exact names, raw sizes/digests, root identity), revalidate it before security decisions and mutations, and apply the same capacity math to replacement writes and hydration (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: identifiers-used-as-durable-filenames-need-one-canonical-case-stable-grammar -->
<a id="applied-learning-identifiers-used-as-durable-filenames-need-one-canonical-case-stable-grammar"></a>
**Identifiers used as durable filenames need one canonical, case-stable grammar.** Distinct logical IDs such as `ws_A` and `ws_a` can alias on the default case-insensitive macOS filesystem even when they are separate map keys. Validate filename-backed IDs to one case before any path construction, and reject non-canonical forms rather than normalizing an authority-bearing identifier after the fact (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: disable-production-durable-stores-before-the-test-application-starts-do-not-tear-them-down-in-test-helper-exs -->
<a id="applied-learning-disable-production-durable-stores-before-the-test-application-starts-do-not-tear-them-down-in-test-helper-exs"></a>
**Disable production durable stores before the test application starts; do not tear them down in `test_helper.exs`.** A test-helper teardown runs only after the application-owned child may already have opened and hydrated real operator state, and deleting the child can make an incorrect test configuration appear isolated. Set the test-environment child config to disabled, inject temporary roots into focused tests, and assert the production child was never started (found 2026-07-16 reviewing retained-workspace restart persistence).

<!-- applied-learning: a-worktree-changes-relative-durable-store-identity -->
<a id="applied-learning-a-worktree-changes-relative-durable-store-identity"></a>
**A worktree changes relative durable-store identity.** Arbor Security's JSONFile backend resolves `.arbor/security` from the server process CWD, so a server launched from a disposable worktree sees a new empty identity/capability/signing-key universe even when it uses the normal master key. For an intentional recovery runtime, explicitly bind the canonical project security store before startup; do not weaken signed-request auth or recreate agent authority piecemeal (found 2026-07-13 recovering the Phase 6 delegator runtime).
