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
  `EgressGate.decide/5` is a cond with THREE distinct branches — do not collapse
  them, the difference is load-bearing:
  1. external + `:hostile` → `{:block, :hostile}`. **Absolute**; no capability
     overrides it.
  2. external + `:untrusted` → `:allow` **if** the agent holds a route-scoped
     **disclosure capability** (`arbor://egress/disclose/...`) and no explicit
     `:block`; otherwise `{:block, :untrusted}`. This branch is NOT absolute —
     the disclosure cap is the designed relief valve.
  3. everything else (incl. `on_host`) → `policy_mode`, whose fallback is
     `config :arbor_trust, :default_egress_modes` (**`:arbor_trust`, not
     `:arbor_security`** — `Arbor.Trust.Policy.default_egress_mode/1`). Library
     default is conservative (`external_provider: :ask`); `dev.exs` already sets
     `%{external_provider: :allow}`.
- **Symptom:** a cloud-LLM agent's call is refused (`requires_approval`), or an agent
  processing web/tainted content can't send it to an external provider. On a session
  turn this surfaces as `⛔ Egress blocked: session turn-egress authorizer refused
  (:initial_denied)`.
- **Action:** for local-first, use `on_host` models (unaffected). For cloud egress,
  ensure `external_provider: :allow` in the profile's `egress_modes`, or issue a
  disclosure capability (`Arbor.Security.issue_disclosure_capability/1`) scoped to
  the route. Tainted→external is *meant* to gate — that's the exfil defense, not a
  misconfiguration.
- **Both interesting branches are currently unreachable in production (2026-08-20).**
  Nothing outside `arbor_security` mints a disclosure capability, so branch 2 can
  never take its `:allow` path; and no ingress ever assigns `:hostile` (`web.ex`
  ingress declares `output_taint :untrusted`; `:hostile` appears only as a
  fail-closed deserialization fallback in `checkpoint.ex`), so branch 1 never
  fires. In practice the cond collapses to "untrusted → block, always", which is
  why a fresh agent cannot hold a cloud-model conversation. Branch 2 is
  `.arbor/roadmap/0-inbox/session-disclosure-capability-minting.md`; branch 1 is
  H4 of `.arbor/roadmap/2-planned/prompt-injection-defense-plan.md` (local Prompt
  Guard 2 escalating taint to hostile). Until H4 lands, `:untrusted` is the only
  level that ever reaches this gate — so treat branch 2 as the whole defense.
- **A user chat message is `:untrusted`**, not `:trusted` — `session.ex` tags it
  `level: :untrusted, chain: ["session_steering"]`. So "use the turn's actual taint
  instead of worst-case" is a no-op for chat; the actual value already IS
  untrusted. Do not re-propose it as a fix for `:initial_denied`.

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

- **What:** what the model *sees* is distinct from what it may *execute* (caps +
  trust mode). Since 2026-08-25, `ToolDisclosure.profile_tools/1` shows the
  **floor** (`core_tools/0`: memory, skills, find_tools, generate) **∪ tools whose
  capability the agent HOLDS**; policy-mintable-but-unheld tools are hidden until
  `tool_find_tools` surfaces them (it searches the full catalog). "Holds" is
  segment-aware in both directions — exact, ancestor wildcard (`arbor://fs/**`),
  AND scoped descendant (`arbor://fs/read/<dir>/**`) all disclose `file_read`.
  Before this, every mintable URI was disclosed (a 12-cap conversationalist saw
  120 tools) and path-scoped grants did NOT expose their tool (exact-match
  reverse map).
- **Symptom:** the agent can't see a tool it is only *mintable* for (expected —
  it must discover it), or flails on a tool it sees but a `:block` rule hides
  execution for (`:block` also hides it from disclosure, so check the profile).
- **Action:** grant the capability if the tool should be visible by default;
  `config["tools"]` still pins an explicit set (authoritative, no find_tools
  injection). If a held scoped grant does NOT expose its tool, the canonical
  action URI is probably not an ancestor of the grant — compare
  `Arbor.Actions.tool_name_to_canonical_uri/1` with the held URI. Pipeline-internal
  syscalls (`tags: ["pipeline_internal"]`) are excluded from disclosure on BOTH
  paths — `Actions.tool_modules_for_agent/1` (APIAgent) and
  `ToolDisclosure.profile_tools/1` (DOT session) — the latter only since 61f76e4b6.

## 8. Unregistered capability URIs (when the URI registry is enforcing)

- **What:** `Arbor.Security.UriRegistry` allowlists capability URIs by prefix; with
  enforcement on, granting/using an unregistered URI is rejected.
- **Symptom:** a brand-new resource URI (e.g. a new eval action) is denied despite a
  grant.
- **Action:** for generated `arbor://action/...` URIs, first ensure the action module
  is present in `Arbor.Actions.all_actions/0`. `Arbor.Actions.Application` projects
  that catalog into both action resolution and `UriRegistry` at startup; manually
  registering only the URI masks a broken action catalog. For non-action resources,
  add the canonical URI prefix to the owning registry allowlist (e.g.
  `arbor://eval/search` was added for the eval fixture). This was the second hidden
  failure in the 2026-08-22 heartbeat incident: `PruneStaleIntents` existed in source
  and DOT but was absent from `all_actions/0`, so lookup failed and its derived URI
  was never registered.

## 9. Native ACP tool callbacks need subtree authority

- **What:** starting an ACP session and authorizing the worker's native tool callbacks
  are separate operations. `AcpSession.Handler` maps a bounded, machine-readable tool
  name or kind to `arbor://acp/tool/<tool>`. Some providers expose only a documented
  opaque callback namespace: Kiro `2.19.1` uses `tooluse_*`, which Arbor accepts only
  when the code-owned session provider is `kiro` and maps to the coarse child
  `arbor://acp/tool/kiro`. A concrete `arbor://acp/tool` capability does not authorize
  any of these child resources.
- **Symptom:** the delegated worker starts normally, then its first native tool request
  is denied or cancelled despite holding the base capability. Descriptive ACP titles
  such as an entire shell command are not authorization identities and fail closed
  unless the payload also supplies a canonical `name`, `toolName`, `tool_name`, `kind`,
  typed `toolCallId` prefix, or a provider-bound opaque ID namespace. Never infer
  authority from the title or from an untrusted provider field in the callback.
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

## 13. Cluster security-sync is optional until subscribers are configured

- **What:** Identity.Registry, NonceCache, and CapabilityStore call
  `SignalSync.establish/3` at init. Cluster subscriptions are admitted only for
  the configured registered owner and its fixed events. An empty or missing
  `security_sync_subscribers` map is local-only. A configured role that cannot
  subscribe still aborts the store.
- **Symptom:** a fresh VM or Mix-release peer that never loaded `sys.config`
  used to fail `arbor_security` with
  `{:security_sync_subscription_failed, {:subscription_failed, _, :unauthorized}}`.
- **Action:** leave subscribers unset for single-node/safe-recovery start. Load
  the release `sys.config` when the node should join cluster sync. Do not treat
  an unconfigured transport as a cluster, and do not fail-open a configured one.

## 14. Sandbox actions require `authorized_principal` (no host-create fallback)

- **What:** `Arbor.Actions.Sandbox.Create` / `Destroy` are the agent/extension
  surface. They never call unauthenticated `Arbor.Sandbox.create/destroy`.
  They consume `Arbor.Actions.authorized_principal(context, __MODULE__)`, not
  a truthy `context[:agent_id]`. Direct `run/2` that only supplies
  `agent_id` fails closed with the existing Unauthorized vocabulary. The
  authorized path is `Arbor.Actions.authorize_and_execute/4` then
  `authorize_create` / `authorize_destroy` (`arbor://sandbox/create` /
  `arbor://sandbox/destroy`). Host/unit tests with no principal keep using
  `Arbor.Sandbox.create/destroy` directly.
- **Symptom:** `sandbox_create` / `sandbox_destroy` returns
  `Unauthorized: :action_principal_authority_required` when the action
  context has no facade-issued envelope, even if `context[:agent_id]` names
  another principal that holds the sandbox grant. Params `agent_id` is the
  *target* the sandbox is created for, not the caller.
- **Action:** invoke sandbox actions through `authorize_and_execute` so the
  executor issues the principal envelope, and grant the matching sandbox
  capability. Use distinct caller vs target ids:
  ```elixir
  Arbor.Actions.authorize_and_execute(
    "agent_caller",
    Arbor.Actions.Sandbox.Create,
    %{agent_id: "agent_target", level: "limited"},
    %{agent_id: "agent_caller"}
  )
  ```
  Do not treat `Arbor.Sandbox.create/2` as an action/extension API.

## 15. Trusted-system `Shell.execute` / `execute_direct` reject a smuggled principal

- **What:** `Arbor.Shell.execute/2` and `execute_direct/3` are trusted-system
  host APIs. They reject `:agent_id` / `:principal_id` (atom key first, then
  the string-key fallback) so an extension cannot smuggle a principal onto
  the host path. Agent callers stay on `authorize_and_execute/3`. Host tests
  with no principal still use `execute` / `execute_direct`.
- **Symptom:** `Shell.execute` / `execute_direct` with a principal key
  returns `{:error, :unauthorized}` and does not launch. The same call with
  no principal key still launches.
- **Action:** do not pass a principal onto the host path. Agent/extension
  callers use `Arbor.Shell.authorize_and_execute/3` or
  `Arbor.Actions.Shell.authorize_and_execute_command/4`. Do not treat
  `Arbor.Shell.execute/2` as an action/extension API.

## 16. Eval-session calls require `authorize_eval` (no host-eval fallback)

- **What:** `Arbor.Sandbox.authorize_eval/4` is the agent/extension
  surface for eval-session. It `Security.authorize/4`s
  `arbor://sandbox/eval` then calls `ExecSession.eval/3`. Missing or
  denied caller fails closed with `{:error, {:unauthorized, reason}}`
  and does not evaluate. Host `eval_code/3` stays the trusted-system
  API with no principal.
- **Symptom:** `authorize_eval` returns `{:error, {:unauthorized, …}}`
  when the caller has no grant. Session bindings are unchanged.
  Calling `eval_code/3` from an extension bypasses the gate — that
  path is host-only.
- **Action:** grant `arbor://sandbox/eval` and call `authorize_eval/4`.
  Host/unit tests with no principal keep using `eval_code/3`.
  Do not treat `eval_code/3` as an action/extension API.

## 17. Git Jido actions require `authorized_principal` (no execute_direct fallback)

- **What:** `Arbor.Actions.Git.Status` / `Diff` / `Commit` / `Log` / `Branch` /
  `PR` are the agent/extension surface. They consume
  `Arbor.Actions.authorized_principal(context, __MODULE__)`, then the existing
  Git TCB (`Git.execute/2`). Direct `run/2` that only supplies a path fails
  closed with `Unauthorized: :action_principal_authority_required` and does
  not launch git. Git is not an agent executable — these actions never call
  `Arbor.Shell.authorize_and_execute/3`. Host `Git.execute/2` stays callable
  without a principal.
- **Symptom:** `git_status` / `git_diff` / `git_commit` / `git_log` /
  `git_branch` / `git_pr` returns `Unauthorized: :action_principal_authority_required`
  when the action context has no facade-issued envelope, even if
  `context[:agent_id]` names another principal.
- **Action:** invoke Git actions through `authorize_and_execute` so the
  executor issues the principal envelope, and grant the matching
  `arbor://action/git/<op>` capability. Host/unit tests with no principal
  keep using `Arbor.Actions.Git.execute/2` directly. Do not treat
  `Git.execute/2` as an action/extension API.

## 18. Mix Jido Compile/Test/Format/Quality/Xref require `authorized_principal` (no run_mix fallback)

- **What:** `Arbor.Actions.Mix.Compile` / `Test` / `Format` / `Quality` /
  `Xref` are the agent/extension surface. They consume
  `Arbor.Actions.authorized_principal(context, __MODULE__)`, then the
  existing Mix TCB (`run_with_required_workspace/5`). Direct `run/2`
  without the envelope fails closed with
  `Unauthorized: :action_principal_authority_required` and does not
  launch mix. Mix is not an agent executable — these actions never call
  `Arbor.Shell.authorize_and_execute/3`. Host `run_mix/3` and
  `run_with_required_workspace/5` stay callable without a principal.
  `Code.CompileAndTest` uses the Mix TCB after its own envelope, never
  nested `Mix.Compile.run` / `Mix.Test.run`.
- **Symptom:** `mix_compile` / `mix_test` / `mix_format` / `mix_quality` /
  `mix_xref` returns
  `Unauthorized: :action_principal_authority_required` when the action
  context has no facade-issued envelope, even if `context[:agent_id]`
  names another principal.
- **Action:** invoke Mix Compile/Test/Format/Quality/Xref through
  `authorize_and_execute` so the executor issues the principal envelope,
  and grant `arbor://action/mix/<op>`. Host/unit tests with no principal
  keep using `Arbor.Actions.Mix.run_mix/3` or
  `run_with_required_workspace/5`. Do not treat those TCB helpers as
  an action/extension API.

## 19. Web Jido Browse/Search/Snapshot/ExaSearch/TinyfishSearch require `authorized_principal` (no ungated network)

- **What:** `Arbor.Actions.Web.Browse` / `Search` / `Snapshot` /
  `ExaSearch` / `TinyfishSearch` are the agent/extension surface. They
  consume `Arbor.Actions.authorized_principal(context, __MODULE__)`, then
  the existing network/credential implementation (`jido_browser` or `Req`
  plus env API keys). Direct `run/2` without the envelope fails closed with
  `Unauthorized: :action_principal_authority_required` and does not call
  `Req.post`/`Req.get` or `jido_browser`. Web is not an agent executable —
  these actions never call `Arbor.Shell.authorize_and_execute/3`. There is
  no host Web facade.
- **Symptom:** `web_browse` / `web_search` / `web_snapshot` /
  `exa_search` / `tinyfish_search` returns
  `Unauthorized: :action_principal_authority_required` when the action
  context has no facade-issued envelope, even if
  `context[:agent_id]` names another principal.
- **Action:** invoke Web Browse/Search/Snapshot/ExaSearch/TinyfishSearch
  through `authorize_and_execute` so the executor issues the principal
  envelope, and grant `arbor://net/http` (Browse/Snapshot) or
  `arbor://net/search` (Search/ExaSearch/TinyfishSearch). Do not invent a
  host Web facade or send these through `Shell.authorize_and_execute`.

## 20. Browser Jido actions require `authorized_principal` (no ungated jido_browser)

- **What:** All 26 `Arbor.Actions.Browser.*` Jido actions
  (`StartSession`, `EndSession`, `GetStatus`, `Navigate`, `Back`,
  `Forward`, `Reload`, `GetUrl`, `GetTitle`, `Click`, `Type`, `Hover`,
  `Focus`, `Scroll`, `SelectOption`, `Query`, `GetText`, `GetAttribute`,
  `IsVisible`, `ExtractContent`, `Screenshot`, `Snapshot`, `Wait`,
  `WaitForSelector`, `WaitForNavigation`, `Evaluate`) are the
  agent/extension surface. They consume
  `Arbor.Actions.authorized_principal(context, __MODULE__)`, then the
  existing session / SSRF / `jido_browser` implementation. Direct `run/2`
  without the envelope fails closed with
  `Unauthorized: :action_principal_authority_required` and does not call
  `JidoBrowser.Actions.*.run`. A spoofed `context[:agent_id]` or fake
  `browser_session` without the envelope is not authority. Browser is not
  an agent executable — these actions never call
  `Arbor.Shell.authorize_and_execute/3`. There is no host Browser facade.
  Canonical URIs stay `arbor://action/browser/<op>` (derived). Navigate
  still runs `Web.validate_url/1` after the principal gate.
- **Symptom:** `browser_start_session` / `browser_navigate` /
  `browser_wait` / other `browser_*` actions return
  `Unauthorized: :action_principal_authority_required` when the action
  context has no facade-issued envelope, even if
  `context[:agent_id]` names another principal or `browser_session` is
  present.
- **Action:** invoke Browser actions through `authorize_and_execute` so
  the executor issues the principal envelope, and grant
  `arbor://action/browser/<op>`. Session-required actions still need a
  session after the envelope. Do not invent a host Browser facade or send
  these through `Shell.authorize_and_execute`.

## 21. SignedRequest auth fails closed when a peer could serve the same request

- **What:** `Arbor.Gateway.SignedRequestAuth` calls `Arbor.Security.verify_request/1`,
  whose first step is `Config.admit_cluster_signed_request_replay_protection/0`. Nonces
  are node-local, and cross-node `nonce_seen` propagation is not authoritative without
  an authenticated security-sync transport — and
  `Arbor.Signals.Config.authenticated_security_sync_transport?/0` is **hardcoded
  `false`** by design ("There is no production env flag that re-opens unauthenticated
  apply"). So when another node could accept the same captured `SignedRequest`, this
  node refuses rather than accept a replayable signature.
- **Symptom:** an external agent (`mix arbor.signer` → gateway `/mcp`) gets
  **HTTP 401 `"Missing API key. Provide via Authorization: Bearer <key> or x-api-key
  header"`** — misleading, because the plug chain is *non-destructive passthrough*:
  signed-request auth silently failed, then JWT, then API key produced the visible
  error. The MCP client sees the server fail `initialize` and drops it, so the tools
  simply never appear — no "server failed" banner in some hosts. The real reason is
  only in the gateway log at `[debug]`:
  `[SignedRequestAuth] Verification failed: :cluster_replay_protection_unavailable`.
  The agent identity is fine — `lookup_public_key_for_agent/1` and `identity_active?/1`
  both succeed, which is what makes this look like a config or key problem.
- **Action:** ask *which* peer is responsible, not whether any peer exists.
  `Arbor.Security.Identity.ReplayPeers` classifies each connected node: a peer running
  `:arbor_security` is a replay target, one that isn't (an SDR recorder, a build box, an
  attached `iex`) is foreign and does not trip the gate. Everything not positively
  foreign counts as a peer, so an outstanding probe, an unreachable node, or a tracker
  that isn't running all fail closed.
  ```elixir
  # triage on the running node (tidewave / iex) — names the actual blocker
  {Arbor.Security.Identity.ReplayPeers.list(),
   Arbor.Security.Config.admit_cluster_signed_request_replay_protection()}
  ```
  If the blocker is a real Arbor node, that is a true positive: signed external-agent
  MCP is unavailable while a dev box shares a mesh with another gateway that could
  accept the replay. Drop the peer, or use a non-signed credential path. Do **not** try
  to flip the transport flag; it is deliberately unflippable.
- **Disconnecting a peer is two-sided, and transitive.** `Node.disconnect/1` alone
  never holds: `Arbor.Cartographer.ClusterKeeper` runs on *both* ends and redials
  every 30s, so forgetting locally just means the peer redials you. Use
  `mix arbor.cluster disconnect node@host`, which asks the remote keeper to forget
  this server first. Even that is not enough when a third node bridges them: Erlang
  keeps a **fully-connected mesh**, so any non-hidden node connected to both will
  force them back together no matter how often you disconnect. Check with
  `:erpc.call(bridge, Node, :list, [])`. Foreign nodes that only need to talk to one
  Arbor node should launch `-hidden` (or `-connect_all false`) so they never bridge.
  Verified 2026-08-19: an SDR recorder on a BeagleBone, started plain
  `--name sdr_node@…`, silently re-meshed a dev box with the prod gateway within
  30s of every disconnect.
- **The gate counts `Node.list(:connected)`, not `Node.list()`.** The default is
  `:visible`, which omits hidden nodes — and a hidden node can still run
  `:arbor_security` and accept a replay. Counting only visible nodes would let one
  launch flag silence the gate. `ReplayPeers` uses `:connected` and
  `monitor_nodes(true, node_type: :all)` for the same reason.
- **History:** the gate landed in `4bda3a047` (2026-08-18) keyed on bare
  `Node.list() != []`, which refused *every* signed request on any clustered node —
  the normal state of a dev machine. It broke Claude Code, Codex, Grok and Hermes
  simultaneously and silently, and was only visible as that 401. Narrowed to
  replay-relevant peers on 2026-08-19; regression tests in
  `apps/arbor_security/test/arbor/security/distributed_test.exs`.

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
   capability alone only names the namespace. Provider-bound opaque callbacks use a
   coarse child such as `arbor://acp/tool/kiro`, never their descriptive title.
9. For nested reviewed graphs, grant every pinned child action's exact canonical URI;
   outer-action and domain capabilities do not substitute for action authority.
10. For binding council runs, grant and auto-trust the exact
    `arbor://action/coding/review/submit` terminal action; reconcile existing agents
    because template changes are not retroactive.
11. For native ACP workers, isolate provider config and bind the session MCP list;
    `mcpServers: []` does not disable provider-global or project MCP servers.
12. For a single-node or safe-recovery boot, omit `security_sync_subscribers`
    so security stores start local-only; load release `sys.config` when cluster
    sync is required.
13. For `sandbox_create` / `sandbox_destroy`, invoke
    `authorize_and_execute` so the caller envelope is issued; grant
    `arbor://sandbox/create` or `arbor://sandbox/destroy`. Params `agent_id`
    is the target, not the caller. A spoofed `context[:agent_id]` without
    the envelope is not sandbox authority.
14. For host `Shell.execute` / `execute_direct`, omit principal keys. A
    smuggled `:agent_id` / `:principal_id` is `:unauthorized` and does not
    launch. Agent callers use `authorize_and_execute`.
15. For eval-session, grant `arbor://sandbox/eval` and call
    `Arbor.Sandbox.authorize_eval/4`. Host `eval_code/3` has no principal
    and is not an agent/extension API.
16. For `git_status` / `git_diff` / `git_commit` / `git_log` / `git_branch` /
    `git_pr`, invoke `authorize_and_execute` so the caller envelope is issued;
    grant `arbor://action/git/<op>`. A spoofed `context[:agent_id]` without
    the envelope is not git authority. Host `Git.execute/2` has no principal
    and is not an agent/extension API.
17. For `mix_compile` / `mix_test` / `mix_format` / `mix_quality` /
    `mix_xref`, invoke `authorize_and_execute` so the caller envelope is
    issued; grant `arbor://action/mix/<op>`. A spoofed `context[:agent_id]`
    without the envelope is not mix authority. Host `run_mix/3` /
    `run_with_required_workspace/5` have no principal and are not an
    action/extension API.
18. For `web_browse` / `web_search` / `web_snapshot` / `exa_search` /
    `tinyfish_search`, invoke `authorize_and_execute` so the caller
    envelope is issued; grant `arbor://net/http` or `arbor://net/search`.
    A spoofed `context[:agent_id]` without the envelope is not web
    authority. Do not invent a host Web facade.
19. For `browser_*` actions, invoke `authorize_and_execute` so the caller
    envelope is issued; grant `arbor://action/browser/<op>`. A spoofed
    `context[:agent_id]` or fake `browser_session` without the envelope
    is not browser authority. Do not invent a host Browser facade.

## 22. Taint LEVEL is provenance — a classifier may only escalate it

- **What:** `Arbor.Contracts.Security.Taint` is four-dimensional, and `level`
  (`:trusted | :derived | :untrusted | :hostile`) tracks **provenance**, not
  safety — "where did this come from", which is a historical fact. `join/2` uses
  `max_by(levels(), …)`, so level is monotonically non-decreasing under
  composition, and nothing in the tree ever raises content TO `:trusted`.
- **Symptom:** a proposal to "reclassify `:untrusted` → `:trusted` once the
  injection classifier passes it", or code that reads a scan result and lowers
  `level`.
- **Action:** never downgrade `level` on a detector result. A classifier can only
  *fail to find* something; "Prompt Guard 2 didn't flag this" is not "this is
  safe", and treating the first as the second is exactly what the H4 section of
  `.arbor/roadmap/2-planned/prompt-injection-defense-plan.md` refuses ("assume it
  fails against a motivated attacker — that's why it's telemetry, not boundary").
  Classifiers move taint UP only (`:untrusted → :hostile`).
- **Record a clean scan in the dimensions built for it, not in `level`:** the
  `sanitizations` bitmask has a `prompt_injection` bit (`0b00010000`), and
  `confidence` runs `:unverified → :plausible → :corroborated → :verified`.
  "Untrusted, injection-screened, corroborated" is more useful and more honest
  than a laundered `:trusted`.
- **The only legitimate downgrade is STRUCTURAL, and it stops at `:derived`.**
  Quarantined extraction reduces `:untrusted`/`:hostile` → `:derived` when a value
  passes a strict mechanically-checkable schema (`enum` / `int` / `match`), because
  an integer *cannot carry* a payload — a structural guarantee, not an opinion.
  `Outcome.taint_reductions` is the other path (e.g. human review). Neither ever
  reaches `:trusted`. That is why there are four levels and not three: `:derived`
  distinguishes *foreign but structurally constrained* from *born inside the TCB*.
- **`:trusted` is real and still reachable — just never by derivation.** It is for
  values Arbor authored that never touched a model or an external source: identity
  data (`Signals.Taint.identity_taint`), explicit `TaintedValue` trusted wraps,
  operator-authored config and graphs. Note `SignalTaint.for_llm_output/1` joins
  every LLM output against a `:derived` floor, so **even perfectly trusted input
  yields `:derived` output** — the model is not in the TCB either.
- **Taint is NOT only for LLM-bound data.** `arbor_actions` threads
  `operation_taint` into `Arbor.Security.Escalation` risk hints and into
  `egress_taint`, and `ExecHandler` computes `Context.worst_taint/2` over an exec
  node's `context_keys` to carry per-parameter taint to the action enforcement
  boundary. So `:trusted` vs `:derived` already decides whether a capability-gated
  action runs or escalates to human approval — not a future concern. For values
  crossing a process or node boundary, bind them through
  `Arbor.Contracts.Security.TaintEnvelope` (versioned, payload-digest-bound,
  deliberately separate from the process-local `%Taint{}`) so provenance cannot be
  stripped or swapped in transit.
- **Useful test when assigning a level:** not "did an LLM see it?" but *"could an
  adversary have influenced this byte?"* No → `:trusted`. Came out of a model →
  `:derived` floor. Came from outside → `:untrusted`.

## 23. `mix arbor.user.link` requires possession-proof plus `arbor://identity/alias/manage`

- **What:** Linking or unlinking OIDC aliases is an admin-class operation.
  `IdentityAliases.link/3` and `unlink/2` authorize
  `arbor://identity/alias/manage` with `verify_identity: true` and a
  `SignedRequest` the **CLI produced** from a `.arbor.key` file it holds
  (`mix arbor.user.init` writes `~/.arbor/operator.key` at 0600). The
  signed payload is bound to the **specific mutation**, not merely to the
  alias-management resource: version tag + operation (`link`/`unlink`) +
  every argument, each length-prefixed. The server reconstructs that
  payload from the arguments it is about to act on and requires an exact
  match; a proof for one link cannot authorize a different link or an
  unlink. `--as` names which key file to use; it is not authority. The
  server only verifies. It does not load a stored private key and sign on
  a caller-named principal's behalf.
- **Symptom:** `mix arbor.user.link` reports a possession-proof failure
  (`key file not found`, `principal_mismatch`, `:missing_signed_request`),
  a payload mismatch (`:payload_mismatch`), or a capability denial
  (`:unauthorized`) instead of linking. A previous confused-deputy design
  (`authorize_as_stored_principal`) would have succeeded for
  `mix arbor.user.link --as <victim>` whenever the victim's key sat in
  SigningKeyStore.
- **Action:** Run `mix arbor.user.init` so the operator key file exists,
  pass `--as <that principal>` (and `--key-file` if it is not at
  `~/.arbor/operator.key`), and grant `arbor://identity/alias/manage` to
  that principal. Do **not** add a server-side "sign as this principal_id"
  path. Proof failures, payload mismatches, and capability denials are
  distinct `{:unauthorized_alias_management, reason}` values.

## 24. OpenCode Zen keyless egress is an explicit, gated allowance

- **What:** OpenCode Zen (`https://opencode.ai/zen/v1`) is a keyless free-tier
  LLM. There is no API-key consent signal, so egress to `opencode_zen` /
  `opencode.ai` is **not** implied by `external_provider: :allow`. It requires
  `config :arbor_security, :allow_opencode_zen_egress` (`true` only in
  `dev.exs`; default `false`). This check is **always on** and runs before
  the general `egress_gate_enforcing` dark-launch short-circuit — a dark
  gate still denies keyless destinations when the allowance is absent.
  Production must set the flag explicitly. Independently, the first request
  is blocked until the user acknowledges the data-disclosure warning
  (`Arbor.LLM.OpenCodeZen.ensure_acknowledged/0`), and dispatch refuses any
  model that is not in the admitted catalog.
- **Symptom:** `EgressGate.decide` / `Arbor.Security.authorize_egress/3`
  returns `{:block, :keyless_egress_not_allowed}` (or
  `{:error, {:egress_blocked, :external_provider, :keyless_egress_not_allowed}}`)
  when the flag is absent, including with the shipped defaults
  (`egress_gate_enforcing: false`, `allow_opencode_zen_egress: false`). LLM
  complete returns `{:error, :disclosure_not_acknowledged}` before any HTTP
  request if the disclosure was not acknowledged, or
  `{:error, {:opencode_zen_model_not_admitted, id}}` for a rejected/unknown
  model such as `big-pickle`. The relay itself 401s any `Authorization`
  bearer, including placeholders.
- **Action:** In development the flag is already on. For production, set
  `allow_opencode_zen_egress: true` deliberately, show the disclosure, and do
  not send a credential. Do not spoof `User-Agent: opencode/latest` to unlock
  UA-gated models.
- **Eval probe pins are per-principal, not Application env.** Heartbeat
  workers do not inherit Mix-task process dictionary, so
  `with_probe_models/2` never reaches `admit_model/2` on that path. Pinning
  via `:eval_opencode_zen_probe_ids` admitted the model for every other
  agent in the same BEAM (including Bootstrap/Reconciler auto-starts).
  `TaskEval` registers probe ids against the eval `agent_id`; `admit_model/2`
  looks them up only when dispatch opts carry that principal from
  `RunAuthorization`. Unregister on teardown. This is measurement, not an
  `admission.json` write (found 2026-08-23 closing the Codex leftover).

## Applied Learning: Security Gates

Read this when changing capabilities, trust, authorization, identity, URI matching, taint, egress, or proof boundaries.

## 25. `:auto` mode does not mint an UNPROFILED URI

- **What:** `Arbor.Trust.PolicyEnforcer` JIT-mints only URIs that have an entry in
  `Arbor.Trust.CapabilityRiskProfiles` (or an action-namespace profile). A URI
  with no profile is refused with `:unprofiled` even when the effective mode is
  `:auto` — mode says "may mint", the profile says "what it costs"; missing the
  latter fails closed.
- **Symptom:** `Trust.effective_mode/3` reports `:auto`, disclosure shows the tool,
  yet execution returns `{:error, :unauthorized}` and the log has
  `[Trust.PolicyEnforcer] refused to mint <uri>: :unprofiled`. Hit twice on
  2026-08-25: `arbor://memory/add_knowledge` (memory_remember) and
  `arbor://agent/discover_tools` (tool_find_tools — never exercised before, then
  load-bearing the moment disclosure became floor ∪ held).
- **Action:** add the profile row (`{uri, owner, blast_radius, reversibility,
  effect_class, data_class, arg_dependent, default_approval, graduation_eligible,
  cost_class, constraints}`) and commit a test that calls `Trust.authorize/3`
  under an `:auto` rule — not just one that checks disclosure. Grep the enforcer
  log for `:unprofiled` after wiring any new tool.


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

<!-- applied-learning: opaque-identifiers-in-capability-uris-must-not-become-uri-syntax -->
<a id="applied-learning-opaque-identifiers-in-capability-uris-must-not-become-uri-syntax"></a>
**Opaque identifiers interpolated into capability URIs must not become URI syntax.** A caller-supplied task id such as `**` can turn an intended exact grant like `arbor://agent/task/adopt/<task-id>` into a recursive wildcard capability. Before constructing a scoped capability URI, either encode/digest the opaque id into one safe segment or enforce a bounded single-segment alphabet; reject `/`, `*`, traversal segments, whitespace/control bytes, and invalid UTF-8 before any grant occurs (found 2026-07-21 while reviewing post-terminal coding-task adoption).

<!-- applied-learning: local-oidc-http-issuers-need-allow-http-wired-through-runtime-config -->
<a id="applied-learning-local-oidc-http-issuers-need-allow-http-wired-through-runtime-config"></a>
**Local OIDC HTTP issuers need `allow_http` wired through runtime config.** Discovery and AuthCodeFlow reject `http://` unless the provider map has `allow_http: true`. Setting `OIDC_ISSUER=http://localhost:8080` alone yields dashboard 502 `{:invalid_issuer, :scheme_not_allowed}`. `Arbor.Security.OIDC.Config.allow_http?/2` is the single resolver; `runtime.exs` and CLI fallbacks must call it. Production stays fail-closed unless `OIDC_ALLOW_HTTP=true`; non-prod loopback HTTP (`localhost` / `127.0.0.1` / `::1`) defaults open (found 2026-08-24 launching local Zitadel).

<!-- applied-learning: telemetry-bridged-security-audits-are-observations-not-sync-mutations -->
<a id="applied-learning-telemetry-bridged-security-audits-are-observations-not-sync-mutations"></a>
**Telemetry-bridged security audits are observations, not sync mutations.**
Security lifecycle audit events are reflected onto the same restricted topics used by the
temporary distributed-sync transport and carry `permanent: true`. A sync reducer must reject
that marker before classifying remote authority direction; otherwise a delayed local suspension
audit can re-suspend an identity after resume, while the corresponding authority-restoring echo
is correctly denied and cannot repair the state. Preserve the audit payload distinction instead
of adding sync provenance to it, which would also make observers count both the direct mutation
and its audit reflection as sync events (found 2026-08-21 during the approval CLI Security-suite
verification).

<!-- applied-learning: a-tool-s-capability-uri-must-reflect-its-maximum-effect-not-its-default-action -->
<a id="applied-learning-a-tool-s-capability-uri-must-reflect-its-maximum-effect-not-its-default-action"></a>
**A tool's capability URI must reflect its maximum effect, not its default action.** `memory_review_queue` defaults to `action: "list"` but also accepts `approve`/`reject`/`approve_all`, and the approve path calls `Arbor.Memory.accept_proposal/2`, which CREATES a knowledge node. It was mapped to `arbor://memory/read`, so a read-only capability could mutate the graph through it (found 2026-08-25 auditing the memory tool surface). Any action-dispatching tool — one with an `action:`/`mode:`/`op:` parameter — has to be gated on the most powerful branch it can reach, because the capability is checked once at the tool boundary and never re-checked per branch. Two corollaries: when auditing a URI map, read each action's BRANCHES rather than its name or description; and this is a standing argument against merging read and write tools to slim a tool surface, since the merged tool must then carry the write capability for everyone who only wanted to list.