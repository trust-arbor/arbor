# Applied Learning: Council and Review

Read this when implementing independent review, binding findings, validation rework, approval, candidate evidence, or terminal report contracts.

## Retained Applied Learning

<!-- applied-learning: a-bound-composite-action-that-launches-a-nested-dot-graph-needs-authority-propagation-declared-child-bindings-and-exact-child-action-capabilities -->
<a id="applied-learning-a-bound-composite-action-that-launches-a-nested-dot-graph-needs-authority-propagation-declared-child-bindings-and-exact-child-action-capabilities"></a>
**A nested DOT graph needs forwarded parent authority, declared child bindings, and exact child capabilities.** Forward the parent `Arbor.Orchestrator.Engine.RunAuthorization` ephemerally so the child receives a distinct authority and a `parent_binding_digest` equal to the parent binding digest. Declare every child action and capability in the parent closure, and require the executing agent to hold each nested action's canonical URI. `arbor://consensus/decide` does not authorize `arbor://action/consensus/decide_review`. Fail closed on removal, expansion, a missing digest, sibling lineage, or a missing agent URI. Do not clear the active binding or reuse the parent unchanged. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-10.)

<!-- applied-learning: approval-escalation-requires-a-running-interaction-tracker-not-just-loaded-comms-modules -->
<a id="applied-learning-approval-escalation-requires-a-running-interaction-tracker-not-just-loaded-comms-modules"></a>
**Approval escalation requires a running interaction tracker, not just loaded comms modules.** `Arbor.Comms.InteractionRouter` can be callable while `:arbor_comms`, `InteractionRegistry`, `PresenceTracker`, and PubSub are stopped; an `:ask` gate then fails closed with `:tracker_unavailable`, produces no pending IRQ, and looks like a missing capability. Check the application and tracker processes as part of approval-path health, and ensure the server startup/reload path starts the dependency before dispatching approval-bearing work (found 2026-07-10 when a validated coding task reached `git_commit` but could not publish its approval).

<!-- applied-learning: stable-review-finding-ids-cannot-include-candidate-identity-or-mutable-prose -->
<a id="applied-learning-stable-review-finding-ids-cannot-include-candidate-identity-or-mutable-prose"></a>
**Stable review finding IDs cannot include candidate identity or mutable prose.** Rework changes
the commit and diff by design, so IDs derived from either cannot converge across cycles. Derive the
issue key from normalized path/side/line/title plus owner, and treat every field included in that
identity (including title) as immutable. Keep the candidate and evidence in cycle records instead.

<!-- applied-learning: changing-a-reviewed-nested-dot-action-requires-updating-every-action-catalog -->
<a id="applied-learning-changing-a-reviewed-nested-dot-action-requires-updating-every-action-catalog"></a>
**Changing a reviewed nested DOT action requires updating every action catalog.** Registering the
action in `Arbor.Actions` is not enough: compiler fixtures, executable profile manifests, and nested
graph tests can retain the old static module set and fail with `referenced_action_missing` before
semantic analysis. Search action names across production manifests and test catalogs whenever a
reviewed subgraph changes its exec action.

<!-- applied-learning: approval-retries-must-carry-exact-one-shot-authority-never-mint-a-clean-standing-capability -->
<a id="applied-learning-approval-retries-must-carry-exact-one-shot-authority-never-mint-a-clean-standing-capability"></a>
**Approval retries must carry exact one-shot authority.** The owner that awaits a nested `{:ok, :pending_approval, irq}` must retry with an `approved_invocation` bound to that request id, principal, and exact resource URI. Both the capability gate and the trust gate must honor that marker. Do not mint a constraint-free standing capability after approval, and do not convert the interrupt into `validation_failed`. A generic action approval answered `rework` is not this marker. Every hop from the shell context through authorization must forward it. (Merged 2026-10-16 from 2 entries; first found 2026-07-08, last 2026-07-13.)

<!-- applied-learning: approval-completion-does-not-preserve-caller-authority-or-executable-code-identity -->
<a id="applied-learning-approval-completion-does-not-preserve-caller-authority-or-executable-code-identity"></a>
**Approval completion does not preserve caller authority or executable-code identity.** An action can wait minutes between its initial authorization and the approved retry; during that interval the delegator's capability may be revoked or the resolved action module may be reloaded/replaced. Immediately before the one-shot retry, revalidate the caller's exact scoped capability and every pinned module/BEAM binding in addition to checking the approved-invocation marker (found 2026-07-10 reviewing caller-bound DOT action execution).

<!-- applied-learning: reviewed-pipeline-assets-belong-to-the-lowest-library-that-owns-their-business-operation -->
<a id="applied-learning-reviewed-pipeline-assets-belong-to-the-lowest-library-that-owns-their-business-operation"></a>
**Reviewed pipeline assets belong to the lowest library that owns their business operation.** A council-review DOT launched by an `arbor_actions` action cannot live only under `arbor_orchestrator/priv` and be resolved upward with `Application.app_dir(:arbor_orchestrator, ...)`; that creates a hidden L6 -> L7 runtime dependency and breaks standalone/release use. Keep the artifact under the owning lower app, expose it through that app's public facade, and let the higher orchestrator attest and execute the exact facade-provided bytes (found 2026-07-10 while binding the nested coding-review council manifest).

<!-- applied-learning: binding-reviewers-need-scoped-source-evidence-not-ambient-repository-authority -->
<a id="applied-learning-binding-reviewers-need-scoped-source-evidence-not-ambient-repository-authority"></a>
**Binding reviewers need scoped source evidence, not ambient repository authority.** A diff-only council can correctly abstain when a claim depends on surrounding contracts or call sites, but enabling generic tools under the coding agent's principal exposes more authority than the review needs. Give reviewer compute nodes an explicit, bounded read/search tool set scoped to the candidate project and task; preferably read tracked blobs from the exact reviewed commit/tree so live worktree drift, `.git`, and untracked secrets are outside the evidence boundary. Bind those tool actions into the reviewed child manifest, cap output/turns, taint code as untrusted evidence, and expose no write, shell, network, or approval tools (found 2026-07-10 when five council members abstained because a documentation diff's contract claims could not be verified from the diff alone).

<!-- applied-learning: terminal-task-cleanup-must-resolve-approvals-by-exact-task-provenance -->
<a id="applied-learning-terminal-task-cleanup-must-resolve-approvals-by-exact-task-provenance"></a>
**Terminal task cleanup must close approvals by exact task provenance.** On cancel, failure, or timeout, best-effort close pending approvals whose stored `task_id` matches that task and leave every other provenance untouched. `Arbor.Agent.Orchestration.cleanup_approvals_for_task/2` is that path, and it runs for ordinary terminal outcomes, not only explicit cancel. Revoking the delegator's answer capability does not remove a stale approval that is still visible and answerable. Sweeping by agent, principal, or URI can close unrelated work. Audit the cleanup, and treat a skipped cleanup as incomplete rather than as proof every visible approval was closed. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-11.)

<!-- applied-learning: approval-rework-must-remain-distinct-from-denial-across-nested-action-waits -->
<a id="applied-learning-approval-rework-must-remain-distinct-from-denial-across-nested-action-waits"></a>
**Approval `rework` must remain distinct from denial across nested action waits.** The interaction backend may encode rework as a rejected invocation plus `%{decision: :rework, rework: true, note: ...}` metadata, but the owner must retain that metadata and project a nonterminal control outcome. Never retry the rejected invocation as approved; route bounded operator feedback to the same worker session, and require a fresh approval for the next commit attempt. Dropping the metadata turns rework into an ordinary action failure and sends the coding graph to `pipeline_error` (root cause confirmed 2026-07-11 after commit approval `rework` terminated `task_1262403`).

<!-- applied-learning: pinned-action-bindings-should-fail-after-a-live-beam-implementation-reload -->
<a id="applied-learning-pinned-action-bindings-should-fail-after-a-live-beam-implementation-reload"></a>
**Do not Mix-compile into the live node's build during a binding-pinned run.** A mid-run BEAM change must fail closed with `handler_binding_mismatch`, `action_binding_mismatch`, or `execution_module_loaded_code_mismatch`. Run verification in an isolated `MIX_BUILD_PATH`, and reload the live node only between tasks. When handler bindings are pinned, `Arbor.Orchestrator.Engine.RunAuthorization.verify_handler/3` checks the handler module passed at execution. An unpinned run does not, so a registry check made before start is not the execution identity. Bind deferred authorization to that resolved handler. (Merged 2026-10-16 from 3 entries; first found 2026-07-10, last 2026-07-13.)

<!-- applied-learning: approval-waiters-must-subscribe-before-making-a-request-externally-visible -->
<a id="applied-learning-approval-waiters-must-subscribe-before-making-a-request-externally-visible"></a>
**Approval waiters must subscribe before making a request externally visible.** Creating an InteractionRouter IRQ and only then spawning a PubSub subscriber leaves a lost-response window: a fast MCP approver can resolve and remove the request before the waiter exists, so an approved invocation executes zero times and eventually times out. Subscribe before authorization/request publication or retain a durable resolved response retrievable by request ID; never hide the race with `Process.sleep/1` in tests (found 2026-07-11 reviewing commit-approval rework).

<!-- applied-learning: a-rework-loop-must-gate-clean-self-commits-as-well-as-dirty-worktrees -->
<a id="applied-learning-a-rework-loop-must-gate-clean-self-commits-as-well-as-dirty-worktrees"></a>
**A rework loop must gate clean self-commits as well as dirty worktrees.** Routing a post-rework clean worktree directly to `adopt_head_commit` lets the delegated worker self-commit and bypass the promised fresh human commit approval. Bind the gate to the candidate revision/adoption outcome on every rework path, enforce it in graph/action semantics, and regress with a worker that commits during the rework turn (found 2026-07-11 reviewing commit-approval rework).

<!-- applied-learning: git-head-does-not-identify-an-uncommitted-candidate -->
<a id="applied-learning-git-head-does-not-identify-an-uncommitted-candidate"></a>
**Git HEAD does not identify an uncommitted candidate.** Binding approval to `HEAD` alone protects a clean commit/adoption path, but a dirty worktree can change arbitrarily while `HEAD` remains constant. Any approval or attestation over pre-commit content must bind a stable tree/diff fingerprint and reverify it after the wait, or commit first and bind the resulting immutable commit (found 2026-07-11 while reviewing `coding_reviewed_commit`).

<!-- applied-learning: make-multi-agent-rework-monotonic-with-a-frozen-finding-ledger -->
<a id="applied-learning-make-multi-agent-rework-monotonic-with-a-frozen-finding-ledger"></a>
**Make multi-agent rework monotonic with a frozen finding ledger.** Resume the original implementation agent in its existing conversation and worktree so it retains the accepted code and prior reasoning; use fresh reviewers only for independent discovery. For ACP workers, look up the pooled session and durable provider conversation ID first: the pool exists specifically to preserve provider context across follow-up/rework calls, even when the ACP process is reopened. Fall back to worktree + commits + ledger only after that provider session is proven unavailable or expired. After each review, classify findings as fixed, open, new regression, or architectural blocker, freeze the fixed set, and ask the prior reviewer to recheck only the remaining ledger plus regressions introduced by the correction. Design checkpoints follow the same rule: bind accepted API and lifetime decisions in the immutable packet, restate them as locked during each rework, and reject regressions outside the named blocker. Preserve additive commits and exact parent probes instead of restarting the slice. After repeated rounds, extract a genuine architectural mismatch into its own tracked item rather than repeatedly weakening or locally patching the same boundary (adopted 2026-07-12 after Phase 6 review rounds showed high rejection counts despite substantial accepted progress; ACP continuity corrected 2026-07-12; design constraint retention reinforced 2026-08-02 during VP-04).

When a simplification finding conflicts with an admitted design, resolve that
conflict as an explicit owner design amendment before another rework loop.
State which guarantees remain, which change, and the evidence required; never
silently relabel a rejected factory outcome as acceptance. SU-3A (2026-09-08)
otherwise alternated a two-observer cleanup promise with a single-guard request.

Archive only fully completed scope under `5-completed/`. Before closing a roadmap item, give every deferred or nonblocking follow-up its own active item, with an owner, acceptance criteria and a backlink; the archive may link to those items but must not remain their execution backlog. The owner explicitly treats anything in `5-completed/` as complete (clarified 2026-10-06 after voice, library-release and legacy-UI follow-ups were left in a completed adoption item).

<!-- applied-learning: review-pure-authority-cores-at-their-actual-trust-boundary -->
<a id="applied-learning-review-pure-authority-cores-at-their-actual-trust-boundary"></a>
**Review pure authority cores at their actual trust boundary.** A CRC core cannot call `TrustedPath.verify_pinned/1` without ceasing to be pure. It may compare trusted owner-issued startup bindings with untrusted probe evidence, but the imperative owner must create/reverify those bindings and must never expose a caller path that can nominate them; the resulting JSON receipt is evidence, not executable authority. A fabricated struct passed directly to the pure function is not a bypass unless production code lets that caller control the owner binding or consume the receipt as authority (clarified 2026-07-14 after independent review of the Apple control-plane core).

<!-- applied-learning: a-candidate-cannot-validate-a-change-to-the-running-validation-substrate-until-that-substrate-is-reloaded -->
<a id="applied-learning-a-candidate-cannot-validate-a-change-to-the-running-validation-substrate-until-that-substrate-is-reloaded"></a>
**A candidate cannot validate a change to the running validation substrate until that substrate is reloaded.** Coding worktree source does not replace the server modules that construct Apple Container plans. For bootstrap fixes to planner, admission, or executor infrastructure, review and integrate the focused change first, recompile or restart the server, then rerun the delegated validation against the corrected runtime; inspecting the active container's environment and mounts reveals stale substrate immediately (found 2026-07-17 during Phase 6 contained validation).

<!-- applied-learning: contained-validation-must-execute-the-reviewed-host-mix-wrapper-not-a-candidate-controlled-wrapper -->
<a id="applied-learning-contained-validation-must-execute-the-reviewed-host-mix-wrapper-not-a-candidate-controlled-wrapper"></a>
**Contained validation must execute the reviewed host Mix wrapper, not a candidate-controlled wrapper.** Resolve `bin/mix` from loaded trusted code roots, pin its executable identity, and project it read-only into the guest alongside revision-private worktree, build, runner, and result paths. A candidate repository is test input, not authority to replace the validation executable (reinforced 2026-07-18 while admitting `mix run` for two-revision proofs).

<!-- applied-learning: validation-rework-evidence-must-identify-the-exact-failing-test-and-bounded-reason -->
<a id="applied-learning-validation-rework-evidence-must-identify-the-exact-failing-test-and-bounded-reason"></a>
**Validation rework evidence must identify the exact failing test and bounded reason.** Aggregate evidence such as `476 tests, 1 failure` plus stdout hashes made the worker rerun broad host suites and guess at a timeout, while the actual contained failure was a named fixture rejected with `:parent_permissions_unsafe`. Preserve module, test name, source location, assertion/reason, batch label, and full artifact reference in the rework prompt; hashes and truncated excerpts remain provenance, not actionable diagnostics (found 2026-07-18 in `task_16898`).
<!-- applied-learning: reviewer-failure-evidence-must-be-bounded-at-first-projection-and-survive-rework-feedback -->
<a id="applied-learning-reviewer-failure-evidence-must-be-bounded-at-first-projection-and-survive-rework-feedback"></a>
**Reviewer failure evidence must be bounded at first projection and survive rework feedback.** Turning failed, missing, or malformed reviewer branches into abstentions preserves voting semantics but destroys diagnosis unless the reducer emits separate evidence. Sanitize and redact that evidence before the first public Engine projection, then retain it in the council result, persisted verdict, terminal evidence, and bounded feedback sent to the same worker. Apply byte/count caps before UTF-8 scans, regexes, sorting, inspection, or numeric conversion; accept only fixed-size text/scalars for diagnostic reasons rather than inspecting containers or rendering arbitrary-precision integers; and ensure truncation cannot hide a terminator-dependent secret whose quote or credential-URI `@` falls outside the scan window. Sanitizing only at the final action boundary leaves lower-level callers exposed, while persisting without feedback leaves rework blind (found 2026-07-20 reviewing council abstention observability).

<!-- applied-learning: an-aggregate-council-accept-can-still-contain-a-real-major-finding -->
<a id="applied-learning-an-aggregate-council-accept-can-still-contain-a-real-major-finding"></a>
**An aggregate council accept can still contain a real major finding.** Quorum and tier reducers
decide whether the workflow may proceed; they do not erase `active_findings`, and aggregation can
leave a finding nonblocking even when its evidence proves a public-boundary bug. Owner review must
inspect and independently classify the structured findings before adoption instead of trusting the
disposition or vote counts alone (found 2026-08-03 when VP-05D1 was approved 9-0 while Comms still
admitted partial delegation receipts).

<!-- applied-learning: consensus-proposals-must-reference-authoritative-validation-evidence-not-select-execution -->
<a id="applied-learning-consensus-proposals-must-reference-authoritative-validation-evidence-not-select-execution"></a>
**Consensus proposals must reference authoritative validation evidence, not select execution.** Accepting proposal-controlled project paths, environments, commands, test paths, or per-call runners turns deliberation input into execution authority even when the current shell sandbox happens to block it. Derive a closed request from the proposal identity and perspective, resolve it through an operator-configured authorization-bound backend, and reject missing, timed-out, or malformed evidence; keep commands, paths, credentials, and runner selection outside the proposal surface (found 2026-07-23 while repairing the deterministic evaluator after shell hardening).

<!-- applied-learning: forced-tool-choice-is-not-provider-compliance-proof -->
<a id="applied-learning-forced-tool-choice-is-not-provider-compliance-proof"></a>
**Forced tool choice is not provider compliance proof.** Even when a request forces
one reserved terminal tool, a provider may return no call, multiple terminal calls,
non-terminal calls, or a mixed set. Reject every non-singleton terminal shape before
executing anything, classify it separately from free-form text, and emit bounded
diagnostics containing only sanitized tool names, never arguments. Do not retry the
same reserved terminal request through a generic tool loop or fallback that could
execute an unexpected call (found 2026-07-28 when an Ollama council reviewer returned
mixed tool calls despite forced selection).

<!-- applied-learning: claimed-formatting-is-not-review-evidence -->
<a id="applied-learning-claimed-formatting-is-not-review-evidence"></a>
**Claimed formatting is not review evidence.** A worker can report that its
candidate is formatted while the exact preserved tree still fails the formatter.
Run the repository formatter in check mode against the immutable candidate under
the same dependency environment used for validation, and bind that result to the
candidate tree OID before accepting it (found 2026-07-28 while reviewing the
pending-approval reconciliation candidate).

<!-- applied-learning: council-reviewchange-must-preflight-a-bound-review-launch-mode -->
<a id="applied-learning-council-reviewchange-must-preflight-a-bound-review-launch-mode"></a>
**`Council.ReviewChange` must preflight a bound review launch mode.** Calling the
composite action without inherited `run_authorization` or a live lease-bound
`signing_authority` launches an `:unbound` council whose reviewers cannot use the
scoped tree-search or terminal report tools. The models may reason over prompt
material, but report submission fails unauthorized, so the run is not review
evidence. Before launching, require inherited authority or an exact active
task/workspace lease; after lease teardown, recover the immutable commit through a
new authorized review owner rather than invoking the action with an empty context
(found 2026-08-20 while recovering P1C-B1 after its outer coding task failed).

<!-- applied-learning: preflight-the-exact-council-question-and-read-the-full-consultation -->
<a id="applied-learning-preflight-the-exact-council-question-and-read-the-full-consultation"></a>
**Preflight the exact council question and read the full consultation.** A generic
WorkPacket can admit many individually bounded entries whose formatted aggregate
exceeds a stricter council section limit. Readiness or compilation must call the
same pure formatter/limit check used by the council before acquiring a workspace.
After review, treat the persisted consultation results as the authority: bounded
checkpoint notes may clip each concern and can hide the condition that actually
blocks implementation. Vote totals and summaries are navigation aids, not complete
review evidence (found 2026-08-31 when candidate materialization failed before any
seat on a 4,096-byte aggregate overflow, and later council notes clipped the two
crash-attribution findings).

<!-- applied-learning: design-council-veto-seat-error-is-unavailability-not-rework -->
<a id="applied-learning-design-council-veto-seat-error-is-unavailability-not-rework"></a>
**A design-council veto seat classified as error is provider unavailability, not
design rework.** `DesignCouncilCore.decide/1` must return
`{:error, :design_council_veto_unavailable}` rather than
`checkpoint_outcome=rework`, so the coding graph's `outcome=fail` path runs and
does not consume design-rework budget. The same atom applies when a configured
veto seat is omitted or duplicated. Out-of-protocol design-review verdicts
including `:abstain` stay admitted rework and are never reclassified as provider
failure (found 2026-08-31).

<!-- applied-learning: corroborated-council-findings-still-need-independent-factual-verification -->
<a id="applied-learning-corroborated-council-findings-still-need-independent-factual-verification"></a>
**Corroborated council findings still need independent factual verification.** Multiple reviewers can share the same false premise. Before treating a claimed compiler or protocol failure as established, reproduce the smallest case with the pinned toolchain or authoritative implementation. On 2026-09-07, Kimi and GLM both called `case` an illegal Elixir variable, but `Code.eval_string("case = 1\ncase")` returned `{1, [case: 1]}` on Elixir 1.19.5. Keep genuine findings active, send the counterexample to the worker, and distinguish a harmless readability rename from a demonstrated compilation fix.

<!-- applied-learning: design-reviewers-need-every-authoritative-plan-field-they-are-expected-to-validate -->
<a id="applied-learning-design-reviewers-need-every-authoritative-plan-field-they-are-expected-to-validate"></a>
**Design reviewers need every authoritative plan field they are expected to validate.**
Packet-only context cannot detect contradictions in budgets, worker/provider policy,
validation or review profiles, output, or immutable candidate identity. Bind one
compiler-owned bounded canonical plan-review projection plus the full-plan
fingerprint into worker prompts, council input, compilation verification, and
semantic preflight; omit execution authority and redundant large payloads (found
2026-09-02 after a council approved a 5,400,000 ms design against a 28,800,000 ms
frozen plan).

<!-- applied-learning: reviewer-evidence-must-not-truncate-below-admitted-ledger-size -->
<a id="applied-learning-reviewer-evidence-must-not-truncate-below-admitted-ledger-size"></a>
**Reviewer evidence must not truncate below admitted ledger size.** If recheck requires every owned active finding, the prompt must expose every admitted id, including minor/nit findings. J0's valid 42,651-byte ledger became a 32,768-byte escaped preview, causing six incomplete-owner abstentions on 2026-09-07. Match admission and rendering bounds, preserve strict update validation, and project bounded known failure tags without report payloads. Regression coverage should construct a valid ledger through its real core, render both reviewer prompts, and close the next cycle from model-visible evidence; prove the parent fails on truncation, not a newly added helper's missing function.

<!-- applied-learning: separate-end-state-architecture-from-current-delivery-constraints -->
<a id="applied-learning-separate-end-state-architecture-from-current-delivery-constraints"></a>
**Separate end-state architecture from current delivery constraints.** When Hysun
asks for an ideal future system, begin with the owner's desired properties and
fundamental security boundaries. Treat missing software, hardware support,
ecosystem maturity, and earlier delivery decisions as work to evaluate, not
permanent limits. Keep migration sequencing separate from the target design.
Arbor's long-term premise includes an owner-controlled device running the full
stack locally, including AI; a preinstalled phone, laptop, or appliance can make
that ownership accessible. Do not silently reduce that vision to a thin client
or a permanently hosted model (clarified 2026-09-20 after interface/OS
brainstorming was answered as a constrained migration plan).

<!-- applied-learning: trace-the-exact-reviewed-symbol-before-closing-a-finding -->
<a id="applied-learning-trace-the-exact-reviewed-symbol-before-closing-a-finding"></a>
**Trace the exact reviewed symbol before closing a finding.** Repositories can
have parallel APIs for the same concept. Anchor remediation and regression to
the file, module, and public function cited by the review, then search for
sibling implementations. On 2026-10-06, hardening
`Arbor.Common.Pagination.filter_after_cursor/3` left the reviewed fail-open path
in `Arbor.Common.Pagination.Cursor.filter_records/4` unchanged.
