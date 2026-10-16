# Applied Learning: Testing and Live Runtime

Read this when choosing a Mix/test isolation boundary, reloading a live runtime, or diagnosing validation evidence and toolchain behavior.

## Retained Applied Learning

<!-- applied-learning: spawned-processes-do-not-inherit-process-dictionaries-and-shared-fakes-require-cleanup-convergence -->
<a id="applied-learning-spawned-processes-do-not-inherit-process-dictionaries-and-shared-fakes-require-cleanup-convergence"></a>
**Spawned processes do not inherit process dictionaries, and shared fakes require cleanup convergence.** Pass test observers explicitly or use test-owned ETS; `Process.put/2` in the test process is invisible to spawned router workers. When a deliberate owner kill triggers asynchronous monitored cleanup, wait for close/absence before replacing a named Agent/ETS backend, or late callbacks can contaminate the next randomized test (found 2026-08-03 while stabilizing VP-04E3 voice tool lifecycle tests).

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

<!-- applied-learning: scope-diagnostic-log-level-overrides-to-the-tested-module -->
<a id="applied-learning-scope-diagnostic-log-level-overrides-to-the-tested-module"></a>
**Scope diagnostic log-level overrides to the tested module.** CaptureLog filtering does not lower the producer's global warning threshold. For INFO diagnostic assertions, serialize the tests, save the module's existing Logger override, enable INFO only for that module, and restore its exact prior setting on exit. If no override existed, delete the temporary one. Leave production severity and global logger configuration unchanged. (Extracted 2026-10-16 from independently-rerun-delegated-verification-against-the-committed-revision; first found 2026-10-05.)

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

<!-- applied-learning: structured-terminal-output-needs-a-tool-contract-not-prompt-only-json -->
<a id="applied-learning-structured-terminal-output-needs-a-tool-contract-not-prompt-only-json"></a>
**Enforce structured final output through a bounded terminal-tool contract.** Expose a schema-bounded terminal action, configure its closed name set through terminal_tools, and publish only the accepted terminal action result as final content. Exact-decode reports; malformed JSON, Markdown fences, prose, missing reports, and failed submissions must remain nonaccepting rather than being scraped into a verdict. Reserve at most one terminal-only correction request shared by free-form replies and ordinary tool-round exhaustion. That request exposes only terminal definitions, forces tool choice, and rejects fabricated nonterminal or ambiguous mixed calls before execution; exhaustion after that request fails closed. When no terminal contract is configured, remove tools for the final wrap-up while preserving the conversation's existing output format. Never replace a required structured response with an unconditional plain-text instruction. (Merged 2026-10-16 from 3 entries; first found 2026-07-10, last 2026-07-18.)

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

<!-- applied-learning: in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries -->
<a id="applied-learning-in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries"></a>
**In Elixir map literals, place every `key => value` entry before keyword-style atom entries.** A map that starts with `foo: value` and later adds `dynamic_key => value` is a syntax error; either order all association entries first or use `Map.put/3` for dynamic keys (found 2026-07-14 during delegated Apple admission-core review).

<!-- applied-learning: for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella -->
<a id="applied-learning-for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella"></a>
**Start only the runtime services a local Mix operation actually needs.** Compile or load paths without starting applications for module introspection; use the no-start run path when compiled code is sufficient. An operation calling an owning facade that needs processes must explicitly start its narrow application or supported minimal bootstrap rather than assuming compilation made the service available. Prefer the Shell direct-runtime boundary for offline Git operations that need only pinned executable policy and execution registration, and release its returned owned supervisor afterward. Do not start the whole umbrella merely to satisfy one local diagnostic, since that can launch endpoints, pollers, persistence owners, and unrelated hydration. Use live RPC when the intended subject is the running server's state. (Merged 2026-10-16 from 2 entries; first found 2026-07-07, last 2026-07-16.)

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
**Construct negative fixtures that survive normalization to the intended guard.** Read configuration accessors and compiler transforms before choosing malformed input. A value repaired to a packaged default or mandatory parameter proves fallback behavior rather than downstream rejection. Test that restored invariant separately, then choose an untouched field or malformed value that actually reaches the intended schema or runtime boundary. Trace the full public call path and assert the exact downstream error, with positive prerequisite controls; do not mistake a setup failure or earlier refusal for the intended denial. Keep the repair behavior and the rejecting boundary independently covered so future normalization changes cannot make the negative test vacuous. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-10.)

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

<!-- applied-learning: process-output-is-arbitrary-bytes-until-proven-otherwise -->
<a id="applied-learning-process-output-is-arbitrary-bytes-until-proven-otherwise"></a>
**Bound raw output bytes and the work needed to retain diagnostics.** Treat process output as arbitrary bytes until validated; hash the original stream and sanitize only bounded retained windows before JSON serialization. Apply byte ceilings to prompts, diagnostics, and persisted output, cutting on valid UTF-8 boundaries and counting replacement expansion within the retained budget. A grapheme limit cannot bound bytes or traversal because one grapheme can contain arbitrarily many combining codepoints. Avoid whole-stream codepoint lists, grapheme slicing, and recursive binary concatenation merely to produce a small excerpt; use bounded head, tail, or failure windows with linear iodata accumulation and a small boundary allowance. Regress invalid UTF-8 and long combining sequences with byte-size assertions. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-11.)

<!-- applied-learning: a-struct-pattern-is-not-hostile-term-shape-validation -->
<a id="applied-learning-a-struct-pattern-is-not-hostile-term-shape-validation"></a>
**A `%Struct{}` pattern is not hostile-term shape validation.** A map carrying only `__struct__` and a subset of fields can satisfy the pattern, then raise on dot access or reach a shared broker with malformed data. Reconstruct opaque security references through their validating `new/1` factory using `Map.get/2` before reading fields or calling a broker, and return a shaped fail-closed error for partial struct-tagged maps (found 2026-07-11 reviewing SigningAuthority Engine propagation).

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

<!-- applied-learning: resource-bounds-belong-at-the-public-facade-not-only-one-adapter -->
<a id="applied-learning-resource-bounds-belong-at-the-public-facade-not-only-one-adapter"></a>
**Enforce resource ceilings across every public dispatch path.** Trace each facade operation through primary and alternate adapters, structured generation, tool-argument decoding, OAuth transports, injected clients, and backend selection by syntax or authorization mode. Apply nonbypassable structural-decode, aggregate-retention, absolute-deadline, and owned-stream-teardown limits at every public entry; adapters may tighten that floor but cannot bypass it. An action-schema option or bounded primary collector does not protect a branch that never consumes it. Enforce equivalent bounds on alternate branches or disable them by default. Inspect transport callbacks that run before ordinary response collectors: a DNS-pinning Finch callback must stream, count bytes, debit the shared deadline, and terminate owned work itself rather than relying on request.into or inactivity timeouts. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-11.)

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

<!-- applied-learning: distribution-readiness-is-not-application-readiness -->
<a id="applied-learning-distribution-readiness-is-not-application-readiness"></a>
**Verify the next operation's prerequisites beyond transport reachability.** Use separately bounded distribution and application startup phases, then positively check required owners, public interfaces, durable stores, budget configuration, SQL schema, credentials, and recipient state before handoff or effects. Managed startup checks applications, but healthy HTTP or a connected transport alone cannot prove feature readiness. After an initial ping, application-readiness nodedown must fail promptly while preserving launch tracking; it does not prove OS process death or authorize cleanup, stop, or restart. Partial startup and RPC timeout retain their existing bounded budget. Match service-manager observations to the canonical job's executable, arguments, and PID, parsing fields at the owning level rather than nested metadata. Require fresh connectivity and semantic success receipts for follow-up commands. Repair only reviewed missing migrations and retain partial outcomes. After authentication and current authorization, refuse new commands to stopped agents before durable admission while preserving exact saved-command replay and later uncertainty. (Merged 2026-10-16 from 2 entries; first found 2026-07-13, last 2026-07-16.)

<!-- applied-learning: authenticate-the-control-plane-service-not-only-its-cli -->
<a id="applied-learning-authenticate-the-control-plane-service-not-only-its-cli"></a>
**Authenticate the control-plane service, not only its CLI.** Apple Container's signed CLI writes a user-owned LaunchAgent for `container-apiserver`, while user configuration can select the VM kernel and vminit image. A containment backend must bind launchd's running program/argv to a separately pinned signed API-server binary and explicitly select root/operator-owned kernel, immutable init image, platform, and runtime values; self-reported health JSON is corroboration, not authority (found 2026-07-14 auditing Apple Container 1.1.0 before the imperative prober).

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

A trace observation timeout also includes signing-authority setup. Compare the
exact predecessor first, then use a bounded test observation interval without
changing product deadlines or authorization assertions (2026-10-06: both accepted
ActionRuntime fixtures missed the default 100 ms interval; 2,000 ms preserved
the existing 3,000 ms task deadline and passed on both revisions).

<!-- applied-learning: escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration -->
<a id="applied-learning-escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration"></a>
**Escape JavaScript transport-string delimiters before tool dispatch.** A Markdown backtick embedded unescaped in a JavaScript template literal terminates the transport string while the orchestration program is being parsed. The failure occurs before the tool call, so do not infer that a delegated task was created from its proximity to dispatch code. Build prompts as ordinary quoted lines joined with a newline, use plain text, or correctly escape every embedded template delimiter. Keep JavaScript string construction separate from shell command quoting: escaping a template delimiter does not make shell interpolation safe. Verify that dispatch returned an actual task identity before treating the operation as started. (Merged 2026-10-16 from 2 entries; first found 2026-07-14, last 2026-07-16.)

<!-- applied-learning: prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence -->
<a id="applied-learning-prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence"></a>
**Prove resource absence through an authoritative successful observation.** Release ownership or output only after a successful complete bounded inventory excludes the exact owned identifier, or a precisely specified not-found outcome proves absence. Preserve unknown on transport, permission, timeout, parse, or owner failures; a missing supervisor, failed snapshot, child DOWN, or restart is never an empty inventory. Reconstruct ownership from durable records and use an independent recovery transport when the original owner disappears. For OS probes, distinguish permission denial from confirmed nonexistence. For Git refs, parse structured exact-full-ref records, reject warnings and malformed output, and reread after compare-and-delete failure: absent is idempotent success, a changed OID is a compare-and-swap mismatch, and the unchanged OID is an operational failure. Bound inventory time as well as output, account for cancellation, and use the cheapest source-owned projection that proves the needed fact. (Merged 2026-10-16 from 4 entries; first found 2026-07-11, last 2026-07-20.)

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

<!-- applied-learning: a-gate-regression-must-prove-it-reached-the-intended-gate -->
<a id="applied-learning-a-gate-regression-must-prove-it-reached-the-intended-gate"></a>
**Prove a regression reached the public gate it claims to test.** Construct isolated prerequisites, start or inject required collaborators, and assert positive readiness before the negative case. An optional if-ready branch that performs no assertion, an earlier not-found result, or a failed setup read is incomplete evidence. Require the exact intended denial and actual authorized completion, rather than merely refuting one error. Derive correlated readiness fields from one actor snapshot, and drive controlled inputs through the actual component path. For hostile-input acceptance, prove exact fixture delivery, provenance, and required sanitization at the real consumer. A model's refusal after delivery can establish resistance; pair it with a deterministic attempted-export denial to establish the enforcement gate. Grade the actual action receipt and durable outcome, naming an earlier Trust refusal accurately rather than attributing it to Security. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-07-28.)

<!-- applied-learning: keyset-pagination-must-bound-the-base-relation-before-expensive-joins-or-sorts -->
<a id="applied-learning-keyset-pagination-must-bound-the-base-relation-before-expensive-joins-or-sorts"></a>
**Keyset pagination must bound the base relation before expensive joins or sorts.** A joined query with `WHERE id > cursor ORDER BY id LIMIT n` can still scan and sort the entire remaining relation, especially after bulk staging with stale statistics. Materialize the exact cursor page first, index and analyze its cursor columns, then join that bounded page; validate the full-scale plan with `EXPLAIN (ANALYZE, BUFFERS)` and inspect temporary I/O. The EventLog identity preflight spilled about 190 GiB before mutation until this was fixed (found 2026-07-15 during the EventLog cutover).

<!-- applied-learning: a-fixed-internal-operation-that-needs-a-generically-blocked-flag-belongs-behind-a-closed-facade-primitive -->
<a id="applied-learning-a-fixed-internal-operation-that-needs-a-generically-blocked-flag-belongs-behind-a-closed-facade-primitive"></a>
**A fixed internal operation that needs a generically blocked flag belongs behind a closed facade primitive.** Do not make a business module call `Arbor.Shell.execute_direct(..., sandbox: :none)` because a generic facade correctly rejects `--force` or a similar flag. Add an exact operation to the owning facade, retain its executable/config/storage hardening there, expose no caller-controlled argv, and keep the generic dispatch surface restricted (found 2026-07-16 reviewing Git worktree cleanup).

<!-- applied-learning: a-per-command-timeout-is-not-an-overall-operation-deadline -->
<a id="applied-learning-a-per-command-timeout-is-not-an-overall-operation-deadline"></a>
**Propagate one absolute deadline through each semantic operation phase.** Start timing before runner setup, pass only the remaining monotonic budget to nested calls, and recheck after every child, including the final nominally successful child; reject observations at or beyond expiry. Reusing a full timeout for each command permits total work to grow with command count. Keep setup, worker execution, cancellation, and cleanup budgets distinct so a short worker budget does not accidentally govern unrelated reconstruction. Derive admission-probe subdeadlines as the minimum of operation remaining time and the reviewed 300,000 ms probe maximum, without clamping the whole operation deadline to that probe ceiling or renewing elapsed time afterward. Inject the same clock seam in boundary tests so scheduling cannot manufacture budget mismatches. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-17.)

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

<!-- applied-learning: serialize-mix-commands-within-each-worktree -->
<a id="applied-learning-serialize-mix-commands-within-each-worktree"></a>
**Serialize Mix operations sharing execution resources and candidate ownership.** A worktree isolates source paths, but commands within it still share build outputs, dependency compilation, protocol consolidation, and runtime resources. Run focused suites sequentially; parallel execution requires independently owned worktrees, build roots, and runtime paths. Respect an active validator's exclusive ownership of retained candidate bytes: manager-side tests can invalidate an attested fingerprint even with a separate build path if scratch files appear beneath the application. Verify from another worktree or wait for the task to become terminal. Put regression scratch in an exclusive cryptorandom directory under the system temporary root, register cleanup, and satisfy the tracked-test guard against literal ExUnit tmp-dir tags across the existing corpus. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-07-20.)

<!-- applied-learning: format-only-scoped-paths-in-an-inherited-or-dirty-worktree -->
<a id="applied-learning-format-only-scoped-paths-in-an-inherited-or-dirty-worktree"></a>
**Constrain formatting to validated owned paths and account for build effects.** Build formatter arguments from the actual ownership-manifest schema and require a nonempty list of existing owned files before invoking Mix; an empty argument list can silently format the project. Inspect source diffs before staging and remove incidental unrelated rewrites from narrow changes. Explicit filenames limit source formatting, but plugins can load paths and compile dependencies across the umbrella. Prepare formatting in an isolated image and compare build-artifact inventories as well as source deltas. Preserve failed compilation or qualification evidence, independently bind and review rebuilt outputs, and reject unexpected artifact changes. Never restore stale attested bytes or reclassify changed BEAMs as disposable caches to make evidence pass. Keep formatting's file-existence precondition separate from predecessor compilation, where new candidate files may legitimately be absent. (Merged 2026-10-16 from 2 entries; first found 2026-07-17, last 2026-07-20.)

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

<!-- applied-learning: per-app-and-umbrella-tests-can-exercise-different-optional-runtime-branches -->
<a id="applied-learning-per-app-and-umbrella-tests-can-exercise-different-optional-runtime-branches"></a>
**Choose test launchers that reproduce the intended runtime topology.** Per-app and umbrella runs may load different optional peers and therefore exercise different branches. Test available and unavailable paths deliberately, with the unavailable fallback at least as restrictive as the integrated policy. Use an isolated umbrella or supported owning launcher for production transitive services and full-profile integrations; prove declared child dependency boundaries separately from a fresh child-project build. Do not add providers to safe application specs, widen production dependencies, disable profile gates, or suppress normal pruning merely to repair a launcher. A no-compile flag does not guarantee code-path retention. Preserve normal app-before-helper startup, load only intended helpers where required, and demand genuine ExUnit counts, completed teardown, and normal failure exits. Check each standalone project's own lock and dependency closure. (Merged 2026-10-16 from 3 entries; first found 2026-07-21, last 2026-10-06.)

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
**Own and restore every global test dependency and configuration seam.** Run modules that mutate Application env, globally named processes, shared ETS, or GenServer state with async disabled. Inject intended dependency availability and authorizers instead of relying on suite order or accidental service absence. Snapshot each key with Application.fetch_env, preserving absent separately from explicitly configured nil, and register exact restoration before the first mutation. Supervise test-owned processes, while giving cleanup observers lifetimes that span teardown. Restore interdependent resources synchronously in dependency order; process shutdown alone does not prove backend cleanup or connection check-in completed. Use private migrated databases, verify effective Repo paths and ancillary adapters, and serialize lanes sharing storage or builds. Keep persistence alive through public identity retirement and its acknowledgement, then stop owners. Preserve a primary failure when best-effort cleanup fails; publish success only after confirmed cleanup and normal shutdown. Prove restoration with a clean dependent case after the faulting case. (Merged 2026-10-16 from 4 entries; first found 2026-07-19, last 2026-10-08.)

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
**Admit test evidence only when the intended cases actually completed.** Resolve owning test roots and exact declaration-line selectors, confirm traced case identities, and account for generated cases rather than counting source declarations. A zero exit or zero failures cannot establish a pass without a genuine completed summary, unchanged bound source, and a nonzero intended execution count. Keep selected, excluded, skipped, invalid, and failed counts explicit; interpret CLI summaries and returned runner statistics by their actual formatter contracts, without subtracting exclusions twice. Bare only-tag filters test key presence, including false-valued tags; include filters are alternatives rather than intersections. Use the repository's tagging guidance instead of assuming database means only PostgreSQL. Interrupted runs remain failed or incomplete even if their exit is zero. Only the owning application's observer may publish the receipt. Repair evidence parsers against retained logs before repeating an already verified successful run. (Merged 2026-10-16 from 4 entries; first found 2026-07-14, last 2026-08-26.)

<!-- applied-learning: parenthesize-do-block-expressions-assigned-to-module-attributes -->
<a id="applied-learning-parenthesize-do-block-expressions-assigned-to-module-attributes"></a>
**Parenthesize do-block expressions assigned to module attributes.** In Elixir,
`@items for ... do ... end` binds the block to the module-attribute macro and
raises instead of assigning the comprehension. Use `@items (for ... do ...
end)` or an `Enum` pipeline expression; compile the touched module before
treating formatter success as syntax validation (found 2026-07-28 while adding
the executable coding-profile declaration guard).

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

<!-- applied-learning: zsh-command-substitution-does-not-split-newline-path-lists -->
<a id="applied-learning-zsh-command-substitution-does-not-split-newline-path-lists"></a>
**Zsh command substitution does not split newline path lists by default.**
Passing `$(git diff --name-only ...)` to a formatter can produce one
newline-containing argument instead of one argument per path. Use a native Zsh
array expansion such as `${(@f)...}` for trusted line-delimited paths, or a
NUL-delimited producer and consumer for arbitrary filenames, then verify the
tool actually inspected the intended file count (found 2026-07-28 during the
Phase F scoped formatting check).

<!-- applied-learning: isolate-mix-build-roots-by-revision-and-environment -->
<a id="applied-learning-isolate-mix-build-roots-by-revision-and-environment"></a>
**Give each source revision and Mix environment its own build root.** An explicit MIX_BUILD_PATH names the exact artifact directory and bypasses ordinary environment partitioning, so sharing it across baseline/candidate or dev/test can execute stale BEAMs or remove required support artifacts. Require an explicit MIX_ENV for overridden build roots and derive a distinct environment directory beneath each revision-owned root. Compile in the intended execution environment before any no-compile run; a default-environment compile does not refresh test artifacts. Keep comparison builds separate from the live server's build tree, and serialize any remaining operations that share dependency or runtime resources. (Merged 2026-10-16 from 2 entries; first found 2026-07-21, last 2026-07-30.)

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
**Test facades must observe production ownership, not reimplement it.** Delegate canonical lifecycle operations to the real owner; retain observation and failure injection. Do not translate handoffs while independently registering, draining or removing cleanup. Assert state on the process that owns it, including leases that outlive coordinators. Acceptance must invoke the deployed execution owner: `LLM.generate` and `ToolLoop.run` qualify different loops. Bind the configured client, adapters, plug order, auditor and loaded owner identity. Load genuine application metadata before private overrides, configure isolated targets before owners start, retain enforcing flags, and verify effective listener configuration and public readiness before effects. Store seeding does not prove a Manager-backed read path is ready: own the real collaborators, verify exact-PID cleanup, and preserve the positive action assertion instead of returning canned success. Verify the real profile mode: retain the host restriction and capability approval constraint, using an exact finite public `:ask` rule when a permissive baseline becomes `:block`; a missing Manager fallback cannot establish that policy. Production interaction acceptance must use isolated, migrated SQL rather than disabled persistence. Assert `Arbor.Comms.durable_interaction_readiness/0` backend, namespace and durability before effects. Validate public configuration and result shapes against the serving owner. (Trimmed 2026-10-16; first found 2026-08-04.)

<!-- applied-learning: bind-tool-schema-and-executable-identity-separately -->
<a id="applied-learning-bind-tool-schema-and-executable-identity-separately"></a>
**Bind advertised tool schemas separately from executable owners.** Fingerprint the exact model-visible tool name, description and JSON parameter schema; exclude incidental callback-function identity that changes across node creation. Bind executable owners through separate loaded-code descriptors. Prove a fresh BEAM preserves the profile while schema or executable changes invalidate prior qualification. Never normalize an unknown executable difference merely because source bytes match. (Extracted 2026-10-16 from test-facades-must-observe-production-ownership-not-reimplement-it; first found 2026-09-24.)

<!-- applied-learning: receipt-encoding-must-preserve-authoritative-policy-identity -->
<a id="applied-learning-receipt-encoding-must-preserve-authoritative-policy-identity"></a>
**Keep receipt encoding separate from authoritative policy identity.** Project recognized tagged structs explicitly with `Map.from_struct/1` before recursive JSON encoding; `is_map/1` does not establish `Enumerable` support. Refuse unknown struct types rather than silently flattening them. Preserve the original raw policy term for its authoritative fingerprint instead of fingerprinting the receipt representation. Exercise receipt encoding against the actual public snapshot before acceptance effects. (Extracted 2026-10-16 from test-facades-must-observe-production-ownership-not-reimplement-it; first found 2026-09-24.)

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
**Capture shell exits in an ordinary scalar with cleanup already installed.** In zsh, status is a read-only special parameter; assigning status from the preceding exit code aborts the wrapper and can hide the command's real result or skip cleanup. Capture the exit immediately in a task-specific scalar such as exit_code or rc before any intervening command changes it. Install the EXIT cleanup trap before allocating worktrees, build roots, or other owned resources, and make it run on both success and failure. Preserve the primary command failure if cleanup also fails so the wrapper reports the actual validation outcome. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-08-20.)

<!-- applied-learning: a-baseline-is-only-valid-on-a-pinned-tree -->
<a id="applied-learning-a-baseline-is-only-valid-on-a-pinned-tree"></a>
**Compare identical commands on frozen baseline and candidate trees.** Record source revision, dirty-state identity, exact selectors, environment, and executed scope before and after each run; movement in the tree or unexplained test-count changes invalidates the comparison. Compare quality failures with the original pre-task base as well as any test-only parent, since the latter already contains new test code. Separate pre-existing failures from introduced ones and validate owned files and behavior without formatting unrelated backlog. Refresh isolated snapshots with explicit absolute source and destination paths, then verify expected changed bytes or hashes before accepting their evidence. Keep shared-tree mutations such as stash out of observational baseline checks. (Merged 2026-10-16 from 3 entries; first found 2026-07-22, last 2026-10-07.)

<!-- applied-learning: hot-reload-updates-modules-not-running-child-processes -->
<a id="applied-learning-hot-reload-updates-modules-not-running-child-processes"></a>
**Converge loaded code, live state, and supervised ownership before dispatch.** Use the supported recompile path between tasks; avoid raw umbrella recompilation. Code loading neither migrates GenServer state nor replaces retained local function captures, startup arguments, or supervision topology. Check existing state and required owners, then apply an explicit migration or compatible access; restart the smallest owner only after work quiesces and persisted reconstruction is safe. Represent retained callbacks as reload-stable data or references. Loaded/disk digest agreement alone proves neither process readiness nor reconstruction safety. Bind state-validity certificates to the loaded identity of every module whose semantics the validator executes, recompute that bounded identity at the callback gate, and fail closed when unavailable; do not cache it across independently reloadable modules. Verify fresh catalog identities, exact child ownership, and public readiness after reload or managed restart. For stop/build/start deployment, stop the owning daemon before source integration can trigger automatic reload, keep it stopped through the build, and verify the new owner before dispatch. (Merged 2026-10-16 from 6 entries; first found 2026-07-10, last 2026-08-26.)

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

<!-- applied-learning: in-zsh-harness-scripts-never-use-path-as-a-scalar-variable -->
<a id="applied-learning-in-zsh-harness-scripts-never-use-path-as-a-scalar-variable"></a>
**Use task-specific variable names for filesystem paths in zsh.** The lowercase path parameter is the special array tied to PATH. Assigning a scalar or loop value to it changes executable lookup for the rest of the shell and can make installed tools appear unavailable. Name filesystem values worktree_path, repo_path, or another task-specific scalar, including in short diagnostic one-liners and cleanup loops. Review variable assignments before diagnosing command-not-found output as a missing installation: an earlier loop iteration may have replaced the search path. Preserve the caller's environment when constructing harness commands. (Merged 2026-10-16 from 4 entries; first found 2026-07-15, last 2026-08-26.)

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

<!-- applied-learning: sources-only-validation-compiles-need-git-and-a-normal-mix-compile -->
<a id="applied-learning-sources-only-validation-compiles-need-git-and-a-normal-mix-compile"></a>
**Sources-only validation compiles need Git and a normal Mix compile.** When dependency sources are populated but the build directory is empty, run ordinary `mix compile`, optionally with `--warnings-as-errors`. Supply Git in the validation image and retain dependency checkout metadata so lock inspection can succeed. `--no-deps-check` skips the dependency loading/compilation needed to make dependency-provided compilers available. Later xref/test children may use it after the build is populated. Do not omit in-unit dependency compilation unless the precompiled test baseline is digest-pinned. Keep provisioning separate from no-network validation. (Trimmed 2026-10-16; first found 2026-08-26.)

<!-- applied-learning: measure-network-exceptions-at-their-actual-socket-boundary -->
<a id="applied-learning-measure-network-exceptions-at-their-actual-socket-boundary"></a>
**Measure network exceptions at the actual socket boundary.** Qualify local locking with real loopback bind, connect and closure while retaining remote-download denial and Mix locking. Probe wildcard binds, non-loopback inbound traffic and non-loopback outbound denial separately; a localhost selector does not establish exclusive loopback confinement. Bind the actual listener to its reviewed loopback source. Check the installed sandbox parser and do not invent per-host SBPL admission. A reviewed remote TCP 443 exception is port-only unless separate evidence establishes hostname filtering; retain ordinary TLS hostname verification and enforcing capability/egress gates. Report only observed permissions, without inferring provider or device acceptance. When a denied transport syscall breaks delivery, use supported transport configuration while retaining outbound denial and verify exact served bytes. Preserve failed diagnostics. (Extracted 2026-10-16 from sources-only-validation-compiles-need-git-and-a-normal-mix-compile; first found 2026-10-04.)

<!-- applied-learning: provision-exact-offline-dependency-resolution-inputs -->
<a id="applied-learning-provision-exact-offline-dependency-resolution-inputs"></a>
**Provision exact locked inputs for offline dependency resolution.** Resolve umbrella dependency changes from the root and compare every lock record. Retain only resolver-generated records for admitted changes, preserve unrelated records, and require full-root `deps.get --check-locked` without further lock changes. Select the resolution environment explicitly with `--only`; a DEV-only build does not qualify tests. Provision reviewed dependency code, licenses and checksum-bound public registry metadata into the private execution root; never copy account configuration or enable networking to hide missing inputs. Compare registry requirements with original package metadata rather than normalized lock requirement text. Retain exact checksum, version, dependency identity, repository and optionality checks, then let ordinary locked resolution decide constraint acceptance. Admit omitted or empty-map dependency metadata only when both registry and lock prove no dependencies. Treat the frozen cache snapshot as input. Separate source overlays from locked assets, assemble fresh trees, and verify actual compiled source paths after explicitly rebuilding changed dependencies. Preserve source and native guards. (Extracted 2026-10-16 from sources-only-validation-compiles-need-git-and-a-normal-mix-compile; first found 2026-09-27.)

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

<!-- applied-learning: pin-the-absolute-namespace-of-nested-policy-test-modules -->
<a id="applied-learning-pin-the-absolute-namespace-of-nested-policy-test-modules"></a>
**Pin the absolute namespace of nested policy test modules.** When a regression declares a fake inside a test module but admission classifies the global application namespace, write `defmodule Elixir.Arbor...` and use the same absolute reference. A nested `defmodule Arbor...` creates a test-module-prefixed name and can test the wrong policy family (found 2026-09-09 while reviewing private-turn memory containment tests).

A test double declared inside one `describe` block also needs a qualified reference
from another block (`__MODULE__.RecordingLog`): its implicit alias is lexically
scoped. Assert that the callback was observed; a graceful production logging rescue
can hide an unresolved double as a no-op (found 2026-09-22 while testing design
council rationale persistence).

<!-- applied-learning: preserve-the-formatter-api-s-newline-contract -->
<a id="applied-learning-preserve-the-formatter-api-s-newline-contract"></a>
**Preserve the formatter API's newline contract.** `Code.format_file!/2` already includes the file's terminating newline; appending another creates blank-at-EOF churn. If formatting without Mix in an isolated source review, write its iodata directly, or normalize to exactly one final newline, then verify the exact files with the repository formatter (found 2026-09-09 during private-turn memory containment validation).
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

<!-- applied-learning: remember-that-the-elixir-pipe-inserts-the-first-argument -->
<a id="applied-learning-remember-that-the-elixir-pipe-inserts-the-first-argument"></a>
**Remember that the Elixir pipe inserts the first argument.** This applies to
Erlang modules too: `value |> :crypto.hash(:sha256)` calls
`:crypto.hash(value, :sha256)`, while the intended call is
`:crypto.hash(:sha256, value)`. Prefer an explicit call whenever the data
argument is not first; both terms can satisfy loose runtime types, so parsing
alone will not catch the reversal (found 2026-10-07 while reviewing a durable
capability rollback regression).

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

<!-- applied-learning: isolate-the-git-index-for-snapshot-checks -->
<a id="applied-learning-isolate-the-git-index-for-snapshot-checks"></a>
**Isolate the Git index for snapshot checks.** An rsynced copy may retain a
`.git` file that points at the live worktree index; `git add` in that copy then
stages the real worktree. Yet `git ls-files` checks omit new candidate files
unless the index includes them. Inspect the snapshot's Git metadata first. For
index-aware checks, set `GIT_INDEX_FILE` to a temporary copy of the live index,
stage the candidate against that private index, and leave the live index alone
(found 2026-10-07 while running umbrella fast tests for security review
remediation).

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

<!-- applied-learning: separate-jido-action-names-from-plugin-registry-aliases -->
<a id="applied-learning-separate-jido-action-names-from-plugin-registry-aliases"></a>
**Separate Jido action names from plugin registry aliases.** Jido validates
action names as letters, digits, and underscores; the locked ActionRegistry
requires dotted plugin names. Keep the module's `name` valid for Jido and
register it under a dotted alias, then use that alias in execution bindings
and DOT fixtures (found 2026-10-08 while fixing provenance test registration).

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

<!-- applied-learning: derive-loop-counters-from-their-prior-control-value -->
<a id="applied-learning-derive-loop-counters-from-their-prior-control-value"></a>
**Derive loop counters from their prior control value.** An action that reads
both a trusted counter and untrusted model or test output gives its whole result
the combined untrusted provenance. Hoisting its returned counter into the next
action's control parameter then fails closed on the second retry. Use a pure
`increment` transform from the prior counter for loop control, while keeping
the action's model and test feedback as data (found 2026-10-09 in the LM Studio
TDD RLE example).
