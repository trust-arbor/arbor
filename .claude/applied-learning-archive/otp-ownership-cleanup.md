# Applied Learning archive: otp-ownership-cleanup

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: hot-loading-a-genserver-module-does-not-migrate-its-running-state -->
<a id="applied-learning-hot-loading-a-genserver-module-does-not-migrate-its-running-state"></a>
**Hot-loading a GenServer module does not migrate its running state or stored local function captures.** A recompiled callback can expect new struct fields while the live process still holds the old map, causing writes to fail long after code loading reports success. A local capture such as `&cleanup/1` stored in state can likewise point at purged code and raise `BadFunctionError`; represent production callback selection as data, an MFA, or a reload-stable external function reference. Before exercising a hot-loaded stateful subsystem, compare `:sys.get_state/1` keys with current expectations; use an explicit in-place state migration when semantics are clear, or restart under its supervisor only when persisted reconstruction is safe. A private state-validity certificate must also bind the loaded executable identity of every runtime module whose semantics its validator executes: a source-only owner hash remains unchanged when a dependency reloads. Recompute that bounded identity at the callback gate and fail closed when unavailable; do not memoize it across independently reloadable modules. Do not restart a memory-backed policy store casually (found 2026-07-10 when `Arbor.Trust.Store` lacked newly added durable-backend fields after hot reload; extended 2026-07-25 when retained workspace settlement failed through a stale cleanup capture and 2026-08-15 when E0B2P initially certified across a `CapabilityUri` reload).

<!-- applied-learning: a-blocking-genserver-callback-also-bypasses-supervisor-exit-handling -->
<a id="applied-learning-a-blocking-genserver-callback-also-bypasses-supervisor-exit-handling"></a>
**A blocking GenServer callback also bypasses supervisor-exit handling.** Moving an unbounded drain out of `terminate/2` is not enough if `handle_call/3` then runs recursive `receive` / sleep loops: the GenServer loop cannot process its supervisor parent's shutdown while the callback owns the process. If an earlier `rest_for_one` sibling fails during that barrier, the parent waits for the coordinator while the coordinator waits for the sibling that cannot restart. Drive durable barriers as a nonblocking state machine, or bind and abort on the exact parent exit in every blocking path; regress an earlier-sibling crash while the barrier is actively held, not only idle turnover (found 2026-07-15 reviewing the Apple planned-shutdown barrier).

<!-- applied-learning: a-genserver-owner-monitor-does-not-interrupt-a-busy-callback -->
<a id="applied-learning-a-genserver-owner-monitor-does-not-interrupt-a-busy-callback"></a>
**A GenServer owner monitor does not interrupt a busy callback.** A queued `:DOWN` message cannot stop a worker that is copying or hashing inside `handle_call/3`; check owner liveness and the absolute deadline inside every bounded loop. If owner-death cleanup fails, retain the worker, root identity, and retry authority until absence is proven rather than stopping and forgetting the resource (found 2026-07-14 hardening the Linux dependency-baseline materialization lease).

<!-- applied-learning: cleanup-absence-checks-must-distinguish-absent-from-unqueryable -->
<a id="applied-learning-cleanup-absence-checks-must-distinguish-absent-from-unqueryable"></a>
**Cleanup absence checks must distinguish absent from unqueryable.** A boolean helper that maps every failing `git show-ref` or worktree query to `false` can issue a verified receipt while the repository is unavailable. Use tri-state queries, accept only the command's exact not-found outcome as absence, and fail closed on every transport, permission, timeout, or parse error (found 2026-07-11 reviewing workspace cleanup receipts).
Record OS PID/group signal-zero outcomes separately: `PermissionError` / `EPERM`
means the sandbox probe is unavailable, while `ESRCH` means absence. On
2026-10-06 UTC, usable user-terminal fixtures were unqueryable from Codex.
The first readiness script aborted before writing success metadata; its corrected
proof recorded `permission_denied` without an independent presence or absence
claim.

<!-- applied-learning: a-missing-supervisor-is-not-an-empty-ownership-snapshot -->
<a id="applied-learning-a-missing-supervisor-is-not-an-empty-ownership-snapshot"></a>
**A missing supervisor is not an empty ownership snapshot.** Under `rest_for_one`, the failed earlier child is already dead when later drain coordinators terminate. Returning `[]` when its registry/supervisor is missing turns unknown owned work into success, and waiting on cleanup through that failed transport can deadlock the restart forever. Consult durable ownership records, use an independent recovery transport, and require positive absence receipts; never equate `:noproc`, child `DOWN`, or a failed snapshot call with no resources (found 2026-07-14 reviewing Apple unit crash recovery).

<!-- applied-learning: quiet-git-ref-probes-do-not-prove-exact-absence -->
<a id="applied-learning-quiet-git-ref-probes-do-not-prove-exact-absence"></a>
**Quiet Git ref probes do not prove exact absence.** `git rev-parse --verify --quiet` returns the same nonzero status for a missing ref and some corrupt or unreadable refs, while localized command text is not a stable error protocol. Observe an exact full ref through structured `for-each-ref` output, reject stderr/warnings and malformed records, and after a compare-and-delete failure re-read the ref: absent is an idempotent success, a different OID is a CAS mismatch, and the same OID is an operational failure (found 2026-07-20 hardening coding-branch discard settlement).

<!-- applied-learning: fail-closed-cleanup-retries-still-need-a-dormant-terminal-state -->
<a id="applied-learning-fail-closed-cleanup-retries-still-need-a-dormant-terminal-state"></a>
**Fail-closed cleanup retries still need a dormant terminal state.** A deterministic identity mismatch, path ceiling, or enumeration-memory failure must retain evidence, but retrying it every few seconds forever leaks timers and consumes work without improving authority. Bound automatic attempts, preserve every destructive token and opaque lease, expose dormant status for explicit recovery, and allow manual or later supervisor cleanup to retry (found 2026-07-15 closing validation-owner cleanup churn).

<!-- applied-learning: bound-retries-at-every-owner-layer-not-only-at-the-composite-registry -->
<a id="applied-learning-bound-retries-at-every-owner-layer-not-only-at-the-composite-registry"></a>
**Bound retries at every owner layer, not only at the composite registry.** A higher-level validation owner can become dormant correctly while its lower Shell materializer continues an independent owner-death timer loop forever. Every process that retains destructive identity must own its own bounded retry counter and dormant state; supervisor teardown or an explicit recovery surface may retry later without background churn (found 2026-07-15 reviewing nested validation cleanup ownership).

<!-- applied-learning: a-bounded-cleanup-handshake-is-not-cleanup-completion -->
<a id="applied-learning-a-bounded-cleanup-handshake-is-not-cleanup-completion"></a>
**A bounded cleanup handshake is not cleanup completion.** A `GenServer.call` timeout or exit can mean the worker is temporarily unresponsive, died without proof, or accepted the request but lost the reply. Keep every owned worker unresolved under the same exact receipt token, retry bounded handshakes as needed, and release shutdown only on the positive-absence receipt; dropping handshake failures from the pending set turns unresponsiveness into a containment bypass (found 2026-07-14 reviewing the Apple unit drain coordinator).

<!-- applied-learning: monitor-separately-supervised-resource-owners-in-both-directions -->
<a id="applied-learning-monitor-separately-supervised-resource-owners-in-both-directions"></a>
**Monitor separately supervised resource owners in both directions.** A child owner monitoring its registry closes registry-crash leaks, but the registry must also monitor the owner so an isolated owner crash cannot leave stale public handles and resources. On either death, the survivor uses retained identities to converge cleanup while preserving the parent workspace (found 2026-07-15 reviewing validation-resource cleanup).

<!-- applied-learning: failure-acquisition-must-return-cleanup-evidence-with-the-opaque-lease -->
<a id="applied-learning-failure-acquisition-must-return-cleanup-evidence-with-the-opaque-lease"></a>
**Failure acquisition must return cleanup evidence with the opaque lease.** A composite owner can retain a Shell lease after `cleanup_required` or malformed-view rollback, then die before release. Return a bounded locator from the same trusted acquisition operation and store it before replying, so the surviving registry can prove the Shell worker's root disappeared without receiving or reconstructing lease authority (found 2026-07-15 closing validation-owner crash convergence).

<!-- applied-learning: an-arbitrary-traversal-depth-ceiling-is-not-progressive-cleanup -->
<a id="applied-learning-an-arbitrary-traversal-depth-ceiling-is-not-progressive-cleanup"></a>
**An arbitrary traversal-depth ceiling is not progressive cleanup.** Retrying from the root reaches the same deep branch and fails forever. Bound portable traversal by the already enforced absolute-path byte ceiling and total entry/time/memory budgets; do not introduce a directory-rename shortcut merely to reset depth, because portable rename cannot bind the expected source inode and no-replace destination atomically (found 2026-07-15 closing validation-tree cleanup liveness).

<!-- applied-learning: compiled-validation-roots-need-operation-specific-ownedtree-cleanup-bounds -->
<a id="applied-learning-compiled-validation-roots-need-operation-specific-ownedtree-cleanup-bounds"></a>
**Compiled validation roots need operation-specific `OwnedTree` cleanup bounds.** The generic 2,000,000-word listing budget scales down by directory depth, so an ordinary `candidate-runtime/build/lib/<app>/ebin` directory exhausted the depth-five allowance even though cleanup succeeded with the supported 8,000,000-word budget. Keep the exact pinned identity and fail-closed ordering, but call `Arbor.Shell.remove_owned_tree/2` with `listing_heap_words: 8_000_000` and the public maximum `timeout_ms: 10_000` only at the validation-root owner; larger timeout values fail with `:invalid_cleanup_budget` (found 2026-07-17 after a successful validation operation was reported as cleanup failure).

<!-- applied-learning: a-timed-out-genserver-call-3-does-not-cancel-the-queued-call -->
<a id="applied-learning-a-timed-out-genserver-call-3-does-not-cancel-the-queued-call"></a>
**A timed-out `GenServer.call/3` does not cancel the queued call.** Security-sensitive
acquisition/finalization protocols need request IDs plus ordered acknowledge/cancel
messages whose late processing cannot commit after the caller has returned an error.
Testing only a delayed initial reply misses the equally dangerous delayed-finalize race.

<!-- applied-learning: killing-a-genserver-call-caller-does-not-remove-a-request-already-queued-in-the-server-mailbox -->
<a id="applied-learning-killing-a-genserver-call-caller-does-not-remove-a-request-already-queued-in-the-server-mailbox"></a>
**Killing a `GenServer.call` caller does not remove a request already queued in the server mailbox.** Async task cancellation must both tombstone the task at the execution boundary and reject queued work whose caller is already dead; otherwise a busy shared agent can execute cancelled work later. This surfaced on 2026-07-09 while closing the `TaskStore -> APIAgent -> Session` cancellation race.

<!-- applied-learning: a-supervised-genserver-cannot-defer-parent-shutdown-from-handle-info-2 -->
<a id="applied-learning-a-supervised-genserver-cannot-defer-parent-shutdown-from-handle-info-2"></a>
**A supervised GenServer cannot defer parent shutdown from `handle_info/2`.** OTP consumes the parent-supervisor exit and enters the behavior's termination path; trapping exits does not turn that parent exit into an ordinary callback message. If children must continue their normal asynchronous lifecycle while sibling infrastructure remains alive, place a later drain coordinator in the parent supervision order: its shutdown callback requests child cleanup before their supervisor is stopped and waits for exact completion receipts. Do not hide an unbounded ownership requirement inside a finite `terminate/2` drain (found 2026-07-14 when the Apple unit worker died before its proposed `handle_info({:EXIT, ...})` cleanup path ran).

<!-- applied-learning: a-supervised-genserver-can-reach-terminate-2-without-handling-the-supervisor-s-exit-tuple-first -->
<a id="applied-learning-a-supervised-genserver-can-reach-terminate-2-without-handling-the-supervisor-s-exit-tuple-first"></a>
**A supervised GenServer can reach `terminate/2` without handling the supervisor's `EXIT` tuple first.** `DynamicSupervisor.terminate_child/2` may drive system termination directly, and named ancestors can appear as atoms in `:"$ancestors"`. Resolve named ancestors to their PID, perform bounded cleanup from both paths, and use a process-local attempted marker so the cleanup runs exactly once (found 2026-07-15 testing validation-owner dormant recovery).

<!-- applied-learning: format-status-2-does-not-make-secret-bearing-genserver-state-private -->
<a id="applied-learning-format-status-2-does-not-make-secret-bearing-genserver-state-private"></a>
**`format_status/2` does not make secret-bearing GenServer state private.** It can redact crash/status formatting, but local code can still call `:sys.get_state/1` and receive the raw state. Do not retain bearer tokens or private authority in long-lived GenServer state at all; keep them in a private owner/ETS boundary or consume them entirely inside the exact request process (found 2026-07-11 probing the MCP verified-request handler).

Private custody must also stay private during handoff. Enable sensitivity before
the first acquisition or claim RPC, since its reply can queue while the caller
is descheduled. Before sending a secret bootstrap to a newly created worker,
wait for that exact worker's fresh sensitive-ready acknowledgment; setting the
flag after receipt leaves an ordinary `Process.info(pid, :messages)` window.
Regress held startup and queued replies, not only an already-claimed worker.
This protects ordinary inspection, not hostile code execution in the same BEAM
(2026-10-03 native notice handoff review).

<!-- applied-learning: genserver-format-status-1-cannot-sanitize-an-explicitly-enabled-sys-debug-ring -->
<a id="applied-learning-genserver-format-status-1-cannot-sanitize-an-explicitly-enabled-sys-debug-ring"></a>
**`GenServer.format_status/1` cannot sanitize an explicitly enabled `:sys` debug ring.** OTP passes the callback a redacted status map, but `:sys.get_status/1` also returns the raw debugger state outside that callback; after `:sys.log(pid, true)`, it can contain prior messages, replies, and GenServer states. Redact `:state`, `:message`, `:reason`, and `:log` for ordinary status/crash formatting, but do not claim this hides secrets from same-BEAM callers: they can also use `:sys.get_state/1`, tracing, or code injection at the currently conceded T4 boundary. Never enable `:sys` logging on a secret/authority owner in production diagnostics (verified 2026-07-14 while testing control-plane status redaction).

<!-- applied-learning: a-genserver-from-tuple-is-protocol-data-not-authenticated-process-identity -->
<a id="applied-learning-a-genserver-from-tuple-is-protocol-data-not-authenticated-process-identity"></a>
**A GenServer `from` tuple is protocol data, not authenticated process identity.** Any local process can send a raw `{:\"$gen_call\", from, request}` message containing another PID, so extracting `elem(from, 0)` cannot prove who submitted an admission, result, or evidence mutation. Keep security-relevant authority inside one owner process or use an opaque owner-generated reference bound to a monitored generation; never authorize from caller-supplied GenServer envelope fields (found 2026-07-11 reviewing the coding benchmark coordinator).

<!-- applied-learning: linearize-starts-through-the-owner-that-snapshots-shutdown-work -->
<a id="applied-learning-linearize-starts-through-the-owner-that-snapshots-shutdown-work"></a>
**Linearize starts through the owner that snapshots shutdown work.** A later drain coordinator cannot safely snapshot a `DynamicSupervisor` if another public path can add a child after that snapshot. Route production starts through the coordinator's `GenServer.call`, derive the real controller from the `from` tuple, and make reply-loss waiting children expire before they can create anything. A callback that successfully starts a child completes before supervised `terminate/2`, while calls arriving during termination cannot create late work (found 2026-07-14 closing the Apple unit shutdown race).

<!-- applied-learning: filesystem-fixture-names-must-outlive-neither-vm-local-uniqueness-nor-cleanup-ownership -->
<a id="applied-learning-filesystem-fixture-names-must-outlive-neither-vm-local-uniqueness-nor-cleanup-ownership"></a>
**Filesystem fixture names must outlive neither VM-local uniqueness nor cleanup ownership.** `System.unique_integer/1` restarts with a new VM, so a root that survives a failed run can collide with a later VM. Use cryptographic randomness for names that outlive one BEAM, record cleanup ownership, and remove only resources owned by that fixture (found 2026-07-16 rerunning the full Actions suite and 2026-07-19 during Grok containment work).

<!-- applied-learning: authenticate-resume-before-any-existence-bearing-lifecycle-lookup -->
<a id="applied-learning-authenticate-resume-before-any-existence-bearing-lifecycle-lookup"></a>
**Authenticate resume before any existence-bearing lifecycle lookup.** Checking RunJournal admission before checkpoint identity returned `:not_found` to an unauthenticated caller and bypassed the intended security regression. Gate resume/recovery on derived checkpoint identity first, then validate takeover status/principal, and make takeover tests supply identity so they reach the gate they claim to test (found 2026-07-15 during final L3C validation).

<!-- applied-learning: a-late-identity-observation-cannot-prove-exclusive-create-ownership -->
<a id="applied-learning-a-late-identity-observation-cannot-prove-exclusive-create-ownership"></a>
**A late identity observation cannot prove exclusive-create ownership.** After creating a cleanup root, capture its stable device/inode/type identity before doing work. If that first capture fails, leave the path in place and fail closed; recapturing an identity during cleanup can observe a replacement path and incorrectly authorize its deletion (found 2026-07-13 proving the tree-binding cleanup regression against its prior revision).
