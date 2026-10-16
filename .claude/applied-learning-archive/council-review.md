# Applied Learning archive: council-review

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: security-regression-plans-require-explicit-reviewed-test-paths -->
<a id="applied-learning-security-regression-plans-require-explicit-reviewed-test-paths"></a>
**Security-regression plans require explicit reviewed test paths.** The executable `security_regression` profile must receive non-empty `requested_paths` ending in `_test.exs`; an empty selection correctly fails compilation with `{:invalid_security_regression_paths, :empty}` before worker execution. Keep candidate-controlled stdout out of automatic rework prompts and checkpoints; trusted proof uses the formatter artifact, while operator diagnostics need a separate bounded, access-controlled channel (found 2026-07-11 during two-revision dogfood).

<!-- applied-learning: containment-tests-that-discover-the-reviewed-mix-wrapper-need-a-worktree-local-build-path -->
<a id="applied-learning-containment-tests-that-discover-the-reviewed-mix-wrapper-need-a-worktree-local-build-path"></a>
**Containment tests that discover the reviewed Mix wrapper need a worktree-local build path.** Sharing `MIX_DEPS_PATH` into an isolated worktree is safe, but pointing `MIX_BUILD_PATH` outside the repo makes the loaded `arbor_actions` BEAM path lead to that external build root, so `Arbor.Actions.Mix.resolve_mix_wrapper/0` correctly cannot prove the repo-owned `bin/mix` identity and fails closed with `:mix_wrapper_unavailable`. For this suite, leave `_build` inside the isolated worktree and share only dependencies; an external build path is still appropriate for tests that do not intentionally derive a source/runtime root from loaded code (found 2026-07-13 while independently validating Spawn Containment Slice 1 R11).

<!-- applied-learning: do-not-update-the-live-node-s-build-path-during-an-execution-binding-pinned-run -->
<a id="applied-learning-do-not-update-the-live-node-s-build-path-during-an-execution-binding-pinned-run"></a>
**Do not update the live node's build path during an execution-binding-pinned run.** A coding manifest can correctly pin the module object currently loaded by the server while a foreground Mix command has already written a newer BEAM to the main checkout's `_build/dev`; a later live reload then changes executable identity mid-run and the Engine correctly rejects the next node with `handler_binding_mismatch`. Run every verification in a worktree with an isolated build path, reconcile or restart the live node before dispatch, and preflight loaded-object versus `:code.which` file identity so stale runtime state fails before the worker starts (found 2026-07-10 while dogfooding the Phase 6 cross-app workflow).

Bind any deferred authorization to the actual resolved handler/executor at the
execution boundary, not verification of an assumed default. An unpinned run can
validate its registry before starting and resolve a different registered handler
later. Pass the actual execution argument privately into the admission decision;
reject overrides unless their own full authorization boundary is qualified
(found 2026-10-03 by a source-bound native action regression that installed an
exec handler after Engine preparation).

<!-- applied-learning: task-cancellation-must-resolve-only-approvals-carrying-that-exact-task-provenance -->
<a id="applied-learning-task-cancellation-must-resolve-only-approvals-carrying-that-exact-task-provenance"></a>
**Task cancellation must resolve only approvals carrying that exact task provenance.** A cancelled owner can otherwise leave an answerable stale IRQ behind, but sweeping by agent, principal, or URI could reject unrelated work. After successful cancellation, best-effort reject or cancel only pending interaction/consensus approvals whose stored `task_id` exactly matches; leave missing or different provenance untouched and audit the cleanup (found 2026-07-10 after cancelling the steering setup task).

<!-- applied-learning: nested-action-binding-changes-need-explicit-parent-child-lineage -->
<a id="applied-learning-nested-action-binding-changes-need-explicit-parent-child-lineage"></a>
**Nested action binding changes need explicit parent-child lineage.** An active action binding cannot accept an arbitrary replacement merely because the child action map is a subset. Project the parent's immutable run-authority digest into the action context, require the child's `parent_binding_digest` to match it, require a distinct child binding digest, and compare every child action descriptor exactly against the parent closure. Missing lineage, sibling lineage, expansion, removal, and code drift must all fail closed (found 2026-07-10 while authorizing a bound council action to launch its reviewed child graph).

<!-- applied-learning: nested-action-approvals-must-be-awaited-by-the-owner-action -->
<a id="applied-learning-nested-action-approvals-must-be-awaited-by-the-owner-action"></a>
**Nested action approvals must be awaited by the owner action.** `ActionsExecutor` can wait/retry top-level `{:ok, :pending_approval, irq}` results, but a composite action that calls another action directly must handle that nested approval itself. `coding_produce_reviewable_change` initially converted validation shell approvals into `validation_failed`, leaving stale `irq_*` records the MCP approval tool could answer but not resume. The fix is owner-side wait/retry plus an exact approved-invocation marker, and every hop (`Shell.Execute` context -> `authorize_command` -> `ApprovalGuard`) must forward that marker.
