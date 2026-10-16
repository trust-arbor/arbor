# Applied Learning: OTP Ownership and Cleanup

Read this when changing GenServer ownership, cancellation, supervision, restart, cleanup, or authority lifetime.

## Retained Applied Learning

<!-- applied-learning: one-shot-protocol-safety-requires-an-uncontaminated-session -->
<a id="applied-learning-one-shot-protocol-safety-requires-an-uncontaminated-session"></a>
**One-shot protocol safety requires an uncontaminated Session.** If normalized
provider events lack response/item correlation, closing after one audio turn is
insufficient when an earlier text turn can leave delayed events on the same
connection. Enforce the audio-only mode before any admission or provider effect,
then retire the Session after its sole completed or cancelled operation. Regress
both the rejected prior operation and the subsequent valid audio turn; do not
claim reusable-session safety from a close-after-audio test alone (found
2026-09-27 reviewing VP-07A1).
Scope cancellation claims to the received lifecycle phase. Capture Cancel
discards held audio, while presentation Cancel retains text already committed;
a turn cancellation can race one valid durable pair. On 2026-10-04 the physical
voice review found generic recording-discard copy for all phases. Test positive
local closure and no late replay separately from remote provider cancellation;
closing a TLS transport does not prove remote computation or billing stopped.

<!-- applied-learning: a-later-rest-for-one-child-must-not-wait-in-terminate-2-for-an-earlier-crashed-sibling-to-restart -->
<a id="applied-learning-a-later-rest-for-one-child-must-not-wait-in-terminate-2-for-an-earlier-crashed-sibling-to-restart"></a>
**A later rest-for-one child must not wait in terminate/2 for a crashed sibling to restart.** Serialize start admission through the one trusted owner that also snapshots shutdown work. Close admission before draining, and do that drain in `Application.prep_stop/1` while dependencies are still alive. Crash termination returns promptly so durable state can be reconstructed; `terminate/2` must not block on a sibling that `rest_for_one` has not restarted. Do not derive that owner from a GenServer `from` tuple. The `from` value is untrusted protocol data. (Merged 2026-10-16 from 2 entries; first found 2026-07-14, last 2026-07-15.)

<!-- applied-learning: a-cleanup-lease-needs-stable-identity-restart-semantics-and-retryable-effects -->
<a id="applied-learning-a-cleanup-lease-needs-stable-identity-restart-semantics-and-retryable-effects"></a>
**A cleanup lease needs stable identity, restart semantics, and retryable effects.** A PID-only
temporary lease can die while its owner remains alive, after which treating `:noproc` as
success permanently detaches live authority from revocation. Address leases by a stable
registry key, restart them with recoverable cleanup state, and stop only after authority,
capability, trust, and identity cleanup has succeeded or reached an explicit terminal policy.
Opt-in admission must pin that identity on every effect request. If a replacement
executor forgets its bindings, a call through its registered name can silently
become an unrestricted legacy call. Keep leased calls on the pinned PID/generation
and recheck after queueing and between blocking open/start phases (2026-09-27
bounded media lease review).

<!-- applied-learning: cancellation-and-verification-must-not-reuse-mutating-scope-allocators -->
<a id="applied-learning-cancellation-and-verification-must-not-reuse-mutating-scope-allocators"></a>
**Cancellation and verification must not reuse mutating scope allocators.** An execution setup
function that exclusively creates an artifact root is correct for first admission, but calling it
again from a timeout cancel hook turns the expected `:eexist` into a cancellation failure. Split
scope derivation from allocation: execution uses the exclusive allocator once; status, verification,
and cancellation derive the same task/worktree/artifact identities without creating anything. A
cancel request or adapter-task exit is not proof that a delegated worker stopped; retain the exact
artifact lease until worker termination and cleanup are positively confirmed, or a late worker can
mutate a path already reassigned to an identical rerun.
Keep delivery uncertainty separate from execution liveness when discovering
active commands. An immutable uncertain delivery may still own a live Engine;
retain it until separate confirmed termination evidence arrives. An admitted
command with confirmed never-dispatched cancellation is inactive
(2026-10-03 durable conversation command index).

<!-- applied-learning: a-private-ets-table-is-not-an-access-control-boundary-if-a-genserver-relays-its-rows -->
<a id="applied-learning-a-private-ets-table-is-not-an-access-control-boundary-if-a-genserver-relays-its-rows"></a>
**A private ETS table is not an access-control boundary if a GenServer relays its rows.**
Keeping bearer authority in a `:private` table prevents direct ETS reads, but unrestricted
`fetch`, enumeration, or delete calls on the owning facade still expose or erase that state for
any local process. Authorize every relay operation by the exact lease/owner/reconciler process,
redact diagnostics, and crash-test the table owner itself rather than only its clients.

<!-- applied-learning: deferred-lifecycle-messages-need-state-owned-unforgeable-settlement-records -->
<a id="applied-learning-deferred-lifecycle-messages-need-state-owned-unforgeable-settlement-records"></a>
**Deferred lifecycle messages need state-owned, unforgeable settlement records.** A later
`send(self(), ...)` carrying the full settlement payload can be forged and can be lost when the
GenServer terminates before handling it. Store the payload in a ref-keyed private outbox, send only
the fresh ref, accept each ref once, and flush the outbox before every close/owner/client/terminate
path (found 2026-07-12 in ACP timeout task-control settlement).

<!-- applied-learning: registry-disappearance-may-lag-synchronous-process-shutdown -->
<a id="applied-learning-registry-disappearance-may-lag-synchronous-process-shutdown"></a>
**Registry disappearance may lag synchronous process shutdown.** `Supervisor.stop/3` waits for the process tree to terminate, but a `Registry.lookup/2`-backed `whereis/1` can briefly retain the registration until its cleanup notification is processed. Tests that assert absence immediately after shutdown should use a short bounded eventual assertion while still checking security state such as identity suspension and capability revocation directly (found 2026-07-10 in exact-policy fail-closed cleanup tests).

<!-- applied-learning: publish-terminal-state-before-invoking-optional-cleanup-infrastructure -->
<a id="applied-learning-publish-terminal-state-before-invoking-optional-cleanup-infrastructure"></a>
**Publish terminal state before invoking optional cleanup infrastructure.** `Task.Supervisor.start_child/5` starts the child body asynchronously, but the call to the supervisor is synchronous and can itself stall. A task owner must commit result/status first, then hand cleanup scheduling to a named, non-closure launcher so an unhealthy cleanup supervisor cannot delay result availability (found 2026-07-11 in the second terminal-approval cleanup council review).

<!-- applied-learning: a-key-owning-broker-must-authenticate-lease-acquisition-not-only-lease-use -->
<a id="applied-learning-a-key-owning-broker-must-authenticate-lease-acquisition-not-only-lease-use"></a>
**A key-owning broker must authenticate lease acquisition, not only lease use.** An unguessable bearer token prevents reference forgery after issuance, but `open(agent_id)` still becomes a sign-as-any-principal deputy when the broker can resolve every stored key. Require fresh cryptographic possession proof bound to the principal, purpose, and actual owner at acquisition; verify it through the existing nonce/freshness path, and never retain the proof, signer callback, or raw key in broker state (found 2026-07-11 reviewing the first reload-stable signing-authority slice).

<!-- applied-learning: process-monitors-do-not-require-trapping-exits -->
<a id="applied-learning-process-monitors-do-not-require-trapping-exits"></a>
**Process monitors do not require trapping exits.** Use a monitor for ordinary observation. Set `trap_exit` only for an explicit linked-worker protocol. A supervisor parent's EXIT arrives as `terminate/2`, not as an ordinary `handle_info/2` EXIT tuple, so a supervised GenServer cannot defer parent shutdown from `handle_info/2`. Resolve atom ancestors stored under the "$ancestors" key. Run cleanup exactly once across the message path and `terminate/2`. Put exhaustive planned barriers in `Application.prep_stop/1` while dependencies are still alive; a finite drain inside `terminate/2` is not that barrier. Crash turnover returns promptly so the supervisor can reconstruct. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-15.)

<!-- applied-learning: derived-summaries-cannot-replace-independently-recorded-cleanup-evidence -->
<a id="applied-learning-derived-summaries-cannot-replace-independently-recorded-cleanup-evidence"></a>
**Derived summaries cannot replace independently recorded cleanup evidence.** If run-root cleanup is observed only while building a summary, later acceptance recomputation may incorrectly infer it from pair cleanup and let a coordinated summary rewrite forge success. Retain each security-relevant lifecycle observation outside caller-editable aggregates, require it in the closed report schema, and derive the summary from that evidence (found 2026-07-11 reviewing coding benchmark acceptance integrity).
An observer can exit nonzero after its `finally` completes resource closure.
Preserve that failed operation receipt. A separate reconciliation must bind the
actual browser/host/terminal owners and fresh absence, endpoint and closure facts
before removing disposable credentials or admitting a successor fixture
(2026-10-05 v9 browser-observer retirement).

<!-- applied-learning: trace-the-actual-external-process-owner-on-every-execution-branch-before-claiming-tree-cleanup -->
<a id="applied-learning-trace-the-actual-external-process-owner-on-every-execution-branch-before-claiming-tree-cleanup"></a>
**Trace the actual external-process owner on every execution branch before claiming tree cleanup.** In the pinned Bash/ExCmd path, the Session owns ordinary foreground `ExCmd.Process` instances, while background jobs introduce a `JobProcess` and a separate worker that creates ExCmd; killing the Session is therefore not one uniform cleanup proof. Timeout/cancellation tests must exercise foreground, pipeline, background, and coprocess branches or reject unsupported branches before launch (found 2026-07-11 reviewing CapShell timeout ownership).

For terminal teardown, bind the surviving PID to the actual adapter owner and
its exact reader before classifying it as shared infrastructure. A linked
child ignores normal owner exit; a reader blocked in IO.getn cannot service
a stop call. Explicitly settle that owned reader and observe DOWN, while
preserving borrowed adapters and the shared I/O device. A forced fixture
cleanup is not a passing normal-exit witness (2026-10-03 native Breeze exit).

<!-- applied-learning: a-determinate-timeout-requires-proof-that-no-later-commit-can-occur -->
<a id="applied-learning-a-determinate-timeout-requires-proof-that-no-later-commit-can-occur"></a>
**A determinate timeout requires proof that no later commit can occur.** Checking a deadline before a state transform, database lock, or backend mutation is insufficient: the caller can time out while the owner continues and commits afterward. Carry one absolute monotonic deadline through queueing, lock acquisition, work, and commit; post-check before publishing mutable state, use backend-side cancellation for database work, and return an indeterminate outcome whenever commit status cannot be observed exactly (found 2026-07-11 with live Agent, PostgreSQL advisory-lock, and SQLite busy-timeout EventLog probes).

<!-- applied-learning: verified-preservation-is-not-verified-cleanup -->
<a id="applied-learning-verified-preservation-is-not-verified-cleanup"></a>
**Verified preservation is not verified cleanup.** Releasing a reused worktree may correctly prove that its path, registration, and branch survived, but that evidence cannot set `cleanup_verified: true` or satisfy a consumer that requires resource removal. Use distinct receipt/status fields and require owned-path absence plus unregistration for cleanup acceptance (found 2026-07-11 reviewing benchmark workspace cleanup evidence).

<!-- applied-learning: secret-bearing-genservers-need-explicit-status-redaction -->
<a id="applied-learning-secret-bearing-genservers-need-explicit-status-redaction"></a>
**Redact secret-bearing GenServer status on the process module itself.** Implement `format_status` on the OTP process module and redact `:state`, `:message`, `:reason`, and `:log`. Preserve `:normal` and `:shutdown`; for `{:shutdown, reason}` redact only the private payload. OTP may append the original stack after the formatter, so keep secrets out of function-clause heads. `format_status` does not hide `:sys.get_state/1`, an enabled `:sys` debug ring, or hostile code in the same BEAM. Do not retain bearer tokens in long-lived state. Set `Process.flag(:sensitive, true)` before the first secret-bearing reply, and wait for that worker's sensitive-ready acknowledgement before bootstrap. Never enable `:sys` logging on a secret owner in production. `:sensitive` is not a `Process.info` key; a test-only reset reads the previous value from `Process.flag/2`. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-14.)

<!-- applied-learning: private-ets-does-not-protect-authority-from-its-owning-genserver-s-sys-callbacks -->
<a id="applied-learning-private-ets-does-not-protect-authority-from-its-owning-genserver-s-sys-callbacks"></a>
**Private ETS does not protect authority from its owning GenServer's `:sys` callbacks.** `:sys.replace_state/2` executes the supplied callback inside the target process, where that callback can read the owner's private ETS tables and exfiltrate a token. A plain sensitive owner that does not implement OTP system messages closes this specific introspection path and is useful Layer-0 defense in depth, but it does not satisfy the T4 same-VM-compromise threat: tracing, code loading, or other first-party calls still run inside the same trusted address space. If T4 is the acceptance criterion, move the authority behind an authenticated OS-process or separate-cluster boundary; moving the token to another GenServer or adding `format_status` is insufficient (found 2026-07-11 exploiting the benchmark RunCoordinator; assurance boundary clarified 2026-07-11).

<!-- applied-learning: a-genserver-wrapper-does-not-make-a-named-dets-table-private -->
<a id="applied-learning-a-genserver-wrapper-does-not-make-a-named-dets-table-private"></a>
**A GenServer wrapper does not make a named DETS table private.** Any same-VM process that knows the table name can call `:dets.lookup/2`, `insert/2`, or `delete/2` directly and bypass the owner's serialized CAS logic. Keep security-authoritative mutable state behind a genuinely private owner boundary, authenticate durable records, and test direct storage mutation; also make record+index transitions reconstructable across crashes (found 2026-07-11 reviewing the local approval backend).

<!-- applied-learning: an-absolute-deadline-needs-an-owner-stamped-completion-time -->
<a id="applied-learning-an-absolute-deadline-needs-an-owner-stamped-completion-time"></a>
**An absolute deadline needs an owner-stamped completion time.** Checking the clock only when a caller receives a result is not enough: a suspended caller can later accept a success that completed after its deadline, while checking only the receive time can reject a result that completed on time. The operation owner must stamp `completed_mono` before sending the result, and the receiver must compare that immutable timestamp with the original deadline; inactivity timeouts are not a substitute (found 2026-07-11 suspending LLM/eval callers across their deadlines).
`receive ... after remaining` alone is not an admission check: an already queued
matching message wins even with `after 0`. Check the chosen absolute deadline
on matched startup/result messages too; an observation-deadline policy may
conservatively reject a timely completion observed late, but must say so. Also
bound startup itself: `Task.Supervisor.async_nolink` can block on a suspended
supervisor before a later `Task.yield` timer exists (reinforced 2026-09-08 in
SU-3A; private supervisor probe blocked beyond 6,001 ms, and a local receive
probe selected its queued message despite `after 0`).
Deadline regression tests must measure from the tested phase's observed start,
not an earlier graph dispatch. Otherwise graph latency can exhaust the test's
clock before persistence begins and make a timely result look late (SU-3A
owner qualification, 2026-09-08).

<!-- applied-learning: caller-timeout-does-not-cancel-a-queued-owner-mutation -->
<a id="applied-learning-caller-timeout-does-not-cancel-a-queued-owner-mutation"></a>
**A caller timeout does not cancel a queued owner mutation.** `GenServer.call/3` timing out, or the caller dying, leaves the request in the server mailbox. Carry a request id and an absolute deadline into the mutation owner. Order acknowledgement, cancel, and finalize so a late success cannot commit after cancel. Reject queued work whose caller is already dead. An expiry timer is not an authorization gate: check the deadline before and after any blocking authority check, and cap a signed proof at the same expiry. When the outcome is unproven, stop and reconcile against the exact request id. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-13.)

<!-- applied-learning: exclusive-create-failure-does-not-grant-cleanup-ownership -->
<a id="applied-learning-exclusive-create-failure-does-not-grant-cleanup-ownership"></a>
**Exclusive-create failure does not grant cleanup ownership.** `:eexist`, or a failed capture of the original device, inode, and type, does not authorize deletion. Capture identity before doing work. If that capture fails, leave the path in place and fail closed. Do not recapture identity at cleanup time; a late observation can name a different object that reused the path. Cleanup authority begins only after exclusive acquisition and the original identity capture both succeed. Pre-existing markers must survive the failed create. (Merged 2026-10-16 from 2 entries; first found 2026-07-13, last 2026-07-13.)

<!-- applied-learning: a-correlation-token-placed-in-a-timer-message-is-not-the-cancellation-handle -->
<a id="applied-learning-a-correlation-token-placed-in-a-timer-message-is-not-the-cancellation-handle"></a>
**A correlation token placed in a timer message is not the cancellation handle.** `Process.send_after/3` returns a reference, so guards such as `is_integer(timer_ref)` silently skip cancellation. A `make_ref()` put into the payload cannot be cancelled with `Process.cancel_timer/1` either — that API needs the reference *returned by* `send_after/3` (or prefer `:erlang.start_timer/3`, whose delivered `{:timeout, timer_ref, payload}` carries the same cancellable ref). On cleanup/reset, cancel the real handle and non-blockingly flush or state-gate an already-delivered exact timeout message so completion races do not surface as unexpected `handle_info/2` traffic; regress by suspending after a fast successful prompt and asserting the mailbox is free of hard/inactivity timer messages (found 2026-07-14 in `AcpSession` / live `task_83651`; reinforced 2026-08-02 when `ResourceOwner` left a healthy close vulnerable to its stale readiness timeout).

<!-- applied-learning: a-permanent-startup-pinned-child-must-not-treat-its-process-restart-as-a-new-trust-epoch -->
<a id="applied-learning-a-permanent-startup-pinned-child-must-not-treat-its-process-restart-as-a-new-trust-epoch"></a>
**A permanent startup-pinned child must not treat its process restart as a new trust epoch.** Under `rest_for_one`, an authority that stops on identity drift is restarted from its original child spec; naively rereading the filesystem then accepts the changed artifact as the new baseline after one failed checkout. Carry an application-generated boot epoch through the child spec, retain only the original binding fingerprint plus a poison marker across child restarts, and clear it only when the application stops. Regress both downstream owner turnover and persistent poison/no-repin behavior (found 2026-07-14 reviewing the Apple control-plane authority).

<!-- applied-learning: cleanup-of-a-writable-leased-tree-must-unlink-without-following-and-never-fall-back-to-unverified-recursion -->
<a id="applied-learning-cleanup-of-a-writable-leased-tree-must-unlink-without-following-and-never-fall-back-to-unverified-recursion"></a>
**Cleanup of a writable leased tree must unlink without following and never fall back to unverified recursion.** Validation can add symlinks, sockets, FIFOs, or other special entries after materialization, so cleanup must `lstat` and unlink each entry itself. If identity changes or any bounded deletion step fails, retain cleanup authority and return a retryable error; a later `File.rm_rf/1` fallback can race with path replacement and delete a different tree (found 2026-07-14 reviewing the Linux dependency-baseline materializer).

<!-- applied-learning: do-not-project-an-ownership-parent-beside-its-typed-child-mounts -->
<a id="applied-learning-do-not-project-an-ownership-parent-beside-its-typed-child-mounts"></a>
**Do not project an ownership parent beside its typed child mounts.** Actions kept `candidate-runtime` as the private cleanup parent for `home`, `tmp`, `build`, runner, and result artifacts; projecting both the parent and selected children created overlapping mount sources and would expose the unselected control artifacts. Keep ownership/cleanup roots private and project only the least-privilege typed children a workload needs (found 2026-07-14 composing Actions validation resources with the Apple Container planner).

<!-- applied-learning: an-operation-deadline-never-authorizes-abandoning-owned-cleanup -->
<a id="applied-learning-an-operation-deadline-never-authorizes-abandoning-owned-cleanup"></a>
**An operation deadline never authorizes abandoning owned cleanup.** Expiry stops new work and stops admitting new attempts. It does not drop cleanup custody. Bound retries at every nested owner, not only at the composite registry. After the retry budget is exhausted, keep destructive tokens and leases in a dormant terminal state and release them only through explicit recovery after positive absence is proven. An uncertain close — process DOWN without a receipt, end-of-stream, enqueue success, or a swallowed native close — is not closure. Compare-and-clear so a stale releaser cannot clear a successor. Public occupancy identifiers are not private completion credentials. Bind custody before acknowledging the caller, and treat a before-open absence proof as valid only after admission has been revoked. (Merged 2026-10-16 from 3 entries; first found 2026-07-14, last 2026-07-15.)

<!-- applied-learning: project-lifecycle-provenance-explicitly-never-infer-it-from-a-result-payload -->
<a id="applied-learning-project-lifecycle-provenance-explicitly-never-infer-it-from-a-result-payload"></a>
**Project lifecycle provenance explicitly; never infer it from a result payload.** A terminal result shaped like `{:execution_owner_down, ...}` is an implementation convention, not proof of who committed the transition. Record a bounded source enum in the same owner transition that writes status/result/completion time, then require that provenance at safety-sensitive consumers (found 2026-07-15 composing the Apple executor with `ExecutionRegistry`).

<!-- applied-learning: a-synchronous-facade-must-not-drain-and-requeue-its-caller-s-mailbox-while-waiting-for-one-owned-signal -->
<a id="applied-learning-a-synchronous-facade-must-not-drain-and-requeue-its-caller-s-mailbox-while-waiting-for-one-owned-signal"></a>
**A synchronous facade must not drain and requeue its caller's mailbox while waiting for one owned signal.** Catch-all receive loops reorder unrelated traffic relative to concurrently arriving messages, can retain it without bound, and violate caller ownership. Use selective receive for the exact PID/ref/id patterns and leave every unrelated message in place; after a stronger positive-absence proof, demonitor only the exact ref with `[:flush]` (found 2026-07-15 reviewing the Apple executor terminal wait).

<!-- applied-learning: engine-ownership-metadata-is-owner-issued-not-caller-selectable -->
<a id="applied-learning-engine-ownership-metadata-is-owner-issued-not-caller-selectable"></a>
**Engine ownership metadata is owner-issued, not caller-selectable.** A caller-supplied `:spawning_pid` can keep a dead run looking live if Engine copies it into lifecycle state. Bind the run owner to the actual Engine process at the trusted execution boundary, and make any auxiliary ticker monitor that owner directly: an owner-side `after` block does not run after an untrappable `:kill` (found 2026-07-15 while proving L4A process-death windows).

<!-- applied-learning: worktree-cleanup-is-idempotent-only-after-both-filesystem-and-git-registration-absence-are-proven -->
<a id="applied-learning-worktree-cleanup-is-idempotent-only-after-both-filesystem-and-git-registration-absence-are-proven"></a>
**Worktree cleanup is idempotent only after both filesystem and Git-registration absence are proven.** A missing directory can still have a live detached `git worktree` registration, and a parser that accepts only branch-bearing entries will misclassify that evidence as absent. Parse every bounded inventory entry for its path independently of branch state; retry cleanup as success only when the path and exact canonical registration are both positively absent (found 2026-07-16 rerunning the retained-workspace validation suite).

<!-- applied-learning: a-restartable-registry-must-not-be-the-sole-owner-of-child-cleanup-authority -->
<a id="applied-learning-a-restartable-registry-must-not-be-the-sole-owner-of-child-cleanup-authority"></a>
**A restartable registry must not be the sole owner of child cleanup authority.** Place cleanup authority in an independently supervised owner. Monitor that owner and the registry in both directions. Retain locators from a failed acquisition so cleanup can still find the resource, without transferring the lease's authority to the finder. Transfer custody only after the receiver has committed adoption and acknowledged it. A queued result is not adoption. `terminate/2` does not run after `:kill`, so cleanup that exists only in the registry's terminate path is lost when the registry is killed or restarted. (Merged 2026-10-16 from 3 entries; first found 2026-07-15, last 2026-07-16.)

<!-- applied-learning: recursive-cleanup-must-be-bounded-and-progressive -->
<a id="applied-learning-recursive-cleanup-must-be-bounded-and-progressive"></a>
**Bound recursive cleanup and require it to make progress.** `Arbor.Shell.OwnedTree` accepts a listing heap from 512 to 8_000_000 words and a timeout of at most 10_000 ms; any other budget returns `:invalid_cleanup_budget`. Delete only identity-bound entries and do not follow links. A fixed depth ceiling that retries the same failing walk is not progress: retain retry authority and advance with operation-specific entry, path, time, and memory budgets. Validation roots pass `listing_heap_words: 8_000_000` and `timeout_ms: 10_000` through `Arbor.Shell.remove_owned_tree/2` from `Arbor.Actions.Coding.WorkspaceLeaseRegistry`. Do not shrink those roots to the default 2_000_000-word listing heap. (Merged 2026-10-16 from 3 entries; first found 2026-07-15, last 2026-07-17.)

<!-- applied-learning: a-synchronous-durability-acknowledgement-is-also-a-mailbox-boundary-not-lifecycle-authority -->
<a id="applied-learning-a-synchronous-durability-acknowledgement-is-also-a-mailbox-boundary-not-lifecycle-authority"></a>
**A synchronous durability acknowledgement is also a mailbox boundary, not lifecycle authority.** Controls and owner/caller exits can arrive while a GenServer waits for its evidence sink, so re-drain applicable messages against the still-active state before choosing a follow-up or replying. If archival then fails, report the combined evidence error while preserving cancellation teardown and hard/inactivity-timeout recovery plus provider settlement; evidence must never weaken the operation's terminal lifecycle (found 2026-07-16 hardening ACP prompt-turn capture).

<!-- applied-learning: negative-cleanup-tests-must-snapshot-and-remove-only-their-own-exact-roots -->
<a id="applied-learning-negative-cleanup-tests-must-snapshot-and-remove-only-their-own-exact-roots"></a>
**Negative cleanup tests must snapshot and remove only their own exact roots.** Never clean test artifacts by scanning a shared temporary directory for broad prefixes, deriving a cleanup target with `Path.dirname/1` from a payload path, or piping matches to `rm -rf`; retained and live resources from unrelated tasks use those same prefixes. Fixture constructors must return the exact owned root separately from paths inside it, and destructive cleanup must fail closed when the target equals `System.tmp_dir!()`, a filesystem root, or any ancestor of the fixture root. Record the exact paths before the negative run, reconstruct or retain their lstat-pinned identities, and remove only that allowlist through the owning public cleanup API. A delegated worker attempted a broad prefix cleanup on 2026-07-17; the ACP client did not execute it, and the two test-created roots were then removed individually through `Arbor.Shell.remove_owned_tree/2`. This guard became mandatory on 2026-08-16 after a Hex fixture returned its root as `source` and an `after` block called `File.rm_rf!(Path.dirname(source))`, deleting user-owned task artifacts and worktrees under the shared macOS temp directory before protected entries stopped the traversal.

<!-- applied-learning: linked-worktree-git-storage-authority-must-come-from-the-active-lease -->
<a id="applied-learning-linked-worktree-git-storage-authority-must-come-from-the-active-lease"></a>
**Linked worktree Git storage authority must come from the active lease.** A linked worktree's files live under its workspace root, but its Git directory, common directory, and objects live under the parent repository's `.git/worktrees` and object store. Do not widen the workspace path grant or trust a caller-provided parent path. Resolve the active workspace lease with task and principal identity, require the requested path to equal the lease's canonical worktree path, and install `Arbor.Actions.Git.with_storage_authority/3` only around the exact nested Git mutation. Revalidate after approval so a stale or rebound lease fails closed (found 2026-07-17 when an approved reviewed commit passed validation but Git rejected the parent metadata path).

<!-- applied-learning: arm-owner-timeouts-at-the-terminal-authority-before-waiting -->
<a id="applied-learning-arm-owner-timeouts-at-the-terminal-authority-before-waiting"></a>
**Arm owner timeouts at the terminal authority before waiting.** Cleanup attempted only after a caller's receive timeout is too late: a partition can strand an answerable request after its owner exits, and rediscovering through an eventually consistent projection can miss a response that already won. Capture the trusted authority once, install a non-extendable authority-local deadline before blocking, and finalize timeout directly against that authority so response and abandonment share one serialized terminal transition. A projection such as Phoenix.Tracker remains discovery, never lifecycle CAS (found 2026-07-19 reviewing the coding approval timeout regression).

<!-- applied-learning: ephemeral-workspace-teardown-must-settle-task-scoped-pooled-sessions-first -->
<a id="applied-learning-ephemeral-workspace-teardown-must-settle-task-scoped-pooled-sessions-first"></a>
**Ephemeral workspace teardown must settle task-scoped pooled sessions first.** Returning a worker to the ACP pool is correct for normal same-task continuity, but a one-shot harness that deletes its worktree must atomically refuse busy sessions, track detached sessions until every process is confirmed down, and only then settle/remove workspace leases; otherwise a live process retains a stale cwd or a retry falsely reports no matches (found 2026-07-20 after the Phase 6 r10 benchmark).

<!-- applied-learning: settle-every-task-owned-resource-through-one-durable-disposition-lifecycle -->
<a id="applied-learning-settle-every-task-owned-resource-through-one-durable-disposition-lifecycle"></a>
**Settle every task-owned resource through one durable disposition lifecycle.** Removing only an ephemeral worktree can leave its task-created branch, evidence ref, pooled session, approvals, or journal marker behind. Let the workflow choose policy (`discard`, `recover`, `publish`, or `adopt`), but make the owning registry persist intent before destructive effects and converge every bound resource after crashes. A terminal task is not settled until the full ownership set is settled (found 2026-07-20 auditing 490 coding branches after worktree cleanup).

<!-- applied-learning: spawned-development-tools-must-not-inherit-the-parent-mix-runtime -->
<a id="applied-learning-spawned-development-tools-must-not-inherit-the-parent-mix-runtime"></a>
**Spawned development tools must not inherit the parent Mix runtime.** An ACP coding CLI launched by the live `MIX_ENV=dev` Arbor node passed that variable to worker shell commands, so ordinary `./bin/mix test` booted dev configuration, collided with the live Gateway port, and attempted to claim the operator Apple-container journal. Scrub parent build/runtime selectors such as `MIX_ENV` at the process-spawn boundary while preserving explicit worker command overrides; test config cannot protect a test command that never entered the test environment (found 2026-07-20 during delegated branch-lifecycle validation).

<!-- applied-learning: long-acp-tool-operations-must-publish-liveness-before-the-inactivity-deadline -->
<a id="applied-learning-long-acp-tool-operations-must-publish-liveness-before-the-inactivity-deadline"></a>
**Long ACP tool operations must publish liveness before the inactivity deadline.** Piping a broad test run through `grep | tail` buffered every progress byte, so Arbor correctly classified the ACP turn as inactive and recovered the same provider session while the valid test process was still running. Prefer focused suites below the deadline, stream bounded progress from long operations, or run broad validation under a separately supervised owner whose liveness and final result are explicit; a live child process that emits nothing through ACP is observationally indistinguishable from a stuck tool (found 2026-07-20 during branch-lifecycle validation).

<!-- applied-learning: git-ref-cas-and-worktree-checkout-protection-are-distinct-invariants -->
<a id="applied-learning-git-ref-cas-and-worktree-checkout-protection-are-distinct-invariants"></a>
**Git ref CAS and worktree checkout protection are distinct invariants.** `git update-ref -d <ref> <expected-oid>` atomically rejects an OID replacement, but it will delete a branch currently checked out in another worktree; the porcelain `git branch -D` guard is not part of the plumbing command. Branch retirement therefore needs both exact-OID authority and explicit checked-out-worktree protection, with conservative postcondition/recovery handling for races between observation and deletion (verified 2026-07-20 while reviewing coding-branch discard settlement).

<!-- applied-learning: erlang-receive-tracing-proves-delivery-not-selective-receive-consumption -->
<a id="applied-learning-erlang-receive-tracing-proves-delivery-not-selective-receive-consumption"></a>
**Erlang `:receive` tracing proves delivery, not selective-receive consumption.** A `{:trace, pid, :receive, message}` event can be emitted even when the process's active receive expression has no matching clause; do not treat that event alone as an acknowledgement that a state machine handled the message. Pair delivery tracing with an explicit reply, monitor, or bounded mailbox/state postcondition, and always disable tracing in cleanup (found 2026-07-27 while making RegistryBase forged-transfer tests deterministic).

<!-- applied-learning: source-owner-cleanup-success-does-not-imply-convergence -->
<a id="applied-learning-source-owner-cleanup-success-does-not-imply-convergence"></a>
**Source-owner cleanup success does not imply convergence.** A bounded handshake, a helper `:ok`, or a worker status of `closing` is intermediate evidence, not settlement. Retain the exact receipt through every retry; do not replace it with a reconstructed view from an empty supervisor or a missing Session. Publish the terminal state only after helper success, index absence, authenticated retirement, and worker DOWN have all been observed. Expiration denies late effects and still preserves authenticated terminal evidence. Take an irreversible next effect only on `closed` or `already_closed` from `Arbor.AI.AcpManaged.SessionRegistry`; any other close observation fails closed. (Merged 2026-10-16 from 3 entries; first found 2026-07-14, last 2026-09-02.)

<!-- applied-learning: out-of-band-owner-updates-must-survive-stale-process-local-publication -->
<a id="applied-learning-out-of-band-owner-updates-must-survive-stale-process-local-publication"></a>
**Out-of-band owner updates must survive stale process-local publication.** A ticker or helper can advance canonical journal state while the owning process is blocked, leaving its process-local snapshot stale. When that owner later republishes the full snapshot, the canonical owner boundary must monotonic-merge independently advanced fields only within the same owner epoch (for example, `owner_node` plus the actual Engine `spawning_pid`); a recovery or takeover epoch must publish its own value. Regress the exact sequence of initial publication, out-of-band advance, then stale full publication (found 2026-07-29 while tracing coding-pipeline heartbeat regressions during long validation).

<!-- applied-learning: crash-recovery-state-must-be-resumable-at-every-effect-boundary -->
<a id="applied-learning-crash-recovery-state-must-be-resumable-at-every-effect-boundary"></a>
**Crash-recovery state must be resumable at every effect boundary.** Do not add a
`settling` or `in_progress` state that recovery treats as complete: the owner can
die after publishing that state but before performing the effect. Persist or retain
the stable effect arguments first, replay the same idempotent effect until its
completion marker is durable, and test death immediately before the effect and
immediately after success but before completion publication (found 2026-08-02 while
reviewing VP-04 budget settlement across forced Session death).

<!-- applied-learning: crash-safe-competing-effects-need-a-permanent-pre-io-winner -->
<a id="applied-learning-crash-safe-competing-effects-need-a-permanent-pre-io-winner"></a>
**Crash-safe competing effects need a permanent pre-I/O winner.** A bounded phase such as
`release_pending` or `consume_pending` cannot by itself arbitrate a concurrent mode change once
ledger I/O has begun, and a transient owner lock strands progress when its caller dies. Atomically
select one permanent effect before external I/O, never clear that selection, make every replay
follow it, and report completion-CAS loss as success only when the terminal state is already
published. Regress the losing mode change while the winning effect is paused after durable
acceptance but before return (found 2026-08-02 repairing the VP-04D1 release-versus-arm race).

<!-- applied-learning: do-not-perform-large-or-backpressured-effects-in-the-control-owner-s-mailbox -->
<a id="applied-learning-do-not-perform-large-or-backpressured-effects-in-the-control-owner-s-mailbox"></a>
**Keep large or backpressured work out of the control owner's mailbox.** Do not run bulk effects, backpressured IO, or durable inventory scans inside the control or journal owner's callback. Admit that work to a bounded worker, check the worker against its deadline, and apply the result only to a conflict-checked snapshot, replying with `GenServer.reply/2`. A blocking callback also skips supervisor exit handling, and a monitor does not interrupt a callback that has already started, so lifecycle messages wait behind the scan. A socket left in active mode drops bytes while the owner is busy; set it passive before the long section. If cleanup on owner death fails, retain cleanup authority for a later attempt. (Merged 2026-10-16 from 4 entries; first found 2026-07-14, last 2026-08-26.)

<!-- applied-learning: admit-effect-ownership-before-invalidating-retryable-discovery -->
<a id="applied-learning-admit-effect-ownership-before-invalidating-retryable-discovery"></a>
**Admit effect ownership before invalidating retryable discovery.** A lifecycle owner
must not remove the registry row or other discovery evidence before a bounded worker
has been successfully admitted to own the destructive effect.
`Task.Supervisor.start_child/2` is synchronous and can stall or fail; invalidating
first can leave a live runtime undiscoverable with no retry owner. Admit a
release-gated worker under the fixed supervisor, monitor the caller, then revalidate
the exact fence immediately before releasing the effect; admission, caller death, or
fence uncertainty must preserve the original owner (found 2026-08-10 while closing
Phase 4C C2B runtime quiescence).

<!-- applied-learning: sys-suspend-does-not-hold-external-exit-signal-retirement -->
<a id="applied-learning-sys-suspend-does-not-hold-external-exit-signal-retirement"></a>
**`:sys.suspend/1` does not hold external exit-signal retirement.** It suspends
system-message and callback processing, but an external exit signal can still retire
the process before a monitor observer can inspect the intended intermediate state.
Concurrency tests that must hold an owner alive across shutdown should use a
controlled trap-exit owner, and tests that need exact message ordering should queue
the messages at the receiving owner before resuming it (found 2026-08-11 while
repairing runtime-admission settlement regressions).

<!-- applied-learning: cleanup-time-cancel-must-not-rewrite-a-completed-start-phase-candidate -->
<a id="applied-learning-cleanup-time-cancel-must-not-rewrite-a-completed-start-phase-candidate"></a>
**Cleanup-time cancel must not rewrite a completed start-phase candidate.** Once
start has produced an exit code, that result is the candidate terminal.
Stamping `cancelled`/`killed` during later cleanup makes Mix project
`validation_capacity_exceeded` and hides the real compile failure. Capacity
flags must come from the start phase itself (found 2026-08-27, V7-16, Linux
factory run 11n).

<!-- applied-learning: every-checkpoint-resumable-resource-consumer-must-reacquire-ownership -->
<a id="applied-learning-every-checkpoint-resumable-resource-consumer-must-reacquire-ownership"></a>
**Every checkpoint-resumable resource consumer must reacquire ownership.** Engine
resume starts a new process after completed nodes, so a predecessor that acquired a
process-owned lease will not replay merely to restore that ownership. Put exact
task/principal lineage reactivation at each durable resource consumer boundary and
test owner death immediately after the predecessor checkpoint; an opaque resource
id or a successful earlier acquisition is not restart authority (found 2026-09-02
while reviewing immutable CrossApp review snapshots).
<!-- applied-learning: retain-conversation-authority-through-final-publication -->
<a id="applied-learning-retain-conversation-authority-through-final-publication"></a>
**Retain conversation authority through final publication.** Finishing a provider
turn or releasing its egress lease does not finish the enclosing conversation
operation. Keep the immutable authenticated subject, owner, scope and proof
available through transcript commit, guarded rendering and the final reply;
recheck after append and immediately before disclosure. A committed write may
remain after revocation, but it must not force a successful reply or playback.
Use a nonconsuming continuation check for repeated effects and fresh admission
for the next turn, so chunk-level checks do not spend additional allowances
(found 2026-09-27 while binding Voice to the canonical private conversation).

<!-- applied-learning: defer-ancestry-queries-until-child-startup-has-acknowledged -->
<a id="applied-learning-defer-ancestry-queries-until-child-startup-has-acknowledged"></a>
**Defer ancestry queries while child startup is still unacknowledged.** `Arbor.Common.SupervisedOwner.starting_application_root/3` binds a candidate to an application root whose `start/2` is still running, without asking that application's master. OTP 28 `:application_master.get_child/1` crashes the master while the child slot is `:undefined`. Do not call `Supervisor.which_children/1` on a parent that is still starting. After startup, use the normal root lookup and the subsystem's reviewed call bound; a tiny timeout on that check becomes a false authorization denial. Exercise production boot in an isolated process, because a test that sets `start_children: false` hides this failure. (Merged 2026-10-16 from 2 entries; first found 2026-10-07, last 2026-10-09.)

<!-- applied-learning: proof-custody-must-protect-read-secrecy-as-well-as-write-authority -->
<a id="applied-learning-proof-custody-must-protect-read-secrecy-as-well-as-write-authority"></a>
**Proof custody must protect read secrecy as well as write authority.** Authenticate an authority-bearing call with an unpredictable challenge and a VM-checked transfer of the caller's exact `:private` ETS proof, as `Arbor.Common.AuthenticatedCall` does. Reject a raw table transfer unless the table is the exact pending proof and is server-owned. Never delete custody from caller-supplied metadata. Anchor the original custody outside replaceable callback state, because `:sys.replace_state/2` can swap the callback map. An invalid reply destination must not crash the server and must still clear the pending record and timer. A GenServer `from`, a raw `:$gen_call`, a reply alias, and a cast are untrusted protocol data. An authenticated forwarder launders content when the producer accepted it through an unauthenticated call or cast. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-10-07.)

<!-- applied-learning: record-a-shared-resource-s-prior-state-and-restore-only-the-task-s-change -->
<a id="applied-learning-record-a-shared-resource-s-prior-state-and-restore-only-the-task-s-change"></a>
**Record a shared resource's prior state and restore only the task's change.** Before a task starts, stops, creates or reconfigures a long-lived shared resource (a container builder, daemon, VM, service or cache), record its running or stopped state and its creation identity, not just its name. A build or setup step can recreate and start a previously stopped instance under the same name, so a familiar name does not prove the running instance predates the task. Afterwards restore only what the task changed, leave pre-existing state alone, and verify the resulting inventory. (Generalized 2026-10-16 from a 2026-09-27 container-builder incident.)
