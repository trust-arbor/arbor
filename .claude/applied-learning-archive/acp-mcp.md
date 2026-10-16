# Applied Learning archive: acp-mcp

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: accepted-queued-steering-needs-an-explicit-terminal-reconciliation-contract -->
<a id="applied-learning-accepted-queued-steering-needs-an-explicit-terminal-reconciliation-contract"></a>
**Accepted queued steering needs an explicit terminal reconciliation contract.** If the worker task succeeds, accepted controls can reconcile to delivered; if the provider or task fails after accepting a control, report delivery unknown or not delivered and never replay the same opaque control ID. Leaving accepted controls permanently queued, or retrying after provider delivery became ambiguous, creates either false status or duplicate instructions (found 2026-07-10 after the live Grok steering task).

<!-- applied-learning: a-terminal-steering-control-must-not-remain-queued -->
<a id="applied-learning-a-terminal-steering-control-must-not-remain-queued"></a>
**A terminal steering control must not remain `queued`.** When an executor accepts a control but the task fails or is cancelled before delivery acknowledgement, the outcome is terminally delivery-unconfirmed, not retryable queue state. Project it under an explicit terminal status and preserve the error/evidence separately; otherwise status counts imply work can still be delivered after the owner has exited (found 2026-07-11 when a queued ACP follow-up ended in `worker_protocol_invalid_json_after_retry`).

<!-- applied-learning: a-terminal-delivery-unconfirmed-steering-status-is-not-proof-that-the-follow-up-was-not-delivered -->
<a id="applied-learning-a-terminal-delivery-unconfirmed-steering-status-is-not-proof-that-the-follow-up-was-not-delivered"></a>
**A terminal `delivery_unconfirmed` steering status is not proof that the follow-up was not delivered.** A same-session Grok follow-up executed, changed the candidate, and committed while its task-control record remained unacknowledged and later reconciled to `delivery_unconfirmed` on task timeout. Inspect the ACP transcript and immutable Git evidence before retrying; the control path must durably acknowledge session acceptance so a later outer failure cannot erase known delivery (found 2026-07-17 steering benchmark-isolation remediation; reconfirmed 2026-07-18 when `task_276738` visibly applied a queued production-seam correction but terminalized with delivery unconfirmed at its graph deadline).

<!-- applied-learning: acp-task-steering-is-a-durable-follow-up-not-mid-command-injection -->
<a id="applied-learning-acp-task-steering-is-a-durable-follow-up-not-mid-command-injection"></a>
**ACP task steering is a durable follow-up, not mid-command injection.** A control sent during an active provider turn remains queued until that turn settles, and a control submitted at a generic validation approval can be deferred because no worker turn currently owns delivery. `queued` or `deferred` does not mean the correction changed the workspace: inspect control status and Git evidence. Deliver corrections before the worker returns to validation; if a known-bad candidate is already gated, deny that exact approval and continue from retained commits in a fresh bounded task rather than approving redundant validation (found 2026-07-18 in `task_16898`).

<!-- applied-learning: acp-steering-preserves-session-continuity-but-cannot-interrupt-an-active-provider-turn -->
<a id="applied-learning-acp-steering-preserves-session-continuity-but-cannot-interrupt-an-active-provider-turn"></a>
**ACP steering preserves session continuity but cannot interrupt an active provider turn.** Same-session follow-ups are queued behind the current ACP prompt; they inherit session context only after that prompt yields. Do not rely on steering to stop a worker looping inside one long turn. Give delegated tasks bounded checkpoints/yield points, and if correction cannot wait, preserve Git WIP, cancel the owner, and restart from the last trusted commit with the correction in the initial prompt (confirmed 2026-07-20 when three controls remained queued for more than an hour behind `task_239299`).

<!-- applied-learning: consolidate-candidate-findings-before-spending-the-commit-rework-budget -->
<a id="applied-learning-consolidate-candidate-findings-before-spending-the-commit-rework-budget"></a>
**Consolidate candidate findings before spending the commit-rework budget.** The
operator commit gate can admit fewer rework turns than the plan's total rework
setting suggests; after one accepted commit rework, a second request may
terminalize as `rework_exhausted` before the worker receives its note. Inspect the
whole frozen candidate, including cleanup and test infrastructure, and run the
smallest decisive checks before sending one compact correction ledger. If a later
issue still surfaces, preserve the retained workspace and finish the narrow repair
locally or redispatch from an exact checkpoint instead of discarding good work
(found 2026-08-03 while integrating VP-05A after a second commit correction hit
the category budget).

<!-- applied-learning: the-coding-plan-data-contract-is-broader-than-the-executable-v1-feature-set -->
<a id="applied-learning-the-coding-plan-data-contract-is-broader-than-the-executable-v1-feature-set"></a>
**The Coding Plan data contract is broader than the executable v1 feature set.** `Arbor.Contracts.Coding.Plan.new/1` can normalize optional policy fields that the current compiler intentionally rejects as `{:unsupported_v1_feature, field}`. Before dispatching live work, use only the executable profile subset (or run a compile probe); in particular, leave `rework.stop_conditions` empty until the compiler implements it. A preflight rejection before workspace acquisition is safe to correct and redispatch (found 2026-07-11 when terminal-approval cleanup was rejected before worker startup).

<!-- applied-learning: a-field-accepted-by-the-coding-plan-contract-may-still-be-unsupported-by-the-v1-compiler -->
<a id="applied-learning-a-field-accepted-by-the-coding-plan-contract-may-still-be-unsupported-by-the-v1-compiler"></a>
**A field accepted by the coding Plan contract may still be unsupported by the v1 compiler.** Non-empty `rework.stop_conditions` and non-nil `budgets.model_cost_usd` normalize successfully but dispatch fails before workspace acquisition with `{:unsupported_v1_feature, field}`; `budgets.parallelism` is executable only at `1`. For executable v1 dispatches, check `CodingPlan.Compiler.validate_supported_v1/1`, omit unsupported fields, and use the reviewed profile plus bounded `max_cycles`, `wall_clock_ms`, and `inactivity_timeout_ms` instead (found 2026-07-11 redispatching Phase 6 corrections).

<!-- applied-learning: codingplan-schema-acceptance-does-not-imply-the-executable-v1-profile-supports-a-field -->
<a id="applied-learning-codingplan-schema-acceptance-does-not-imply-the-executable-v1-profile-supports-a-field"></a>
**CodingPlan schema acceptance does not imply the executable v1 profile supports a field.** The v1 contract can normalize non-empty `overlays` and `rework.stop_conditions`, while the current compiler rejects both as `{:unsupported_v1_feature, field}` before workspace allocation. Check `Compiler.validate_supported_features/1` and profile-specific preflight before adding optional plan fields to an MCP dispatch; omit unsupported fields or use their supported empty/default value. The executable `security_regression` profile also requires a non-empty `requested_paths` list containing only `*_test.exs` paths (found 2026-07-15 dispatching Engine lifecycle L3B).

<!-- applied-learning: long-running-mcp-actions-and-canaries-need-asynchronous-owner-processes -->
<a id="applied-learning-long-running-mcp-actions-and-canaries-need-asynchronous-owner-processes"></a>
**Long-running MCP actions and canaries need asynchronous owner processes.** Calling `coding_produce_reviewable_change` directly through synchronous `arbor_run` can outlive the HTTP request/session teardown: a Grok ACP session started normally, then the gateway timed out stopping the request-scoped MCP session after about 11 seconds and killed the ACP client with an HTTP 500. A synchronous gateway canary can likewise lose its owner on request timeout. Start persisted coding work, or an unlinked async canary task, and publish explicit durable status before polling; do not leave a long canary owned only by the request (reproduced 2026-07-09 and 2026-07-19).

<!-- applied-learning: do-not-run-long-owner-bound-coding-work-through-standalone-arbor-run -->
<a id="applied-learning-do-not-run-long-owner-bound-coding-work-through-standalone-arbor-run"></a>
**Do not run long owner-bound coding work through standalone `arbor_run`.** The standalone MCP HTTP request process becomes the composite action/ACP owner; if the Gateway request times out, owner death tears down the managed session and the client sees an empty HTTP 500 even though the worker briefly started. Dispatch the reviewed `coding_change` plan with `arbor_dispatch_task`, then use task status/result/steering so ownership outlives one HTTP request (found 2026-07-16 dispatching retained-workspace safety remediation).

<!-- applied-learning: durable-coding-delegation-goes-through-structured-task-dispatch-not-standalone-arbor-run -->
<a id="applied-learning-durable-coding-delegation-goes-through-structured-task-dispatch-not-standalone-arbor-run"></a>
**Durable coding delegation goes through structured task dispatch, not standalone `arbor_run`.** A long `coding_produce_reviewable_change` call outlives the short-lived MCP HTTP handler that owns its ACP session; handler teardown can kill the worker and return an empty HTTP 500. Resume a coding agent and use `arbor_dispatch_task` with the versioned `coding_change` plan, then drive status, steering, approvals, and result through stable task IDs (found 2026-07-17 while validating the repaired contained toolchain).

<!-- applied-learning: security-regression-coding-plan-requested-paths-are-test-selectors-not-source-scopes -->
<a id="applied-learning-security-regression-coding-plan-requested-paths-are-test-selectors-not-source-scopes"></a>
**`security_regression` coding-plan `requested_paths` are test selectors, not source scopes.** The compiler requires a non-empty list where every path ends in `_test.exs`; passing app directories or implementation files fails before workspace acquisition with `{:invalid_security_regression_paths, ...}`. Put the exact public behavioral regression test paths there and describe implementation ownership in the task prompt instead (found 2026-07-11 while dispatching the signing-authority spine correction).

<!-- applied-learning: worker-close-success-is-not-quiescence-until-cleanup-settles -->
<a id="applied-learning-worker-close-success-is-not-quiescence-until-cleanup-settles"></a>
**Worker-close success is not quiescence until cleanup settles.** A pooled ACP
check-in can return successfully while provider-specific state remains able to
write, and an idempotent replay may report `closing` while asynchronous cleanup is
still active. Before an irreversible next effect such as immutable candidate
materialization, force a non-pooled close and advance only on a positively settled
`closed` or `already_closed` result; all intermediate or unknown states fail closed
(found 2026-09-02 while reviewing the G5D descriptor route).

<!-- applied-learning: structured-coding-dispatch-requires-the-task-kind-envelope -->
<a id="applied-learning-structured-coding-dispatch-requires-the-task-kind-envelope"></a>
**Structured coding dispatch requires the task-kind envelope.** Send executable CodingPlan data through `arbor_dispatch_task` as `%{"kind" => "coding_change", "plan" => plan}`. A bare plan map is not selected by TaskStore's coding executor and instead falls through to the ordinary agent-session path, where unrelated turn-graph errors can obscure the malformed dispatch (found 2026-07-11 while retrying security-regression dogfood).

<!-- applied-learning: do-not-wrap-an-internal-action-invocation-inside-arbor-dispatch-task -->
<a id="applied-learning-do-not-wrap-an-internal-action-invocation-inside-arbor-dispatch-task"></a>
**Do not wrap an internal action invocation inside `arbor_dispatch_task`.** The MCP task boundary routes only a plain prompt or a supported task kind. A payload such as `{"action":"coding_produce_reviewable_change","params":{...}}` has no `kind`, falls through to the default chat runner, and fails with `:missing_task_input`; `coding_produce_reviewable_change` is now an internal compiled-pipeline action rather than the MCP dispatch envelope. Send the canonical `{"kind":"coding_change","plan":{...}}` shape, or the strict legacy-compatible flat `coding_change` fields while that adapter remains supported (found 2026-07-14 after two immediate false-start dispatches following a reconnect).

<!-- applied-learning: a-clean-coding-worktree-does-not-prove-the-worker-made-no-change -->
<a id="applied-learning-a-clean-coding-worktree-does-not-prove-the-worker-made-no-change"></a>
**A clean coding worktree does not prove the worker made no change.** ACP workers can create a commit even when asked only to edit; `git status --porcelain` is then empty while `HEAD` has advanced. `coding_produce_reviewable_change` currently misclassifies that case as `no_changes` (observed 2026-07-09 on the Grok parity-fixture delegation). Capture the acquired base commit and treat either a dirty tree or `HEAD != base_commit` as a change. Prompt the worker not to commit so the wrapper owns the review commit, but enforce correct detection in code rather than trusting that instruction.

<!-- applied-learning: a-failed-outer-coding-task-may-still-have-produced-a-committed-branch -->
<a id="applied-learning-a-failed-outer-coding-task-may-still-have-produced-a-committed-branch"></a>
**A failed outer coding task may still have produced a committed branch.** Pipeline timeout, worker protocol repair failure, or terminal-result transport can occur after the worker committed. Before redispatching or declaring work lost, inspect the requested branch and retained worktree for an immutable commit; review that snapshot independently of the outer task status (found 2026-07-11 recovering cross-app and benchmark corrections).

<!-- applied-learning: arbor-dispatch-task-timeout-bounds-the-whole-asynchronous-task-not-the-mcp-request -->
<a id="applied-learning-arbor-dispatch-task-timeout-bounds-the-whole-asynchronous-task-not-the-mcp-request"></a>
**`arbor_dispatch_task.timeout` bounds the whole asynchronous task, not the MCP request.** A
structured coding plan already carries its worker budget in `plan.budgets.wall_clock_ms` and
`inactivity_timeout_ms`. Omit the outer dispatch timeout for coding work unless a deliberately
shorter task-wide cancellation is intended; setting it to 120 seconds terminated Grok during its
first implementation turn and cleanup removed the uncommitted worktree (found 2026-07-14 in
`task_74626`).

<!-- applied-learning: arbor-dispatch-task-timeout-is-the-asynchronous-task-deadline-not-an-mcp-call-timeout -->
<a id="applied-learning-arbor-dispatch-task-timeout-is-the-asynchronous-task-deadline-not-an-mcp-call-timeout"></a>
**`arbor_dispatch_task.timeout` is the asynchronous task deadline, not an MCP-call timeout.** Supplying `timeout: 60_000` on a coding dispatch terminalized the graph during `implement` after exactly one minute even though `plan.budgets.wall_clock_ms` allowed 90 minutes. For coding plans, omit the outer timeout unless it is intentionally tighter than the reviewed plan budget; use the plan's wall-clock and inactivity budgets for workflow liveness (found 2026-07-18 in `task_233474`).

<!-- applied-learning: acp-steering-contracts-must-match-the-semantic-worker-phase -->
<a id="applied-learning-acp-steering-contracts-must-match-the-semantic-worker-phase"></a>
**ACP steering contracts must match the semantic worker phase.** Arbor's current
managed coding-task control is an implementation follow-up: it tells the worker to
apply a correction in the worktree and return the advisory implementation envelope.
Do not use that control to repair a design-checkpoint envelope, even when TaskStore's
generic current step is named `implement`; queued controls run before the active
`acp_send_message` call returns and can replace the response the design parser sees.
Make controls phase-aware before steering design or review turns (found 2026-07-28
while attempting to accelerate the Phase E design-digest repair).

<!-- applied-learning: stage-targeted-controls-require-owner-enforced-delivery-eligibility -->
<a id="applied-learning-stage-targeted-controls-require-owner-enforced-delivery-eligibility"></a>
**Stage-targeted controls require owner-enforced delivery eligibility.** Persisting
`target_stage` or including it in a follow-up prompt does not delay delivery. The
task owner must compare the target with the graph's bounded semantic worker phase
before submitting the control to the ACP session, then retain the same control ID
and immutable payload in FIFO order until eligible. In particular, never let an
implementation control become the next same-session prompt while a mandatory
read-only design turn is still settling; the worker can correctly edit and still
trip `design_turn_modified_workspace`. Until the barrier is deployed, wait for the
explicit design checkpoint before steering implementation (found 2026-08-30 after
the same race recurred during CrossApp G3C2 task
`task_6d868b681794b63c997dafafd71ed1d5`).

<!-- applied-learning: versioned-coding-plans-do-not-inherit-legacy-flat-field-aliases -->
<a id="applied-learning-versioned-coding-plans-do-not-inherit-legacy-flat-field-aliases"></a>
**Versioned coding plans do not inherit legacy flat-field aliases.** Every direct Plan object is closed: `branch_name` at the plan top level fails with `{:unknown_fields, ["branch_name"]}` even though the legacy flat `coding_change` envelope accepts it. Put it under `workspace_policy.branch_name`, or omit it and let Arbor generate the branch (found 2026-07-17 dispatching benchmark-isolation remediation).

<!-- applied-learning: coding-plan-contract-admission-does-not-prove-template-support -->
<a id="applied-learning-coding-plan-contract-admission-does-not-prove-template-support"></a>
**Coding-plan contract admission does not prove template support.** Before
dispatching a reviewed plan with an optional feature, compile that exact normalized
plan or verify the active template advertises the feature. Plan v2 currently accepts
nonempty `rework.stop_conditions`, while `coding-change-v1` rejects it as
`{:unsupported_v1_feature, "rework.stop_conditions"}`. Contract success alone would
spend a failed preflight attempt; omit unsupported optional fields without changing
the bound work packet (found 2026-07-28 dispatching the Phase E route-input slice).

<!-- applied-learning: outer-task-liveness-does-not-imply-the-acp-worker-session-is-steerable -->
<a id="applied-learning-outer-task-liveness-does-not-imply-the-acp-worker-session-is-steerable"></a>
**Outer task liveness does not imply the ACP worker session is steerable.** Once the implementation node closes its managed ACP session, the task can still be waiting on commit approval while `steer_task` correctly reports `task_terminal` for the worker stage. Deliver steering while the worker session is alive; after it closes, retain or commit an exact checkpoint and start a new delegated revision rather than assuming approval-wait state preserves the ACP handle (found 2026-07-11 trying to steer validator corrections at commit approval).

<!-- applied-learning: audit-every-runtime-dispatch-branch-when-adding-a-resource-bound -->
<a id="applied-learning-audit-every-runtime-dispatch-branch-when-adding-a-resource-bound"></a>
**Audit every runtime dispatch branch when adding a resource bound.** A timeout or output ceiling on the primary executor does not cover an alternate backend selected by syntax, feature flag, agent context, or authorization mode. Trace the public operation through every dispatch branch and either enforce identical bounds there or disable the unbounded branch by default; an action-schema option alone can otherwise advertise protection that the live path ignores (found 2026-07-11 when compound shell commands bypassed `Arbor.Shell.Executor` through `CapShell`).

<!-- applied-learning: do-not-reuse-a-delegated-worktree-build-across-compile-time-adapter-modes -->
<a id="applied-learning-do-not-reuse-a-delegated-worktree-build-across-compile-time-adapter-modes"></a>
**Do not reuse a delegated worktree build across compile-time adapter modes.**
`ARBOR_DB=postgres` compiles `:arbor_persistence, :repo_adapter` differently
from the default SQLite test mode, and Mix will reject a later run whose runtime
adapter no longer matches that retained build. Use a fresh named
`MIX_BUILD_PATH` for each adapter mode (or explicitly keep `ARBOR_DB` identical)
instead of treating a worker's `_build_*` directory as mode-agnostic (found
2026-07-13 rerunning the lifecycle suite after Grok's Postgres validation).

<!-- applied-learning: standalone-mcp-action-calls-cannot-carry-a-process-owned-coding-workspace-lease-across-requests -->
<a id="applied-learning-standalone-mcp-action-calls-cannot-carry-a-process-owned-coding-workspace-lease-across-requests"></a>
**Standalone MCP action calls cannot carry a process-owned coding workspace lease across requests.** `coding_workspace_acquire` can return an active lease, but a later standalone `arbor_run` executes under a different request owner and `coding_workspace_inspect`, `coding_workspace_committed_change`, or council snapshot binding can return `:not_found`. Run acquisition, committed-change capture, and binding review inside one structured `coding_change` task/compiled pipeline; use ordinary Git inspection for a retained failed worktree rather than trying to reconstruct task ownership through separate MCP calls (found 2026-07-15 attempting an independent binding review of Engine lifecycle L3A).

<!-- applied-learning: budget-agent-work-by-model-provider-but-distinguish-native-subagents-from-acp-workers -->
<a id="applied-learning-budget-agent-work-by-model-provider-but-distinguish-native-subagents-from-acp-workers"></a>
**Budget agent work by model/provider, but distinguish native subagents from ACP workers.** Keep the coordinating parent on architecture, delegation, integration, and final judgment; send substantial implementation to resumable ACP workers such as Grok or GPT-5.3-Codex-Spark; use a faster/cheaper native Codex subagent only for bounded mechanical work; reserve stronger agents for security review and cross-library design. Inspect `spawn_agent`'s advertised model overrides before choosing a native subagent, and inspect Arbor's ACP provider registry separately: absence from `spawn_agent` does not imply a subscription-backed model is unavailable through ACP. Limit active concurrency, close completed native agents immediately, reuse author/reviewer threads and provider session IDs with frozen ledgers, and avoid `fork_context: true` unless the worker genuinely needs the full history (adopted 2026-07-12 after repeated parent-model capacity stalls; ACP Spark lane clarified 2026-07-12).

<!-- applied-learning: a-durable-acp-provider-session-may-still-be-bound-to-its-original-workspace -->
<a id="applied-learning-a-durable-acp-provider-session-may-still-be-bound-to-its-original-workspace"></a>
**A durable ACP provider session may still be bound to its original workspace.** Reopening a valid Grok provider session from a newly allocated worktree returned `FS_NOT_FOUND` even though the provider conversation ID and both worktrees still existed. Do not equate "new worktree + resume_session_id" with continuity. Reactivate the retained original workspace for follow-up work, or use a provider protocol that explicitly supports rebinding the session cwd; otherwise classify the attempt as resume-unavailable and preserve the candidate commit before falling back to a fresh session (found 2026-07-13 when `task_37699` tried to resume the `task_35331` worker on a review-rework worktree).
The structured coding dispatcher currently allocates a new workspace for each new slice, so omit
Grok resume fields there unless that path has first gained explicit retained-workspace reactivation;
reserve provider-session resume for a rework path that can reopen the original workspace (reconfirmed
2026-07-14 by `task_74242` failing at `acp_start_session` before implementation).

<!-- applied-learning: treat-worker-resume-provider-as-a-provider-selector-not-a-boolean -->
<a id="applied-learning-treat-worker-resume-provider-as-a-provider-selector-not-a-boolean"></a>
**Treat `worker.resume_provider` as a provider selector, not a boolean.** In a structured coding plan it is an optional nonblank provider/session string; omit it for a fresh worker. Passing `true` fails schema validation before workspace allocation. Also use `review_profile: "binding"` for executable delegated review: although the interchange contract can describe `"none"`, the current compiler rejects that profile before execution (confirmed 2026-07-14 dispatching the Apple local-alias slices).

<!-- applied-learning: coding-worker-output-is-evidence-not-control-authority -->
<a id="applied-learning-coding-worker-output-is-evidence-not-control-authority"></a>
**Coding worker output is evidence, not control authority.** After a successful ACP turn, the coding pipeline must capture the provider session id for continuity and inspect the owned workspace to decide `no_changes` versus validation/review/commit. Never parse or route on a model-reported `implemented`/`declined` status in the current graph; malformed output must not discard real edits or consume a repair budget. Prompts may still require one JSON-only response for compatibility with resumed archived graphs whose old parser is immutable. Retain `protocol_retry_count=0` only as a public compatibility metric while older records age out (fixed 2026-07-15 after repeated Grok terminal-response failures hid completed commits).

<!-- applied-learning: let-coding-dispatch-choose-its-configured-worktree-root-unless-an-override-is-already-known-to-be-admitted -->
<a id="applied-learning-let-coding-dispatch-choose-its-configured-worktree-root-unless-an-override-is-already-known-to-be-admitted"></a>
**Let coding dispatch choose its configured worktree root unless an override is already known to be admitted.** `worktree_base_dir` is a security-sensitive coding path and must fall within the runtime's configured workspace roots; an otherwise valid task can fail preflight with `{:invalid_coding_path, :worktree_base_dir}` before allocating a worker. Omit the override to use the reviewed default rather than guessing that a convenient host temp directory is allowed (found 2026-07-15 dispatching retained-workspace remediation).

<!-- applied-learning: prefer-provider-canonical-terminal-text-over-replayed-acp-stream-chunks -->
<a id="applied-learning-prefer-provider-canonical-terminal-text-over-replayed-acp-stream-chunks"></a>
**Prefer provider-canonical terminal text over replayed ACP stream chunks.**
An adapter may emit incremental text deltas and then emit the complete assistant
message again before its terminal result. When that result carries a validated
provider-namespaced canonical text field, use it instead of concatenating the
generic chunk accumulator; do not guess by splitting repeated halves. Regress
the exact delta-plus-full-message sequence because ordinary streaming tests will
not expose the duplication (found 2026-07-29 when Claude SDK responses doubled
every coding design envelope).

<!-- applied-learning: approval-and-rework-notes-are-bounded-control-plane-messages -->
<a id="applied-learning-approval-and-rework-notes-are-bounded-control-plane-messages"></a>
**Approval and rework notes are bounded control-plane messages.** Put only the
decision and a compact, actionable correction ledger in an approval answer;
reference task, request, or artifact identities for longer evidence instead of
embedding the full review. Regress both an over-limit rejection and an accepted
bounded note so feedback cannot disappear before the delegated worker sees it
(found 2026-07-28 when the first detailed Grok rework note was rejected because
the approval note exceeded its maximum size).

<!-- applied-learning: private-per-dispatch-options-must-not-select-executable-cleanup-code -->
<a id="applied-learning-private-per-dispatch-options-must-not-select-executable-cleanup-code"></a>
**Private per-dispatch options must not select executable cleanup code.** A caller that can reach a low-level task store directly can supply an arbitrary MFA even when the facade normally constructs that option. Fix stable lifecycle code at the store's trusted initialization boundary (with an explicit test-only seam if needed), and let per-task descriptors carry data only. Launch deferred work with module/function/args APIs rather than storing or spawning anonymous closures (found 2026-07-11 when council review rejected the first terminal-approval cleanup implementation).

<!-- applied-learning: treat-provider-account-exhaustion-errors-as-deterministic-routing-failures-not-transport-retries -->
<a id="applied-learning-treat-provider-account-exhaustion-errors-as-deterministic-routing-failures-not-transport-retries"></a>
**Treat provider account-exhaustion errors as deterministic routing failures, not transport retries.** An ACP send that returns provider-authenticated HTTP `402`/`403` with explicit team-credit or spending-limit exhaustion will fail again against a replacement session; consuming uncertain-send recovery only delays terminalization and obscures the budget signal. Classify only the exact structured provider evidence, expose it through an opt-in delivery receipt, preserve the default error contract for other callers, and route to another allowed provider or a budget wait state without replaying the logical turn. Generic permission failures and malformed or unrecognized errors must retain uncertain-send handling (found 2026-07-21 when Grok 4.5 `task_323715` exhausted both initial and recovery sends against the same xAI team limit).

<!-- applied-learning: aggregate-payload-bounds-must-compose-from-admitted-component-bounds -->
<a id="applied-learning-aggregate-payload-bounds-must-compose-from-admitted-component-bounds"></a>
**Aggregate payload contracts must reconcile component and envelope bounds.**
If a component accepts a 16 KB design and 256 KB work packet, a later
interaction must not silently assume that every combination fits an unrelated
16 KB description or 32 KB metadata cap. Either derive an envelope that admits
the component maxima, reject incompatible combinations explicitly at the
earliest real public boundary, or store full evidence separately and carry a
bounded digest/reference. Keep operator prose short, retain exact evidence in
the authoritative channel, and pass representative plus maximum admitted
values through the real public operation. Never report caller-invalid payloads
as backend unavailability. Per-field tests alone miss the downstream
contradiction (found 2026-07-28 when a valid 14,324-byte Grok design parsed
successfully but design-checkpoint Open rejected its packet-composed
description as too large).

<!-- applied-learning: stable-structured-coding-plans-require-a-review-bearing-profile-and-only-their-executable-feature-subset -->
<a id="applied-learning-stable-structured-coding-plans-require-a-review-bearing-profile-and-only-their-executable-feature-subset"></a>
**Stable structured coding plans require a review-bearing profile and only their executable feature subset.** The compiled `coding_change` path rejects `review_profile: "none"` before workspace allocation. Use `human_required` when the local delegator will perform the binding review, or `binding` when the configured council should decide; do not use a no-review profile merely to save reviewer tokens. Also, contract-valid optional fields are not necessarily executable in v1: custom `rework.stop_conditions` currently fails preflight with `unsupported_v1_feature`, so omit it and use the compiled profile defaults until that feature is implemented (confirmed 2026-07-13 dispatching the eval DOT last-mile slice).

<!-- applied-learning: steer-pre-validation-corrections-generic-action-rework-is-a-rejected-syscall -->
<a id="applied-learning-steer-pre-validation-corrections-generic-action-rework-is-a-rejected-syscall"></a>
**Steer pre-validation corrections; generic action `rework` is a rejected syscall.** `ActionsExecutor` intentionally returns an error when an operator answers a generic action approval with `rework`; only dedicated control actions such as `coding_reviewed_commit` project rework as a branchable success payload. At a validation approval, deliver review feedback with task steering while the managed ACP session is still alive, inspect the resulting workspace, and then approve or deny the exact action request. Answering that request with `rework` terminalizes through the action's `outcome=fail` edge and does not enter the coding graph's validation/operator rework loops (confirmed 2026-07-18 by `task_102210`).

<!-- applied-learning: bind-security-regression-paths-in-the-reviewed-plan -->
<a id="applied-learning-bind-security-regression-paths-in-the-reviewed-plan"></a>
**Bind security-regression paths in the reviewed plan.** A
`task_class: "security_regression"` dispatch must include the exact committed
regression test paths in `requested_paths`; naming them only in
`required_evidence` does not satisfy compiler admission. Preflight the plan
locally when possible so a missing path binding fails before workspace
acquisition (found 2026-07-30 while redispatching the OAuth model-catalog
transport).

<!-- applied-learning: adopt-provider-refined-session-identities-before-continuity -->
<a id="applied-learning-adopt-provider-refined-session-identities-before-continuity"></a>
**Adopt provider-refined session identities before continuity consumers.** Some
ACP adapters return a transient local handle from `session/new` and reveal the
durable provider identity only in the first prompt result; Claude uses
`claude_sdk_*` before emitting its resumable UUID in namespaced metadata.
Validate that provider-specific transition and atomically replace both
`session_id` and `last_session_id` before status, recovery, or the next prompt.
Reject malformed identities and later drift, leave other providers untouched,
and make fake clients model the transient-to-durable transition rather than a
single static ID (found 2026-07-28 after recovery tried to resume
`claude_sdk_179` instead of Claude's persisted UUID).

<!-- applied-learning: acp-recovery-needs-reserved-budget-not-a-provider-switch -->
<a id="applied-learning-acp-recovery-needs-reserved-budget-not-a-provider-switch"></a>
**ACP recovery needs reserved budget, not a provider switch.** A worker can
consume the coding stage's remaining wall-clock budget before reopen or
follow-up delivery, producing `worker_recovery_reopen_failed` or
`worker_recovery_send_failed` with `:budget_exhausted`. The same failure on Grok
and Claude proves this is orchestration accounting, not provider behavior.
The send boundary can also time out after a useful provider turn with no manual
steering, so a terminal-delivery failure is not evidence that the candidate is
bad. Preserve the exact terminal worktree or immutable snapshot, inspect it,
avoid blind cross-provider retries, and reserve enough stage budget for one
complete recovery turn plus settlement. If managed delivery itself remains the
failure, use the provider's direct CLI against an isolated worktree rather than
rerunning the implementation from scratch (found 2026-07-28 while completing
the managed ACP reconciliation read model; extended 2026-08-21 after Cursor
returned useful code before `worker_recovery_send_failed: :timeout`).

<!-- applied-learning: acp-terminal-commands-run-under-zsh-unless-the-provider-explicitly-selects-another-shell -->
<a id="applied-learning-acp-terminal-commands-run-under-zsh-unless-the-provider-explicitly-selects-another-shell"></a>
**ACP terminal commands run under zsh unless the provider explicitly selects another shell.** Bash-only helpers such as `mapfile` fail, and a subsequently expanded empty file array can accidentally turn a bounded test batch into the full suite. Use zsh-native line arrays such as `${(@f)$(<file)}`, a portable `while read` loop, or pass exact argv without shell reconstruction; print and verify the resulting count before launching expensive tests (found 2026-07-18 while diagnosing `task_16898`).

<!-- applied-learning: custom-coding-validation-commands-must-not-assume-ignored-repo-tooling-exists-in-a-git-worktree -->
<a id="applied-learning-custom-coding-validation-commands-must-not-assume-ignored-repo-tooling-exists-in-a-git-worktree"></a>
**Custom coding validation commands must not assume ignored repo tooling exists in a git worktree.** `coding_produce_reviewable_change` routes recognized `mix compile` and bare `mix quality` commands through schema-bounded Mix actions, but `./bin/mix test ...` currently falls back to raw `Shell.Execute`. After approval, that command runs with the generated worktree as `cwd`; because `bin/mix` is not present there, validation fails with `{:executable_not_found, "./bin/mix"}` and no commit is produced. Route test commands through `Mix.Test` with shared host deps/build paths, or resolve the tracked checkout's wrapper explicitly before using shell fallback (reproduced 2026-07-09 with Grok ACP).
