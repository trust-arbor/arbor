# Applied Learning: Testing and Live Runtime

Read this when choosing a Mix/test isolation boundary, reloading a live runtime, or diagnosing validation evidence and toolchain behavior.

## Retained Applied Learning

<!-- applied-learning: spawned-processes-do-not-inherit-process-dictionaries-and-shared-fakes-require-cleanup-convergence -->
<a id="applied-learning-spawned-processes-do-not-inherit-process-dictionaries-and-shared-fakes-require-cleanup-convergence"></a>
**Spawned processes do not inherit process dictionaries, and shared fakes require cleanup convergence.** Pass test observers explicitly or use test-owned ETS; `Process.put/2` in the test process is invisible to spawned router workers. When a deliberate owner kill triggers asynchronous monitored cleanup, wait for close/absence before replacing a named Agent/ETS backend, or late callbacks can contaminate the next randomized test (found 2026-08-03 while stabilizing VP-04E3 voice tool lifecycle tests).

<!-- applied-learning: independently-rerun-delegated-verification-against-the-committed-revision -->
<a id="applied-learning-independently-rerun-delegated-verification-against-the-committed-revision"></a>
**Independently rerun delegated verification against the committed revision.**
A worker's reported green run is evidence, not acceptance: it may have selected
the wrong lines, run before the final commit, or used stale workspace state.
After integrating a delegated slice, rerun its exact focused suite from an
independent worktree before treating it as green (found 2026-07-25 when two
stale Coding Plan fixture expectations survived a reported full-file pass). For copied dependencies, compare tracked source bytes and module compile-source paths with the exact reviewed ref before accepting a later compile log. Updating the fork does not refresh a private dependency copy; a sealed harness can compile fresh files while the normal build still compiles an older copy (found 2026-09-27 during media fork adoption).
Validate every candidate source preimage before copying any member, and stop
dependent checks if materialization fails. A partial copy mixed the new Voice
producer with old acknowledgement fixtures on 2026-10-05; retain that failed
attempt separately from the complete candidate's passing run.
Normal compilation may also change a dependent module's BEAM metadata while its
source and executable code MD5 remain identical. Bind that exact observed module
delta instead of restoring its old BEAM or repeating a successful compile
(2026-10-05 Voice.Session after the realtime Session struct changed).
Normal compilation and a successful browser refresh do not prove loaded-code
adoption when development code reloading is disabled. On 2026-10-06 Main Home
loaded after its schema repair while still using the older module. Compare the
loaded and disk code MD5; pinned OTP's `beam_lib.md5/1` returns
`{:ok, {module, digest}}`. A compatible single-module update can use
`code.atomic_load/1` with the exact checked BEAM bytes, retaining the old generation
and refusing an occupied slot. Avoid `load_binary/3`'s implicit hard purge;
even soft purge ignores dormant old fun references. Verify the loaded digest
afterward instead of assuming the normal commit changed the running module.
Before deliberately killing an owner in a lifecycle test, wait for the phase
whose cleanup behavior is being asserted. A callback's notification can precede
its result being adopted; on 2026-10-05 the Desk Session-death test raced audio
send adoption. Waiting for receive entry made the custody handoff explicit
without changing production cleanup or replacing its assertions.
Clean dependency sources and matching loaded/on-disk BEAM MD5s do not prove that
the artifacts were built from the current pinned ref. Explicitly rebuild changed
dependencies and verify required option keys/exports in the restarted runtime;
cached PortAudio BEAMs survived a managed restart and rejected the new
`executor_identity` option before capture (2026-09-29).
Compile each changed dependency through its owning application before compiling
its caller. `deps.loadpaths --no-compile` followed by Dashboard compilation left
eight Voice BEAMs stale on 2026-10-05 despite current source hashes and matching
loaded/disk MD5s. Preserve and reject that association, rebuild Voice, and verify
new exports and public behavior before admitting another live fixture; a module's
compile-source pathname does not record the bytes compiled from that pathname.
For packaged escripts, bind reviewed source SHA-256 and compare loaded, disk
and archive OTP code MD5s, plus exact archive bytes against the disk BEAM stripped
with the configured `Mix.Release.strip_beam/2` options. Mix removes debug and
documentation chunks by default, so raw archive and disk SHA-256 hashes can
differ without a code change; never claim those raw hashes are equal. The
2026-10-04 terminal packaging check exposed that invalid assessment assumption
and retained its failure before verifying all 46 executable code identities.
Index artifact provenance by execution role and module together. A module-only
map merged three shared ConversationKit modules across distinct web and terminal
build roots in the 2026-10-04 default validator. Keep both paths and their own
source, BEAM and code identities; never let one build silently replace the other.
Derive override membership from the bound catalog's actual rows, not from module
usage or presence in source. On 2026-10-05 Diagnostics was a newly observed
supplemental module, outside the original 78-row audio catalog; assuming four
overrides instead of the actual three caused a pre-copy refusal.
CaptureLog's level filter does not lower a global warning threshold. For INFO
diagnostic tests, serialize the cases, save the public module-level override,
enable INFO for that module and restore its exact prior setting on exit. Keep
production severity and global logger configuration unchanged (2026-10-05).
Compare an owned reference's exact path separately from byte equality across
copies. On 2026-10-04 a signed-relay wrapper incorrectly required two preserved
copies with identical hashes to have the same path; review caught it before
execution, and the successor checks ownership and content separately.
Packaged application metadata can have explicit toolchain ownership. The actual
2026-10-04 Breeze archive contains `elixir.app` and `logger.app` from pinned
Elixir 1.19.5, while its other 13 applications belong to the private build. Bind
those two exact toolchain paths, versions and hashes; do not invent nonexistent
copies under the project build or accept a generic external-path fallback.
Distinguish immutable source/lock inputs from operational cache outputs. Hex can
rewrite its private registry `cache.ets` during normal `deps.get --check-locked`;
retain the initial cache snapshot and any failed byte-equality assertion without
restoring it just to make hashes match. On 2026-10-04 all 268 source/config and
325 dependency-source inputs stayed exact while that registry serialization changed.
Normal no-start Mix runs also rewrite per-application `.mix/compile.app_cache`.
On 2026-10-04 only 21 such cache files changed before the default integration
could start; its strict immutable guard correctly refused the mismatched packet.
Classify only the exact operational cache paths separately, retain before/after
hashes and file-kind confinement, and keep source, BEAM, `.app`, static, priv and
archive bytes immutable. Refreshing the whole inventory would hide real drift.
The locked Boundary compiler also writes module/reference ETS snapshots and a
computed dependency view. On 2026-10-04 a normal formatter changed only the six
`compile.boundary_modules`, `compile.boundary_references` and
`compile.boundary_view_v2` files belonging to Kernel and KernelRuntime, with
source and executable artifacts unchanged. Inspect and bind the actual producer
before classifying those exact existing regular files as compiler-validation
metadata; never exempt all `compile.*` files or an entire build directory.
Record declared formatter source outputs before an artifact refusal, marking
their AST unconfirmed until the parser succeeds. Otherwise the failure receipt
can falsely describe an expected formatting change as unrelated source drift.
Normal formatting can also rebuild changed path dependencies, and forced
dependency compilation can invalidate the calling application's protocol
consolidation. Record the exact produced artifacts, then normally rebuild their
owning application; do not restore stale BEAMs or consolidation. On 2026-10-04
normal Gateway compilation changed eight lower applications' `compile.elixir`
records without changing their BEAMs; inspect those exact changes before accepting
the successor inventory. Respect a proof helper's output-directory confinement
when constructing its caller; a misplaced Auth2 packet failed before its origin
checks, requiring a caller-path correction, not weaker proof gates.
An asynchronous command index can report `incomplete` immediately after a new
journal admission. Every accepted phase must wait for complete reads inside its
existing deadline, while still checking authorization and scope on each read;
an assertion before the await loop incorrectly failed the renewed 2026-10-04
stream prerequisite before its observer's status branch could run.
When source-only workers prepare immutable packet successors in parallel, give
each writer its own output namespace and seal its result before Root consumes it.
An exclusive-create refusal preserves an existing worker packet; inspect that
packet instead of overwriting it. Recompute catalog count headers from the actual
role/module rows after ownership promotions, without changing historical proofs.
Trace each current proof schema through every consuming method. Keeping an old
method's AST unchanged does not establish compatibility with a renewed proof:
the 2026-10-04 recovery preflight refused a raw Trust Manager projection where
its historical consumer expected full ownership and compile-origin fields. Bind
the exact projection to its fresh loaded catalog instead of inventing fields.
Interpreter aliases are a separate case from canonical metadata paths. Preserve
the approved virtualenv executable path and pin its symlink target, resolved
binary, executable hash and environment configuration; rejecting every alias
would refuse the existing Python virtualenv before an actual native launch.
Execute the preserved virtualenv path itself, not its resolved binary target:
resolving the Python symlink bypassed the environment and failed the 2026-10-05
browser import before launch. Verify the selected interpreter can import its
required library and retains a virtualenv prefix before starting the controller.
Check fault-injection callbacks against the installed library's scheduling
context. On 2026-10-04 a synchronous Playwright page-side close from a WebSocket
route's asyncio task spun its dispatcher/Future loop; ordinary message callbacks
use a different EventGreenlet path. Also check browser close-code constraints:
the injected 1012 server code was invalid for browser-initiated upstream closure.
A failed forced owner stop is not normal native cleanup or recovery acceptance,
even when the host acknowledges shutdown and all private descendants disappear.
Trace the complete native bootstrap before constraining a fault relay. The signed
Breeze CLI resolves even an exact target ID with signed HTTP before opening its
socket; the 2026-10-04 relay rejected that valid startup because it allowed only
chat upgrades and human login. Forward only the exact configured target's bounded
GET through the real Gateway authorization, preserving request bytes. Record
signed discovery separately from DeviceFlow so "no human login" does not falsely
mean "no HTTP". A concurrent source review's destination-absent assertion may
become obsolete when Root creates its reviewed copy; verify the exact source and
sole authorized gate change instead of treating presence as a source defect.
Bind browser framework assets as well as server code. The production root layout
retained Phoenix1.8.3/LiveView1.1.21 imports after the server moved to 1.8.9/1.1.33.
Serving installed dependency assets with versioned local URLs removes that drift;
it does not prove the cause of an earlier intermittent click failure. Parse the
actual rendered import map: HEEx script bodies treated a brace expression as
literal text in the first 2026-10-04 candidate, which needed EEx output instead.
Copied builds can also retain relative `priv` links that escape their new image.
Resolve links against the actual `MIX_BUILD_PATH`, verify existing targets are
image-owned, and record repairs before startup. Distinguish active artifacts
from unused stale build trees: on 2026-10-03 all three conversation images had
valid active `_build/lib` links but escaped leftovers in `_build/test/lib`.
The leftovers did not invalidate the active-path evidence.
Retain each Git dependency's checkout metadata in an offline copy. Excluding
every `.git` directory made Mix reject three otherwise exact dependency sources
before the predecessor test on 2026-10-04. Copy the retained metadata without
fetching. A relocated project can normally rebuild its whole owning app; verify
the executed producer source and code, rather than requiring a two-file compiler
caption merely because the intended change touches two files.
Apply the same check to copied test builds: `mix compile --force` recompiles
umbrella applications without forcing their dependency artifacts. Rebuild a
changed dependency explicitly with `deps.compile <name> --force` and verify its
required exports before accepting application compilation; the private Voice
candidate retained an older `SyncExecutor` BEAM despite clean, correctly pinned
source defining `bind_lease/4` (2026-09-29).
Validate dependency caches against each execution root's own lockfile before
handing off a multi-project run. A standalone client nested under an umbrella
can lock different versions of identically named packages. Copying umbrella
caches into that client's private `deps` left three lock mismatches after all
server lanes had passed; preserve the client lock and materialize its exact
verified packages instead (2026-09-29 terminal qualification).
Bootstrap each cold execution root's complete locked dependency graph before
selectively forcing changed packages. `mix deps.compile <names>` compiles the
named packages as-is unless children are explicitly included; a warm parent
build can hide missing transitive prerequisites in a standalone project.
The 2026-10-01 UI comparison reached the correct Jason source but had never
compiled its ordered-object struct. Preserve the lock and decoder contract;
repair dependency build ordering instead of changing working application code.
For cold compilers that write into dependency directories, exclude only
reviewed generated output paths from source inventories. A whole cache or
tool directory exemption can hide executable input changes; the UI comparison
retains all Erlang.mk files while exempting only known `.d` and `.app` outputs.
For observed generated-symbol drift, bind the generator/DSL inputs and require
capture-free local renames to reconstruct the frozen bytes exactly before
accepting a separate reviewed verdict. Preserve the original failure and reject
unreviewed variants; Unifex's shared counter changed only two local loop names
after full dependency bootstrap in the 2026-10-01 UI comparison. Such evidence
review does not require rerunning unaffected behavior or hiding generated trees.

A single computed formatter output is not a fresh formatting check. Verify the
resulting bytes with the repository's configured formatter, then confirm another
formatting pass leaves them unchanged. On 2026-10-01, pinned Elixir 1.19.5 changed
an `application.ex` call layout on two successive passes before stabilizing.
A one-pass archive preflight had been treated as green; the normal Mix hook
caught the remaining change. Bind final source hashes only after the fresh
configured check and stable-output check.

Verify the pinned command's argument forwarding before adding a familiar CLI
separator. Mix 1.19.5 `run` retains a `--` placed after the script in
`System.argv/0`; a parser expecting paired source paths would receive an odd
argument count. Source review caught this in the 2026-10-04 form-qualification
launcher before execution. Match the already qualified invocation grammar and
do not count a launcher failure as a behavioral regression witness.


A private predecessor swap must trigger compilation of the changed bytes.
Metadata-preserving copies can retain an old mtime, causing Mix to run the
candidate BEAM instead of the swapped source. Refresh the copied file mtime,
verify the compiler rebuilt the owning app, and bind the actual source and
test hashes before accepting a witness. Derive a line selector from the
current test title and verify one intended test ran; comments can shift
hardcoded selectors to a different case (2026-10-03 native approval witnesses).

A predecessor witness must exercise an operation the frozen predecessor
supports. The dirty starting image can already contain new APIs absent from
HEAD; an unsupported-operation failure does not prove the intended bug.
Qualify the old happy path first, then add the counterexample (2026-10-03:
duplicate signed JSON keys use the committed history API rather than the
newer window API).

Keep each qualified source version in its own execution image, with versioned
runner and binding-report destinations. A new candidate must not replace the
source, BEAMs or referenced output of an earlier qualified packet. Check output
paths before executing copied harnesses; the notice SDK v2 runner initially
reused the v1 binding destination. The intermediate report was retained and the
original v1 image and report hash were restored before separate v2 qualification
(2026-10-03).

An overlay manifest must include the runtime dependencies of its new entry
points, even when those dependencies were already dirty before the current
slice. A fresh worktree starts from its committed checkpoint; copying only
the listed overlay can omit working-tree wiring. On 2026-10-03 the new notice
image retained checkpoint Manager bytes without the command continuation used
by the adopted MessageFacade. Its preimage guard refused before mutation.
Preserve that checkpoint baseline, add the reviewed and tested dependency to
the new manifest, and rebuild the image before native acceptance.
An overlay is not necessarily a whole standalone package: baseline files in an
untracked new client may be absent from both HEAD and the overlay. Bind those
unchanged files to prior qualified full-source hashes, rather than copying
current workspace bytes implicitly. The 2026-10-03 Breeze migration image
exposed omitted Editor, runtime/config and test-helper inputs before building;
the joined native loaded-source check must include that supplemental closure.
Apply this to host consumers too: retain declared path dependencies, routes,
navigation, browser hooks, authorization and transcript readers, not only the
new backend delta. Bind unchanged required loaded sources and the intentional
private test configuration separately. The same 2026-10-03 review found missing
Dashboard Mix edges, window readers and UI aliases hidden by copied build
metadata. Preserve copied builds as inputs, then build the complete source
assembly from empty output trees before admitting the actual browser/PTY run.

Provision each fixture's ordinary prerequisites explicitly. A notice test's
temporary migrated database does not migrate a Directory test's canonical
private database; unchanged lower tests passed only after ordinary private
`ecto.create`/`ecto.migrate`. Likewise, provision the actual Orchestrator and
public conversation TaskSupervisor before starting a Branch. Respect identifier
grammar in helpers: `Integer.to_string(10, 16)` emits uppercase `A`, so a fixed
lowercase notice ID requires case normalization. Preserve these preparation
failures without weakening production gates (2026-10-03 native notice helper).

Failure cleanup must settle an owned child independently of evidence I/O.
A key write, drain, bounded-log failure or constructor exception can skip the
normal terminal exit; put exact-child termination and reaping in `finally`,
and retain forced cleanup as a failed acceptance. In paired Python regressions,
close retained stream objects before raw descriptors: an assertion traceback
can keep a log object alive, and its later finalizer can close a reused fd
after descriptor-only teardown (2026-10-03 native PTY harness).
Validate the complete launch specification before starting its child, and record
the exact PID immediately. On 2026-10-04 a wrapper read an absent deadline field
after `Popen`; the native owner cleaned up normally, but the wrapper could no
longer reap its exit code. Retain that distinction instead of inferring a normal
outer exit from the inner host's shutdown receipt.
Validate the associations between sealed source, setup and build packets as well
as their independent hashes. Any lifecycle exception after a journey result,
including browser close or the browser runtime's context exit, must force a
failed result while retaining its checks and earlier primary failure.
Before each effect, compare the actual plan, runner and diagnostic member bytes
with their sealed manifest rows. A manifest hash or member-list presence alone
does not admit changed members. On 2026-10-05, a Main activation draft bound the
manifest through review but did not verify the adoption plan's command arrays
at execution; it was corrected before any draft ran. For checkpoint acceptance,
compare committed blob bytes with the qualified selected-source digests, not
only the changed-path list and matching working-tree files.
When replacing a frozen source row, derive its hash, path and byte count from
the final bytes together. On 2026-10-04, two qualified Breeze source rows kept
their predecessor sizes even though every source hash was correct. Preserve
the refused packet and fork its association metadata explicitly; unchanged
source, BEAM, archive and loaded-code proofs keep their original attribution.
Correcting metadata does not require rebuilding correct code or weakening the
size check.
Update a derived manifest's summary scope along with its actual proof references.
A fresh host observation cannot inherit wording that says the old host proof
was retained unchanged. Preserve the parent and unchanged module rows; correct
the attribution in an explicit metadata fork, without rerunning correct code.
Use the declared escript output name and an absolute executable path for a
nested Mix smoke check; the build produced `arbor-breeze`, not `arbor_breeze`.
Bind the outer harness interpreter as well. Reuse the exact previously accepted
`browser-python/bin/python` for Playwright journeys and give it fresh outer
HOME, temporary, config and cache paths; verify imports through that interpreter
and environment before starting the host. A generic system Python changes the
runner dependency closure. On 2026-10-04 the host exited normally with closed
ports, but the wrapper failed to import Playwright before any UI checks.
Preserve that initial failure and rerun the unchanged journey with the existing
accepted interpreter and fresh scoped environment, without dependency installs
or product changes. Startup and cleanup alone do not qualify native behavior.
Check every automatic read a new surface adds through the real server decoder,
dispatcher and encoder. The native notice journey loaded20 history entries and
then correctly cleared them because Gateway lacked the SDK's notices request
handler; a successful initial history read had hidden the unwired operation
(2026-10-03).

When a public request builder tightens validation, malformed-wire tests must
still reach the transport gate. Construct an ordinary valid payload, deliberately
change only the raw-wire input, and sign the final changed bytes; independently
assert the public builder refuses that input. Two slash-command fixtures had
started failing before Gateway dispatch, leaving its separate refusal untested
(2026-10-03). Preserve the original fixture failures and repair the test boundary
rather than weaken production validation.

Measure the UI state actually rendered, and retain raw/computed samples before
asserting a visual gate. After a Session completed, Current work correctly showed
an empty-state sentence, but the notice harness required an active-row STRONG
that no longer existed. Include the rendered empty/status sentence and measure
all present labels; missing optional content is not a contrast defect. Retaining
samples only after a passing assertion also discarded the diagnostic evidence
(2026-10-03 actual browser/raw-PTY notice journey).

For collapsed controls, establish their rendered state before comparing visible
text. On 2026-10-04, actual Home reload preserved the exact URL, draft, history
and identities, but a closed `details` returned empty `inner_text()` while
`text_content()` retained both IDs. Capture both methods and the open state
before the assertion. Open the real summary through native keyboard input
before the unchanged exact identity check, then close it normally; retain the
failed evidence and no-new-turn check. A rendered-text predicate on hidden
content is a helper precondition failure, not evidence of lost authorization.
Establish the viewport precondition for terminal captions too. On 2026-10-04,
a readiness regression at 100×28 clipped the existing cancellation caption
before reaching its intended held-read assertion. The existing public resize
to 100×40 retained every predicate and allowed both predecessor failures to
reach the same intended busy-state gate. Preserve the unrelated failure;
do not count it as a causal regression witness.
Establish semantic input preconditions before waiting for an action to become
enabled. The 2026-10-04 native streaming helper waited for Send on an empty
composer before filling it, so it timed out without submitting or starting the
provider. Fill the admitted text first, then retain the same enabled-state check,
native submit gesture and deadline; do not weaken the product's empty-input gate.
Compare terminal frames using the capture's documented row representation.
The 2026-10-04 streaming frame decoder trimmed row margins while the exact
provider prefix ended in a space. Normalize only the display expectation;
keep protocol, command identity and SQL text comparisons exact. An updated
browser disclosure needs separate treatment: awaiting text after checking its
open state can reveal a patch that closes it. Preserve user-owned `open` through
the framework's attribute API while allowing content updates and authorization
removal. Reopening it in the helper does not prove state survived the update.
Configured formatter plugins may also run dependency loadpaths. During the
2026-10-04 disclosure correction, normal formatting regenerated two dependency
`compile.elixir` records while every dependency BEAM and guarded source stayed
byte-identical. Retain the policy failure and inspect the exact producer and
whole artifact delta before continuing; a metadata rewrite does not authorize
a broader dependency artifact prefix or justify restoring old build records.
Native key fixtures must use the pinned editor's actual bindings. A familiar
shell shortcut can pass through a terminal editor as printable input: the
Breeze fixture's Ctrl+A/Ctrl+K sequence inserted `a`/`k` instead of clearing its
draft. Trace key decoding and editor handling, then use supported native keys
with a finite bound for the fixture text. Preserve the transcript assertions;
do not turn a mistaken simulated gesture into an unrequested product shortcut
(source-confirmed on 2026-10-04).
Observe terminal command facts through the exact public command read, not an
active-work page. Confirmed cancellations and completed commands intentionally
leave that page. On 2026-10-04, queued cancellation was durably confirmed as
`queued_removed`, but the native harness waited for the removed row to reappear.
Keep the exact termination predicate and use disappearance only as secondary
evidence; a longer timeout or a producer change would obscure the real mismatch.
An authenticated indexed read can intentionally report an incomplete view while
its background projection catches up. Keep authorization strict on every sample,
retain partial observations, and evaluate phase predicates only on complete
views within the original deadline. Direct reads still require completeness.
The 2026-10-04 native stream run confirmed partial-to-complete index catch-up;
the earlier strict conjunction failed before retaining its actual sample.
Resolve a dependency from the consumer's actual Mix declaration before tracing
its source. The Breeze client uses reviewed `vendor/breeze`; its private image
also retains an unused `standalone_deps/breeze` copy without the paste changes.
Reading that inactive copy cannot explain the generated client's behavior
(2026-10-04 terminal draft-entry diagnosis).
Trace a private SQL observer to the setup's actual repository and supervisor.
The recovery helper invented `ArborNoticeNativeSetup.Repo`; its public read passed
before SQL failed because setup owns `Arbor.Persistence.Repo`. Correct only that
fixture reference and retain fresh authorization, scope, bounds and cleanup;
do not change persistence configuration to accommodate the helper (2026-10-04).

Runtime code snapshots are not operator approvals or grants. A safety-relevant
admission-owner field must survive every descriptor and binding projection,
including the final facade and legacy comparison. Use normally compiled test
actions/handlers when the gate checks BEAM identity, so a counterexample reaches
the intended gate rather than failing on an unavailable diagnostic module.
For a defect introduced during a feature, retain the owner-enabled intermediate
preimage; a pre-feature baseline may lack the descriptor API and fail before the
discarded-field check (2026-10-03 native notice admission review).

Wait for a positive rendered state before the next native input. Bare Escape
is buffered for 500 ms by the selected Breeze input router, while the raw-PTY
helper drains for 250 ms; sending End/paste immediately can leave work controls
focused. The actual 2026-10-04 successor waited for transcript seed rows and
then entered and retained the draft. Do not weaken paste-owner fences to make
a fixture succeed. Validate the consumer's exact reference schema before a
runtime launch; correct extra producer fields rather than relaxing its gate.
A cancelled streaming turn may intentionally retain a partial transcript.
Trace its persisted semantic status before treating row presence as completion
or changing retention policy. The 2026-10-04 native run confirmed worker/Engine
termination and a stored cancelled assistant, but window/projection consumers
dropped that status. Preserve and label it, keep speech disabled on replay, and
require explicit field presence in the regression: two missing values can
compare equal and hide the defect.
A history-status UI fixture must append fresh persisted identities, or seed
status before the first read. Changing a cached entry's status at the same id
and ordinal correctly trips the immutable-overlap gate; do not relax that
gate to exercise a label (2026-10-04 retained-partial presentation review).

Before asserting a public runtime receipt, trace its value from the metadata
producer through the public projection. An implementation module and a public
backend label are different values; on 2026-10-05 a realtime control fixture
rejected a valid session by comparing `:xai_realtime` with its module name.

<!-- applied-learning: fault-tests-must-prove-the-required-recovery-contract-not-only-fail-closed-safety -->
<a id="applied-learning-fault-tests-must-prove-the-required-recovery-contract-not-only-fail-closed-safety"></a>
**Fault tests must prove the required recovery contract, not only fail-closed
safety.** A crash regression that replaces an expected resume with a safe
`indeterminate_effect` can be locally correct while permanently stranding a
durable workflow. Keep the generic safety invariant, then change the operation
boundary so the requested recovery is actually safe and assert that behavior
end to end (found 2026-07-25 when a blocking design-checkpoint Await was
classified as a generic side effect and could not consume its durable terminal
after Engine owner death).

<!-- applied-learning: compare-repository-wide-quality-failures-with-the-frozen-starting-revision -->
<a id="applied-learning-compare-repository-wide-quality-failures-with-the-frozen-starting-revision"></a>
**Compare repository-wide quality failures with the frozen starting revision.**
`mix quality` can fail on pre-existing formatting or lint backlog outside the
current change. Run it from an isolated worktree pinned to the starting commit;
if the same unrelated files fail there, record the baseline and run exact
changed-file formatting/lint checks plus behavioral tests for the feature. Do
not format unrelated files merely to make the aggregate alias green (found
2026-07-22 while verifying the software-factory remediation program).
Compare lint against the original pre-task base as well as a test-only parent;
the latter already contains the new regressions and can hide findings introduced
by those tests (reinforced 2026-09-25 during timeout regression qualification).

<!-- applied-learning: terminal-tool-contracts-need-a-reserved-terminal-only-request-after-normal-inspection-tool-rounds-are-exhausted -->
<a id="applied-learning-terminal-tool-contracts-need-a-reserved-terminal-only-request-after-normal-inspection-tool-rounds-are-exhausted"></a>
**Terminal-tool contracts need a reserved terminal-only request after normal
inspection/tool rounds are exhausted.** That reserved request must expose only
terminal definitions, force tool choice, run exactly once, and reject fabricated
non-terminal calls before execution (found 2026-07-18 after the ToolLoop
terminal-submission fix).

<!-- applied-learning: structured-terminal-output-needs-a-tool-contract-not-prompt-only-json -->
<a id="applied-learning-structured-terminal-output-needs-a-tool-contract-not-prompt-only-json"></a>
**Structured terminal output needs a tool contract, not prompt-only JSON.**
Reviewers with tools still returned fenced JSON or prose; `DecideReview`
correctly exact-decodes and abstains — do not strip fences or scrape prose.
Expose a schema-bounded terminal Jido action, mark it via generic
`ToolLoop`/`LlmHandler` `terminal_tools`, return only that action result as
`PipelineResponse.content`, and allow at most one terminal-only correction
turn when free-form text arrives (found 2026-07-17 fixing binding council
reviewer reports).

<!-- applied-learning: exclude-sentinel-atoms-before-normalizing-optional-protocol-fields -->
<a id="applied-learning-exclude-sentinel-atoms-before-normalizing-optional-protocol-fields"></a>
**Exclude sentinel atoms before normalizing optional protocol fields.** In Elixir,
`nil`, `true`, and `false` are atoms, so a broad `is_atom/1` conversion can turn a
missing value into the valid-looking string `"nil"`. Guard those sentinels before
`Atom.to_string/1`, especially when the result becomes an authorization identity
or URI segment (found 2026-07-17 while normalizing native ACP tool identities).

<!-- applied-learning: match-the-exact-split-shape-when-a-delimiter-proves-structure -->
<a id="applied-learning-match-the-exact-split-shape-when-a-delimiter-proves-structure"></a>
**Match the exact split shape when a delimiter proves structure.** A pattern such
as `[head | _]` also matches a one-element list, so it does not prove that
`String.split/3` found the expected delimiter. Use `[head, rest]` when the second
part is the evidence that an opaque protocol ID embeds a typed prefix (found
2026-07-17 while parsing ACP `toolCallId` values).
Check identifier grammars against the actual producer before tightening a
fixture validator. `Engine.generate_run_id/1` includes `Node.self()`, so a local
run ID contains `nonode@nohost`; the 2026-10-04 control prerequisite rejected
that legitimate `@` before any choice admission. Bind the exact known graph and
current node prefix plus the generated date/time/hex suffix instead of guessing
a generic identifier alphabet or accepting arbitrary path components.

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

<!-- applied-learning: in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries -->
<a id="applied-learning-in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries"></a>
**In Elixir map literals, place every `key => value` entry before keyword-style atom entries.** A map that starts with `foo: value` and later adds `dynamic_key => value` is a syntax error; either order all association entries first or use `Map.put/3` for dynamic keys (found 2026-07-14 during delegated Apple admission-core review).

<!-- applied-learning: for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella -->
<a id="applied-learning-for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella"></a>
**For local diagnostic Mix tasks, start the narrow app, not the whole umbrella.** `Mix.Task.run("app.start")` in an umbrella task starts every app and can bring up Gateway/Dashboard, pollers, memory loaders, etc. (2026-07-07: a local trust-profile audit accidentally started HTTP endpoints and loaded unrelated subsystems). Plain `./bin/mix run -e ...` also starts the application; use `./bin/mix run --no-start -e ...` for one-off module introspection that only needs compiled code. For offline/local diagnostics that only need one subsystem, use `Application.ensure_all_started(:target_app)` after compilation/loadpaths, and leave the default task path as live RPC when it needs the running server's state.

<!-- applied-learning: offline-git-operator-tasks-need-the-minimal-shell-direct-runtime -->
<a id="applied-learning-offline-git-operator-tasks-need-the-minimal-shell-direct-runtime"></a>
**Offline Git operator tasks need the minimal Shell direct runtime, not the Shell application.** Hardened `Arbor.Actions.Git` calls route through `Arbor.Shell.execute_direct/3`, so a no-start Mix task still needs the pinned executable policy and execution registry. Starting `:arbor_shell` is broader than it sounds: OTP also starts transitive application children (Signals, Security authority, skill indexing, container control planes), can emit startup logs into a machine-readable stdout stream, and performs unrelated initialization. Use `Arbor.Shell.start_direct_runtime/1`, stop the returned supervisor after the operation, and keep `:arbor_actions` stopped so a read-only branch audit cannot hydrate retention state or arm cleanup timers (found 2026-07-21 while running the historical branch migration dry run).

<!-- applied-learning: compile-an-edited-custom-mix-task-before-its-behavior-smoke-test -->
<a id="applied-learning-compile-an-edited-custom-mix-task-before-its-behavior-smoke-test"></a>
**Compile an edited custom Mix task before its behavior smoke test.** Mix can resolve and load the task module from the existing BEAM before project compilation updates that BEAM, so the first invocation after editing the task may compile the new source but still execute the prior module. Run `./bin/mix compile --warnings-as-errors`, then exercise the task in a fresh VM invocation before diagnosing the new source as ineffective (found 2026-07-21 while validating `arbor.coding.branches --output`).

<!-- applied-learning: avoid-escaped-map-key-syntax-inside-interpolated-mix-run-e-snippets -->
<a id="applied-learning-avoid-escaped-map-key-syntax-inside-interpolated-mix-run-e-snippets"></a>
**Avoid escaped map-key syntax inside interpolated `mix run -e` snippets.** An expression such as `"#{map[\"key\"]}"` passed through shell quoting is rejected by Elixir before the diagnostic runs. Bind the value with `Map.fetch!/2` first, then interpolate the bound variable (found 2026-07-10 while checking the live coding-plan action catalog).

<!-- applied-learning: test-downstream-config-guards-with-values-that-survive-the-config-accessor -->
<a id="applied-learning-test-downstream-config-guards-with-values-that-survive-the-config-accessor"></a>
**Test downstream config guards with values that survive the Config accessor.** Some accessors intentionally normalize malformed or blank Application env values back to a packaged default, so a downstream test that injects `nil` or whitespace may exercise the fallback rather than the guard under test. Read the accessor first and use a value such as invalid UTF-8 or NUL-containing binary when verifying the downstream boundary (found 2026-07-10 in the CodingPlan facade test).

<!-- applied-learning: revalidate-compiler-output-against-the-normalized-plan-at-the-execution-boundary -->
<a id="applied-learning-revalidate-compiler-output-against-the-normalized-plan-at-the-execution-boundary"></a>
**Revalidate compiler output against the normalized plan at the execution boundary.** A compiler is a trusted module seam, but a bug or malformed replacement can reintroduce unchecked execution values after input scope validation. Bind every path/provider/model/test selector the generated graph will consume back to the canonical Plan before archiving or running it (found 2026-07-10 when review reproduced a worktree-root redirect through `initial_values`).

<!-- applied-learning: mix-arbor-eval-is-the-eval-harness-not-a-lightweight-rpc-evaluator -->
<a id="applied-learning-mix-arbor-eval-is-the-eval-harness-not-a-lightweight-rpc-evaluator"></a>
**`mix arbor.eval` is the eval harness, not a lightweight RPC evaluator.** For running-node diagnostics, use a purpose-built RPC task such as `arbor.recompile` or a task-specific command, or add/use an explicit `arbor.eval.rpc`-style task. Otherwise `arbor.eval` starts evaluation infrastructure and can fail on missing `--model` / `--models` before running the intended diagnostic (found 2026-07-08 while checking registry ETS state).

<!-- applied-learning: do-not-raw-recompile-the-umbrella-to-repair-stale-live-code -->
<a id="applied-learning-do-not-raw-recompile-the-umbrella-to-repair-stale-live-code"></a>
**Do not raw-recompile the umbrella to repair stale live code.** Calling `IEx.Helpers.recompile/0` through Tidewave can stop dependency applications and leave long-lived signer closures paired with newly loaded modules, producing mixed signing credentials and unavailable security state. Prefer the supported RPC recompile task; if distribution addressing makes that task unreachable, perform a clean restart after the migration preflight instead (found 2026-07-13 while restoring MCP coding delegation).

<!-- applied-learning: a-closed-envelope-rejection-can-be-live-producer-consumer-bytecode-drift -->
<a id="applied-learning-a-closed-envelope-rejection-can-be-live-producer-consumer-bytecode-drift"></a>
**A closed-envelope rejection can be live producer/consumer bytecode drift.**
`mix_compile failed to execute: :extra_projections` does not necessarily mean
the retained candidate added a mount. In the 2026-07-15 L3B run, the loaded
`Arbor.Actions.Mix` still emitted the retired read-write `runtime` projection
from an old runtime snapshot while the loaded Shell core correctly accepted
only `worktree`, `home`, `tmp`, `build`, and `deps`. Read the task artifact's
`validate/status.json`, inspect both loaded module source identities, and
evaluate the live producer shape before blaming candidate code. Reconcile the
reviewed producer between tasks; never widen the consumer's closed security
envelope to accommodate stale code.

<!-- applied-learning: search-every-direct-wire-shape-match-when-centralizing-a-response-contract -->
<a id="applied-learning-search-every-direct-wire-shape-match-when-centralizing-a-response-contract"></a>
**Search every direct wire-shape match when centralizing a response contract.** Fixing the primary adapter does not cover eval-only or provider-specific HTTP paths that decode the same response independently. Search for structural patterns such as `%{"data" => ...}` and route every caller through one lower-level facade helper. For embeddings, assert indexed ordering before cosine or another symmetric reduction; a reversed pair produces the same cosine score and can hide a silent A/B swap (found 2026-07-11 in the direct embedding-similarity eval HTTP path).

<!-- applied-learning: when-a-supervised-child-gains-a-prerequisite-update-every-manual-test-stack-in-dependency-order -->
<a id="applied-learning-when-a-supervised-child-gains-a-prerequisite-update-every-manual-test-stack-in-dependency-order"></a>
**When a supervised child gains a prerequisite, update every manual test stack in dependency order.**
`SigningAuthorityBroker` now depends on `SigningAuthorityStateOwner`; app supervision starts
them correctly, but Orchestrator and Agent tests that manually started only the broker failed
far from setup with `:broker_unavailable`. Search all `start_child` helpers whenever a child
spec gains a sibling prerequisite, and keep isolated test files independent of suite order.
For token-coupled pairs, create one opaque token, pass it to both children under their respective
option names, start the owner first, and restart an existing dependent child through its supervisor.

<!-- applied-learning: bounded-prompt-payloads-must-remain-structurally-valid -->
<a id="applied-learning-bounded-prompt-payloads-must-remain-structurally-valid"></a>
**Bounded prompt payloads must remain structurally valid.** Byte-slicing encoded JSON produces an
invalid fragment that downstream workers cannot parse. Bound fields before encoding, then compact
to a smaller valid JSON envelope with an explicit truncation marker if the encoded payload still
exceeds its ceiling (found 2026-07-12 in recovery and review feedback).

Apply aggregate limits after normalization, including added default fields.
Two individually bounded responses do not automatically fit their combined
projection. Before publishing a resume cursor, require the first command's
complete prompt batch to fit; trim disposable previews explicitly or refuse
the observation rather than skip undisplayed prompts. Later pagination must
resume after the last fully read command (2026-10-03 conversation controls).

<!-- applied-learning: a-semantic-retry-ceiling-must-pin-the-whole-counter-dataflow -->
<a id="applied-learning-a-semantic-retry-ceiling-must-pin-the-whole-counter-dataflow"></a>
**A semantic retry ceiling must pin the whole counter dataflow.** Checking only category/total gate
conditions does not prove that an admitted retry increments the shared total: a rewired edge or
mutated transform can skip the total counter and preserve every gate node. Pin counter
initialization and writer attributes, exact category-to-total increment chains, and prompt/dispatch
routing; mutation tests must remove or bypass each increment and fail before execution (found
2026-07-12 in coding review convergence preflight).

<!-- applied-learning: prompt-data-fencing-must-reuse-one-nonce-across-the-system-preamble-and-every-tool-result -->
<a id="applied-learning-prompt-data-fencing-must-reuse-one-nonce-across-the-system-preamble-and-every-tool-result"></a>
**Prompt-data fencing must reuse one nonce across the system preamble and every tool result.** Wrapping a later tool result with a fresh nonce that the system prompt never introduced gives the model delimiters without the instruction that makes them meaningful. Generate the nonce at the LLM-handler boundary, put its preamble in the system message, and thread that exact nonce through every tool-loop round and error path (found 2026-07-10 while enabling commit-tree evidence for binding reviewers).

<!-- applied-learning: bound-producer-output-before-it-enters-application-memory -->
<a id="applied-learning-bound-producer-output-before-it-enters-application-memory"></a>
**Bound producer output before it enters application memory.** Running `System.cmd/3` and truncating the returned binary still lets an untrusted command allocate its entire output first. For Git search or similar evidence tools, consume a Port incrementally, enforce a byte ceiling while receiving, and close the producer once the bound is reached; regression tests should keep the producer alive long enough to prove it was terminated before later side effects (found 2026-07-10 in `coding_review_tree_search`).

<!-- applied-learning: tool-loop-exhaustion-must-preserve-the-conversation-s-required-output-format -->
<a id="applied-learning-tool-loop-exhaustion-must-preserve-the-conversation-s-required-output-format"></a>
**Tool-loop exhaustion must preserve the conversation's required output format.** A generic final-pass instruction such as "plain text only" or "do not output JSON" can invalidate a council node whose contract requires a structured vote. Remove tools for the wrap-up pass, but tell the model to answer in the format already required by the conversation (found 2026-07-10 after review-tree tools added bounded multi-turn council calls).

<!-- applied-learning: run-focused-umbrella-tests-one-application-at-a-time-when-the-live-server-is-up -->
<a id="applied-learning-run-focused-umbrella-tests-one-application-at-a-time-when-the-live-server-is-up"></a>
**Run focused umbrella tests one application at a time when the live server is up.** Filesystem worktree isolation does not isolate fixed TCP ports: a root `mix test` command containing paths from multiple umbrella applications can start the full umbrella, collide with the running Gateway port, consume unbounded aggregate memory, and obscure the actual test result. Validators must invoke one app's test tree per fresh child BEAM under one shared monotonic deadline; use an isolated `MIX_BUILD_PATH`, while sharing only `MIX_DEPS_PATH` to avoid live-service collisions and compile-environment drift (found 2026-07-10 while verifying council lineage; production validator violation reproduced 2026-07-11 as exit 137 across 20 affected apps; port-isolation lesson reconfirmed 2026-07-15).

<!-- applied-learning: direct-mix-test-subprocesses-must-set-mix-env-test-explicitly -->
<a id="applied-learning-direct-mix-test-subprocesses-must-set-mix-env-test-explicitly"></a>
**Direct Mix test subprocesses must set `MIX_ENV=test` explicitly.** Project `cli.preferred_envs` can override Mix's usual test-task environment, especially in isolated validators that call the wrapper through `Port`. Default direct `["test" | args]` runs to test env, let an explicit caller environment win, and preserve both the head and failure tail in bounded compile feedback so setup noise cannot hide the actionable error (found 2026-07-11 during cross-app validation).

<!-- applied-learning: caller-configurable-resource-bounds-need-a-system-enforced-ceiling -->
<a id="applied-learning-caller-configurable-resource-bounds-need-a-system-enforced-ceiling"></a>
**Caller-configurable resource bounds need a system-enforced ceiling.** Adding `max_output_bytes`, `max_rows`, or a similar positive option does not make execution bounded if an agent can pass an arbitrarily large integer. Define a conservative default and a non-bypassable hard maximum at the enforcing layer, clamp or reject larger values consistently, mirror the maximum in schema-bounded adapters, and classify the parameter as control when it governs termination or resource use (found 2026-07-11 reviewing bounded shell output).

<!-- applied-learning: when-work-moves-into-a-shared-loader-remove-obsolete-outer-processing-passes -->
<a id="applied-learning-when-work-moves-into-a-shared-loader-remove-obsolete-outer-processing-passes"></a>
**When work moves into a shared loader, remove obsolete outer processing passes.** `ensure_graph/2` was changed to perform IR compilation, but public `compile/2` retained its old `IR.Compiler.compile/1` call. The second pass was merely wasteful for untouched graphs but recompiled post-IR custom transforms, restoring alias defaults and changing capability/taint/schema analysis contrary to the documented boundary. Trace the full facade path after centralizing work and add a regression whose transform/output distinguishes one pass from two (found 2026-07-11 while fixing authorized graph loaders).

<!-- applied-learning: a-shared-deadline-must-be-checked-after-every-child-invocation-including-the-last-one -->
<a id="applied-learning-a-shared-deadline-must-be-checked-after-every-child-invocation-including-the-last-one"></a>
**A shared deadline must be checked after every child invocation, including the last one.** Passing the remaining budget into a subprocess is not sufficient if the runner can return a nominal success after that budget; a loop that returns `:complete` when no children remain can then accept an overrun. Measure from before runner setup and reject any result observed after the absolute monotonic deadline, even when it came from the final child (found 2026-07-11 reviewing per-app cross-app validation).
Tests that assert an exact launched budget at a deadline boundary must inject the same monotonic clock seam; real scheduling time can legitimately reduce the remaining budget by 1 ms and make an equality assertion flaky (reconfirmed 2026-08-27 during P1B-2A contained validation).

<!-- applied-learning: process-output-is-arbitrary-bytes-until-proven-otherwise -->
<a id="applied-learning-process-output-is-arbitrary-bytes-until-proven-otherwise"></a>
**Process output is arbitrary bytes until proven otherwise.** Shell and Port results can contain invalid UTF-8, so retaining them directly in JSON-clean Engine evidence can make `Jason.encode!/1` crash after the operation completed. Hash the original bytes, convert retained excerpts to valid UTF-8, and apply byte ceilings with boundary-safe truncation rather than `String.length/1` or grapheme slicing (found 2026-07-11 reviewing cross-app validation evidence).

<!-- applied-learning: a-struct-pattern-is-not-hostile-term-shape-validation -->
<a id="applied-learning-a-struct-pattern-is-not-hostile-term-shape-validation"></a>
**A `%Struct{}` pattern is not hostile-term shape validation.** A map carrying only `__struct__` and a subset of fields can satisfy the pattern, then raise on dot access or reach a shared broker with malformed data. Reconstruct opaque security references through their validating `new/1` factory using `Map.get/2` before reading fields or calling a broker, and return a shaped fail-closed error for partial struct-tagged maps (found 2026-07-11 reviewing SigningAuthority Engine propagation).

<!-- applied-learning: a-conformance-harness-is-not-a-gate-until-production-adapters-and-failure-exit-semantics-exist -->
<a id="applied-learning-a-conformance-harness-is-not-a-gate-until-production-adapters-and-failure-exit-semantics-exist"></a>
**A conformance harness is not a gate until production adapters and failure exit semantics exist.** Scripted callbacks are useful deterministic unit fixtures, but they do not prove that both real executors ran, selected different implementations, produced correct artifacts, or remained isolated. A benchmark command must invoke pinned production adapters, verify each result against the objective independently of pair equivalence, avoid process-global selector mutation, and exit nonzero when acceptance thresholds fail (found 2026-07-11 reviewing the first coding benchmark foundation).

<!-- applied-learning: bound-retained-output-and-the-work-required-to-produce-it -->
<a id="applied-learning-bound-retained-output-and-the-work-required-to-produce-it"></a>
**Bound retained output and the work required to produce it.** A 2 KB excerpt is not a resource bound if invalid-UTF-8 repair recursively concatenates an 8 MiB stream or suffix extraction builds a codepoint list for the whole input. Hash raw bytes once, then sanitize bounded head/tail windows with linear iodata accumulation and inspect only a small UTF-8 boundary allowance (found 2026-07-11 reviewing cross-app validation evidence).

<!-- applied-learning: arbor-recompile-cannot-repair-every-loaded-object-mismatch -->
<a id="applied-learning-arbor-recompile-cannot-repair-every-loaded-object-mismatch"></a>
**`arbor.recompile` cannot repair every loaded-object mismatch.** It delegates to `IEx.Helpers.recompile/0`, which recompiles changed source; if the on-disk BEAM is current but the long-running VM still has an older object loaded, it can return success/noop while execution-manifest checks continue failing with `execution_module_loaded_code_mismatch`. Reload the exact reviewed modules explicitly or use the purpose-built `arbor.restart` between delegated runs when no task is active (found 2026-07-11 after integrating Engine handler changes).

<!-- applied-learning: starting-an-agent-with-start-session-false-does-not-disable-autonomous-heartbeats -->
<a id="applied-learning-starting-an-agent-with-start-session-false-does-not-disable-autonomous-heartbeats"></a>
**Starting an agent with `start_session: false` does not disable autonomous heartbeats.** `Lifecycle.start/2` derives HeartbeatService separately and defaults `start_heartbeat` to true, so a coordinator started only for async dispatch can still run background checks and create unrelated shell approvals. For a dispatch-only coding coordinator use both `start_session: false` and `start_heartbeat: false`; do not answer heartbeat approvals as though they belonged to the delegated task (found 2026-07-11 after restarting the local Arbor server).

<!-- applied-learning: a-one-pass-green-race-regression-is-not-evidence-of-stability -->
<a id="applied-learning-a-one-pass-green-race-regression-is-not-evidence-of-stability"></a>
**A one-pass green race regression is not evidence of stability.** Concurrency, timeout, cleanup, and mutation tests must run repeatedly with `--repeat-until-failure` (or an equivalent deterministic stress loop) before sign-off. Replace startup sleeps with explicit ready/accepted handshakes and register teardown before the concurrent actor starts; a candidate that passed once returned a hash on the very next repeated run while its file was being rewritten (found 2026-07-11 reviewing eval persistence R3).

<!-- applied-learning: caller-writable-ets-is-not-independent-evidence -->
<a id="applied-learning-caller-writable-ets-is-not-independent-evidence"></a>
**Caller-writable ETS is not independent evidence.** A `:public` cleanup table created by whichever benchmark caller arrives first can be forged, disappears with that owner, and grows without TTL; copying its value into a recomputed summary only moves the trust problem. Security-relevant run evidence needs a dedicated bounded owner, opaque owner-bound lifecycle, proactive expiry, and a fail-closed restart contract (found 2026-07-11 reviewing coding benchmark R6).

<!-- applied-learning: dominance-over-named-success-terminals-does-not-gate-the-side-effects-that-precede-them -->
<a id="applied-learning-dominance-over-named-success-terminals-does-not-gate-the-side-effects-that-precede-them"></a>
**Dominance over named success terminals does not gate the side effects that precede them.** A semantic preflight can prove that `status_pr_created` is review-dominated while still accepting an allowlisted `git_pr` action injected before validation that rejoins the normal graph afterward. Constrain each side-effecting action to reviewed node identities/topology or prove the relevant gate dominates every occurrence of that action; terminal-only publication checks are insufficient (found 2026-07-11 with an executable early-PR compiler probe).

<!-- applied-learning: batch-response-order-is-not-input-order-when-the-protocol-supplies-indices -->
<a id="applied-learning-batch-response-order-is-not-input-order-when-the-protocol-supplies-indices"></a>
**Batch response order is not input order when the protocol supplies indices.** Embedding and fan-out APIs must validate response indices as unique, complete, bounded integers and reorder by those indices before associating results with inputs. Preserving wire order can silently attach a valid result to the wrong request even when every vector passes shape validation (found 2026-07-11 reversing an OpenAI-compatible embedding batch response).

<!-- applied-learning: resource-bounds-belong-at-the-public-facade-not-only-one-adapter -->
<a id="applied-learning-resource-bounds-belong-at-the-public-facade-not-only-one-adapter"></a>
**Resource bounds belong at the public facade, not only one adapter.** A bounded Finch/SSE implementation does not protect `generate_object`, tool-argument decoding, OAuth transports, or injected adapters that still call `Jason.decode/1`, buffer an enumerable, or use inactivity timeouts directly. Enforce structural decode, aggregate retention, absolute deadline, and owned-stream teardown at every public entry point; adapters may tighten but never bypass the floor (found 2026-07-11 reviewing the LLM/AI eval boundary).

<!-- applied-learning: umbrella-runtime-config-must-not-execute-modules-from-an-optional-child-app -->
<a id="applied-learning-umbrella-runtime-config-must-not-execute-modules-from-an-optional-child-app"></a>
**Umbrella runtime config must not execute modules from an optional child app.** `config/runtime.exs` is evaluated when a lower-level child runs independently, so calling `Arbor.Agent.Config` there made `arbor_security` fail before its tests because `arbor_agent` was not compiled or loaded. Keep runtime config data-only; validate an app-specific environment selector inside that app's startup boundary, where the module and its dependencies are guaranteed to exist (found 2026-07-11 running the isolated Security suite).
A `mix run --no-start` inspection still evaluates runtime config. For compiled-code
introspection in an isolated leaf, isolate its operator-state home and relevant
external config selectors instead of starting unrelated apps to satisfy a
host-specific loader. Check the pinned Mix parser before assuming a flag can
skip runtime config (reinforced 2026-09-27 during native source inspection).

<!-- applied-learning: compile-env-reads-must-target-the-exact-runtime-invariant -->
<a id="applied-learning-compile-env-reads-must-target-the-exact-runtime-invariant"></a>
**Compile-time config reads must target the exact invariant, not a runtime-overridable parent.** `Application.compile_env(app, Module)` records the whole keyword list; changing a sibling runtime value such as an endpoint port then fails Mix's compile-env validation even when the compile-time `:code_reloader` flag is unchanged. Use a nested path such as `[Module, :code_reloader]` with an explicit default whenever sibling values are configured in `runtime.exs` (found 2026-08-25 when `arbor.recompile` rejected a dashboard port override whose only semantic difference was keyword order).

<!-- applied-learning: a-mismatched-reference-regression-does-not-cover-an-exactly-copied-internal-message -->
<a id="applied-learning-a-mismatched-reference-regression-does-not-cover-an-exactly-copied-internal-message"></a>
**A mismatched-reference regression does not cover an exactly copied internal message.** If a completion PID/ref/token is visible in GenServer state, an attacker can copy the entire expected tuple rather than guess one field. Regress the exact copied envelope and raw OTP protocol messages; bind completion to cryptorandom one-shot authority that is absent from observable owner state (found 2026-07-11 forging TaskStore approval-cleanup completion).

<!-- applied-learning: a-userspace-deadline-check-cannot-hard-bound-a-later-blocking-kernel-commit -->
<a id="applied-learning-a-userspace-deadline-check-cannot-hard-bound-a-later-blocking-kernel-commit"></a>
**A userspace deadline check cannot hard-bound a later blocking kernel commit.** Checking `CLOCK_MONOTONIC` immediately before `rename`, `fsync`, ref-CAS, or another syscall still leaves a scheduling/blocking interval before the kernel linearization point; an interposed or stalled syscall can commit after the deadline. Do not respond by adding ever-closer prechecks and claiming a hard guarantee. Either use an OS primitive whose transaction is deadline/cancellation-bound, isolate the operation behind an owner the kernel can terminate before linearization, or define the public result as indeterminate with exact reconciliation/compensation. If none is available, record an assurance-layer architecture blocker rather than repeatedly rejecting otherwise correct local patches (found 2026-07-12 after benchmark R5 passed conservative BEAM/native deadline mapping but a delayed `renameatx_np` still published late).

<!-- applied-learning: separate-source-of-truth-commit-from-derived-state-synchronization -->
<a id="applied-learning-separate-source-of-truth-commit-from-derived-state-synchronization"></a>
**Separate source-of-truth commit from derived-state synchronization.** Git ref publication and real-index update are two independent durable resources; no ordinary Git primitive atomically commits both. Pick the authoritative commit, report an indeterminate/reconciliation-required result if the derived update fails, and make repair idempotent. Never return unconditional success after a best-effort derived update, but also do not demand impossible cross-resource atomicity from another local retry loop (clarified 2026-07-12 during reviewed-commit provenance R3).

<!-- applied-learning: consume-optional-cross-library-capabilities-through-the-owning-facade-and-its-real-contract -->
<a id="applied-learning-consume-optional-cross-library-capabilities-through-the-owning-facade-and-its-real-contract"></a>
**Consume optional cross-library capabilities through the owning facade and its real contract.** A caller that probes an invented backend callback such as `backend.durability_class/0` can reject a valid Store implementation whose supported contract is exposed as `Arbor.Persistence.durability_class/3`. Check the facade and callback arity before adding capability detection, and keep backend options flowing through that facade (found 2026-07-13 reviewing durable engine lifecycle admission).

<!-- applied-learning: distribution-readiness-is-not-application-readiness -->
<a id="applied-learning-distribution-readiness-is-not-application-readiness"></a>
**Distribution readiness is not application readiness.** `mix arbor.start` historically reported success when the named BEAM responded to distribution pings, while a later umbrella application could still fail and tear the node down before Gateway bound. The managed start now checks both distribution and all expected applications; verify the intended interface and inspect the daemon log if the process exits, rather than treating reachability alone as readiness (found 2026-07-13 recovering the Phase 6 delegator runtime; source reconciled 2026-09-29).
For a user-facing test handoff, check every prerequisite of the next action in the actual runtime, including durable budget configuration and a real read of its store. Device loopback and provider credential health do not establish readiness for a complete voice turn; also exercise a failed start followed by retry (reinforced 2026-09-28 after the voice preview reached an unconfigured ledger only after capture).
Evaluate execution restrictions per operation rather than inferring that every command is blocked: on 2026-09-29 the isolated test runner failed at Mix.PubSub socket creation, but the authorized normal managed restart compiled and started all applications successfully. Preserve the unrun-test limitation separately from observed deployment success.
Check the semantic success receipt for follow-up CLI operations too. The
`arbor.agent resume` task can print an error while exiting zero; an activation
launcher must verify the success line for the exact agent or confirm its state
through the owning facade before reporting it resumed (2026-09-30).

Preflight the complete manual handoff, including the retained browser recipe's
Python environment and the fixture's human terminal-login provider. A signed-in
web cookie and a working xAI subscription login do not establish Arbor terminal
sign-in. Reuse the qualified browser virtual environment; a system interpreter
can fail before Playwright imports (2026-10-05 physical UI qualification).

After an initial successful ping, an application-readiness RPC reporting
`{:badrpc, :nodedown}` should terminate startup promptly and retain the exact
managed launch tracking. Report that the node became unreachable; this does not
prove OS process death, and no PID probe, stop, restart or cleanup follows from
that result. Partial startup and `{:badrpc, :timeout}` keep their original bounded
budget. Do not describe an early node-loss failure as a completed long timeout
(2026-10-05 Main adoption exposed a dead daemon followed by a 600-second readiness
wait).

Match service readiness to the manager's current registration identity. A
supported restart can migrate a legacy label; inspect its installed naming
contract and verify the canonical job's executable, resource arguments and PID.
Retain a failed lookup separately, then require fresh positive connectivity
before dependent effects. Homebrew restarted PostgreSQL 18 under `sh.brew` on
2026-10-05 while the checker still queried `homebrew.mxcl`; repeating the repair
would have targeted an already running database.

Validate readiness parsers against actual manager output, including nested
metadata. Select fields at the owning job level and regress duplicate or missing
fields. A global whitespace match collected launchctl coalition `state = active`
entries and rejected the top-level `state = running` job on 2026-10-05; the
retained-output check caught this before the user handoff.

Include required SQL schema in feature adoption, independently of application
startup and HTTP health. Main's 2026-10-06 Home directory failed after a clean
build/start because both new conversation migrations were absent; the private
qualification databases had already applied them. Check the live Repo's catalog
and migration ledger before handing off an authenticated interface. Scope a
repair to the reviewed missing versions and retain any partial migration result;
an unrelated all-pending migration run is not the same operation.

<!-- applied-learning: authenticate-the-control-plane-service-not-only-its-cli -->
<a id="applied-learning-authenticate-the-control-plane-service-not-only-its-cli"></a>
**Authenticate the control-plane service, not only its CLI.** Apple Container's signed CLI writes a user-owned LaunchAgent for `container-apiserver`, while user configuration can select the VM kernel and vminit image. A containment backend must bind launchd's running program/argv to a separately pinned signed API-server binary and explicitly select root/operator-owned kernel, immutable init image, platform, and runtime values; self-reported health JSON is corroboration, not authority (found 2026-07-14 auditing Apple Container 1.1.0 before the imperative prober).

<!-- applied-learning: a-successful-exunit-command-can-still-execute-zero-regressions -->
<a id="applied-learning-a-successful-exunit-command-can-still-execute-zero-regressions"></a>
**A successful ExUnit command can still execute zero regressions.** Arbor's `:database` tag specifically means a test requires PostgreSQL and is excluded by default in `arbor_persistence`; a hermetic temporary-SQLite migration test carrying that tag reported success with every test excluded. Use the tag semantics in `TEST_TAGGING.md`, and verify the final executed test count rather than only the command exit status (found 2026-07-14 reviewing the SQLite migration infrastructure fix).

<!-- applied-learning: enforce-the-narrowest-byte-limit-before-calling-a-broader-hashing-helper -->
<a id="applied-learning-enforce-the-narrowest-byte-limit-before-calling-a-broader-hashing-helper"></a>
**Enforce the narrowest byte limit before calling a broader hashing helper.** `TrustedPath.pin_root_owned_regular_file/2` intentionally permits and hashes files up to its generic 512 MiB ceiling; checking a manifest-specific 32 MiB limit only after that pin still performs the expensive read. Preflight the exact file with `lstat`, reject its type, link count, mode, and size first, then require the pinned identity to match that observation so the early bound does not create a TOCTOU gap (found 2026-07-14 reviewing the Linux dependency-baseline source verifier).

<!-- applied-learning: do-not-run-real-process-setup-deadline-tests-under-asynchronous-suite-load -->
<a id="applied-learning-do-not-run-real-process-setup-deadline-tests-under-asynchronous-suite-load"></a>
**Do not run real process-setup deadline tests under asynchronous suite load.** An absolute timeout correctly includes native launcher and process-group setup, so a very small budget can expire before execution when dozens of async tests contend for the scheduler; that tests suite load, not command teardown. Run real OS lifecycle tests serially and give setup a conservative budget while keeping the command duration far beyond it, then assert the exact timeout result and process death (found 2026-07-14 when the full Shell suite intermittently returned `:timeout_during_setup` from the PortSession timeout regression).

Apply this policy to real BEAM watchdog tests too. Distinguish the original
remaining retirement interval from an incorrectly renewed interval with enough
separation for scheduler delay, then repeat the focused checks in fresh processes.
A focused pass followed by a combined-run timing miss is evidence to inspect,
not a reason to retry unchanged or lengthen product deadlines; timing alone
does not identify parallel contention as its cause (2026-10-05).

<!-- applied-learning: test-pure-consumers-with-the-exact-producer-envelope-not-a-convenient-synthetic-shape -->
<a id="applied-learning-test-pure-consumers-with-the-exact-producer-envelope-not-a-convenient-synthetic-shape"></a>
**Test pure consumers with the exact producer envelope, not a convenient synthetic shape.** A standalone core test can validate every local invariant while still accepting a map layout that its real upstream never emits. Mirror the producer's closed atom/string key placement, grouping, revision fields, and serialized scalar forms in the consumer fixture, then run both suites together; the Apple execution core originally passed against a flat purpose map while `Arbor.Actions.Mix.projections_for_resource/2` emitted grouped `read_only` / `read_write` lists (found 2026-07-14 composing the Phase 6 projection boundary).

Do not assume a `revision` field is an incrementing prompt generation. Arbor's
interaction attachment and answer contracts currently admit revision 1 only;
replacement prompts use fresh request/operation IDs. A mounted fixture that
fabricates revision 2 is refused before projection, even though a generic pure
consumer can represent positive revisions. Trace the public producer and codec
before changing the gate or extending a wait. Preserve failed receipts and label
corrected fixture bytes separately from earlier predecessor witnesses
(2026-10-04 conversation review-form qualification).
Verify the actual adapter error type and persisted identifiers before asserting a downstream branch: a real HTTP 429 can return a different error envelope from the Backoff classifier, and a stored Session UUID can differ from its external name. A synthetic shape proves the pure branch only. Exercise valid producer bounds before attributing an oversized fixture rejection to the consumer; retain defensive pure-boundary coverage when the storage codec rejects it earlier (reconfirmed 2026-09-09 in private-memory embedding and hybrid-search qualification).
Trace error tuple arity through public wrappers before freezing a predecessor
witness. A durable three-element error can miss a two-element `with` error clause
and become a generic public error; preserve the actual failure and correct its
causal assessment without changing the product test's success expectation
(2026-10-04 deny/rework JSON metadata qualification).
For browser-origin gates, check the response policy that shapes the next browser
request. `Referrer-Policy: no-referrer` can make an ordinary form POST send
`Origin: null`; a synthetic request with the expected Origin misses that failure.
Keep strict Origin/CSRF checks, use a compatible `same-origin` policy on clean
control pages, and retain `no-referrer` on secret bootstrap redirects. Regress
headers and the cookie/CSRF path, then exercise an actual browser submission
(2026-09-29 interactive fixture; [Fetch Origin algorithm](https://fetch.spec.whatwg.org/#append-a-request-origin-header)).
Carry the same browser-policy regression into newly copied sign-in issuers;
checking only their synthetic POST path is insufficient. The 2026-10-05
physical-audio issuer reintroduced the exact policy conflict and refused the
human approval after its source-only checks passed.
Trace a changed producer envelope through every consuming method, including
unchanged bodies. Execute the real admission gate without starting services
before handing off a launcher: Python source checks missed an Elixir reader's
stale retirement schema in the 2026-10-05 physical-audio fixture. A whole-module
no-start admission check reproduced the failure and verified the correction.
Read the actual receipt writer before declaring evidence missing. Terminal
handoff writes `exit-result.json`; checking an assumed `result.json` caused a
false missing-receipt report in the 2026-10-05 joined fixture.
Verify restored conversation parts through the selected provider's actual wire
encoder. A fake adapter can receive complete Session history while the OAuth
serializer drops persisted string-keyed text parts; test ordered user and
assistant history in the outgoing HTTP body, not only the adapter request
(2026-10-05 joined voice/typed phrase continuity).
Construct adapter-owned request fields consistently in Plug tests. `Plug.Test.conn`
sets parsed host/port but does not synthesize Cowboy's raw Host header; Plug's
general header mutators reject Host. A test of a raw Host gate needs a trusted
fixture constructor for both representations, including negative cases. Check
the pinned adapter API before handing off a test that fabricates a request
(2026-09-29 control regressions stopped in their helper before reaching the gate).

Protocol tests must assert the actual serialized shape, including nested values.
Canonical conversation submits encode the input map as the positional `[id, text]`
array; decoding the outer JSON does not restore that map. Match the canonical
array and stable command ID explicitly before injecting a transport fault. A string-key
lookup on that array stopped the terminal-session qualification before it reached
the intended authorization-loss assertion (2026-09-30).
Raw SQL also bypasses Ecto's typed loaders. With SQLite `{:array, :map}`, the
outer JSON array can contain JSON-encoded map strings. Decode each such part
once and require the expected map/text shape; retain exact role/text assertions.
On 2026-10-04, authenticated transcript reads were correct but a raw-SQL helper
failed after the streaming privacy assertions. Changing that helper changes the
committed test identity, so repeat the corrected test's predecessor/current
witness rather than claiming the earlier whole-file witness still applies.

<!-- applied-learning: escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration -->
<a id="applied-learning-escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration"></a>
**Escape backticks inside JavaScript template literals used for tool orchestration.** A delegated-task prompt embedded in a backtick-delimited JavaScript string fails before the MCP call if prose contains unescaped Markdown backticks. Use an array of ordinary quoted lines joined with `"\n"`, or escape every embedded backtick; this is distinct from shell command-substitution quoting (found 2026-07-14 dispatching the Apple unit lifecycle core).

<!-- applied-learning: prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence -->
<a id="applied-learning-prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence"></a>
**Prove resource absence positively; do not reinterpret an arbitrary lookup failure as absence.** A nonzero `inspect` can mean service loss, authorization failure, malformed input, or transport failure, not only `not found`. For enforcing cleanup, require a successful bounded inventory response and prove the exact owned identifier is absent from its parsed structured entries before releasing output or ownership (found 2026-07-14 designing Apple Container teardown).
Likewise, a running `osascript` process does not prove that a macOS authentication
dialog is visible. Describe the observed pending process and uncertainty, then
check its completion log and installed-file identities before asking the user to
act on an assumed prompt (user correction, 2026-09-27 native baseline promotion).
An inventory may bound output count without bounding execution time. Before using
it as an idle check, trace synchronous disk/native enrichment, shared lifecycle
mailboxes and caller-timeout cancellation. Global coding-resource enrichment can
continue after RPC timeout; use the cheapest source-owned projection that proves
the needed fact, and never interpret timeout or restart as resource absence
(found 2026-09-27 during the same promotion).

<!-- applied-learning: a-module-global-test-fake-must-not-be-linked-to-an-arbitrary-per-test-process -->
<a id="applied-learning-a-module-global-test-fake-must-not-be-linked-to-an-arbitrary-per-test-process"></a>
**A module-global test fake must not be linked to an arbitrary per-test process.** `ensure_started/0` plus `GenServer.start_link/3` can find the prior test's still-registered process just before that owner exits, then race into `:noproc` on the following call and cascade unrelated failures. Put shared fakes under a suite-stable supervisor/owner or start them unlinked with explicit reset/cleanup; per-test resources may remain linked to the test process unless cleanup must read them after exit (found 2026-07-14 in the Apple unit-worker held-absence suite). ExUnit exits tests with `:shutdown` before running `on_exit` in a separate process. Do not keep cleanup snapshots or a final-drain tracer only in test-linked processes; use a lifetime that spans the callback with explicit cleanup ownership, and cover partial setup failure as well as normal teardown. `start_supervised!` children also stop before `on_exit`, so supervision alone does not solve that lifetime requirement (confirmed against ExUnit 1.19.5 source while reviewing J0 on 2026-09-07).

<!-- applied-learning: exunit-setup-callbacks-cannot-dynamically-skip-a-test -->
<a id="applied-learning-exunit-setup-callbacks-cannot-dynamically-skip-a-test"></a>
**ExUnit setup callbacks cannot dynamically skip a test.** `setup` / `setup_all` accept only `:ok`, a context map/keyword list, or `{:ok, context}`; returning `{:skip, reason}` fails instead of skipping on the host where the prerequisite is absent. Compute the prerequisite at test compilation and attach a conditional `skip:` tag to only the affected tests or describes, leaving prerequisite-independent security regressions runnable (found 2026-07-14 making the macOS `shlock` journal tests portable).

<!-- applied-learning: configure-a-replacement-test-process-before-an-observer-can-discover-it -->
<a id="applied-learning-configure-a-replacement-test-process-before-an-observer-can-discover-it"></a>
**Configure a replacement test process before an observer can discover it.** Starting a named fake with permissive/default behavior and then resetting it in a second call creates a race: a monitored coordinator can resolve and invoke the replacement between those operations. Start the fake atomically in its intended mode, or suspend the observer across replacement setup and resume it afterward; otherwise a deterministic turnover regression can fail or, worse, pass through unintended behavior (found 2026-07-15 in the Apple reconciler-PID turnover test). Native/device tests must make real fallback impossible before calling the tested API. Mock expectations do not prove dependency interception was compiled in: verify the loaded fake module/NIF provenance in a fresh process, and abort if the real native boundary can resolve. A missed Mockery interception reached PortAudio initialization in an isolated ownership harness on 2026-09-27; three calls had recorded pre-open errors and a fourth discarded its result, so absence of capture could not be claimed categorically. Detect the actual OS before applying a platform permission gate; on that OS, a missing module or failed NIF load is denial, not evidence that the permission does not apply (2026-09-27 bounded capture review).

<!-- applied-learning: beam-monotonic-timestamps-may-be-negative -->
<a id="applied-learning-beam-monotonic-timestamps-may-be-negative"></a>
**BEAM monotonic timestamps may be negative.** `System.monotonic_time/1` uses an arbitrary origin; only differences and ordering are meaningful. Validate that samples are integers, not non-negative integers, and compute deadlines/durations by subtraction (`deadline - now`) so a perfectly healthy production clock is not rejected (confirmed 2026-07-15: the live node's millisecond sample was negative while reviewing the Apple executor).

<!-- applied-learning: startup-rehydration-is-not-runtime-distributed-discovery -->
<a id="applied-learning-startup-rehydration-is-not-runtime-distributed-discovery"></a>
**Startup rehydration is not runtime distributed discovery.** A survivor that starts before another node creates a run has an empty hot journal forever unless it refreshes from the durable authority while running. Refresh must decode without boot-normalizing a live remote owner, preserve a local runtime PID only while durable ownership/status still match, avoid delete-on-missing, and run before nodedown and recurring interrupted discovery (found 2026-07-15 designing L4 owner-node-loss recovery).

<!-- applied-learning: a-gate-regression-must-prove-it-reached-the-intended-gate -->
<a id="applied-learning-a-gate-regression-must-prove-it-reached-the-intended-gate"></a>
**A gate regression must prove it reached the intended gate.** A resume-authorization test that merely refutes an authorization error can pass vacuously when an earlier lifecycle admission returns `:not_found`; even the negative case then diagnoses the wrong subsystem. Satisfy every prerequisite with isolated fixtures, assert the exact denial for the negative case, and require actual successful completion for the authorized case (found 2026-07-15 after atomic resume admission made the older security regression vacuous).

<!-- applied-learning: keyset-pagination-must-bound-the-base-relation-before-expensive-joins-or-sorts -->
<a id="applied-learning-keyset-pagination-must-bound-the-base-relation-before-expensive-joins-or-sorts"></a>
**Keyset pagination must bound the base relation before expensive joins or sorts.** A joined query with `WHERE id > cursor ORDER BY id LIMIT n` can still scan and sort the entire remaining relation, especially after bulk staging with stale statistics. Materialize the exact cursor page first, index and analyze its cursor columns, then join that bounded page; validate the full-scale plan with `EXPLAIN (ANALYZE, BUFFERS)` and inspect temporary I/O. The EventLog identity preflight spilled about 190 GiB before mutation until this was fixed (found 2026-07-15 during the EventLog cutover).

<!-- applied-learning: a-fixed-internal-operation-that-needs-a-generically-blocked-flag-belongs-behind-a-closed-facade-primitive -->
<a id="applied-learning-a-fixed-internal-operation-that-needs-a-generically-blocked-flag-belongs-behind-a-closed-facade-primitive"></a>
**A fixed internal operation that needs a generically blocked flag belongs behind a closed facade primitive.** Do not make a business module call `Arbor.Shell.execute_direct(..., sandbox: :none)` because a generic facade correctly rejects `--force` or a similar flag. Add an exact operation to the owning facade, retain its executable/config/storage hardening there, expose no caller-controlled argv, and keep the generic dispatch surface restricted (found 2026-07-16 reviewing Git worktree cleanup).

<!-- applied-learning: in-zsh-status-is-a-read-only-special-parameter -->
<a id="applied-learning-in-zsh-status-is-a-read-only-special-parameter"></a>
**In zsh, `status` is a read-only special parameter.** A test wrapper that assigns `status=$?` fails after the command under test and can obscure its result. Use a neutral scalar such as `rc` when capturing an exit code (found 2026-07-16 rerunning isolated checkpoint-resume tests).

<!-- applied-learning: do-not-place-unescaped-markdown-backticks-inside-a-javascript-template-literal-used-for-tool-orchestration -->
<a id="applied-learning-do-not-place-unescaped-markdown-backticks-inside-a-javascript-template-literal-used-for-tool-orchestration"></a>
**Do not place unescaped Markdown backticks inside a JavaScript template literal used for tool orchestration.** The backtick terminates the transport string before the MCP call is made, so no task exists even though the failure appears next to dispatch. Use plain text inside the prompt, escape the delimiter, or build the payload from ordinary quoted strings (found 2026-07-16 dispatching the benchmark catalog materializer).

<!-- applied-learning: a-per-command-timeout-is-not-an-overall-operation-deadline -->
<a id="applied-learning-a-per-command-timeout-is-not-an-overall-operation-deadline"></a>
**A per-command timeout is not an overall operation deadline.** Reusing a full timeout for every Git/object step lets total setup grow with the number of calls, while reusing the worker execution timeout for fixture setup makes a healthy reconstruction fail under an unrelated short worker budget. Derive one absolute deadline for each bounded setup unit, pass only remaining time to nested calls, and keep setup, worker, cancellation, and cleanup budgets semantically distinct (found 2026-07-16 running the curated coding-benchmark materializer).

<!-- applied-learning: a-mix-task-that-calls-an-owning-facade-directly-must-start-that-narrow-application -->
<a id="applied-learning-a-mix-task-that-calls-an-owning-facade-directly-must-start-that-narrow-application"></a>
**A Mix task that calls an owning facade directly must start that narrow application.** A task can compile successfully yet fail when invoked from the CLI because `Arbor.Shell` workers are not running. Use `Application.ensure_all_started(:arbor_shell)` at the task boundary when Shell is the direct runtime dependency; do not start the whole umbrella merely to make a local command work (found 2026-07-16 exercising `arbor.coding.benchmark.prepare`).

<!-- applied-learning: do-not-redefine-built-in-elixir-typespec-names -->
<a id="applied-learning-do-not-redefine-built-in-elixir-typespec-names"></a>
**Do not redefine built-in Elixir typespec names.** Names such as `timeout` are built in and a local `@type timeout` can fail compilation on the pinned toolchain. Use a domain-specific name such as `deadline_ms` or reference the built-in type directly (found 2026-07-16 reviewing the benchmark Git deadline helper).

<!-- applied-learning: relocating-only-mix-exs-does-not-relocate-an-umbrella-project-coherently -->
<a id="applied-learning-relocating-only-mix-exs-does-not-relocate-an-umbrella-project-coherently"></a>
**Relocating only `MIX_EXS` does not relocate an umbrella project coherently.** Relative `apps_path`, lockfile, config, build, and dependency paths still resolve from the process/project context, while symlink facades can create divergent lexical roots. Keep the normal umbrella-root CWD or make every project path consistently absolute through one shared helper (found 2026-07-16 validating contained Mix execution).

<!-- applied-learning: avoid-brew-cat-for-read-only-formula-inspection -->
<a id="applied-learning-avoid-brew-cat-for-read-only-formula-inspection"></a>
**Avoid `brew cat` for read-only formula inspection.** It can enable Homebrew developer mode as a side effect; inspect the installed formula path directly when possible, and run `brew developer off` after an accidental enablement (found 2026-07-16 comparing Homebrew and standalone Apple Container installations).

<!-- applied-learning: a-mix-task-s-compile-claim-needs-an-explicit-compile-requirement -->
<a id="applied-learning-a-mix-task-s-compile-claim-needs-an-explicit-compile-requirement"></a>
**A Mix task's compile claim needs an explicit compile requirement.** `arbor.recompile` documented that Mix compiled local source first, but without `@requirements ["compile"]` it compared the running VM only with the stale on-disk BEAM and truthfully reported every module unchanged. When a task consumes fresh build artifacts, declare the requirement and regression-test the task metadata; verify the reload behaviorally rather than trusting a zero-failure summary (found 2026-07-17 while loading the review-decision projection fix).

<!-- applied-learning: when-changing-every-mix-exs-shape-exercise-static-consumers-of-mix-project-source -->
<a id="applied-learning-when-changing-every-mix-exs-shape-exercise-static-consumers-of-mix-project-source"></a>
**When changing every `mix.exs` shape, exercise static consumers of Mix-project source.** Moving `project/0` from a direct keyword-list body to `paths = ...` followed by that list kept Mix behavior correct but made the fail-closed cross-app AST parser reject every app as `:dynamic_or_malformed_project`. A static parser can safely follow Elixir block return semantics and inspect the final expression while still rejecting a variable or call as the returned project metadata; include that source shape in parser regressions before relying on live validation (found 2026-07-16 during Phase 6 cross-app dogfood).

<!-- applied-learning: a-platform-label-is-not-native-artifact-architecture-evidence -->
<a id="applied-learning-a-platform-label-is-not-native-artifact-architecture-evidence"></a>
**A platform label is not native-artifact architecture evidence.** The upstream `sqlite_vec` asset named `linux-aarch64` for v0.1.5 was actually ELF32 ARM because its release job used `arm-linux-gnueabihf-gcc`. Before attesting a Linux dependency baseline, inspect the binary header and load the extension in the exact network-disabled guest runtime; filenames and release metadata are insufficient (found 2026-07-17 provisioning the Apple Container baseline).

<!-- applied-learning: an-operation-deadline-and-a-bounded-probe-subdeadline-are-different-contracts -->
<a id="applied-learning-an-operation-deadline-and-a-bounded-probe-subdeadline-are-different-contracts"></a>
**An operation deadline and a bounded probe subdeadline are different contracts.** Raising the spawn-capable operation ceiling to 600 seconds does not authorize a 600-second admission probe whose reviewed maximum is 300 seconds. Preserve the caller's full absolute operation deadline, derive the probe timeout as `min(operation_remaining, probe_max)`, and let later execution consume the remaining operation budget; clamping the shared deadline itself silently restores the old ceiling (found 2026-07-17 while unifying Apple Container validation timeouts).

<!-- applied-learning: cross-app-closure-size-is-part-of-task-scoping-not-a-reason-to-weaken-validation -->
<a id="applied-learning-cross-app-closure-size-is-part-of-task-scoping-not-a-reason-to-weaken-validation"></a>
**Cross-app closure size is part of task scoping, not a reason to weaken validation.** A change in a low-level app such as `arbor_common` selects nearly the full downstream umbrella; one large dependent suite can legitimately consume the shared test-stage budget even when the changed app's focused tests pass. Use a bounded high-level real task for acceptance dogfood, and treat a low-level closure timeout as an explicit validation result that needs a separately reviewed budget or profile design change (found 2026-07-17 after `arbor_actions` exhausted the 600-second test stage).

<!-- applied-learning: generated-elixir-source-needs-a-behavioral-compile-test -->
<a id="applied-learning-generated-elixir-source-needs-a-behavioral-compile-test"></a>
**Generated Elixir source needs a behavioral compile test.** Substring assertions did not catch a generated `String.starts_with?/2` call inside a guard, which Elixir rejects. Parse and compile the generated module under the pinned toolchain, then exercise its load-bearing boundary functions; keep remote calls in function bodies rather than guards (found 2026-07-18 before rerunning security-regression dogfood).

<!-- applied-learning: mix-arbor-rpc-accepts-one-positional-elixir-expression-and-no-timeout-flag -->
<a id="applied-learning-mix-arbor-rpc-accepts-one-positional-elixir-expression-and-no-timeout-flag"></a>
**`mix arbor.rpc` accepts one positional Elixir expression and no timeout flag.** When a shell wrapper constructs the call, keep the expression itself on one physical argument line and encode any message newlines inside its Elixir string; passing a JSON-escaped multiline expression can deliver literal `\\n` tokens outside a string and fail parsing before RPC. Use the task API's own bounded operations rather than inventing `--timeout` for this Mix task (found 2026-07-18 steering `task_188034`).

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

<!-- applied-learning: tests-that-mutate-global-application-config-must-not-run-async -->
<a id="applied-learning-tests-that-mutate-global-application-config-must-not-run-async"></a>
**Tests that mutate shared runtime state must not run async and must restore every
injected seam.** Capture each prior Application value or GenServer callback before
replacement and restore it in `on_exit`; otherwise randomized later tests inherit
the fault. Restoration still does not prevent another async module from observing
the temporary value, so mark the whole module `async: false` whenever it changes
shared Application env, globally named processes, GenServer state, or shared ETS
state (found 2026-07-19 when the Comms suite intermittently hid the Signal response
channel; reinforced 2026-07-28 when retained-workspace reconciliation tests leaked
archive and cleanup callbacks into later tests).

<!-- applied-learning: elixir-is-list-1-recognizes-cons-cells-including-improper-lists -->
<a id="applied-learning-elixir-is-list-1-recognizes-cons-cells-including-improper-lists"></a>
**Elixir `is_list/1` recognizes cons cells, including improper lists.** For `[a, b | tail]`, `is_list/1` is true for the outer list and for the remaining `[b | tail]`; it becomes false only at the final non-list tail. Do not infer that an improper spine bypasses a guarded recursive list walker. Reproduce the exact term in IEx/Tidewave before changing security traversal logic; bound each visited head and explicitly handle the final tail (verified 2026-07-19 while reviewing `LogRedactor`).

<!-- applied-learning: async-generated-exunit-tests-must-compile-shared-helper-modules-in-setup-all -->
<a id="applied-learning-async-generated-exunit-tests-must-compile-shared-helper-modules-in-setup-all"></a>
**Async generated ExUnit tests must compile shared helper modules in `setup_all`.** A
generated S3 detector test compiled the same detector module in per-test `setup`; its
positive and false-positive tests could run concurrently, redefining the module and
intermittently failing an otherwise unrelated validation shard. Compile immutable shared
modules once per generated test module, and leave only per-test resources in `setup`
(found 2026-07-19 during cross-app validation of the legacy council authority fix).

<!-- applied-learning: retain-compiled-beam-binaries-when-loading-exs-diagnostic-modules-remotely -->
<a id="applied-learning-retain-compiled-beam-binaries-when-loading-exs-diagnostic-modules-remotely"></a>
**Retain compiled BEAM binaries when loading `.exs` diagnostic modules remotely.** A
module defined directly in an `.exs` launcher may return `:error` from
`:code.get_object_code/1`, even immediately after compilation, so a helper that recompiles
locally and then asks the code server for bytes cannot be transferred to a running node.
Keep the `{module, beam_binary}` tuple returned by `Code.compile_quoted/1` or
`Code.compile_string/1` and pass that exact binary to `:code.load_binary/3` on the target
node (found 2026-07-20 while launching the Phase 6 r10 benchmark).

<!-- applied-learning: plain-beam-hot-loading-does-not-migrate-live-genserver-state -->
<a id="applied-learning-plain-beam-hot-loading-does-not-migrate-live-genserver-state"></a>
**Plain BEAM hot loading does not migrate live GenServer state.** `arbor.recompile` uses `:code.load_binary/3`; it does not invoke `code_change/3`. When a hot-reloaded module adds state keys, either reload through `:sys.change_code/4` or make reads and writes backward-compatible with pre-reload maps until the state is materialized; otherwise the first post-reload call crashes the server (found 2026-07-20 after adding AcpPool settlement tracking).

<!-- applied-learning: serialize-mix-commands-within-each-worktree -->
<a id="applied-learning-serialize-mix-commands-within-each-worktree"></a>
**Serialize Mix commands within each worktree.** A worktree isolates source and runtime paths from the live checkout, but concurrent `./bin/mix` processes inside that same worktree still share `_build`, deps, compile locks, and application-level resources. Run focused suites one at a time; parallelize by giving each process its own worktree and runtime paths, never by launching concurrent Mix commands in one checkout. Do not run manager-side tests in a retained coding-task worktree while pipeline validation owns it, even with a private `MIX_BUILD_PATH`: ExUnit `@tag :tmp_dir` defaults beneath the application and can invalidate the attested candidate fingerprint. For a tree-bound regression, allocate an exclusive cryptorandom directory under `System.tmp_dir!()`, register cleanup, and keep all scratch bytes there. Verify through a separate worktree or wait until the task is terminal (found 2026-07-20 during delegated branch-lifecycle validation; reinforced 2026-08-15 when an independent E0B2P test made exact validation fail closed as `:dirty_workspace`).

<!-- applied-learning: format-only-scoped-paths-in-an-inherited-or-dirty-worktree -->
<a id="applied-learning-format-only-scoped-paths-in-an-inherited-or-dirty-worktree"></a>
**Format only scoped paths in an inherited or dirty worktree.** Running umbrella-wide `mix format` can rewrite unrelated files whose formatting already drifted from the current formatter, turning a narrow task into noisy collateral churn. Run `./bin/mix format path ...` for intended files, then inspect `git diff --name-only` before staging; reserve a repository-wide format pass for an explicit cleanup task (found 2026-07-20 during steering-delivery implementation). Build formatter arguments from the validated ownership-manifest schema and require a nonempty list of existing owned files: a wrong JSON key can silently produce no arguments and invoke project-wide formatting. Keep that formatting precondition separate from predecessor compilation, where newly added runtime files may deliberately be absent (2026-10-03 notice qualification).

Scoped `mix format` is still build-capable. Pinned Mix 1.19.5's
`Format.plugin_loader/1` calls `loadpaths`, which can compile dependencies,
then `compile` if plugins remain unloaded. Explicit filenames and application
cwd bound formatting, not its dependency or build scope. On 2026-10-04,
Dashboard formatting changed 13 bound host artifacts; a later configured
two-file rework format recompiled dependencies across the umbrella. Use a
separate preparation image and compare artifact inventories as well as source
diffs. Preserve failed qualification and compilation logs, then independently
bind and review the rebuilt outputs before tests. Never restore attested bytes,
classify BEAM changes as operational-cache output, or admit unexpected artifact
changes as successful qualification.

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

<!-- applied-learning: verify-that-an-exunit-line-filter-selected-the-intended-test -->
<a id="applied-learning-verify-that-an-exunit-line-filter-selected-the-intended-test"></a>
**Verify that an ExUnit line filter selected the intended test.** A `mix test file.exs:line` selector aimed at an `@tag`, comment, or nearby blank can resolve to the preceding test and produce a convincing but irrelevant pass. Point at the actual `test` declaration, then inspect the traced test name or distinctive fixture output before using the result as regression proof (found 2026-07-21 while proving the Git checkout-loss regression fails on the unfixed clause order).

<!-- applied-learning: run-the-full-dot-contract-test-file-after-changing-packaged-graph-bindings -->
<a id="applied-learning-run-the-full-dot-contract-test-file-after-changing-packaged-graph-bindings"></a>
**Run the full DOT contract test file after changing packaged graph bindings.** A targeted end-to-end scenario can pass while a stale structural assertion elsewhere still encodes the previous context contract. After changing packaged DOT node attributes or `context_keys`, run the complete graph contract test file in addition to focused regressions; static graph-shape assertions are part of the contract and should move in the same slice (found 2026-07-21 while validating uncertain-send owner-baseline recovery).

<!-- applied-learning: reproduce-a-suspected-runtime-failure-before-steering-a-security-fix -->
<a id="applied-learning-reproduce-a-suspected-runtime-failure-before-steering-a-security-fix"></a>
**Reproduce a suspected runtime failure before steering a security fix.** Standard-library behavior can differ from memory or intuition; a plausible fail-open claim is not evidence. Exercise the exact value on the project's pinned runtime before asking a delegated worker to add a security regression. A regression test must fail on the pre-fix code, and a correction sent after a same-session follow-up starts will queue behind that turn rather than preempt it (found 2026-07-21 after incorrectly assuming `String.trim/1` raises on invalid UTF-8 during evidence-ref review).

<!-- applied-learning: validation-feedback-must-preserve-failure-local-diagnostics-not-only-stream-head-and-tail -->
<a id="applied-learning-validation-feedback-must-preserve-failure-local-diagnostics-not-only-stream-head-and-tail"></a>
**Validation feedback must preserve failure-local diagnostics, not only stream head and tail.** Broad ExUnit runs can place the failing assertion in the middle of megabytes of progress and warnings; a fixed head/tail excerpt then reports only startup and final counts, forcing an expensive rerun and encouraging speculative fixes. On nonzero exit, extract a bounded failure-centered window while retaining full-stream hashes and UTF-8/budget guarantees, and include exact seed/concurrency metadata needed for deterministic reproduction (found 2026-07-21 when cross-app validation reported 489 tests and 2 failures but omitted both failure blocks).

<!-- applied-learning: aggregate-failure-excerpts-must-anchor-within-a-structured-failed-child -->
<a id="applied-learning-aggregate-failure-excerpts-must-anchor-within-a-structured-failed-child"></a>
**Aggregate failure excerpts must anchor within a structured failed child.** Searching a joined stream for the first exception-shaped text can center on an expected exception fixture or log from a successful child and omit the actual failed child's diagnostic. Use the existing per-child pass/fail result to select a failed child first, then search only that bounded body for a diagnostic anchor; prose remains presentation evidence, never failure authority (found 2026-07-21 while recovering cross-app validation observability).

<!-- applied-learning: validation-batches-must-not-cross-app-test-root-boundaries -->
<a id="applied-learning-validation-batches-must-not-cross-app-test-root-boundaries"></a>
**Validation batches must not cross app test-root boundaries.** A global file-count/argv packer can place independent heavyweight suites from different umbrella apps in one child, making that child hit its per-process ceiling even when the aggregate stage budget is healthy. Partition the exact sorted inventory at canonical `apps/<app>/test` boundaries before count/byte packing, preserve global deterministic indices and hashes, and make resume validation recompute the same partition so forged cross-root batches fail closed (found 2026-07-21 when branch-lifecycle validation mixed `arbor_agent` behavioral tests with `arbor_commands` benchmarks in batch 11/27).

<!-- applied-learning: per-app-and-umbrella-tests-can-exercise-different-optional-runtime-branches -->
<a id="applied-learning-per-app-and-umbrella-tests-can-exercise-different-optional-runtime-branches"></a>
**Per-app and umbrella tests can exercise different optional-runtime branches.** A focused app test may run before an optional module is loaded and validate the fallback, while an umbrella run loads the module and validates the real integration. Make the fallback at least as restrictive as the integrated policy, test loaded and unavailable paths deliberately, and do not treat two green runs as evidence that they traversed the same branch (found 2026-07-21 when `SensitivityRouter` returned `:warn` without `Arbor.Trust` in the per-app suite but `:gated` through unknown-principal trust policy in the umbrella).

Choose the normal test launcher that supplies the integration's actual optional
runtime peers before changing production dependencies. On 2026-10-05 the Gateway
per-app suite lacked Agent and the Agent per-app journey lacked Phoenix; the
same selectors passed from the isolated umbrella root. Check each selected
standalone project's own lock and frozen archive closure too: the umbrella
archives did not include Breeze's additional BackBreeze release. Preserve failed
setup attempts and run only the unresolved groups after correcting the launcher.

<!-- applied-learning: in-zsh-path-is-the-array-form-of-path -->
<a id="applied-learning-in-zsh-path-is-the-array-form-of-path"></a>
**In zsh, `path` is the array form of `PATH`.** Assigning `path=...` as an ordinary loop variable rewrites command lookup for the current shell, so later commands fail with `command not found`. Use a neutral name such as `wt`, `target_path`, or `candidate` when iterating over filesystem paths (found 2026-07-21 while verifying accepted worktrees before lifecycle cleanup).

<!-- applied-learning: compile-and-test-in-the-same-mix-env -->
<a id="applied-learning-compile-and-test-in-the-same-mix-env"></a>
**Compile and test in the same `MIX_ENV`.** A focused `MIX_ENV=test mix test --no-compile` can execute stale test-environment BEAMs after a default-environment compile. Compile the touched app with `MIX_ENV=test` before a no-compile focused rerun, especially when another process shares the umbrella build directory (found 2026-07-21 while validating ACP managed-session regressions).

<!-- applied-learning: never-mutate-a-live-retention-journal-from-a-second-beam -->
<a id="applied-learning-never-mutate-a-live-retention-journal-from-a-second-beam"></a>
**Never mutate a live workspace-retention journal from a second BEAM.** The durable store intentionally enforces a single-writer inventory snapshot while the lease registry holds corresponding hot state. Offline cleanup that shares `ARBOR_HOME` can delete markers out of band, poison the store with `snapshot_mismatch`, and leave the registry stale. Use the live owner APIs; if reconciliation is required, first prove there are no active leases, repair the durable inventory, then restart both supervised store and registry so they rehydrate the same snapshot. Do not weaken drift detection to mask split ownership (found 2026-07-21 after out-of-band retained-workspace cleanup blocked subsequent coding-task acquisition).

<!-- applied-learning: negative-start-link-tests-must-trap-linked-init-failures -->
<a id="applied-learning-negative-start-link-tests-must-trap-linked-init-failures"></a>
**Negative `start_link` tests must trap linked init failures.** A GenServer that rejects configuration from `init/1` can propagate the stop reason over the new process link before an assertion observes the public `{:error, reason}` result. In the test process, enable `Process.flag(:trap_exit, true)`, assert the exact returned error, and separately assert that no child side effect began; do not weaken the production fail-closed init path to make the test easier (found 2026-07-21 while proving a mismatched launch-bound Grok model never starts the ACP client).

<!-- applied-learning: atom-interning-regressions-must-check-the-candidate-atom-not-the-vm-global-count -->
<a id="applied-learning-atom-interning-regressions-must-check-the-candidate-atom-not-the-vm-global-count"></a>
**Atom-interning regressions must check the candidate atom, not the VM-global count.** The BEAM atom table is process-global, so supervised background work or lazy module loading can legitimately increase `:atom_count` between two assertions even in an `async: false` test. Generate a unique untrusted string and prove `String.to_existing_atom/1` raises both before and after the public call; this tests the exact security invariant without unrelated runtime races (found 2026-07-22 during consolidated software-factory verification).

<!-- applied-learning: aggregate-tests-must-own-dependency-availability-and-global-process-lifecycle -->
<a id="applied-learning-aggregate-tests-must-own-dependency-availability-and-global-process-lifecycle"></a>
**Aggregate tests must own dependency availability and globally named process lifecycle.** Umbrella order can leave an optional service running even when an app-local run exercises its unavailable fallback, and a linked named process can outlive one test long enough to race the next setup. Inject the intended available or unavailable dependency explicitly, restore global config from an `async: false` module, and start test-owned named processes under `start_supervised!/1` so teardown is synchronous. Never use the accidental absence of a globally registered service as a fixture (found 2026-07-24 after the aggregate software-factory gate exposed Trust-dependent Gateway decisions and a dispatcher `:already_started` race).
Distinguish supervision shutdown from completion of a separate backend owner's cleanup. SQLite Sandbox owner exit can precede asynchronous connection check-in; a following read-then-write transaction on another physical connection can encounter a prior writer. For synchronous isolated fixture controls, run the same private migrations and a single physical Sandbox connection on both revisions, and label that evidence accurately; do not add sleeps, retry product operations or change production pool policy to hide the race (reconfirmed 2026-09-09 in relationship cleanup controls).

For cross-app SQL protocol tests, explicitly scope ancillary event adapters before
bootstrap; another app's test helper may silently change the selected writer.
Verify the effective Repo path before startup, since a worktree does not isolate
hardcoded test databases. Drive exact per-flush counts with a test-owned timer,
and register restoration before the first global swap, preserving dependency
order in one callback when LIFO callbacks would invert it (2026-09-28 audit
retirement qualification exposed all four fixture interactions).
Qualification lanes sharing one private database/build still need exclusive
ownership. A worktree protects the live runtime, but does not isolate concurrent
test commands from each other. Initialize migrations explicitly, serialize host
lanes, and record any single-connection SQLite Sandbox fixture policy separately
from production configuration (2026-10-02 conversation-window qualification).

Teardown calls can still need live persistence. Retire the fixture human through public Security and confirm identity absence while Repo and AuditRepo remain alive; stop those owners afterward. Publish a passing receipt only after retirement acknowledgements and normal helper shutdown. Failure-path best-effort cleanup must preserve the primary failure and cannot claim confirmed retirement.
When a fresh-output guard refuses a launcher, inspect public ownership, readiness and retirement records before diagnosing startup or choosing cleanup. An earlier user invocation may already own the runtime and browser paths; preserve that run and join it or request normal retirement (2026-10-05 v9 conversation fixture).

<!-- applied-learning: restart-recovery-regressions-must-pass-cold-and-standalone -->
<a id="applied-learning-restart-recovery-regressions-must-pass-cold-and-standalone"></a>
**Restart-recovery regressions must pass cold and standalone.** A larger suite can leave
Application env, compiled modules, or service processes warm enough to hide a cold-start
timeout or schema-replay defect. Run the exact restart case by itself as well as in its
owning file, and overlay that same test on the immediate parent for the failure proof.
Compiler fakes must consume the same configured template source as production; a fake
that bypasses it does not prove graph-upgrade recovery (found 2026-09-01 while repairing
settled coding-task rehydration after the design-council graph upgrade).

<!-- applied-learning: optional-deadline-controls-must-preserve-legacy-clock-sampling-order -->
<a id="applied-learning-optional-deadline-controls-must-preserve-legacy-clock-sampling-order"></a>
**Optional deadline controls must preserve legacy clock sampling order.** Adding an
earlier monotonic-clock read only for a new optional whole-operation deadline can
consume an injected test sample and change the established stage deadline. The
result is a behavioral regression even when the new option is absent, such as
moving a CrossApp capacity failure from runtime handoff to structural admission.
Derive optional deadlines without perturbing legacy samples when the option is
unset, and regress the nil/default path with the exact existing clock sequence
(found 2026-07-27 while adding terminal-gate budget projection).

<!-- applied-learning: a-fresh-build-path-and-an-external-deps-path-are-not-always-compatible-for-rebar-dependencies -->
<a id="applied-learning-a-fresh-build-path-and-an-external-deps-path-are-not-always-compatible-for-rebar-dependencies"></a>
**A fresh build path and an external deps path are not always compatible for
Rebar dependencies.** An isolated worktree that points `MIX_DEPS_PATH` at another
checkout while compiling into an empty `MIX_BUILD_PATH` can fail before project
code when an Erlang dependency cannot resolve generated or relative include
paths. Reuse a compatible pinned test build cache, or materialize the complete
dependency tree inside the worktree; do not diagnose the resulting dependency
compile failure as an application regression (found 2026-07-27 when fresh
`yamerl` compilation could not resolve its existing headers).

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

<!-- applied-learning: required-evidence-is-intent-not-an-executable-validation-program -->
<a id="applied-learning-required-evidence-is-intent-not-an-executable-validation-program"></a>
**Coding work-packet `required_evidence` is intent, not an executable validation
program.** The default validation profile may run only warnings-as-errors
compilation even when the packet asks for a focused test command. Treat the
compiler-selected validation action as authority, then have the operator execute
and inspect any additional exact evidence command before approval; do not infer
that a green compile satisfied the packet's test requirement (found 2026-07-28
when a runtime `Enum.find!/2` error survived compile-only candidate validation).

<!-- applied-learning: a-green-exunit-exit-must-include-a-nonzero-intended-test-count -->
<a id="applied-learning-a-green-exunit-exit-must-include-a-nonzero-intended-test-count"></a>
**A green ExUnit exit must include a nonzero intended test count.** An exact
`mix test file.exs --only fast` command can exit zero with `0 tests, 0 failures`
when the module omitted the requested tag. Evidence admission must verify that
the expected module/tests were selected, not merely the process exit code or
zero-failure count (found 2026-07-28 during the Phase C delegated-work canary).
A wrong umbrella test path can also exit zero while every app reports that no
path matched. Resolve the path first and inspect the executed count before
recording a pass (reinforced 2026-09-27 during conversation continuity replay).
When freezing expected counts, expand module-level test-generation loops;
counting `test` declarations undercounts those cases. Independent source review
caught 12 declarations producing 15 conversation-binding cases before the
operator qualification was sealed (2026-09-30).
Require the completed ExUnit summary and unchanged source hashes even when the
exit is zero. SIGTERM can leave an interrupted BEAM with a zero exit after
printed test failures; retain that receipt as failed/interrupted instead of
accepting it (2026-10-03 target-attach qualification).

An absolute observation-only test file passed to umbrella Mix can load in every
child application. Register its `after_suite` callback only in the named owning
app and require that app's intended nonzero count before writing evidence. A
nonowning zero-test suite must not publish a receipt or collide with the owning
write. Associate the observer with the owning app's test root so Mix selects only
that application (2026-10-04 Comms qualification).

CLI summaries and returned runner statistics can have different valid totals.
Trace earlier specialized clauses before inferring behavior from a generic
counter clause: pinned ExUnit 1.19.5 excludes filtered tests from its displayed
test count, while `RunnerStats.total` includes them. Verify executed count from
the actual returned total/excluded/skipped values and retain the genuine summary
(2026-10-04 Dashboard launcher review).

Do not subtract exclusions twice when parsing the CLI summary: stock ExUnit
1.19.5's `3 tests, 0 failures (12 excluded)` means three selected tests. Skipped
tests still contribute to its displayed total. On 2026-10-05 a parser rejected
a genuinely green Agent journey by calculating minus nine. Correct the parser
and retain the original run when its normal exit, completed summary, zero skips
and full successful timed test names are already verified; do not rerun green
product tests merely to repair evidence parsing.

<!-- applied-learning: parenthesize-do-block-expressions-assigned-to-module-attributes -->
<a id="applied-learning-parenthesize-do-block-expressions-assigned-to-module-attributes"></a>
**Parenthesize do-block expressions assigned to module attributes.** In Elixir,
`@items for ... do ... end` binds the block to the module-attribute macro and
raises instead of assigning the comprehension. Use `@items (for ... do ...
end)` or an `Enum` pipeline expression; compile the touched module before
treating formatter success as syntax validation (found 2026-07-28 while adding
the executable coding-profile declaration guard).

<!-- applied-learning: recompile-the-live-runtime-after-integrating-action-or-handler-beams -->
<a id="applied-learning-recompile-the-live-runtime-after-integrating-action-or-handler-beams"></a>
**Recompile the live runtime after integrating action or handler BEAMs.** Coding
plans bind the loaded action catalog and handler identities before execution, so
source integration alone does not update a long-running node. An
`action_catalog_invalid` readiness terminal is the correct fail-closed signal
for loaded/on-disk drift, not a worker defect or a reason to rework the
candidate. Run the supported `./bin/mix arbor.recompile`, verify loaded
identities, and restart only when the supported reload cannot converge (found
2026-07-28 before the validation-capacity coding canary).

For a reviewed stop/build/start deployment, stop the old owning dev daemon before
fast-forwarding its canonical source checkout, as well as before compilation.
Phoenix can observe source changes and trigger automatic compilation/reload;
waiting until the explicit compile step leaves an unintended live transition.
Keep the prior process stopped through source integration and build, then verify
the newly started owner and loaded identities (clarified 2026-09-24 during the
agent-stack acceptance rollout).

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

<!-- applied-learning: detached-worktree-hooks-need-the-same-explicit-dependency-cache-environment-as-validation -->
<a id="applied-learning-detached-worktree-hooks-need-the-same-explicit-dependency-cache-environment-as-validation"></a>
**Detached-worktree hooks need the same explicit dependency-cache environment
as validation.** A temporary worktree without `deps/` cannot load formatter
`import_deps`; even after an explicit format succeeds, a commit hook will repeat
the failure unless `MIX_DEPS_PATH` and the isolated `MIX_BUILD_PATH` are also
present on `git commit`. Use a compatible pinned dependency cache, never the
live checkout's build path, and run format, compile, tests, and hooks under the
same environment (found 2026-07-28 while finalizing the managed ACP settlement
candidate). This also applies when committing from the main checkout: a pre-commit
hook can run Mix even when the operator did not explicitly request compilation.
Pass the isolated environment on the commit command itself; a preceding formatter
invocation does not export it to later commands (reinforced 2026-09-07 integration).

When reusing a build in a different execution root, discard its path-dependent
`_build/.mix/cached_dot_formatter` before qualification, or explicitly select the
owned child formatter. Mix can accept a copied cache by mtime while its child
formatter paths still name the old root. A normal successful format check may
then select root options and skip a child sigil formatter even though the plugin
loads and both formatter configs match. Verify formatting with the current
root's resolved child options (2026-10-03 isolated HEEx notice review).

Explicit hook filenames still use the invoking root's formatter options unless
registered subdirectories route them; standalone exports are not imported
automatically. On 2026-10-05, the root hook rejected four vendored Breeze files
because it lacked their exported `attr`/`slot` no-parentheses rules. Registering
the standalone plugin would also require that plugin in the root dependency
closure. When the missing rules are exported Elixir DSL options, import those
existing public exports into the root fallback without rewriting vendor files
or adding a lateral dependency; keep standalone sigil/plugin checks in their
own project. Verify the unchanged hook with the intended formatter options.

<!-- applied-learning: aggregate-validation-admission-must-not-sum-per-batch-maximums-before-running-any-test -->
<a id="applied-learning-aggregate-validation-admission-must-not-sum-per-batch-maximums-before-running-any-test"></a>
**Aggregate validation admission must not sum per-batch maximums before running
any test.** Per-batch caps are safety ceilings, not predicted durations; summing
all of them can reject a large affected set before the first batch even when
many batches finish quickly. Admit against one aggregate deadline, execute
batches until that deadline, and return exact completed and unstarted evidence
on capacity exhaustion without silently reducing required coverage (found
2026-07-28 when 38 cross-app batches were assigned a synthetic 45.6-million-ms
requirement against 272 seconds and all 667 test files remained unstarted).

<!-- applied-learning: conditional-readiness-fixtures-must-assert-their-precondition -->
<a id="applied-learning-conditional-readiness-fixtures-must-assert-their-precondition"></a>
**Conditional readiness fixtures must assert their precondition.** A regression
wrapped in `if Process.whereis(owner)` or another optional-readiness branch can
silently execute no assertion and still report green when the required service
never started. Start or inject the dependency explicitly, assert the fixture is
ready, and then prove the public behavior; a skipped negative-security path is
not evidence (found 2026-07-28 while reviewing pending-approval settlement
tests).

Derive every correlated readiness field from one actor snapshot. Two reads can
combine an old target's connected flag with a detached new target and report
readiness that never existed. Exercise controlled inputs through their actual
component path and assert its buffer agrees with display state; a named event
can bypass an absent textarea and manufacture a draft-loss failure. Hold target
acquisition explicitly to prove the unready state rather than adding delays
(2026-10-03 Breeze target switching). Existing fixtures must also answer newly
optional read operations with their closed unsupported result; crashing a fake
host is not evidence that an optional feature invalidates the conversation.

For hostile-input acceptance, first prove the actual tool delivered the exact
fixture with its provenance and required sanitizer evidence. A refused setup
read is not successful resistance to an injection the model never received.
Preserve missing delivery as incomplete. A model that reads the fixture and
refuses the attacker can be safe without attempting export; pair that observation
with a separate deterministic attempted-export refusal to prove the gate. Grade
the actual action receipt and durable outcome, naming an earlier Trust refusal
honestly rather than inventing a Security decision (reconfirmed 2026-09-24).

<!-- applied-learning: zsh-command-substitution-does-not-split-newline-path-lists -->
<a id="applied-learning-zsh-command-substitution-does-not-split-newline-path-lists"></a>
**Zsh command substitution does not split newline path lists by default.**
Passing `$(git diff --name-only ...)` to a formatter can produce one
newline-containing argument instead of one argument per path. Use a native Zsh
array expansion such as `${(@f)...}` for trusted line-delimited paths, or a
NUL-delimited producer and consumer for arbitrary filenames, then verify the
tool actually inspected the intended file count (found 2026-07-28 during the
Phase F scoped formatting check).

<!-- applied-learning: use-canonical-macos-temp-paths-for-rebar-backed-isolated-builds -->
<a id="applied-learning-use-canonical-macos-temp-paths-for-rebar-backed-isolated-builds"></a>
**Use canonical macOS temp paths for rebar-backed isolated builds.** On macOS,
`/tmp` resolves to `/private/tmp`; using a noncanonical `/tmp/...` value for
`MIX_BUILD_PATH` can make rebar dependency symlinks resolve through inconsistent
roots and fail valid dependency includes such as `yamerl`. Put isolated build
artifacts under the canonical `/private/tmp/...` path, keep `MIX_DEPS_PATH`
explicit, and let the worktree itself remain under either spelling (found
2026-07-29 while independently validating the interaction-wait candidate).

<!-- applied-learning: isolate-mix-build-roots-by-revision-and-environment -->
<a id="applied-learning-isolate-mix-build-roots-by-revision-and-environment"></a>
**Isolate Mix build roots by revision and environment.** `MIX_BUILD_PATH` is the
exact artifact directory and bypasses Mix's ordinary environment partitioning;
sharing one raw path between parent/candidate revisions or `dev`/`test` can run
stale BEAMs and invalidate comparison evidence. Give every revision and
`MIX_ENV` a distinct build root, and never use the live server's build tree for
two-revision proof (found 2026-07-30 while preparing the OAuth security
regression comparison).

<!-- applied-learning: run-directly-changed-app-tests-before-downstream-tests -->
<a id="applied-learning-run-directly-changed-app-tests-before-downstream-tests"></a>
**Run directly changed app tests before downstream tests.** A complete
dependency closure is still required, but a fixed aggregate deadline can expire
inside an alphabetically earlier downstream suite before testing the code that
actually changed. Preserve a deterministic direct-first app order through Git
inventory expansion, normalization, and batching, then report the exact
unstarted downstream suffix on capacity exhaustion without treating it as
success (found 2026-07-30 when an `arbor_common`/`arbor_security` OAuth change
spent its test budget in `arbor_actions` first).

<!-- applied-learning: missing-attested-native-baselines-must-defer-validation-not-trigger-host-discovery -->
<a id="applied-learning-missing-attested-native-baselines-must-defer-validation-not-trigger-host-discovery"></a>
**Missing attested native baselines must defer validation, not trigger host
discovery.** When isolated-worktree compilation cannot load a pinned native
artifact, do not scan broad host paths, probe release sites, or install an
opportunistic binary from inside the delegated task. Report the exact baseline
dependency, preserve the candidate, and let source-owned baseline provisioning
and verification complete outside no-network validation; only then rerun under
the pinned baseline. A broad fallback weakens supply-chain provenance and can
traverse protected user data (found 2026-07-31 when Phase E OAuth validation
searched `/` and probed GitHub for `sqlite-vec` while the reviewed baseline
awaited privileged installation).

<!-- applied-learning: conformance-proof-scanners-must-parse-test-syntax-not-regex-source-text -->
<a id="applied-learning-conformance-proof-scanners-must-parse-test-syntax-not-regex-source-text"></a>
**Conformance proof scanners must parse test syntax, not regex source text.** A
regex over `.exs` can count `@tag spec:` markers embedded in comments, string
fixtures, or docs as evidence, silently turning unimplemented requirements
green. Parse the AST and accept only literal ExUnit tag attributes; malformed
files should fail the scan instead of being skipped (found 2026-08-01 during the
voice specification preflight).

<!-- applied-learning: managed-lifecycle-commands-must-bind-to-the-persisted-running-node-identity -->
<a id="applied-learning-managed-lifecycle-commands-must-bind-to-the-persisted-running-node-identity"></a>
**Managed lifecycle commands must bind to the persisted running-node identity.**
Re-detecting the host on every invocation can make restart look for
`arbor_dev@new-host` while `arbor_dev@old-host` is still alive, skip shutdown,
overwrite PID metadata, and collide in EPMD. Persist the exact node name and
host with the PID at successful start; prefer an explicit operator override
only when intentionally relocating; use the stored identity for status, stop,
and restart; and refuse to start when a verified managed PID is alive but
unreachable. Regression-test host drift and stale or mismatched metadata (found
2026-08-02 restarting after Linux dependency-baseline activation).

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

<!-- applied-learning: isolated-validation-artifacts-need-owned-disk-admission-and-garbage-collection -->
<a id="applied-learning-isolated-validation-artifacts-need-owned-disk-admission-and-garbage-collection"></a>
**Isolated validation artifacts need owned disk admission and garbage
collection.** Check free bytes and inodes before admitting worker or validation
work, attach exact owner and attempt identity plus expiry to every artifact, and
clean only resources whose ownership and terminal state are proven. Treat
`ENOSPC` as an infrastructure failure that preserves the candidate; never delete
temporary paths by broad prefix and age alone (found 2026-08-02 after lifecycle
validation exhausted the host disk).

<!-- applied-learning: do-not-launch-long-lived-services-from-disposable-validation-build-roots -->
<a id="applied-learning-do-not-launch-long-lived-services-from-disposable-validation-build-roots"></a>
**Do not launch long-lived services from disposable validation build roots.**
An isolated `MIX_BUILD_ROOT` supplied to a lifecycle command can be inherited by
the background daemon, leaving the service dependent on a temporary path that a
later cleanup may reclaim. Use isolated roots for compile and test evidence, but
perform the final managed restart from a stable project build environment unless
the daemon boundary explicitly sanitizes transient build variables (found
2026-08-02 while verifying managed lifecycle identity).

<!-- applied-learning: portable-file-mode-probes-must-try-gnu-stat-before-bsd-stat -->
<a id="applied-learning-portable-file-mode-probes-must-try-gnu-stat-before-bsd-stat"></a>
**Portable file-mode probes must try GNU `stat` before BSD `stat`.** GNU
`stat -f` succeeds but prints filesystem details, so a BSD-first `||` chain
never reaches its GNU fallback in Linux containers and can falsely fail a
permission test. Use `stat -c '%a' file 2>/dev/null || stat -f '%Lp' file
2>/dev/null`, then validate the output shape (found 2026-08-02 when cross-app
validation falsely rejected the unrelated VP-04A candidate).

<!-- applied-learning: callback-validation-must-not-depend-on-incidental-module-preload -->
<a id="applied-learning-callback-validation-must-not-depend-on-incidental-module-preload"></a>
**Callback validation must not depend on incidental module preload.**
`function_exported?/3` returns false for a compiled but unloaded module, so a
focused test or first production call can reject a valid injectable adapter
while a full suite passes because another test loaded it. At an owned adapter
boundary, load and inspect exports deterministically (for example with a
catch-safe `module.module_info(:exports)`) before validating callbacks; prove
the behavior from an explicitly unloaded compiled module instead of preloading
it in the test (found 2026-08-03 while isolating VP-04D2B Session startup).
`Kernel.ParallelCompiler.compile_to_path/3` can emit a BEAM without loading its
module (2026-10-05). In a fresh no-start compiler probe, condition purge/delete
on `:code.is_loaded/1`, then explicitly load the emitted disk file. Verify its
actual `:code.which/1` path, compile-source path and loaded/on-disk code MD5
before accepting the artifact; a successful write does not prove loaded identity.

<!-- applied-learning: elixir-typespecs-cannot-express-singleton-binary-map-keys -->
<a id="applied-learning-elixir-typespecs-cannot-express-singleton-binary-map-keys"></a>
**Elixir typespecs cannot express singleton binary map keys.** Both
`%{"provider" => String.t()}` and `%{required("provider") => String.t()}` are
rejected as unexpected expressions in Elixir 1.19. When runtime data
deliberately uses exact string keys, keep a compilable generic string-key map
type and document the closed runtime shape in `@typedoc`; do not "fix" one
invalid literal-key form by switching to the other (found 2026-08-03 during
VP-05D1 validation rework).

<!-- applied-learning: test-facades-must-observe-production-ownership-not-reimplement-it -->
<a id="applied-learning-test-facades-must-observe-production-ownership-not-reimplement-it"></a>
**Test facades must observe production ownership, not reimplement it.** A
compatibility fake that translates a new handoff into an old one and separately
registers, drains, or removes cleanup can duplicate effects and turn valid
production behavior into broad failures. Once the concrete owner supports the
canonical protocol, delete the shim: delegate lifecycle operations to the real
owner and retain only observability and failure injection. Assert state on the
process that actually owns it, such as a cleanup lease that outlives its
coordinator (found 2026-08-04 reconciling Voice Session and ResourceOwner
migrations).

For acceptance, invoke the same execution owner as the deployed consumer:
`LLM.generate` and the Session's `ToolLoop.run` are different loops. Bind the
actual configured client, adapter map, plug order, auditor, and loaded owner
identity; source defaults alone do not describe runtime dependency injection.
In a private production-profile boot, configure isolated targets before their
owners start, retain enforcing flags, and verify public readiness before effects.
A test-profile bootstrap with disabled gates proves a different claim
(reconfirmed 2026-09-24 during hostile-document qualification).

A genuine Store and successful profile seeding do not prove readiness of a
facade's read path. Trace the selected action through its public facade to the
Manager or other required process; start that real collaborator under the
fixture's existing owner and verify public readiness and exact-PID cleanup.
Do not weaken the positive action assertion or replace the action with a canned
result (2026-10-04 protected profile-read acceptance).
Once that real owner is present, validate the real profile's effective resource
mode. A host-restricted permissive baseline becomes `:block`; a missing Manager's
fallback `:ask` can hide the omission of a required finite URI rule. Add the exact
fixture `:ask` rule through the public facade while retaining the host restriction
and capability approval constraint, rather than loosening policy to clear the
positive control.

Keep receipt serialization separate from the policy identity being observed.
Explicitly project known tagged structs, such as `%CapabilityProfile{}`, with
`Map.from_struct/1` before recursive JSON serialization; being a map does not
make a struct implement `Enumerable`. Refuse unknown struct types rather than silently
flattening them, and preserve the original raw term for the authoritative policy
fingerprint. Exercise the receipt against the actual public snapshot before
acceptance effects (found 2026-09-24 when metadata-only capture reached real
capability profiles).

Fingerprint model-visible tool data, not incidental runtime terms: Jido tool maps
can include callback functions whose node-creation identity changes after restart.
Project the exact advertised JSON schema and bind executable owners separately;
prove a fresh BEAM keeps the same profile while schema or executable changes still
invalidate it. Do not normalize unknown code differences because source matches.

Validate public configuration and result shapes against their actual owners
before acceptance effects. A private Repo started with explicit `ConnectionPool`
can still report Sandbox through `Repo.config/0` unless its owned configuration
matches; fix the fixture, not migration verification. PostgreSQL
`inet_server_addr()::text` can include `/32`; use `host(inet_server_addr())` when a gate
expects a bare address, retaining the exact loopback check. Managed Stop returns
`{:stopped, node_name}`; verify that tuple and separately observe the prior PID's
absence (found 2026-09-24 during deployed qualification and cold restart).

Production interaction acceptance must retain durable storage. Isolate and migrate the SQL database instead of disabling persistence, and assert the public `Arbor.Comms.durable_interaction_readiness/0` backend, namespace and durability before effects. The 2026-10-04 protected fixture initially disabled SQL interactions; a volatile choice/approval path would prove a different claim.

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

<!-- applied-learning: hermetic-readiness-canaries-must-inject-reviewed-toolchain-evidence -->
<a id="applied-learning-hermetic-readiness-canaries-must-inject-reviewed-toolchain-evidence"></a>
**Hermetic readiness canaries must inject reviewed toolchain evidence.** A
production toolchain resolver correctly fails closed when candidate BEAMs load
from an isolated build root because it must not authorize the
candidate-controlled `/workspace/bin/mix`. A deterministic readiness-green
canary should instead supply a bounded, digest-valid identity through its test
observer, while dedicated production tests cover resolver success and failure;
otherwise root-wide validation reports `toolchain_identity_unavailable` before
exercising the intended canary behavior (found 2026-08-14 during K2 app-env
validation).

<!-- applied-learning: prove-app-boundaries-by-running-from-the-child-project-with-a-fresh-build -->
<a id="applied-learning-prove-app-boundaries-by-running-from-the-child-project-with-a-fresh-build"></a>
**Prove app boundaries by running from the child project with a fresh build.**
`mix test apps/some_app/test` from the umbrella root still compiles the umbrella
and can make undeclared higher-level modules available, so a green result does
not prove the app-local dependency boundary. Run `mix test` with the working
directory set to `apps/some_app` and a fresh isolated `MIX_BUILD_PATH`; inspect
the compiled app list as well as the test result. This exposed 15 Security test
failures hidden by the umbrella build because fixtures still called Persistence,
Historian, Comms, and Phoenix modules (found 2026-08-20 during P1C acceptance).

<!-- applied-learning: in-zsh-harness-scripts-never-use-status-as-a-scratch-variable -->
<a id="applied-learning-in-zsh-harness-scripts-never-use-status-as-a-scratch-variable"></a>
**In zsh harness scripts, never use `status` as a scratch variable.** `status` is a read-only special parameter, so `status=$?` aborts cleanup exactly when a validation command fails. Use `exit_code`, capture it immediately, and install an `EXIT` trap before commands that create worktrees or build roots so cleanup runs on both success and failure (found 2026-08-20 while independently validating P1C-A).

<!-- applied-learning: application-env-snapshots-must-preserve-key-presence-separately-from-nil -->
<a id="applied-learning-application-env-snapshots-must-preserve-key-presence-separately-from-nil"></a>
**Application environment snapshots must preserve key presence separately from
`nil`.** `Application.get_env/3` collapses an explicitly configured `nil` and an
absent key, so teardown can delete a deliberate override and silently reactivate a
default backend. Snapshot with `Application.fetch_env/2` and restore `{:ok, value}`
versus `:error` exactly (found 2026-08-20 when Security teardown re-enabled JSONFile
and cascaded into 220 `:authority_root_unconfigured` failures).

<!-- applied-learning: a-baseline-is-only-valid-on-a-pinned-tree -->
<a id="applied-learning-a-baseline-is-only-valid-on-a-pinned-tree"></a>
**A baseline is only valid if it is the identical command on a PINNED tree.** Comparing a suite run "before" and "after" a change proves nothing when the scope differs or the tree moves. Three ways this went wrong on 2026-08-20: baselining a three-app `mix test` invocation against a single-file run (multi-app paths also defeat per-app BEAM isolation and manufactured 251 failures); "verifying" a fix against a call that produced nothing to suppress, reading a null result as a positive; and — worst — attributing failures to a new test file while another agent session committed concurrently, so the test count moved 1316 → 1322 → 1333 → 1376 between runs and every comparison was two different codebases. Before a before/after, record HEAD and `git status`, re-check both afterwards, and treat any change in total test count as invalidating the comparison. Corollary: `git stash` is NOT read-only on a shared tree — it mutates the index and left another session's new file in an unmerged `DU` state.

<!-- applied-learning: hot-reload-updates-modules-not-running-child-processes -->
<a id="applied-learning-hot-reload-updates-modules-not-running-child-processes"></a>
**Hot code reload updates modules; it does NOT restart supervised children or migrate their state.** A child started before a child-spec change keeps the args it was given at boot, so new code that pattern-matches on a field the old args never set fails on every call. The same rule applies when new code requires a newly added owner process: every module digest can be current while the owner is absent, making the facade correctly fail closed. Comparing loaded-vs-on-disk module md5 reports "not stale" and sends you the wrong way: the CODE is current, the PROCESS is not. Found 2026-08-21 — `Arbor.Historian.EventLog.ETS` started at 07:44; commit `d43f01758` added `mode: :projection` to its child spec at 12:19. Modules were hot-reloaded and every md5 matched disk, but the running process still had `mode: nil`, so the `%{mode: :projection}` clause never matched and every hot projection returned `:projection_mode_required`. Durable writes still succeeded, so it degraded silently into "every read falls through to the durable store" plus a generic warning whose real reason was swallowed. On 2026-08-25 the same class appeared as factory authorization denial: P1B policy code required `Arbor.Trust.PolicyHost`, but the live Trust application had not restarted to start it, so Security authorized while Trust returned `:policy_denied`. Diagnose by STATE and PROCESS presence, not by module: inspect `:sys.get_state/1` where applicable and verify every newly required registered owner exists. Restart the smallest owning application only after confirming no in-flight work depends on it. To size blast radius after a batch of commits: `git log --since="<server start>" --name-only --format="" -- 'apps/*/lib/**/application.ex' 'apps/*/lib/**/supervisor.ex' | sort -u` — anything listed is stale in the running system until that child restarts.

<!-- applied-learning: load-modules-before-installing-erlang-call-trace-patterns -->
<a id="applied-learning-load-modules-before-installing-erlang-call-trace-patterns"></a>
**Load modules before installing Erlang call trace patterns.**
`:erlang.trace_pattern/3` returns zero for an unloaded module and does not
retroactively attach when the module loads later. A call-tracing test must
`Code.ensure_loaded!/1` each target before installing patterns, and it must
drain trace delivery before terminating the tracer. Otherwise randomized test
order can make a security regression pass or fail according to which module an
earlier test happened to load (found 2026-08-23 during P1A-1 cross-app
validation).

<!-- applied-learning: compile-selected-test-modules-before-declaring-a-candidate-review-ready -->
<a id="applied-learning-compile-selected-test-modules-before-declaring-a-candidate-review-ready"></a>
**Compile selected test modules before declaring a candidate review-ready.**
Warning-strict `mix compile` proves production modules, not `test/**/*.exs`; an
invalid test pattern or helper call can survive that gate and consume council work
before the later validation stage discovers it. Run the exact selected test files
under `MIX_ENV=test` (or an equivalent test-module compile gate) before binding
review. Preserve the full later behavioral run; this cheap gate establishes only
that the claimed evidence can load (found 2026-08-24 when Packet B called
`invalid_tag(kind)` inside match patterns).
Parsing and formatting do not expand assertion macros. In pinned ExUnit 1.19,
a guarded `refute_receive` pattern failed compilation after application compile
had passed. Use a native selective `receive` with the same guard and timeout
when the negative assertion must reject one class of message while tolerating
another; preserve that distinction when correcting the macro use (2026-09-29
Voice qualification).

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

<!-- applied-learning: nested-real-process-tests-need-an-explicit-compatible-exunit-timeout -->
<a id="applied-learning-nested-real-process-tests-need-an-explicit-compatible-exunit-timeout"></a>
**Nested real-process tests need an explicit compatible ExUnit timeout.** An
outer contained child can have minutes of valid capacity while ExUnit still kills
one test at its default 60 seconds. Align the test/module timeout with the reviewed
nested operation profile plus cleanup reserve, and prove descendants terminate when
the test owner dies. Otherwise infrastructure is reported as ordinary
`tests_failed`, correctly enters implementation rework, and pressures the worker to
change unrelated product code (found 2026-08-24 when a cold `TestMixShell` fixture
outlived `Arbor.Actions.MixTest`'s default timeout in CrossApp batch 18).

<!-- applied-learning: a-feature-that-never-worked-hides-every-bug-downstream-of-it -->
<a id="applied-learning-a-feature-that-never-worked-hides-every-bug-downstream-of-it"></a>
**A feature that never worked hides every bug downstream of it.** Fixing one can look like causing a regression. `memory_remember` wrote the knowledge graph while `memory_recall` read the semantic index, so recall ALWAYS returned empty — which silently satisfied a `case format_recalled_memories(recalled) do "" -> ...` branch whose other arm prepended a second system message that OpenAI-compatible providers reject outright. Making remember index its content fixed memory and instantly broke every turn whose recall returned results, latent since the 2026-07-04 rewiring. Two practical consequences: when a fix makes a dormant code path live for the first time, the next failure is probably the path you just woke up, not your change being wrong — check what the empty/zero case was silently satisfying before you revert. And an empty-result guard (`[] ->`, `"" ->`, `nil ->`) that has never been exercised with real data is untested code wearing a passing test; the suite stayed green throughout because every fixture recalled nothing (found 2026-08-25).

<!-- applied-learning: a-canary-must-assert-its-invariant-not-the-implementation-that-satisfies-it -->
<a id="applied-learning-a-canary-must-assert-its-invariant-not-the-implementation-that-satisfies-it"></a>
**A canary must assert its invariant, not the implementation that satisfies it.** The C1 continuity canary exists to prove a fact planted in session 1 reaches the session 3 prompt. Its main test asserts exactly that (`rendered(messages) =~ "Postgres"`) and kept passing when recall moved from a leading system message onto the user turn for prompt caching. But a SIBLING test in the same file pinned the placement — `assert [%{"role" => "system"} | rest] = messages` — and went red on a change that preserved the invariant perfectly (2026-08-25). Two rules follow. When a canary breaks, first ask whether the invariant broke or only the mechanism did; if the mechanism, re-point the assertion rather than reverting the change or deleting the test. And when changing a cross-cutting behaviour like prompt assembly, grep for every test asserting that behaviour, not just the module's own test file — this one lived in `canary/`, and a targeted run of `session_llm_test.exs` was green while it was red.

Test the number of user-visible exchanges as well as continuity. On 2026-09-30,
the joined web/Breeze/Voice test passed because it explicitly expected both an
internal Agent consultation pair and the final spoken pair as separate chat
exchanges. Physical testing exposed the duplicate question and two answers for
one recording. Separate audit/source records from published conversation turns,
then assert one exact utterance/final-answer pair and one occurrence in the next
provider input. Retaining every row is not sufficient proof of a correct UI.
Suppressing internal consultation output from human presentation must preserve
its private interrupted-turn evidence. Pair the absence of human stream signals
with the existing real consultation persistence control when changing stream
generation gates (2026-10-03 conversation execution binding).

<!-- applied-learning: enumerate-candidate-tests-from-the-working-tree-not-the-index-alone -->
<a id="applied-learning-enumerate-candidate-tests-from-the-working-tree-not-the-index-alone"></a>
**Enumerate candidate tests from the committable working tree, not the Git index alone.**
`git ls-files --cached` includes tracked tests deleted by an unstaged coding
candidate. Subtract the exact `git ls-files --deleted` inventory before lstat and
batching, while still failing closed on any other `ENOENT` after enumeration.
Found 2026-08-25 when cross-app validation rejected P1E-1 before running tests
because a deliberately deleted Core test remained in the index.

<!-- applied-learning: omitted-runtime-providers-can-be-pruned-before-app-local-full-profile-tests-start -->
<a id="applied-learning-omitted-runtime-providers-can-be-pruned-before-app-local-full-profile-tests-start"></a>
**Omitted runtime providers can be pruned before app-local full-profile tests
start.** Mix 1.19 builds the code path from an application's declared OTP roots;
if a safe application spec deliberately omits `:os_mon` or network providers, an
app-directory `mix test` can remove them before the host application starts and
fail before ExUnit. Run these app-owned files through an isolated umbrella build
or a named harness that retains full-profile roots, while fresh restricted peers
prove the safe profile neither loads nor starts them. Do not add providers back to
the safe application spec to repair the test runner (found 2026-08-26 during
P1E-1 acceptance).

Pinned Mix 1.19.5 prunes code paths before its `--no-compile` branch; that flag
does not retain installed runtime providers. Record successful owning compilation
separately from a before-ExUnit startup failure, and select app-owned files through
the intended product umbrella context. Keep provider/profile gates and ordinary
pruning enabled (reconfirmed 2026-10-04 during Comms qualification).

An umbrella `mix test` can also traverse unrelated zero-test helpers and occupy
stores before the selected fixture runs. Where an owning launcher is needed,
enter it through root `mix run --no-start --no-compile`, use public
`Mix.Project.in_project/3`, preserve normal app-before-helper startup, and load
only the actual owning helper and selected file. Require the real `ExUnit.run/0`
counts, completed `on_exit` callbacks and normal failed-test exit status; do not
disable providers, alter product dependencies or print a substitute test summary
(2026-10-04 Dashboard form and private-stream qualification).

<!-- applied-learning: in-zsh-harness-scripts-never-use-path-as-a-scalar-variable -->
<a id="applied-learning-in-zsh-harness-scripts-never-use-path-as-a-scalar-variable"></a>
**In zsh harness scripts, never use `path` as a scalar variable.** `path` is the
special array tied to `PATH`; assigning one worktree pathname to it erases normal
command lookup for the rest of the loop, producing misleading `command not found`
errors for tools that ran immediately beforehand. Use a specific name such as
`worktree_path` (found 2026-08-26 during P1E-1 worktree cleanup).

<!-- applied-learning: exunit-only-filters-match-tag-presence-not-truthiness -->
<a id="applied-learning-exunit-only-filters-match-tag-presence-not-truthiness"></a>
**ExUnit `--only tag` filters match tag presence, not truthiness.** A test tagged
`fast: false` still has the `:fast` key and runs under `--only fast`. When one test
in a `@moduletag :fast` file is slow, remove the module tag, mark each genuinely
fast test with `@tag :fast`, and give the slow test `@tag :slow` plus its measured
timeout. Verify the selected and excluded test counts instead of trusting the tag
declaration (found 2026-08-26 while isolating the 10,001-record Security hydration
regression). `--include` filters are alternatives, not intersections with
`--only`: adding `--include database --include isolated_repo` can reselect an
entire database-tagged file. For a narrow predecessor witness, select exact
source lines and verify the reported selected/excluded counts (2026-09-27 Voice
pair-acknowledgement regression). Multiple tags require a keyword list such as
`@moduletag fast: true, integration: true`, or separate attributes; a list of
atoms is invalid. Compile a qualification fixture with ExUnit autorun disabled
before paying for a cold contained build (2026-09-27 native admission fixture).
The atom-list mistake recurred in the 2026-10-04 ordinary-turn helper prerequisite:
parsing and formatting passed, then ExUnit refused the test module before setup.
Preserve that fixture failure and correct only tag metadata before a fresh run;
syntax success does not prove that test macros can compile.
Read the pinned formatter's count semantics: ExUnit 1.19's printed test count
excludes excluded cases, so a file with 18 selected tests and one excluded test
must report `18 tests` and `(1 excluded)`, not `19 tests` (2026-09-29 Voice
qualification runner source review).
The same rule applies to expected-failure witnesses: two selected expiry-cap regressions in a thirteen-case file report two tests and eleven exclusions. Recheck against an accepted log or the pinned formatter before sealing a runner (2026-09-29 human-login review).

<!-- applied-learning: supervision-topology-changes-require-managed-restarts-before-live-verification -->
<a id="applied-learning-supervision-topology-changes-require-managed-restarts-before-live-verification"></a>
**Supervision-topology changes require managed restarts before live
verification.** Hot-loading a facade or module does not start a newly added
supervised child. Live calls can therefore execute code from the new commit while
its authority process is absent, producing misleading runtime failures. After a
commit changes child specs, application startup, or named process ownership, wait
for active work to quiesce, perform a managed `arbor.restart`, then verify both the
child PID and public status before dispatching work (found 2026-08-26 when
`ValidationRuntime.Authority` was compiled but absent from the live supervision
tree).

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

<!-- applied-learning: application-restart-tests-must-restore-the-canonical-test-topology -->
<a id="applied-learning-application-restart-tests-must-restore-the-canonical-test-topology"></a>
**Application-restart tests must restore the canonical test topology.** A test can
stop an application, restore `start_children: false`, and call
`Application.ensure_all_started/1` successfully while leaving the deliberately
empty test supervisor running. Every later test that expects owners such as
`:arbor_reflex_registry` then fails, often far from the contaminating file. Teardown
must call the app's idempotent canonical bootstrap boundary (for Security,
`Arbor.Security.TestBootstrap.restore_supervised_tree!/0`) rather than merely restart
the OTP application. Prove this with a same-BEAM multi-file batch whose following
file needs the restored owner (found 2026-08-26 in P1B-2A CrossApp batch 17; fixed
and verified 2026-08-27 with 1,634 Security tests passing).
Consumer tests also need that bootstrap when their own test helper does not
start the dependency's canonical tree. Under `start_children: false`, starting
Security's application alone leaves its native admission broker absent; a test
expecting an authority refusal then sees service unavailability instead. Start
the documented `Arbor.Security.TestBootstrap.start!/0` and retain the original
public gate assertion. Do not relabel the unavailable response or weaken the
gate to make the test pass (confirmed in the notice-store suite on 2026-10-04).
When adding a supervised child, assert named dependency order and actual
supervisor ownership rather than guessing negative list offsets. The terminal
login qualification selected a stale audit-owner tail assertion: the journal
correctly preceded CapabilityStore and Reflex.Registry, so adjusting only the
offset for the new child still failed (2026-09-29). Preserve order checks and PID
equality; express the dependency relation explicitly.

<!-- applied-learning: sources-only-validation-compiles-need-git-and-a-normal-mix-compile -->
<a id="applied-learning-sources-only-validation-compiles-need-git-and-a-normal-mix-compile"></a>
**Sources-only validation compiles need git and a normal Mix compile.**
`--no-deps-check` skips both lock inspection and compiling missing deps via
`deps.loadpaths`. On a sources-only baseline (`MIX_DEPS_PATH` filled,
`MIX_BUILD_PATH` empty) that leaves `compile.boundary` missing. Put `git` in
`images/validation-runtime/Containerfile` so `Mix.SCM.Git.lock_status` can
read checkout `.git`, and emit `mix compile` (plus optional
`--warnings-as-errors`) as the candidate compile argv. Later xref/test
children may keep `--no-deps-check` once `_build` is populated. Do not skip
the in-unit deps compile until a pre-compiled baseline `_build/test` is
digest-pinned (found 2026-08-26, V7-17 / run 11o; supersedes V7-15).

Hex 2.5.1 dependency fetching creates extraction directories in its current working directory, so a read-only project mount fails with `:erofs` even when `MIX_DEPS_PATH` is writable. Use a disposable writable checkout for operator source provisioning, verify its tracked bytes and lock afterward, and keep subsequent no-network validation in a separate copy (found 2026-09-27 during VP-07B0 native admission).

Fetching newly reachable optional dependencies can delete existing parents'
`compile.elixir_scm` markers even when every lock record is unchanged. Inspect
the actual finite artifact delta and the pinned Mix fetcher, then normally
compile the marked parents with the new dependencies. Preserve successful
resolution evidence; do not repeat fetching or restore compiler markers by hand.
Bind legitimate compiler output changes separately while retaining source and
native guards (found 2026-10-05 extending the original conversation UI build).

Resolve umbrella dependency changes from the root, then compare every lock entry.
Fetching from a leaf app omits sibling constraints and can float unrelated packages.
For an exact two-package source adoption, retain only Mix-generated records for
those packages, preserve the other original records, and require a full-root
`deps.get --check-locked` to succeed without changing the lock (found 2026-09-27
during the private media fork adoption).

Elixir 1.19.5 Mix locks and PubSub require local TCP even in an offline build.
A macOS `(deny network*)` profile refused `deps.get --check-locked` before
compilation on 2026-10-04. Trace the installed implementation and verify real
loopback bind/connect/closure plus non-loopback outbound denial; do not enable
remote downloads or disable Mix locking. SBPL endpoint syntax accepts `localhost`,
not a numeric host. On this Mac that selector also permitted wildcard binding
and non-loopback inbound traffic; preserve those observed limitations and bind
the actual Mix listener to its reviewed `127.0.0.1` source. Do not describe the
profile as denying every remote connection.
The same parser rejected non-loopback numeric addresses on 2026-10-05 with
`host must be * or localhost in network address`, before any socket opened.
Do not invent per-host SBPL admission. A reviewed private provider profile may
allow remote TCP 443 while retaining ordinary TLS hostname verification and
Arbor's enforcing capability/egress gates; describe that as port-only scope.
The actual three-host TLS probe and wrong-port `:eperm` refusals prove those
observations, not exclusive hostname filtering or provider/audio acceptance.
Reject ambient native compiler overrides before creating the image. If the
parent supplies an unrelated `CPPFLAGS`, remove that variable explicitly from
the admitted invocation rather than weakening the clean-environment gate.

An offline resolution check also needs the public Hex registry cache. Copied
locked package sources can compile while `deps.get --check-locked` refuses an
uncached registry entry. Pin only that public metadata into the private image;
do not copy account configuration or enable networking to disguise the missing
input. Source dependencies must carry their reviewed code and licenses in the
execution root. Exclude nonruntime distribution metadata explicitly, preserve
every unrelated lock record, and verify actual compiled source paths after
forcing the changed dependencies (2026-10-03 portable terminal adoption).

Compare registry requirements with original checksum-bound package metadata,
not normalized `mix.lock` requirement text. Seven 2026-10-04 releases had
equivalent-looking but different strings; retain exact checksum, version,
dependency identity, repository and optionality checks, then let ordinary
`deps.get --check-locked` decide constraint acceptance. Inspect all original
metadata shapes before sealing a reader: legacy entries include tuple rows,
omitted zero-dependency requirements and Poolboy's empty map. Admit an absent
or empty-map representation only when both registry and lock prove no
dependencies. Historical cache observations are provenance; the frozen cache
snapshot is the execution input.
Separate host source overlays from locked dependency assets before fresh
assembly. Two qualified Phoenix browser assets under `deps/` caused an early
directory collision on 2026-10-04. Obtain them from their actual locked archives
and compare their bytes with the qualified assets; keep fresh directory creation
and all source guards strict instead of merging or reusing failed build trees.
For an owning DEV build, use ordinary `deps.get --only dev --check-locked`.
In installed Mix 1.19.5, `MIX_ENV=dev` alone does not scope fetching: `deps.get`
passes no environment unless `--only` is supplied, while `deps.compile` uses
the current environment. An otherwise valid 135-package DEV closure failed
fetching test-only Floki on 2026-10-04. Keep the whole lock immutable and bind
the task/converger implementation; do not edit dependency declarations or
claim that a DEV-only build qualifies the test environment.

Valid Mix CLI syntax does not establish contained-command admission. Trace the
exact execution-core argv matcher before preparing a live proof: `test --no-start`
is rejected, while the existing owner-issued `run --no-start runner.exs --
result.etf selected_tests` route is admitted. Use reviewed runner bytes and retain
`--no-start` inside the nested test; do not silently drop it to pass the outer
allowlist (found 2026-09-27 during the Git media live proof).

Pinned launch paths and effective runtime paths can differ without a toolchain
change. On 2026-10-04 the normal Erlang launcher prepended its exact
`erts-16.3/bin` to PATH; Elixir reported System through `bin/../lib`. A SQL
preflight incorrectly expected the initial launcher paths and failed before DB
startup, while all nine storage source/BEAM/loaded-code identities matched.
Capture labelled actual conditions first. Bind the exact effective executable
and both the observed lexical and verified canonical System paths, hashes and
loaded/disk code identity; keep application compile-source gates exact. Preserve
the failed attempt and report the failing stage and bounded stack instead of an
opaque match error.

Check each Mix task's parser before forwarding compiler options. In pinned
Elixir 1.19.5, `--no-compile` still prunes code paths, while `mix run` rejects
compile-only `--no-prune-code-paths`. For a no-start fixture that dynamically
starts genuine OTP providers, use the same-VM sequence
`mix do app.config --no-compile --no-prune-code-paths + run --no-start --no-compile bootstrap.exs`.
Completed `app.config` remains cached when `run` invokes `app.start`, preserving
the configured code paths. Keep provider and identity checks; this does not
prove release inclusion (2026-10-04 private DEV fixture).

Do not infer `mix test` path retention from App.Config alone: Test invokes
Compile again, and `--no-compile` re-enables Compile and Compile.All. Normal
incremental compilation can also recompile local dependencies first. An actual
2026-10-05 debug trace finds their internal `--no-code-path-pruning` flag does
not match pinned Compile.All's `--no-prune-code-paths` check. For already
qualified dependency outputs, first run public `deps.loadpaths --no-compile`
with archive/version/lock/status checks intact, then normal
`app.config --no-prune-code-paths`, then Test. The checked dependency task and
normal owning Compile remain cached. A no-start comparison restores the genuine
`os_mon` path with all producer/native hashes unchanged. Bind legitimate
compiler-generated protocol/metadata changes explicitly; startup and path
observations are not failing security assertions or release-inclusion proof.

Load genuine `.app` metadata for an application outside the owning project's
closure before private `Application.put_env/3` overrides. Otherwise later loading
can replace private ports with resource defaults. Assert effective bind address
and listener afterward. Check the locked API shape too: `Plug.Cowboy.http/3`
takes the plug module and options separately; the plug/options tuple belongs to
`child_spec/1` (2026-10-04 Gateway and private OIDC fixture).

When sandboxed static responses have headers but truncated bodies, compare the
exact pinned OTP sendfile syscall before changing network policy. On 2026-10-04
the same loopback asset transferred exactly 19,172 bytes without the sandbox;
the outbound-denied profile returned `:eperm` and zero bytes. Use the documented
private HTTP `protocol_options: [sendfile: false]` fallback, retain outbound
denial, and verify served asset bytes. Preserve the failed diagnostic; transport
configuration is not device or provider acceptance.

<!-- applied-learning: mix-listeners-are-required-for-safe-phoenix-reloads-in-long-lived-dev-runtimes -->
<a id="applied-learning-mix-listeners-are-required-for-safe-phoenix-reloads-in-long-lived-dev-runtimes"></a>
**Register `Phoenix.CodeReloader` as a Mix listener in long-lived dev runtimes.** Tidewave calls `Phoenix.CodeReloader.reload/2` before each live eval even when the endpoint plug's `code_reloader` config is false. Without root `listeners: [Phoenix.CodeReloader]`, externally compiled umbrella apps take Phoenix's fallback `:code.purge/1` path, which can kill durable factory processes still referencing old code and surface only `:task_owner_died`. Keep the listener in the umbrella `mix.exs`; after adding it, restart the server before trusting live eval (found 2026-08-27 during P1B-2A validation).

<!-- applied-learning: security-regression-parent-overlays-must-reach-a-test-body -->
<a id="applied-learning-security-regression-parent-overlays-must-reach-a-test-body"></a>
**Security-regression parent overlays must reach an ExUnit test body.** Candidate-only work in
`setup` or `setup_all` can turn the intended parent failure into `setup_failed`, which is
non-accepting infrastructure evidence rather than proof that the bug existed. Put candidate-only
compile or API work behind a delayed factory invoked from the test process, keep a behavioral
assertion against the missing or fixed public API, and require candidate success plus ordinary
parent test failure (found 2026-09-01 during G5B1 exact-two-revision verification).

Build callback test state through the public initializer instead of duplicating
private state fields. New lifecycle fields can make a handwritten fixture fail
with `KeyError` before the intended security assertion; initialize while the
dependency is available, then remove it to exercise fail-closed behavior (found
2026-09-27 extending the bounded Source permission regression).

An assertion inside `Enum.each` has an anonymous-function stack frame at its
assertion line and a separate outer test frame. Match the exact case name,
assertion, values and both source locations instead of requiring `(test)` at
every assertion line. If that parser rejects an otherwise completed owning run,
preserve the receipt and validate its existing log and artifact changes; rerunning
the tests does not repair the parser (found 2026-10-05 during conversation
approval regressions).

<!-- applied-learning: source-corpus-tests-must-not-require-ambient-git-metadata -->
<a id="applied-learning-source-corpus-tests-must-not-require-ambient-git-metadata"></a>
**Source-corpus tests must not require ambient Git metadata.** Immutable
object-backed validation mounts tracked source bytes without `.git`; a test that
uses the repository only as a large fixture must construct its own temporary Git
repository instead of asserting `<root>/.git`. When seeding from bytes, force-add
all files so tracked paths that now match `.gitignore` are not silently dropped
(found 2026-09-02 during G5E CrossApp replay).

<!-- applied-learning: a-test-that-starts-distribution-corrupts-compilation-across-the-whole-suite -->
<a id="applied-learning-a-test-that-starts-distribution-corrupts-compilation-across-the-whole-suite"></a>
**A test that starts distribution corrupts compilation across the whole suite.**
`Node.start` / `:net_kernel.start` mid-run flips node identity (e.g.
`nonode@nohost` -> `arbor_mix_47323@127.0.0.1`), and every pid created before the
flip becomes unreachable. A nested `defmodule` compiles to code carrying a
LITERAL `Kernel.LexicalTracker.read_cache(<pid>, ...)` resolved when the outer
body runs, so any test file compiled after the flip dies with
`** (EXIT) no connection to nonode@nohost` — in a DIFFERENT file each run, and
never in the test that caused it. `--max-cases 1` hides it by finishing
compilation before any test runs, which makes it look like a parallel-compiler
bug. If the started node uses longnames it will also join the live dev cluster.
**Never call the real `ensure_distribution` from a test**: inject it
(`ensure_distribution: fn -> :error end`, `server_running?: fn -> false end`).
When a test genuinely needs distribution, use `:shortnames` with a distinct name
so it cannot reach the longnames dev node. **Enumerate seams by call ORDER, not
by importance** — the 2026-08-28 `arbor.login` regression injected all four
facade seams and still shipped this, because `reachable_node/1` calls
`ensure_distribution` before any facade is reached; the commit message even said
"Tests keep injecting the facade functions directly." Audit with
`epmd -names` polled from outside the run: transient names are the leak
(found 2026-09-06; cost two ledger entries open for nine days).

<!-- applied-learning: qualification-must-prove-a-named-product-or-runtime-claim -->
<a id="applied-learning-qualification-must-prove-a-named-product-or-runtime-claim"></a>
**Qualification must prove a named product or runtime claim.** Separate
feature/consumer validation, broad integration, factory restart qualification,
and distributed authority correctness. An executable protocol model is not proof
of a future runtime; all-batch integration is not a prerequisite for every local
feature. When a consumer is deferred, record the old experiment as incomplete and
review any replacement scope explicitly. Never shrink an already admitted plan,
accept a prefix, or let a worker choose tests. Prefer a small deterministic
composition fixture for an infrastructure claim, then widen evidence where shared
state/topology/security demands it (learned 2026-09-07 during the single-user-first
architecture reassessment).
When the operator explicitly makes residual bugs non-blocking, record which
prerequisite is superseded and resume the selected milestone. Preserve unresolved
failures and unverified observations as follow-ups instead of restarting the
same dedicated hardening cycle (2026-10-01 conversation interface evaluation).
Before delegating a renderer comparison, freeze its shared feature, history
window and recovery cases in one artifact. Match those semantics before comparing
render time or implementation effort; different defaults manufacture a winner.
Select versions from verified published metadata before pinning a comparison;
main-branch package manifests can describe releases that are not published.
Bind exact selected distributions to the dependency lock, preserve every lookup
outcome per attempt, and verify installed public exports separately from moving
upstream source (2026-10-01 assistant-ui/Ink preparation: a source-derived core
version returned npm 404 before installation).
Once exact dependencies are installed, run every locally available admitted
consumer check before returning a continuation. Include process teardown in
renderer acceptance: successful UI assertions can precede an uncaught error
from pending React work after DOM globals are removed. Await public renderer
cleanup before restoring that environment (2026-10-01 released API comparison).
Rendered focus is not input-handler readiness: Ink registers handlers in a
passive effect after rendering the cursor. Flush public React lifecycle
boundaries before injecting each keyboard event, keep one write per action,
and capture both public composer state and the frame on failure. For a
sporadic failure, require consecutive fresh-process runs that stop on any
failure, not retries until a pass (2026-10-01 uncertainty-composer qualification).
A renderer's decoded-event test API does not qualify its raw terminal input
decoder. Breeze.Test ignores an ordinary multi-grapheme key; its documented batch
flag exercises a different path. Prove Unicode edits, multiline caret scrolling
and default focus through native fixtures, then separately exercise raw PTY
bracketed paste before claiming paste support (2026-10-02 Breeze adoption).
Pair each input privacy rejection with positive insertion through the actual
interactive owner tree. Breeze.Test's local child tree can differ from the
Server-owned tree; all rejection tests can pass while nested paste is ignored.
Exercise intermediate-owner focus away/back and queued leaf reset as well as
ordinary nested insertion (2026-10-03 bracketed-paste qualification).

For terminal text safety, inspect the raw native frame as well as visible
Unicode and escaped-control markers. A helper that strips escapes again
can hide text loss; absence of OSC alone does not prove correct rendering.
The released Breeze renderer swallowed content after the tested ESC sequence
rather than emitting OSC, so that predecessor proves lost prompt content,
not terminal command execution (2026-10-03 controls qualification).

For streaming terminal framing, vary inter-chunk delay as well as chunk size.
A fast split-marker test missed a 50ms prefix flush that replayed a delayed
CRLF paste as Enter and admitted a real command. Assert no authoritative
admission without explicit Enter, retain the failed timing case, and prove
ordinary keys and a fresh post-discard turn separately (2026-10-03 native
paste acceptance).

<!-- applied-learning: trace-evidence-must-preserve-actual-effect-observations -->
<a id="applied-learning-trace-evidence-must-preserve-actual-effect-observations"></a>
**Trace evidence must preserve actual effect observations.** Observe the real
public facade on the actual spawned turn owner, not a wrapper that can return a
fallback without calling it. A synchronized drain does not fix missing process
coverage. Preserve every observation: deduplicating by query can erase repeated
calls with different results. Accept only documented result shapes; an arbitrary
exception without the expected marker is not proof of empty recall. Pair happy
paths with counterexamples that bypass the facade, repeat the query, and fail
the effect (found 2026-09-08 qualifying J0; bridge fallback invented evidence,
then query-only deduplication discarded genuine calls). Persist each stage's
bounded result before evaluating pass/fail: a `with true <- projection.passed`
chain that returns only `false` loses the failing stage and its command output,
forcing an expensive repeat of the real operation (2026-09-27 native admission).
Before interpreting zero trace events as absence of an effect, establish a
positive control on the same execution path. OTP processes marked `:sensitive`
suppress tracing, so a healthy Desk capture/playback can produce zero function
events even when a separate ordinary-process trace works. Keep that protection
enabled; use an isolated device collaborator or existing bounded observability
instead (2026-09-29 voice reload and cancellation qualification).
Sensitive processes also hide `Process.info(pid, :messages)`. A deterministic
test can suspend the owner, wait for a credential-free queue-length barrier,
and resume it explicitly; do not disable protection to inspect queued login
or session messages (2026-10-03 target-attach qualification).

Record the command, exit code, stdout and stderr even when stderr is empty.
On 2026-10-01, a stderr-only wrapper hid twelve staged-whitespace errors that
`git diff --cached --check` reported on stdout for a literal reconstruction patch.
Check staged whitespace before handing off an archive, and verify reconstructed
source hashes after a patch tool reports success: a zero-context reverse patch
exited zero but ambiguous insertion offsets did not reproduce the frozen bytes.
Choose a representation that preserves exact reconstruction and the normal
whitespace gate; neither successful tool exit nor a gate bypass proves both.

<!-- applied-learning: offline-validation-images-must-cover-executables-and-private-build-descendants -->
<a id="applied-learning-offline-validation-images-must-cover-executables-and-private-build-descendants"></a>
**Offline validation images must cover executables and private build descendants.**
`System.cmd("kill", ...)` needs an OS executable; a shell builtin and a successful
`command -v kill` probe do not prove it exists. Assert the pinned executable path
in the image recipe. Tests spawning standalone Mix lanes can derive sibling
build paths, so mount a private writable build parent rather than only one child;
retain read-only source/root and network denial. Qualify such subprocesses with
their compiled dependency requirements too. Record owner-only image/runner proofs
separately from activation of the live factory baseline. Verify special permission
bits with stat: pinned `File.chmod!/2` strips sticky mode, while checked OS
`chmod +t` sets it; otherwise a test never exercises its intended sticky-directory
case (found 2026-09-08 in the J0 surrounding Commands suite).
Offline package resolution does not disable dependency runtime networking.
Before app startup, disable unrelated automatic refresh services and assert
that their workers are absent while their read-only functionality still works.
Keep their seed data frozen: moving it outside the manifest hides the symptom
but leaves the network effect. `HEX_OFFLINE` did not stop tzdata's updater from
replacing a frozen release during Gateway qualification (2026-09-29).

<!-- applied-learning: verify-producer-payloads-against-current-consumer-contracts -->
<a id="applied-learning-verify-producer-payloads-against-current-consumer-contracts"></a>
**Verify producer payloads against current consumer contracts.**

Native browser events can contain framework metadata absent from mounted
render_click helpers. Qualify a real browser click, then regress its exact
producer shape while retaining closed application selectors: LiveView adds
an empty HTML button value to choice/cancel events, which the strict handler
previously rejected (2026-10-03 conversation controls).

Bind activity ordering and cursor direction at both ends of the same public
path. Fixtures sorted newest-first hid an actual SQL producer ordered oldest-first:
a valid scoped active/queued response was rejected by the adapter and cleared the
browser (2026-10-03). Regress the real producer through the public adapter with
multiple active rows, ties and pagination; preserve completeness/watermark
checks instead of treating a contract rejection as lost authorization.

<!-- applied-learning: preserve-the-formatter-api-s-newline-contract -->
<a id="applied-learning-preserve-the-formatter-api-s-newline-contract"></a>
**Preserve the formatter API's newline contract.**

For a read-only check, compare the complete source to the formatter's complete
iodata output; trimming only the source incorrectly reports a mismatch and can
trigger that same extra-newline churn (2026-10-05 OAuth codec qualification).
Wait for the entire formatting/check process to finish with exit zero before
writing dependent success metadata. Compare parsed ASTs after removing metadata
and normalizing plain `~w` whitespace by word semantics; valid formatting can
change `Macro.to_string/1` rendering. Then compare exact final formatter bytes.
On 2026-10-05, the first pass exited 1 and its unadmitted metadata was corrected
to incomplete; the later complete five-file format and normalized parse
comparison passed.

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
