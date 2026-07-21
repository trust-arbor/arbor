# Applied Learning: ACP/MCP and Delegation

Read this when dispatching, steering, approving, resuming, or reviewing delegated ACP/MCP work. Entries retain the behavioral rule and the incident that motivated it.

## Retained Applied Learning

<!-- applied-learning: never-mutate-a-delegated-worktree-after-owner-inspection-has-pinned-its-validation-fingerprint -->
<a id="applied-learning-never-mutate-a-delegated-worktree-after-owner-inspection-has-pinned-its-validation-fingerprint"></a>
**Never mutate a delegated worktree after owner inspection has pinned its
validation fingerprint.** Put temporary build output outside the worktree from
the outset or remove it before the worker turn ends; mid-validation cleanup
correctly produces `:validation_tree_mutated` (found 2026-07-18 during council
smoke after terminal-submission hardening).

<!-- applied-learning: native-acp-session-access-and-native-tool-authority-are-separate-gates -->
<a id="applied-learning-native-acp-session-access-and-native-tool-authority-are-separate-gates"></a>
**Native ACP session access and native tool authority are separate gates.** The
handler authorizes callbacks at `arbor://acp/tool/<canonical-name-or-kind>`, so an
exact `arbor://acp/tool` capability does not cover them under segment-aware
capability semantics. Grant exact child URIs or the bounded `arbor://acp/tool/**`
subtree, and derive the child only from machine-readable protocol identity fields;
human-readable titles may contain entire commands (found 2026-07-17 when Grok's
structured `kind=execute` callback was misidentified by its descriptive title).

<!-- applied-learning: a-coding-task-s-public-result-may-omit-the-actionable-validation-failure -->
<a id="applied-learning-a-coding-task-s-public-result-may-omit-the-actionable-validation-failure"></a>
**A coding task's public result may omit the actionable validation failure.**
The canonical task result can report only `validation_failed` and even an empty
`files` list after retaining a real candidate. Read the task artifact's
`validate/status.json` for the exact action failure before diagnosing or
redispatching; for example, Phase 6 cross-app validation correctly recorded
`{:spawn_backend_unavailable, :production_backend_missing}` only there (found
2026-07-13 reviewing retained Grok candidates).

<!-- applied-learning: do-not-reuse-a-delegated-worktree-build-across-compile-time-adapter-modes -->
<a id="applied-learning-do-not-reuse-a-delegated-worktree-build-across-compile-time-adapter-modes"></a>
**Do not reuse a delegated worktree build across compile-time adapter modes.**
`ARBOR_DB=postgres` compiles `:arbor_persistence, :repo_adapter` differently
from the default SQLite test mode, and Mix will reject a later run whose runtime
adapter no longer matches that retained build. Use a fresh named
`MIX_BUILD_PATH` for each adapter mode (or explicitly keep `ARBOR_DB` identical)
instead of treating a worker's `_build_*` directory as mode-agnostic (found
2026-07-13 rerunning the lifecycle suite after Grok's Postgres validation).

<!-- applied-learning: structured-coding-worktree-roots-are-policy-not-a-scratch-directory-preference -->
<a id="applied-learning-structured-coding-worktree-roots-are-policy-not-a-scratch-directory-preference"></a>
**Structured coding worktree roots are policy, not a scratch-directory preference.** `coding_change` dispatch validates `workspace_policy.worktree_base_dir` against configured coding roots before allocating a worker; an arbitrary `/private/tmp/...` path fails with `{:coding_path_outside_roots, :worktree_base_dir}`. Omit the field to use Arbor's configured root unless a reviewed allowed root is specifically required (found 2026-07-15 during Phase 6 supervision delegation).

<!-- applied-learning: flat-coding-change-dispatch-does-not-accept-the-full-composite-action-schema -->
<a id="applied-learning-flat-coding-change-dispatch-does-not-accept-the-full-composite-action-schema"></a>
**Flat `coding_change` dispatch does not accept the full composite-action schema.** The strict compatibility envelope accepts only `kind`, `task`, `repo_path`, `acp_agent`, `base_ref`, `branch_name`, `worktree_base_dir`, `open_pr`, and `submit_review`. Action parameters such as `skip_validation`, `validation_commands`, `timeout`, and `inactivity_timeout_ms` fail before workspace allocation with `{:unknown_task_key, key}` even though `coding_produce_reviewable_change` advertises them. Put supported budgets and controls in a versioned direct plan, or omit them from the flat envelope (found 2026-07-15 after two immediate Phase 6 follow-up dispatch failures).

<!-- applied-learning: mcp-approval-answering-is-explicit-capability-authority-not-trust-profile-graduation -->
<a id="applied-learning-mcp-approval-answering-is-explicit-capability-authority-not-trust-profile-graduation"></a>
**MCP approval answering is explicit capability authority, not trust-profile graduation.** `arbor_answer_approval` authorizes `arbor://approval/answer/<principal-or-agent>` through `Arbor.Security.authorize/4` before it mutates the IRQ. A scoped capability grant with no `requires_approval` constraint is enough for that security check; `Arbor.Trust.authorize/4` would still gate it because the high-risk profile projects `arbor://approval/answer` to a `:ask` ceiling. Do not try to relax this with an `:auto` trust rule. Give the local approver an explicit scoped answer capability for the delegated worker/owner approval principal, or a global `arbor://approval/answer` cap only for trusted operator surfaces. When listing pending approvals, filter on the stored coarse `resource_uri` (for example `arbor://shell/exec`) rather than the command-specific target URI.

<!-- applied-learning: native-hermes-acp-edit-approval-can-fail-before-arbor-validation -->
<a id="applied-learning-native-hermes-acp-edit-approval-can-fail-before-arbor-validation"></a>
**Native Hermes ACP edit approval can fail before Arbor validation.** A `coding_produce_reviewable_change` run with `acp_agent: "hermes"` may return `status: "declined"` with `Edit approval denied by ACP client; file was not modified`. That is Hermes' ACP edit gate, not Arbor's validation approval loop, so no `arbor_list_pending_approvals` item will appear for the validation command.

<!-- applied-learning: acp-launch-isolation-must-include-arbor-home-not-only-cwd-build-paths -->
<a id="applied-learning-acp-launch-isolation-must-include-arbor-home-not-only-cwd-build-paths"></a>
**ACP launch isolation must include `ARBOR_HOME`, not only cwd/build paths.** A coding worker can start a child Arbor runtime while self-validating. If its CLI inherits the live server's Arbor home, that child treats active workspace-retention markers as prior-incarnation evidence and rewrites the production journal under a foreign runtime id; the real store then correctly poisons on inventory drift. Every native and adapted ACP subprocess gets a private owner-tracked `ARBOR_HOME` while retaining its normal credential `HOME`, and that private tree is removed when the session closes (found 2026-07-19 during the Phase 6 r4 benchmark).

<!-- applied-learning: stdio-mcp-servers-must-keep-stdout-json-rpc-clean-during-startup -->
<a id="applied-learning-stdio-mcp-servers-must-keep-stdout-json-rpc-clean-during-startup"></a>
**Stdio MCP servers must keep stdout JSON-RPC clean during startup.** Launching Arbor's stdio signing proxy through Mix while Mix recompiles can print `==> ...`, `Compiling ...`, or `Generated ... app` on stdout. Hermes then tries to parse those compiler lines as JSON-RPC and can hit `init_timeout` before the ACP session starts. Warm the compile cache or keep compiler/log output off stdout before diagnosing the downstream MCP tool path.

<!-- applied-learning: acp-mcpservers-is-additive-not-a-provider-config-override -->
<a id="applied-learning-acp-mcpservers-is-additive-not-a-provider-config-override"></a>
**ACP `mcpServers` is additive, not a provider-config override.** A native ACP agent can load user, compatibility, managed, project, and plugin MCP servers independently of `session/new`; `mcpServers: []` does not disable them, and a broken same-name entry does not portably shadow them. Isolate the provider home, disable compatibility/managed discovery, reject and sandbox-deny repository MCP sources, and bind the session MCP list so create/load/reconnect cannot widen it. Keep raw provider debug/config payloads out of logs: Grok debug output can include its resolved OAuth bearer token, and ExMCP's debug fallback logs full unsupported notification payloads (verified 2026-07-19).

<!-- applied-learning: long-running-mcp-actions-and-canaries-need-asynchronous-owner-processes -->
<a id="applied-learning-long-running-mcp-actions-and-canaries-need-asynchronous-owner-processes"></a>
**Long-running MCP actions and canaries need asynchronous owner processes.** Calling `coding_produce_reviewable_change` directly through synchronous `arbor_run` can outlive the HTTP request/session teardown: a Grok ACP session started normally, then the gateway timed out stopping the request-scoped MCP session after about 11 seconds and killed the ACP client with an HTTP 500. A synchronous gateway canary can likewise lose its owner on request timeout. Start persisted coding work, or an unlinked async canary task, and publish explicit durable status before polling; do not leave a long canary owned only by the request (reproduced 2026-07-09 and 2026-07-19).

<!-- applied-learning: answering-a-top-level-mcp-approval-does-not-currently-make-a-fresh-arbor-run-replay-resumable -->
<a id="applied-learning-answering-a-top-level-mcp-approval-does-not-currently-make-a-fresh-arbor-run-replay-resumable"></a>
**Answering a top-level MCP approval does not currently make a fresh `arbor_run` replay resumable.** `trust_propose_profile` returned a pending IRQ and `arbor_answer_approval` approved it, but calling the same action/params again created a new IRQ because the approved-invocation marker was not carried across requests. Nested owners such as `coding_produce_reviewable_change` work because they remain alive, await the IRQ, and retry with the marker themselves. Top-level gated actions need an async owner or an explicit retry token/context before "answer, then call again" can be relied on (reproduced 2026-07-09).

<!-- applied-learning: custom-coding-validation-commands-must-not-assume-ignored-repo-tooling-exists-in-a-git-worktree -->
<a id="applied-learning-custom-coding-validation-commands-must-not-assume-ignored-repo-tooling-exists-in-a-git-worktree"></a>
**Custom coding validation commands must not assume ignored repo tooling exists in a git worktree.** `coding_produce_reviewable_change` routes recognized `mix compile` and bare `mix quality` commands through schema-bounded Mix actions, but `./bin/mix test ...` currently falls back to raw `Shell.Execute`. After approval, that command runs with the generated worktree as `cwd`; because `bin/mix` is not present there, validation fails with `{:executable_not_found, "./bin/mix"}` and no commit is produced. Route test commands through `Mix.Test` with shared host deps/build paths, or resolve the tracked checkout's wrapper explicitly before using shell fallback (reproduced 2026-07-09 with Grok ACP).

<!-- applied-learning: prefer-steering-an-active-delegated-acp-worker-for-review-and-rework-reserve-cancellation-for-termination -->
<a id="applied-learning-prefer-steering-an-active-delegated-acp-worker-for-review-and-rework-reserve-cancellation-for-termination"></a>
**Prefer steering an active delegated ACP worker for review and rework; reserve cancellation for termination.** Steering preserves the model context, worktree, and test state. As of 2026-07-09, `coding_produce_reviewable_change` does not expose nested ACP steering, and Session steering cannot interrupt a blocking nested action, so add an explicit task/ACP steering control instead of simulating rework with cancel-and-redispatch. `arbor_cancel_task` must remain hard, deterministic termination.

<!-- applied-learning: verify-the-pinned-mix-wrapper-from-inside-the-actual-delegated-worktree -->
<a id="applied-learning-verify-the-pinned-mix-wrapper-from-inside-the-actual-delegated-worktree"></a>
**Verify the pinned Mix wrapper from inside the actual delegated worktree.** A nested git worktree can inherit a PATH with Homebrew before mise's insertion point; `mise current` still reports the configured versions while `mise exec -- mix` silently selects `/opt/homebrew/bin/mix` and the wrong OTP. `bin/mix` must resolve `mise where erlang` / `mise where elixir`, prepend those exact `bin` directories, and execute that Mix path. Check `./bin/mix --version` in the worktree, not only the parent checkout (found 2026-07-09: parent used Elixir 1.19.5/OTP 28 while the nested worktree used Elixir 1.20.2/OTP 29).

<!-- applied-learning: a-custom-mix-build-directory-must-still-be-ignored-before-a-coding-worker-commits -->
<a id="applied-learning-a-custom-mix-build-directory-must-still-be-ignored-before-a-coding-worker-commits"></a>
**A custom Mix build directory must still be ignored before a coding worker commits.** Names such as `_build_test_owner_outcome` do not necessarily match the repository's ignore rules; a worker that later runs `git add -A` can stage an entire generated build tree and make workspace inspection report irrelevant changes. Prefer the standard ignored `_build`, or verify `git check-ignore` and remove the custom build output before the worker returns (found 2026-07-15 while salvaging the owner-observed outcome delegation).

<!-- applied-learning: a-clean-coding-worktree-does-not-prove-the-worker-made-no-change -->
<a id="applied-learning-a-clean-coding-worktree-does-not-prove-the-worker-made-no-change"></a>
**A clean coding worktree does not prove the worker made no change.** ACP workers can create a commit even when asked only to edit; `git status --porcelain` is then empty while `HEAD` has advanced. `coding_produce_reviewable_change` currently misclassifies that case as `no_changes` (observed 2026-07-09 on the Grok parity-fixture delegation). Capture the acquired base commit and treat either a dirty tree or `HEAD != base_commit` as a change. Prompt the worker not to commit so the wrapper owns the review commit, but enforce correct detection in code rather than trusting that instruction.

<!-- applied-learning: verify-delegated-git-refs-as-exact-opaque-values-before-invoking-the-coding-action -->
<a id="applied-learning-verify-delegated-git-refs-as-exact-opaque-values-before-invoking-the-coding-action"></a>
**Verify delegated Git refs as exact opaque values before invoking the coding action.** Do not reconstruct, expand, or concatenate a commit hash while relaying it through an agent prompt. Prefer a verified short hash or stable branch name when either is unambiguous, and run `git rev-parse --verify <ref>^{commit}` before dispatch. A 2026-07-09 correction delegation duplicated part of a full SHA, so `coding_produce_reviewable_change` failed before the ACP worker started.

<!-- applied-learning: do-not-send-long-newline-delimited-mcp-json-frames-through-a-canonical-pty -->
<a id="applied-learning-do-not-send-long-newline-delimited-mcp-json-frames-through-a-canonical-pty"></a>
**Do not send long newline-delimited MCP JSON frames through a canonical PTY.** A terminal's line buffer can truncate or reject a large JSON-RPC request before the stdio signer reads it, which looks like a malformed or missing MCP response. Use a non-TTY client or an existing MCP tool for long dispatch payloads; reserve interactive signer sessions for short diagnostic calls (found 2026-07-10 during the signed steering proof).

<!-- applied-learning: accepted-queued-steering-needs-an-explicit-terminal-reconciliation-contract -->
<a id="applied-learning-accepted-queued-steering-needs-an-explicit-terminal-reconciliation-contract"></a>
**Accepted queued steering needs an explicit terminal reconciliation contract.** If the worker task succeeds, accepted controls can reconcile to delivered; if the provider or task fails after accepting a control, report delivery unknown or not delivered and never replay the same opaque control ID. Leaving accepted controls permanently queued, or retrying after provider delivery became ambiguous, creates either false status or duplicate instructions (found 2026-07-10 after the live Grok steering task).

<!-- applied-learning: coding-worker-output-is-evidence-not-control-authority -->
<a id="applied-learning-coding-worker-output-is-evidence-not-control-authority"></a>
**Coding worker output is evidence, not control authority.** After a successful ACP turn, the coding pipeline must capture the provider session id for continuity and inspect the owned workspace to decide `no_changes` versus validation/review/commit. Never parse or route on a model-reported `implemented`/`declined` status in the current graph; malformed output must not discard real edits or consume a repair budget. Prompts may still require one JSON-only response for compatibility with resumed archived graphs whose old parser is immutable. Retain `protocol_retry_count=0` only as a public compatibility metric while older records age out (fixed 2026-07-15 after repeated Grok terminal-response failures hid completed commits).

<!-- applied-learning: gate-acp-coding-turns-on-trusted-stop-reason-and-per-turn-owner-fingerprints -->
<a id="applied-learning-gate-acp-coding-turns-on-trusted-stop-reason-and-per-turn-owner-fingerprints"></a>
**Gate ACP coding turns on trusted `stop_reason` and per-turn owner fingerprints.** A successful `acp_send_message` is not enough: require explicit `stop_reason == "end_turn"` before workspace inspection; never default a missing/blank stop reason to `end_turn` at the action layer. Treat `exists != true` as `pipeline_error` with retention (never `no_changes`). Capture a bounded workspace fingerprint immediately before each implement/rework send and compare after the turn — initial no-op => `no_changes`, rework no-op => `pipeline_error` (`worker_turn_no_progress`) so a prior candidate is not re-presented. Keep prompts requesting one advisory terminal JSON object for old-graph compatibility while the live graph ignores that prose for control (hardened 2026-07-15).

<!-- applied-learning: coding-plan-uses-reviewed-task-class-identifiers-not-informal-scope-labels -->
<a id="applied-learning-coding-plan-uses-reviewed-task-class-identifiers-not-informal-scope-labels"></a>
**Coding Plan uses reviewed task-class identifiers, not informal scope labels.**
`task_class: "simple"` is invalid. Use `"default"` for a narrow ordinary change;
the current reviewed set is `default`, `security_regression`, `contract_change`,
`frontend_visual`, `docs_only`, `cross_app`, and `database_migration` (found
2026-07-10 when a Phase 6 dogfood dispatch failed normalization before startup).

<!-- applied-learning: structured-coding-dispatch-requires-the-task-kind-envelope -->
<a id="applied-learning-structured-coding-dispatch-requires-the-task-kind-envelope"></a>
**Structured coding dispatch requires the task-kind envelope.** Send executable CodingPlan data through `arbor_dispatch_task` as `%{"kind" => "coding_change", "plan" => plan}`. A bare plan map is not selected by TaskStore's coding executor and instead falls through to the ordinary agent-session path, where unrelated turn-graph errors can obscure the malformed dispatch (found 2026-07-11 while retrying security-regression dogfood).

<!-- applied-learning: audit-every-runtime-dispatch-branch-when-adding-a-resource-bound -->
<a id="applied-learning-audit-every-runtime-dispatch-branch-when-adding-a-resource-bound"></a>
**Audit every runtime dispatch branch when adding a resource bound.** A timeout or output ceiling on the primary executor does not cover an alternate backend selected by syntax, feature flag, agent context, or authorization mode. Trace the public operation through every dispatch branch and either enforce identical bounds there or disable the unbounded branch by default; an action-schema option alone can otherwise advertise protection that the live path ignores (found 2026-07-11 when compound shell commands bypassed `Arbor.Shell.Executor` through `CapShell`).

<!-- applied-learning: do-not-verify-against-an-active-worker-s-mutable-worktree -->
<a id="applied-learning-do-not-verify-against-an-active-worker-s-mutable-worktree"></a>
**Do not verify against an active worker's mutable worktree.** A delegated coding loop can rewrite source while an external Mix command is compiling it, producing a mixed-revision build and failures that belong to neither commit. Wait for the worker's committed terminal snapshot or create a detached worktree at the exact commit, then run verification there with an isolated build path (found 2026-07-11 while Grok was applying council rework to security-attestation routing).

<!-- applied-learning: the-coding-plan-data-contract-is-broader-than-the-executable-v1-feature-set -->
<a id="applied-learning-the-coding-plan-data-contract-is-broader-than-the-executable-v1-feature-set"></a>
**The Coding Plan data contract is broader than the executable v1 feature set.** `Arbor.Contracts.Coding.Plan.new/1` can normalize optional policy fields that the current compiler intentionally rejects as `{:unsupported_v1_feature, field}`. Before dispatching live work, use only the executable profile subset (or run a compile probe); in particular, leave `rework.stop_conditions` empty until the compiler implements it. A preflight rejection before workspace acquisition is safe to correct and redispatch (found 2026-07-11 when terminal-approval cleanup was rejected before worker startup).

<!-- applied-learning: private-per-dispatch-options-must-not-select-executable-cleanup-code -->
<a id="applied-learning-private-per-dispatch-options-must-not-select-executable-cleanup-code"></a>
**Private per-dispatch options must not select executable cleanup code.** A caller that can reach a low-level task store directly can supply an arbitrary MFA even when the facade normally constructs that option. Fix stable lifecycle code at the store's trusted initialization boundary (with an explicit test-only seam if needed), and let per-task descriptors carry data only. Launch deferred work with module/function/args APIs rather than storing or spawning anonymous closures (found 2026-07-11 when council review rejected the first terminal-approval cleanup implementation).

<!-- applied-learning: check-the-current-branch-after-a-coding-subagent-reports-completion -->
<a id="applied-learning-check-the-current-branch-after-a-coding-subagent-reports-completion"></a>
**Check the current branch after a coding subagent reports completion.** A worker may commit directly to the shared branch rather than returning an external commit for cherry-pick, even when its changes were produced in an isolated execution context. Re-read `git status` and `git log` before integrating another branch so later work is based on the actual HEAD and an incomplete worker commit is corrected forward rather than duplicated (found 2026-07-11 during Agent baseline repair).

<!-- applied-learning: a-managed-acp-handle-lives-only-as-long-as-its-owning-action-unless-an-explicit-durable-owner-retains-it -->
<a id="applied-learning-a-managed-acp-handle-lives-only-as-long-as-its-owning-action-unless-an-explicit-durable-owner-retains-it"></a>
**A managed ACP handle lives only as long as its owning action unless an explicit durable owner retains it.** Calling `acp_start_session` as one standalone MCP action can return `status: "ready"` while the action's cleanup closes the worker immediately; a later standalone `acp_send_message` then returns `:not_found`. Multi-turn steering must stay inside the coding task owner (or use a deliberately pooled/durable session contract), and retained work should be resumed by a new task from an exact committed checkpoint rather than assuming the old worker handle survived (found 2026-07-11 after commit-approval rework terminated a coding pipeline).

<!-- applied-learning: outer-task-liveness-does-not-imply-the-acp-worker-session-is-steerable -->
<a id="applied-learning-outer-task-liveness-does-not-imply-the-acp-worker-session-is-steerable"></a>
**Outer task liveness does not imply the ACP worker session is steerable.** Once the implementation node closes its managed ACP session, the task can still be waiting on commit approval while `steer_task` correctly reports `task_terminal` for the worker stage. Deliver steering while the worker session is alive; after it closes, retain or commit an exact checkpoint and start a new delegated revision rather than assuming approval-wait state preserves the ACP handle (found 2026-07-11 trying to steer validator corrections at commit approval).

<!-- applied-learning: security-regression-coding-plan-requested-paths-are-test-selectors-not-source-scopes -->
<a id="applied-learning-security-regression-coding-plan-requested-paths-are-test-selectors-not-source-scopes"></a>
**`security_regression` coding-plan `requested_paths` are test selectors, not source scopes.** The compiler requires a non-empty list where every path ends in `_test.exs`; passing app directories or implementation files fails before workspace acquisition with `{:invalid_security_regression_paths, ...}`. Put the exact public behavioral regression test paths there and describe implementation ownership in the task prompt instead (found 2026-07-11 while dispatching the signing-authority spine correction).

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

<!-- applied-learning: a-field-accepted-by-the-coding-plan-contract-may-still-be-unsupported-by-the-v1-compiler -->
<a id="applied-learning-a-field-accepted-by-the-coding-plan-contract-may-still-be-unsupported-by-the-v1-compiler"></a>
**A field accepted by the coding Plan contract may still be unsupported by the v1 compiler.** Non-empty `rework.stop_conditions` and non-nil `budgets.model_cost_usd` normalize successfully but dispatch fails before workspace acquisition with `{:unsupported_v1_feature, field}`; `budgets.parallelism` is executable only at `1`. For executable v1 dispatches, check `CodingPlan.Compiler.validate_supported_v1/1`, omit unsupported fields, and use the reviewed profile plus bounded `max_cycles`, `wall_clock_ms`, and `inactivity_timeout_ms` instead (found 2026-07-11 redispatching Phase 6 corrections).

<!-- applied-learning: the-public-task-control-facade-remains-usable-when-a-client-has-not-exposed-a-steering-mcp-tool -->
<a id="applied-learning-the-public-task-control-facade-remains-usable-when-a-client-has-not-exposed-a-steering-mcp-tool"></a>
**The public task-control facade remains usable when a client has not exposed a steering MCP tool.** `Arbor.Agent.Orchestration.steer_task/3` still performs exact task/delegator authorization and persists the control through TaskStore; invoke it with the authenticated caller identity through a trusted local RPC surface rather than mutating worker state directly. A control queued as `same_session_follow_up` while ACP is inside a blocking turn is not delivered yet and must remain visibly queued until that session accepts it (found 2026-07-11 steering the commit-approval R3 correction).

<!-- applied-learning: executable-v1-coding-plans-use-workspace-policy-mode-isolated -->
<a id="applied-learning-executable-v1-coding-plans-use-workspace-policy-mode-isolated"></a>
**Executable v1 coding plans use `workspace_policy.mode="isolated"`.** The intuitive value `"new"` is not part of the closed v1 contract and fails before workspace acquisition. The v1 compiler also requires `task_class` to match `validation_profile` (for example both `"cross_app"`); describe additional security-test obligations in the task rather than mixing profile names (found 2026-07-11 dispatching the approval-authority correction).

<!-- applied-learning: a-terminal-steering-control-must-not-remain-queued -->
<a id="applied-learning-a-terminal-steering-control-must-not-remain-queued"></a>
**A terminal steering control must not remain `queued`.** When an executor accepts a control but the task fails or is cancelled before delivery acknowledgement, the outcome is terminally delivery-unconfirmed, not retryable queue state. Project it under an explicit terminal status and preserve the error/evidence separately; otherwise status counts imply work can still be delivered after the owner has exited (found 2026-07-11 when a queued ACP follow-up ended in `worker_protocol_invalid_json_after_retry`).

<!-- applied-learning: term-serialization-bounds-must-include-integer-bit-size-before-encoding -->
<a id="applied-learning-term-serialization-bounds-must-include-integer-bit-size-before-encoding"></a>
**Term serialization bounds must include integer bit size before encoding.** Counting every integer as a fixed scalar lets a hostile bignum allocate megabytes in `term_to_binary/2` before a post-encode byte check can reject it. Bound signed integer magnitude/bit length during the structural walk, then encode only the already bounded term (found 2026-07-11 reviewing execution-proof payloads).

<!-- applied-learning: acp-continuity-requires-the-provider-session-id-not-only-the-managed-worker-handle -->
<a id="applied-learning-acp-continuity-requires-the-provider-session-id-not-only-the-managed-worker-handle"></a>
**ACP continuity requires the provider session ID, not only the managed worker handle.** `worker_session_id` (`acp_worker_*`) is an owner-scoped live registry handle; `acp_close_session` or owner death invalidates it. The ACP provider's `worker.session_id` is the durable conversation identity consumed by `load_session`. A coding graph must opt into pooled execution, preserve/project that provider ID before closing or checking in the worker, and pass it through a later authorized start to resume context. Returning only the closed managed handle is not resumability. When diagnosing an older run, recover the provider ID from the `open_worker/status.json` checkpoint if the public result dropped it (found 2026-07-12 tracing `task_167682`, whose non-pooled graph retained provider session `019f52ad-dfb1-7d33-8156-effae2a1c9fa` only in the checkpoint).

<!-- applied-learning: a-durable-acp-provider-session-may-still-be-bound-to-its-original-workspace -->
<a id="applied-learning-a-durable-acp-provider-session-may-still-be-bound-to-its-original-workspace"></a>
**A durable ACP provider session may still be bound to its original workspace.** Reopening a valid Grok provider session from a newly allocated worktree returned `FS_NOT_FOUND` even though the provider conversation ID and both worktrees still existed. Do not equate "new worktree + resume_session_id" with continuity. Reactivate the retained original workspace for follow-up work, or use a provider protocol that explicitly supports rebinding the session cwd; otherwise classify the attempt as resume-unavailable and preserve the candidate commit before falling back to a fresh session (found 2026-07-13 when `task_37699` tried to resume the `task_35331` worker on a review-rework worktree).
The structured coding dispatcher currently allocates a new workspace for each new slice, so omit
Grok resume fields there unless that path has first gained explicit retained-workspace reactivation;
reserve provider-session resume for a rework path that can reopen the original workspace (reconfirmed
2026-07-14 by `task_74242` failing at `acp_start_session` before implementation).

<!-- applied-learning: budget-agent-work-by-model-provider-but-distinguish-native-subagents-from-acp-workers -->
<a id="applied-learning-budget-agent-work-by-model-provider-but-distinguish-native-subagents-from-acp-workers"></a>
**Budget agent work by model/provider, but distinguish native subagents from ACP workers.** Keep the coordinating parent on architecture, delegation, integration, and final judgment; send substantial implementation to resumable ACP workers such as Grok or GPT-5.3-Codex-Spark; use a faster/cheaper native Codex subagent only for bounded mechanical work; reserve stronger agents for security review and cross-library design. Inspect `spawn_agent`'s advertised model overrides before choosing a native subagent, and inspect Arbor's ACP provider registry separately: absence from `spawn_agent` does not imply a subscription-backed model is unavailable through ACP. Limit active concurrency, close completed native agents immediately, reuse author/reviewer threads and provider session IDs with frozen ledgers, and avoid `fork_context: true` unless the worker genuinely needs the full history (adopted 2026-07-12 after repeated parent-model capacity stalls; ACP Spark lane clarified 2026-07-12).

<!-- applied-learning: stable-structured-coding-plans-require-a-review-bearing-profile-and-only-their-executable-feature-subset -->
<a id="applied-learning-stable-structured-coding-plans-require-a-review-bearing-profile-and-only-their-executable-feature-subset"></a>
**Stable structured coding plans require a review-bearing profile and only their executable feature subset.** The compiled `coding_change` path rejects `review_profile: "none"` before workspace allocation. Use `human_required` when the local delegator will perform the binding review, or `binding` when the configured council should decide; do not use a no-review profile merely to save reviewer tokens. Also, contract-valid optional fields are not necessarily executable in v1: custom `rework.stop_conditions` currently fails preflight with `unsupported_v1_feature`, so omit it and use the compiled profile defaults until that feature is implemented (confirmed 2026-07-13 dispatching the eval DOT last-mile slice).

<!-- applied-learning: preserve-a-stalled-delegated-worktree-before-starting-a-replacement-worker -->
<a id="applied-learning-preserve-a-stalled-delegated-worktree-before-starting-a-replacement-worker"></a>
**Preserve a stalled delegated worktree before starting a replacement worker.** When an ACP run exits with useful uncommitted changes, use `git stash create` to capture the tracked work without altering the retained worker directory, then point a named preservation branch at that commit. A correction can start from the exact preserved state while the original workspace remains available for diagnosis and provider-session recovery (adopted 2026-07-13 after the spawn-containment R10 worker transport failed).

<!-- applied-learning: a-structured-coding-dispatch-has-a-closed-two-level-envelope -->
<a id="applied-learning-a-structured-coding-dispatch-has-a-closed-two-level-envelope"></a>
**A structured coding dispatch has a closed two-level envelope.** The outer task contains only `kind: "coding_change"` and `plan`; execution policy such as workspace, worker, review, rework, budgets, and output belongs inside the versioned plan. Validate the plan against both `Arbor.Contracts.Coding.Plan` and the current compiler subset: a field may be contract-valid yet still fail preflight as `unsupported_v1_feature` (found 2026-07-13 re-dispatching the spawn-containment correction).

<!-- applied-learning: the-coding-security-regression-profile-treats-requested-paths-as-test-paths -->
<a id="applied-learning-the-coding-security-regression-profile-treats-requested-paths-as-test-paths"></a>
**The coding `security_regression` profile treats `requested_paths` as test paths.** Its compiler requires a non-empty list containing only files ending in `_test.exs`; adding the source file produces `{:invalid_security_regression_paths, ...}` before workspace allocation. Use that profile for its specialized two-revision proof, not merely as a descriptive label for security-sensitive feature work. A feature slice that changes source plus adversarial tests should use an executable general profile and still prove the tests fail against the candidate parent where applicable (found 2026-07-14 while continuing the Apple Container planner).

<!-- applied-learning: use-the-structured-coding-envelope-for-durable-acp-delegation -->
<a id="applied-learning-use-the-structured-coding-envelope-for-durable-acp-delegation"></a>
**Use the structured coding envelope for durable ACP delegation.** A plain `arbor_dispatch_task` prompt goes through the target agent's ordinary task/chat path; merely naming `coding_produce_reviewable_change` does not invoke it. Conversely, running that long owner-bound composite synchronously through standalone `arbor_run` can lose its MCP request owner and tear down the ACP worker. Dispatch `{"kind":"coding_change","plan":{...}}` for coding work, use `arbor_run` only for bounded standalone actions, and use a compiled DOT node when an explicit long-running action belongs inside a durable workflow (found 2026-07-14 after the plain dispatch took the chat path and the synchronous composite lost its request owner).

<!-- applied-learning: do-not-wrap-an-internal-action-invocation-inside-arbor-dispatch-task -->
<a id="applied-learning-do-not-wrap-an-internal-action-invocation-inside-arbor-dispatch-task"></a>
**Do not wrap an internal action invocation inside `arbor_dispatch_task`.** The MCP task boundary routes only a plain prompt or a supported task kind. A payload such as `{"action":"coding_produce_reviewable_change","params":{...}}` has no `kind`, falls through to the default chat runner, and fails with `:missing_task_input`; `coding_produce_reviewable_change` is now an internal compiled-pipeline action rather than the MCP dispatch envelope. Send the canonical `{"kind":"coding_change","plan":{...}}` shape, or the strict legacy-compatible flat `coding_change` fields while that adapter remains supported (found 2026-07-14 after two immediate false-start dispatches following a reconnect).

<!-- applied-learning: distinguish-backend-availability-from-host-admission-in-structured-coding-validation -->
<a id="applied-learning-distinguish-backend-availability-from-host-admission-in-structured-coding-validation"></a>
**Distinguish backend availability from host admission in structured coding validation.** Before `f4b675a2`, the default coding profile correctly stopped at `production_backend_missing`; retained `validation_failed` tasks from that bootstrap period can still contain useful committed changes worth independent review. The facade is now open, so new runs must not be assumed red for that sentinel. On an unprovisioned host, a valid request instead fails admission before registration (for example `:executable_not_found` when the accepted `/usr/local` signed-installer assets are absent). Do not weaken the validation profile or path/signature policy; identify whether the failure is stale loaded code, missing host authority, or candidate behavior (updated 2026-07-15 after the live facade proof).

<!-- applied-learning: independently-test-retained-worker-commits-with-a-fresh-build-path -->
<a id="applied-learning-independently-test-retained-worker-commits-with-a-fresh-build-path"></a>
**Independently test retained worker commits with a fresh build path.** A retained coding worktree may have no local `deps/`, and its `_build` can reflect the worker's compile-time environment (for example Postgres) while the reviewing test process selects another adapter (for example SQLite). Share only the canonical checkout's dependency cache through `MIX_DEPS_PATH`, use a fresh reviewer-owned `MIX_BUILD_PATH`, and keep that build outside any suite that intentionally derives repository identity from loaded BEAM paths. Reusing the worker `_build` can produce a compile-env mismatch that says nothing about the candidate source (found 2026-07-14 independently verifying the StartupEpoch extraction).

<!-- applied-learning: treat-worker-resume-provider-as-a-provider-selector-not-a-boolean -->
<a id="applied-learning-treat-worker-resume-provider-as-a-provider-selector-not-a-boolean"></a>
**Treat `worker.resume_provider` as a provider selector, not a boolean.** In a structured coding plan it is an optional nonblank provider/session string; omit it for a fresh worker. Passing `true` fails schema validation before workspace allocation. Also use `review_profile: "binding"` for executable delegated review: although the interchange contract can describe `"none"`, the current compiler rejects that profile before execution (confirmed 2026-07-14 dispatching the Apple local-alias slices).

<!-- applied-learning: run-composition-tests-after-disjoint-delegated-contract-changes -->
<a id="applied-learning-run-composition-tests-after-disjoint-delegated-contract-changes"></a>
**Run composition tests after disjoint delegated contract changes.** Two workers can each produce a clean focused commit while a parent aggregate fixture or consumer remains on the prior required shape. Compose the commits in an isolated review worktree and run the child plus every direct consumer before integration; the Apple launchd evidence expansion passed its own tests but initially left 14 aggregate admission tests failing at the newly required `launchd.path` field (found 2026-07-14 combining the Phase 6 Apple admission slices).

<!-- applied-learning: inspect-a-retained-coding-workspace-independently-of-the-terminal-task-verdict -->
<a id="applied-learning-inspect-a-retained-coding-workspace-independently-of-the-terminal-task-verdict"></a>
**Inspect a retained coding workspace independently of the terminal task verdict.** `worker_protocol_invalid_json_after_retry` describes the worker-response envelope, not necessarily the Git outcome: one Grok run left a valid committed change while another left only dirty files. Check the retained worktree's `HEAD`, status, and requested-path diff before deciding whether to cherry-pick, salvage, or re-dispatch; never infer commit durability from the wrapper status alone (found 2026-07-14 during the Apple admission slices).

<!-- applied-learning: checkpoint-a-substantial-delegated-patch-before-diagnosing-test-infrastructure -->
<a id="applied-learning-checkpoint-a-substantial-delegated-patch-before-diagnosing-test-infrastructure"></a>
**Checkpoint a substantial delegated patch before diagnosing test infrastructure.** A structured coding worker that returns `declined` triggers normal workspace removal; useful tracked edits disappear if they were never committed, even when the outer task still had ample time. For a correction likely to consume most of one ACP turn, require an early formatted checkpoint commit, then run focused tests from the repository root and correct forward. An `eaddrinuse`, missing app-scoped dependency path, or intentionally unavailable backend is validation evidence, not a reason to leave the implementation ephemeral (found 2026-07-14 when `task_158723` drafted the Apple unit-worker F1-F9 corrections and then removed its uncommitted worktree).

<!-- applied-learning: map-decoding-can-erase-duplicate-json-members-before-closed-schema-validation -->
<a id="applied-learning-map-decoding-can-erase-duplicate-json-members-before-closed-schema-validation"></a>
**Map decoding can erase duplicate JSON members before closed-schema validation.** Jason's normal map mode keeps only one value for repeated keys, so a durable record with two `active` or `token` members may look valid after decode while evidence was discarded. Decode security-critical durable JSON as ordered objects, reject duplicate members recursively under a depth/size bound, then convert to maps for the ordinary closed core (found 2026-07-14 reviewing the Apple unit-intent journal).

<!-- applied-learning: owner-death-must-preserve-coding-workspaces-even-when-currently-pristine -->
<a id="applied-learning-owner-death-must-preserve-coding-workspaces-even-when-currently-pristine"></a>
**Owner death must preserve coding workspaces, even when currently pristine.** TaskStore hard cancellation kills the coding owner, but an external ACP worker can outlive it and write after any inspect-then-remove check. `WorkspaceLeaseRegistry` therefore never treats unexpected owner death as immediate deletion authority: reused paths survive, and every owned path converts to the existing identity-pinned, bounded-TTL retained lease for exact task+principal reactivation. Identity uncertainty is a non-destructive authorized quarantine with retry, not deletion authority. Explicit release and verified TTL expiry remain the deletion paths (fixed 2026-07-15 after cancellation destroyed an uncommitted coding patch).

<!-- applied-learning: an-acp-provider-session-is-not-a-durable-workspace-continuation-by-itself -->
<a id="applied-learning-an-acp-provider-session-is-not-a-durable-workspace-continuation-by-itself"></a>
**An ACP provider session is not a durable workspace continuation by itself.** A retained Git commit/worktree can survive a coding task while the pooled provider session is closed or its provider-owned path state disappears; an explicit Grok `resume_session_id` then fails immediately with `FS_NOT_FOUND`. Try the exact provider resume once, but preserve progress in Git and re-dispatch a fresh conversation from that exact commit with the frozen finding ledger when restoration is unavailable. Session continuity improves context reuse; commit continuity is the recovery invariant (found 2026-07-15 correcting Engine lifecycle L3A after the original worker response protocol failed).

<!-- applied-learning: standalone-mcp-action-calls-cannot-carry-a-process-owned-coding-workspace-lease-across-requests -->
<a id="applied-learning-standalone-mcp-action-calls-cannot-carry-a-process-owned-coding-workspace-lease-across-requests"></a>
**Standalone MCP action calls cannot carry a process-owned coding workspace lease across requests.** `coding_workspace_acquire` can return an active lease, but a later standalone `arbor_run` executes under a different request owner and `coding_workspace_inspect`, `coding_workspace_committed_change`, or council snapshot binding can return `:not_found`. Run acquisition, committed-change capture, and binding review inside one structured `coding_change` task/compiled pipeline; use ordinary Git inspection for a retained failed worktree rather than trying to reconstruct task ownership through separate MCP calls (found 2026-07-15 attempting an independent binding review of Engine lifecycle L3A).

<!-- applied-learning: codingplan-schema-acceptance-does-not-imply-the-executable-v1-profile-supports-a-field -->
<a id="applied-learning-codingplan-schema-acceptance-does-not-imply-the-executable-v1-profile-supports-a-field"></a>
**CodingPlan schema acceptance does not imply the executable v1 profile supports a field.** The v1 contract can normalize non-empty `overlays` and `rework.stop_conditions`, while the current compiler rejects both as `{:unsupported_v1_feature, field}` before workspace allocation. Check `Compiler.validate_supported_features/1` and profile-specific preflight before adding optional plan fields to an MCP dispatch; omit unsupported fields or use their supported empty/default value. The executable `security_regression` profile also requires a non-empty `requested_paths` list containing only `*_test.exs` paths (found 2026-07-15 dispatching Engine lifecycle L3B).

<!-- applied-learning: a-process-started-with-start-link-through-erpc-inherits-the-short-lived-rpc-worker-s-lifetime -->
<a id="applied-learning-a-process-started-with-start-link-through-erpc-inherits-the-short-lived-rpc-worker-s-lifetime"></a>
**A process started with `start_link` through `:erpc` inherits the short-lived RPC worker's lifetime.** Starting a remote long-lived service inside `:erpc.call/4` links it to the transient RPC server process, so it can disappear as soon as the call returns and later authorization looks mysteriously empty. Start it under a stable remote supervisor or explicitly unlink the returned PID before the RPC worker exits, then assert the registered process remains alive from a second RPC call (found 2026-07-15 building the real L4 multi-BEAM recovery proof).

<!-- applied-learning: verify-the-running-checkout-before-live-mcp-dogfood -->
<a id="applied-learning-verify-the-running-checkout-before-live-mcp-dogfood"></a>
**Verify the running checkout before live MCP dogfood.** `mix arbor.recompile` executes `IEx.Helpers.recompile/0` in the running node's own working directory; it does not load source or `priv/` assets from the shell that invoked the RPC. A long-lived node may run from a detached runtime worktree far behind `main`, making a new task archive a stale DOT graph even after recompile reports success. Check `Arbor.Orchestrator.Config.coding_pipeline_path/0` and the runtime worktree HEAD before attributing live behavior to current source (found 2026-07-15 while verifying coding protocol hardening).

<!-- applied-learning: normalize-explicit-acp-wire-aliases-never-replace-a-missing-terminal-fact -->
<a id="applied-learning-normalize-explicit-acp-wire-aliases-never-replace-a-missing-terminal-fact"></a>
**Normalize explicit ACP wire aliases; never replace a missing terminal fact.** ExMCP prompt results use camelCase `stopReason`, while streamed completion notifications can expose snake_case `stop_reason`. Normalize both spellings at the action boundary and regress each explicit form, but keep a genuinely missing/blank stop reason missing so the owner graph fails closed (found 2026-07-15 in the live Grok coding pipeline).

<!-- applied-learning: let-coding-dispatch-choose-its-configured-worktree-root-unless-an-override-is-already-known-to-be-admitted -->
<a id="applied-learning-let-coding-dispatch-choose-its-configured-worktree-root-unless-an-override-is-already-known-to-be-admitted"></a>
**Let coding dispatch choose its configured worktree root unless an override is already known to be admitted.** `worktree_base_dir` is a security-sensitive coding path and must fall within the runtime's configured workspace roots; an otherwise valid task can fail preflight with `{:invalid_coding_path, :worktree_base_dir}` before allocating a worker. Omit the override to use the reviewed default rather than guessing that a convenient host temp directory is allowed (found 2026-07-15 dispatching retained-workspace remediation).

<!-- applied-learning: the-mcp-task-timeout-does-not-replace-a-structured-coding-plan-s-wall-clock-budget -->
<a id="applied-learning-the-mcp-task-timeout-does-not-replace-a-structured-coding-plan-s-wall-clock-budget"></a>
**The MCP task timeout does not replace a structured coding plan's wall-clock budget.** `arbor_dispatch_task.timeout` bounds the outer asynchronous task, while `plan.budgets.wall_clock_ms` controls the whole compiled coding graph and defaults to 900,000 ms. The executor uses the smaller value, so a larger outer timeout cannot extend an omitted plan budget; implementation, validation, review, approval, rework, and queued same-session steering follow-ups all consume the original graph wall clock. A follow-up can therefore be killed mid-turn even while the provider session is healthy. Long-running trusted callers that historically sent a flat task must construct an explicit reviewed Plan budget below their own outer cancellation deadline; changing only the outer timeout leaves the graph at its default. Set the reviewed plan budget explicitly and reserve one complete contained-validation pass for every permitted rework cycle, plus implementation/review/approval headroom; a 20-minute graph cannot safely support two approximately 10-minute validation passes (found 2026-07-16/17 during retained-workspace remediation and benchmark-isolation dogfood; reconfirmed 2026-07-18 when a one-hour exact-candidate repair timed out during its final test-only steer and 2026-07-20 when a correct Grok rework exhausted its graph budget during second validation).

<!-- applied-learning: do-not-run-long-owner-bound-coding-work-through-standalone-arbor-run -->
<a id="applied-learning-do-not-run-long-owner-bound-coding-work-through-standalone-arbor-run"></a>
**Do not run long owner-bound coding work through standalone `arbor_run`.** The standalone MCP HTTP request process becomes the composite action/ACP owner; if the Gateway request times out, owner death tears down the managed session and the client sees an empty HTTP 500 even though the worker briefly started. Dispatch the reviewed `coding_change` plan with `arbor_dispatch_task`, then use task status/result/steering so ownership outlives one HTTP request (found 2026-07-16 dispatching retained-workspace safety remediation).

<!-- applied-learning: a-schema-valid-coding-review-profile-may-still-be-forbidden-for-the-target-agent -->
<a id="applied-learning-a-schema-valid-coding-review-profile-may-still-be-forbidden-for-the-target-agent"></a>
**A schema-valid coding review profile may still be forbidden for the target agent.** `review_profile: "none"` exists in the Plan contract, but the executable agent policy can reject it before workspace allocation with `coding_plan_review_profile_not_allowed`. Use the target template's reviewed profile (normally `binding`) unless its trust configuration explicitly permits bypassing council review; never treat contract normalization as authority (found 2026-07-16 retrying retained-workspace safety remediation).

<!-- applied-learning: durable-coding-delegation-goes-through-structured-task-dispatch-not-standalone-arbor-run -->
<a id="applied-learning-durable-coding-delegation-goes-through-structured-task-dispatch-not-standalone-arbor-run"></a>
**Durable coding delegation goes through structured task dispatch, not standalone `arbor_run`.** A long `coding_produce_reviewable_change` call outlives the short-lived MCP HTTP handler that owns its ACP session; handler teardown can kill the worker and return an empty HTTP 500. Resume a coding agent and use `arbor_dispatch_task` with the versioned `coding_change` plan, then drive status, steering, approvals, and result through stable task IDs (found 2026-07-17 while validating the repaired contained toolchain).

<!-- applied-learning: task-handles-are-currently-less-durable-than-retained-coding-workspaces -->
<a id="applied-learning-task-handles-are-currently-less-durable-than-retained-coding-workspaces"></a>
**Task handles are currently less durable than retained coding workspaces.** After a full server restart, an earlier task ID returned `:not_found` while its retained Git workspace evidence still existed. Until TaskStore persistence is implemented and proven, record task results before restart and use the durable workspace journal plus commit identity for recovery; do not describe the public task handle itself as crash-durable (found 2026-07-17 during Phase 6 dogfood).

<!-- applied-learning: versioned-coding-plans-do-not-inherit-legacy-flat-field-aliases -->
<a id="applied-learning-versioned-coding-plans-do-not-inherit-legacy-flat-field-aliases"></a>
**Versioned coding plans do not inherit legacy flat-field aliases.** Every direct Plan object is closed: `branch_name` at the plan top level fails with `{:unknown_fields, ["branch_name"]}` even though the legacy flat `coding_change` envelope accepts it. Put it under `workspace_policy.branch_name`, or omit it and let Arbor generate the branch (found 2026-07-17 dispatching benchmark-isolation remediation).

<!-- applied-learning: a-terminal-delivery-unconfirmed-steering-status-is-not-proof-that-the-follow-up-was-not-delivered -->
<a id="applied-learning-a-terminal-delivery-unconfirmed-steering-status-is-not-proof-that-the-follow-up-was-not-delivered"></a>
**A terminal `delivery_unconfirmed` steering status is not proof that the follow-up was not delivered.** A same-session Grok follow-up executed, changed the candidate, and committed while its task-control record remained unacknowledged and later reconciled to `delivery_unconfirmed` on task timeout. Inspect the ACP transcript and immutable Git evidence before retrying; the control path must durably acknowledge session acceptance so a later outer failure cannot erase known delivery (found 2026-07-17 steering benchmark-isolation remediation; reconfirmed 2026-07-18 when `task_276738` visibly applied a queued production-seam correction but terminalized with delivery unconfirmed at its graph deadline).

<!-- applied-learning: structured-coding-plan-resume-fields-are-a-paired-identity-not-a-boolean-switch -->
<a id="applied-learning-structured-coding-plan-resume-fields-are-a-paired-identity-not-a-boolean-switch"></a>
**Structured coding-plan resume fields are a paired identity, not a boolean switch.** `worker.resume_provider` and `worker.resume_session_id` are optional nonblank strings that must either both be omitted for a fresh pooled worker or both identify the same provider/session binding. A value such as `resume_provider: false` fails plan construction before workspace acquisition (found 2026-07-17 dispatching the benchmark-adapter fixture split).

<!-- applied-learning: acp-rework-continuity-and-acp-tool-completion-are-separate-contracts -->
<a id="applied-learning-acp-rework-continuity-and-acp-tool-completion-are-separate-contracts"></a>
**ACP rework continuity and ACP tool completion are separate contracts.** A rework prompt can reach the same provider session successfully, yet a follow-up terminal tool call can end with `stop_reason: cancelled` before execution; treating every non-`end_turn` stop as an immediate pipeline error loses otherwise-valid workspace progress. Inspect the retained transcript and workspace before restarting, and keep the rework turn alive until ACP client tool execution or denial reaches a settled terminal state (found 2026-07-17 after returning a formatting-only review finding to Grok).

<!-- applied-learning: steer-pre-validation-corrections-generic-action-rework-is-a-rejected-syscall -->
<a id="applied-learning-steer-pre-validation-corrections-generic-action-rework-is-a-rejected-syscall"></a>
**Steer pre-validation corrections; generic action `rework` is a rejected syscall.** `ActionsExecutor` intentionally returns an error when an operator answers a generic action approval with `rework`; only dedicated control actions such as `coding_reviewed_commit` project rework as a branchable success payload. At a validation approval, deliver review feedback with task steering while the managed ACP session is still alive, inspect the resulting workspace, and then approve or deny the exact action request. Answering that request with `rework` terminalizes through the action's `outcome=fail` edge and does not enter the coding graph's validation/operator rework loops (confirmed 2026-07-18 by `task_102210`).

<!-- applied-learning: an-acp-pool-profile-must-be-the-single-source-of-immutable-startup-identity -->
<a id="applied-learning-an-acp-pool-profile-must-be-the-single-source-of-immutable-startup-identity"></a>
**An ACP pool profile must be the single source of immutable startup identity.** Validating and canonicalizing `cwd`/workspace into `SessionProfile` is insufficient if `spawn_session` later forwards the raw option independently: `cwd: nil`, relative paths, and surrounding whitespace can make the profile claim one workspace while the provider starts in another. Verify that `session/new`'s `cwd` is actually bound to the supplied directory workspace, then pass the validated profile into the spawn boundary and derive startup values from it; regress profile fields against `AcpSession` state, not only against another profile (found 2026-07-18 reviewing the task-scoped ACP pool fix and 2026-07-19 diagnosing Grok ACP containment).

<!-- applied-learning: structured-acp-workspace-plans-are-a-live-pool-contract -->
<a id="applied-learning-structured-acp-workspace-plans-are-a-live-pool-contract"></a>
**Structured ACP workspace plans are a live pool contract.** DOT compute nodes intentionally pass `{:directory, path}` and `{:worktree, opts}` through `session.acp_workspace`; a new fail-closed profile validator that accepts only binary paths breaks that production route before `AcpSession` can materialize the existing plan. Admit only the exact established tuple shapes, normalize and bind their immutable plan identity into pool compatibility, reject arbitrary structures, and test the public `AcpPool.checkout/2` path (found 2026-07-18 reviewing `task_188034`).

<!-- applied-learning: every-owner-initiated-acp-session-stop-must-preserve-terminate-2-cleanup -->
<a id="applied-learning-every-owner-initiated-acp-session-stop-must-preserve-terminate-2-cleanup"></a>
**Every owner-initiated ACP session stop must preserve `terminate/2` cleanup.** Replacing an eviction-time `Process.exit(pid, :kill)` is incomplete if timeout cleanup still uses the same raw kill: both bypass provider disconnect and session-owned workspace cleanup. Remove pool indexes promptly when logical capacity must be reclaimed, then use the bounded graceful close path and assert eventual client/workspace cleanup on every stop reason (found 2026-07-18 reviewing ACP pool capacity reclamation).

<!-- applied-learning: initial-explicit-acp-resume-needs-its-own-reviewed-fallback-binding -->
<a id="applied-learning-initial-explicit-acp-resume-needs-its-own-reviewed-fallback-binding"></a>
**Initial explicit ACP resume needs its own reviewed fallback binding.** A new coding task with valid `resume_provider`/`resume_session_id` can fail during `AcpSession` startup with Grok `FS_NOT_FOUND`, before follow-up/rework recovery exists. Bind one fresh-session retry to the reviewed initial-resume plan, classify only exact structural unavailability evidence, and make semantic preflight reject both forged enablement on fresh starts and forged disablement on resumes. Preserve commit/worktree continuity independently of provider-session recovery (found in `task_187330`; repaired with classifier, action, compiler, preflight, and graph regressions in `task_234818` on 2026-07-18).

<!-- applied-learning: arbor-dispatch-task-timeout-is-the-asynchronous-task-deadline-not-an-mcp-call-timeout -->
<a id="applied-learning-arbor-dispatch-task-timeout-is-the-asynchronous-task-deadline-not-an-mcp-call-timeout"></a>
**`arbor_dispatch_task.timeout` is the asynchronous task deadline, not an MCP-call timeout.** Supplying `timeout: 60_000` on a coding dispatch terminalized the graph during `implement` after exactly one minute even though `plan.budgets.wall_clock_ms` allowed 90 minutes. For coding plans, omit the outer timeout unless it is intentionally tighter than the reviewed plan budget; use the plan's wall-clock and inactivity budgets for workflow liveness (found 2026-07-18 in `task_233474`).

<!-- applied-learning: native-acp-cli-options-must-be-placed-at-the-parser-level-that-owns-them -->
<a id="applied-learning-native-acp-cli-options-must-be-placed-at-the-parser-level-that-owns-them"></a>
**Native ACP CLI options must be placed at the parser level that owns them.** Grok accepts `grok agent --model grok-4.5 stdio` but rejects `grok agent stdio --model grok-4.5`; Arbor's generic native-provider `args` are appended after the configured command, so a parent-command option must be embedded in `command` before the subcommand rather than supplied through `args`. Verify the exact argv with the installed CLI's `--help` before pinning a model or policy flag (found 2026-07-18 while making the Grok coding model explicit).

<!-- applied-learning: use-a-raw-elixir-sigil-for-quote-bearing-arbor-rpc-steering-messages -->
<a id="applied-learning-use-a-raw-elixir-sigil-for-quote-bearing-arbor-rpc-steering-messages"></a>
**Use a raw Elixir sigil for quote-bearing `arbor.rpc` steering messages.** The shell can safely single-quote the whole RPC expression, but unescaped double quotes inside an ordinary Elixir message string still terminate that string before RPC runs. Put the human message in a delimiter-safe form such as `~S|...|` (after checking the text does not contain the delimiter), keep the expression on one physical argument line, and reserve ordinary quoted strings for bounded IDs/options (found 2026-07-18 steering the contained CrossApp test-seam repair).

<!-- applied-learning: signed-mcp-coding-dispatch-requires-the-canonical-coding-envelope -->
<a id="applied-learning-signed-mcp-coding-dispatch-requires-the-canonical-coding-envelope"></a>
**Signed MCP coding dispatch requires the canonical coding envelope.** Passing a versioned plan directly as `task` is a valid generic object task, so it routes through ordinary agent chat and can return an empty `result_type: chat` without ever invoking `CodingTaskExecutor`. Wrap it as `%{"kind" => "coding_change", "plan" => plan}` (JSON equivalent for external clients), then verify `current_step: "implement"` or `execution_path: "pipeline"` before treating the dispatch as coding work (found 2026-07-18 after `task_32194` silently took the generic OpenRouter path).

<!-- applied-learning: a-persisted-agent-profile-is-not-a-running-dispatch-target -->
<a id="applied-learning-a-persisted-agent-profile-is-not-a-running-dispatch-target"></a>
**A persisted agent profile is not a running dispatch target.** `Arbor.Agent.list_agents/0` can include an `auto_start: false` coding profile while `arbor_dispatch_task` returns `:agent_not_found` because no runtime is registered. Check `Arbor.Agent.whereis_cluster/1` or the cluster registry and start the exact persisted principal with `Arbor.Agent.start_agent/2` before retrying; do not create a replacement identity merely to unblock dispatch (found 2026-07-18 after `task_59907`).

<!-- applied-learning: acp-task-steering-is-a-durable-follow-up-not-mid-command-injection -->
<a id="applied-learning-acp-task-steering-is-a-durable-follow-up-not-mid-command-injection"></a>
**ACP task steering is a durable follow-up, not mid-command injection.** A control sent during an active provider turn remains queued until that turn settles, and a control submitted at a generic validation approval can be deferred because no worker turn currently owns delivery. `queued` or `deferred` does not mean the correction changed the workspace: inspect control status and Git evidence. Deliver corrections before the worker returns to validation; if a known-bad candidate is already gated, deny that exact approval and continue from retained commits in a fresh bounded task rather than approving redundant validation (found 2026-07-18 in `task_16898`).

<!-- applied-learning: acp-terminal-commands-run-under-zsh-unless-the-provider-explicitly-selects-another-shell -->
<a id="applied-learning-acp-terminal-commands-run-under-zsh-unless-the-provider-explicitly-selects-another-shell"></a>
**ACP terminal commands run under zsh unless the provider explicitly selects another shell.** Bash-only helpers such as `mapfile` fail, and a subsequently expanded empty file array can accidentally turn a bounded test batch into the full suite. Use zsh-native line arrays such as `${(@f)$(<file)}`, a portable `while read` loop, or pass exact argv without shell reconstruction; print and verify the resulting count before launching expensive tests (found 2026-07-18 while diagnosing `task_16898`).

<!-- applied-learning: provider-tool-identities-differ-across-acp-layers -->
<a id="applied-learning-provider-tool-identities-differ-across-acp-layers"></a>
**Provider tool identities differ across ACP layers.** Grok's internal terminal ID is `run_terminal_cmd`, while the ACP client-visible name is `run_terminal_command`; ACP tool kind `execute` is a category, not a reliable provider tool ID. Authorize and deny using the machine-readable identity at the layer being tested, rather than inferring one name from another (found 2026-07-19 during Grok ACP containment work).

<!-- applied-learning: acp-http-mcp-descriptors-must-use-the-standard-wire-shape -->
<a id="applied-learning-acp-http-mcp-descriptors-must-use-the-standard-wire-shape"></a>
**ACP HTTP MCP descriptors must use the standard wire shape.** Send descriptors as `type`/`name`/`url`/`headers`; Grok rejects the legacy `uri`/`name` map during `session/new`, before the MCP tool path can be tested (found 2026-07-19 during Grok ACP containment work).

<!-- applied-learning: a-late-mcp-approval-cannot-retroactively-resume-a-timed-out-coding-owner -->
<a id="applied-learning-a-late-mcp-approval-cannot-retroactively-resume-a-timed-out-coding-owner"></a>
**A late MCP approval cannot retroactively resume a timed-out coding owner.** Coding pipeline approval owners currently wait a bounded 300,000 ms by default. A late MCP `arbor_answer_approval` can successfully resolve the durable IRQ after the owner has timed out and released the pipeline, but it cannot retroactively resume that dead owner. In live r6 on 2026-07-19 America/Chicago, `irq_0f9b88fb1290267d` was created 22:11:09, owner timed out/released at 22:16:09, and the valid bound approval was answered at 22:20:52; no commit occurred. Operational rule: poll/surface delegated approvals well inside the owner timeout and verify the owner resumed/committed, not merely that `answer_approval` returned ok. Architectural follow-up is durable resume/push notification, not an unbounded blocking wait.

<!-- applied-learning: acp-usage-extraction-must-follow-the-provider-s-prompt-result-shape -->
<a id="applied-learning-acp-usage-extraction-must-follow-the-provider-s-prompt-result-shape"></a>
**ACP usage extraction must follow the provider's prompt-result shape.** Prefer the bounded top-level `usage` map; when it is absent, inspect provider metadata such as `_meta.usage`. At the `AcpSession` boundary, use first-present alias semantics, accept only non-negative signed-64 integers, preserve the provider result unchanged, and exercise both cumulative session status and cost accounting. Verify a provider-shape change with a live canary rather than inferring it from zero metrics (found 2026-07-20 when Grok CLI 0.2.106 returned nonzero `inputTokens`/`outputTokens` only under `_meta.usage`, leaving the r8 report at zero before `a459458d`).
<!-- applied-learning: recovery-of-an-uncertain-send-must-preserve-the-logical-turn-s-original-baseline -->
<a id="applied-learning-recovery-of-an-uncertain-send-must-preserve-the-logical-turn-s-original-baseline"></a>
**Recovery of an uncertain send must preserve the logical turn's original baseline.** An ACP send can edit the workspace before its owner observes inactivity or timeout. Re-fingerprinting after that uncertain send and using the new value as the recovered send's baseline launders real edits into `no_changes`, which can authorize terminal cleanup. Capture the owner-observed fingerprint once before the logical turn, carry it across resume/reopen retries, and let recovery inspection prove existence or build context without rebasing progress authority (found 2026-07-20 when live `task_216707` removed a changed worktree after inactivity recovery).

<!-- applied-learning: queued-control-acceptance-is-not-delivery-and-task-success-cannot-manufacture-the-acknowledgement -->
<a id="applied-learning-queued-control-acceptance-is-not-delivery-and-task-success-cannot-manufacture-the-acknowledgement"></a>
**Queued control acceptance is not delivery, and task success cannot manufacture the acknowledgement.** A same-session follow-up accepted by a busy ACP session may become explicitly not-delivered when that session times out before the prompt runs. Persist the exact control ID, confirm delivery only from the owner that completed that follow-up, safely retry only positive non-delivery against a recovered session, and keep unknown delivery terminally unconfirmed; an unrelated successful outer task is not evidence that the control executed (found 2026-07-20 when `control_850WVUTtkx8jirzj1khYWAVW` was marked delivered without a transcript turn).

<!-- applied-learning: acp-steering-preserves-session-continuity-but-cannot-interrupt-an-active-provider-turn -->
<a id="applied-learning-acp-steering-preserves-session-continuity-but-cannot-interrupt-an-active-provider-turn"></a>
**ACP steering preserves session continuity but cannot interrupt an active provider turn.** Same-session follow-ups are queued behind the current ACP prompt; they inherit session context only after that prompt yields. Do not rely on steering to stop a worker looping inside one long turn. Give delegated tasks bounded checkpoints/yield points, and if correction cannot wait, preserve Git WIP, cancel the owner, and restart from the last trusted commit with the correction in the initial prompt (confirmed 2026-07-20 when three controls remained queued for more than an hour behind `task_239299`).

<!-- applied-learning: treat-provider-account-exhaustion-errors-as-deterministic-routing-failures-not-transport-retries -->
<a id="applied-learning-treat-provider-account-exhaustion-errors-as-deterministic-routing-failures-not-transport-retries"></a>
**Treat provider account-exhaustion errors as deterministic routing failures, not transport retries.** An ACP send that returns provider-authenticated HTTP `403` with explicit team-credit or spending-limit exhaustion will fail again against a replacement session; consuming uncertain-send recovery only delays terminalization and obscures the budget signal. Classify this separately from timeout/disconnect uncertainty, preserve the provider diagnostic, and route to another allowed provider or a budget wait state without replaying the logical turn (found 2026-07-21 when Grok 4.5 `task_323715` exhausted both initial and recovery sends against the same xAI team limit).

<!-- applied-learning: a-provider-startup-notice-is-not-prompt-completion-evidence -->
<a id="applied-learning-a-provider-startup-notice-is-not-prompt-completion-evidence"></a>
**A provider startup notice is not prompt-completion evidence.** Codex Spark ACP can emit a skills-context budget warning as the only `agent_message_chunk`, followed by `end_turn`, without executing tools or addressing the coding prompt; the owner then correctly observes `no_changes`, but the adapter has mislabeled a startup notice as a successful turn. Preserve the raw event sequence, require prompt-correlated completion evidence before accepting warning-only success, and use a canary before routing production work through a newly enabled ACP provider/model (found 2026-07-21 when `task_324547` returned only the 2% skills-budget warning).

<!-- applied-learning: live-dogfood-proves-only-the-code-actually-loaded-on-the-node -->
<a id="applied-learning-live-dogfood-proves-only-the-code-actually-loaded-on-the-node"></a>
**Live dogfood proves only the code actually loaded on the node.** A task built from a candidate `base_ref` changes its isolated worktree, not the TaskStore/ACP modules executing on the already-running server; an older finalizer can therefore report a queued control as delivered even while the candidate confirmation lifecycle was never active. Before treating a live task as regression proof for orchestration infrastructure, verify the loaded module version or restart the node on the candidate, then inspect state fields or events unique to the new contract (found 2026-07-21 while validating queued steering on `task_37765`).
