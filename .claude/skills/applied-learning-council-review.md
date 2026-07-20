# Applied Learning: Council and Review

Read this when implementing independent review, binding findings, validation rework, approval, candidate evidence, or terminal report contracts.

## Retained Applied Learning

<!-- applied-learning: nested-action-approvals-must-be-awaited-by-the-owner-action -->
<a id="applied-learning-nested-action-approvals-must-be-awaited-by-the-owner-action"></a>
**Nested action approvals must be awaited by the owner action.** `ActionsExecutor` can wait/retry top-level `{:ok, :pending_approval, irq}` results, but a composite action that calls another action directly must handle that nested approval itself. `coding_produce_reviewable_change` initially converted validation shell approvals into `validation_failed`, leaving stale `irq_*` records the MCP approval tool could answer but not resume. The fix is owner-side wait/retry plus an exact approved-invocation marker, and every hop (`Shell.Execute` context -> `authorize_command` -> `ApprovalGuard`) must forward that marker.

<!-- applied-learning: do-not-update-the-live-node-s-build-path-during-an-execution-binding-pinned-run -->
<a id="applied-learning-do-not-update-the-live-node-s-build-path-during-an-execution-binding-pinned-run"></a>
**Do not update the live node's build path during an execution-binding-pinned run.** A coding manifest can correctly pin the module object currently loaded by the server while a foreground Mix command has already written a newer BEAM to the main checkout's `_build/dev`; a later live reload then changes executable identity mid-run and the Engine correctly rejects the next node with `handler_binding_mismatch`. Run every verification in a worktree with an isolated build path, reconcile or restart the live node before dispatch, and preflight loaded-object versus `:code.which` file identity so stale runtime state fails before the worker starts (found 2026-07-10 while dogfooding the Phase 6 cross-app workflow).

<!-- applied-learning: a-bound-composite-action-that-launches-a-nested-dot-graph-needs-authority-propagation-declared-child-bindings-and-exact-child-action-capabilities -->
<a id="applied-learning-a-bound-composite-action-that-launches-a-nested-dot-graph-needs-authority-propagation-declared-child-bindings-and-exact-child-action-capabilities"></a>
**A bound composite action that launches a nested DOT graph needs authority propagation, declared child bindings, and exact child-action capabilities.** Forward the full parent `RunAuthorization` ephemerally through the action/runtime bridge so `Engine.run/2` derives a distinct child authority, and make the reviewed parent manifest explicitly pin every action/capability/egress binding reachable only inside that child graph. The executing agent must also hold each nested action's canonical URI: `arbor://consensus/decide` does not authorize `arbor://action/consensus/decide_review`. Dropping the parent looks like `:nested_action_binding_removed`; forwarding it without declaring the child action correctly fails the subset check; missing agent authority fails at the nested node and can surface to the parent as `:no_decision_in_result`. Never fix this by clearing the active binding, reusing the parent unchanged, broadening the action subtree, or disabling nested authorization (found 2026-07-10 and confirmed live 2026-07-17 when `council_review_change` completed reviewers but could not execute the nested `consensus_decide_review` node).

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
**Approval retries must carry exact one-shot authority, never mint a clean standing capability.** The owner that awaits an IRQ must retry with an `approved_invocation` marker bound to the request ID, principal, and exact resource URI, and both Security's capability gate and Trust's policy gate must honor that marker. Granting a constraint-free capability after approval silently turns "approve once" into durable authority; omitting the marker makes the retry ask again and leaves a stale IRQ. Reproduced 2026-07-10 through `arbor_dispatch_task -> coding-change-v1.dot -> git_commit`.

<!-- applied-learning: task-cancellation-must-resolve-only-approvals-carrying-that-exact-task-provenance -->
<a id="applied-learning-task-cancellation-must-resolve-only-approvals-carrying-that-exact-task-provenance"></a>
**Task cancellation must resolve only approvals carrying that exact task provenance.** A cancelled owner can otherwise leave an answerable stale IRQ behind, but sweeping by agent, principal, or URI could reject unrelated work. After successful cancellation, best-effort reject or cancel only pending interaction/consensus approvals whose stored `task_id` exactly matches; leave missing or different provenance untouched and audit the cleanup (found 2026-07-10 after cancelling the steering setup task).

<!-- applied-learning: approval-completion-does-not-preserve-caller-authority-or-executable-code-identity -->
<a id="applied-learning-approval-completion-does-not-preserve-caller-authority-or-executable-code-identity"></a>
**Approval completion does not preserve caller authority or executable-code identity.** An action can wait minutes between its initial authorization and the approved retry; during that interval the delegator's capability may be revoked or the resolved action module may be reloaded/replaced. Immediately before the one-shot retry, revalidate the caller's exact scoped capability and every pinned module/BEAM binding in addition to checking the approved-invocation marker (found 2026-07-10 reviewing caller-bound DOT action execution).

<!-- applied-learning: reviewed-pipeline-assets-belong-to-the-lowest-library-that-owns-their-business-operation -->
<a id="applied-learning-reviewed-pipeline-assets-belong-to-the-lowest-library-that-owns-their-business-operation"></a>
**Reviewed pipeline assets belong to the lowest library that owns their business operation.** A council-review DOT launched by an `arbor_actions` action cannot live only under `arbor_orchestrator/priv` and be resolved upward with `Application.app_dir(:arbor_orchestrator, ...)`; that creates a hidden L6 -> L7 runtime dependency and breaks standalone/release use. Keep the artifact under the owning lower app, expose it through that app's public facade, and let the higher orchestrator attest and execute the exact facade-provided bytes (found 2026-07-10 while binding the nested coding-review council manifest).

<!-- applied-learning: nested-action-binding-changes-need-explicit-parent-child-lineage -->
<a id="applied-learning-nested-action-binding-changes-need-explicit-parent-child-lineage"></a>
**Nested action binding changes need explicit parent-child lineage.** An active action binding cannot accept an arbitrary replacement merely because the child action map is a subset. Project the parent's immutable run-authority digest into the action context, require the child's `parent_binding_digest` to match it, require a distinct child binding digest, and compare every child action descriptor exactly against the parent closure. Missing lineage, sibling lineage, expansion, removal, and code drift must all fail closed (found 2026-07-10 while authorizing a bound council action to launch its reviewed child graph).

<!-- applied-learning: binding-reviewers-need-scoped-source-evidence-not-ambient-repository-authority -->
<a id="applied-learning-binding-reviewers-need-scoped-source-evidence-not-ambient-repository-authority"></a>
**Binding reviewers need scoped source evidence, not ambient repository authority.** A diff-only council can correctly abstain when a claim depends on surrounding contracts or call sites, but enabling generic tools under the coding agent's principal exposes more authority than the review needs. Give reviewer compute nodes an explicit, bounded read/search tool set scoped to the candidate project and task; preferably read tracked blobs from the exact reviewed commit/tree so live worktree drift, `.git`, and untracked secrets are outside the evidence boundary. Bind those tool actions into the reviewed child manifest, cap output/turns, taint code as untrusted evidence, and expose no write, shell, network, or approval tools (found 2026-07-10 when five council members abstained because a documentation diff's contract claims could not be verified from the diff alone).

<!-- applied-learning: security-regression-plans-require-explicit-reviewed-test-paths -->
<a id="applied-learning-security-regression-plans-require-explicit-reviewed-test-paths"></a>
**Security-regression plans require explicit reviewed test paths.** The executable `security_regression` profile must receive non-empty `requested_paths` ending in `_test.exs`; an empty selection correctly fails compilation with `{:invalid_security_regression_paths, :empty}` before worker execution. Keep candidate-controlled stdout out of automatic rework prompts and checkpoints; trusted proof uses the formatter artifact, while operator diagnostics need a separate bounded, access-controlled channel (found 2026-07-11 during two-revision dogfood).

<!-- applied-learning: terminal-task-cleanup-must-resolve-approvals-by-exact-task-provenance -->
<a id="applied-learning-terminal-task-cleanup-must-resolve-approvals-by-exact-task-provenance"></a>
**Terminal task cleanup must resolve approvals by exact task provenance.** Ordinary failure or wall-clock timeout can terminate the owner after it created a nested commit/validation IRQ. Revoking the delegator's answer capability is not enough: the stale approval remains visible and answerable even though no owner can resume. Every terminal path, not only explicit cancel, must best-effort close approvals whose stored `task_id` exactly matches and leave unrelated approvals untouched (found 2026-07-11 after `task_1162946` timed out).

<!-- applied-learning: approval-rework-must-remain-distinct-from-denial-across-nested-action-waits -->
<a id="applied-learning-approval-rework-must-remain-distinct-from-denial-across-nested-action-waits"></a>
**Approval `rework` must remain distinct from denial across nested action waits.** The interaction backend may encode rework as a rejected invocation plus `%{decision: :rework, rework: true, note: ...}` metadata, but the owner must retain that metadata and project a nonterminal control outcome. Never retry the rejected invocation as approved; route bounded operator feedback to the same worker session, and require a fresh approval for the next commit attempt. Dropping the metadata turns rework into an ordinary action failure and sends the coding graph to `pipeline_error` (root cause confirmed 2026-07-11 after commit approval `rework` terminated `task_1262403`).

<!-- applied-learning: pinned-action-bindings-should-fail-after-a-live-beam-implementation-reload -->
<a id="applied-learning-pinned-action-bindings-should-fail-after-a-live-beam-implementation-reload"></a>
**Pinned action bindings should fail after a live BEAM implementation reload.** A long-running compiled graph may reach a later action after that action's module has been recompiled and hot-loaded; the current descriptor then differs from the manifest and execution must stop with `action_binding_mismatch`. For live dogfood, compile into an isolated `MIX_BUILD_PATH` and avoid loading bound action modules into the running node mid-task. Once a task has compiled its catalog, wait for it to terminalize before `arbor.recompile`; otherwise expect the later validation action to reject the new beam hash even when the candidate is correct. Recompile or restart before dispatch rather than weakening the binding check (confirmed 2026-07-11 during the shell security-profile replay and 2026-07-18 by two benchmark tasks dispatched before an Actions reload).

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
**Make multi-agent rework monotonic with a frozen finding ledger.** Resume the original implementation agent in its existing conversation and worktree so it retains the accepted code and prior reasoning; use fresh reviewers only for independent discovery. For ACP workers, look up the pooled session and durable provider conversation ID first: the pool exists specifically to preserve provider context across follow-up/rework calls, even when the ACP process is reopened. Fall back to worktree + commits + ledger only after that provider session is proven unavailable or expired. After each review, classify findings as fixed, open, new regression, or architectural blocker, freeze the fixed set, and ask the prior reviewer to recheck only the remaining ledger plus regressions introduced by the correction. Preserve additive commits and exact parent probes instead of restarting the slice. After repeated rounds, extract a genuine architectural mismatch into its own tracked item rather than repeatedly weakening or locally patching the same boundary (adopted 2026-07-12 after Phase 6 review rounds showed high rejection counts despite substantial accepted progress; ACP continuity corrected 2026-07-12).

<!-- applied-learning: containment-tests-that-discover-the-reviewed-mix-wrapper-need-a-worktree-local-build-path -->
<a id="applied-learning-containment-tests-that-discover-the-reviewed-mix-wrapper-need-a-worktree-local-build-path"></a>
**Containment tests that discover the reviewed Mix wrapper need a worktree-local build path.** Sharing `MIX_DEPS_PATH` into an isolated worktree is safe, but pointing `MIX_BUILD_PATH` outside the repo makes the loaded `arbor_actions` BEAM path lead to that external build root, so `Arbor.Actions.Mix.resolve_mix_wrapper/0` correctly cannot prove the repo-owned `bin/mix` identity and fails closed with `:mix_wrapper_unavailable`. For this suite, leave `_build` inside the isolated worktree and share only dependencies; an external build path is still appropriate for tests that do not intentionally derive a source/runtime root from loaded code (found 2026-07-13 while independently validating Spawn Containment Slice 1 R11).

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
