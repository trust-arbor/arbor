# Applied Learning archive: testing-live-runtime

Retired entries, kept for history and revival. Not loaded by default.

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

<!-- applied-learning: plain-beam-hot-loading-does-not-migrate-live-genserver-state -->
<a id="applied-learning-plain-beam-hot-loading-does-not-migrate-live-genserver-state"></a>
**Plain BEAM hot loading does not migrate live GenServer state.** `arbor.recompile` uses `:code.load_binary/3`; it does not invoke `code_change/3`. When a hot-reloaded module adds state keys, either reload through `:sys.change_code/4` or make reads and writes backward-compatible with pre-reload maps until the state is materialized; otherwise the first post-reload call crashes the server (found 2026-07-20 after adding AcpPool settlement tracking).

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

<!-- applied-learning: do-not-raw-recompile-the-umbrella-to-repair-stale-live-code -->
<a id="applied-learning-do-not-raw-recompile-the-umbrella-to-repair-stale-live-code"></a>
**Do not raw-recompile the umbrella to repair stale live code.** Calling `IEx.Helpers.recompile/0` through Tidewave can stop dependency applications and leave long-lived signer closures paired with newly loaded modules, producing mixed signing credentials and unavailable security state. Prefer the supported RPC recompile task; if distribution addressing makes that task unreachable, perform a clean restart after the migration preflight instead (found 2026-07-13 while restoring MCP coding delegation).

<!-- applied-learning: use-canonical-macos-temp-paths-for-rebar-backed-isolated-builds -->
<a id="applied-learning-use-canonical-macos-temp-paths-for-rebar-backed-isolated-builds"></a>
**Use canonical macOS temp paths for rebar-backed isolated builds.** On macOS,
`/tmp` resolves to `/private/tmp`; using a noncanonical `/tmp/...` value for
`MIX_BUILD_PATH` can make rebar dependency symlinks resolve through inconsistent
roots and fail valid dependency includes such as `yamerl`. Put isolated build
artifacts under the canonical `/private/tmp/...` path, keep `MIX_DEPS_PATH`
explicit, and let the worktree itself remain under either spelling (found
2026-07-29 while independently validating the interaction-wait candidate).

<!-- applied-learning: keep-nested-mix-build-paths-canonical-on-macos -->
<a id="applied-learning-keep-nested-mix-build-paths-canonical-on-macos"></a>
**Keep nested Mix build paths canonical on macOS.** `/tmp` resolves to
`/private/tmp`; a Mix dependency include symlink made relative under `/tmp`
can resolve under `/private/Users` and fail with a missing header. Put
`MIX_BUILD_PATH` under the canonical checkout for release probes, then place
only the finished release under temporary storage (found 2026-10-09 building
the Persistence cleanup release regression).

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

<!-- applied-learning: local-llm-node-timeouts-are-separate-from-exunit-timeouts -->
<a id="applied-learning-local-llm-node-timeouts-are-separate-from-exunit-timeouts"></a>
**Local LLM node timeouts are separate from ExUnit timeouts.** A test may allow
20 minutes while an individual DOT compute node still has a five-minute
`timeout` and fails first. For slow local reasoning models, use observed call
latency to set the node timeout as well as the test timeout; keep the model's
output budget intact unless measured evidence supports lowering it (found
2026-10-09 when Qwen RLE timed out at 300 seconds despite a prior passing run).

<!-- applied-learning: application-env-snapshots-must-preserve-key-presence-separately-from-nil -->
<a id="applied-learning-application-env-snapshots-must-preserve-key-presence-separately-from-nil"></a>
**Application environment snapshots must preserve key presence separately from
`nil`.** `Application.get_env/3` collapses an explicitly configured `nil` and an
absent key, so teardown can delete a deliberate override and silently reactivate a
default backend. Snapshot with `Application.fetch_env/2` and restore `{:ok, value}`
versus `:error` exactly (found 2026-08-20 when Security teardown re-enabled JSONFile
and cascaded into 220 `:authority_root_unconfigured` failures).

<!-- applied-learning: pin-and-restore-cross-app-test-authorizers -->
<a id="applied-learning-pin-and-restore-cross-app-test-authorizers"></a>
**Pin and restore global authorizers in tests that exercise them.** Umbrella
tests can carry Application env from an earlier app's test helper into the next
app. A Shell helper's command-only authorizer caused an Actions batch test to
fail at the filesystem gate under `mix test.fast`, though the test passed in
isolation. An integration test requiring a specific authorizer should set it
in setup and restore the exact previous `fetch_env` result on exit (found
2026-10-08 while reviewing batch context security tests).

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
archive and cleanup callbacks into later tests). Register restoration immediately
after capturing the original state and before the first mutation; never place it
after assertions in the test body. A failed security assertion otherwise strands
a replacement store or terminated supervisor child and turns every later denial
into a misleading cascade. Prove teardown by running a clean dependent case after
the faulting case (reinforced 2026-10-07 while qualifying the Security review).

<!-- applied-learning: verify-that-an-exunit-line-filter-selected-the-intended-test -->
<a id="applied-learning-verify-that-an-exunit-line-filter-selected-the-intended-test"></a>
**Verify that an ExUnit line filter selected the intended test.** A `mix test file.exs:line` selector aimed at an `@tag`, comment, or nearby blank can resolve to the preceding test and produce a convincing but irrelevant pass. Point at the actual `test` declaration, then inspect the traced test name or distinctive fixture output before using the result as regression proof (found 2026-07-21 while proving the Git checkout-loss regression fails on the unfixed clause order).

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

<!-- applied-learning: a-successful-exunit-command-can-still-execute-zero-regressions -->
<a id="applied-learning-a-successful-exunit-command-can-still-execute-zero-regressions"></a>
**A successful ExUnit command can still execute zero regressions.** Arbor's `:database` tag specifically means a test requires PostgreSQL and is excluded by default in `arbor_persistence`; a hermetic temporary-SQLite migration test carrying that tag reported success with every test excluded. Use the tag semantics in `TEST_TAGGING.md`, and verify the final executed test count rather than only the command exit status (found 2026-07-14 reviewing the SQLite migration infrastructure fix).

<!-- applied-learning: in-zsh-path-is-the-array-form-of-path -->
<a id="applied-learning-in-zsh-path-is-the-array-form-of-path"></a>
**In zsh, `path` is the array form of `PATH`.** Assigning `path=...` as an ordinary loop variable rewrites command lookup for the current shell, so later commands fail with `command not found`. Use a neutral name such as `wt`, `target_path`, or `candidate` when iterating over filesystem paths (found 2026-07-21 while verifying accepted worktrees before lifecycle cleanup).

<!-- applied-learning: terminal-tool-contracts-need-a-reserved-terminal-only-request-after-normal-inspection-tool-rounds-are-exhausted -->
<a id="applied-learning-terminal-tool-contracts-need-a-reserved-terminal-only-request-after-normal-inspection-tool-rounds-are-exhausted"></a>
**Terminal-tool contracts need a reserved terminal-only request after normal
inspection/tool rounds are exhausted.** That reserved request must expose only
terminal definitions, force tool choice, run exactly once, and reject fabricated
non-terminal calls before execution (found 2026-07-18 after the ToolLoop
terminal-submission fix).

<!-- applied-learning: tool-loop-exhaustion-must-preserve-the-conversation-s-required-output-format -->
<a id="applied-learning-tool-loop-exhaustion-must-preserve-the-conversation-s-required-output-format"></a>
**Tool-loop exhaustion must preserve the conversation's required output format.** A generic final-pass instruction such as "plain text only" or "do not output JSON" can invalidate a council node whose contract requires a structured vote. Remove tools for the wrap-up pass, but tell the model to answer in the format already required by the conversation (found 2026-07-10 after review-tree tools added bounded multi-turn council calls).

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

<!-- applied-learning: refresh-isolated-snapshots-from-an-absolute-source -->
<a id="applied-learning-refresh-isolated-snapshots-from-an-absolute-source"></a>
**Refresh isolated snapshots from an absolute source path.** A relative
`rsync ./ <snapshot>` run with the snapshot as the command's working directory
copies the snapshot onto itself and silently reruns stale source. Pin both the
repository source and snapshot destination explicitly, then verify at least one
expected changed line or hash before accepting the run (found 2026-10-07 while
rerunning the full Security suite).

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

<!-- applied-learning: a-shared-deadline-must-be-checked-after-every-child-invocation-including-the-last-one -->
<a id="applied-learning-a-shared-deadline-must-be-checked-after-every-child-invocation-including-the-last-one"></a>
**A shared deadline must be checked after every child invocation, including the last one.** Passing the remaining budget into a subprocess is not sufficient if the runner can return a nominal success after that budget; a loop that returns `:complete` when no children remain can then accept an overrun. Measure from before runner setup and reject any result observed after the absolute monotonic deadline, even when it came from the final child (found 2026-07-11 reviewing per-app cross-app validation).
Tests that assert an exact launched budget at a deadline boundary must inject the same monotonic clock seam; real scheduling time can legitimately reduce the remaining budget by 1 ms and make an equality assertion flaky (reconfirmed 2026-08-27 during P1B-2A contained validation).

<!-- applied-learning: an-operation-deadline-and-a-bounded-probe-subdeadline-are-different-contracts -->
<a id="applied-learning-an-operation-deadline-and-a-bounded-probe-subdeadline-are-different-contracts"></a>
**An operation deadline and a bounded probe subdeadline are different contracts.** Raising the spawn-capable operation ceiling to 600 seconds does not authorize a 600-second admission probe whose reviewed maximum is 300 seconds. Preserve the caller's full absolute operation deadline, derive the probe timeout as `min(operation_remaining, probe_max)`, and let later execution consume the remaining operation budget; clamping the shared deadline itself silently restores the old ceiling (found 2026-07-17 while unifying Apple Container validation timeouts).

<!-- applied-learning: bound-retained-output-and-the-work-required-to-produce-it -->
<a id="applied-learning-bound-retained-output-and-the-work-required-to-produce-it"></a>
**Bound retained output and the work required to produce it.** A 2 KB excerpt is not a resource bound if invalid-UTF-8 repair recursively concatenates an 8 MiB stream or suffix extraction builds a codepoint list for the whole input. Hash raw bytes once, then sanitize bounded head/tail windows with linear iodata accumulation and inspect only a small UTF-8 boundary allowance (found 2026-07-11 reviewing cross-app validation evidence).

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

<!-- applied-learning: validate-transitive-otp-services-from-the-umbrella-root -->
<a id="applied-learning-validate-transitive-otp-services-from-the-umbrella-root"></a>
**Validate transitive OTP services from the umbrella root.** A child app may
compile while its standalone Mix test cannot start an OTP service supplied by a
sibling's release dependency. Do not add that service to the child's
`extra_applications` merely to make an artificial standalone lane pass. Use the
isolated umbrella test lane for the real dependency graph, and keep child-app
tests to dependencies the child actually declares (found 2026-10-06 while
validating kernel-runtime diagnostics that use `os_mon`).

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

<!-- applied-learning: do-not-place-unescaped-markdown-backticks-inside-a-javascript-template-literal-used-for-tool-orchestration -->
<a id="applied-learning-do-not-place-unescaped-markdown-backticks-inside-a-javascript-template-literal-used-for-tool-orchestration"></a>
**Do not place unescaped Markdown backticks inside a JavaScript template literal used for tool orchestration.** The backtick terminates the transport string before the MCP call is made, so no task exists even though the failure appears next to dispatch. Use plain text inside the prompt, escape the delimiter, or build the payload from ordinary quoted strings (found 2026-07-16 dispatching the benchmark catalog materializer).

<!-- applied-learning: startup-rehydration-is-not-runtime-distributed-discovery -->
<a id="applied-learning-startup-rehydration-is-not-runtime-distributed-discovery"></a>
**Startup rehydration is not runtime distributed discovery.** A survivor that starts before another node creates a run has an empty hot journal forever unless it refreshes from the durable authority while running. Refresh must decode without boot-normalizing a live remote owner, preserve a local runtime PID only while durable ownership/status still match, avoid delete-on-missing, and run before nodedown and recurring interrupted discovery (found 2026-07-15 designing L4 owner-node-loss recovery).

<!-- applied-learning: attest-supervised-children-during-application-start-without-get-child -->
<a id="applied-learning-attest-supervised-children-during-application-start-without-get-child"></a>
**Attest supervised children during application startup without `get_child/1`.**
OTP's application master exists before the callback returns its root, but
`:application_master.get_child/1` can terminate that master while the root is
still undefined. Verify the linked master → callback → root chain, application
ownership, exact child path, and registered PID during startup; use the normal
root lookup after startup. Exercise the production boot in an isolated process,
because test config with `start_children: false` hides this ordering bug (found
2026-10-09 in the production SQLite probe).

<!-- applied-learning: a-mix-task-that-calls-an-owning-facade-directly-must-start-that-narrow-application -->
<a id="applied-learning-a-mix-task-that-calls-an-owning-facade-directly-must-start-that-narrow-application"></a>
**A Mix task that calls an owning facade directly must start that narrow application.** A task can compile successfully yet fail when invoked from the CLI because `Arbor.Shell` workers are not running. Use `Application.ensure_all_started(:arbor_shell)` at the task boundary when Shell is the direct runtime dependency; do not start the whole umbrella merely to make a local command work (found 2026-07-16 exercising `arbor.coding.benchmark.prepare`).

<!-- applied-learning: revalidate-compiler-output-against-the-normalized-plan-at-the-execution-boundary -->
<a id="applied-learning-revalidate-compiler-output-against-the-normalized-plan-at-the-execution-boundary"></a>
**Revalidate compiler output against the normalized plan at the execution boundary.** A compiler is a trusted module seam, but a bug or malformed replacement can reintroduce unchecked execution values after input scope validation. Bind every path/provider/model/test selector the generated graph will consume back to the canonical Plan before archiving or running it (found 2026-07-10 when review reproduced a worktree-root redirect through `initial_values`).

<!-- applied-learning: compile-and-test-in-the-same-mix-env -->
<a id="applied-learning-compile-and-test-in-the-same-mix-env"></a>
**Compile and test in the same `MIX_ENV`.** A focused `MIX_ENV=test mix test --no-compile` can execute stale test-environment BEAMs after a default-environment compile. Compile the touched app with `MIX_ENV=test` before a no-compile focused rerun, especially when another process shares the umbrella build directory (found 2026-07-21 while validating ACP managed-session regressions).

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
PID ownership is only an initialization acknowledgement, not readiness: a
dynamically rebuilt child can return from `start_child` and then fail in
`handle_continue`, taking its `rest_for_one` tail down after the bootstrap has
reported success. The canonical bootstrap must run each subsystem's public
startup barrier in dependency order and assert public readiness before returning
(found 2026-10-07 when the Security test tree disappeared before ExUnit began).

<!-- applied-learning: register-real-audit-consumers-after-security-test-bootstrap -->
<a id="applied-learning-register-real-audit-consumers-after-security-test-bootstrap"></a>
**Register real audit consumers after Security test bootstrap.**
`Arbor.Security.TestBootstrap.start!/1` points Security at its test-only audit
consumer. A journey that starts the real Historian puller must set both
`:authority_audit_consumer_name` and `:authority_audit_consumer_application` to
the supervised puller before relying on durable audit delivery, then restore
the previous values. Otherwise Security rejects the real puller and an audit
flush reports `:audit_source_unavailable` (found 2026-10-09 merging the
conversation entrypoint journey).

<!-- applied-learning: validation-feedback-must-preserve-failure-local-diagnostics-not-only-stream-head-and-tail -->
<a id="applied-learning-validation-feedback-must-preserve-failure-local-diagnostics-not-only-stream-head-and-tail"></a>
**Validation feedback must preserve failure-local diagnostics, not only stream head and tail.** Broad ExUnit runs can place the failing assertion in the middle of megabytes of progress and warnings; a fixed head/tail excerpt then reports only startup and final counts, forcing an expensive rerun and encouraging speculative fixes. On nonzero exit, extract a bounded failure-centered window while retaining full-stream hashes and UTF-8/budget guarantees, and include exact seed/concurrency metadata needed for deterministic reproduction (found 2026-07-21 when cross-app validation reported 489 tests and 2 failures but omitted both failure blocks).

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

<!-- applied-learning: in-zsh-status-is-a-read-only-special-parameter -->
<a id="applied-learning-in-zsh-status-is-a-read-only-special-parameter"></a>
**In zsh, `status` is a read-only special parameter.** A test wrapper that assigns `status=$?` fails after the command under test and can obscure its result. Use a neutral scalar such as `rc` when capturing an exit code (found 2026-07-16 rerunning isolated checkpoint-resume tests).

<!-- applied-learning: batch-response-order-is-not-input-order-when-the-protocol-supplies-indices -->
<a id="applied-learning-batch-response-order-is-not-input-order-when-the-protocol-supplies-indices"></a>
**Batch response order is not input order when the protocol supplies indices.** Embedding and fan-out APIs must validate response indices as unique, complete, bounded integers and reorder by those indices before associating results with inputs. Preserving wire order can silently attach a valid result to the wrong request even when every vector passes shape validation (found 2026-07-11 reversing an OpenAI-compatible embedding batch response).

<!-- applied-learning: starting-an-agent-with-start-session-false-does-not-disable-autonomous-heartbeats -->
<a id="applied-learning-starting-an-agent-with-start-session-false-does-not-disable-autonomous-heartbeats"></a>
**Starting an agent with `start_session: false` does not disable autonomous heartbeats.** `Lifecycle.start/2` derives HeartbeatService separately and defaults `start_heartbeat` to true, so a coordinator started only for async dispatch can still run background checks and create unrelated shell approvals. For a dispatch-only coding coordinator use both `start_session: false` and `start_heartbeat: false`; do not answer heartbeat approvals as though they belonged to the delegated task (found 2026-07-11 after restarting the local Arbor server).

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

<!-- applied-learning: consume-optional-cross-library-capabilities-through-the-owning-facade-and-its-real-contract -->
<a id="applied-learning-consume-optional-cross-library-capabilities-through-the-owning-facade-and-its-real-contract"></a>
**Consume optional cross-library capabilities through the owning facade and its real contract.** A caller that probes an invented backend callback such as `backend.durability_class/0` can reject a valid Store implementation whose supported contract is exposed as `Arbor.Persistence.durability_class/3`. Check the facade and callback arity before adding capability detection, and keep backend options flowing through that facade (found 2026-07-13 reviewing durable engine lifecycle admission).

<!-- applied-learning: fast-and-database-tags-conflict -->
<a id="applied-learning-fast-and-database-tags-conflict"></a>
**Never tag one test both `:fast` and `:database`.** The fast alias uses
`--only fast:true`; ExUnit selects any test whose effective fast tag is true
even with `--exclude database`, so it can run against an unmigrated default
test Repo. For a mixed module, override real database cases with
`@tag fast: false`. Use `:database` for shared configured Repo tests. A test
that must start its own exclusive Repo uses only `:isolated_repo`, since
`--include database` overrides an isolated exclusion in `test.all`. Run it
separately (found 2026-10-08 after 15 command-index failures in
`mix test.fast` and an isolated-Repo filter check).

<!-- applied-learning: arbor-recompile-cannot-repair-every-loaded-object-mismatch -->
<a id="applied-learning-arbor-recompile-cannot-repair-every-loaded-object-mismatch"></a>
**`arbor.recompile` cannot repair every loaded-object mismatch.** It delegates to `IEx.Helpers.recompile/0`, which recompiles changed source; if the on-disk BEAM is current but the long-running VM still has an older object loaded, it can return success/noop while execution-manifest checks continue failing with `execution_module_loaded_code_mismatch`. Reload the exact reviewed modules explicitly or use the purpose-built `arbor.restart` between delegated runs when no task is active (found 2026-07-11 after integrating Engine handler changes).

<!-- applied-learning: mix-arbor-eval-is-the-eval-harness-not-a-lightweight-rpc-evaluator -->
<a id="applied-learning-mix-arbor-eval-is-the-eval-harness-not-a-lightweight-rpc-evaluator"></a>
**`mix arbor.eval` is the eval harness, not a lightweight RPC evaluator.** For running-node diagnostics, use a purpose-built RPC task such as `arbor.recompile` or a task-specific command, or add/use an explicit `arbor.eval.rpc`-style task. Otherwise `arbor.eval` starts evaluation infrastructure and can fail on missing `--model` / `--models` before running the intended diagnostic (found 2026-07-08 while checking registry ETS state).
