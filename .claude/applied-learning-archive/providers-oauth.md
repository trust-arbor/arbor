# Applied Learning archive: providers-oauth

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: owner-process-test-timeouts-must-include-the-hardened-operation-s-real-cost-under-suite-load -->
<a id="applied-learning-owner-process-test-timeouts-must-include-the-hardened-operation-s-real-cost-under-suite-load"></a>
**Owner-process test timeouts must include the hardened operation's real cost under suite load.** A spawned workspace owner can legitimately spend several seconds in canonicalization and repeated Git storage/registration checks; a two-second `assert_receive` may fail first, let test teardown delete its temp repo, and make the still-running owner report a misleading path or storage-identity error. Use a bounded CI-scale timeout and keep teardown ownership explicit (found 2026-07-16 running the consolidated retained-workspace suite).

<!-- applied-learning: a-per-process-shell-ceiling-is-not-an-aggregate-sequential-validation-budget -->
<a id="applied-learning-a-per-process-shell-ceiling-is-not-an-aggregate-sequential-validation-budget"></a>
**A per-process Shell ceiling is not an aggregate sequential validation budget.** Keep every contained child under the immutable spawn-capable maximum, split large selected suites into deterministic bounded units, and give the enclosing stage a separately reviewed plan-derived deadline. Reusing one timeout for both contracts makes a healthy multi-file suite fail when its total duration exceeds the maximum allowed for any one process (found 2026-07-17 when the Commands suite exceeded the 600-second cross-app operation ceiling after its individual benchmark fixtures were repaired).

<!-- applied-learning: a-rotating-oauth-refresh-token-cannot-be-safely-cloned-into-two-independently-refreshing-stores -->
<a id="applied-learning-a-rotating-oauth-refresh-token-cannot-be-safely-cloned-into-two-independently-refreshing-stores"></a>
**A rotating OAuth refresh token cannot be safely cloned into two independently
refreshing stores.** The 2026-07-18 council failure showed `~/.arbor/oauth/openai.json`
remained from 2026-07-04 while `~/.codex/auth.json` rotated on 2026-07-12;
per-provider single-flight worked, but both serialized calls used the stale
Arbor-owned credential. Prefer an independently acquired Arbor OAuth
session/token family; do not consume or overwrite a CLI-owned rotating
credential as a retry workaround (found 2026-07-18 during council smoke).

When reusing an owned store in place, bind its credential-origin directory and
the most recently retired runtime separately. A successor may keep the original
store while the last runtime uses a newer private root; verify positive retirement
of that last owner without substituting its root for the store origin (2026-10-05
private realtime controls).

<!-- applied-learning: a-copied-oauth-refresh-token-can-be-invalidated-by-its-source-cli -->
<a id="applied-learning-a-copied-oauth-refresh-token-can-be-invalidated-by-its-source-cli"></a>
**A copied OAuth refresh token can be invalidated by its source CLI.** Arbor imports Codex/Grok credentials into `~/.arbor/oauth` and then prefers that copy, but the provider CLI can independently rotate the same single-use refresh-token lineage. The stale Arbor copy then fails with `refresh_token_reused` even while the CLI's newer access token works. Do not delete auth files or reimport another copy of the rotating refresh token to unblock a probe. This entry's original retry guidance was superseded by the exact-one-owner invariant below: source-owned mode may reread only a changed access token, while Arbor-owned mode requires an independently acquired credential family (found 2026-07-12 validating `gpt-5.6-sol`; corrected 2026-07-20 after reproducing cross-owner invalidation).

<!-- applied-learning: sse-json-must-wait-for-reassembled-events-not-finch-chunks -->
<a id="applied-learning-sse-json-must-wait-for-reassembled-events-not-finch-chunks"></a>
**SSE JSON must wait for reassembled events, not Finch chunks.** `complete/2` never
sees chunk boundaries, so a streaming-only `{:invalid_stream_json, {:invalid_json,
:malformed}}` is a line/event split until proven otherwise. Feed the captured byte
sequence at every offset (mid-`data:` prefix, mid-JSON, between `\n` and `\n`)
plus one-byte HTTP frames with no network. `[DONE]` is not JSON — match it after
ASCII whitespace trim or preflight reports a malformed array. OpenCode Zen also
appends a valid cost object after `[DONE]`; ignore it rather than decoding a
fragment (found 2026-08-25 keyless streaming).

<!-- applied-learning: a-streaming-tool-call-can-lose-argument-bytes-before-your-code-sees-it -->
<a id="applied-learning-a-streaming-tool-call-can-lose-argument-bytes-before-your-code-sees-it"></a>
**A streaming tool call can lose argument bytes before your code sees it.** When a provider packs `name` and the opening bytes of `arguments` into the SAME tool-call delta, ReqLLM's OpenAI-compatible decoder runs `Jason.decode/1` on that partial, fails, and falls back to `tool_call(name, %{})` — silently discarding the fragment (`deps/req_llm/.../provider/defaults.ex`). Later deltas carry no `name`, so they accumulate normally, and assembly then sees `query":"onboarding"}` and rejects it as `{:invalid_tool_arguments, {:invalid_json, :malformed}}`. OpenAI proper sends `arguments: ""` there, so the drop is invisible on the reference provider and only bites on others. Two lessons that generalize past this bug: a decoder that validates a STREAM fragment as if it were a COMPLETE value will either reject or discard it — validate at assembly, where the value is actually whole; and "no error was raised" is not evidence of correct assembly, because the drop itself removes the thing that would have failed validation. Assert on the reassembled bytes (found 2026-08-25; the first regression test passed for exactly that wrong reason).

<!-- applied-learning: isolated-acp-runtime-homes-snapshot-provider-credentials-at-worker-creation -->
<a id="applied-learning-isolated-acp-runtime-homes-snapshot-provider-credentials-at-worker-creation"></a>
**Isolated ACP runtime homes snapshot provider credentials at worker creation.** A CLI login or
token refresh performed after a worker starts updates the source credential, not the private copy
already staged for that worker. Compare bounded file timestamps when a later CLI check disagrees
with an earlier provider error, then start a fresh worker or session; do not reinterpret a real
HTTP 403 as a classifier defect, and do not expect relogin to repair an already-open session
(found 2026-08-02 after a Grok coding task failed two minutes before the CLI rewrote its auth
store, while a fresh Grok 4.5 task succeeded).

<!-- applied-learning: provider-usage-displays-do-not-prove-persisted-cli-authentication -->
<a id="applied-learning-provider-usage-displays-do-not-prove-persisted-cli-authentication"></a>
**Provider usage displays do not prove persisted CLI authentication.** Before dispatching an
expensive ACP task after login or quota uncertainty, run the provider's smallest no-tools
authenticated canary against the exact launch-bound model. A healthy-looking usage window may
come from cached or interactive session state even when the persisted CLI credential is stale;
Arbor will faithfully snapshot that stale file, and the provider may classify the resulting
request as an account-limit 403. Treat the canary plus bounded credential generation metadata as
readiness evidence, and never print credential contents (found 2026-08-03 when Grok displayed 0%
usage but an exact `grok-4.5` CLI call reported that it was not signed in and removed stale auth).

<!-- applied-learning: arbor-s-model-budget-foundation-is-built-but-not-yet-one-routing-control-plane -->
<a id="applied-learning-arbor-s-model-budget-foundation-is-built-but-not-yet-one-routing-control-plane"></a>
**Arbor's model-budget foundation is built but not yet one routing control plane.** `Arbor.AI.BudgetTracker`, `QuotaTracker`, and `UsageStats` already persist spend, cooldowns, latency, and outcomes, while mandatory Engine budget middleware expects a separate `check_budget/0` + `record_usage/1` tracker contract. `QuotaTracker.check_and_mark/2` has no production error-path caller, and the AI budget tracker infers subscription use from model names such as `-cli`; an ACP Codex subscription model can therefore be classified like a metered OpenAI API call after provider normalization. Extend and reconcile these components rather than creating a fourth tracker: preserve route/credential-pool provenance through every call, feed quota failures into availability, and make routing consume the unified portfolio state (traced 2026-07-12 after discussing multi-provider budgeting).
