# Applied Learning: ACP Sessions, Providers, and MCP Transport

Read this when launching, resuming, steering, or attesting ACP sessions and providers, or when working on MCP transport and progressive tool disclosure.

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

<!-- applied-learning: native-acp-session-access-and-native-tool-authority-are-separate-gates -->
<a id="applied-learning-native-acp-session-access-and-native-tool-authority-are-separate-gates"></a>
**Native ACP session access and native tool authority are separate gates.** The
handler authorizes callbacks at `arbor://acp/tool/<canonical-name-or-kind>`, so an
exact `arbor://acp/tool` capability does not cover them under segment-aware
capability semantics. Grant exact child URIs or the bounded `arbor://acp/tool/**`
subtree, and derive the child only from machine-readable protocol identity fields;
human-readable titles may contain entire commands (found 2026-07-17 when Grok's
structured `kind=execute` callback was misidentified by its descriptive title).

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

<!-- applied-learning: prefer-steering-an-active-delegated-acp-worker-for-review-and-rework-reserve-cancellation-for-termination -->
<a id="applied-learning-prefer-steering-an-active-delegated-acp-worker-for-review-and-rework-reserve-cancellation-for-termination"></a>
**Prefer steering an active delegated ACP worker for review and rework; reserve cancellation for termination.** Steering preserves the model context, worktree, and test state. As of 2026-07-09, `coding_produce_reviewable_change` does not expose nested ACP steering, and Session steering cannot interrupt a blocking nested action, so add an explicit task/ACP steering control instead of simulating rework with cancel-and-redispatch. `arbor_cancel_task` must remain hard, deterministic termination.

<!-- applied-learning: do-not-send-long-newline-delimited-mcp-json-frames-through-a-canonical-pty -->
<a id="applied-learning-do-not-send-long-newline-delimited-mcp-json-frames-through-a-canonical-pty"></a>
**Do not send long newline-delimited MCP JSON frames through a canonical PTY.** A terminal's line buffer can truncate or reject a large JSON-RPC request before the stdio signer reads it, which looks like a malformed or missing MCP response. Use a non-TTY client or an existing MCP tool for long dispatch payloads; reserve interactive signer sessions for short diagnostic calls (found 2026-07-10 during the signed steering proof).

<!-- applied-learning: a-managed-acp-handle-lives-only-as-long-as-its-owning-action-unless-an-explicit-durable-owner-retains-it -->
<a id="applied-learning-a-managed-acp-handle-lives-only-as-long-as-its-owning-action-unless-an-explicit-durable-owner-retains-it"></a>
**A managed ACP handle dies with its owning action unless a durable owner retains it.** A standalone session start can report ready and then close the worker during action cleanup, so a later standalone send does not find that session. A still-live outer task or an approval wait does not keep the worker steerable after the implementation node has closed it. Deliver steering while that session is alive. After it closes, resume from an exact committed checkpoint in a new task. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-11.)

<!-- applied-learning: the-public-task-control-facade-remains-usable-when-a-client-has-not-exposed-a-steering-mcp-tool -->
<a id="applied-learning-the-public-task-control-facade-remains-usable-when-a-client-has-not-exposed-a-steering-mcp-tool"></a>
**The public task-control facade remains usable when a client has not exposed a steering MCP tool.** `Arbor.Agent.Orchestration.steer_task/3` still performs exact task/delegator authorization and persists the control through TaskStore; invoke it with the authenticated caller identity through a trusted local RPC surface rather than mutating worker state directly. A control queued as `same_session_follow_up` while ACP is inside a blocking turn is not delivered yet and must remain visibly queued until that session accepts it (found 2026-07-11 steering the commit-approval R3 correction).

<!-- applied-learning: term-serialization-bounds-must-include-integer-bit-size-before-encoding -->
<a id="applied-learning-term-serialization-bounds-must-include-integer-bit-size-before-encoding"></a>
**Term serialization bounds must include integer bit size before encoding.** Counting every integer as a fixed scalar lets a hostile bignum allocate megabytes in `term_to_binary/2` before a post-encode byte check can reject it. Bound signed integer magnitude/bit length during the structural walk, then encode only the already bounded term (found 2026-07-11 reviewing execution-proof payloads).

<!-- applied-learning: acp-continuity-requires-the-provider-session-id-not-only-the-managed-worker-handle -->
<a id="applied-learning-acp-continuity-requires-the-provider-session-id-not-only-the-managed-worker-handle"></a>
**ACP continuity requires the provider session ID, not only the managed worker handle.** `worker_session_id` (`acp_worker_*`) is an owner-scoped live registry handle; `acp_close_session` or owner death invalidates it. The ACP provider's `worker.session_id` is the durable conversation identity consumed by `load_session`. A coding graph must opt into pooled execution, preserve/project that provider ID before closing or checking in the worker, and pass it through a later authorized start to resume context. Returning only the closed managed handle is not resumability. When diagnosing an older run, recover the provider ID from the `open_worker/status.json` checkpoint if the public result dropped it (found 2026-07-12 tracing `task_167682`, whose non-pooled graph retained provider session `019f52ad-dfb1-7d33-8156-effae2a1c9fa` only in the checkpoint).

<!-- applied-learning: map-decoding-can-erase-duplicate-json-members-before-closed-schema-validation -->
<a id="applied-learning-map-decoding-can-erase-duplicate-json-members-before-closed-schema-validation"></a>
**Map decoding can erase duplicate JSON members before closed-schema validation.** Jason's normal map mode keeps only one value for repeated keys, so a durable record with two `active` or `token` members may look valid after decode while evidence was discarded. Decode security-critical durable JSON as ordered objects, reject duplicate members recursively under a depth/size bound, then convert to maps for the ordinary closed core (found 2026-07-14 reviewing the Apple unit-intent journal).

Use the same rule for signed request objects and authenticated response
envelopes. A client-side correlation check cannot detect conflicting
`agent_id` members once map decoding has discarded one. Test both key orders
through a supported public operation and retain a successful predecessor
happy path (2026-10-03 conversation SDK and remote adapter regressions).

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

<!-- applied-learning: native-acp-cli-options-must-be-placed-at-the-parser-level-that-owns-them -->
<a id="applied-learning-native-acp-cli-options-must-be-placed-at-the-parser-level-that-owns-them"></a>
**Native ACP CLI options must be placed at the parser level that owns them.** Grok accepts `grok agent --model grok-4.5 stdio` but rejects `grok agent stdio --model grok-4.5`; Arbor's generic native-provider `args` are appended after the configured command, so a parent-command option must be embedded in `command` before the subcommand rather than supplied through `args`. Verify the exact argv with the installed CLI's `--help` before pinning a model or policy flag (found 2026-07-18 while making the Grok coding model explicit).

<!-- applied-learning: use-a-raw-elixir-sigil-for-quote-bearing-arbor-rpc-steering-messages -->
<a id="applied-learning-use-a-raw-elixir-sigil-for-quote-bearing-arbor-rpc-steering-messages"></a>
**Use a raw Elixir sigil for quote-bearing `arbor.rpc` steering messages.** The shell can safely single-quote the whole RPC expression, but unescaped double quotes inside an ordinary Elixir message string still terminate that string before RPC runs. Put the human message in a delimiter-safe form such as `~S|...|` (after checking the text does not contain the delimiter), keep the expression on one physical argument line, and reserve ordinary quoted strings for bounded IDs/options (found 2026-07-18 steering the contained CrossApp test-seam repair).

<!-- applied-learning: provider-tool-identities-differ-across-acp-layers -->
<a id="applied-learning-provider-tool-identities-differ-across-acp-layers"></a>
**Provider tool identities differ across ACP layers.** Grok's internal terminal ID is `run_terminal_cmd`, while the ACP client-visible name is `run_terminal_command`; ACP tool kind `execute` is a category, not a reliable provider tool ID. Authorize and deny using the machine-readable identity at the layer being tested, rather than inferring one name from another (found 2026-07-19 during Grok ACP containment work).

<!-- applied-learning: acp-http-mcp-descriptors-must-use-the-standard-wire-shape -->
<a id="applied-learning-acp-http-mcp-descriptors-must-use-the-standard-wire-shape"></a>
**ACP HTTP MCP descriptors must use the standard wire shape.** Send descriptors as `type`/`name`/`url`/`headers`; Grok rejects the legacy `uri`/`name` map during `session/new`, before the MCP tool path can be tested (found 2026-07-19 during Grok ACP containment work).

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

<!-- applied-learning: acp-receiver-idleness-is-not-worker-inactivity -->
<a id="applied-learning-acp-receiver-idleness-is-not-worker-inactivity"></a>
**ACP receiver idleness is not worker inactivity.** A provider turn can be
waiting on a background tool process while the adapter receiver emits no new
frames. Track acknowledged tool-call and child-process lifecycle as activity,
and require terminal provider or process evidence before declaring the turn
stalled; receiver silence alone can kill useful work and strand its workspace
(found 2026-07-30 when a Spark worker's broker reproduction continued in a
background job after the ACP receiver appeared idle).

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

<!-- applied-learning: disconnect-a-programmatic-mcp-client-before-stopping-its-genserver -->
<a id="applied-learning-disconnect-a-programmatic-mcp-client-before-stopping-its-genserver"></a>
**Disconnect a programmatic MCP client before stopping its GenServer.**
With ExMCP 1.3.0, Client.stop/1 calls GenServer.stop without closing the
stdio transport. Repeated short-lived clients left SSH signing proxies running
on a fresh factory, despite completed requests. Client.disconnect/1 then stop/1
closed the transport and reaped the extra guest process in a live check. Reuse
connections and verify child quiescence during teardown; do not infer it from a
successful stop return. The signer itself exited normally on stdin EOF (2026-09-07).
