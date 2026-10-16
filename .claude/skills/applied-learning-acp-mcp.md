# Applied Learning: ACP/MCP and Delegation

Read this when dispatching, steering, approving, resuming, or reviewing delegated ACP/MCP work. Entries retain the behavioral rule and the incident that motivated it.

## Session/update token usage (AcpSession)

`Arbor.AI.AcpSession` records `arbor.provider_usage.v1` from the prompt result
first. When the result carries no usage map, it falls back to `pending_usage`
accumulated from bound `session/update` notifications for that prompt only,
then clears the accumulator so a follow-up cannot inherit those tokens.

Accepted discriminators: ACP schema `usage_update`, plus provider-extension
aliases `usage`, `tokenUsage`, and `token_usage`. Token fields are numbers
only (camelCase and snake_case `input`/`output`/`total`/`cached`); official
context-window `used`/`size` payloads are ignored. Unrelated `sessionUpdate`
kinds that nest a usage-shaped map are ignored.

The cursor-agent test fixture is constructed from the ACP Usage schema
(`usage_update` + `inputTokens`/`outputTokens`/`totalTokens`/`cachedReadTokens`)
because no captured cursor-agent session/update fixture exists in this
repository. `cachedReadTokens` is schema-defined; snake_case aliases are
provider extensions.

## Retained Applied Learning

<!-- applied-learning: do-not-chain-process-owned-workspace-leases-across-standalone-mcp-requests -->
<a id="applied-learning-do-not-chain-process-owned-workspace-leases-across-standalone-mcp-requests"></a>
**Do not chain a process-owned coding workspace lease across standalone MCP requests.** `coding_workspace_acquire` through `arbor_run` has no durable task id, so the lease is owned by the HTTP request process and the next request observes `:not_found` on inspect, committed-change, or review binding. Acquire, use, and release the lease inside one durable `coding_change` task. Never treat an opaque `workspace_id` as authority to recover that lease. Use ordinary Git inspection for a retained worktree that no longer has a live owner. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-08-27.)

<!-- applied-learning: bind-opaque-acp-tool-identities-to-the-code-owned-provider-never-the-display-title -->
<a id="applied-learning-bind-opaque-acp-tool-identities-to-the-code-owned-provider-never-the-display-title"></a>
**Bind opaque ACP tool identities to the code-owned provider, never the display
title.** Some spec-valid native agents emit permission requests containing only
an opaque `toolCallId` and a descriptive title. Thread the session's code-owned
provider into the handler, accept only a documented bounded ID namespace, and
map it to a coarse provider child capability; keep other providers and malformed
IDs denied. Kiro CLI 2.19.1 emits `tooluse_*`, which maps to
`arbor://acp/tool/kiro` without trusting the title (found 2026-08-22 in the
managed Kiro coding canary).

<!-- applied-learning: discover-progressively-disclosed-arbor-mcp-tools-before-declaring-them-unavailable -->
<a id="applied-learning-discover-progressively-disclosed-arbor-mcp-tools-before-declaring-them-unavailable"></a>
**Discover progressively disclosed Arbor MCP tools before declaring them
unavailable.** The client intentionally keeps most Arbor actions out of the
default visible surface to control context size. Query the available tool
registry for `arbor_help`, `arbor_actions`, and `arbor_dispatch_task`; use
`arbor_actions` for the category index and `arbor_help` for one exact schema.
Do not fall back to direct CLI orchestration merely because a specialized action
was not initially listed (found 2026-08-22 while qualifying Kiro ACP dispatch).

<!-- applied-learning: select-acp-models-through-the-provider-s-advertised-protocol-surface -->
<a id="applied-learning-select-acp-models-through-the-provider-s-advertised-protocol-surface"></a>
**Select ACP models through the provider's advertised protocol surface.**
`session/set_config_option` is not interchangeable with ACP's dedicated
`session/set_model`: Kiro CLI 2.19.1 advertises a `models` catalog from
`session/new`, accepts `session/set_model`, and rejects the config-option method
with `-32601`. Bind the strategy per provider, validate the requested id against
the bounded session catalog, and require the method's exact successful response
before marking the model confirmed (found 2026-08-22 in the managed Kiro coding
canary).

<!-- applied-learning: treat-official-acp-registry-membership-as-protocol-discovery-not-executable-provenance -->
<a id="applied-learning-treat-official-acp-registry-membership-as-protocol-discovery-not-executable-provenance"></a>
**Treat official ACP registry membership as protocol discovery, not executable
provenance.** Registry conformance can establish that an entry speaks ACP and
advertises authentication, while its binary distribution still lacks a publisher
digest. Probe an unactivated candidate without credentials in an isolated temporary
home and require verified artifact integrity before publishing a runtime launch
specification. Run platform-signature verification where host trust services are
available: a restricted sandbox can make valid code fail as `invalid` or
`CSSMERR_TP_NOT_TRUSTED` (found 2026-08-22 when sandboxed checks falsely rejected
Apple's `/bin/ls`, notarized Kiro, and Google's Antigravity ACP binary; all verified
correctly outside the sandbox).

<!-- applied-learning: bind-ex-mcp-acp-pending-request-timeouts-at-client-start -->
<a id="applied-learning-bind-ex-mcp-acp-pending-request-timeouts-at-client-start"></a>
**Bind `ExMCP.ACP.Client` pending and handler request timeouts at client start.**
`ex_mcp` 1.0.0-rc.8 defaults `pending_request_timeout` and
`handler_request_timeout` to 30,000 ms. Arbor's prompt `GenServer.call`
timeout is a separate caller deadline; the client `send_after` uses the
init-time pending timeout and returns `:request_timeout` first. Passing a
long `timeout` on `prompt/3` does not raise that ceiling. Set both options
in `AcpSession.configure_client_opts/4` to session-lifetime reviewed
ceilings (coding wall clock / intensive Mix child), not the start-handshake
remainder. Found 2026-08-16 when C3c0.5 Pi design turns died at 32s on
`task_58d8a4cf466dbb167d0e46bf0ab4b765`.

<!-- applied-learning: outer-protocol-deadlines-must-exceed-owned-inner-callback-budgets -->
<a id="applied-learning-outer-protocol-deadlines-must-exceed-owned-inner-callback-budgets"></a>
**Outer protocol deadlines must strictly exceed owned inner callback budgets.**
Do not give an MCP/HTTP transport the same deadline as the action or facade it
wraps: scheduler jitter then lets the transport replace the subsystem's typed
timeout with an opaque `handler_timeout`. Keep the outer bound finite but give
it explicit cleanup/serialization headroom, and test the relationship. Found
2026-08-23 when ExMCP HttpPlug's 10,000 ms default killed Arbor's legitimate
10,000 ms coding-readiness projection; a 30,000 ms HTTP handler bound let the
owned readiness result return in 6.3 seconds.

<!-- applied-learning: build-structured-coding-work-packet-digests-with-the-contract-helper -->
<a id="applied-learning-build-structured-coding-work-packet-digests-with-the-contract-helper"></a>
**Build structured coding WorkPacket digests with the contract helper.**
`Arbor.Contracts.Coding.WorkPacket.digest/1` serializes fields in the contract's
canonical order; generic lexicographic JSON key sorting produces a different
digest even when every value is identical, so coding preflight correctly rejects
it as `digest_mismatch`. Normalize the packet, call the helper, and relay that
exact digest. The helper returns `{:ok, digest}`, not a bare string; pattern-match
the tuple before placing the digest in a plan (reinforced 2026-08-23 during the
P1C-B2C3 correction). Found 2026-07-29 redispatching the interaction-wait correction.
When invoking this pure helper from the shell, use `./bin/mix run --no-start -e`;
plain `mix run` boots the full umbrella before evaluating the expression and can
spend the MCP request window waiting on unrelated runtime services (reinforced
2026-08-22 during P1C-B2B preflight).

<!-- applied-learning: compile-the-exact-structured-coding-plan-before-dispatch -->
<a id="applied-learning-compile-the-exact-structured-coding-plan-before-dispatch"></a>
**Compile the exact coding plan before dispatch.** `Arbor.Contracts.Coding.Plan.new/1` admits the interchange contract. `Arbor.Orchestrator.CodingPlan.Compiler.compile/1` is the executable gate: nonempty `overlays`, a non-nil `budgets.model_cost_usd`, and `budgets.parallelism` other than 1 fail as `{:unsupported_v1_feature, field}` before workspace allocation. Nonempty `rework.stop_conditions` is admitted, and `validation_failed` is compiled into a terminal validation edge rather than another rework. Preflight that exact normalized map. The supported-feature check lives inside `compile/1`, not a `validate_supported_v1/1` helper. A rejection before workspace acquisition is safe to correct and redispatch. MCP admission may surface only `compilation_failed`, so run `compile/1` on the dispatch map first. (Merged 2026-10-16 from 4 entries; first found 2026-07-11, last 2026-07-29.)

<!-- applied-learning: keep-approval-decisions-concise-and-put-detail-in-the-artifact -->
<a id="applied-learning-keep-approval-decisions-concise-and-put-detail-in-the-artifact"></a>
**Keep approval decisions concise and put detail in the artifact.** MCP approval
notes are contract-bounded to 1,024 bytes and reject oversize input; they are
not a second design document. Review the digest-bound artifact, record only the
decisive constraints in the approval note, and keep extended reasoning in the
artifact or review record (found 2026-07-29 reviewing a delegated design
checkpoint).

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
`files` list after retaining a real candidate. The preserved candidate tree OID
and immutable tree contents are authoritative for what changed; the public file
summary is not proof that the tree is empty. Read the task artifact's
`validate/status.json` for the exact action failure before diagnosing or
redispatching; for example, Phase 6 cross-app validation correctly recorded
`{:spawn_backend_unavailable, :production_backend_missing}` only there (found
2026-07-13 reviewing retained Grok candidates; tree-authority lesson reinforced
2026-07-28 when validation terminalized before commit).

<!-- applied-learning: structured-coding-worktree-roots-are-policy-not-a-scratch-directory-preference -->
<a id="applied-learning-structured-coding-worktree-roots-are-policy-not-a-scratch-directory-preference"></a>
**Structured coding worktree roots are policy.** Omit `workspace_policy.worktree_base_dir` unless that override is already an admitted coding root. `Arbor.Orchestrator.CodingPlan.WorkspaceScope` rejects a guessed host temp path before a worker is allocated, as `{:invalid_coding_path, :worktree_base_dir}` or `{:coding_path_outside_roots, :worktree_base_dir}`. Both failures are preflight failures, before workspace allocation. A path that looks like a convenient scratch directory is still denied when it is outside the configured roots. The omitted field uses the configured root. Leave it unset whenever that configured root is acceptable. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-07-15.)

<!-- applied-learning: flat-coding-change-dispatch-does-not-accept-the-full-composite-action-schema -->
<a id="applied-learning-flat-coding-change-dispatch-does-not-accept-the-full-composite-action-schema"></a>
**Flat `coding_change` dispatch does not accept the full composite-action schema.** The strict compatibility envelope accepts only `kind`, `task`, `repo_path`, `acp_agent`, `base_ref`, `branch_name`, `worktree_base_dir`, `open_pr`, and `submit_review`. Action parameters such as `skip_validation`, `validation_commands`, `timeout`, and `inactivity_timeout_ms` fail before workspace allocation with `{:unknown_task_key, key}` even though `coding_produce_reviewable_change` advertises them. Put supported budgets and controls in a versioned direct plan, or omit them from the flat envelope (found 2026-07-15 after two immediate Phase 6 follow-up dispatch failures).

<!-- applied-learning: mcp-approval-answering-is-explicit-capability-authority-not-trust-profile-graduation -->
<a id="applied-learning-mcp-approval-answering-is-explicit-capability-authority-not-trust-profile-graduation"></a>
**MCP approval answering is explicit capability authority, not trust-profile graduation.** `arbor_answer_approval` authorizes `arbor://approval/answer/<principal-or-agent>` through `Arbor.Security.authorize/4` before it mutates the IRQ. A scoped capability grant with no `requires_approval` constraint is enough for that security check; `Arbor.Trust.authorize/4` would still gate it because the high-risk profile projects `arbor://approval/answer` to a `:ask` ceiling. Do not try to relax this with an `:auto` trust rule. Give the local approver an explicit scoped answer capability for the delegated worker/owner approval principal, or a global `arbor://approval/answer` cap only for trusted operator surfaces. A dispatch-minted approval-read lease is exact-task authority: pass that `task_id` to `arbor_list_pending_approvals`; omitting it requires global approval-read and correctly returns unauthorized. When filtering by resource, use the stored coarse `resource_uri` (for example `arbor://shell/exec`) rather than the command-specific target URI (reinforced 2026-08-23 during P1C-B2C3 dispatch).

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

<!-- applied-learning: host-generated-grok-sandbox-profiles-in-runtime-grok-home -->
<a id="applied-learning-host-generated-grok-sandbox-profiles-in-runtime-grok-home"></a>
**Host generated Grok sandbox profiles in the runtime `GROK_HOME`, never the
worktree.** Linux grok/landlock cannot resolve a custom profile that also
denies its own file: it warns `sandbox could not be applied` and continues
unsandboxed, after which worktree `.grok/` reads fail and auth collapses to
`:grok_external_auth_unavailable`. Install `$GROK_HOME/sandbox.toml` (Arbor-
owned, 0700, outside the worker-writable tree), keep denying worktree
`.grok/sandbox.toml`, the Arbor backup, and ambient MCP files, and fail the
launch if pre-launch `grok --sandbox <name> inspect` prints that warning
(stderr, not `grok.log`; exit status is not authoritative). Reuse the same
generated bytes on reconnect; a different pre-existing runtime-home profile
is a conflict (found 2026-08-26, V7-13, `task_13b256be6e742fb6bfe25c1d42c4ccd5`;
inspect gate R7 2026-08-27).

<!-- applied-learning: grok-written-files-inside-a-verified-private-home-must-not-require-umask-022 -->
<a id="applied-learning-grok-written-files-inside-a-verified-private-home-must-not-require-umask-022"></a>
**Grok-written files inside a verified-private `GROK_HOME` must not require umask 022.**
Debian/Ubuntu user-private-group umask 002 creates `auth.json.lock` as 664; macOS
umask 022 creates 644. The directory is already euid-owned 0700, so group/world
bits on inner files grant nothing (same class as V7-10 HOME 0755). Require
regular, `links: 1`, euid ownership, and a size bound; keep 0600 only for files
Arbor writes. Surface `{:grok_external_auth_cache_invalid, %{file, mode}}`
instead of collapsing to `:grok_external_auth_unavailable` (found 2026-08-27,
V7-14, Linux factory run 11l/11m).

<!-- applied-learning: answering-a-top-level-mcp-approval-does-not-currently-make-a-fresh-arbor-run-replay-resumable -->
<a id="applied-learning-answering-a-top-level-mcp-approval-does-not-currently-make-a-fresh-arbor-run-replay-resumable"></a>
**Answering a top-level MCP approval does not currently make a fresh `arbor_run` replay resumable.** `trust_propose_profile` returned a pending IRQ and `arbor_answer_approval` approved it, but calling the same action/params again created a new IRQ because the approved-invocation marker was not carried across requests. Nested owners such as `coding_produce_reviewable_change` work because they remain alive, await the IRQ, and retry with the marker themselves. Top-level gated actions need an async owner or an explicit retry token/context before "answer, then call again" can be relied on (reproduced 2026-07-09).

<!-- applied-learning: prefer-steering-an-active-delegated-acp-worker-for-review-and-rework-reserve-cancellation-for-termination -->
<a id="applied-learning-prefer-steering-an-active-delegated-acp-worker-for-review-and-rework-reserve-cancellation-for-termination"></a>
**Prefer steering an active delegated ACP worker for review and rework; reserve cancellation for termination.** Steering preserves the model context, worktree, and test state. As of 2026-07-09, `coding_produce_reviewable_change` does not expose nested ACP steering, and Session steering cannot interrupt a blocking nested action, so add an explicit task/ACP steering control instead of simulating rework with cancel-and-redispatch. `arbor_cancel_task` must remain hard, deterministic termination.

<!-- applied-learning: verify-the-pinned-mix-wrapper-from-inside-the-actual-delegated-worktree -->
<a id="applied-learning-verify-the-pinned-mix-wrapper-from-inside-the-actual-delegated-worktree"></a>
**Verify the pinned Mix wrapper from inside the actual delegated worktree.** A nested git worktree can inherit a PATH with Homebrew before mise's insertion point; `mise current` still reports the configured versions while `mise exec -- mix` silently selects `/opt/homebrew/bin/mix` and the wrong OTP. `bin/mix` must resolve `mise where erlang` / `mise where elixir`, prepend those exact `bin` directories, and execute that Mix path. Check `./bin/mix --version` in the worktree, not only the parent checkout (found 2026-07-09: parent used Elixir 1.19.5/OTP 28 while the nested worktree used Elixir 1.20.2/OTP 29).

<!-- applied-learning: a-custom-mix-build-directory-must-still-be-ignored-before-a-coding-worker-commits -->
<a id="applied-learning-a-custom-mix-build-directory-must-still-be-ignored-before-a-coding-worker-commits"></a>
**A custom Mix build directory must still be ignored before a coding worker commits.** Names such as `_build_test_owner_outcome` do not necessarily match the repository's ignore rules; a worker that later runs `git add -A` can stage an entire generated build tree and make workspace inspection report irrelevant changes. Prefer the standard ignored `_build`, or verify `git check-ignore` and remove the custom build output before the worker returns (found 2026-07-15 while salvaging the owner-observed outcome delegation).

<!-- applied-learning: verify-delegated-git-refs-as-exact-opaque-values-before-invoking-the-coding-action -->
<a id="applied-learning-verify-delegated-git-refs-as-exact-opaque-values-before-invoking-the-coding-action"></a>
**Verify delegated Git refs as exact opaque values before invoking the coding action.** Do not reconstruct, expand, or concatenate a commit hash while relaying it through an agent prompt. Prefer a verified short hash or stable branch name when either is unambiguous, and run `git rev-parse --verify <ref>^{commit}` before dispatch. A 2026-07-09 correction delegation duplicated part of a full SHA, so `coding_produce_reviewable_change` failed before the ACP worker started.

<!-- applied-learning: do-not-send-long-newline-delimited-mcp-json-frames-through-a-canonical-pty -->
<a id="applied-learning-do-not-send-long-newline-delimited-mcp-json-frames-through-a-canonical-pty"></a>
**Do not send long newline-delimited MCP JSON frames through a canonical PTY.** A terminal's line buffer can truncate or reject a large JSON-RPC request before the stdio signer reads it, which looks like a malformed or missing MCP response. Use a non-TTY client or an existing MCP tool for long dispatch payloads; reserve interactive signer sessions for short diagnostic calls (found 2026-07-10 during the signed steering proof).

<!-- applied-learning: gate-acp-coding-turns-on-trusted-stop-reason-and-per-turn-owner-fingerprints -->
<a id="applied-learning-gate-acp-coding-turns-on-trusted-stop-reason-and-per-turn-owner-fingerprints"></a>
**Gate a coding turn on a trusted stop reason and a per-turn workspace fingerprint.** Require `stop_reason` equal to `end_turn` before workspace inspection. Do not default a missing or blank stop reason to `end_turn`. Treat model-reported `implemented` or `declined` JSON as advisory evidence, not as the branch the graph takes. Compare a fingerprint captured before the send: an initial no-op is `no_changes`, and a rework no-op is `worker_turn_no_progress`, so a prior candidate is not presented again as a fresh empty turn. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-07-15.)

<!-- applied-learning: coding-plan-uses-reviewed-task-class-identifiers-not-informal-scope-labels -->
<a id="applied-learning-coding-plan-uses-reviewed-task-class-identifiers-not-informal-scope-labels"></a>
**Coding Plan uses reviewed task-class identifiers, not informal scope labels.**
`task_class: "simple"` is invalid. Use `"default"` for a narrow ordinary change;
the current reviewed set is `default`, `security_regression`, `contract_change`,
`frontend_visual`, `docs_only`, `cross_app`, and `database_migration` (found
2026-07-10 when a Phase 6 dogfood dispatch failed normalization before startup).
Classify a follow-up by the behavior it introduces, not by the ancestry of the
feature it touches: a fixture/documentation correction on top of a security fix is
normally `default`/direct, because `security_regression` requires a mandatory design
turn and identical test bytes that fail the follow-up's immediate parent. Its
`requested_paths` are exact regression-test selectors, not a write-scope list;
supplying production paths is rejected as `invalid_security_regression_paths`
(found 2026-08-23 after a B2C3 correction was first over-classified, then correctly
redispatched without salvaging its task-owned dirty design worktree). A task class also
selects executable proof, not just a conceptual label: `contract_change` requires a
recognized contract surface, so an internal Orchestrator terminal-publication fix belongs
under `default` even when its prose discusses evidence contracts. If the selected validator
reports that its required surface is absent, cancel before rework; that is a dispatch
classification defect, not an instruction to fabricate an unrelated surface (found
2026-08-31 in `task_f3f37143f3fe6646d7be9a7c4eab1dd2`).

<!-- applied-learning: do-not-verify-against-an-active-worker-s-mutable-worktree -->
<a id="applied-learning-do-not-verify-against-an-active-worker-s-mutable-worktree"></a>
**Do not verify against an active worker's mutable worktree.** A delegated coding loop can rewrite source while an external Mix command is compiling it, producing a mixed-revision build and failures that belong to neither commit. Wait for the worker's committed terminal snapshot or create a detached worktree at the exact commit, then run verification there with an isolated build path (found 2026-07-11 while Grok was applying council rework to security-attestation routing).

<!-- applied-learning: normalized-coding-profile-ids-are-not-proof-that-the-profile-is-executable -->
<a id="applied-learning-normalized-coding-profile-ids-are-not-proof-that-the-profile-is-executable"></a>
**A normalized profile id is not proof the profile is executable.** Treat declared profile ids as discovery. Refuse execution until `Arbor.Orchestrator.CodingPlan.Profiles.fetch_executable/1` returns the profile and every claimed enforcement primitive is present. A selected `_test.exs` file does not by itself prove a security regression fails on the base and passes on the candidate. Keep such a profile undispatchable, with a precise missing-primitive reason, until both sides of that claim are enforced. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-22.)

<!-- applied-learning: check-the-current-branch-after-a-coding-subagent-reports-completion -->
<a id="applied-learning-check-the-current-branch-after-a-coding-subagent-reports-completion"></a>
**Check the current branch after a coding subagent reports completion.** A worker may commit directly to the shared branch rather than returning an external commit for cherry-pick, even when its changes were produced in an isolated execution context. Re-read `git status` and `git log` before integrating another branch so later work is based on the actual HEAD and an incomplete worker commit is corrected forward rather than duplicated (found 2026-07-11 during Agent baseline repair).

<!-- applied-learning: a-managed-acp-handle-lives-only-as-long-as-its-owning-action-unless-an-explicit-durable-owner-retains-it -->
<a id="applied-learning-a-managed-acp-handle-lives-only-as-long-as-its-owning-action-unless-an-explicit-durable-owner-retains-it"></a>
**A managed ACP handle dies with its owning action unless a durable owner retains it.** A standalone session start can report ready and then close the worker during action cleanup, so a later standalone send does not find that session. A still-live outer task or an approval wait does not keep the worker steerable after the implementation node has closed it. Deliver steering while that session is alive. After it closes, resume from an exact committed checkpoint in a new task. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-11.)

<!-- applied-learning: the-public-task-control-facade-remains-usable-when-a-client-has-not-exposed-a-steering-mcp-tool -->
<a id="applied-learning-the-public-task-control-facade-remains-usable-when-a-client-has-not-exposed-a-steering-mcp-tool"></a>
**The public task-control facade remains usable when a client has not exposed a steering MCP tool.** `Arbor.Agent.Orchestration.steer_task/3` still performs exact task/delegator authorization and persists the control through TaskStore; invoke it with the authenticated caller identity through a trusted local RPC surface rather than mutating worker state directly. A control queued as `same_session_follow_up` while ACP is inside a blocking turn is not delivered yet and must remain visibly queued until that session accepts it (found 2026-07-11 steering the commit-approval R3 correction).

<!-- applied-learning: executable-v1-coding-plans-use-workspace-policy-mode-isolated -->
<a id="applied-learning-executable-v1-coding-plans-use-workspace-policy-mode-isolated"></a>
**Executable v1 coding plans use `workspace_policy.mode="isolated"`.** The intuitive value `"new"` is not part of the closed v1 contract and fails before workspace acquisition. The v1 compiler also requires `task_class` to match `validation_profile` (for example both `"cross_app"`); describe additional security-test obligations in the task rather than mixing profile names (found 2026-07-11 dispatching the approval-authority correction).

<!-- applied-learning: term-serialization-bounds-must-include-integer-bit-size-before-encoding -->
<a id="applied-learning-term-serialization-bounds-must-include-integer-bit-size-before-encoding"></a>
**Term serialization bounds must include integer bit size before encoding.** Counting every integer as a fixed scalar lets a hostile bignum allocate megabytes in `term_to_binary/2` before a post-encode byte check can reject it. Bound signed integer magnitude/bit length during the structural walk, then encode only the already bounded term (found 2026-07-11 reviewing execution-proof payloads).

<!-- applied-learning: acp-continuity-requires-the-provider-session-id-not-only-the-managed-worker-handle -->
<a id="applied-learning-acp-continuity-requires-the-provider-session-id-not-only-the-managed-worker-handle"></a>
**ACP continuity requires the provider session ID, not only the managed worker handle.** `worker_session_id` (`acp_worker_*`) is an owner-scoped live registry handle; `acp_close_session` or owner death invalidates it. The ACP provider's `worker.session_id` is the durable conversation identity consumed by `load_session`. A coding graph must opt into pooled execution, preserve/project that provider ID before closing or checking in the worker, and pass it through a later authorized start to resume context. Returning only the closed managed handle is not resumability. When diagnosing an older run, recover the provider ID from the `open_worker/status.json` checkpoint if the public result dropped it (found 2026-07-12 tracing `task_167682`, whose non-pooled graph retained provider session `019f52ad-dfb1-7d33-8156-effae2a1c9fa` only in the checkpoint).

<!-- applied-learning: dispatch-provider-selection-must-satisfy-worker-owned-packet-operations -->
<a id="applied-learning-dispatch-provider-selection-must-satisfy-worker-owned-packet-operations"></a>
**Dispatch provider selection must satisfy worker-owned packet operations.** A
valid Coding Plan and a healthy provider do not prove that the worker can execute
the packet. Grok's `arbor-no-shell` profile intentionally exposes native file
tools but denies terminal execution, so a packet that required generating a
baseline through a Mix command correctly ended with no changes. Before dispatch,
intersect worker-owned mutations and evidence commands with the provider's
attested tool profile. A no-shell worker can still make bounded file edits when
the manager owns later validation, but route command-derived artifact generation
to a shell-capable provider (found 2026-08-11 while freezing the SPIKE-3B
source-coupling baseline).

<!-- applied-learning: preserve-a-stalled-delegated-worktree-before-starting-a-replacement-worker -->
<a id="applied-learning-preserve-a-stalled-delegated-worktree-before-starting-a-replacement-worker"></a>
**Preserve a stalled delegated worktree before starting a replacement worker.** When an ACP run exits with useful uncommitted changes, use `git stash create` to capture the tracked work without altering the retained worker directory, then point a named preservation branch at that commit. A correction can start from the exact preserved state while the original workspace remains available for diagnosis and provider-session recovery (adopted 2026-07-13 after the spawn-containment R10 worker transport failed).

<!-- applied-learning: a-structured-coding-dispatch-has-a-closed-two-level-envelope -->
<a id="applied-learning-a-structured-coding-dispatch-has-a-closed-two-level-envelope"></a>
**Structured coding dispatch has a closed envelope.** `Arbor.Orchestrator.CodingPlan.Normalizer.normalize_task/1` accepts `{"kind":"coding_change","plan":...}`, whose only direct keys are `kind` and `plan`, or the legacy flat `coding_change` keys. Workspace, worker, review, rework, budgets, and output belong inside the versioned plan. A bare plan or an `{action, params}` wrapper is not that envelope: without `kind` it falls through to the chat runner, and a map with no text field fails `:missing_task_input`. `coding_produce_reviewable_change` is not a dispatch envelope. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-14.)

<!-- applied-learning: the-coding-security-regression-profile-treats-requested-paths-as-test-paths -->
<a id="applied-learning-the-coding-security-regression-profile-treats-requested-paths-as-test-paths"></a>
**Security-regression requested paths are test selectors.** The executable `security_regression` profile requires a non-empty `requested_paths` list of files ending in `_test.exs`. Any other selection, including an empty list, fails as `{:invalid_security_regression_paths, ...}` before workspace allocation. The validator copies and runs only those paths against the base and the candidate, so put every public behavioral proof in one of them before dispatch. Use this profile when those tests should fail on the parent. A fixture-only repair with unchanged production belongs on ordinary validation. Keep candidate-controlled stdout out of automatic rework prompts; trusted proof uses the formatter artifact. (Merged 2026-10-16 from 4 entries; first found 2026-07-11, last 2026-07-14.)

<!-- applied-learning: use-the-structured-coding-envelope-for-durable-acp-delegation -->
<a id="applied-learning-use-the-structured-coding-envelope-for-durable-acp-delegation"></a>
**Give long coding work an asynchronous owner.** A plain `arbor_dispatch_task` prompt takes the agent's chat path, and naming a coding action does not select the coding executor. Standalone `arbor_run` makes the HTTP request the owner, so request teardown kills the worker and can return an empty failure after the worker has already started. Dispatch `{"kind":"coding_change","plan":...}` and drive status, steering, approvals, and result through the task. Use `arbor_run` only for bounded actions. Put a long action that belongs inside a workflow on a compiled DOT node. A long canary needs an unlinked async owner and durable status before polling. (Merged 2026-10-16 from 4 entries; first found 2026-07-14, last 2026-07-19.)

<!-- applied-learning: distinguish-backend-availability-from-host-admission-in-structured-coding-validation -->
<a id="applied-learning-distinguish-backend-availability-from-host-admission-in-structured-coding-validation"></a>
**Distinguish backend availability from host admission in structured coding validation.** Before `f4b675a2`, the default coding profile correctly stopped at `production_backend_missing`; retained `validation_failed` tasks from that bootstrap period can still contain useful committed changes worth independent review. The facade is now open, so new runs must not be assumed red for that sentinel. On an unprovisioned host, a valid request instead fails admission before registration (for example `:executable_not_found` when the accepted `/usr/local` signed-installer assets are absent). Do not weaken the validation profile or path/signature policy; identify whether the failure is stale loaded code, missing host authority, or candidate behavior (updated 2026-07-15 after the live facade proof).

<!-- applied-learning: independently-test-retained-worker-commits-with-a-fresh-build-path -->
<a id="applied-learning-independently-test-retained-worker-commits-with-a-fresh-build-path"></a>
**Test a retained worker commit with a fresh build path.** Share only the canonical checkout's `MIX_DEPS_PATH`. Use a fresh reviewer-owned `MIX_BUILD_PATH` for each compile-time adapter mode. A Postgres `ARBOR_DB` build and the default SQLite test mode do not share a `_build`. Reusing the worker build can fail on adapter mismatch and says nothing about the candidate source. Keep that reviewer build outside any suite that derives repository identity from loaded BEAM paths. (Merged 2026-10-16 from 2 entries; first found 2026-07-13, last 2026-07-14.)

<!-- applied-learning: run-composition-tests-after-disjoint-delegated-contract-changes -->
<a id="applied-learning-run-composition-tests-after-disjoint-delegated-contract-changes"></a>
**Run composition tests after disjoint delegated contract changes.** Two workers can each produce a clean focused commit while a parent aggregate fixture or consumer remains on the prior required shape. Compose the commits in an isolated review worktree and run the child plus every direct consumer before integration; the Apple launchd evidence expansion passed its own tests but initially left 14 aggregate admission tests failing at the newly required `launchd.path` field (found 2026-07-14 combining the Phase 6 Apple admission slices). Reinforced 2026-09-02 when canonical design-context admission and retained-workspace review resume each passed focused suites, but the exact CrossApp batch exposed one stale direct-call fixture and one stale pre-resume public-boundary expectation.

<!-- applied-learning: inspect-a-retained-coding-workspace-independently-of-the-terminal-task-verdict -->
<a id="applied-learning-inspect-a-retained-coding-workspace-independently-of-the-terminal-task-verdict"></a>
**Inspect a retained coding workspace independently of the terminal task verdict.** A clean worktree, a failed outer task, or a worker protocol error does not prove the Git outcome. A worker can commit while status is empty, and a timeout or protocol failure can happen after that commit. Capture the acquired base and treat a dirty tree or a `HEAD` that differs from that base as a change. Compare the retained worktree and requested branch before cherry-pick, salvage, or redispatch. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-14.)

<!-- applied-learning: checkpoint-a-substantial-delegated-patch-before-diagnosing-test-infrastructure -->
<a id="applied-learning-checkpoint-a-substantial-delegated-patch-before-diagnosing-test-infrastructure"></a>
**Checkpoint a substantial delegated patch before diagnosing test infrastructure.** A structured coding worker that returns `declined` triggers normal workspace removal; useful tracked edits disappear if they were never committed, even when the outer task still had ample time. For a correction likely to consume most of one ACP turn, require an early formatted checkpoint commit, then run focused tests from the repository root and correct forward. An `eaddrinuse`, missing app-scoped dependency path, or intentionally unavailable backend is validation evidence, not a reason to leave the implementation ephemeral (found 2026-07-14 when `task_158723` drafted the Apple unit-worker F1-F9 corrections and then removed its uncommitted worktree).

<!-- applied-learning: map-decoding-can-erase-duplicate-json-members-before-closed-schema-validation -->
<a id="applied-learning-map-decoding-can-erase-duplicate-json-members-before-closed-schema-validation"></a>
**Map decoding can erase duplicate JSON members before closed-schema validation.** Jason's normal map mode keeps only one value for repeated keys, so a durable record with two `active` or `token` members may look valid after decode while evidence was discarded. Decode security-critical durable JSON as ordered objects, reject duplicate members recursively under a depth/size bound, then convert to maps for the ordinary closed core (found 2026-07-14 reviewing the Apple unit-intent journal).

Use the same rule for signed request objects and authenticated response
envelopes. A client-side correlation check cannot detect conflicting
`agent_id` members once map decoding has discarded one. Test both key orders
through a supported public operation and retain a successful predecessor
happy path (2026-10-03 conversation SDK and remote adapter regressions).

<!-- applied-learning: owner-death-must-preserve-coding-workspaces-even-when-currently-pristine -->
<a id="applied-learning-owner-death-must-preserve-coding-workspaces-even-when-currently-pristine"></a>
**Owner death must preserve coding workspaces, even when currently pristine.** TaskStore hard cancellation kills the coding owner, but an external ACP worker can outlive it and write after any inspect-then-remove check. `WorkspaceLeaseRegistry` therefore never treats unexpected owner death as immediate deletion authority: reused paths survive, and every owned path converts to the existing identity-pinned, bounded-TTL retained lease for exact task+principal reactivation. Identity uncertainty is a non-destructive authorized quarantine with retry, not deletion authority. Explicit release and verified TTL expiry remain the deletion paths (fixed 2026-07-15 after cancellation destroyed an uncommitted coding patch).

<!-- applied-learning: an-acp-provider-session-is-not-a-durable-workspace-continuation-by-itself -->
<a id="applied-learning-an-acp-provider-session-is-not-a-durable-workspace-continuation-by-itself"></a>
**An ACP provider session is not a durable workspace continuation.** A provider session id does not carry the worktree. Resume that returns `FS_NOT_FOUND` means the session is still bound to its original path, even when the conversation id and both worktrees exist. Try that exact resume once, then re-dispatch a fresh conversation from the retained Git commit. Do not attach a new worktree to an old Grok session unless the path can reopen the original workspace. Commit continuity is the recovery invariant. (Merged 2026-10-16 from 2 entries; first found 2026-07-13, last 2026-07-15.)

<!-- applied-learning: a-process-started-with-start-link-through-erpc-inherits-the-short-lived-rpc-worker-s-lifetime -->
<a id="applied-learning-a-process-started-with-start-link-through-erpc-inherits-the-short-lived-rpc-worker-s-lifetime"></a>
**A process started with `start_link` through `:erpc` inherits the short-lived RPC worker's lifetime.** Starting a remote long-lived service inside `:erpc.call/4` links it to the transient RPC server process, so it can disappear as soon as the call returns and later authorization looks mysteriously empty. Start it under a stable remote supervisor or explicitly unlink the returned PID before the RPC worker exits, then assert the registered process remains alive from a second RPC call (found 2026-07-15 building the real L4 multi-BEAM recovery proof).

<!-- applied-learning: verify-the-running-checkout-before-live-mcp-dogfood -->
<a id="applied-learning-verify-the-running-checkout-before-live-mcp-dogfood"></a>
**Verify the running checkout before live MCP dogfood.** `mix arbor.recompile` executes `IEx.Helpers.recompile/0` in the running node's own working directory; it does not load source or `priv/` assets from the shell that invoked the RPC. A long-lived node may run from a detached runtime worktree far behind `main`, making a new task archive a stale DOT graph even after recompile reports success. Check `Arbor.Orchestrator.Config.coding_pipeline_path/0` and the runtime worktree HEAD before attributing live behavior to current source (found 2026-07-15 while verifying coding protocol hardening).

<!-- applied-learning: normalize-explicit-acp-wire-aliases-never-replace-a-missing-terminal-fact -->
<a id="applied-learning-normalize-explicit-acp-wire-aliases-never-replace-a-missing-terminal-fact"></a>
**Normalize explicit ACP wire aliases; never replace a missing terminal fact.** ExMCP prompt results use camelCase `stopReason`, while streamed completion notifications can expose snake_case `stop_reason`. Normalize both spellings at the action boundary and regress each explicit form, but keep a genuinely missing/blank stop reason missing so the owner graph fails closed (found 2026-07-15 in the live Grok coding pipeline).

<!-- applied-learning: the-mcp-task-timeout-does-not-replace-a-structured-coding-plan-s-wall-clock-budget -->
<a id="applied-learning-the-mcp-task-timeout-does-not-replace-a-structured-coding-plan-s-wall-clock-budget"></a>
**The outer task timeout does not replace the plan wall clock.** `arbor_dispatch_task` timeout bounds the whole asynchronous task. `plan.budgets.wall_clock_ms` bounds the compiled coding graph and defaults to 900000 ms when omitted. `Arbor.Orchestrator.CodingTaskExecutor` uses the minimum of the plan budget and a positive outer timeout, so a larger outer timeout cannot extend an omitted plan budget, and a shorter one can cancel the graph during implementation. Omit the outer timeout unless it is intentionally tighter than the reviewed plan budget. (Merged 2026-10-16 from 3 entries; first found 2026-07-14, last 2026-07-18.)

<!-- applied-learning: a-schema-valid-coding-review-profile-may-still-be-forbidden-for-the-target-agent -->
<a id="applied-learning-a-schema-valid-coding-review-profile-may-still-be-forbidden-for-the-target-agent"></a>
**A schema-valid review profile may still be forbidden for the target agent.** `review_profile` `none` can exist in `Arbor.Contracts.Coding.Plan` and still be rejected before workspace allocation as `{:coding_plan_review_profile_not_allowed, "none"}`. Contract normalization is not authority. Use the target's reviewed profile, normally `binding`, or `human_required` when the local delegator performs the binding review. Do not select `none` to avoid reviewer cost. A `security_regression` plan paired with `none` is a separate rejection, `{:security_regression_review_profile_not_allowed, "none"}`. (Merged 2026-10-16 from 2 entries; first found 2026-07-13, last 2026-07-16.)

<!-- applied-learning: task-handles-are-currently-less-durable-than-retained-coding-workspaces -->
<a id="applied-learning-task-handles-are-currently-less-durable-than-retained-coding-workspaces"></a>
**Task handles are currently less durable than retained coding workspaces.** After a full server restart, an earlier task ID returned `:not_found` while its retained Git workspace evidence still existed. Until TaskStore persistence is implemented and proven, record task results before restart and use the durable workspace journal plus commit identity for recovery; do not describe the public task handle itself as crash-durable (found 2026-07-17 during Phase 6 dogfood).

<!-- applied-learning: structured-coding-plan-resume-fields-are-a-paired-identity-not-a-boolean-switch -->
<a id="applied-learning-structured-coding-plan-resume-fields-are-a-paired-identity-not-a-boolean-switch"></a>
**Coding-plan resume fields are a paired provider identity.** Omit `worker.resume_provider` and `worker.resume_session_id` together, or set both. `resume_provider` must equal `worker.provider`. `Arbor.Contracts.Coding.Plan.new/1` rejects a missing partner with `{:missing_field, ...}` and a provider mismatch with `{:invalid_field, "worker.resume_provider", {:must_match, ...}}`. A boolean fails plan construction before workspace allocation. Omit both for a fresh pooled worker. Setting only one field is a construction error, not a request to resume the latest session of that provider. (Merged 2026-10-16 from 2 entries; first found 2026-07-14, last 2026-07-17.)

<!-- applied-learning: acp-rework-continuity-and-acp-tool-completion-are-separate-contracts -->
<a id="applied-learning-acp-rework-continuity-and-acp-tool-completion-are-separate-contracts"></a>
**ACP rework continuity and ACP tool completion are separate contracts.** A rework prompt can reach the same provider session successfully, yet a follow-up terminal tool call can end with `stop_reason: cancelled` before execution; treating every non-`end_turn` stop as an immediate pipeline error loses otherwise-valid workspace progress. Inspect the retained transcript and workspace before restarting, and keep the rework turn alive until ACP client tool execution or denial reaches a settled terminal state (found 2026-07-17 after returning a formatting-only review finding to Grok).

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

<!-- applied-learning: design-checkpoint-rework-can-exhaust-provider-session-continuity-before-implementation -->
<a id="applied-learning-design-checkpoint-rework-can-exhaust-provider-session-continuity-before-implementation"></a>
**Design-checkpoint rework can exhaust provider-session continuity before implementation.** A pooled worker may complete the original and revised design turns, then exit before the approved implementation prompt; recovery can terminalize as `worker_recovery_reopen_failed` with `retry: new_session` while the retained workspace is still clean. Verify the workspace and transcript, then redispatch the exact frozen packet plus accepted design corrections in a fresh session. Do not wait on the dead provider process or claim implementation progress from approved design artifacts alone (found 2026-07-30 in `task_545761ac0ba110c6da1af9365594ef18`).

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

<!-- applied-learning: provider-tool-identities-differ-across-acp-layers -->
<a id="applied-learning-provider-tool-identities-differ-across-acp-layers"></a>
**Provider tool identities differ across ACP layers.** Grok's internal terminal ID is `run_terminal_cmd`, while the ACP client-visible name is `run_terminal_command`; ACP tool kind `execute` is a category, not a reliable provider tool ID. Authorize and deny using the machine-readable identity at the layer being tested, rather than inferring one name from another (found 2026-07-19 during Grok ACP containment work).

<!-- applied-learning: acp-http-mcp-descriptors-must-use-the-standard-wire-shape -->
<a id="applied-learning-acp-http-mcp-descriptors-must-use-the-standard-wire-shape"></a>
**ACP HTTP MCP descriptors must use the standard wire shape.** Send descriptors as `type`/`name`/`url`/`headers`; Grok rejects the legacy `uri`/`name` map during `session/new`, before the MCP tool path can be tested (found 2026-07-19 during Grok ACP containment work).

<!-- applied-learning: a-late-mcp-approval-cannot-retroactively-resume-a-timed-out-coding-owner -->
<a id="applied-learning-a-late-mcp-approval-cannot-retroactively-resume-a-timed-out-coding-owner"></a>
**A late MCP approval cannot retroactively resume a timed-out coding owner.** On 2026-07-19, coding pipeline approval owners waited a bounded 300,000 ms by default. A late MCP `arbor_answer_approval` can successfully resolve the durable IRQ after the owner has timed out and released the pipeline, but it cannot retroactively resume that dead owner. In live r6 on 2026-07-19 America/Chicago, `irq_0f9b88fb1290267d` was created 22:11:09, owner timed out/released at 22:16:09, and the valid bound approval was answered at 22:20:52; no commit occurred. Operational rule: poll/surface delegated approvals well inside the owner timeout and verify the owner resumed/committed, not merely that `answer_approval` returned ok. Architectural follow-up is durable resume/push notification, not an unbounded blocking wait.

A durable task does not wake an external coding harness after its turn ends. Keep the supervising turn open with timed polling through actionable gates, or establish and verify an actual wake-up mechanism before ending it; never imply an unarmed background watcher exists. On 2026-09-07, ending the provider-setup turn left J0 at its 22:41 UTC commit approval until the user prompted again. Record this as a manager continuity failure, not a factory execution stall.

The same distinction applies to collaborator messaging: `send_message` queues
context but does not start an idle or completed agent. Use `followup_task` for
the next work slice and confirm the agent is running before reporting that work
is underway (2026-09-29: voice compatibility follow-up messages remained queued
after the worker had completed its previous patch).

Repeated on 2026-10-05: hook-closure work requests sent to the completed DEV
Breeze preparation worker stayed queued until a new `followup_task` opened a
turn. Check the actual collaborator runtime state before reporting progress;
a successful `send_message` receipt confirms queued context, not that the next
work slice has started.

<!-- applied-learning: acp-usage-extraction-must-follow-the-provider-s-prompt-result-shape -->
<a id="applied-learning-acp-usage-extraction-must-follow-the-provider-s-prompt-result-shape"></a>
**ACP usage extraction must follow the provider's prompt-result shape.** Prefer the bounded top-level `usage` map; when it is absent, inspect provider metadata such as `_meta.usage`. At the `AcpSession` boundary, use first-present alias semantics, accept only non-negative signed-64 integers, preserve the provider result unchanged, and exercise both cumulative session status and cost accounting. Verify a provider-shape change with a live canary rather than inferring it from zero metrics (found 2026-07-20 when Grok CLI 0.2.106 returned nonzero `inputTokens`/`outputTokens` only under `_meta.usage`, leaving the r8 report at zero before `a459458d`).
<!-- applied-learning: recovery-of-an-uncertain-send-must-preserve-the-logical-turn-s-original-baseline -->
<a id="applied-learning-recovery-of-an-uncertain-send-must-preserve-the-logical-turn-s-original-baseline"></a>
**Recovery of an uncertain send must preserve the logical turn's original baseline.** An ACP send can edit the workspace before its owner observes inactivity or timeout. Re-fingerprinting after that uncertain send and using the new value as the recovered send's baseline launders real edits into `no_changes`, which can authorize terminal cleanup. Capture the owner-observed fingerprint once before the logical turn, carry it across resume/reopen retries, and let recovery inspection prove existence or build context without rebasing progress authority (found 2026-07-20 when live `task_216707` removed a changed worktree after inactivity recovery).

<!-- applied-learning: queued-control-acceptance-is-not-delivery-and-task-success-cannot-manufacture-the-acknowledgement -->
<a id="applied-learning-queued-control-acceptance-is-not-delivery-and-task-success-cannot-manufacture-the-acknowledgement"></a>
**Queued steering acceptance is not delivery.** An accepted control must not stay `queued` after its owner exits. Confirm delivery only from the owner that completed that follow-up. Unknown delivery is the terminal status `delivery_unconfirmed`, and that status is not proof the follow-up was absent, so inspect the transcript and Git before retrying. Replay only the store's bounded same-id path after positive non-delivery; do not replay an ambiguous control id, and do not treat an unrelated task success as the acknowledgement. Same-session follow-ups stay queued behind the active provider turn, so `queued` or `deferred` does not mean the workspace changed. If the correction cannot wait, cancel the owner and restart from the last trusted commit with the correction in the initial prompt. (Merged 2026-10-16 from 6 entries; first found 2026-07-10, last 2026-07-20.)

<!-- applied-learning: a-provider-startup-notice-is-not-prompt-completion-evidence -->
<a id="applied-learning-a-provider-startup-notice-is-not-prompt-completion-evidence"></a>
**A provider startup notice is not prompt-completion evidence.** Codex Spark ACP can emit a skills-context budget warning as the only `agent_message_chunk`, followed by `end_turn`, without executing tools or addressing the coding prompt; the owner then correctly observes `no_changes`, but the adapter has mislabeled a startup notice as a successful turn. Preserve the raw event sequence, require prompt-correlated completion evidence before accepting warning-only success, and use a canary before routing production work through a newly enabled ACP provider/model (found 2026-07-21 when `task_324547` returned only the 2% skills-budget warning).

<!-- applied-learning: live-dogfood-proves-only-the-code-actually-loaded-on-the-node -->
<a id="applied-learning-live-dogfood-proves-only-the-code-actually-loaded-on-the-node"></a>
**Live dogfood proves only the code actually loaded on the node.** A task built from a candidate `base_ref` changes its isolated worktree, not the TaskStore/ACP modules executing on the already-running server; an older finalizer can therefore report a queued control as delivered even while the candidate confirmation lifecycle was never active. Before treating a live task as regression proof for orchestration infrastructure, verify the loaded module version or restart the node on the candidate, then inspect state fields or events unique to the new contract (found 2026-07-21 while validating queued steering on `task_37765`).

<!-- applied-learning: cross-worktree-provider-resume-needs-provider-native-root-compatibility -->
<a id="applied-learning-cross-worktree-provider-resume-needs-provider-native-root-compatibility"></a>
**Cross-worktree provider resume needs provider-native root compatibility.** Rebinding Arbor's ACP handler and OS process cwd to a replacement worktree does not necessarily rebind a resumed provider conversation's own workspace authority. OpenCode retained the original session directory, classified a read-only Git command in the replacement worktree as `external_directory`, and waited on a native permission request that never reached Arbor. Before moving a conversation, verify the provider-reported session directory. If it cannot be rebound, checkpoint the exact dirty diff, start a fresh provider session from the original review base, and apply the checkpoint without its WIP commit so cumulative validation and review still cover every change (found 2026-07-21 recovering `task_737730` through `task_921666` and `task_953218`).

<!-- applied-learning: requested-acp-model-metadata-is-a-claim-until-the-provider-confirms-it -->
<a id="applied-learning-requested-acp-model-metadata-is-a-claim-until-the-provider-confirms-it"></a>
**Requested ACP model metadata is a claim until the provider confirms it.** A managed session can report the plan's requested model while the provider actually runs its default: OpenCode started `task_953218` on `opencode/big-pickle` even though Arbor's action result said `zai-coding-plan/glm-5.2`. Verify provider-native session or turn telemetry before attributing work or cost. When model selection is explicit, the start boundary should wait for and validate the selector response, then fail closed on rejection or mismatch instead of silently preserving requested metadata. For config-selectable providers, inspect the validated `AcpSession.status/1` model after selection; the original `session/new` response may still show its pre-selection catalog default. Select only values advertised by the live ACP `configOptions[].options[].value` catalog: provider CLI aliases can be rejected even when their underlying model exists. Do not rely on Cursor `auto` for architecture-heavy work; on 2026-08-21 it resolved to Haiku 4.5 and repeatedly missed load-bearing boundedness and sealing constraints. Explicit `gpt-5.6-sol-high` preserved the regression matrix, designed the cross-library deadline boundary correctly, and passed independent review; use an explicit high-reasoning model for architecture or security packets and reserve medium tiers for tightly bounded edits (found 2026-07-21 during managed-branch lifecycle integration; reconfirmed with Codex Spark on 2026-07-24 and Cursor on 2026-08-21).

<!-- applied-learning: claude-acp-resume-is-launch-bound-and-model-aliases-need-live-attestation -->
<a id="applied-learning-claude-acp-resume-is-launch-bound-and-model-aliases-need-live-attestation"></a>
**Claude ACP resume is launch-bound, and model aliases need live attestation.** Pass an explicit Claude provider session through native `--resume` before pool checkout and child startup; a post-launch `session/load` cannot rebind the already-running subprocess. Preserve sibling adapter options and reject malformed or conflicting resume configuration before spawning. Treat aliases such as `sonnet` as requests until the live adapter confirms the resolved model; on 2026-07-27 it resolved to `claude-sonnet-5` and provided a viable coding fallback while Grok credits were exhausted (found while repairing and proving managed Claude session continuity).

<!-- applied-learning: launch-bound-acp-models-must-be-attested-not-inferred-from-method-not-found -->
<a id="applied-learning-launch-bound-acp-models-must-be-attested-not-inferred-from-method-not-found"></a>
**Launch-bound ACP models must be attested, not inferred from `Method not found`.** Some native ACP servers bind an exact model in launch argv but do not implement `session/set_config_option`. Skip dynamic confirmation only when an independent fail-closed launch policy attests the exact requested model; reject mismatches before launch and keep an unsupported config RPC fatal for dynamically selectable providers. Never turn JSON-RPC `-32601` into generic model-selection success (found 2026-07-21 when Grok 4.5 created a valid pooled provider session but rejected Arbor's post-creation config RPC).

<!-- applied-learning: readiness-and-execution-must-share-the-same-canonicalizer -->
<a id="applied-learning-readiness-and-execution-must-share-the-same-canonicalizer"></a>
**Readiness and execution must share the same canonicalizer.** A preflight that merely proves a requested repository path is an existing directory inside an admitted root can report success even though execution later rejects it because it is not a Git repository, resolves to a different Git top-level, or chooses a different default worktree root. Extract the exact non-mutating workspace-scope normalization used by execution, bind the readiness digest to its canonical plan, and regress a plain directory plus a nested Git path through both entry points. Duplicating a weaker approximation creates false-green readiness evidence (found 2026-07-22 while reviewing the first static coding-readiness slice).

<!-- applied-learning: treat-acp-streamed-text-as-transcript-evidence-not-a-terminal-structured-envelope -->
<a id="applied-learning-treat-acp-streamed-text-as-transcript-evidence-not-a-terminal-structured-envelope"></a>
**Treat streamed ACP text as transcript evidence, not as the terminal control envelope.** Accept one unique structured envelope, tolerate identical duplicates, and reject conflicting or malformed envelopes. Progress chunks, compaction notices, and a duplicated final payload stay in the transcript. When the terminal result carries validated provider-canonical text, prefer that text over a concatenated chunk accumulator. A rejected balanced composite is indivisible: resume after its closing delimiter, and reject an unbalanced remainder. Do not weaken generic JSON parsing so one provider transcript passes. (Merged 2026-10-16 from 2 entries; first found 2026-07-26, last 2026-07-29.)

<!-- applied-learning: durable-interaction-metadata-must-be-json-clean-before-persistence -->
<a id="applied-learning-durable-interaction-metadata-must-be-json-clean-before-persistence"></a>
**Durable interaction metadata must be JSON-clean before persistence.** In-memory
approval and consensus paths may use atom keys, atom decisions, and `%DateTime{}`
values, but a durable interaction crosses a JSON serialization boundary. Construct
its metadata explicitly with string keys, closed-enum strings, and ISO 8601
timestamps; do not reuse a richer in-memory map or rely on recursive cleanup after
the fact. Regress both JSON encoding and the public answer normalizer so persistence
success also proves the decision and note survive the round trip (found 2026-07-26
when a design-checkpoint rework answer failed as `:durable_unavailable`).

<!-- applied-learning: provider-spend-limit-notices-are-not-successful-no-change-turns -->
<a id="applied-learning-provider-spend-limit-notices-are-not-successful-no-change-turns"></a>
**Provider account exhaustion is a typed routing failure, not a successful empty turn.** Exact provider evidence of account or spend-limit exhaustion, including HTTP 402 or 403 and a spend-limit notice that surfaces as `end_turn` with an untouched workspace, is `worker_provider_account_exhausted`. Do not spend uncertain-send recovery on that evidence, and do not record it as `no_changes`. Preserve the provider session id in the terminal evidence. Generic permission failures and unrecognized notices keep uncertain-send handling. Route to another allowed provider or a budget wait, without replaying the logical turn into the exhausted account. (Merged 2026-10-16 from 2 entries; first found 2026-07-21, last 2026-07-27.)

<!-- applied-learning: validate-closed-typed-envelopes-before-generic-json-canonicalization -->
<a id="applied-learning-validate-closed-typed-envelopes-before-generic-json-canonicalization"></a>
**Validate closed typed envelopes before generic JSON canonicalization.** A generic
canonicalizer can convert atom keys into accepted string keys and recursively walk
an attacker-sized payload before the typed contract applies its field and byte
bounds. Validate the raw closed shape and bounded component contracts first,
require equality with the canonical representation, and only then perform a JSON
round trip on that small canonical object (found 2026-07-27 while reviewing typed
coding-plan admission failures).

<!-- applied-learning: coding-task-adoption-is-post-integration-settlement-not-git-integration -->
<a id="applied-learning-coding-task-adoption-is-post-integration-settlement-not-git-integration"></a>
**Coding-task adoption is post-integration settlement, not Git integration.**
First integrate the reviewed candidate through the operator or merge system by
fast-forward, cherry-pick, or squash; only then call `adopt_task_change/3` or
`arbor_adopt_task_change`. The API proves ancestry or bounded patch equivalence,
archives immutable evidence, and retires only the exact owned resources. It
deliberately does not move the destination ref, so calling it before integration
must fail as `:not_adopted` (found 2026-07-28 when the Phase C canary correctly
returned `:aggregate_patch_not_found` before its reviewed commit reached `main`).

<!-- applied-learning: synchronous-mcp-mutations-must-converge-before-the-transport-deadline -->
<a id="applied-learning-synchronous-mcp-mutations-must-converge-before-the-transport-deadline"></a>
**Synchronous MCP mutations must converge before the transport deadline.** If the
MCP server has a shorter fixed call timeout than an owned operation's worst-case
duration, start the mutation exactly once, wait only within a smaller product
budget, then reconcile the authoritative owner state and return a typed
pending, settled, or failed receipt. Never let an ambiguous transport timeout invite
the caller to replay the mutation; retries may poll or coalesce against the exact
destination and result fingerprint but may not create a second owner (found
2026-07-28 when adoption completed in `TaskStore` after ExMCP had already returned
an empty HTTP 500).

<!-- applied-learning: compute-generated-artifact-digests-at-the-owned-admission-boundary -->
<a id="applied-learning-compute-generated-artifact-digests-at-the-owned-admission-boundary"></a>
**Compute generated-artifact digests at the owned admission boundary.** A worker
that authors a design controls both its text and any self-reported digest, so asking
the model to calculate SHA-256 adds no authority or tamper resistance. Parse the
closed bounded text envelope, compute its digest inside Arbor, and bind approval and
execution to that server-owned result. Requiring model-computed integrity fields
only creates an expensive protocol-repair failure mode (found 2026-07-28 when Grok
returned the empty-string digest for an 8,378-byte Phase E design).

<!-- applied-learning: repair-prompts-must-cover-every-admission-defect-the-retry-can-correct -->
<a id="applied-learning-repair-prompts-must-cover-every-admission-defect-the-retry-can-correct"></a>
**Repair prompts must cover every admission defect the retry can correct.** A
generic instruction to preserve content and repair only its envelope cannot
recover when the decoded payload itself exceeds a bounded contract. State the
closed schema, exact hard limit, and a conservative target, and explicitly
permit condensation when size is one possible rejection reason. Regress an
oversized first turn through the same worker session to a bounded admitted
repair; a malformed-JSON-only fixture does not prove size recovery (found
2026-07-28 after Grok reduced a 23,806-byte design only to 20,382 bytes because
the repair prompt never disclosed Arbor's 16,384-byte limit).

<!-- applied-learning: compute-work-packet-digests-through-the-contract -->
<a id="applied-learning-compute-work-packet-digests-through-the-contract"></a>
**Compute work-packet digests through the contract, not a generic JSON encoder.**
`Arbor.Contracts.Coding.WorkPacket` uses a fixed schema field order for canonical
bytes; lexicographically sorting object keys produces a different SHA-256 even
when the packet values are identical. Construct the exact packet and call
`WorkPacket.digest/1`, then submit that returned `sha256:` value unchanged. A
digest mismatch is a typed plan-admission failure and should consume no worker
resources (found 2026-07-28 while dispatching the security-regression
attestation preflight correction).

<!-- applied-learning: preflight-security-regression-selectors-before-reviewer-egress -->
<a id="applied-learning-preflight-security-regression-selectors-before-reviewer-egress"></a>
**Preflight security-regression selectors before reviewer egress.** A `security_regression` plan must bind the exact test paths in `requested_paths`. Naming them only in required evidence does not satisfy admission. Materialize the candidate commit and prove each bounded path exists in that commit before any council call. A missing selector is an Arbor readiness defect. Return a bounded path-aware reason, discard the preflight material, and rematerialize after a keep verdict so the final attestation still binds the reviewed diff. (Merged 2026-10-16 from 2 entries; first found 2026-07-28, last 2026-07-30.)

<!-- applied-learning: budget-design-required-plans-for-the-design-and-the-reserved-tail -->
<a id="applied-learning-budget-design-required-plans-for-the-design-and-the-reserved-tail"></a>
**Budget design-required plans for the design turn and the reserved tail.** `Arbor.Orchestrator.CodingPlan.BudgetPolicy` caps the validation, approval, review, and cleanup reserve at 40 percent of the effective wall clock, so the worker phase keeps the rest. Size the plan so design, operator review, implementation, and one ACP recovery turn fit in that worker share. `worker_recovery_reopen_failed` and `worker_recovery_send_failed` with budget exhaustion are accounting outcomes, not a reason to switch providers. Budgets are fixed after admission. Preserve the terminal snapshot and redispatch a larger reviewed plan. (Merged 2026-10-16 from 2 entries; first found 2026-07-28, last 2026-08-02.)

<!-- applied-learning: a-design-checkpoint-approval-note-is-audit-evidence-not-guaranteed-worker-steering -->
<a id="applied-learning-a-design-checkpoint-approval-note-is-audit-evidence-not-guaranteed-worker-steering"></a>
**A design checkpoint approval note is audit evidence, not guaranteed worker
steering.** When approval depends on required corrections, deliver them through
a phase-aware steering or rework control and verify the next artifact against
each correction; do not approve and assume the note became part of the worker's
implementation prompt. Keep the approval note as the authoritative review
record, but treat implementation conformance as a separate gate (found
2026-07-28 when an approved ACP settlement naming and arity correction was
absent from Grok's candidate).

<!-- applied-learning: coding-plan-numeric-bounds-are-runtime-contracts-not-advisory-tuning -->
<a id="applied-learning-coding-plan-numeric-bounds-are-runtime-contracts-not-advisory-tuning"></a>
**Treat coding-plan rework ceilings as runtime contracts.** `Arbor.Contracts.Coding.Plan` admits `rework.max_cycles` only from 0 through 2, and that integer is the shared total, not a per-category budget. The reviewed coding graph still allows one validation repair, one operator commit repair, and two council repairs. Diagnose `rework_exhausted` from `validation_rework_count`, `operator_rework_count`, and `review_rework_count`, not from `max_cycles` alone. Inspect the whole frozen candidate and send one exhaustive operator ledger; a second operator request can terminalize before the worker sees the note. Preserve the retained workspace and redispatch from an exact checkpoint when a later issue appears. (Merged 2026-10-16 from 2 entries; first found 2026-07-28, last 2026-08-03.)

<!-- applied-learning: design-required-checkpoint-turns-must-be-observational -->
<a id="applied-learning-design-required-checkpoint-turns-must-be-observational"></a>
**Design-required checkpoint turns must be observational.** Tell the delegated
worker explicitly to inspect and design without editing any filesystem state
until the checkpoint is approved, including shared locations such as `/tmp`.
Arbor correctly rejects a design turn that changes the owned workspace as
`design_turn_modified_workspace`, even when the resulting patch is useful, but
an unowned shared-temp write can escape that fingerprint and collide with
another worker. Implementation authority begins only after approval, not when
the model believes its design is obvious (found 2026-07-28 during the Phase F
pending-approval settlement delegation; broadened 2026-08-02 after a voice
design wrote `/tmp/design_draft.txt`).

<!-- applied-learning: preserve-retained-worker-trees-without-mutating-the-source-owned-workspace -->
<a id="applied-learning-preserve-retained-worker-trees-without-mutating-the-source-owned-workspace"></a>
**Preserve retained worker trees without mutating the source-owned workspace.**
When a failed coding task retains a useful dirty tree, materialize its exact
state through an alternate Git index, `write-tree`, and `commit-tree`, then pin
that synthetic commit under a preservation ref and review it from a separate
worktree. Do not stage, reset, commit, or otherwise alter the retained source
workspace after Arbor has published its ownership and fingerprint evidence
(found 2026-07-28 salvaging the rejected Phase F design-turn implementation).

<!-- applied-learning: a-frozen-work-packet-is-not-delegated-until-every-worker-facing-prompt-binds-it -->
<a id="applied-learning-a-frozen-work-packet-is-not-delegated-until-every-worker-facing-prompt-binds-it"></a>
**A frozen work packet is not delegated until every worker-facing prompt binds
it.** Storing canonical packet bytes in graph metadata or a checkpoint node does
not scope a direct worker when the implementation route bypasses that node. Put
the canonical JSON in validated initial context before the first worker turn,
bind it into implementation and every rework prompt, and inspect the rendered
`build_*_prompt/status.json` artifact in an end-to-end dispatch; graph presence
alone proves construction, not delivery (found 2026-07-29 after a Grok ledger
worker spent its budget rediscovering constraints already present in the packet).

<!-- applied-learning: replace-advisory-payload-caps-with-one-artifact-backed-contract -->
<a id="applied-learning-replace-advisory-payload-caps-with-one-artifact-backed-contract"></a>
**Envelope limits must admit the component maxima or move the bytes to an artifact.** Do not assume that a component's admitted maximum fits a smaller interaction envelope. Either derive an envelope that admits those maxima, reject the incompatible combination at the earliest public boundary, or store the full bytes in an owned artifact and pass only a closed descriptor plus digest. Verify that artifact before every terminal decision and implementation handoff. Never report a caller-invalid payload as backend unavailability. (Merged 2026-10-16 from 2 entries; first found 2026-07-28, last 2026-07-29.)

<!-- applied-learning: distinguish-plan-capacity-from-operation-owned-timeout-ceilings -->
<a id="applied-learning-distinguish-plan-capacity-from-operation-owned-timeout-ceilings"></a>
**Distinguish plan capacity from operation-owned timeout ceilings.** A long
coding plan's interaction wait is available stage capacity, not necessarily a
valid timeout request for every action. When a missing request defaults to that
capacity, deadline clamping can still leave a value above the action's hard
maximum and make an otherwise healthy plan fail closed. Bind the action-owned
reviewed maximum as the requested timeout, then let plan capacity, owner
deadline, and completion reserve only shrink it; regress the full
producer-to-consumer path with a plan whose wall clock exceeds the action
maximum (found 2026-07-29 when a 90-minute provider-observation plan passed
design generation but failed `coding_design_checkpoint_open` with
`:invalid_design_checkpoint_timeout`).

<!-- applied-learning: route-rework-before-authorizing-validation -->
<a id="applied-learning-route-rework-before-authorizing-validation"></a>
**Route rework before authorizing validation.** A `rework` answer at the commit checkpoint can return that task to implementation. A non-approve answer at a validation authorization denies the side effect and terminalizes as `validation_failed`. Generic action `rework` is an error from `Arbor.Orchestrator.ActionsExecutor`, not a coding-graph branch. Steer the correction while the managed session is alive, or preserve the commit and start a follow-up from that exact commit. Do not answer the validation request with `rework` and expect an in-place repair. (Merged 2026-10-16 from 2 entries; first found 2026-07-18, last 2026-07-30.)

<!-- applied-learning: review-frozen-commit-approvals-before-the-interaction-deadline -->
<a id="applied-learning-review-frozen-commit-approvals-before-the-interaction-deadline"></a>
**Review frozen approvals before the remaining interaction deadline.** The
current coding pipeline expires a pending design or commit approval against
the remaining stage budget, which can be materially shorter than a nominal
five-minute interaction window. Once expired, the task is terminal and neither
`rework` nor steering can reach the worker. Inspect likely risk areas while the
worker runs, then prioritize the frozen artifact as soon as the approval
appears. If the deadline is too short for a responsible review, preserve the
immutable workspace evidence and redispatch an explicit provider-session
continuation rather than mutating the worker tree (found 2026-07-30 during the
OAuth model-catalog transport review; reinforced 2026-07-31 when a Phase E
design checkpoint had about 223 seconds available).

<!-- applied-learning: use-current-coding-plan-output-keys-and-preflight-the-normalized-plan -->
<a id="applied-learning-use-current-coding-plan-output-keys-and-preflight-the-normalized-plan"></a>
**Preflight the normalized coding plan and use its current keys.** Run the exact map through `Arbor.Contracts.Coding.Plan.new/1` and `Arbor.Orchestrator.CodingPlan.Compiler.compile/1` before dispatch. Top-level `branch_name` fails as an unknown field; put it under `workspace_policy.branch_name` or omit it. Output keys are `commit`, `draft_pr`, and `retain_workspace`. Contract admission does not prove v1 template support: nonempty `overlays`, a non-nil `budgets.model_cost_usd`, and `budgets.parallelism` other than 1 still fail as `unsupported_v1_feature`. On success, read `%Arbor.Orchestrator.CodingPlan.Compilation{manifest: manifest}`. `compile_manifest` is an artifact path, not that struct field. (Merged 2026-10-16 from 3 entries; first found 2026-07-17, last 2026-07-31.)

<!-- applied-learning: acp-receiver-idleness-is-not-worker-inactivity -->
<a id="applied-learning-acp-receiver-idleness-is-not-worker-inactivity"></a>
**ACP receiver idleness is not worker inactivity.** A provider turn can be
waiting on a background tool process while the adapter receiver emits no new
frames. Track acknowledged tool-call and child-process lifecycle as activity,
and require terminal provider or process evidence before declaring the turn
stalled; receiver silence alone can kill useful work and strand its workspace
(found 2026-07-30 when a Spark worker's broker reproduction continued in a
background job after the ACP receiver appeared idle).

<!-- applied-learning: delegate-from-candidate-commits-via-base-ref-not-linked-repo-roots -->
<a id="applied-learning-delegate-from-candidate-commits-via-base-ref-not-linked-repo-roots"></a>
**Delegate from candidate commits via `base_ref`, not linked `repo_root`
paths.** Keep the canonical repository as the coding plan's `repo_root` and
bind an unmerged candidate by its exact commit in `base_ref`. A linked
worktree may pass trusted-root readiness, but workspace acquisition runs the
hardened Git facade and correctly rejects that worktree's administrative
directory under the parent repository's `.git/worktrees` as storage outside
the linked root. The canonical repository plus candidate object ID preserves
the exact base without widening Git authority (found 2026-07-31 while
dispatching the Phase E provider-login continuation).

<!-- applied-learning: attest-dynamic-acp-models-from-session-state-not-process-arguments -->
<a id="applied-learning-attest-dynamic-acp-models-from-session-state-not-process-arguments"></a>
**Attest dynamic ACP models from managed session state, not process
arguments.** Adapted providers such as Claude can launch the CLI with a
configured bootstrap model and then select the reviewed task model over the
SDK control channel. The OS command line therefore describes process startup,
not necessarily the active model. Check Arbor's managed-session inventory and
the pipeline's requested/confirmed model evidence before diagnosing a model
mismatch; both still must agree with the reviewed plan (found 2026-07-31 while
the Phase E Claude fallback launched with `--model opus` but attested
`model: sonnet` after dynamic selection).

<!-- applied-learning: approval-notes-are-bounded-single-line-audit-fields -->
<a id="applied-learning-approval-notes-are-bounded-single-line-audit-fields"></a>
**Approval notes are bounded single-line audit fields.** `Arbor.Contracts.Comms.ApprovalAnswer` rejects a note above 1024 bytes and rejects control characters, including newlines. The same bound applies to a rework note carried on an approval answer. Put the decision and a compact correction ledger in the note. Put longer evidence in the reviewed artifact or in a separate steering message. The note is an audit field, not a second review document. Regress both an over-limit rejection and an accepted bounded note so the worker still receives the feedback. (Merged 2026-10-16 from 2 entries; first found 2026-07-28, last 2026-08-02.)

<!-- applied-learning: negotiate-optional-acp-resume-fields-against-advertised-capabilities -->
<a id="applied-learning-negotiate-optional-acp-resume-fields-against-advertised-capabilities"></a>
**Negotiate optional ACP resume fields against advertised capabilities.** A
provider session id does not prove every extension on that provider's resume
request is accepted. In particular, do not send Codex
`thread/resume.initialTurnsPage` unless the peer advertised the required
`experimentalApi` capability; otherwise a valid explicit continuation fails at
session startup with JSON-RPC `-32600` before the worker can respond. Gate the
field structurally from negotiated capabilities and regress the full managed
resume path, rather than matching provider error text or treating every resume
failure as a missing conversation (found 2026-08-02 while recovering a voice
packet after `design_response_invalid`).

<!-- applied-learning: acp-adapter-bootstrap-ids-are-not-resumable-provider-identities -->
<a id="applied-learning-acp-adapter-bootstrap-ids-are-not-resumable-provider-identities"></a>
**Adopt the provider's durable session id before continuity consumers.** A transient adapter handle, including a `claude_sdk_` prefix from Claude `session/new`, is not the resumable id. Validate the one-time transition to the provider's durable id and replace both session id fields before status, inactivity accounting, cancellation, or resume. Ignore later updates that match neither the bound id nor that permitted transition. Reject malformed identities and later drift. Fake clients must model the transient-to-durable transition. (Merged 2026-10-16 from 2 entries; first found 2026-07-28, last 2026-08-03.)

<!-- applied-learning: coding-dispatch-authority-uses-the-agent-dispatch-namespace -->
<a id="applied-learning-coding-dispatch-authority-uses-the-agent-dispatch-namespace"></a>
**Coding dispatch authority uses `arbor://agent/dispatch`, not the task-control
namespace.** Prefer the least-privilege exact target URI
`arbor://agent/dispatch/<agent_id>`; `arbor://agent/task/read`, `cancel`, `steer`,
and `adopt` are separate post-dispatch controls. A grant for the unregistered
`arbor://agent/task/dispatch` can be signed and stored, but authorization rejects
it at the URI registry and MCP reports `:agent_dispatch_required`. Compile the
plan's authority horizon and separately verify the exact dispatch URI before
allocating a task (found 2026-08-07 while starting Voice C3I0C1).

<!-- applied-learning: do-not-queue-future-stage-controls-before-the-semantic-phase-advances -->
<a id="applied-learning-do-not-queue-future-stage-controls-before-the-semantic-phase-advances"></a>
**Do not steer an edit before the semantic phase can accept it.** `Arbor.Orchestrator.CodingPlan.SteeringEligibilityCore` treats a nil `target_stage` as eligible during design, so an untargeted follow-up can still tell the worker to edit and terminalize `design_turn_modified_workspace`. A `target_stage` other than `design` is ineligible during design and stays queued as `:next_stage` until the phase advances. Do not use an implementation follow-up to repair a design turn. Wait for durable phase evidence before an implementation control, and checkpoint any source that was produced anyway instead of replaying the packet. (Merged 2026-10-16 from 3 entries; first found 2026-07-28, last 2026-08-30.)

<!-- applied-learning: inline-load-bearing-nested-repository-context-in-delegated-work-packets -->
<a id="applied-learning-inline-load-bearing-nested-repository-context-in-delegated-work-packets"></a>
**Inline load-bearing nested-repository context in delegated work packets.**
Arbor coding worktrees contain files tracked by the parent repository; the separate
`.arbor` Git repository and its roadmap documents are absent. Treat `.arbor` paths in
`architecture_refs` as manager provenance only, and copy every constraint the worker
must follow into the canonical WorkPacket and task prompt. Otherwise a correctly
isolated worker cannot read the cited design and may silently reconstruct weaker
requirements (found 2026-08-15 while dispatching E0B2P).

<!-- applied-learning: rehydrate-stdio-mcp-proxies-after-upstream-session-loss -->
<a id="applied-learning-rehydrate-stdio-mcp-proxies-after-upstream-session-loss"></a>
**Rehydrate stdio MCP proxies in-process after the upstream loses session state.** A
signing proxy can outlive the HTTP gateway whose in-memory Streamable HTTP session
it replays, and MCP hosts do not reliably respawn a proxy that closes stdio. Cache
only the latest successfully completed `initialize` plus
`notifications/initialized` lifecycle. On a narrowly identified stale-session or
negotiated-version rejection, freshly sign and replay that lifecycle, require a new
session with the same negotiated protocol, retry the interrupted request once, and
keep stdio open. Never retry arbitrary upstream errors. A client-driven second
`initialize` must likewise discard the old HTTP session before forwarding it (found
2026-08-20 when a live Codex postcheck stayed permanently transport-closed after the
signer exited).

<!-- applied-learning: derive-coding-commit-subjects-from-reviewed-plan-data -->
<a id="applied-learning-derive-coding-commit-subjects-from-reviewed-plan-data"></a>
**Derive coding commit subjects from reviewed plan data.** A fixed subject such as
`Coding agent change` destroys traceability across retained branches, evidence refs,
and the main history. Treat `Plan.task` as the subject: supply a self-contained
imperative of at most 72 bytes and put rationale/detail in the WorkPacket. Compiler
truncation is a safety boundary, not a prose editor. Compile a one-line, valid-UTF-8
subject; strip the full Unicode control/format category and keep worker prose unable
to override it. Give archived or uncompiled graphs a descriptive stable fallback.
When changing the canonical DOT template, also update its exact source-size regression
and run the compiler plus pipeline tests, because compile-only validation will not
catch that drift (found 2026-08-20 after hundreds of generic coding commits and a
focused post-council test run; authoring rule clarified 2026-08-23).

<!-- applied-learning: probe-provider-owned-acp-credential-layouts-instead-of-substituting-a-familiar-oauth-shape -->
<a id="applied-learning-probe-provider-owned-acp-credential-layouts-instead-of-substituting-a-familiar-oauth-shape"></a>
**Probe provider-owned ACP credential layouts instead of substituting a familiar
OAuth shape.** Native ACP providers can use provider-specific paths, settings, and
refresh records. Probe them under an isolated home and inspect only names and shape,
never secret values; then stage exactly that bounded schema. Google Antigravity uses
`$GEMINI_HOME/antigravity-acp/{settings.json,acp_token.json}` and a six-field Google
refresh credential. Assuming a generic `access_token` document and a root-level
settings file produced a plausible implementation that could never authenticate
(found 2026-08-22 while adding Antigravity as a managed coding provider).

<!-- applied-learning: reassert-acp-provider-launch-ceilings-after-every-raw-configuration-seam -->
<a id="applied-learning-reassert-acp-provider-launch-ceilings-after-every-raw-configuration-seam"></a>
**Reassert ACP provider launch ceilings after every raw configuration seam.** A
strict catalog policy protects only calls that pass through `Config.resolve/2`;
direct sessions can accept raw `client_opts`. Enforce the exact command, native
transport, Arbor permission handler, and isolated environment again at the last
pre-spawn boundary. `Keyword.put_new(:handler, ...)` is not a ceiling when a raw
caller can pre-populate the key (found 2026-08-22 while hardening Antigravity ACP;
a schema-valid raw handler override otherwise survived into provider startup).

<!-- applied-learning: read-progressively-disclosed-mcp-tool-schemas-before-calling -->
<a id="applied-learning-read-progressively-disclosed-mcp-tool-schemas-before-calling"></a>
**Read the emitted MCP tool schema before calling a progressively disclosed tool.**
Names do not reliably imply argument keys: `arbor_help` requires `action`, not
`action_name`. A missing required key may also expose a server admission bug rather
than a useful lookup error, so distinguish caller correction from the separate
typed-validation regression (found 2026-08-23 while inspecting task steering).

<!-- applied-learning: a-complete-test-artifact-does-not-overrule-process-capacity-exhaustion -->
<a id="applied-learning-a-complete-test-artifact-does-not-overrule-process-capacity-exhaustion"></a>
**A complete test artifact does not overrule process capacity exhaustion.** A
contained child may emit a full passing ExUnit count and still hit its deadline
before clean process completion; the trusted timeout/containment result remains
authoritative and the revision is not accepted. Before retrying, compare the work's
actual grain with the closed Shell resource profile: fix a standard-versus-intensive
profile mismatch at the Core, action opts, and compiled-policy owners instead of
raising a one-off timeout or relabeling counts as success. Then repeat every unfinished
revision under the corrected bound (found 2026-08-24 when SecurityRegression passed
49 selected candidate tests under a standard child ceiling but timed out before the
base leg).

<!-- applied-learning: prefer-the-retained-candidate-verifier-over-implementation-replay -->
<a id="applied-learning-prefer-the-retained-candidate-verifier-over-implementation-replay"></a>
**Prefer the retained-candidate verifier over implementation replay.** When a
coding task terminalizes after producing a reviewed commit but deliberately retains
an inactive task-owned workspace, first use public `arbor.coding.check --verify`
with its archived plan and exact agent, task, and workspace ids. That boundary
reactivates the workspace, binds compilation plus task/principal/workspace
provenance, and reruns product validation without reconstructing the tree. Preserve
the original terminal as historical evidence; a later passing report does not
rewrite it. Replay only when no valid retained record exists (found 2026-08-24 while
recovering the checkpoint-policy candidate after validation capacity exhaustion).

<!-- applied-learning: distinguish-live-runtime-binding-drift-from-a-nested-manifest-defect -->
<a id="applied-learning-distinguish-live-runtime-binding-drift-from-a-nested-manifest-defect"></a>
**Distinguish live runtime binding drift from a nested-manifest defect.** An
authorized graph pins loaded module and BEAM identities. If the server reloads a
handler after the parent manifest is compiled but before a nested graph launches,
`child_binding_not_pinned_by_parent` is the expected fail-closed result even when
both graphs select the same module. Compare parent/child module hashes and correlate
task and source-commit timestamps before changing compiler or authority code. Keep
the candidate, classify the run as infrastructure drift, and rerun review against a
stable runtime; never weaken subset enforcement or request implementation rework
without a semantic verdict (found 2026-08-24 when Packet B crossed a live
`LlmHandler` upgrade).

<!-- applied-learning: bound-design-retries-independently-and-carry-continuity-in-the-packet -->
<a id="applied-learning-bound-design-retries-independently-and-carry-continuity-in-the-packet"></a>
**Bound design retries independently and carry continuity in the packet.** A
multi-hour validation plan may legitimately need a long execution window, but a
read-only design turn should use its own short inactivity timeout. Do not blindly
inherit the execution profile's budget: a silent model can otherwise occupy the
task for an hour without producing an artifact. Provider-session resume is also
runtime-local; when the old isolated ACP session store is gone, opening a fresh
transport cannot restore its conversation. Freeze every accepted decision and open
finding into the canonical packet so a fresh session can continue honestly (found
2026-08-31 after a CrossApp materialization retry went silent under an inherited
one-hour timeout and its predecessor's Grok session could not be loaded).

<!-- applied-learning: disconnect-a-programmatic-mcp-client-before-stopping-its-genserver -->
<a id="applied-learning-disconnect-a-programmatic-mcp-client-before-stopping-its-genserver"></a>
**Disconnect a programmatic MCP client before stopping its GenServer.**
With ExMCP 1.3.0, Client.stop/1 calls GenServer.stop without closing the
stdio transport. Repeated short-lived clients left SSH signing proxies running
on a fresh factory, despite completed requests. Client.disconnect/1 then stop/1
closed the transport and reaped the extra guest process in a live check. Reuse
connections and verify child quiescence during teardown; do not infer it from a
successful stop return. The signer itself exited normally on stdin EOF (2026-09-07).
