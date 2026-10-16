# Applied Learning: Providers and OAuth

Read this when changing LLM/provider routing, OAuth credentials, refresh ownership, quotas, budgets, egress, or transport behavior.

## Retained Applied Learning

<!-- applied-learning: backend-specific-responses-usage-extensions-must-be-bounded-and-discarded -->
<a id="applied-learning-backend-specific-responses-usage-extensions-must-be-bounded-and-discarded"></a>
**Backend-specific Responses usage extensions must be bounded and discarded when they are not evidence.**
OpenAI's ChatGPT Responses backend added `usage.attribution`, whose message-keyed items include
token counters and copies of message content. Observe only field names while diagnosing; accept
the object only on the exact backend, rely on the enclosing stream's byte/node/depth limits, and do
not retain or log it. Validate fields that contribute evidence, but do not couple Arbor to the
private structure of discarded metadata merely to appear stricter (found 2026-09-02 when every
OpenAI OAuth reviewer failed with `invalid_terminal_usage_keys`).

The same assumption recurred on 2026-09-22: all seven xAI council failures rejected
`usage.context_details` because Arbor required its counters to equal top-level usage.
A process-scoped, numeric-only trace of one normal council-bridge call observed billing
input/output `655/141` versus context input/output `655/148`, with exactly the expected two
context fields. [xAI's own client](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-sampler/src/client.rs)
distinguishes live-context counts from cumulative billing counts. Validate context counters
independently; neither equality nor a context-less-than-billing rule is valid. Keep canonical
billing consistency, backend scoping, and decoder resource limits intact. This is a diagnosed
parser defect, not evidence of invalid credentials or a rationale-contract failure. Fixed on
2026-09-22 by validating each context counter independently against the existing token bound;
the live-value regression fails on the old parser and passes with the fix. Malformed context,
wrong-backend metadata, and inconsistent billing remain rejected (117 targeted tests passed).
Use the actual caller path for a live reproduction: adding `require_live_pipeline: true` to
the generic facade rejected this OAuth route locally with `:live_completion_provider_unsupported`
before any network call; the ordinary council bridge reached the failing terminal validator.

Exercise the actual upstream decoder and response builder when testing optional metadata.
Streaming and non-streaming paths can produce different shapes despite sharing a struct type:
on 2026-09-29, ReqLLM's streaming builder retained raw string-keyed `reasoning_details` maps,
while Arbor's translator matched only `ReasoningDetails` structs. A visible `CHAT_OK` delta
was followed by a failed turn. Extract only supported text fields, preserve opaque metadata
as opaque, and verify final response acceptance rather than treating displayed deltas as success.

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

Measure a backend consultation from admission through committed response, not
only its main LLM call: local preprocessing, authorization, queueing and
persistence also consume the caller's budget. Preserve time for the containing
voice response and distinguish the audio-turn deadline from the longer device
operation deadline. On 2026-09-29, a successful typed turn took about 9.3 seconds
with only 3.0 seconds in the main LLM call; voice's five-second tool budget
could not accommodate the same path. Do not diagnose a caller-down log alone
as proof of a particular timer firing; instrument the exact timeout branch.
When promoting a voice prototype into an interface, remove unnecessary timing
caps and make retained policy durations configurable with validated relationships;
separate recording duration, tool wait, processing, playback and cleanup from
cost budgets and actual protocol constraints. Fixed test-clip values must not
silently become product requirements (user clarification, 2026-09-29).

Keep a closed failure-stage diagnostic before normalizing private provider or
protocol errors into a generic public result. A `turn_failed` after successful
capture does not distinguish provider receive, transcript ordering, authority,
handoff or finalization failures. Record only source-owned categories and safe
structural state, never raw frames, audio, text or credentials. On 2026-09-30 the
physical voice journey failed about 1.3 seconds after capture closed; the sole
generic log could neither identify the cause nor justify changing a 15-second
tool timeout. Sensitive workers also make absent trace events inconclusive.

Keep missing/null protocol fields distinct from unrecognized values, and retain
the last successful outbound effect plus inbound milestones when reporting a
provider rejection. Configuration-only code/parameter allowlists made absent
fields indistinguishable from unrecognized runtime values behind the same
`unknown` pair during the 2026-09-30 follow-up investigation. A fresh connection rejected
before any backend consultation is not evidence of previous-turn cleanup or
tool overlap. Preserve this uncertainty until the actual rejecting phase is
observed; do not guess a wire-order change from a generic error.

Compare an early-finished recording with a recording that reaches its configured
limit before attributing a provider failure to a new device control. Separately
check the typed backend: successful subscription text inference does not prove
realtime speech inference. An acknowledgement-order candidate remains an
experiment until an actual provider comparison supports it (2026-10-05).

Keep provider work and cleanup budgets separate. The receive reservation on
2026-10-05 retained the voice-turn deadline, but handoff silently clamped the
acknowledgement wait to cleanup's five seconds and killed its worker. Bound each
receive handoff by the existing worker operation ceiling within the original
turn deadline; keep cleanup independently bounded. Test long valid reservations
against that ceiling rather than passing an unsupported full deadline through.

Distinguish empty, malformed, oversized and conflicting completed speech text
at the existing reducer rejection boundary. A successful retry does not prove
which one occurred, and exact duplicate completions may already be idempotent.
Keep these diagnostics content-free and preserve the admission gate until the
observed category supports a change (2026-09-30 intermittent Voice failure).

When repeated completed events conflict, preserve item/response relationships
before flattening the provider protocol into text-only events. A second valid
transcript is not necessarily a harmless duplicate or a correction; accepting it
after tool admission can change the input that authorized the tool. Likewise,
an empty normalized terminal is not evidence of a timeout when response status
and completed output were discarded. Observe bounded relationships and status
first, without logging payloads (2026-09-30 repeated Voice failures).

<!-- applied-learning: nested-llm-tool-calls-need-the-exact-child-runauthorization-not-only-its-flattened-manifest-fields -->
<a id="applied-learning-nested-llm-tool-calls-need-the-exact-child-runauthorization-not-only-its-flattened-manifest-fields"></a>
**Nested LLM tool calls need the exact child `RunAuthorization`, not only its flattened manifest fields.** A nested council can carry the correct child manifest and action bindings yet still fail every tool call with `:nested_action_binding_lineage_missing` if `LlmHandler` or `ToolLoop` drops the opaque authority term. Thread the validated authority unchanged through both layers into `ActionsExecutor`; that is what projects the distinct child digest and matching parent digest without weakening the action-layer lineage checks (found 2026-07-10 during commit-tree council dogfood).

<!-- applied-learning: tests-must-never-move-or-rename-live-credential-stores-to-simulate-missing-credentials -->
<a id="applied-learning-tests-must-never-move-or-rename-live-credential-stores-to-simulate-missing-credentials"></a>
**Tests must never move or rename live credential stores to simulate missing credentials.** A `try/after` around `~/.codex/auth.json`, `~/.grok/auth.json`, or `~/.arbor/oauth` still strands real credentials if the VM is killed between rename and restore, and can trigger unrelated authentication/keychain behavior while the test runs. Give discovery code an explicit disable flag or injected path/module and test against that seam; leave operator credential files untouched (found 2026-07-11 reviewing the provider-discovery baseline repair).

Verify the effective fallback, not just the override's presence. An empty
`oauth_source_files` map falls back to the operator's OpenAI auth file; use an
explicit absent file inside the private test directory. Likewise, `ARBOR_HOME`
alone does not isolate SQLite, master-key and OAuth defaults that resolve
independently from the user home. Configure their existing path seams explicitly
and leave `HOME` unchanged (2026-09-29 cross-surface runner review).

<!-- applied-learning: arbitrary-integers-bypass-fixed-scalar-cost-estimates -->
<a id="applied-learning-arbitrary-integers-bypass-fixed-scalar-cost-estimates"></a>
**Arbitrary integers bypass fixed scalar cost estimates.** Treating every number as 32 estimated bytes before JSON encoding still admits a bignum with millions of decimal digits, and converting it with `value * 1.0` can raise before a later clamp. Bound integer bit size before encoding or arithmetic, and compare/reject before float conversion (found 2026-07-11 reviewing eval fingerprints and intent grading).

<!-- applied-learning: model-budgeting-is-a-portfolio-problem-not-a-single-dollar-counter -->
<a id="applied-learning-model-budgeting-is-a-portfolio-problem-not-a-single-dollar-counter"></a>
**Model budgeting is a portfolio problem, not a single dollar counter.** Centrally inventory each provider/model route, credential or subscription pool, reset window, concurrency limit, context/output limits, capability/tool support, latency/reliability history, sensitivity ceiling, and marginal cost. Subscription-backed OpenAI, Anthropic, Ollama, xAI, Z.ai, and Google capacity should be tracked as quota pools alongside metered OpenRouter, Groq, Venice, and direct API balances. Route by task requirements and opportunity cost, reserve scarce frontier capacity for architecture/security/final judgment, and record actual usage/outcomes so routing can improve from evidence rather than static model rankings (requested 2026-07-12).

<!-- applied-learning: compute-node-usage-must-attribute-the-resolved-request-route-not-session-defaults -->
<a id="applied-learning-compute-node-usage-must-attribute-the-resolved-request-route-not-session-defaults"></a>
**Compute-node usage must attribute the resolved request route, not session defaults.** A DOT node can pin `llm_provider` and `llm_model`; `build_llm_request/4` correctly gives those attrs priority, but `LlmHandler` currently logs, signals, and writes `session.usage` from `session.llm_provider` / `session.llm_model`. The multi-model review council therefore executed its pinned Ollama/OpenAI/xAI routes while observability reported blank provider/model fields. Resolve the effective route once (including sensitivity/fallback changes), then thread that identity through telemetry, usage, consultation records, and budgets so portfolio accounting is not silently wrong (found 2026-07-12 auditing council routing).

<!-- applied-learning: file-ls-1-materializes-the-entire-directory-before-an-entry-budget-can-fire -->
<a id="applied-learning-file-ls-1-materializes-the-entire-directory-before-an-entry-budget-can-fire"></a>
**`File.ls/1` materializes the entire directory before an entry budget can fire.** For adversary-influenced cleanup, isolate enumeration in a monitored process with an explicit heap/shared-binary ceiling and hand one name at a time to the deleting owner. Monitor the owner from every listing worker, bound receives by the cleanup deadline, and retain identity on worker overflow; a parent-side `Enum.take/2` does not bound allocation (found 2026-07-15 closing validation-tree resource exhaustion).

<!-- applied-learning: a-shutdown-cleanup-budget-must-be-shared-across-every-nested-operation -->
<a id="applied-learning-a-shutdown-cleanup-budget-must-be-shared-across-every-nested-operation"></a>
**A shutdown cleanup budget must be shared across every nested operation.** Counting retries does not bound shutdown when each Git/storage command owns a full timeout and `terminate/2` silently repeats the work. Establish one monotonic deadline above the sequence, pass only remaining time through exact facade primitives, keep it below the supervisor child window, and let bidirectional monitors handle crash convergence (found 2026-07-15 closing validation-owner shutdown bounds).

<!-- applied-learning: a-declared-validation-budget-must-reach-resource-setup-as-well-as-the-child-command -->
<a id="applied-learning-a-declared-validation-budget-must-reach-resource-setup-as-well-as-the-child-command"></a>
**A declared validation budget must cover resource setup as well as the child command.** Metadata that is not compiled into execution is not a budget. Derive each nested subdeadline from the owner's remaining time, including projection and transport headroom and the system ceiling in `Arbor.Shell.SpawnCapableTimeout`. Propagate that remaining time into setup, actions, and `execute_spawn_capable/3` probes. Each layer returns its own timeout and contains its children. A probe that inherits an unbounded or default timeout can outlive the stage that admitted it. (Merged 2026-10-16 from 2 entries; first found 2026-07-17, last 2026-08-28.)

<!-- applied-learning: cold-mix-env-test-compilation-is-not-app-test-execution-budget -->
<a id="applied-learning-cold-mix-env-test-compilation-is-not-app-test-execution-budget"></a>
**Cold `MIX_ENV=test` compilation is not app-test execution budget.** A fresh test environment can spend the entire shared test deadline compiling before the first selected suite starts. Run an explicit test-environment compile after development compile and xref, require that stage in validation evidence, and start the shared per-app test deadline only after it succeeds; preserve the exact selected path in later execution failures (found 2026-07-17 during Phase 6 cross-app dogfood).

<!-- applied-learning: exunit-s-per-test-timeout-is-a-third-validation-budget-layer -->
<a id="applied-learning-exunit-s-per-test-timeout-is-a-third-validation-budget-layer"></a>
**Budget each validation deadline as its own layer.** Keep the inner operation or compute-node cap, the ExUnit case timeout, the contained-child ceiling, and the aggregate stage deadline separate. `Arbor.Shell.SpawnCapableTimeout` allows 600_000 ms for `:standard` and 1_200_000 ms for `:intensive`; the intensive figure is one contained process, not the sum of a sequential batch. Size each ExUnit case for the hardened operation's measured cost under suite load, including startup and a cleanup reserve, and do not lower an enclosing deadline to make a case fit. Leave model output capacity at the provider budget unless measurement shows a lower cap still completes the task. Each layer reports its own timeout and still contains its children. (Merged 2026-10-16 from 5 entries; first found 2026-07-16, last 2026-10-09.)

<!-- applied-learning: normalize-forced-reqllm-tool-choices-at-the-adapter-boundary -->
<a id="applied-learning-normalize-forced-reqllm-tool-choices-at-the-adapter-boundary"></a>
**Normalize forced ReqLLM tool choices at the adapter boundary.** Arbor's ToolLoop emits OpenAI's nested string-key choice for a reserved terminal tool, but ReqLLM/NimbleOptions rejects that map before transport. Convert supported canonical and OpenAI forms to the bounded atom-keyed `%{type: "tool", name: name}` form, reject malformed names, and regress the exact `build_req_opts/2` production shape through ReqLLM option processing (found 2026-07-18 when every Ollama council reviewer failed before transport).

Apply the same boundary discipline to persisted message content. Prove history
continuity through the final provider encoder using JSON-round-tripped storage
shapes, not only an Arbor Request capture. On 2026-09-30, the test phrase survived
Session hydration and compaction but canonical string-keyed text blocks became
empty user and assistant content in OpenRouter encoding. The model's claim that
it could not see the phrase was consistent with that loss; message counts and
a green capture-provider test had not proved the wire content. Normalize known
text representations without stringifying unknown blocks or promoting stored
tool/thinking records into new protocol effects.
Preserve each role's prior exclusions and test unsupported assistant blocks
before expanding normalization. Trace the actual provider path before inferring
disclosure from a generic encoding helper: Google's context path first uses the
shared OpenAI encoder, which drops unknown parts before its generic text fallback.
The fallback alone did not establish a disclosure in this investigation.

Distinguish missing history from ambiguous recall framing. Inspect both exact
recent content in the local provider encoding and the actual handler's message
count before treating a model's self-report as proof of loss. Label retrieved
context as supplied by Arbor and separate it from the unchanged current user
message; private recall may include the current session, so do not label all of
it as past-session material. On 2026-09-30, a typed `yes please` received an answer
that attributed the injected recall block to the user even though the recent
voice rows survived Session, compaction and local encoding. A reconstruction is
not a captured historical request, and clearer framing does not prove model
compliance.

<!-- applied-learning: a-rotating-oauth-refresh-token-family-must-have-exactly-one-owner -->
<a id="applied-learning-a-rotating-oauth-refresh-token-family-must-have-exactly-one-owner"></a>
**A rotating OAuth refresh-token family must have exactly one owner.** Do not clone a refresh token into two stores that refresh independently; the source CLI can invalidate the copy. Publish Arbor-owned credentials with `Arbor.LLM.OAuth.publish_arbor_owned/2`. Source-owned token maps must be empty. `reread_source_credential/1` is OpenAI-only; xAI source-owned refresh returns `:oauth_source_owned_unsupported`. On `:refresh_token_reused`, relogin for an Arbor-owned family, or perform one generation-changing reread for OpenAI source-owned only. Keep the credential-origin directory as the directory the credential was issued from. One family has one refresh owner. (Merged 2026-10-16 from 3 entries; first found 2026-07-12, last 2026-07-18.)

<!-- applied-learning: provider-security-flags-must-be-proven-on-the-exact-transport -->
<a id="applied-learning-provider-security-flags-must-be-proven-on-the-exact-transport"></a>
**Prove provider security flags on the exact transport.** CLI tool-allow and tool-deny flags do not constrain grok agent stdio. The no-shell boundary is the Arbor-owned profile `arbor-agent-profile.md`, mode 0600, checked by `Arbor.AI.AcpSession.RuntimeHome.verify_grok_agent_profile/1` for bytes, path, type, and mode at launch and at reconnect. That profile disallows `run_terminal_cmd`, `task`, `get_task_output`, and `kill_task`. Qualify the effective adapter, including a default provider and a fallback: provider `acp` can launch the native CLI even when the runtime setting is `arbor`. Prove the route with a denied terminal effect and a successful native edit on that same transport. (Merged 2026-10-16 from 2 entries; first found 2026-07-19, last 2026-07-19.)

<!-- applied-learning: provider-registration-is-independent-of-credential-readiness -->
<a id="applied-learning-provider-registration-is-independent-of-credential-readiness"></a>
**Provider registration is independent of credential readiness.** A known provider
route must remain registered even when its credential is expired, unsafe to migrate,
or requires login. Validate credentials lazily at the adapter boundary and return the
typed migration, login, or refresh error there; omitting the adapter during client
construction turns an actionable auth failure into misleading `unknown_provider`
evidence and prevents health and routing systems from identifying the real fault
(found 2026-07-28 when legacy OpenAI and xAI OAuth stores made council reviewers
appear unconfigured).

<!-- applied-learning: streamed-function-call-arguments-are-not-terminal-json-until-the-protocol-says-the-item-is-done -->
<a id="applied-learning-streamed-function-call-arguments-are-not-terminal-json-until-the-protocol-says-the-item-is-done"></a>
**Streamed function-call arguments stay incomplete while the protocol item is open.** Reassemble SSE events before parsing JSON. Transport chunks are not events, and a terminal `[DONE]` marker is not a JSON document. Preserve every tool-argument fragment; a streaming tool call can drop argument bytes before application code sees them. Validate and charge embedded arguments only after the protocol item is complete, using `Arbor.LLM.ResponseBudget.decode_json_source_with_measurements/2`, `preflight_json/2`, and `decode_json_with_measurements/2` through `Arbor.LLM.Adapter.ReqLLM.BoundedStream.process/2`. Assert the exact assembled bytes across adversarial chunk splits. (Merged 2026-10-16 from 3 entries; first found 2026-07-20, last 2026-08-25.)

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

<!-- applied-learning: sequential-readiness-observers-need-a-bounded-capture-time-skew -->
<a id="applied-learning-sequential-readiness-observers-need-a-bounded-capture-time-skew"></a>
**Sequential readiness observers need a bounded capture-time skew.** If the coordinator
records its observation time before invoking a provider observer, the provider's honest
timestamp will normally be a few milliseconds later; a strict `provider_observed_at <=
readiness_observed_at` check rejects every healthy call. Permit one small documented skew
window for that call ordering, still require provider expiry after the coordinator time,
and reject evidence beyond the window rather than refreshing it (found 2026-07-22 while
reviewing live coding readiness).

<!-- applied-learning: never-recursively-search-credential-or-provider-session-roots -->
<a id="applied-learning-never-recursively-search-credential-or-provider-session-roots"></a>
**Never recursively search credential or provider-session roots.** A broad command such as
`rg ~/.codex ~/.grok ~/.claude ~/.arbor` can copy bearer tokens, refresh tokens, session
transcripts, or keychain-related metadata into terminal and agent logs even when the search
term looks harmless. Search source, configuration, and documentation roots separately. When
credential state itself must be inspected, use a known exact file plus bounded metadata-only
extraction or the product's redacting facade; never print raw credential or session content
(found 2026-07-30 while auditing provider OAuth client eligibility).

<!-- applied-learning: verify-the-shipped-credential-envelope-not-only-provider-auth-documentation -->
<a id="applied-learning-verify-the-shipped-credential-envelope-not-only-provider-auth-documentation"></a>
**Verify the shipped credential envelope, not only provider auth documentation.** Provider
documentation and current source can describe a newer store shape than an installed release.
Before enabling external-source-owned OAuth, inspect only the known exact file with
metadata-only extraction and prove that a current access token plus stable generation metadata
actually exist; never infer feasibility from refresh-token presence or print credential values.
On 2026-07-31, current xAI documentation described an access token while the installed Grok
0.2.117 nested store exposed only a refresh token, so xAI source-owned mode remains disabled
(found 2026-07-31 during the Phase E provider-login audit).

<!-- applied-learning: canonical-model-ids-are-not-provider-wire-model-ids -->
<a id="applied-learning-canonical-model-ids-are-not-provider-wire-model-ids"></a>
**Canonical model IDs are not provider wire model IDs.** Preserve the canonical requested
`model`, exact sent `provider_ref`, and provider-reported `confirmed_model` as separate fields.
Confirmation compares the trusted terminal model to `provider_ref`; requiring it to equal the
canonical ID rejects legitimate aliases and erases which name the provider actually executed
(found 2026-07-31 while reviewing Phase E Responses attestation).

<!-- applied-learning: durable-oauth-login-must-request-the-provider-s-refresh-grant-scope -->
<a id="applied-learning-durable-oauth-login-must-request-the-provider-s-refresh-grant-scope"></a>
**Durable OAuth login must request the provider's refresh-grant scope.** A mocked token
response containing a refresh token can make acquisition tests pass even when the real
authorization request cannot obtain one. Assert the exact scope at the public request boundary
and dogfood each provider's live flow; keep refresh-token publication fail-closed rather than
accepting an access-only credential. On 2026-08-01, xAI accepted Arbor's device authorization
but omitted a refresh token until the request included `offline_access`. A later live Responses
canary proved that refresh authority is independent of resource authority: the resulting
`grok-cli:access` token refreshed correctly but `/v1/responses` returned 403, while the replacement
`api:access` token reached Responses but the CLI model catalog returned 403. xAI discovery
advertises both scopes, and Arbor uses both protected resources, so its single owned credential
must request `openid profile email offline_access api:access grok-cli:access`. Assert refresh and
every target-resource scope against the live endpoints, not only against a client template.

<!-- applied-learning: background-evidence-refresh-must-start-before-its-freshness-deadline -->
<a id="applied-learning-background-evidence-refresh-must-start-before-its-freshness-deadline"></a>
**Background evidence refresh must start before its freshness deadline.** A coordinator that
polls every 30 seconds but refreshes only after a five-minute catalog expires creates a recurring
fail-closed outage even when both mechanisms work as designed. Trigger refresh when remaining
freshness is no greater than the next steady interval plus the bounded refresh timeout and
scheduling jitter. If a proactive refresh fails transiently, keep still-valid last-good evidence
usable until its actual expiry but retry on backoff instead of waiting another steady interval.
Pin the boundary with an injected clock and repeatedly exercise the timer regression (found
2026-08-01 during the final Phase E provider-route health check).

<!-- applied-learning: long-lived-provider-processes-can-outlive-cli-upgrades-and-oauth-relogin -->
<a id="applied-learning-long-lived-provider-processes-can-outlive-cli-upgrades-and-oauth-relogin"></a>
**Long-lived provider processes can outlive a CLI upgrade and an OAuth relogin.** An isolated ACP runtime home snapshots provider credentials at worker creation; a later relogin does not repair the open session. Bind readiness to the process, the executable, and the credential generation, using metadata only and never reading the secret. A timestamp disagreement is a hypothesis, not proof of causation. Replace only the stale owned runtime, then verify a real refresh. Do not reinterpret HTTP 403 as a classifier defect. (Merged 2026-10-16 from 2 entries; first found 2026-08-02, last 2026-08-03.)

<!-- applied-learning: oauth-readiness-must-separate-local-validity-from-remote-acceptance -->
<a id="applied-learning-oauth-readiness-must-separate-local-validity-from-remote-acceptance"></a>
**OAuth readiness must separate local validity from remote acceptance.** Local credential metadata — structure, scope, expiry, and cached usage displays — is not remote acceptance. Probe with an exact-model or exact-resource canary and never print the secret. On an Arbor-owned 401, perform at most one receipt-authorized owned refresh and one retry. A call specified as a single attempt stays one resource request. Treat login or rotation as a trigger inference unless the provider confirms the cause. (Merged 2026-10-16 from 2 entries; first found 2026-08-03, last 2026-08-13.)

<!-- applied-learning: separate-chat-routing-from-embedding-egress-and-refresh-both-provider-caches -->
<a id="applied-learning-separate-chat-routing-from-embedding-egress-and-refresh-both-provider-caches"></a>
**Separate text-generation routing from embedding egress, and refresh both provider caches after live configuration changes.** Enabling an Ollama Cloud council through the shared `ARBOR_OLLAMA_BASE_URL` also redirects embeddings; authorization to send review prompts is not authorization to move every embedding request off-host. Use `ARBOR_OLLAMA_CHAT_BASE_URL` for chat only, preserve the embedding endpoint, and regress the actual runtime config in an isolated environment. For a running node, updating Application config and the default LLM client does not refresh `ProviderCatalog`'s separate availability cache: explicitly refresh it, then recheck exact-plan review routes. Credential presence and model inventory are not generation evidence; test the exact configured model ids (found 2026-09-07 enabling the new factory's three-provider council).

<!-- applied-learning: prove-responses-store-false-by-retrieve-and-resume-failure-not-the-outbound-flag -->
<a id="applied-learning-prove-responses-store-false-by-retrieve-and-resume-failure-not-the-outbound-flag"></a>
**Prove Responses `store: false` by retrieve and resume failure, not the outbound flag.** A captured body with `"store": false` is necessary but not the honor check. After a successful ChatGPT Codex `POST /backend-api/codex/responses`, take the `resp_*` id from `response.completed` and assert `GET .../responses/{id}` is 404 and a follow-up `POST` with `previous_response_id` is 400. The completed object echoing `store: false` is corroboration only. Phase 3 websocket/Lite must copy outbound `store: false` and omit `previous_response_id` on create; connection-scoped WS resume is a different mechanism (found 2026-08-25 verifying the Codex-native harness).

<!-- applied-learning: provider-startup-defaults-are-not-acknowledged-operation-formats -->
<a id="applied-learning-provider-startup-defaults-are-not-acknowledged-operation-formats"></a>
**Provider startup defaults are not acknowledged operation formats.** When a transport negotiates media, keep requested settings, initial defaults and confirmed formats distinct. Admit bytes only after the provider acknowledges the exact format and transport within the original operation deadline; replay the documented startup order in a positive fixture alongside malformed-format negatives. On 2026-09-27, xAI's initial `session.created` correctly reported 24 kHz input/output before Arbor requested 16 kHz/24 kHz. Treating that initial event as an acknowledged mismatch rejected normal startup, while hardcoded metadata falsely claimed the requested input rate. Configuration now owns acknowledgement before publishing usable PCM metadata.

A fake that echoes the client's configuration as the provider acknowledgement proves
internal consistency, not the provider's response contract. Use independently
scripted startup frames, and retain bounded distinctions between provider errors,
unexpected events and rejected format acknowledgements before closing the socket.
On 2026-09-29, the live xAI handshake failed while auto-echo fixtures could not
identify which provider response was rejected; do not relax format admission from
that generic error alone.

Separate known control notifications from format acknowledgements. The same
incident was narrowed to an application-level JSON `ping`, distinct from a
WebSocket control frame. Discard only that exact observed control event under
the existing absolute deadline; keep unknown events, premature media and invalid
acknowledgements rejected. When allowlisted diagnostics still say "unknown", use
a short-lived trace projecting only the needed protocol label with argument
capture disabled, and tear it down after one observation. Repeated blind retries
and guessed decoder changes do not supply the missing evidence.

The subsequent acknowledgement supplied correct nested PCM rates plus legacy
`input_audio_format` and `output_audio_format` fields equal to `"not specified"`.
Normalize only that exact non-declaration at the session envelope; it cannot
replace the required canonical formats, and real conflicting declarations still
fail. Inspect the small relevant metadata projection together (shape, length and
descriptor), rather than repeatedly guessing enum labels and losing the value
behind an "other" classification.

Keep provider framing separate from normalized event limits. A valid provider
PCM blob may exceed an internal 64 KiB event while fitting the already bounded
whole-blob decoder; validate the complete blob first, then emit aligned bounded
chunks in order without raising downstream per-event or per-turn limits. Retain
and redact the bounded remainder, and preserve the receive deadline before
emitting buffered chunks (2026-09-29 Voice response investigation). Diagnostic
traces of long event streams should return counts, maxima and bounded failure
samples directly; an inspected list wrapped in a string can be truncated again
by the tool renderer and lose the decisive final sample.

Verify the exact nullable field in provider configuration, not only the apparent
meaning of null. xAI documents `turn_detection.type: null`; Arbor sent the whole
`turn_detection` container as null. On 2026-09-30, twelve observed recordings still
emitted server-VAD start/stop events and two completed transcripts apiece while
Arbor also committed manually. An independently scripted acknowledgement plus an
exact outbound JSON assertion catches this mismatch; an echo fake does not.
Do not invent acknowledgement fields the provider has not promised to echo.

<!-- applied-learning: release-provider-audio-only-for-the-exact-guarded-final-text -->
<a id="applied-learning-release-provider-audio-only-for-the-exact-guarded-final-text"></a>
**Release provider audio only for the exact guarded final text.** When a guard or
source-owned finalizer rewrites, truncates or suppresses text, suppress the original
provider PCM unless provider terminal text, durable authoritative text and guarded
speech text all match exactly. Matching only the first two can disclose content the
guard replaced. A screen-only verdict must expose no spoken text or audio; keep its
display text in a separate field. Regress a safe rewritten guard while the provider
and durable texts still agree (found 2026-09-27 reviewing VP-07A1 presentation).

Surface the actual audio disposition separately from successful text completion.
Whitespace normalization alone can make exact guarded text differ, while a
truncated verdict also suppresses existing provider PCM. On 2026-09-30, source
review found that absent PCM becomes successful `screen_only` and the dashboard
discarded that disposition, hiding why a voice turn could finish silently. A
stored transcript cannot retrospectively prove the presentation decision;
observe closed verdict/equality metadata at the decision boundary and preserve
the speech guard while designing any guarded synthesis fallback.
