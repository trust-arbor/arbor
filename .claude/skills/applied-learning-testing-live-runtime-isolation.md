# Applied Learning: Test Isolation and Fixtures

Read this when writing or fixing ExUnit tests that touch global state, supervised services, fakes, fixtures, distribution, or test timing.

## Retained Applied Learning

<!-- applied-learning: spawned-processes-do-not-inherit-process-dictionaries-and-shared-fakes-require-cleanup-convergence -->
<a id="applied-learning-spawned-processes-do-not-inherit-process-dictionaries-and-shared-fakes-require-cleanup-convergence"></a>
**Spawned processes do not inherit process dictionaries, and shared fakes require cleanup convergence.** Pass test observers explicitly or use test-owned ETS; `Process.put/2` in the test process is invisible to spawned router workers. When a deliberate owner kill triggers asynchronous monitored cleanup, wait for close/absence before replacing a named Agent/ETS backend, or late callbacks can contaminate the next randomized test (found 2026-08-03 while stabilizing VP-04E3 voice tool lifecycle tests).

<!-- applied-learning: scope-diagnostic-log-level-overrides-to-the-tested-module -->
<a id="applied-learning-scope-diagnostic-log-level-overrides-to-the-tested-module"></a>
**Scope diagnostic log-level overrides to the tested module.** CaptureLog filtering does not lower the producer's global warning threshold. For INFO diagnostic assertions, serialize the tests, save the module's existing Logger override, enable INFO only for that module, and restore its exact prior setting on exit. If no override existed, delete the temporary one. Leave production severity and global logger configuration unchanged. (Extracted 2026-10-16 from independently-rerun-delegated-verification-against-the-committed-revision; first found 2026-10-05.)

<!-- applied-learning: test-applications-can-be-running-while-required-children-are-deliberately-absent -->
<a id="applied-learning-test-applications-can-be-running-while-required-children-are-deliberately-absent"></a>
**Test applications can be running while required children are deliberately
absent.** `MIX_ENV=test` commonly starts an application supervisor with
`start_children: false`; a direct diagnostic that needs a child such as
`Arbor.Shell.ExecutionRegistry` must start that test-owned child explicitly.
Checking only `Application.started_applications/0` can misdiagnose a missing
child as a broken API. A subprocess regression for a documented production
Mix command must instead run with the production/dev topology; launching it
under `MIX_ENV=test` only proves the intentional child suppression (found
2026-07-13 during Phase 6 shell diagnostics; recurred 2026-08-11 in the
source-coupling standalone-task regression).

A real long-running Session fixture must also own the production authority-audit
consumer and a private durable SQL target. An observational security event-log
adapter does not deliver the authority-mutation journal. In the 2026-10-03
conversation journey, 1,024 undelivered effect-applied operations exhausted
reserved soft capacity; the final turn failed although it passed alone. Preserve
the no-consumer failure, add the real consumer, and prove content readback and
acknowledgement rather than increasing limits or resetting the journal.

A suppressed child therefore fails far from its cause. On 2026-09-29, with
Historian's `AuthorityAuditPuller` suppressed, nothing acknowledged Security
audit deliveries, so about 1,024 grants into a long suite every grant returned
`:audit_unavailable` (`:soft_capacity_exhausted`) while each file passed alone.
`Arbor.Security.TestBootstrap.start!/1` has started
`Arbor.Security.TestAuditConsumer` in every test BEAM since 2026-10-07. For a
failure that only appears in full-suite runs, log the refusing process's
counters (`Security.audit_journal_status/0`,
`Security.capability_mutation_audit_status/0`) at the first failure before
bisecting test files.

<!-- applied-learning: when-a-supervised-child-gains-a-prerequisite-update-every-manual-test-stack-in-dependency-order -->
<a id="applied-learning-when-a-supervised-child-gains-a-prerequisite-update-every-manual-test-stack-in-dependency-order"></a>
**When a supervised child gains a prerequisite, update every manual test stack in dependency order.**
`SigningAuthorityBroker` now depends on `SigningAuthorityStateOwner`; app supervision starts
them correctly, but Orchestrator and Agent tests that manually started only the broker failed
far from setup with `:broker_unavailable`. Search all `start_child` helpers whenever a child
spec gains a sibling prerequisite, and keep isolated test files independent of suite order.
For token-coupled pairs, create one opaque token, pass it to both children under their respective
option names, start the owner first, and restart an existing dependent child through its supervisor.

<!-- applied-learning: do-not-run-real-process-setup-deadline-tests-under-asynchronous-suite-load -->
<a id="applied-learning-do-not-run-real-process-setup-deadline-tests-under-asynchronous-suite-load"></a>
**Do not run real process-setup deadline tests under asynchronous suite load.** An absolute timeout correctly includes native launcher and process-group setup, so a very small budget can expire before execution when dozens of async tests contend for the scheduler; that tests suite load, not command teardown. Run real OS lifecycle tests serially and give setup a conservative budget while keeping the command duration far beyond it, then assert the exact timeout result and process death (found 2026-07-14 when the full Shell suite intermittently returned `:timeout_during_setup` from the PortSession timeout regression).

Apply this policy to real BEAM watchdog tests too. Distinguish the original
remaining retirement interval from an incorrectly renewed interval with enough
separation for scheduler delay, then repeat the focused checks in fresh processes.
A focused pass followed by a combined-run timing miss is evidence to inspect,
not a reason to retry unchanged or lengthen product deadlines; timing alone
does not identify parallel contention as its cause (2026-10-05).

A trace observation timeout also includes signing-authority setup. Compare the
exact predecessor first, then use a bounded test observation interval without
changing product deadlines or authorization assertions (2026-10-06: both accepted
ActionRuntime fixtures missed the default 100 ms interval; 2,000 ms preserved
the existing 3,000 ms task deadline and passed on both revisions).

<!-- applied-learning: a-module-global-test-fake-must-not-be-linked-to-an-arbitrary-per-test-process -->
<a id="applied-learning-a-module-global-test-fake-must-not-be-linked-to-an-arbitrary-per-test-process"></a>
**A module-global test fake must not be linked to an arbitrary per-test process.** `ensure_started/0` plus `GenServer.start_link/3` can find the prior test's still-registered process just before that owner exits, then race into `:noproc` on the following call and cascade unrelated failures. Put shared fakes under a suite-stable supervisor/owner or start them unlinked with explicit reset/cleanup; per-test resources may remain linked to the test process unless cleanup must read them after exit (found 2026-07-14 in the Apple unit-worker held-absence suite). ExUnit exits tests with `:shutdown` before running `on_exit` in a separate process. Do not keep cleanup snapshots or a final-drain tracer only in test-linked processes; use a lifetime that spans the callback with explicit cleanup ownership, and cover partial setup failure as well as normal teardown. `start_supervised!` children also stop before `on_exit`, so supervision alone does not solve that lifetime requirement (confirmed against ExUnit 1.19.5 source while reviewing J0 on 2026-09-07).

<!-- applied-learning: exunit-setup-callbacks-cannot-dynamically-skip-a-test -->
<a id="applied-learning-exunit-setup-callbacks-cannot-dynamically-skip-a-test"></a>
**ExUnit setup callbacks cannot dynamically skip a test.** `setup` / `setup_all` accept only `:ok`, a context map/keyword list, or `{:ok, context}`; returning `{:skip, reason}` fails instead of skipping on the host where the prerequisite is absent. Compute the prerequisite at test compilation and attach a conditional `skip:` tag to only the affected tests or describes, leaving prerequisite-independent security regressions runnable (found 2026-07-14 making the macOS `shlock` journal tests portable).

<!-- applied-learning: configure-a-replacement-test-process-before-an-observer-can-discover-it -->
<a id="applied-learning-configure-a-replacement-test-process-before-an-observer-can-discover-it"></a>
**Configure a replacement test process before an observer can discover it.** Starting a named fake with permissive/default behavior and then resetting it in a second call creates a race: a monitored coordinator can resolve and invoke the replacement between those operations. Start the fake atomically in its intended mode, or suspend the observer across replacement setup and resume it afterward; otherwise a deterministic turnover regression can fail or, worse, pass through unintended behavior (found 2026-07-15 in the Apple reconciler-PID turnover test). Native/device tests must make real fallback impossible before calling the tested API. Mock expectations do not prove dependency interception was compiled in: verify the loaded fake module/NIF provenance in a fresh process, and abort if the real native boundary can resolve. A missed Mockery interception reached PortAudio initialization in an isolated ownership harness on 2026-09-27; three calls had recorded pre-open errors and a fourth discarded its result, so absence of capture could not be claimed categorically. Detect the actual OS before applying a platform permission gate; on that OS, a missing module or failed NIF load is denial, not evidence that the permission does not apply (2026-09-27 bounded capture review).

<!-- applied-learning: a-hermetic-test-must-replace-the-runner-seam-the-code-actually-consumes -->
<a id="applied-learning-a-hermetic-test-must-replace-the-runner-seam-the-code-actually-consumes"></a>
**A hermetic test must replace the runner seam the code actually consumes.** Setting `:mix_shell_module` did not make `CrossAppTest` hermetic because `CrossAppShell` independently defaulted `:cross_app_mix_runner` to production `MixAction.run_mix/3`; under an external contained build root, production wrapper discovery correctly failed closed before the configured test shell ran. Trace the invocation from suite setup through the final subprocess boundary, install and restore the narrow test-only runner there, and leave production wrapper-authority tests on the production path. Assert that the seam received the exact structured request and performed the intended effect; checking only a sealed/result shape can make a dead or fail-closed execution path look green (found 2026-07-18 during contained validation of `task_234818`; reinforced 2026-07-23 when deterministic-evaluator tests never proved Mix ran).

<!-- applied-learning: contained-durable-store-fixtures-need-a-private-trusted-parent -->
<a id="applied-learning-contained-durable-store-fixtures-need-a-private-trusted-parent"></a>
**Contained durable-store fixtures need a private trusted parent.** In the Linux guest, `System.tmp_dir!()` can be `/tmp`, whose parent permissions intentionally fail production durable-root safety before the behavior under test. Build security fixtures beneath `ActionCase`'s per-test `tmp_dir` so the real parent check stays enabled and the intended poison or budget condition is reached; never add `:parent_permissions_unsafe` to an unrelated assertion merely to make the test pass (found 2026-07-18 in `WorkspaceRetentionRestartTest`).

Before launching a fixture, validate the relationships between its explicit
private root and fresh environment paths, not only their permissions. If the
helper requires `ARBOR_HOME` within `private_root`, derive it from that same
root; a private sibling still fails containment. The pair prerequisite rejected
`out/actual-pair-state` with `ARBOR_HOME=out/arbor-home` before runtime setup
(2026-10-04). Preserve that refusal and correct the driver paths while retaining
the helper's containment gate.

<!-- applied-learning: do-not-make-optional-runtime-packaging-directories-a-test-prerequisite -->
<a id="applied-learning-do-not-make-optional-runtime-packaging-directories-a-test-prerequisite"></a>
**Do not make optional runtime packaging directories a test prerequisite.** An Elixir installation may omit an empty `.mix/archives` directory until an archive is installed; the contained Linux image did while the developer installation did not. Test the authority and path-placement contract, and only validate directory type when the optional path exists (found 2026-07-18 in `MixSpawnContainmentSlice1Test`).

<!-- applied-learning: task-history-observations-need-a-storage-barrier-and-monotonic-event-order -->
<a id="applied-learning-task-history-observations-need-a-storage-barrier-and-monotonic-event-order"></a>
**Task-history observations need a storage barrier and monotonic event order.** A cast-only audit signal can lose a race with the response that wakes its owner, and wall-clock timestamps can tie even at microsecond precision. Store task-correlated lifecycle signals before wake-up, attach an emitter-owned monotonic sequence, and aggregate by `{timestamp, sequence}`; terminal result fields are fallback evidence, not event history (found 2026-07-19 repairing rework/approval benchmark counts).

<!-- applied-learning: async-generated-exunit-tests-must-compile-shared-helper-modules-in-setup-all -->
<a id="applied-learning-async-generated-exunit-tests-must-compile-shared-helper-modules-in-setup-all"></a>
**Async generated ExUnit tests must compile shared helper modules in `setup_all`.** A
generated S3 detector test compiled the same detector module in per-test `setup`; its
positive and false-positive tests could run concurrently, redefining the module and
intermittently failing an otherwise unrelated validation shard. Compile immutable shared
modules once per generated test module, and leave only per-test resources in `setup`
(found 2026-07-19 during cross-app validation of the legacy council authority fix).

<!-- applied-learning: fault-injection-stores-must-faithfully-perform-every-operation-they-report-as-successful -->
<a id="applied-learning-fault-injection-stores-must-faithfully-perform-every-operation-they-report-as-successful"></a>
**Fault-injection stores must faithfully perform every operation they report as successful.** A fail-after-N persistence double that returns `:ok` without storing the value creates an impossible durable state and invalidates crash-ordering regressions. Implement the normal success effect, arm failure counts relative to an explicit mode switch, and test the double's contract independently before relying on it to prove a state-machine invariant (found 2026-07-21 while validating discard-journal persistence failure).

When extending a one-turn fixture to queued or repeated turns, inspect its
incremental read contract too. A known-empty transcript reader must support the
legitimate `[after: 0]` refresh after an internal-only consultation, as well as
bootstrap `[]`; observe the requested options in the test. Do not advance the
canonical cursor for hidden records or weaken production freshness checks to
accommodate a fake's missing clause (2026-09-30 Voice consultation qualification).

When extending a fixture across targets, inspect request-ID ownership before
reusing its seed commands. Conversation request IDs identify one command for
the principal across targets; changing the target cannot repurpose an admitted
ID. Use distinct IDs for independent turns and deliberately assert that a
cross-target reuse remains refused. The actual two-Branch fixture on 2026-10-04
failed at the second target's first admission with `:command_conflict` because
both seeds reused the same 22 IDs. Target-specific fixture IDs repaired setup
without weakening the production idempotency or scope checks.

For authenticated multi-turn security tests, a successful append must be visible
to the next scoped transcript read. Prefer a private migrated Repo over a fake
that acknowledges writes without storing them. Check checkpoint semantics before
using restore as a partial state setter: transcript restoration invalidates the
live anchor, so seeding legacy context must not silently discard an established
conversation (2026-09-30 private-goal prompt qualification).

<!-- applied-learning: per-app-and-umbrella-tests-can-exercise-different-optional-runtime-branches -->
<a id="applied-learning-per-app-and-umbrella-tests-can-exercise-different-optional-runtime-branches"></a>
**Choose test launchers that reproduce the intended runtime topology.** Per-app and umbrella runs may load different optional peers and therefore exercise different branches. Test available and unavailable paths deliberately, with the unavailable fallback at least as restrictive as the integrated policy. Use an isolated umbrella or supported owning launcher for production transitive services and full-profile integrations; prove declared child dependency boundaries separately from a fresh child-project build. Do not add providers to safe application specs, widen production dependencies, disable profile gates, or suppress normal pruning merely to repair a launcher. A no-compile flag does not guarantee code-path retention. Preserve normal app-before-helper startup, load only intended helpers where required, and demand genuine ExUnit counts, completed teardown, and normal failure exits. Check each standalone project's own lock and dependency closure. (Merged 2026-10-16 from 3 entries; first found 2026-07-21, last 2026-10-06.)

<!-- applied-learning: negative-start-link-tests-must-trap-linked-init-failures -->
<a id="applied-learning-negative-start-link-tests-must-trap-linked-init-failures"></a>
**Negative `start_link` tests must trap linked init failures.** A GenServer that rejects configuration from `init/1` can propagate the stop reason over the new process link before an assertion observes the public `{:error, reason}` result. In the test process, enable `Process.flag(:trap_exit, true)`, assert the exact returned error, and separately assert that no child side effect began; do not weaken the production fail-closed init path to make the test easier (found 2026-07-21 while proving a mismatched launch-bound Grok model never starts the ACP client).

<!-- applied-learning: aggregate-tests-must-own-dependency-availability-and-global-process-lifecycle -->
<a id="applied-learning-aggregate-tests-must-own-dependency-availability-and-global-process-lifecycle"></a>
**Own and restore every global test dependency and configuration seam.** Run modules that mutate Application env, globally named processes, shared ETS, or GenServer state with async disabled. Inject intended dependency availability and authorizers instead of relying on suite order or accidental service absence. Snapshot each key with Application.fetch_env, preserving absent separately from explicitly configured nil, and register exact restoration before the first mutation. Supervise test-owned processes, while giving cleanup observers lifetimes that span teardown. Restore interdependent resources synchronously in dependency order; process shutdown alone does not prove backend cleanup or connection check-in completed. Use private migrated databases, verify effective Repo paths and ancillary adapters, and serialize lanes sharing storage or builds. Keep persistence alive through public identity retirement and its acknowledgement, then stop owners. Preserve a primary failure when best-effort cleanup fails; publish success only after confirmed cleanup and normal shutdown. Prove restoration with a clean dependent case after the faulting case. (Merged 2026-10-16 from 4 entries; first found 2026-07-19, last 2026-10-08.)

<!-- applied-learning: direct-engine-fixtures-must-seed-owner-computed-budget-context -->
<a id="applied-learning-direct-engine-fixtures-must-seed-owner-computed-budget-context"></a>
**Direct Engine fixtures must seed owner-computed budget context.** Production
owners can validate a plan, allocate stage budgets, and project dotted context
keys before invoking a packaged graph. A test that calls `Engine.run/2` directly
bypasses that boundary and can make a sound graph fail broadly because required
budget keys are absent. Build the fixture through the same pure budget policy and
seed every owner-projected key; assertions about a stage timeout must target the
effective allocated cap, not the uncapped request supplied before allocation
(found 2026-07-28 when terminal-gate budgeting exposed 58 stale direct-pipeline
fixture failures). The same rule applies to semantic-preflight helpers:
derive profile-specific validation timeouts through `Profiles` and
`ValidationProgram`, because default/cross-app and security-regression have
different ceilings under the same plan budget (reinforced 2026-07-28 after a
generic 600-second fixture default caused nine base-identical failures). The
same residual-deadline rule applies to production dispatch: a 600-second child
ceiling does not create 600 seconds when worker and review stages have consumed
most of a 15-minute task budget. Size `budgets.wall_clock_ms` for those stages
plus both cold isolated validation legs, or capacity will fail closed before
the selected test runs (reinforced 2026-08-15 when E0B2P timed out compiling
candidate dependencies with the base leg still `not_run`).
A declared live-phase budget must also reach each nested client's explicit
`timeout_ms`: inheriting the outer deadline only narrows the per-call budget;
it does not replace an omitted client's 30-second default. Pass the declared
budget through the ToolLoop client options while retaining the inherited
remaining deadline, so later calls cannot reset elapsed time. Forward the
normalized `receive_timeout` into the provider request too; an adapter that
rereads only the original request field can reintroduce the provider default.
Test a real response beyond the default and a shorter outer-deadline control. Name the
budget's phase precisely: deterministic preparation and cleanup are outside
this live-phase deadline (reinforced 2026-09-25 after an actual delivered
hostile-input journey stopped at 30 seconds despite its larger declared budget).

<!-- applied-learning: cancellation-tests-must-synchronize-on-the-cancellable-phase -->
<a id="applied-learning-cancellation-tests-must-synchronize-on-the-cancellable-phase"></a>
**Cancellation tests must synchronize on the cancellable phase.** A coding
executor can spend variable time constructing an execution manifest and hashing
loaded BEAM identities before its runner starts. Wait for the runner-start
message with a realistic bounded timeout, distinguish an early owner result
from a startup timeout, and only then kill the owner and assert linked-child
termination. A short fixed delay tests code-server scheduling rather than
cancellation semantics (found 2026-07-28 when an independently reviewed
candidate crossed a brittle two-second startup assertion).

<!-- applied-learning: deterministic-deadline-tests-must-count-every-clock-read-and-keep-fake-clocks-process-local -->
<a id="applied-learning-deterministic-deadline-tests-must-count-every-clock-read-and-keep-fake-clocks-process-local"></a>
**Deterministic deadline tests must count every clock read and keep fake clocks
process-local.** Absolute-deadline code may sample time while constructing the
deadline and again before each receive, so scripted clocks must model every read
and mailbox tests should assert exact unconsumed messages. Keep fake-clock state
in the test process or ensure explicit cleanup; a linked Agent can outlive a
normally exiting test process and leak into later tests (found 2026-08-02 while
reworking VOICE transport deadlines).
Derive an immediate monotonic deadline from the current clock, never literal
zero: a VM's monotonic epoch can be negative, making zero a future deadline
(2026-10-03 conversation activity projector scheduling).
For real socket deadline regressions, keep the peer alive beyond the client
expiry and queued-call return. Otherwise peer retirement can prevent the late
write and make the test pass without the client fence. Give the observation
message a separate bounded delivery allowance (2026-09-29 remote conversation
transport review).

<!-- applied-learning: test-facades-must-observe-production-ownership-not-reimplement-it -->
<a id="applied-learning-test-facades-must-observe-production-ownership-not-reimplement-it"></a>
**Test facades must observe production ownership, not reimplement it.** Delegate canonical lifecycle operations to the real owner; retain observation and failure injection. Do not translate handoffs while independently registering, draining or removing cleanup. Assert state on the process that owns it, including leases that outlive coordinators. Acceptance must invoke the deployed execution owner: `LLM.generate` and `ToolLoop.run` qualify different loops. Bind the configured client, adapters, plug order, auditor and loaded owner identity. Load genuine application metadata before private overrides, configure isolated targets before owners start, retain enforcing flags, and verify effective listener configuration and public readiness before effects. Store seeding does not prove a Manager-backed read path is ready: own the real collaborators, verify exact-PID cleanup, and preserve the positive action assertion instead of returning canned success. Verify the real profile mode: retain the host restriction and capability approval constraint, using an exact finite public `:ask` rule when a permissive baseline becomes `:block`; a missing Manager fallback cannot establish that policy. Production interaction acceptance must use isolated, migrated SQL rather than disabled persistence. Assert `Arbor.Comms.durable_interaction_readiness/0` backend, namespace and durability before effects. Validate public configuration and result shapes against the serving owner. (Trimmed 2026-10-16; first found 2026-08-04.)

<!-- applied-learning: test-observation-helpers-must-not-acquire-authority -->
<a id="applied-learning-test-observation-helpers-must-not-acquire-authority"></a>
**Test observation helpers must not acquire authority.** A helper named
`fence_active_count` installed an operation-owned target fence on every read,
so its first observation changed admission behavior and every later probe failed
under a different owner. Inspect state without mutation, or reuse and explicitly
release one exact test-owned lease when acquisition is the behavior under test.
Also, serialization at one GenServer does not establish arrival order after
different helper processes forward its replies (found 2026-08-11 while repairing
runtime-admission settlement regressions).

<!-- applied-learning: do-not-follow-a-linearized-intermediate-observation-with-a-negative-receive-window -->
<a id="applied-learning-do-not-follow-a-linearized-intermediate-observation-with-a-negative-receive-window"></a>
**Do not follow a linearized intermediate observation with a negative receive
window.** A synchronous owner-state read can prove that a barrier existed before
terminalization; the valid terminal may then reach the test mailbox before the
next `refute_receive` executes. Treat the serialized state response as the
ordering evidence and assert the exact terminal next. Queue an observer between
events at the owner only when the intermediate state itself must be held
deterministically (found 2026-08-11 while repeating runtime-admission liveness
regressions).

<!-- applied-learning: signal-test-callbacks-must-not-assume-serialized-delivery -->
<a id="applied-learning-signal-test-callbacks-must-not-assume-serialized-delivery"></a>
**Signal test callbacks must not assume serialized delivery.** `Arbor.Signals`
subscriptions are asynchronous by default, so two emissions can invoke the same
handler concurrently. A `:counters.add` followed by `:counters.get == 1` is not an
atomic first-event claim: both callbacks may observe the final count and skip the
capture. For order-sensitive assertions, subscribe with `async: false` or use an
atomic accumulator; do not infer callback order from a shared counter (found
2026-08-24 when Packet B's clamped-timeout test observed both correct signals but
left its first-event Agent unset).

<!-- applied-learning: networkless-peer-tests-need-out-of-band-boot-control -->
<a id="applied-learning-networkless-peer-tests-need-out-of-band-boot-control"></a>
**Networkless `:peer` tests need out-of-band boot control.** Under a contained
`--network none` profile, start EPMD inside the isolated namespace and bind the
initiating node explicitly as `name@localhost`; an implicit container hostname can
make distribution fail before the peer starts. Start each peer with
`connection: :standard_io` and `host: ~c"localhost"`, then explicitly require
`Node.connect(peer_node) == true` so stdio controls only peer lifecycle while the
test still proves real distribution. EPMD alone is necessary but does not repair
the default distribution-backed peer-control handshake (found 2026-08-26 during
P1B-2A contained validation).

<!-- applied-learning: source-corpus-tests-must-not-require-ambient-git-metadata -->
<a id="applied-learning-source-corpus-tests-must-not-require-ambient-git-metadata"></a>
**Source-corpus tests must not require ambient Git metadata.** Immutable
object-backed validation mounts tracked source bytes without `.git`; a test that
uses the repository only as a large fixture must construct its own temporary Git
repository instead of asserting `<root>/.git`. When seeding from bytes, force-add
all files so tracked paths that now match `.gitignore` are not silently dropped
(found 2026-09-02 during G5E CrossApp replay).

<!-- applied-learning: pin-the-absolute-namespace-of-nested-policy-test-modules -->
<a id="applied-learning-pin-the-absolute-namespace-of-nested-policy-test-modules"></a>
**Pin the absolute namespace of nested policy test modules.** When a regression declares a fake inside a test module but admission classifies the global application namespace, write `defmodule Elixir.Arbor...` and use the same absolute reference. A nested `defmodule Arbor...` creates a test-module-prefixed name and can test the wrong policy family (found 2026-09-09 while reviewing private-turn memory containment tests).

A test double declared inside one `describe` block also needs a qualified reference
from another block (`__MODULE__.RecordingLog`): its implicit alias is lexically
scoped. Assert that the callback was observed; a graceful production logging rescue
can hide an unresolved double as a no-op (found 2026-09-22 while testing design
council rationale persistence).

<!-- applied-learning: avoid-compiler-reserved-attributes-for-test-matrix-values -->
<a id="applied-learning-avoid-compiler-reserved-attributes-for-test-matrix-values"></a>
**Avoid compiler-reserved attributes for test matrix values.** In an Elixir module-level test matrix, use a task-specific attribute such as `@child_type`, not `@type`: `@type` records a typespec instead of an ordinary scalar, so interpolating it into a test name fails before any regression executes. Prefer explicit `unquote` when a test macro supports it (found 2026-09-09 during isolated memory-policy transport compilation).

<!-- applied-learning: derive-integration-fixture-roots-from-source-locations-not-mix-working-directory -->
<a id="applied-learning-derive-integration-fixture-roots-from-source-locations-not-mix-working-directory"></a>
**Derive integration fixture roots from source locations, not Mix working directory.** Umbrella test tasks can execute with the current directory set to apps/<app>. A helper using File.cwd! to find migrations or retained evidence may create a database in the wrong tree and run zero migrations. Derive fixture, migration and artifact roots from __DIR__ or an explicit validated root; positively assert migrations and isolated storage before exercising persistence (found 2026-09-27 while qualifying ConversationKit against a real Arbor Session).

An existing private database can still predate the candidate migration. Apply
normal migrations to the verified private database and assert the required
schema before interpreting a facade unavailable result as a product failure.
Keep incompatible runtime fixtures in separate normal test processes: a
database helper that starts the default Repo conflicts with an actual Session
journey that deliberately requires it absent. Bind every phase to the same
frozen source and retain the failed combined attempt (2026-10-03 host controls).

<!-- applied-learning: isolate-bounded-admission-budgets-between-test-cases -->
<a id="applied-learning-isolate-bounded-admission-budgets-between-test-cases"></a>
**Isolate bounded admission budgets between test cases.** When repeated cases
share a stable admission identity, use distinct trusted source fixtures for
independent attempts or explicitly raise only the fixture's bounded budget.
Earlier valid starts can otherwise exhaust a per-source quota and make a later
positive assertion fail for the wrong reason (found 2026-10-07 while qualifying
TerminalLogin source binding).

<!-- applied-learning: canonical-runtime-fixtures-should-restore-rather-than-release-global-children -->
<a id="applied-learning-canonical-runtime-fixtures-should-restore-rather-than-release-global-children"></a>
**Restore canonical supervised services through an idempotent readiness boundary.** Call the owning bootstrap before a fixture and during cleanup rather than merely restarting an application whose test configuration suppresses children. Pin the supervisor instance, verify exact child-PID ownership and dependency order, reject registered-name squatters, and leave canonical global children running. Starting a child acknowledges initialization, not readiness: complete each subsystem's public startup barrier in dependency order before returning success, including children with deferred startup. Preserve the intended public gate assertion when a missing collaborator causes an earlier unavailable response. Use acquire/release handles only when they own exact PIDs and reference-count shared users; child IDs resolved after restart can target replacements. Prove restoration with a following same-BEAM file that requires the canonical owner. (Merged 2026-10-16 from 2 entries; first found 2026-08-27, last 2026-10-07.)

<!-- applied-learning: make-loopback-listener-lifetime-explicit -->
<a id="applied-learning-make-loopback-listener-lifetime-explicit"></a>
**Make loopback listener lifetime explicit.** A short
`:gen_tcp.accept/2` timeout is a polling interval, not evidence that a test is
finished. Closing after one idle timeout produces `:econnrefused` when suite
load delays the client. Keep accepting until the expected connection arrives or
the test explicitly awaits/stops the fixture, and monitor the test owner so a
failed test cannot orphan the listener. Gate the acceptor on any ownership
transfer so socket custody is deterministic; passive accept itself is not
restricted to the controlling process (found 2026-10-07 while stabilizing OIDC
loopback security regressions).

<!-- applied-learning: simulate-owner-outages-by-stopping-the-owner -->
<a id="applied-learning-simulate-owner-outages-by-stopping-the-owner"></a>
**Simulate supervised owner outages by stopping the owner, not unregistering its name.**
An authorization path may retain or resolve the supervised PID without using
the registered name. `Process.unregister/1` left CapabilityStore calls live and
made the outage regression pass for the wrong reason. Terminate the supervised
child, assert its protected operations deny, then restart it through the
supervisor (found 2026-10-08 while fixing ACP outage tests).

<!-- applied-learning: stop-test-started-distribution-after-each-case -->
<a id="applied-learning-stop-test-started-distribution-after-each-case"></a>
**Restore exactly the distribution state a test owns.** Inject distribution setup and reachability in ordinary tests rather than invoking a real startup path before the intended facade seam. Run genuine peer scenarios in an isolated BEAM with distinct shortnames derived from the test process identity, owned peer lifetimes, and no route into the live development cluster. Record whether distribution was already running before setup. Stop every fixture-owned peer, and stop local distribution on teardown only when that fixture started it; preserve a pre-existing controller identity. Leaving a newly named node behind can alter later recovery and local-claim semantics even when the peer test passed. (Merged 2026-10-16 from 3 entries; first found 2026-07-15, last 2026-10-08.)

<!-- applied-learning: test-durable-authority-with-owned-fixtures-and-real-consumers -->
<a id="applied-learning-test-durable-authority-with-owned-fixtures-and-real-consumers"></a>
**Test durable authority with private storage and a real authorized consumer.** Start the real supervised audit puller against a private migrated durable database and prove content delivery and acknowledgement. Do not silently retire pending journal effects, reset retention, or increase limits to hide an absent consumer. Security bootstrap installs its test consumer binding; after bootstrap, bind both the real consumer name and its owning application before relying on durable delivery. Capture the exact prior environment presence and values, register restoration before mutation, and restore both bindings on exit. Replace supervised authority or journal owners only through explicit test-fixture registration seams so facade ownership checks remain fail closed. Keep storage alive until delivery and fixture retirement acknowledgements finish. (Merged 2026-10-16 from 2 entries; first found 2026-10-09, last 2026-10-09.)

<!-- applied-learning: label-trusted-control-fixtures-before-durable-checkpointing -->
<a id="applied-learning-label-trusted-control-fixtures-before-durable-checkpointing"></a>
**Label trusted control fixtures before durable checkpointing.** An unlabeled
initial value may pass a legacy action boundary, but the checkpoint correctly
rehydrates missing provenance as untrusted. A restart test must label only its
compiler- and owner-proven control fields, then assert the resumed Engine
`final_outcome.status` before inspecting context; `{:ok, run_result}` alone is
only an envelope (found 2026-10-09 in the design checkpoint BEAM restart test).

<!-- applied-learning: integration-examples-using-mix-test-need-the-validation-test-runtime -->
<a id="applied-learning-integration-examples-using-mix-test-need-the-validation-test-runtime"></a>
**Integration examples using Mix.Test need the validation test runtime.** A
childless Shell test application cannot create owned validation trees, and its
production Linux materializer and spawn path fail closed. Use the Actions test
baseline materializer and real-Mix test shell under an isolated registry
fixture, restore the registry and shell selection after the example, and commit
an empty `mix.lock` in a dependency-free fixture project. The TDD LM Studio
example reached its model call but then failed successively at workspace,
owned-tree, baseline, and lockfile gates before this setup passed on
2026-10-09.
