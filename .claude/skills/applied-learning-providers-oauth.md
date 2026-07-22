# Applied Learning: Providers and OAuth

Read this when changing LLM/provider routing, OAuth credentials, refresh ownership, quotas, budgets, egress, or transport behavior.

## Retained Applied Learning

<!-- applied-learning: a-rotating-oauth-refresh-token-cannot-be-safely-cloned-into-two-independently-refreshing-stores -->
<a id="applied-learning-a-rotating-oauth-refresh-token-cannot-be-safely-cloned-into-two-independently-refreshing-stores"></a>
**A rotating OAuth refresh token cannot be safely cloned into two independently
refreshing stores.** The 2026-07-18 council failure showed `~/.arbor/oauth/openai.json`
remained from 2026-07-04 while `~/.codex/auth.json` rotated on 2026-07-12;
per-provider single-flight worked, but both serialized calls used the stale
Arbor-owned credential. Prefer an independently acquired Arbor OAuth
session/token family; do not consume or overwrite a CLI-owned rotating
credential as a retry workaround (found 2026-07-18 during council smoke).

<!-- applied-learning: rotating-oauth-refresh-is-a-provider-keyed-single-flight-publication -->
<a id="applied-learning-rotating-oauth-refresh-is-a-provider-keyed-single-flight-publication"></a>
**Rotating OAuth refresh is a provider-keyed single-flight publication.** Concurrent
callers must serialize on the provider, reread the store while holding the lock, and
publish a complete valid access/refresh token pair atomically before any caller returns.
Under-lock read failure, malformed stored or refreshed credentials, persistence failure,
and refresh-token omission without a valid prior token all fail closed; exact store
absence is the only condition that permits CLI bootstrap (found 2026-07-17 hardening
subscription-backed council model refresh).

<!-- applied-learning: llm-usage-cost-may-be-a-nested-breakdown-map-not-a-number -->
<a id="applied-learning-llm-usage-cost-may-be-a-nested-breakdown-map-not-a-number"></a>
**LLM usage cost may be a nested breakdown map, not a number.** Logging and
aggregation code must normalize a recognized numeric total before doing any
arithmetic. A logging-only `:badarith` can otherwise turn a successful model
response into an apparent provider failure (found 2026-07-13 in council
perspective calls through `Arbor.Consensus.LLMBridge`).

<!-- applied-learning: budget-multi-leg-action-timeouts-against-the-enclosing-wall-clock -->
<a id="applied-learning-budget-multi-leg-action-timeouts-against-the-enclosing-wall-clock"></a>
**Budget multi-leg action timeouts against the enclosing wall clock.** A timeout on a two-revision validator is per revision, so setting each leg to 600,000ms permits 1,200,000ms of work and exceeds a 900,000ms plan budget. Prefer the measured/default per-leg timeout when it fits the aggregate budget, and name profile metadata explicitly as per-leg default/max rather than presenting one ambiguous timeout (found 2026-07-10 during security-regression profile activation).

<!-- applied-learning: nested-llm-tool-calls-need-the-exact-child-runauthorization-not-only-its-flattened-manifest-fields -->
<a id="applied-learning-nested-llm-tool-calls-need-the-exact-child-runauthorization-not-only-its-flattened-manifest-fields"></a>
**Nested LLM tool calls need the exact child `RunAuthorization`, not only its flattened manifest fields.** A nested council can carry the correct child manifest and action bindings yet still fail every tool call with `:nested_action_binding_lineage_missing` if `LlmHandler` or `ToolLoop` drops the opaque authority term. Thread the validated authority unchanged through both layers into `ActionsExecutor`; that is what projects the distinct child digest and matching parent digest without weakening the action-layer lineage checks (found 2026-07-10 during commit-tree council dogfood).

<!-- applied-learning: tests-must-never-move-or-rename-live-credential-stores-to-simulate-missing-credentials -->
<a id="applied-learning-tests-must-never-move-or-rename-live-credential-stores-to-simulate-missing-credentials"></a>
**Tests must never move or rename live credential stores to simulate missing credentials.** A `try/after` around `~/.codex/auth.json`, `~/.grok/auth.json`, or `~/.arbor/oauth` still strands real credentials if the VM is killed between rename and restore, and can trigger unrelated authentication/keychain behavior while the test runs. Give discovery code an explicit disable flag or injected path/module and test against that seam; leave operator credential files untouched (found 2026-07-11 reviewing the provider-discovery baseline repair).

<!-- applied-learning: arbitrary-integers-bypass-fixed-scalar-cost-estimates -->
<a id="applied-learning-arbitrary-integers-bypass-fixed-scalar-cost-estimates"></a>
**Arbitrary integers bypass fixed scalar cost estimates.** Treating every number as 32 estimated bytes before JSON encoding still admits a bignum with millions of decimal digits, and converting it with `value * 1.0` can raise before a later clamp. Bound integer bit size before encoding or arithmetic, and compare/reject before float conversion (found 2026-07-11 reviewing eval fingerprints and intent grading).

<!-- applied-learning: model-budgeting-is-a-portfolio-problem-not-a-single-dollar-counter -->
<a id="applied-learning-model-budgeting-is-a-portfolio-problem-not-a-single-dollar-counter"></a>
**Model budgeting is a portfolio problem, not a single dollar counter.** Centrally inventory each provider/model route, credential or subscription pool, reset window, concurrency limit, context/output limits, capability/tool support, latency/reliability history, sensitivity ceiling, and marginal cost. Subscription-backed OpenAI, Anthropic, Ollama, xAI, Z.ai, and Google capacity should be tracked as quota pools alongside metered OpenRouter, Groq, Venice, and direct API balances. Route by task requirements and opportunity cost, reserve scarce frontier capacity for architecture/security/final judgment, and record actual usage/outcomes so routing can improve from evidence rather than static model rankings (requested 2026-07-12).

<!-- applied-learning: arbor-s-model-budget-foundation-is-built-but-not-yet-one-routing-control-plane -->
<a id="applied-learning-arbor-s-model-budget-foundation-is-built-but-not-yet-one-routing-control-plane"></a>
**Arbor's model-budget foundation is built but not yet one routing control plane.** `Arbor.AI.BudgetTracker`, `QuotaTracker`, and `UsageStats` already persist spend, cooldowns, latency, and outcomes, while mandatory Engine budget middleware expects a separate `check_budget/0` + `record_usage/1` tracker contract. `QuotaTracker.check_and_mark/2` has no production error-path caller, and the AI budget tracker infers subscription use from model names such as `-cli`; an ACP Codex subscription model can therefore be classified like a metered OpenAI API call after provider normalization. Extend and reconcile these components rather than creating a fourth tracker: preserve route/credential-pool provenance through every call, feed quota failures into availability, and make routing consume the unified portfolio state (traced 2026-07-12 after discussing multi-provider budgeting).

<!-- applied-learning: compute-node-usage-must-attribute-the-resolved-request-route-not-session-defaults -->
<a id="applied-learning-compute-node-usage-must-attribute-the-resolved-request-route-not-session-defaults"></a>
**Compute-node usage must attribute the resolved request route, not session defaults.** A DOT node can pin `llm_provider` and `llm_model`; `build_llm_request/4` correctly gives those attrs priority, but `LlmHandler` currently logs, signals, and writes `session.usage` from `session.llm_provider` / `session.llm_model`. The multi-model review council therefore executed its pinned Ollama/OpenAI/xAI routes while observability reported blank provider/model fields. Resolve the effective route once (including sensitivity/fallback changes), then thread that identity through telemetry, usage, consultation records, and budgets so portfolio accounting is not silently wrong (found 2026-07-12 auditing council routing).

<!-- applied-learning: a-copied-oauth-refresh-token-can-be-invalidated-by-its-source-cli -->
<a id="applied-learning-a-copied-oauth-refresh-token-can-be-invalidated-by-its-source-cli"></a>
**A copied OAuth refresh token can be invalidated by its source CLI.** Arbor imports Codex/Grok credentials into `~/.arbor/oauth` and then prefers that copy, but the provider CLI can independently rotate the same single-use refresh-token lineage. The stale Arbor copy then fails with `refresh_token_reused` even while the CLI's newer access token works. Do not delete auth files or reimport another copy of the rotating refresh token to unblock a probe. This entry's original retry guidance was superseded by the exact-one-owner invariant below: source-owned mode may reread only a changed access token, while Arbor-owned mode requires an independently acquired credential family (found 2026-07-12 validating `gpt-5.6-sol`; corrected 2026-07-20 after reproducing cross-owner invalidation).

<!-- applied-learning: owner-process-test-timeouts-must-include-the-hardened-operation-s-real-cost-under-suite-load -->
<a id="applied-learning-owner-process-test-timeouts-must-include-the-hardened-operation-s-real-cost-under-suite-load"></a>
**Owner-process test timeouts must include the hardened operation's real cost under suite load.** A spawned workspace owner can legitimately spend several seconds in canonicalization and repeated Git storage/registration checks; a two-second `assert_receive` may fail first, let test teardown delete its temp repo, and make the still-running owner report a misleading path or storage-identity error. Use a bounded CI-scale timeout and keep teardown ownership explicit (found 2026-07-16 running the consolidated retained-workspace suite).

<!-- applied-learning: file-ls-1-materializes-the-entire-directory-before-an-entry-budget-can-fire -->
<a id="applied-learning-file-ls-1-materializes-the-entire-directory-before-an-entry-budget-can-fire"></a>
**`File.ls/1` materializes the entire directory before an entry budget can fire.** For adversary-influenced cleanup, isolate enumeration in a monitored process with an explicit heap/shared-binary ceiling and hand one name at a time to the deleting owner. Monitor the owner from every listing worker, bound receives by the cleanup deadline, and retain identity on worker overflow; a parent-side `Enum.take/2` does not bound allocation (found 2026-07-15 closing validation-tree resource exhaustion).

<!-- applied-learning: a-shutdown-cleanup-budget-must-be-shared-across-every-nested-operation -->
<a id="applied-learning-a-shutdown-cleanup-budget-must-be-shared-across-every-nested-operation"></a>
**A shutdown cleanup budget must be shared across every nested operation.** Counting retries does not bound shutdown when each Git/storage command owns a full timeout and `terminate/2` silently repeats the work. Establish one monotonic deadline above the sequence, pass only remaining time through exact facade primitives, keep it below the supervisor child window, and let bidirectional monitors handle crash convergence (found 2026-07-15 closing validation-owner shutdown bounds).

<!-- applied-learning: a-declared-validation-budget-must-reach-resource-setup-as-well-as-the-child-command -->
<a id="applied-learning-a-declared-validation-budget-must-reach-resource-setup-as-well-as-the-child-command"></a>
**A declared validation budget must reach resource setup as well as the child command.** The cross-app profile advertised a 600-second ceiling, but the compiler omitted `param.timeout` and `CrossApp.Shell` omitted the timeout when acquiring its dependency resource, so both silently fell back to 300 seconds and a healthy cold contained build expired before Mix completed. Compile `min(plan wall-clock, reviewed profile ceiling)` into each validation action and forward the validated value through owner-scoped setup; metadata that is not wired into execution is not a budget (found 2026-07-17 during Phase 6 cross-app dogfood).

<!-- applied-learning: cold-mix-env-test-compilation-is-not-app-test-execution-budget -->
<a id="applied-learning-cold-mix-env-test-compilation-is-not-app-test-execution-budget"></a>
**Cold `MIX_ENV=test` compilation is not app-test execution budget.** A fresh test environment can spend the entire shared test deadline compiling before the first selected suite starts. Run an explicit test-environment compile after development compile and xref, require that stage in validation evidence, and start the shared per-app test deadline only after it succeeds; preserve the exact selected path in later execution failures (found 2026-07-17 during Phase 6 cross-app dogfood).

<!-- applied-learning: a-per-process-shell-ceiling-is-not-an-aggregate-sequential-validation-budget -->
<a id="applied-learning-a-per-process-shell-ceiling-is-not-an-aggregate-sequential-validation-budget"></a>
**A per-process Shell ceiling is not an aggregate sequential validation budget.** Keep every contained child under the immutable spawn-capable maximum, split large selected suites into deterministic bounded units, and give the enclosing stage a separately reviewed plan-derived deadline. Reusing one timeout for both contracts makes a healthy multi-file suite fail when its total duration exceeds the maximum allowed for any one process (found 2026-07-17 when the Commands suite exceeded the 600-second cross-app operation ceiling after its individual benchmark fixtures were repaired).

<!-- applied-learning: exunit-s-per-test-timeout-is-a-third-validation-budget-layer -->
<a id="applied-learning-exunit-s-per-test-timeout-is-a-third-validation-budget-layer"></a>
**ExUnit's per-test timeout is a third validation budget layer.** A 600-second contained process ceiling and a 1,200-second aggregate test-stage deadline do not override ExUnit's default 60-second timeout for one test. Slow integration fixtures that run several independently bounded scenarios need an explicit per-test cap below the process ceiling, while their inner worker/setup/cancellation deadlines remain much smaller; otherwise constrained one-CPU/virtiofs scheduling can preempt healthy assertions even though every owned subprocess is bounded (found 2026-07-17 after splitting the Commands benchmark adapter suite).

<!-- applied-learning: normalize-forced-reqllm-tool-choices-at-the-adapter-boundary -->
<a id="applied-learning-normalize-forced-reqllm-tool-choices-at-the-adapter-boundary"></a>
**Normalize forced ReqLLM tool choices at the adapter boundary.** Arbor's ToolLoop emits OpenAI's nested string-key choice for a reserved terminal tool, but ReqLLM/NimbleOptions rejects that map before transport. Convert supported canonical and OpenAI forms to the bounded atom-keyed `%{type: "tool", name: name}` form, reject malformed names, and regress the exact `build_req_opts/2` production shape through ReqLLM option processing (found 2026-07-18 when every Ollama council reviewer failed before transport).

<!-- applied-learning: a-rotating-oauth-refresh-token-family-must-have-exactly-one-owner -->
<a id="applied-learning-a-rotating-oauth-refresh-token-family-must-have-exactly-one-owner"></a>
**A rotating OAuth refresh-token family must have exactly one owner.** Copying a Codex/Grok CLI refresh token into `~/.arbor` and writing Arbor's rotations only to that copy does not make the family independent: either process can rotate first and invalidate the other, and an Arbor-local single-flight lock cannot coordinate an external CLI. Use an Arbor-acquired family that only Arbor refreshes, or treat the external CLI as owner and read through current access tokens without ever persisting or submitting its refresh token. On `refresh_token_reused`, never overwrite/delete/retry the same token; require relogin for Arbor-owned credentials or one generation-changing reread for source-owned credentials (found 2026-07-18 when OpenAI OAuth council reviewers repeatedly failed).

<!-- applied-learning: provider-security-flags-must-be-proven-on-the-exact-transport -->
<a id="applied-learning-provider-security-flags-must-be-proven-on-the-exact-transport"></a>
**Provider security flags must be proven on the exact transport.** Grok CLI `--tools`, `--disallowed-tools`, and `--deny Bash(*)` are headless-policy claims that did not constrain `grok agent stdio`; an anonymous ACP denial proves only missing handler identity/authority, not provider-level shell containment. Test the actual ACP transport and client-visible contract, not a nearby CLI mode (found 2026-07-19 during Grok ACP containment work).

<!-- applied-learning: streamed-function-call-arguments-are-not-terminal-json-until-the-protocol-says-the-item-is-done -->
<a id="applied-learning-streamed-function-call-arguments-are-not-terminal-json-until-the-protocol-says-the-item-is-done"></a>
**Streamed function-call arguments are not terminal JSON until the protocol says the item is done.** xAI Responses emits valid `response.output_item.added` events whose in-progress function call has `arguments: ""`. Apply bounded JSON decoding to the event envelope, but validate and charge embedded tool-argument JSON only on the terminal `response.output_item.done` item. A generic recursive detector for every map containing `name` and `arguments` will reject legitimate intermediate events as malformed (found 2026-07-20 reproducing the xAI council reviewer failure against the raw SSE stream).

<!-- applied-learning: a-local-acp-worker-handle-is-not-provider-continuity-identity -->
<a id="applied-learning-a-local-acp-worker-handle-is-not-provider-continuity-identity"></a>
**A local ACP worker handle is not provider continuity identity.** A provider process and
Arbor-managed worker can both exist even when `session/new` returned no usable
`sessionId`; accepting that state defers the real protocol error until resume/recovery and
makes pool configuration look responsible. Preserve an intentional pooled pre-session
handle, but after actual creation require a bounded, nonblank provider session ID before
registering or publishing the worker as ready. For resume, the validated requested ID is
the continuity authority because a valid load response may omit it; any response alias that
is present must match exactly. Provider IDs are opaque: validate their bounds and shape but
never trim or otherwise rewrite their bytes (found 2026-07-21 after two Grok 4.5 coding
tasks failed with `worker_provider_session_id_missing`).
