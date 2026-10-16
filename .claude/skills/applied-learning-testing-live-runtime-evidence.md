# Applied Learning: Validation Evidence and Regression Proof

Read this when deciding whether a test run, canary, baseline, qualification, or security regression actually proves its claim, or when reviewing delegated verification.

## Retained Applied Learning

<!-- applied-learning: independently-rerun-delegated-verification-against-the-committed-revision -->
<a id="applied-learning-independently-rerun-delegated-verification-against-the-committed-revision"></a>
**Independently rerun delegated verification against the committed revision.** Treat a worker's green report as evidence, then rerun the exact focused suite in an independently owned worktree at the integrated committed revision. Bind selected source and test bytes to committed blobs, derive selectors from current test declarations, and require the intended cases to execute. Validate every source preimage before copying any member; stop dependent checks on materialization failure and preserve the failed attempt separately. Each qualified revision keeps its own source, build and result namespace.

Trace each consumer's actual dependency declaration and lock. Matching compile-source paths, clean checkout bytes, archive hashes, or loaded/disk code MD5s do not establish freshness. Explicitly rebuild changed dependencies through their owning applications before callers, bootstrap cold transitive prerequisites, and verify required exports and public behavior through the consumer. Record provenance by execution role plus module so separate build roots cannot overwrite one another. Compilation and browser refresh do not establish loaded-code adoption: check the running code identity against the qualified artifact before accepting runtime evidence. Recheck final committed blobs against the qualified source digests; reject partial copies, stale outputs, or unexplained drift. (Trimmed 2026-10-16; first found 2026-07-25.)

<!-- applied-learning: preserve-persisted-cancellation-status-when-replaying-partial-transcripts -->
<a id="applied-learning-preserve-persisted-cancellation-status-when-replaying-partial-transcripts"></a>
**Preserve persisted cancellation status when replaying partial transcripts.** A retained transcript row is not proof that a turn completed. Trace its persisted semantic status through the supported window and presentation projections, retain and label partial cancelled output, and keep speech disabled on replay. Regression tests must assert that status fields are present before comparing values; two missing values can compare equal. Seed fixture statuses before the first read or append fresh persisted identities. Do not change an already cached entry's status at the same ID and ordinal or relax immutable-overlap validation merely to exercise a label. (Extracted 2026-10-16 from independently-rerun-delegated-verification-against-the-committed-revision; first found 2026-10-04.)

<!-- applied-learning: require-complete-authorized-views-before-accepting-indexed-phase-evidence -->
<a id="applied-learning-require-complete-authorized-views-before-accepting-indexed-phase-evidence"></a>
**Require complete authorized views before accepting indexed phase evidence.** A background command index may legitimately lag its journal after admission. Retain partial observations, but evaluate phase predicates only on complete views within the original deadline. Authenticate and enforce scope on every sample; authorization, transport or owner failures are not index catch-up. Direct reads still require completeness. Read terminal command facts through the exact public command read: completed or cancelled commands can leave an active-work list. Require the exact termination predicate and use disappearance only as secondary evidence. Do not extend the deadline, weaken authorization or change the producer to accommodate an observation helper. (Extracted 2026-10-16 from independently-rerun-delegated-verification-against-the-committed-revision; first found 2026-10-04.)

<!-- applied-learning: execute-the-admitted-virtualenv-path-without-resolving-away-its-environment -->
<a id="applied-learning-execute-the-admitted-virtualenv-path-without-resolving-away-its-environment"></a>
**Execute the admitted virtualenv path without resolving away its environment.** Preserve the approved virtualenv executable path and bind its symlink target, resolved binary, executable hash and environment configuration separately. Invoke the virtualenv path itself: invoking the resolved Python binary can bypass the environment. Before launching the controlled application, verify required imports and a virtualenv prefix through that exact interpreter and its fresh scoped home, temporary, configuration and cache paths. Do not substitute system Python, install dependencies or change the product to repair a fixture that selected the wrong interpreter. Retain the failed attempt; startup and cleanup alone do not qualify the journey. (Extracted 2026-10-16 from independently-rerun-delegated-verification-against-the-committed-revision; first found 2026-10-04.)

<!-- applied-learning: allow-only-exact-reviewed-operational-cache-deltas -->
<a id="applied-learning-allow-only-exact-reviewed-operational-cache-deltas"></a>
**Allow only exact reviewed operational-cache deltas.** Separate immutable qualification inputs and executable artifacts from operational outputs. When a normal tool changes a cache or compiler-validation record, inspect its actual producer and complete artifact delta before classifying only those exact existing regular files as mutable outputs. Retain initial snapshots, before/after hashes, file-kind confinement and failed guards. Keep source, lock, BEAM, .app, static, priv and archive bytes immutable within the sealed phase; keep generator and DSL inputs bound. Never exempt all compile.* files, an entire dependency directory or a tool/cache tree, or accept unreviewed generated variants. Legitimate recompilation requires an explicitly reviewed successor inventory. Do not restore stale BEAMs, protocol consolidation, or build records merely to satisfy an old inventory. (Extracted 2026-10-16 from independently-rerun-delegated-verification-against-the-committed-revision; first found 2026-10-01.)

<!-- applied-learning: verify-packaged-beam-identity-through-the-configured-transformation -->
<a id="applied-learning-verify-packaged-beam-identity-through-the-configured-transformation"></a>
**Verify packaged BEAM identity through the configured transformation.** For escripts, bind reviewed source SHA-256 and compare loaded, disk and archive OTP code MD5s. Compare exact archive member bytes with the disk BEAM after applying the configured Mix.Release.strip_beam options. Stripping can change raw file SHA-256 without changing executable code; never claim those raw hashes are equal. Bind packaged application metadata to its exact project or toolchain owner paths, versions and hashes; reject a generic external-path fallback. Preserve failed identity checks instead of rewriting evidence to make them pass. (Extracted 2026-10-16 from independently-rerun-delegated-verification-against-the-committed-revision; first found 2026-10-04.)

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

<!-- applied-learning: test-downstream-config-guards-with-values-that-survive-the-config-accessor -->
<a id="applied-learning-test-downstream-config-guards-with-values-that-survive-the-config-accessor"></a>
**Construct negative fixtures that survive normalization to the intended guard.** Read configuration accessors and compiler transforms before choosing malformed input. A value repaired to a packaged default or mandatory parameter proves fallback behavior rather than downstream rejection. Test that restored invariant separately, then choose an untouched field or malformed value that actually reaches the intended schema or runtime boundary. Trace the full public call path and assert the exact downstream error, with positive prerequisite controls; do not mistake a setup failure or earlier refusal for the intended denial. Keep the repair behavior and the rejecting boundary independently covered so future normalization changes cannot make the negative test vacuous. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-10.)

<!-- applied-learning: a-conformance-harness-is-not-a-gate-until-production-adapters-and-failure-exit-semantics-exist -->
<a id="applied-learning-a-conformance-harness-is-not-a-gate-until-production-adapters-and-failure-exit-semantics-exist"></a>
**A conformance harness is not a gate until production adapters and failure exit semantics exist.** Scripted callbacks are useful deterministic unit fixtures, but they do not prove that both real executors ran, selected different implementations, produced correct artifacts, or remained isolated. A benchmark command must invoke pinned production adapters, verify each result against the objective independently of pair equivalence, avoid process-global selector mutation, and exit nonzero when acceptance thresholds fail (found 2026-07-11 reviewing the first coding benchmark foundation).

<!-- applied-learning: a-one-pass-green-race-regression-is-not-evidence-of-stability -->
<a id="applied-learning-a-one-pass-green-race-regression-is-not-evidence-of-stability"></a>
**A one-pass green race regression is not evidence of stability.** Concurrency, timeout, cleanup, and mutation tests must run repeatedly with `--repeat-until-failure` (or an equivalent deterministic stress loop) before sign-off. Replace startup sleeps with explicit ready/accepted handshakes and register teardown before the concurrent actor starts; a candidate that passed once returned a hash on the very next repeated run while its file was being rewritten (found 2026-07-11 reviewing eval persistence R3).

<!-- applied-learning: caller-writable-ets-is-not-independent-evidence -->
<a id="applied-learning-caller-writable-ets-is-not-independent-evidence"></a>
**Caller-writable ETS is not independent evidence.** A `:public` cleanup table created by whichever benchmark caller arrives first can be forged, disappears with that owner, and grows without TTL; copying its value into a recomputed summary only moves the trust problem. Security-relevant run evidence needs a dedicated bounded owner, opaque owner-bound lifecycle, proactive expiry, and a fail-closed restart contract (found 2026-07-11 reviewing coding benchmark R6).

<!-- applied-learning: dominance-over-named-success-terminals-does-not-gate-the-side-effects-that-precede-them -->
<a id="applied-learning-dominance-over-named-success-terminals-does-not-gate-the-side-effects-that-precede-them"></a>
**Dominance over named success terminals does not gate the side effects that precede them.** A semantic preflight can prove that `status_pr_created` is review-dominated while still accepting an allowlisted `git_pr` action injected before validation that rejoins the normal graph afterward. Constrain each side-effecting action to reviewed node identities/topology or prove the relevant gate dominates every occurrence of that action; terminal-only publication checks are insufficient (found 2026-07-11 with an executable early-PR compiler probe).

<!-- applied-learning: a-mismatched-reference-regression-does-not-cover-an-exactly-copied-internal-message -->
<a id="applied-learning-a-mismatched-reference-regression-does-not-cover-an-exactly-copied-internal-message"></a>
**A mismatched-reference regression does not cover an exactly copied internal message.** If a completion PID/ref/token is visible in GenServer state, an attacker can copy the entire expected tuple rather than guess one field. Regress the exact copied envelope and raw OTP protocol messages; bind completion to cryptorandom one-shot authority that is absent from observable owner state (found 2026-07-11 forging TaskStore approval-cleanup completion).

<!-- applied-learning: a-gate-regression-must-prove-it-reached-the-intended-gate -->
<a id="applied-learning-a-gate-regression-must-prove-it-reached-the-intended-gate"></a>
**Prove a regression reached the public gate it claims to test.** Construct isolated prerequisites, start or inject required collaborators, and assert positive readiness before the negative case. An optional if-ready branch that performs no assertion, an earlier not-found result, or a failed setup read is incomplete evidence. Require the exact intended denial and actual authorized completion, rather than merely refuting one error. Derive correlated readiness fields from one actor snapshot, and drive controlled inputs through the actual component path. For hostile-input acceptance, prove exact fixture delivery, provenance, and required sanitization at the real consumer. A model's refusal after delivery can establish resistance; pair it with a deterministic attempted-export denial to establish the enforcement gate. Grade the actual action receipt and durable outcome, naming an earlier Trust refusal accurately rather than attributing it to Security. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-07-28.)

<!-- applied-learning: a-platform-label-is-not-native-artifact-architecture-evidence -->
<a id="applied-learning-a-platform-label-is-not-native-artifact-architecture-evidence"></a>
**A platform label is not native-artifact architecture evidence.** The upstream `sqlite_vec` asset named `linux-aarch64` for v0.1.5 was actually ELF32 ARM because its release job used `arm-linux-gnueabihf-gcc`. Before attesting a Linux dependency baseline, inspect the binary header and load the extension in the exact network-disabled guest runtime; filenames and release metadata are insufficient (found 2026-07-17 provisioning the Apple Container baseline).

<!-- applied-learning: cross-app-closure-size-is-part-of-task-scoping-not-a-reason-to-weaken-validation -->
<a id="applied-learning-cross-app-closure-size-is-part-of-task-scoping-not-a-reason-to-weaken-validation"></a>
**Cross-app closure size is part of task scoping, not a reason to weaken validation.** A change in a low-level app such as `arbor_common` selects nearly the full downstream umbrella; one large dependent suite can legitimately consume the shared test-stage budget even when the changed app's focused tests pass. Use a bounded high-level real task for acceptance dogfood, and treat a low-level closure timeout as an explicit validation result that needs a separately reviewed budget or profile design change (found 2026-07-17 after `arbor_actions` exhausted the 600-second test stage).

<!-- applied-learning: generated-elixir-source-needs-a-behavioral-compile-test -->
<a id="applied-learning-generated-elixir-source-needs-a-behavioral-compile-test"></a>
**Generated Elixir source needs a behavioral compile test.** Substring assertions did not catch a generated `String.starts_with?/2` call inside a guard, which Elixir rejects. Parse and compile the generated module under the pinned toolchain, then exercise its load-bearing boundary functions; keep remote calls in function bodies rather than guards (found 2026-07-18 before rerunning security-regression dogfood).

<!-- applied-learning: run-the-full-dot-contract-test-file-after-changing-packaged-graph-bindings -->
<a id="applied-learning-run-the-full-dot-contract-test-file-after-changing-packaged-graph-bindings"></a>
**Run the full DOT contract test file after changing packaged graph bindings.** A targeted end-to-end scenario can pass while a stale structural assertion elsewhere still encodes the previous context contract. After changing packaged DOT node attributes or `context_keys`, run the complete graph contract test file in addition to focused regressions; static graph-shape assertions are part of the contract and should move in the same slice (found 2026-07-21 while validating uncertain-send owner-baseline recovery).

<!-- applied-learning: reproduce-a-suspected-runtime-failure-before-steering-a-security-fix -->
<a id="applied-learning-reproduce-a-suspected-runtime-failure-before-steering-a-security-fix"></a>
**Reproduce disputed runtime and security-failure claims on the pinned toolchain.** Exercise the exact API, option, and value through the public behavior before redesigning around memory, static inspection, or an assumed standard-library incompatibility. When executable evidence disagrees with a claimed failure, reproduce the disputed call directly in the repository's pinned runtime and retain the observed result. Check portability deliberately rather than projecting one runtime's behavior onto every supported platform. Before delegating a security fix, establish a behavioral witness that fails on the unfixed code and can pass with the intended correction. A plausible fail-open narrative or a setup failure is insufficient evidence of the bug. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-21.)

<!-- applied-learning: aggregate-failure-excerpts-must-anchor-within-a-structured-failed-child -->
<a id="applied-learning-aggregate-failure-excerpts-must-anchor-within-a-structured-failed-child"></a>
**Anchor aggregate diagnostics within a structurally failed child.** Select a failed child from its authoritative result before searching for exception or assertion text; successful children may contain expected exception fixtures that would otherwise displace the real failure. Extract a bounded failure-centered window from that child's body while retaining useful stream head/tail context, raw-stream hashes, valid UTF-8, and byte ceilings. Include exact selectors, seed, concurrency, and command metadata needed to reproduce the run. If no diagnostic anchor exists, retain the failed child's bounded fallback rather than borrowing another child's prose. Keep excerpts as presentation evidence: text matching must never determine the verdict or override structured failure authority. (Merged 2026-10-16 from 2 entries; first found 2026-07-21, last 2026-07-21.)

<!-- applied-learning: validation-batches-must-not-cross-app-test-root-boundaries -->
<a id="applied-learning-validation-batches-must-not-cross-app-test-root-boundaries"></a>
**Preserve exact authorized inventories through deterministic app-local batching.** Enumerate surviving tracked and untracked files, verify segment-aware paths and lstat identity, and authorize the exact entries before contained execution. Container-per-file startup is an execution choice, not the authorization boundary. Partition the verified inventory at canonical application test roots before packing under closed file-count, argv-count, and argument-byte ceilings; never mix independent app roots in one child. Preserve deterministic ordering, global indices, counts, and hashes, including the final partial batch. Resume must recompute and validate that same partition, rejecting forged cross-root batches or changed inventories. Execute every required file or report exact incomplete coverage and remaining work; budget exhaustion or a passing prefix cannot become success. (Merged 2026-10-16 from 2 entries; first found 2026-07-17, last 2026-07-21.)

<!-- applied-learning: atom-interning-regressions-must-check-the-candidate-atom-not-the-vm-global-count -->
<a id="applied-learning-atom-interning-regressions-must-check-the-candidate-atom-not-the-vm-global-count"></a>
**Atom-interning regressions must check the candidate atom, not the VM-global count.** The BEAM atom table is process-global, so supervised background work or lazy module loading can legitimately increase `:atom_count` between two assertions even in an `async: false` test. Generate a unique untrusted string and prove `String.to_existing_atom/1` raises both before and after the public call; this tests the exact security invariant without unrelated runtime races (found 2026-07-22 during consolidated software-factory verification).

<!-- applied-learning: restart-recovery-regressions-must-pass-cold-and-standalone -->
<a id="applied-learning-restart-recovery-regressions-must-pass-cold-and-standalone"></a>
**Restart-recovery regressions must pass cold and standalone.** A larger suite can leave
Application env, compiled modules, or service processes warm enough to hide a cold-start
timeout or schema-replay defect. Run the exact restart case by itself as well as in its
owning file, and overlay that same test on the immediate parent for the failure proof.
Compiler fakes must consume the same configured template source as production; a fake
that bypasses it does not prove graph-upgrade recovery (found 2026-09-01 while repairing
settled coding-task rehydration after the design-council graph upgrade).

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
**Admit test evidence only when the intended cases actually completed.** Resolve owning test roots and exact declaration-line selectors, confirm traced case identities, and account for generated cases rather than counting source declarations. A zero exit or zero failures cannot establish a pass without a genuine completed summary, unchanged bound source, and a nonzero intended execution count. Keep selected, excluded, skipped, invalid, and failed counts explicit; interpret CLI summaries and returned runner statistics by their actual formatter contracts, without subtracting exclusions twice. Bare only-tag filters test key presence, including false-valued tags; include filters are alternatives rather than intersections. Use the repository's tagging guidance instead of assuming database means only PostgreSQL. Interrupted runs remain failed or incomplete even if their exit is zero. Only the owning application's observer may publish the receipt. Repair evidence parsers against retained logs before repeating an already verified successful run. (Merged 2026-10-16 from 4 entries; first found 2026-07-14, last 2026-08-26.)

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

<!-- applied-learning: bind-tool-schema-and-executable-identity-separately -->
<a id="applied-learning-bind-tool-schema-and-executable-identity-separately"></a>
**Bind advertised tool schemas separately from executable owners.** Fingerprint the exact model-visible tool name, description and JSON parameter schema; exclude incidental callback-function identity that changes across node creation. Bind executable owners through separate loaded-code descriptors. Prove a fresh BEAM preserves the profile while schema or executable changes invalidate prior qualification. Never normalize an unknown executable difference merely because source bytes match. (Extracted 2026-10-16 from test-facades-must-observe-production-ownership-not-reimplement-it; first found 2026-09-24.)

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

<!-- applied-learning: a-baseline-is-only-valid-on-a-pinned-tree -->
<a id="applied-learning-a-baseline-is-only-valid-on-a-pinned-tree"></a>
**Compare identical commands on frozen baseline and candidate trees.** Record source revision, dirty-state identity, exact selectors, environment, and executed scope before and after each run; movement in the tree or unexplained test-count changes invalidates the comparison. Compare quality failures with the original pre-task base as well as any test-only parent, since the latter already contains new test code. Separate pre-existing failures from introduced ones and validate owned files and behavior without formatting unrelated backlog. Refresh isolated snapshots with explicit absolute source and destination paths, then verify expected changed bytes or hashes before accepting their evidence. Keep shared-tree mutations such as stash out of observational baseline checks. (Merged 2026-10-16 from 3 entries; first found 2026-07-22, last 2026-10-07.)

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

<!-- applied-learning: qualification-must-prove-a-named-product-or-runtime-claim -->
<a id="applied-learning-qualification-must-prove-a-named-product-or-runtime-claim"></a>
**Qualification must prove a named product or runtime claim.** State whether the evidence qualifies a feature/consumer, broad integration, factory restart or distributed authority. Use a deterministic composition fixture for a bounded infrastructure claim, widening coverage when shared state, topology or security requires it. A protocol model does not prove a future runtime, and broad integration is not a prerequisite for every local feature. Freeze shared features, history windows and recovery cases before comparing implementations. When claiming released-API support, verify published distributions, lock selected versions and inspect installed public exports rather than moving upstream source; preserve lookup failures. Never shrink an admitted plan, accept a prefix or let a worker choose tests. Run every locally available admitted consumer check, including teardown, before handoff. Record deferred consumer evidence as incomplete and explicitly review replacement scope. When the operator makes residual bugs non-blocking, record the superseded prerequisite, preserve unresolved failures and unverified observations as follow-ups, then resume the selected milestone. (Trimmed 2026-10-16; first found 2026-09-07.)

<!-- applied-learning: inspect-raw-terminal-frames-for-text-safety -->
<a id="applied-learning-inspect-raw-terminal-frames-for-text-safety"></a>
**Inspect raw terminal frames when qualifying text safety.** Inspect the raw native frame together with visible Unicode and escaped-control markers. Do not run it through another escape-stripping helper that can hide lost text. Absence of OSC alone does not establish correct rendering. Distinguish lost prompt content from terminal command execution and claim only the outcome the witness actually demonstrates. (Extracted 2026-10-16 from qualification-must-prove-a-named-product-or-runtime-claim; first found 2026-10-03.)

<!-- applied-learning: qualify-terminal-paste-through-timed-native-owner-streams -->
<a id="applied-learning-qualify-terminal-paste-through-timed-native-owner-streams"></a>
**Qualify terminal paste through timed streams and real input owners.** Exercise raw PTY input and the actual server-owned interactive tree before claiming paste support; decoded-event helpers bypass the raw decoder and can use a different owner tree. Vary inter-chunk delay as well as chunk size across opening and closing delimiters, including incomplete and delayed CRLF pastes. Assert no authoritative admission without explicit Enter. Pair each privacy rejection with positive Unicode/multiline insertion through the same real owner chain; cover default focus, caret scrolling, intermediate-owner focus away/back and queued leaf resets. Prove ordinary keys and a fresh post-discard turn separately. Preserve the failed timing case instead of accepting fast split-marker coverage as equivalent. (Extracted 2026-10-16 from qualification-must-prove-a-named-product-or-runtime-claim; first found 2026-10-02.)

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

<!-- applied-learning: verify-producer-payloads-against-current-consumer-contracts -->
<a id="applied-learning-verify-producer-payloads-against-current-consumer-contracts"></a>
**Test producer-to-consumer contracts with the exact current wire envelope.** Trace real producers through normalization, codecs, public wrappers, and every consuming method, including unchanged callers. Build fixtures from actual key placement, grouping, tuple arity, revision grammar, scalar forms, nested serialization, ordering, cursor direction, and persisted identifiers. A convenient synthetic map proves only its local branch; never invent revisions or IDs the producer cannot issue. Exercise public write/read roundtrips and disclosure scope; normalize JSON at the producer instead of weakening strict storage or provenance validation to admit arbitrary structs. Qualify browser-origin events and request-shaping headers through actual browser submissions, retaining strict Origin/CSRF checks and secret-redirect protections. Verify outgoing provider HTTP bodies rather than only fake-adapter inputs. Assert producer bounds and delivered callback effects before blaming a consumer; keep defensive consumer checks when an earlier codec also rejects input. Preserve failed fixture receipts separately, and repeat predecessor/current witnesses when corrected test bytes change the test identity. (Merged 2026-10-16 from 2 entries; first found 2026-07-14, last 2026-09-09.)

<!-- applied-learning: verify-effective-file-selectors-before-accepting-scoped-lint-evidence -->
<a id="applied-learning-verify-effective-file-selectors-before-accepting-scoped-lint-evidence"></a>
**Verify effective file selectors before accepting scoped lint evidence.** Use
exact positional paths for the pinned Credo CLI (`credo --strict path1 path2`)
and verify its reported source-file count matches the intended scope. Its
`treat_unknown_args_as_files` branch overwrites `--files-included` with positional
arguments, including an empty list (`deps/credo/lib/credo/cli/options.ex:136-139`).
A seemingly scoped invocation therefore scanned 3,696 files on 2026-09-09; stop
an unexpectedly broadened run and correct the selector before accepting lint
results. Recheck effective selection when upgrading the tool.

<!-- applied-learning: bind-cold-storage-proofs-to-the-declared-backend -->
<a id="applied-learning-bind-cold-storage-proofs-to-the-declared-backend"></a>
**Bind cold storage proofs to the declared backend.** A direct checkpoint or
store API can select a different default from the configured Engine, even when
the runtime owner reports healthy durable storage. Pass the captured store, name
and options explicitly, then load by its actual run identity to prove the same
SQL roundtrip. Diagnose the value-producing failure before attributing it to a
nearby database warning; retain the initial failure and fix the owning consumer
recipe without substituting a volatile store or relaxing durability (found
2026-10-06 while qualifying the standalone Workflow release consumer).

<!-- applied-learning: validate-security-scanner-bounds-against-the-production-corpus -->
<a id="applied-learning-validate-security-scanner-bounds-against-the-production-corpus"></a>
**Validate security scanner bounds against the production corpus.** Fail-closed
limits must accept the largest legitimate input they guard while remaining
finite. Exercise boundary failures through the public reporting path because
locationless aggregate violations must preserve the result schema (`line: nil`)
or diagnostics can crash before showing the denial. Run the scanner against
current maximum-size sources when changing byte, line, regex, or deadline
budgets (found 2026-10-07 when the PII scan's new 10,000-line cap rejected two
existing libraries and its locationless overflow finding crashed the pre-commit
reporter).

<!-- applied-learning: make-model-generated-test-edge-semantics-explicit -->
<a id="applied-learning-make-model-generated-test-edge-semantics-explicit"></a>
**Make model-generated test edge semantics explicit.** In a TDD pipeline that
runs both generated and held-out tests, a generated assertion can contradict an
implicit rule and prevent convergence even when the implementation meets the
held-out examples. Specify the disputed edge in the prose and held-out cases;
retain both test sets. When repeated attempts fail on foreign-language syntax,
put the target language's valid branching form in the implementation prompt
(found 2026-10-09 with FizzBuzz zero and Python-style `elif` in Elixir). If
feedback repeats the same invalid library call, give the exact API shape in
the system prompt; the RLE example converged after specifying that
`Enum.chunk_by/2` takes a unary key function.
