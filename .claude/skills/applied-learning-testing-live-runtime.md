# Applied Learning: Testing and Live Runtime

Read this when choosing a Mix/test isolation boundary, reloading a live runtime, or diagnosing validation evidence and toolchain behavior.

## Retained Applied Learning

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

<!-- applied-learning: test-applications-can-be-running-while-required-children-are-deliberately-absent -->
<a id="applied-learning-test-applications-can-be-running-while-required-children-are-deliberately-absent"></a>
**Test applications can be running while required children are deliberately
absent.** `MIX_ENV=test` commonly starts an application supervisor with
`start_children: false`; a direct diagnostic that needs a child such as
`Arbor.Shell.ExecutionRegistry` must start that test-owned child explicitly.
Checking only `Application.started_applications/0` can misdiagnose a missing
child as a broken API (found 2026-07-13 during Phase 6 shell diagnostics).

<!-- applied-learning: in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries -->
<a id="applied-learning-in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries"></a>
**In Elixir map literals, place every `key => value` entry before keyword-style atom entries.** A map that starts with `foo: value` and later adds `dynamic_key => value` is a syntax error; either order all association entries first or use `Map.put/3` for dynamic keys (found 2026-07-14 during delegated Apple admission-core review).

<!-- applied-learning: for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella -->
<a id="applied-learning-for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella"></a>
**For local diagnostic Mix tasks, start the narrow app, not the whole umbrella.** `Mix.Task.run("app.start")` in an umbrella task starts every app and can bring up Gateway/Dashboard, pollers, memory loaders, etc. (2026-07-07: a local trust-profile audit accidentally started HTTP endpoints and loaded unrelated subsystems). Plain `./bin/mix run -e ...` also starts the application; use `./bin/mix run --no-start -e ...` for one-off module introspection that only needs compiled code. For offline/local diagnostics that only need one subsystem, use `Application.ensure_all_started(:target_app)` after compilation/loadpaths, and leave the default task path as live RPC when it needs the running server's state.

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
**Distribution readiness is not application readiness.** `mix arbor.start` currently reports success when the named BEAM responds to distribution pings, but a later umbrella application can still fail and tear the node down before Gateway binds. After every restart, poll `http://127.0.0.1:4000/health` and inspect the daemon log if the process exits; do not dispatch work from the startup banner alone (found 2026-07-13 recovering the Phase 6 delegator runtime).

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

<!-- applied-learning: test-pure-consumers-with-the-exact-producer-envelope-not-a-convenient-synthetic-shape -->
<a id="applied-learning-test-pure-consumers-with-the-exact-producer-envelope-not-a-convenient-synthetic-shape"></a>
**Test pure consumers with the exact producer envelope, not a convenient synthetic shape.** A standalone core test can validate every local invariant while still accepting a map layout that its real upstream never emits. Mirror the producer's closed atom/string key placement, grouping, revision fields, and serialized scalar forms in the consumer fixture, then run both suites together; the Apple execution core originally passed against a flat purpose map while `Arbor.Actions.Mix.projections_for_resource/2` emitted grouped `read_only` / `read_write` lists (found 2026-07-14 composing the Phase 6 projection boundary).

<!-- applied-learning: escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration -->
<a id="applied-learning-escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration"></a>
**Escape backticks inside JavaScript template literals used for tool orchestration.** A delegated-task prompt embedded in a backtick-delimited JavaScript string fails before the MCP call if prose contains unescaped Markdown backticks. Use an array of ordinary quoted lines joined with `"\n"`, or escape every embedded backtick; this is distinct from shell command-substitution quoting (found 2026-07-14 dispatching the Apple unit lifecycle core).

<!-- applied-learning: prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence -->
<a id="applied-learning-prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence"></a>
**Prove resource absence positively; do not reinterpret an arbitrary lookup failure as absence.** A nonzero `inspect` can mean service loss, authorization failure, malformed input, or transport failure, not only `not found`. For enforcing cleanup, require a successful bounded inventory response and prove the exact owned identifier is absent from its parsed structured entries before releasing output or ownership (found 2026-07-14 designing Apple Container teardown).

<!-- applied-learning: a-module-global-test-fake-must-not-be-linked-to-an-arbitrary-per-test-process -->
<a id="applied-learning-a-module-global-test-fake-must-not-be-linked-to-an-arbitrary-per-test-process"></a>
**A module-global test fake must not be linked to an arbitrary per-test process.** `ensure_started/0` plus `GenServer.start_link/3` can find the prior test's still-registered process just before that owner exits, then race into `:noproc` on the following call and cascade unrelated failures. Put shared fakes under a suite-stable supervisor/owner or start them unlinked with explicit reset/cleanup; per-test resources may remain linked to the test process (found 2026-07-14 in the Apple unit-worker held-absence suite).

<!-- applied-learning: exunit-setup-callbacks-cannot-dynamically-skip-a-test -->
<a id="applied-learning-exunit-setup-callbacks-cannot-dynamically-skip-a-test"></a>
**ExUnit setup callbacks cannot dynamically skip a test.** `setup` / `setup_all` accept only `:ok`, a context map/keyword list, or `{:ok, context}`; returning `{:skip, reason}` fails instead of skipping on the host where the prerequisite is absent. Compute the prerequisite at test compilation and attach a conditional `skip:` tag to only the affected tests or describes, leaving prerequisite-independent security regressions runnable (found 2026-07-14 making the macOS `shlock` journal tests portable).

<!-- applied-learning: configure-a-replacement-test-process-before-an-observer-can-discover-it -->
<a id="applied-learning-configure-a-replacement-test-process-before-an-observer-can-discover-it"></a>
**Configure a replacement test process before an observer can discover it.** Starting a named fake with permissive/default behavior and then resetting it in a second call creates a race: a monitored coordinator can resolve and invoke the replacement between those operations. Start the fake atomically in its intended mode, or suspend the observer across replacement setup and resume it afterward; otherwise a deterministic turnover regression can fail or, worse, pass through unintended behavior (found 2026-07-15 in the Apple reconciler-PID turnover test).

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
**A hermetic test must replace the runner seam the code actually consumes.** Setting `:mix_shell_module` did not make `CrossAppTest` hermetic because `CrossAppShell` independently defaulted `:cross_app_mix_runner` to production `MixAction.run_mix/3`; under an external contained build root, production wrapper discovery correctly failed closed before the configured test shell ran. Trace the invocation from suite setup through the final subprocess boundary, install and restore the narrow test-only runner there, and leave production wrapper-authority tests on the production path (found 2026-07-18 during contained validation of `task_234818`).

<!-- applied-learning: contained-durable-store-fixtures-need-a-private-trusted-parent -->
<a id="applied-learning-contained-durable-store-fixtures-need-a-private-trusted-parent"></a>
**Contained durable-store fixtures need a private trusted parent.** In the Linux guest, `System.tmp_dir!()` can be `/tmp`, whose parent permissions intentionally fail production durable-root safety before the behavior under test. Build security fixtures beneath `ActionCase`'s per-test `tmp_dir` so the real parent check stays enabled and the intended poison or budget condition is reached; never add `:parent_permissions_unsafe` to an unrelated assertion merely to make the test pass (found 2026-07-18 in `WorkspaceRetentionRestartTest`).

<!-- applied-learning: do-not-make-optional-runtime-packaging-directories-a-test-prerequisite -->
<a id="applied-learning-do-not-make-optional-runtime-packaging-directories-a-test-prerequisite"></a>
**Do not make optional runtime packaging directories a test prerequisite.** An Elixir installation may omit an empty `.mix/archives` directory until an archive is installed; the contained Linux image did while the developer installation did not. Test the authority and path-placement contract, and only validate directory type when the optional path exists (found 2026-07-18 in `MixSpawnContainmentSlice1Test`).

<!-- applied-learning: task-history-observations-need-a-storage-barrier-and-monotonic-event-order -->
<a id="applied-learning-task-history-observations-need-a-storage-barrier-and-monotonic-event-order"></a>
**Task-history observations need a storage barrier and monotonic event order.** A cast-only audit signal can lose a race with the response that wakes its owner, and wall-clock timestamps can tie even at microsecond precision. Store task-correlated lifecycle signals before wake-up, attach an emitter-owned monotonic sequence, and aggregate by `{timestamp, sequence}`; terminal result fields are fallback evidence, not event history (found 2026-07-19 repairing rework/approval benchmark counts).

<!-- applied-learning: tests-that-mutate-global-application-config-must-not-run-async -->
<a id="applied-learning-tests-that-mutate-global-application-config-must-not-run-async"></a>
**Tests that mutate global Application config must not run async.** Restoring values in `on_exit` does not prevent another async module from observing the temporary value. Mark the whole module `async: false` whenever it changes shared Application env, globally named processes, or shared ETS state (found 2026-07-19 when the Comms suite intermittently hid the Signal response channel).

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
