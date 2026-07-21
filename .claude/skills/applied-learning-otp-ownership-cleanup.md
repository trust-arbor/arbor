# Applied Learning: OTP Ownership and Cleanup

Read this when changing GenServer ownership, cancellation, supervision, restart, cleanup, or authority lifetime.

## Retained Applied Learning

<!-- applied-learning: a-later-rest-for-one-child-must-not-wait-in-terminate-2-for-an-earlier-crashed-sibling-to-restart -->
<a id="applied-learning-a-later-rest-for-one-child-must-not-wait-in-terminate-2-for-an-earlier-crashed-sibling-to-restart"></a>
**A later `rest_for_one` child must not wait in `terminate/2` for an earlier crashed sibling to restart.** OTP terminates all later children before restarting the failed child, so a drain coordinator that waits for a dead Journal/Reconciler creates a supervision deadlock. Run exhaustive planned shutdown barriers from `Application.prep_stop/1` while the dependency chain is live; crash-driven turnover must exit promptly and rely on durable intent plus startup reconstruction (identified 2026-07-15 while wiring the Apple durable-unit topology).

<!-- applied-learning: a-blocking-genserver-callback-also-bypasses-supervisor-exit-handling -->
<a id="applied-learning-a-blocking-genserver-callback-also-bypasses-supervisor-exit-handling"></a>
**A blocking GenServer callback also bypasses supervisor-exit handling.** Moving an unbounded drain out of `terminate/2` is not enough if `handle_call/3` then runs recursive `receive` / sleep loops: the GenServer loop cannot process its supervisor parent's shutdown while the callback owns the process. If an earlier `rest_for_one` sibling fails during that barrier, the parent waits for the coordinator while the coordinator waits for the sibling that cannot restart. Drive durable barriers as a nonblocking state machine, or bind and abort on the exact parent exit in every blocking path; regress an earlier-sibling crash while the barrier is actively held, not only idle turnover (found 2026-07-15 reviewing the Apple planned-shutdown barrier).

<!-- applied-learning: a-timed-out-genserver-call-3-does-not-cancel-the-queued-call -->
<a id="applied-learning-a-timed-out-genserver-call-3-does-not-cancel-the-queued-call"></a>
**A timed-out `GenServer.call/3` does not cancel the queued call.** Security-sensitive
acquisition/finalization protocols need request IDs plus ordered acknowledge/cancel
messages whose late processing cannot commit after the caller has returned an error.
Testing only a delayed initial reply misses the equally dangerous delayed-finalize race.

<!-- applied-learning: a-cleanup-lease-needs-stable-identity-restart-semantics-and-retryable-effects -->
<a id="applied-learning-a-cleanup-lease-needs-stable-identity-restart-semantics-and-retryable-effects"></a>
**A cleanup lease needs stable identity, restart semantics, and retryable effects.** A PID-only
temporary lease can die while its owner remains alive, after which treating `:noproc` as
success permanently detaches live authority from revocation. Address leases by a stable
registry key, restart them with recoverable cleanup state, and stop only after authority,
capability, trust, and identity cleanup has succeeded or reached an explicit terminal policy.

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

<!-- applied-learning: killing-a-genserver-call-caller-does-not-remove-a-request-already-queued-in-the-server-mailbox -->
<a id="applied-learning-killing-a-genserver-call-caller-does-not-remove-a-request-already-queued-in-the-server-mailbox"></a>
**Killing a `GenServer.call` caller does not remove a request already queued in the server mailbox.** Async task cancellation must both tombstone the task at the execution boundary and reject queued work whose caller is already dead; otherwise a busy shared agent can execute cancelled work later. This surfaced on 2026-07-09 while closing the `TaskStore -> APIAgent -> Session` cancellation race.

<!-- applied-learning: registry-disappearance-may-lag-synchronous-process-shutdown -->
<a id="applied-learning-registry-disappearance-may-lag-synchronous-process-shutdown"></a>
**Registry disappearance may lag synchronous process shutdown.** `Supervisor.stop/3` waits for the process tree to terminate, but a `Registry.lookup/2`-backed `whereis/1` can briefly retain the registration until its cleanup notification is processed. Tests that assert absence immediately after shutdown should use a short bounded eventual assertion while still checking security state such as identity suspension and capability revocation directly (found 2026-07-10 in exact-policy fail-closed cleanup tests).

<!-- applied-learning: hot-loading-a-genserver-module-does-not-migrate-its-running-state -->
<a id="applied-learning-hot-loading-a-genserver-module-does-not-migrate-its-running-state"></a>
**Hot-loading a GenServer module does not migrate its running state.** A recompiled callback can expect new struct fields while the live process still holds the old map, causing writes to fail long after code loading reports success. Before exercising a hot-loaded stateful subsystem, compare `:sys.get_state/1` keys with the current struct; use an explicit in-place state migration when semantics are clear, or restart under its supervisor only when persisted reconstruction is safe. Do not restart a memory-backed policy store casually (found 2026-07-10 when `Arbor.Trust.Store` lacked newly added durable-backend fields after hot reload).

<!-- applied-learning: publish-terminal-state-before-invoking-optional-cleanup-infrastructure -->
<a id="applied-learning-publish-terminal-state-before-invoking-optional-cleanup-infrastructure"></a>
**Publish terminal state before invoking optional cleanup infrastructure.** `Task.Supervisor.start_child/5` starts the child body asynchronously, but the call to the supervisor is synchronous and can itself stall. A task owner must commit result/status first, then hand cleanup scheduling to a named, non-closure launcher so an unhealthy cleanup supervisor cannot delay result availability (found 2026-07-11 in the second terminal-approval cleanup council review).

<!-- applied-learning: a-key-owning-broker-must-authenticate-lease-acquisition-not-only-lease-use -->
<a id="applied-learning-a-key-owning-broker-must-authenticate-lease-acquisition-not-only-lease-use"></a>
**A key-owning broker must authenticate lease acquisition, not only lease use.** An unguessable bearer token prevents reference forgery after issuance, but `open(agent_id)` still becomes a sign-as-any-principal deputy when the broker can resolve every stored key. Require fresh cryptographic possession proof bound to the principal, purpose, and actual owner at acquisition; verify it through the existing nonce/freshness path, and never retain the proof, signer callback, or raw key in broker state (found 2026-07-11 reviewing the first reload-stable signing-authority slice).

<!-- applied-learning: process-monitors-do-not-require-trapping-exits -->
<a id="applied-learning-process-monitors-do-not-require-trapping-exits"></a>
**Process monitors do not require trapping exits.** A GenServer that sets `Process.flag(:trap_exit, true)` only to monitor unrelated owners can convert its supervisor's shutdown signal into an ignored `{:EXIT, ...}` message, delaying termination until the supervisor kills it. Use monitors for owner lifecycle and leave linked supervisor exits at the OTP default unless the process has an explicit linked-exit protocol (found 2026-07-11 reviewing the signing-authority broker).

<!-- applied-learning: derived-summaries-cannot-replace-independently-recorded-cleanup-evidence -->
<a id="applied-learning-derived-summaries-cannot-replace-independently-recorded-cleanup-evidence"></a>
**Derived summaries cannot replace independently recorded cleanup evidence.** If run-root cleanup is observed only while building a summary, later acceptance recomputation may incorrectly infer it from pair cleanup and let a coordinated summary rewrite forge success. Retain each security-relevant lifecycle observation outside caller-editable aggregates, require it in the closed report schema, and derive the summary from that evidence (found 2026-07-11 reviewing coding benchmark acceptance integrity).

<!-- applied-learning: trace-the-actual-external-process-owner-on-every-execution-branch-before-claiming-tree-cleanup -->
<a id="applied-learning-trace-the-actual-external-process-owner-on-every-execution-branch-before-claiming-tree-cleanup"></a>
**Trace the actual external-process owner on every execution branch before claiming tree cleanup.** In the pinned Bash/ExCmd path, the Session owns ordinary foreground `ExCmd.Process` instances, while background jobs introduce a `JobProcess` and a separate worker that creates ExCmd; killing the Session is therefore not one uniform cleanup proof. Timeout/cancellation tests must exercise foreground, pipeline, background, and coprocess branches or reject unsupported branches before launch (found 2026-07-11 reviewing CapShell timeout ownership).

<!-- applied-learning: a-genserver-from-tuple-is-protocol-data-not-authenticated-process-identity -->
<a id="applied-learning-a-genserver-from-tuple-is-protocol-data-not-authenticated-process-identity"></a>
**A GenServer `from` tuple is protocol data, not authenticated process identity.** Any local process can send a raw `{:\"$gen_call\", from, request}` message containing another PID, so extracting `elem(from, 0)` cannot prove who submitted an admission, result, or evidence mutation. Keep security-relevant authority inside one owner process or use an opaque owner-generated reference bound to a monitored generation; never authorize from caller-supplied GenServer envelope fields (found 2026-07-11 reviewing the coding benchmark coordinator).

<!-- applied-learning: a-determinate-timeout-requires-proof-that-no-later-commit-can-occur -->
<a id="applied-learning-a-determinate-timeout-requires-proof-that-no-later-commit-can-occur"></a>
**A determinate timeout requires proof that no later commit can occur.** Checking a deadline before a state transform, database lock, or backend mutation is insufficient: the caller can time out while the owner continues and commits afterward. Carry one absolute monotonic deadline through queueing, lock acquisition, work, and commit; post-check before publishing mutable state, use backend-side cancellation for database work, and return an indeterminate outcome whenever commit status cannot be observed exactly (found 2026-07-11 with live Agent, PostgreSQL advisory-lock, and SQLite busy-timeout EventLog probes).

<!-- applied-learning: cleanup-absence-checks-must-distinguish-absent-from-unqueryable -->
<a id="applied-learning-cleanup-absence-checks-must-distinguish-absent-from-unqueryable"></a>
**Cleanup absence checks must distinguish absent from unqueryable.** A boolean helper that maps every failing `git show-ref` or worktree query to `false` can issue a verified receipt while the repository is unavailable. Use tri-state queries, accept only the command's exact not-found outcome as absence, and fail closed on every transport, permission, timeout, or parse error (found 2026-07-11 reviewing workspace cleanup receipts).

<!-- applied-learning: verified-preservation-is-not-verified-cleanup -->
<a id="applied-learning-verified-preservation-is-not-verified-cleanup"></a>
**Verified preservation is not verified cleanup.** Releasing a reused worktree may correctly prove that its path, registration, and branch survived, but that evidence cannot set `cleanup_verified: true` or satisfy a consumer that requires resource removal. Use distinct receipt/status fields and require owned-path absence plus unregistration for cleanup acceptance (found 2026-07-11 reviewing benchmark workspace cleanup evidence).

<!-- applied-learning: secret-bearing-genservers-need-explicit-status-redaction -->
<a id="applied-learning-secret-bearing-genservers-need-explicit-status-redaction"></a>
**Secret-bearing GenServers need explicit status redaction.** Redacted struct `Inspect` implementations do not protect a broker whose raw state map uses bearer tokens as keys or stores session/root private keys. Implement bounded `format_status/2`, keep secrets out of crash metadata and error tuples, and regress `:sys`/status formatting for every authority owner (found 2026-07-11 reviewing verified-request and execution-permit brokers).

<!-- applied-learning: format-status-2-does-not-make-secret-bearing-genserver-state-private -->
<a id="applied-learning-format-status-2-does-not-make-secret-bearing-genserver-state-private"></a>
**`format_status/2` does not make secret-bearing GenServer state private.** It can redact crash/status formatting, but local code can still call `:sys.get_state/1` and receive the raw state. Do not retain bearer tokens or private authority in long-lived GenServer state at all; keep them in a private owner/ETS boundary or consume them entirely inside the exact request process (found 2026-07-11 probing the MCP verified-request handler).

<!-- applied-learning: private-ets-does-not-protect-authority-from-its-owning-genserver-s-sys-callbacks -->
<a id="applied-learning-private-ets-does-not-protect-authority-from-its-owning-genserver-s-sys-callbacks"></a>
**Private ETS does not protect authority from its owning GenServer's `:sys` callbacks.** `:sys.replace_state/2` executes the supplied callback inside the target process, where that callback can read the owner's private ETS tables and exfiltrate a token. A plain sensitive owner that does not implement OTP system messages closes this specific introspection path and is useful Layer-0 defense in depth, but it does not satisfy the T4 same-VM-compromise threat: tracing, code loading, or other first-party calls still run inside the same trusted address space. If T4 is the acceptance criterion, move the authority behind an authenticated OS-process or separate-cluster boundary; moving the token to another GenServer or adding `format_status` is insufficient (found 2026-07-11 exploiting the benchmark RunCoordinator; assurance boundary clarified 2026-07-11).

<!-- applied-learning: a-genserver-wrapper-does-not-make-a-named-dets-table-private -->
<a id="applied-learning-a-genserver-wrapper-does-not-make-a-named-dets-table-private"></a>
**A GenServer wrapper does not make a named DETS table private.** Any same-VM process that knows the table name can call `:dets.lookup/2`, `insert/2`, or `delete/2` directly and bypass the owner's serialized CAS logic. Keep security-authoritative mutable state behind a genuinely private owner boundary, authenticate durable records, and test direct storage mutation; also make record+index transitions reconstructable across crashes (found 2026-07-11 reviewing the local approval backend).

<!-- applied-learning: an-absolute-deadline-needs-an-owner-stamped-completion-time -->
<a id="applied-learning-an-absolute-deadline-needs-an-owner-stamped-completion-time"></a>
**An absolute deadline needs an owner-stamped completion time.** Checking the clock only when a caller receives a result is not enough: a suspended caller can later accept a success that completed after its deadline, while checking only the receive time can reject a result that completed on time. The operation owner must stamp `completed_mono` before sending the result, and the receiver must compare that immutable timestamp with the original deadline; inactivity timeouts are not a substitute (found 2026-07-11 suspending LLM/eval callers across their deadlines).

<!-- applied-learning: caller-timeout-does-not-cancel-a-queued-owner-mutation -->
<a id="applied-learning-caller-timeout-does-not-cancel-a-queued-owner-mutation"></a>
**Caller timeout does not cancel a queued owner mutation.** A bounded `GenServer.call/3` can return timeout while its request remains in the mailbox and later consumes a permit or commits state. Put the caller's absolute deadline inside the request, check it in the owner immediately before mutation, and return indeterminate plus exact reconciliation only when the outcome cannot be proven; the call timeout alone is not the operation deadline (found 2026-07-11 suspending the execution-permit broker).

<!-- applied-learning: exclusive-create-failure-does-not-grant-cleanup-ownership -->
<a id="applied-learning-exclusive-create-failure-does-not-grant-cleanup-ownership"></a>
**Exclusive-create failure does not grant cleanup ownership.** If `File.mkdir/1` returns `:eexist`, the caller must reject or retry without deleting that path; an unconditional `after`/error cleanup can erase an attacker-created or concurrent invocation's directory even though this invocation never owned it. Carry an explicit created/owned identity into cleanup, verify that identity before removal where feasible, and regress a pre-existing path with a marker that must survive the fail-closed result (found 2026-07-13 probing the tree-binding private-root collision path).

<!-- applied-learning: a-late-identity-observation-cannot-prove-exclusive-create-ownership -->
<a id="applied-learning-a-late-identity-observation-cannot-prove-exclusive-create-ownership"></a>
**A late identity observation cannot prove exclusive-create ownership.** After creating a cleanup root, capture its stable device/inode/type identity before doing work. If that first capture fails, leave the path in place and fail closed; recapturing an identity during cleanup can observe a replacement path and incorrectly authorize its deletion (found 2026-07-13 proving the tree-binding cleanup regression against its prior revision).

<!-- applied-learning: a-correlation-token-placed-in-a-timer-message-is-not-the-cancellation-handle -->
<a id="applied-learning-a-correlation-token-placed-in-a-timer-message-is-not-the-cancellation-handle"></a>
**A correlation token placed in a timer message is not the cancellation handle.** `make_ref()` put into a `Process.send_after/3` payload cannot be cancelled with `Process.cancel_timer/1` — that API needs the reference *returned by* `send_after/3` (or prefer `:erlang.start_timer/3`, whose delivered `{:timeout, timer_ref, payload}` carries the same cancellable ref). On cleanup/reset, cancel the real handle and non-blockingly flush an already-delivered exact timeout message so completion races do not surface as unexpected `handle_info/2` traffic; regress by suspending after a fast successful prompt and asserting the mailbox is free of hard/inactivity timer messages (found 2026-07-14 in `AcpSession` / live `task_83651`).

<!-- applied-learning: a-permanent-startup-pinned-child-must-not-treat-its-process-restart-as-a-new-trust-epoch -->
<a id="applied-learning-a-permanent-startup-pinned-child-must-not-treat-its-process-restart-as-a-new-trust-epoch"></a>
**A permanent startup-pinned child must not treat its process restart as a new trust epoch.** Under `rest_for_one`, an authority that stops on identity drift is restarted from its original child spec; naively rereading the filesystem then accepts the changed artifact as the new baseline after one failed checkout. Carry an application-generated boot epoch through the child spec, retain only the original binding fingerprint plus a poison marker across child restarts, and clear it only when the application stops. Regress both downstream owner turnover and persistent poison/no-repin behavior (found 2026-07-14 reviewing the Apple control-plane authority).

<!-- applied-learning: genserver-format-status-1-cannot-sanitize-an-explicitly-enabled-sys-debug-ring -->
<a id="applied-learning-genserver-format-status-1-cannot-sanitize-an-explicitly-enabled-sys-debug-ring"></a>
**`GenServer.format_status/1` cannot sanitize an explicitly enabled `:sys` debug ring.** OTP passes the callback a redacted status map, but `:sys.get_status/1` also returns the raw debugger state outside that callback; after `:sys.log(pid, true)`, it can contain prior messages, replies, and GenServer states. Redact `:state`, `:message`, `:reason`, and `:log` for ordinary status/crash formatting, but do not claim this hides secrets from same-BEAM callers: they can also use `:sys.get_state/1`, tracing, or code injection at the currently conceded T4 boundary. Never enable `:sys` logging on a secret/authority owner in production diagnostics (verified 2026-07-14 while testing control-plane status redaction).

<!-- applied-learning: a-genserver-owner-monitor-does-not-interrupt-a-busy-callback -->
<a id="applied-learning-a-genserver-owner-monitor-does-not-interrupt-a-busy-callback"></a>
**A GenServer owner monitor does not interrupt a busy callback.** A queued `:DOWN` message cannot stop a worker that is copying or hashing inside `handle_call/3`; check owner liveness and the absolute deadline inside every bounded loop. If owner-death cleanup fails, retain the worker, root identity, and retry authority until absence is proven rather than stopping and forgetting the resource (found 2026-07-14 hardening the Linux dependency-baseline materialization lease).

<!-- applied-learning: cleanup-of-a-writable-leased-tree-must-unlink-without-following-and-never-fall-back-to-unverified-recursion -->
<a id="applied-learning-cleanup-of-a-writable-leased-tree-must-unlink-without-following-and-never-fall-back-to-unverified-recursion"></a>
**Cleanup of a writable leased tree must unlink without following and never fall back to unverified recursion.** Validation can add symlinks, sockets, FIFOs, or other special entries after materialization, so cleanup must `lstat` and unlink each entry itself. If identity changes or any bounded deletion step fails, retain cleanup authority and return a retryable error; a later `File.rm_rf/1` fallback can race with path replacement and delete a different tree (found 2026-07-14 reviewing the Linux dependency-baseline materializer).

<!-- applied-learning: do-not-project-an-ownership-parent-beside-its-typed-child-mounts -->
<a id="applied-learning-do-not-project-an-ownership-parent-beside-its-typed-child-mounts"></a>
**Do not project an ownership parent beside its typed child mounts.** Actions kept `candidate-runtime` as the private cleanup parent for `home`, `tmp`, `build`, runner, and result artifacts; projecting both the parent and selected children created overlapping mount sources and would expose the unselected control artifacts. Keep ownership/cleanup roots private and project only the least-privilege typed children a workload needs (found 2026-07-14 composing Actions validation resources with the Apple Container planner).

<!-- applied-learning: an-operation-deadline-never-authorizes-abandoning-owned-cleanup -->
<a id="applied-learning-an-operation-deadline-never-authorizes-abandoning-owned-cleanup"></a>
**An operation deadline never authorizes abandoning owned cleanup.** Stop admitting setup or candidate work once the original absolute budget expires, but retain a supervised cleanup owner and retry bounded teardown until positive absence is proven. This may outlive the caller's operation budget, as the materializer already does; returning on the deadline while a named containment unit may remain would turn timeout into a containment bypass (confirmed 2026-07-14 designing the Apple Container unit worker).

<!-- applied-learning: a-supervised-genserver-cannot-defer-parent-shutdown-from-handle-info-2 -->
<a id="applied-learning-a-supervised-genserver-cannot-defer-parent-shutdown-from-handle-info-2"></a>
**A supervised GenServer cannot defer parent shutdown from `handle_info/2`.** OTP consumes the parent-supervisor exit and enters the behavior's termination path; trapping exits does not turn that parent exit into an ordinary callback message. If children must continue their normal asynchronous lifecycle while sibling infrastructure remains alive, place a later drain coordinator in the parent supervision order: its shutdown callback requests child cleanup before their supervisor is stopped and waits for exact completion receipts. Do not hide an unbounded ownership requirement inside a finite `terminate/2` drain (found 2026-07-14 when the Apple unit worker died before its proposed `handle_info({:EXIT, ...})` cleanup path ran).

<!-- applied-learning: a-bounded-cleanup-handshake-is-not-cleanup-completion -->
<a id="applied-learning-a-bounded-cleanup-handshake-is-not-cleanup-completion"></a>
**A bounded cleanup handshake is not cleanup completion.** A `GenServer.call` timeout or exit can mean the worker is temporarily unresponsive, died without proof, or accepted the request but lost the reply. Keep every owned worker unresolved under the same exact receipt token, retry bounded handshakes as needed, and release shutdown only on the positive-absence receipt; dropping handshake failures from the pending set turns unresponsiveness into a containment bypass (found 2026-07-14 reviewing the Apple unit drain coordinator).

<!-- applied-learning: linearize-starts-through-the-owner-that-snapshots-shutdown-work -->
<a id="applied-learning-linearize-starts-through-the-owner-that-snapshots-shutdown-work"></a>
**Linearize starts through the owner that snapshots shutdown work.** A later drain coordinator cannot safely snapshot a `DynamicSupervisor` if another public path can add a child after that snapshot. Route production starts through the coordinator's `GenServer.call`, derive the real controller from the `from` tuple, and make reply-loss waiting children expire before they can create anything. A callback that successfully starts a child completes before supervised `terminate/2`, while calls arriving during termination cannot create late work (found 2026-07-14 closing the Apple unit shutdown race).

<!-- applied-learning: a-missing-supervisor-is-not-an-empty-ownership-snapshot -->
<a id="applied-learning-a-missing-supervisor-is-not-an-empty-ownership-snapshot"></a>
**A missing supervisor is not an empty ownership snapshot.** Under `rest_for_one`, the failed earlier child is already dead when later drain coordinators terminate. Returning `[]` when its registry/supervisor is missing turns unknown owned work into success, and waiting on cleanup through that failed transport can deadlock the restart forever. Consult durable ownership records, use an independent recovery transport, and require positive absence receipts; never equate `:noproc`, child `DOWN`, or a failed snapshot call with no resources (found 2026-07-14 reviewing Apple unit crash recovery).

<!-- applied-learning: project-lifecycle-provenance-explicitly-never-infer-it-from-a-result-payload -->
<a id="applied-learning-project-lifecycle-provenance-explicitly-never-infer-it-from-a-result-payload"></a>
**Project lifecycle provenance explicitly; never infer it from a result payload.** A terminal result shaped like `{:execution_owner_down, ...}` is an implementation convention, not proof of who committed the transition. Record a bounded source enum in the same owner transition that writes status/result/completion time, then require that provenance at safety-sensitive consumers (found 2026-07-15 composing the Apple executor with `ExecutionRegistry`).

<!-- applied-learning: a-synchronous-facade-must-not-drain-and-requeue-its-caller-s-mailbox-while-waiting-for-one-owned-signal -->
<a id="applied-learning-a-synchronous-facade-must-not-drain-and-requeue-its-caller-s-mailbox-while-waiting-for-one-owned-signal"></a>
**A synchronous facade must not drain and requeue its caller's mailbox while waiting for one owned signal.** Catch-all receive loops reorder unrelated traffic relative to concurrently arriving messages, can retain it without bound, and violate caller ownership. Use selective receive for the exact PID/ref/id patterns and leave every unrelated message in place; after a stronger positive-absence proof, demonitor only the exact ref with `[:flush]` (found 2026-07-15 reviewing the Apple executor terminal wait).

<!-- applied-learning: authenticate-resume-before-any-existence-bearing-lifecycle-lookup -->
<a id="applied-learning-authenticate-resume-before-any-existence-bearing-lifecycle-lookup"></a>
**Authenticate resume before any existence-bearing lifecycle lookup.** Checking RunJournal admission before checkpoint identity returned `:not_found` to an unauthenticated caller and bypassed the intended security regression. Gate resume/recovery on derived checkpoint identity first, then validate takeover status/principal, and make takeover tests supply identity so they reach the gate they claim to test (found 2026-07-15 during final L3C validation).

<!-- applied-learning: engine-ownership-metadata-is-owner-issued-not-caller-selectable -->
<a id="applied-learning-engine-ownership-metadata-is-owner-issued-not-caller-selectable"></a>
**Engine ownership metadata is owner-issued, not caller-selectable.** A caller-supplied `:spawning_pid` can keep a dead run looking live if Engine copies it into lifecycle state. Bind the run owner to the actual Engine process at the trusted execution boundary, and make any auxiliary ticker monitor that owner directly: an owner-side `after` block does not run after an untrappable `:kill` (found 2026-07-15 while proving L4A process-death windows).

<!-- applied-learning: worktree-cleanup-is-idempotent-only-after-both-filesystem-and-git-registration-absence-are-proven -->
<a id="applied-learning-worktree-cleanup-is-idempotent-only-after-both-filesystem-and-git-registration-absence-are-proven"></a>
**Worktree cleanup is idempotent only after both filesystem and Git-registration absence are proven.** A missing directory can still have a live detached `git worktree` registration, and a parser that accepts only branch-bearing entries will misclassify that evidence as absent. Parse every bounded inventory entry for its path independently of branch state; retry cleanup as success only when the path and exact canonical registration are both positively absent (found 2026-07-16 rerunning the retained-workspace validation suite).

<!-- applied-learning: a-restartable-registry-must-not-be-the-sole-owner-of-child-cleanup-authority -->
<a id="applied-learning-a-restartable-registry-must-not-be-the-sole-owner-of-child-cleanup-authority"></a>
**A restartable registry must not be the sole owner of child cleanup authority.** Process-local maps disappear on registry restart, and process-bound opaque leases cannot be transferred to the replacement process. Put each multi-part validation resource under a separately supervised owner that monitors the registry, acquires/releases the opaque Shell lease itself, retains every filesystem/Git identity, and cleans on registry death; the registry keeps only an authorized handle and public projection (found 2026-07-16 reviewing validation-resource restart cleanup).

<!-- applied-learning: filesystem-fixture-names-must-outlive-neither-vm-local-uniqueness-nor-cleanup-ownership -->
<a id="applied-learning-filesystem-fixture-names-must-outlive-neither-vm-local-uniqueness-nor-cleanup-ownership"></a>
**Filesystem fixture names must outlive neither VM-local uniqueness nor cleanup ownership.** `System.unique_integer/1` restarts with a new VM, so a root that survives a failed run can collide with a later VM. Use cryptographic randomness for names that outlive one BEAM, record cleanup ownership, and remove only resources owned by that fixture (found 2026-07-16 rerunning the full Actions suite and 2026-07-19 during Grok containment work).

<!-- applied-learning: recursive-cleanup-must-be-bounded-and-progressive -->
<a id="applied-learning-recursive-cleanup-must-be-bounded-and-progressive"></a>
**Recursive cleanup must be bounded and progressive.** Identity binding and symlink rejection prevent deleting the wrong root, but an attacker-controlled tree can still exhaust shutdown time or memory through depth and entry count. Give each attempt explicit entry, depth, and wall-clock budgets; delete only proven non-directory entries without following links; preserve the identity after budget exhaustion so retries make bounded forward progress (found 2026-07-15 reviewing validation-resource cleanup).

<!-- applied-learning: monitor-separately-supervised-resource-owners-in-both-directions -->
<a id="applied-learning-monitor-separately-supervised-resource-owners-in-both-directions"></a>
**Monitor separately supervised resource owners in both directions.** A child owner monitoring its registry closes registry-crash leaks, but the registry must also monitor the owner so an isolated owner crash cannot leave stale public handles and resources. On either death, the survivor uses retained identities to converge cleanup while preserving the parent workspace (found 2026-07-15 reviewing validation-resource cleanup).

<!-- applied-learning: an-arbitrary-traversal-depth-ceiling-is-not-progressive-cleanup -->
<a id="applied-learning-an-arbitrary-traversal-depth-ceiling-is-not-progressive-cleanup"></a>
**An arbitrary traversal-depth ceiling is not progressive cleanup.** Retrying from the root reaches the same deep branch and fails forever. Bound portable traversal by the already enforced absolute-path byte ceiling and total entry/time/memory budgets; do not introduce a directory-rename shortcut merely to reset depth, because portable rename cannot bind the expected source inode and no-replace destination atomically (found 2026-07-15 closing validation-tree cleanup liveness).

<!-- applied-learning: failure-acquisition-must-return-cleanup-evidence-with-the-opaque-lease -->
<a id="applied-learning-failure-acquisition-must-return-cleanup-evidence-with-the-opaque-lease"></a>
**Failure acquisition must return cleanup evidence with the opaque lease.** A composite owner can retain a Shell lease after `cleanup_required` or malformed-view rollback, then die before release. Return a bounded locator from the same trusted acquisition operation and store it before replying, so the surviving registry can prove the Shell worker's root disappeared without receiving or reconstructing lease authority (found 2026-07-15 closing validation-owner crash convergence).

<!-- applied-learning: fail-closed-cleanup-retries-still-need-a-dormant-terminal-state -->
<a id="applied-learning-fail-closed-cleanup-retries-still-need-a-dormant-terminal-state"></a>
**Fail-closed cleanup retries still need a dormant terminal state.** A deterministic identity mismatch, path ceiling, or enumeration-memory failure must retain evidence, but retrying it every few seconds forever leaks timers and consumes work without improving authority. Bound automatic attempts, preserve every destructive token and opaque lease, expose dormant status for explicit recovery, and allow manual or later supervisor cleanup to retry (found 2026-07-15 closing validation-owner cleanup churn).

<!-- applied-learning: a-supervised-genserver-can-reach-terminate-2-without-handling-the-supervisor-s-exit-tuple-first -->
<a id="applied-learning-a-supervised-genserver-can-reach-terminate-2-without-handling-the-supervisor-s-exit-tuple-first"></a>
**A supervised GenServer can reach `terminate/2` without handling the supervisor's `EXIT` tuple first.** `DynamicSupervisor.terminate_child/2` may drive system termination directly, and named ancestors can appear as atoms in `:"$ancestors"`. Resolve named ancestors to their PID, perform bounded cleanup from both paths, and use a process-local attempted marker so the cleanup runs exactly once (found 2026-07-15 testing validation-owner dormant recovery).

<!-- applied-learning: bound-retries-at-every-owner-layer-not-only-at-the-composite-registry -->
<a id="applied-learning-bound-retries-at-every-owner-layer-not-only-at-the-composite-registry"></a>
**Bound retries at every owner layer, not only at the composite registry.** A higher-level validation owner can become dormant correctly while its lower Shell materializer continues an independent owner-death timer loop forever. Every process that retains destructive identity must own its own bounded retry counter and dormant state; supervisor teardown or an explicit recovery surface may retry later without background churn (found 2026-07-15 reviewing nested validation cleanup ownership).

<!-- applied-learning: a-synchronous-durability-acknowledgement-is-also-a-mailbox-boundary-not-lifecycle-authority -->
<a id="applied-learning-a-synchronous-durability-acknowledgement-is-also-a-mailbox-boundary-not-lifecycle-authority"></a>
**A synchronous durability acknowledgement is also a mailbox boundary, not lifecycle authority.** Controls and owner/caller exits can arrive while a GenServer waits for its evidence sink, so re-drain applicable messages against the still-active state before choosing a follow-up or replying. If archival then fails, report the combined evidence error while preserving cancellation teardown and hard/inactivity-timeout recovery plus provider settlement; evidence must never weaken the operation's terminal lifecycle (found 2026-07-16 hardening ACP prompt-turn capture).

<!-- applied-learning: compiled-validation-roots-need-operation-specific-ownedtree-cleanup-bounds -->
<a id="applied-learning-compiled-validation-roots-need-operation-specific-ownedtree-cleanup-bounds"></a>
**Compiled validation roots need operation-specific `OwnedTree` cleanup bounds.** The generic 2,000,000-word listing budget scales down by directory depth, so an ordinary `candidate-runtime/build/lib/<app>/ebin` directory exhausted the depth-five allowance even though cleanup succeeded with the supported 8,000,000-word budget. Keep the exact pinned identity and fail-closed ordering, but call `Arbor.Shell.remove_owned_tree/2` with `listing_heap_words: 8_000_000` and the public maximum `timeout_ms: 10_000` only at the validation-root owner; larger timeout values fail with `:invalid_cleanup_budget` (found 2026-07-17 after a successful validation operation was reported as cleanup failure).

<!-- applied-learning: negative-cleanup-tests-must-snapshot-and-remove-only-their-own-exact-roots -->
<a id="applied-learning-negative-cleanup-tests-must-snapshot-and-remove-only-their-own-exact-roots"></a>
**Negative cleanup tests must snapshot and remove only their own exact roots.** Never clean test artifacts by scanning a shared temporary directory for broad prefixes or by piping matches to `rm -rf`; retained and live resources from unrelated tasks use those same prefixes. Record the exact paths before the negative run, reconstruct or retain their lstat-pinned identities, and remove only that allowlist through the owning public cleanup API. A delegated worker attempted a broad prefix cleanup on 2026-07-17; the ACP client did not execute it, and the two test-created roots were then removed individually through `Arbor.Shell.remove_owned_tree/2`.

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

<!-- applied-learning: quiet-git-ref-probes-do-not-prove-exact-absence -->
<a id="applied-learning-quiet-git-ref-probes-do-not-prove-exact-absence"></a>
**Quiet Git ref probes do not prove exact absence.** `git rev-parse --verify --quiet` returns the same nonzero status for a missing ref and some corrupt or unreadable refs, while localized command text is not a stable error protocol. Observe an exact full ref through structured `for-each-ref` output, reject stderr/warnings and malformed records, and after a compare-and-delete failure re-read the ref: absent is an idempotent success, a different OID is a CAS mismatch, and the same OID is an operational failure (found 2026-07-20 hardening coding-branch discard settlement).

<!-- applied-learning: spawned-development-tools-must-not-inherit-the-parent-mix-runtime -->
<a id="applied-learning-spawned-development-tools-must-not-inherit-the-parent-mix-runtime"></a>
**Spawned development tools must not inherit the parent Mix runtime.** An ACP coding CLI launched by the live `MIX_ENV=dev` Arbor node passed that variable to worker shell commands, so ordinary `./bin/mix test` booted dev configuration, collided with the live Gateway port, and attempted to claim the operator Apple-container journal. Scrub parent build/runtime selectors such as `MIX_ENV` at the process-spawn boundary while preserving explicit worker command overrides; test config cannot protect a test command that never entered the test environment (found 2026-07-20 during delegated branch-lifecycle validation).

<!-- applied-learning: long-acp-tool-operations-must-publish-liveness-before-the-inactivity-deadline -->
<a id="applied-learning-long-acp-tool-operations-must-publish-liveness-before-the-inactivity-deadline"></a>
**Long ACP tool operations must publish liveness before the inactivity deadline.** Piping a broad test run through `grep | tail` buffered every progress byte, so Arbor correctly classified the ACP turn as inactive and recovered the same provider session while the valid test process was still running. Prefer focused suites below the deadline, stream bounded progress from long operations, or run broad validation under a separately supervised owner whose liveness and final result are explicit; a live child process that emits nothing through ACP is observationally indistinguishable from a stuck tool (found 2026-07-20 during branch-lifecycle validation).

<!-- applied-learning: git-ref-cas-and-worktree-checkout-protection-are-distinct-invariants -->
<a id="applied-learning-git-ref-cas-and-worktree-checkout-protection-are-distinct-invariants"></a>
**Git ref CAS and worktree checkout protection are distinct invariants.** `git update-ref -d <ref> <expected-oid>` atomically rejects an OID replacement, but it will delete a branch currently checked out in another worktree; the porcelain `git branch -D` guard is not part of the plumbing command. Branch retirement therefore needs both exact-OID authority and explicit checked-out-worktree protection, with conservative postcondition/recovery handling for races between observation and deletion (verified 2026-07-20 while reviewing coding-branch discard settlement).
