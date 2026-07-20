# Agent Security Gates — the security actions needed to run agents & tools

Arbor is capability-secure by default. When you spin up an agent, grant it tools, or
subscribe to internal signals, you will hit **security gates** that must be satisfied
*explicitly* — a missing grant or the wrong trust mode does not error loudly; it fails
closed (denied, or escalated to a human-approval `:ask` that an autonomous run can't
answer, so the agent loops/times out).

This is a **living checklist**: each gate below lists *what it is*, the *symptom* when
it's unhandled, and the *action* to satisfy it. Add a new entry whenever you discover
another one. It doubles as user documentation — anyone standing up agents needs this.

---

## 1. Restricted signal topics (`security.*`, and other privileged namespaces)

- **What:** `Arbor.Signals.subscribe/3` authorizes the *pattern*. `security.*` topics
  are **restricted** — subscribing requires an authorized principal
  (`Bus.authorize_subscription/3`). `agent.*` topics are not restricted.
- **Symptom:** `Signals.subscribe("security.egress_blocked", …)` returns
  `{:error, :unauthorized}` (nil principal + restricted topic). A strict
  `{:ok, sub} = subscribe(...)` then crashes with a `MatchError`.
- **Action:** pass `principal_id:` in the opts and **tolerate refusal** — never
  strict-match a restricted subscription:
  ```elixir
  case Arbor.Signals.subscribe(topic, handler, principal_id: agent_id) do
    {:ok, sub} -> sub
    _ -> nil                       # gate we can't watch → capture nothing, don't crash
  end
  ```
  If you *need* the events, authorize the principal for that topic (the signal
  authorizer's policy) — passing the agent id is best-effort and may still be refused.

## 2. `arbor://shell/exec` is structurally `:ask` (always-locked ceiling)

- **What:** shell is deliberately un-autonomous: it has an always-on `:ask` **ceiling**
  that capabilities cannot override. A model that *names* `shell_execute` (even one it
  wasn't granted) hits that ceiling.
- **Symptom:** real human-approval requests appear in the operator's Signal for
  `arbor://shell/exec` that you never granted — a stray/hallucinated shell call from an
  agent whose task didn't include shell.
- **Action:** if the agent must NOT shell, hard-`:block` it in the trust profile — a
  `:block` *rule* beats the `:ask` ceiling, so the call is denied outright instead of
  paging a human:
  ```elixir
  Arbor.Trust.Authority.set_rule(profile, "arbor://shell/exec", :block)
  ```
  If it *should* shell, grant the shell caps and expect `:ask` (or wire an approver).

## 3. File tools need **path-scoped** fs caps (not the bare tool cap)

- **What:** `file_read`/`file_list`/`file_write` authorize `arbor://fs/<op>` with the
  concrete `file_path` checked by `FileGuard` against a **path-scoped** cap. The bare
  `arbor://fs/read` only *exposes* the tool; executing a read needs a cap whose path
  scope covers the target.
- **Symptom:** the file tool returns `{:error, {:unauthorized, …}}` even though the tool
  is in the agent's tool list.
- **Action:** grant the path-scoped cap (mirror `Lifecycle.grant_workspace_capabilities`):
  ```elixir
  Arbor.Security.grant(principal: agent_id,
    resource: "arbor://fs/read/#{String.trim_leading(dir, "/")}/**")
  ```
  Also mind `context[:workspace]`: when set, paths resolve *within* it (SafePath), so a
  scenario dir outside the workspace is rejected before the cap is even checked.
- **`fs/write` escalates to human approval and a trust `:allow` rule does NOT clear
  it (open gap).** `file_write` fires `ActionsExecutor.await_interactive` → a Signal
  approval that *stalls the agent ~60s per write* (a hidden cause of "why is my
  autonomous agent so slow"). `file_read`/`file_list` default safe, so read-only tasks
  don't hit this. VERIFIED 2026-07-02: setting `baseline: :allow` AND an explicit
  `set_rule(profile, "arbor://fs/write", :allow)` did NOT stop it — there is no
  fs/write *ceiling* (only `arbor://shell` + `arbor://governance` have ceilings), so
  the escalation comes from a lower layer: either a capability `requires_approval`
  constraint on the granted fs/write cap, or the profile being re-resolved (which
  resets `arbor://fs/write => :ask`, per `profile_resolver.ex`) at authorize time.
  **Root cause not yet pinned; no known eval-usable bypass.** Until then: for
  autonomous agents that must write, either provision a pre-approved write cap or have
  the agent return output another way. (The crm-export eval task outputs its report in
  the response instead of `file_write` for exactly this reason.)

## 4. A granted cap ≠ permission to run — the trust profile sets the MODE

- **What:** `Arbor.Security.grant/1` says the agent *may* use a resource. The trust
  profile's per-resource **rule** (or the `baseline`) sets the **mode**: `:allow`,
  `:ask`, `:block`, `:auto`. `effective_mode` = most-restrictive of (rule/baseline,
  ceilings, model constraints).
- **Symptom:** the agent has the cap but the tool never executes — it loops or
  times out, silently waiting on an approval an autonomous run can't answer (default
  `baseline` is `:ask`).
- **Action:** set the resource to `:allow` (or `baseline: :allow` for a sandboxed eval):
  ```elixir
  Arbor.Trust.Store.update_profile(agent_id, fn p ->
    %{p | baseline: :allow} |> Arbor.Trust.Authority.set_rule(uri, :allow)
  end)
  ```
  `:allow` only steps aside the *approval* gate — the taint/egress gate still applies.

## 5. The egress gate is ENFORCING by default (dev + prod)

- **What:** `config :arbor_security, egress_gate_enforcing: true` (dev.exs/prod.exs).
  `EgressGate.decide`: `on_host` (local LM Studio) → `:allow`; **tainted (untrusted/
  hostile) content to external egress → `{:block}`**; `external_provider` (cloud LLM)
  egress → `policy_mode` (default `external_provider: :allow` via
  `default_egress_modes`, else `:ask`).
- **Symptom:** a cloud-LLM agent's call is refused (`requires_approval`), or an agent
  processing web/tainted content can't send it to an external provider.
- **Action:** for local-first, use `on_host` models (unaffected). For cloud egress,
  ensure `external_provider: :allow` in the profile's `egress_modes` or grant a
  destination-scoped egress cap. Tainted→external is *meant* to block — that's the
  exfil defense, not a misconfiguration.

## 6. `arbor://agent/discover_tools` must be infrastructure-`:auto`

- **What:** agents discovering their own tools go through
  `arbor://agent/discover_tools`. If it resolves to `:ask`, every agent pages the
  operator just to see its toolset. `Authority.effective_mode` treats it as
  infrastructure-`:auto` (see `@infrastructure_auto_prefixes`).
- **Symptom:** repeated approval requests on tool discovery; agents that can't enumerate
  their own tools.
- **Action:** keep `discover_tools` in the infrastructure-`:auto` set (single source in
  `Authority`), not per-agent trust rules.

## 7. Tool *exposure* vs *authorization* are separate

- **What:** what the model *sees* (`config["tools"]`, else profile-derived via
  `ToolDisclosure` reverse-mapping caps→tools by **exact canonical URI**) is distinct
  from what it may *execute* (caps + trust mode). Path-scoped caps (`…/**`) do NOT
  expose a tool via the reverse-map.
- **Symptom:** the agent flails on tools it can't run, or can't see a tool it was
  granted a path-scoped cap for.
- **Action:** pin the exposed set with `config["tools"]` (authoritative) and grant the
  execution caps separately; don't rely on the reverse-map for path-scoped grants.

## 8. Unregistered capability URIs (when the URI registry is enforcing)

- **What:** `Arbor.Security.UriRegistry` allowlists capability URIs by prefix; with
  enforcement on, granting/using an unregistered URI is rejected.
- **Symptom:** a brand-new resource URI (e.g. a new eval action) is denied despite a
  grant.
- **Action:** add the canonical URI prefix to the registry's allowlist (e.g.
  `arbor://eval/search` was added for the eval fixture).

## 9. Native ACP tool callbacks need subtree authority

- **What:** starting an ACP session and authorizing the worker's native tool callbacks
  are separate operations. `AcpSession.Handler` maps a bounded, machine-readable tool
  name or kind to `arbor://acp/tool/<tool>`. A concrete `arbor://acp/tool` capability
  does not authorize those child resources.
- **Symptom:** the delegated worker starts normally, then its first native tool request
  is denied or cancelled despite holding the base capability. Descriptive ACP titles
  such as an entire shell command are not authorization identities and fail closed
  unless the payload also supplies a canonical `name`, `toolName`, `tool_name`, `kind`,
  or typed `toolCallId` prefix.
- **Action:** for agents trusted to use their native ACP harness, grant the bounded
  subtree explicitly:
  ```elixir
  Arbor.Security.grant(principal: agent_id, resource: "arbor://acp/tool/**")
  ```
  Set the `arbor://acp/tool` trust rule intentionally as a separate policy decision.
  This subtree includes native execution tools, so do not grant it to read-only agents;
  grant exact child URIs instead when the provider exposes stable canonical names.

## 10. Nested reviewed graphs need exact child-action authority

- **What:** a capability for the outer composite action does not authorize actions in
  a nested reviewed DOT graph. Domain authority such as
  `arbor://consensus/decide` also does not satisfy the action executor's canonical
  gate for `consensus_decide_review`, which is
  `arbor://action/consensus/decide_review`.
- **Symptom:** every council reviewer completes, but the parent review action returns
  `:no_decision_in_result`. The nested `decide/status.json` shows
  `Capability check failed: arbor://action/consensus/decide_review (:unauthorized)`.
- **Action:** keep the child action pinned in the reviewed execution manifest and
  grant its exact canonical action URI to the agent template that is authorized to
  run that graph. Set the matching trust rule deliberately; do not broaden to
  `arbor://action/consensus/**` or disable nested authorization.

## 11. Binding council reviewers need exact terminal-report authority

- **What:** each binding council compute node exposes
  `coding_submit_review_report` as its sole terminal tool. Tool exposure and the
  outer `council_review_change` capability do not authorize that child action;
  execution uses the exact generated URI
  `arbor://action/coding/review/submit`. The action registry registers that exact
  URI at `arbor_actions` startup, so a broad manual registry prefix is neither
  needed nor desirable.
- **Symptom:** reviewers can read/search the candidate, but the terminal call is
  denied. ToolLoop returns the failed result for one correction attempt and then
  fails with `terminal_tool_submission_required`, so the council never produces a
  binding report even though the model reached a vote.
- **Action:** pin `coding_submit_review_report` in the compiled execution manifest,
  grant the coding-agent principal the exact URI, and set the exact trust rule to
  `:auto`. Template updates cover newly created agents only; reconcile the same
  exact capability and rule on an existing live coding agent before dogfooding the
  updated council. Do not broaden to `arbor://action/coding/**`.

## 12. Native ACP MCP configuration is additive ambient authority

- **What:** ACP `session/new.mcpServers` adds client-provided servers; it does not
  replace servers the native provider discovers from its user home, compatibility
  files, managed settings, repository config, or plugins. A same-name ACP entry is
  not a portable shadowing mechanism. Grok initializes native configuration before
  or alongside the session list.
- **Symptom:** a delegated worker can discover a globally configured server such as
  Tidewave and use it to read or evaluate outside Arbor's workspace capabilities.
  Sending `mcpServers: []` still leaves the ambient server enabled. Sending a broken
  duplicate merely adds another server. Grok debug logs can also print resolved OAuth
  bearer material while diagnosing initialization.
- **Action:** treat the provider process boundary as part of authorization. Launch
  Grok with a private `GROK_HOME` containing only a private copy of `auth.json`; turn
  off Claude/Cursor/Codex and managed MCP discovery; reject repository MCP/plugin
  sources before startup; protect those paths with the transient strict profile; and
  bind the normalized ACP MCP list once in `AcpSession`, replacing per-operation
  attempts to widen it on create, load, and reconnect. Keep `MCPTool(*)` denied when
  the bound list is empty; remove only that blanket denial when Arbor supplied an
  explicit scoped ToolServer. Force provider logs into the private runtime at warning
  verbosity, and keep `ExMCP.ACP.Client` at an `:info` module-level floor because
  its debug fallback includes complete unsupported notification payloads.

---

## Quick checklist for "make an autonomous agent actually run a tool"

1. Grant the **execution cap** (path-scoped for fs; destination-scoped for egress).
2. Set the trust **mode** to `:allow` (or `baseline: :allow`) — else it `:ask`-loops.
3. **Expose** the tool (`config["tools"]`) so the model sees it.
4. Hard-`:block` anything it must never touch (e.g. `shell/exec`) so strays don't page a human.
5. Register any **new URIs** if the URI registry is enforcing.
6. For **local** models egress is `:on_host → :allow`; for **cloud**, allow
   `external_provider` egress — and remember tainted→external is blocked by design.
7. To watch `security.*` signals, subscribe with a `principal_id:` and **tolerate refusal**.
8. For native ACP workers, grant exact callback URIs or `arbor://acp/tool/**`; the base
   capability alone only names the namespace.
9. For nested reviewed graphs, grant every pinned child action's exact canonical URI;
   outer-action and domain capabilities do not substitute for action authority.
10. For binding council runs, grant and auto-trust the exact
    `arbor://action/coding/review/submit` terminal action; reconcile existing agents
    because template changes are not retroactive.
11. For native ACP workers, isolate provider config and bind the session MCP list;
    `mcpServers: []` does not disable provider-global or project MCP servers.

## Applied Learning: Security Gates

Read this when changing capabilities, trust, authorization, identity, URI matching, taint, egress, or proof boundaries.

<!-- applied-learning: do-not-telemetry-invert-distributed-security-state-sync -->
<a id="applied-learning-do-not-telemetry-invert-distributed-security-state-sync"></a>
**Do not telemetry-invert distributed security state sync.** Security observability can emit `:telemetry` and let `arbor_signals` bridge it back to signals, but nonce, capability, and identity sync are load-bearing cross-node security state. `NonceCache` uses `security.nonce_seen` to block replay against peer nodes; `CapabilityStore` uses revocation signals to evict revoked grants on peers; `Identity.Registry` uses identity lifecycle signals to keep peer caches current. Telemetry is in-process and synchronous, so it cannot replace node-hop transport. B9 extraction needs an injected sync transport (likely Phoenix.PubSub or `Arbor.Signals` behind a behaviour), not a telemetry bridge, before dropping the `arbor_signals` dependency.

<!-- applied-learning: template-capability-grants-may-need-runtime-uri-expansion -->
<a id="applied-learning-template-capability-grants-may-need-runtime-uri-expansion"></a>
**Template capability grants may need runtime URI expansion.** Agent templates and trust presets can declare the human-readable coarse gate (`arbor://orchestrator/execute`), but mandatory Engine middleware authorizes per-node runtime resources like `arbor://orchestrator/execute/exec`. A trust rule prefix can stay bare, but a capability grant must be subtree-scoped (`/**`) or the session pipeline fails closed after `classify` with an empty CLI response. Diagnose by inspecting the node status checkpoint, not just the top-level turn summary (found 2026-07-07 while debugging `arbor.agent chat` for coding agents).

<!-- applied-learning: trust-policy-rules-match-by-uri-prefix-not-glob-never-write -->
<a id="applied-learning-trust-policy-rules-match-by-uri-prefix-not-glob-never-write"></a>
**Trust-policy rules match by URI PREFIX, not glob — never write `/**` in a trust rule.** A bare `arbor://fs/read` already covers the whole subtree (`ApprovalGuard` longest-prefix match); a literal `arbor://fs/read/**` is a prefix of nothing real, so the rule *silently never fires* and the request falls to the baseline. `/**` is correct for **capabilities** (path scope) but dead in **trust rules** — the two forms look identical, which is the footgun. Failure mode is config-dependent: fail-**closed** under a `block` baseline (the Test Agent selected `file_read` but every read returned `{:error, :policy_denied}` despite the trust profile literally showing `"arbor://fs/read/**" => :allow`; 2026-07-06), but fail-**OPEN** for a `/** block` rule under an `allow` baseline. Diagnose by reproducing the exact `Security.authorize(agent, "arbor://fs/read", :execute, file_path: …)` the action makes, and inspect the profile with `Arbor.Trust.Store.get_profile/1`. (Same day, unrelated: `./bin/mix` served a **stale beam** for an edited *mix task* until an explicit `mix compile` — a first "Unknown provider"/old-behavior right after editing a `Mix.Tasks.*` module is un-recompiled code, not a wrong edit; force the compile before concluding.)

<!-- applied-learning: tests-must-explicitly-own-security-children-disabled-by-test-config -->
<a id="applied-learning-tests-must-explicitly-own-security-children-disabled-by-test-config"></a>
**Tests must explicitly own security children disabled by test config.** `config/test.exs` sets `arbor_security, start_children: false`, so a focused test that calls signing APIs such as `Arbor.Security.grant/1` must start `Identity.Registry` and `SystemAuthority` under ExUnit supervision. Do not rely on another test file to start shared infrastructure. Use `start_supervised!/1` rather than a raw linked `start_link/0` for ordinary test ownership, but do not rely on `on_exit` to call that child: ExUnit teardown can stop it before the callback runs. Restore mutable process state in a `try/after` while the process is still alive, or put the process under a longer-lived supervisor (found 2026-07-10 during Phase 5 isolated verification and confirmed by the stale ActionRegistry catalog regression).

<!-- applied-learning: do-not-confuse-arbor-security-keychain-with-macos-keychain-services -->
<a id="applied-learning-do-not-confuse-arbor-security-keychain-with-macos-keychain-services"></a>
**Do not confuse `Arbor.Security.Keychain` with macOS Keychain Services.** Arbor's module is an in-process cryptographic peer/session abstraction and does not invoke the macOS `security` tool or credential store. Repeating macOS prompts for a `Claude Code credentials` item can come from the Claude daemon itself; `~/.claude/daemon.log` reports `auth: no token found, will re-check keychain every 30s` when that happens. Diagnose the requesting process and daemon log before attributing a prompt to Arbor code (found 2026-07-10 while delegated tests were running).

<!-- applied-learning: long-lived-agents-do-not-automatically-inherit-later-template-authority-changes -->
<a id="applied-learning-long-lived-agents-do-not-automatically-inherit-later-template-authority-changes"></a>
**Long-lived agents do not automatically inherit later template authority changes.** Updating a template's `required_capabilities` and trust preset fixes newly instantiated agents, but an already-running coding agent keeps its persisted grants and profile rules. Before dogfooding a newly enabled validation profile, inspect both `Arbor.Security.list_capabilities/1` and `Arbor.Trust.get_trust_profile/1`; reconcile the existing principal through the public facades or recreate it, otherwise the first profile action can fail `:unauthorized` even though the template and template tests are correct (found 2026-07-10 on the first real `cross_app` run).

<!-- applied-learning: long-lived-anonymous-signer-functions-can-become-invalid-after-hot-code-purge -->
<a id="applied-learning-long-lived-anonymous-signer-functions-can-become-invalid-after-hot-code-purge"></a>
**Long-lived anonymous signer functions can become invalid after hot code purge.** Session and heartbeat state currently retain the closure returned by `Arbor.Security.make_signer/2`; purging that defining module makes the stored function raise `BadFunctionError`, which the authorization boundary correctly projects as `:security_unavailable`. A restart regenerates the closure but is only a workaround. Long-lived owners need a reload-stable signer reference/factory and must refresh the short-lived closure before each turn or heartbeat without placing raw private keys in orchestrator state (found 2026-07-11 after recompiling during Phase 6 dogfood).

<!-- applied-learning: a-security-regression-must-reach-the-exact-field-that-was-vulnerable -->
<a id="applied-learning-a-security-regression-must-reach-the-exact-field-that-was-vulnerable"></a>
**A security regression must reach the exact field that was vulnerable.** A nearby counter or earlier closed-schema rejection can make a test fail while never exercising the cleanup flag, scalar alias, or identity check named in the claim. Keep each regression independent, mutate only the vulnerable field where possible, and overlay that exact test on the exact parent so an earlier guard cannot mask the intended failure (found 2026-07-11 reviewing coding benchmark parent evidence).

<!-- applied-learning: test-doubles-must-not-create-production-authorization-bypasses -->
<a id="applied-learning-test-doubles-must-not-create-production-authorization-bypasses"></a>
**Test doubles must not create production authorization bypasses.** Never mark a request identity-verified merely because a signer returned a noncanonical map so unit tests can use a stub. Production code must accept and verify the same typed proof it requires in reality; tests should construct a real proof or inject behind an explicitly test-only boundary that runtime input cannot select (found 2026-07-11 while reviewing the coding commit approval redesign).

<!-- applied-learning: template-trust-policy-changes-do-not-retroactively-update-existing-agents -->
<a id="applied-learning-template-trust-policy-changes-do-not-retroactively-update-existing-agents"></a>
**Template trust-policy changes do not retroactively update existing agents.** Restarting an agent preserves its stored `Arbor.Trust` profile, so a long-lived coding coordinator can hold newly granted action capabilities while its older baseline/rules still block them. Before dogfooding a newly added template capability, compare the live stored profile with the shipped template preset and explicitly reconcile through the Trust facade; do not diagnose the resulting capability-granted/trust-denied sequence as a worker or validator failure (found 2026-07-11 when cross-app validation and council review-tree reads failed for a reused coordinator).

<!-- applied-learning: a-process-dictionary-authorization-marker-is-not-an-opaque-capability -->
<a id="applied-learning-a-process-dictionary-authorization-marker-is-not-an-opaque-capability"></a>
**A process-dictionary authorization marker is not an opaque capability.** Any code running in the process can reproduce a predictable key/value and call the downstream public facade directly, so an internal `Process.put` preauthorization shortcut can turn double-authorization cleanup into a bypass. Carry owner-bound authority as an unforgeable broker reference, consume it at one explicit boundary, and make nested execution use a non-public owner path rather than a guessable ambient marker (found 2026-07-11 reviewing the one-shot approved-invocation branch).

<!-- applied-learning: beam-references-are-correlation-identifiers-not-bearer-secrets -->
<a id="applied-learning-beam-references-are-correlation-identifiers-not-bearer-secrets"></a>
**BEAM references are correlation identifiers, not bearer secrets.** `make_ref/0` values are sequential enough that a nearby exposed timer/monitor reference plus a digest oracle can reveal a worker-completion token on the pinned OTP runtime. Generate completion authority from cryptographically random bytes, keep it out of observable state/timers/logs, bind it to the exact run generation, and consume it once (found 2026-07-11 forging a supervised coding-benchmark result from an adjacent timer reference).

<!-- applied-learning: route-specific-proof-minting-must-refine-generic-authentication-not-replace-it -->
<a id="applied-learning-route-specific-proof-minting-must-refine-generic-authentication-not-replace-it"></a>
**Route-specific proof minting must refine generic authentication, not replace it.** Forcing every signed HTTP request through an MCP POST/body parser broke valid signed GET routes. Verify the generic method/path/body contract first, then mint a specialized one-shot intent only after the exact route/tool operation is identified (found 2026-07-11 reviewing the verified approval-answer boundary).

<!-- applied-learning: network-destination-policy-is-operator-authority-not-a-request-option -->
<a id="applied-learning-network-destination-policy-is-operator-authority-not-a-request-option"></a>
**Network destination policy is operator authority, not a request option.** A public helper that accepts caller-defined proxy prefixes, arbitrary OAuth discovery URLs, or widened private-address allowances turns endpoint validation into an SSRF bypass. Keep exact trusted origins and local-provider exceptions in startup configuration, clamp request options to that policy, validate every transport path consistently, and never match credential destinations by hostname substring (found 2026-07-11 reviewing LLM, retrieval, and OAuth endpoint gates).

<!-- applied-learning: task-and-principal-ids-are-provenance-labels-not-operation-authority -->
<a id="applied-learning-task-and-principal-ids-are-provenance-labels-not-operation-authority"></a>
**Task and principal IDs are provenance labels, not operation authority.** Requiring an exact non-empty `task_id` plus `principal_id` stops accidental cross-task access, but both values are observable and can be copied into a direct registry call or raw message. The enforcing storage owner must receive an authenticated facade-issued proof bound to that exact operation/task/principal, or perform the mutation inside the authenticated facade; do not treat matching scalar fields as a capability (found 2026-07-11 reviewing workspace cleanup receipts).

<!-- applied-learning: a-public-trust-anchor-is-security-critical-mutable-state-even-though-it-is-not-secret -->
<a id="applied-learning-a-public-trust-anchor-is-security-critical-mutable-state-even-though-it-is-not-secret"></a>
**A public trust anchor is security-critical mutable state even though it is not secret.** Keeping a verifier root public key in ordinary GenServer state lets `:sys.replace_state/2` substitute an attacker root and admit an entirely forged proof chain. Pinning trust anchors outside OTP system-message state (or in a plain sensitive owner initialized from trusted static configuration) closes that Layer-0 mutation path; it is not isolation from arbitrary same-VM code. Reject runtime replacement and regress full attacker-root session activation for the assurance layer being claimed; use an external verifier/policy boundary when T4 resistance is required (found 2026-07-11 reviewing pipeline execution provenance; assurance boundary clarified 2026-07-11).

<!-- applied-learning: label-every-security-regression-with-the-assurance-layer-it-proves -->
<a id="applied-learning-label-every-security-regression-with-the-assurance-layer-it-proves"></a>
**Label every security regression with the assurance layer it proves.** `docs/arbor/SECURITY_ARCHITECTURE.md` explicitly concedes T4 (arbitrary compromised-agent code inside the BEAM) at current Layer 0 and assigns key isolation to the target external-signer architecture. A malicious graph/tool input, ACP worker, shell child, persisted file, or public API caller is a current-layer adversary; a test that uses `:sys.replace_state`, process tracing, direct internal-module calls, code loading, or arbitrary mailbox injection demonstrates same-VM compromise instead. Opaque refs, private owner protocols, status redaction, and closed facades are still worthwhile defense in depth, but do not describe them as T4 boundaries. When T4 is required, use a separate OS process/UID or a separate cluster behind authenticated non-distribution transport; Erlang distribution mesh membership is code-execution authority, not isolation (clarified 2026-07-11 after Phase 6 corrections were being rejected against target-layer guarantees using Layer-0 mechanisms).

<!-- applied-learning: crash-reconstructable-role-authority-must-survive-the-role-process-pid -->
<a id="applied-learning-crash-reconstructable-role-authority-must-survive-the-role-process-pid"></a>
**Crash-reconstructable role authority must survive the role process PID.** Binding a worker's ownership query only to the coordinator PID that created it makes exact reconstruction impossible after that coordinator crashes while the worker survives under an earlier supervisor. Bind authorization to the process currently holding the fixed registered coordinator role, require the full exact durable record for authoritative ownership, and use at most a non-authoritative execution-ID hint to select that record in O(n); a hint alone must never grant adoption or cleanup authority (found 2026-07-15 reviewing Apple durable worker admission).

<!-- applied-learning: carry-destructive-object-identity-through-the-final-owning-facade -->
<a id="applied-learning-carry-destructive-object-identity-through-the-final-owning-facade"></a>
**Carry destructive object identity through the final owning facade.** A registry-side `lstat` check followed by an unbound `Git.remove_worktree/2` leaves a validation-to-use gap at the actual destructive operation. Pass the creation-captured device/inode and Git registration state into the Git facade, then revalidate both after canonicalization and immediately before execution; an outer branch check or path-only callback is not deletion authority. Document the residual same-UID double-swap limit of portable BEAM filesystem APIs (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: preserve-a-destructive-token-before-returning-a-post-create-failure -->
<a id="applied-learning-preserve-a-destructive-token-before-returning-a-post-create-failure"></a>
**Preserve a destructive token before returning a post-create failure.** A detached worktree can be created and identity-bound successfully, then fail final commit/registration verification while its immediate cleanup also fails. Return the captured composite identity in an internal retained-cleanup result and store it in the owning resource before replying; collapsing the failure to two reasons discards the only safe retry authority (found 2026-07-16 reviewing detached validation snapshots).

<!-- applied-learning: do-not-broaden-closed-production-identity-gates-to-make-integration-tests-faster -->
<a id="applied-learning-do-not-broaden-closed-production-identity-gates-to-make-integration-tests-faster"></a>
**Do not broaden closed production identity gates to make integration tests faster.** The coding benchmark intentionally grants strict provenance and artifact-lease finalization only to its two named production adapters; an arbitrary test module exporting `run/1` and `cancel/1` is not equivalent authority. Keep short-timeout behavior in test-only helpers only when the assertion does not depend on that production identity, extract a separately testable lifecycle primitive when the boundary warrants it, or accept the slower exact integration test. A 2026-07-18 attempt generalized the production gate and added a flat-task production seam, then a steered test-only rewrite duplicated adapter behavior and still took 131 seconds; neither change was integrated.

<!-- applied-learning: agent-template-trust-changes-are-not-retroactive-for-existing-live-principals -->
<a id="applied-learning-agent-template-trust-changes-are-not-retroactive-for-existing-live-principals"></a>
**Agent template trust changes are not retroactive for existing live principals.** A template can declare a new action capability and trust rule while an already-created agent still has the capability but falls through to its older baseline trust mode, blocking the action at runtime. Before dogfooding a newly granted action, compare the live principal's effective trust decision with the current template and reconcile only the exact missing rules or recreate the agent; do not weaken the baseline to compensate (found 2026-07-17 when `coding_reviewed_commit` passed validation but the live coding agent retained an older `:block` profile).
