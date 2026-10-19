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

## Private turns: memory write containment (2026-09-09)

- **What:** receipt-authenticated private Session turns carry a source-owned
  `memory_write_policy: :deny` until scoped writers and readers are qualified.
  Memory-family mutations and child-launch routes that lose the restriction
  are unavailable; native runtimes include the legacy `provider: "acp"` adapter
  even when its route says `runtime: "arbor"`.
- **Symptom:** `:private_turn_memory_write_denied` on an action, or
  `:memory_write_policy_runtime_unsupported` before provider execution.
- **Action:** keep the denial and use the supported Arbor runtime. More grants,
  a permissive tool argument, or a `fact` type cannot relax this source policy.
  Replace the denial only with a qualified scoped Memory operation; see
  [the current boundary and next ownership slice](../../docs/arbor/PRIVATE_TURN_MEMORY_WRITES.md).

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

## 1A. Distributed security-sync mutation publishers are owner-bound

- **What:** `security.nonce_seen` and the authority-reducing capability/identity
  mutations are live security state, not ordinary observability. The Signals bus
  accepts a local publication only from the exact supervised owner that established
  the configured security-sync subscription. Missing, malformed, or ambiguous
  publisher configuration fails closed for these mutation types. Other security and
  identity observability events remain publishable when no sync publisher is defined.
- **Symptom:** `Arbor.Signals.emit/4` returns `{:error, :unauthorized}` and the event
  is neither delivered locally nor relayed. This commonly means the Security owner
  has not completed startup or its role/event mapping is invalid or duplicated.
- **Action:** start the canonical Security supervision tree and keep the
  `:security_sync_subscribers` map aligned with its exact owner, supervisor path,
  child ID, and event list. Emit these mutations from `CapabilityStore`,
  `Identity.Registry`, or `NonceCache` through their normal public Security flows;
  do not synthesize them from an agent, action, or observability process.

## 1B. Restricted realtime signals are not durable audit acknowledgements (2026-10-15)

- **What:** `Signals.durable_emit/4` refuses restricted categories with
  `:restricted_durable_encryption_unavailable` until restart-safe encryption
  exists, even when realtime delivery succeeds. A signal in `Signals.recent/1`
  proves only realtime retention.
- **Symptom:** an authority mutation succeeds although its purported durable
  security record was refused; a ring-buffer assertion still passes.
- **Action:** check the audit acknowledgement before changing authority, record
  a requested change as an intent rather than a completed change, and propagate
  refusals. Regression tests must assert unchanged authority on refusal. Do not
  remove restricted-topic protection to make an audit write succeed. Found while
  reviewing ApplyProfile's ignored emission result on 2026-10-15.

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
  **ROOT CAUSE PINNED 2026-10-11 (cross-library review, design-friction D1):** the
  "no fs/write ceiling" claim above is stale. `arbor://fs/write` is profiled
  `:high / :require_human` in `arbor_trust/.../capability_risk_profiles.ex:69-70`,
  which `ceiling_mode/1` (`:213-214`) projects into a `:ask` **ceiling**; a rule cannot
  beat a ceiling (`authority.ex:158`). Independently, `PolicyEnforcer.grant_decision_for_profile`
  (`policy_enforcer.ex:260-282`) clamps every JIT-minted `:auto`/`:allow` cap to `:ask`
  unless the profile is `blast_radius: :low` — and EVERY `arbor://action/**` profile is
  `:require_human` (`arbor_actions.ex:4296-4340`). The only relief,
  `ApprovalGuard.pre_approved_bypasses_ceiling?/2`, needs `metadata.provenance` AND a
  non-glob leaf, but workspace caps are minted as `arbor://fs/write/<root>/**` with no
  provenance (`lifecycle.ex:2258-2267`). Net: no action URI can be made autonomous by a
  trust rule; only an operator-minted standing cap with provenance works. Until the
  relief path is designed (stamp provenance + bounded leaf on workspace caps, or let
  operators override `default_approval` for a workspace root), either provision such a
  cap or have the agent return output another way. (The crm-export eval task outputs
  its report in the response instead of `file_write` for exactly this reason.)

## 4. A granted cap ≠ permission to run — the trust profile sets the MODE

- **What:** `Arbor.Security.grant/1` says the agent *may* use a resource. The trust
  profile's per-resource **rule** (or the `baseline`) sets the **mode**: `:allow`,
  `:ask`, `:block`, `:auto`. `effective_mode` = most-restrictive of (rule/baseline,
  ceilings, model constraints).
- **Symptom:** the agent has the cap but the tool never executes — it loops or
  times out, silently waiting on an approval an autonomous run can't answer (default
  `baseline` is `:ask`).
- **Action:** set an explicit resource rule through the public facade, preserving
  the profile's other rules:
  ```elixir
  {:ok, profile} = Arbor.Trust.get_trust_profile(agent_id)
  Arbor.Trust.ensure_trust_profile(agent_id, rules: Map.put(profile.rules, uri, :allow))
  ```
  Use `:ask` when testing human approval. A bare `baseline: :allow` is constrained
  to `:block` unless the host explicitly permits permissive baselines; a finite
  resource rule is evaluated separately. Keep that host restriction enabled.
  A missing Manager can hide this restriction by making policy resolve a fallback
  profile, so verify public readiness and the real stored profile first
  (reconfirmed 2026-10-04 during protected profile-read qualification).
  An explicit `:allow` rule permits automatic use under trust policy; a held
  capability's `requires_approval` constraint still requires approval. Taint,
  capability, and egress checks also remain in force.

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
- **A missing or unreadable `:egress_taint` is `:untrusted` (2026-09-27, Imp review
  D3).** `EgressGate.effective_taint_level/1` reads a level atom, a level string, or
  a Taint struct/map with a `:level`. Anything else (key omitted or misspelled,
  `nil`, an unknown atom/string, a bare multi-key context taint map) is decided as
  `:untrusted`. Before this, those forms read as "no taint", which skipped
  branches 1 and 2 and left only the policy check. *Symptom:* a new egress caller
  gets `{:egress_blocked, tier, :untrusted}` even with `egress_mode: :allow`, and
  `:egress_observed` reports `egress_taint: :untrusted`. *Action:* thread the real
  taint. If your boundary's model genuinely means "no label = clean", pass
  `egress_taint: :trusted` explicitly and say so in a comment. `LlmHandler`
  (context with no taint labels) and `Arbor.Actions.authorize_and_execute`
  (context without `:taint`) do exactly this; they are the two deliberate
  "unlabeled = clean" decision points. Regression:
  `egress_taint_fail_closed_security_regression_test.exs`.
  `Arbor.Trust.TaintConjunct` (TRUST-15) follows the same rule for *present*
  values: an unreadable operation taint is `:untrusted` and degrades
  `:auto`/`:allow` to `:ask` for high-risk effect classes. An *absent* taint
  stays "no signal" there on purpose, because most `Trust.authorize` callers
  don't track taint, and reading their silence as untrusted would turn `:auto`
  action rules into approvals (e.g. stalling reviewed validation).
- **External-agent inputs are labeled `:derived` (decision 2026-09-27).** Three
  entry points used to hand `authorize_and_execute` no `:taint`, so an external
  LLM agent's arguments were decided as clean:
  - gateway `arbor_run` (`Handler.native_action_context/0`, source `gateway_mcp`)
  - `AgentEndpoint` (source `agent_endpoint`)
  - the ACP ToolServer (source `acp_tool_server`)
  They now carry the same `:derived` label an in-process compute node's tool
  calls get. Egress is unaffected, since `:derived` isn't exfiltration-blocked.
  The action taint policy does apply: `:audit_only` (dev) records audits;
  `:permissive` (test) and `:strict` (prod) refuse a `requires:` control param
  (file `path`, shell `command`) that lacks the sanitization bit, with
  `{:missing_sanitization, param, [...]}`, and `:strict` refuses any non-trusted
  control param. *Symptom:* outside dev, an external agent's `file_read` or
  `shell_execute` fails with `missing_sanitization` (as in-process agents'
  already do). *Action:* this is the designed posture. Tests of authority or
  plumbing pin `:arbor_actions, :default_taint_policy` to `:audit_only`, as dev
  does. Regressions: the provenance tests in `handler_test.exs`,
  `agent_endpoint_test.exs`, `tool_server_test.exs` and `acp_tool_exposure_test.exs`.

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

### ACP execution also needs the Shell gate (2026-10-15)

Native execution names and `kind=execute` must also pass
`Arbor.Shell.authorize/3`: an ACP wildcard never substitutes for a command-scoped
shell grant, command validation, or the configured Trust-aware authorizer's
always-locked approval floor. Exact shell tool grants remain askable at launch;
explicit shell pre-allow rules and wildcard pre-allow patterns are removed after
adapter-option merges. A descriptive title or opaque Kiro callback without a
structured command cannot establish shell authority and is denied.

Symptom: ACP tools can be granted while a terminal request still returns
`shell authorization denied`. Supply classifiable structured `rawInput` and
the same shell authority/approval required by Arbor's own shell actions. Do not
restore callback-free execution with `permission_mode=bypass`: the session
action rejects that mode and its aliases before creating a session. Keep
read-only workloads on exact read/list/search child capabilities.

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
- **Claude sessions are strict (2026-09-27).** Every ClaudeSDK launch gets
  `--strict-mcp-config`, so servers from the user's own Claude configuration
  never join, even when the bound list is empty (see gate 28). Codex still reads
  `~/.codex/config.toml`; RuntimeHome has no private Codex home yet.

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
- **A fixed conservative label must dominate the actual source (2026-10-03).**
  A durable `untrusted/internal` label still downgrades a hostile or restricted
  source. Join the actual private aggregate/parameter dimensions monotonically
  before payload binding; missing or malformed source metadata requires the
  absorbing hostile/restricted fallback or an explicit refusal. A taint-policy
  pass is not evidence for a weaker stored label. Private source-chain details
  may be projected away without claiming that the content became clean.
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
- **Revoking a grant does not revoke standing policy (2026-09-24).** An
  exact `:allow` rule can mint a replacement after `Security.revoke/1`; the real
  hostile-document acceptance journey observed a later file read succeed this
  way. For source-owned access-closure checks, first block only the verified
  synthetic principal's exact fixture URI through the public Trust owner,
  verify its acknowledged rule and healthy policy snapshot, then revoke the
  dedicated grant and require actual future Action refusal. Preserve both
  observations. Cleanup may tighten that admitted rule but must never restore
  access; only the operator may restore the identical rule and grant after
  reviewing the denial. Do not disable JIT globally or treat asynchronous
  capability synchronization as a completed revocation barrier.

## 26. Self-scoped resources: the minted parent covers only *your own* child

- **What:** facades gate scoped resources (`arbor://memory/read/<agent>`,
  `arbor://historian/query/agent:<id>`) while trust policy mints the canonical
  parent. Since 2026-08-25 `Arbor.Security.authorize_self_scoped/6` lets the
  parent cover the child **only when principal == subject and the child is a
  strict segment-descendant**. Memory and the historian's own-stream use it;
  categories, other agents' streams, and non-principal scopes (shell command,
  AI provider, consensus topic, signal topic, persistence name) do not.
- **Symptom:** `Unauthorized: :unauthorized` right after the log says Trust
  *minted* the parent — you are hitting a scoped facade gate the parent does not
  cover. If the scope is another principal or a category, that is correct.
- **Action:** derive "self" from the executor context, never from params
  (`Memory.extract_agent_id/2` fails closed); if the action is self-scoped,
  export `self_scoped_resource/2` so the action layer honours a child `:block`
  rule before authorizing the parent. Do not widen the helper to non-principal
  scopes. **And forward the call's scope:** JIT-minted capabilities are
  session/task-bound, so a facade that authorizes without
  `Arbor.Actions.auth_scope(context)` gets `:scope_mismatch` from a cap the
  agent visibly holds (78ba5418a). Template/lifecycle grants are unscoped,
  which is why they never showed this.


## 27. Cluster signed-request replay protection vs flappy dist peers (2026-08-30)

- **Symptom:** the whole software factory 401s (`cluster_replay_protection_unavailable —
  this node is connected to a peer …`) whenever the brax3 phone
  (`beamapp@…`, hidden, bare OTP) is attached to the cluster. Codex hit it
  operating the local factory.
- **Mechanism:** `Arbor.Security.Identity.ReplayPeers` probes every
  *connected* node (hidden included, deliberately) with
  `:application.which_applications` (2 s timeout) and **fails closed**: only
  an affirmative "not running `:arbor_security`" makes a peer `:foreign`,
  and that verdict expires every 30 s and must be re-earned. An Android
  phone in Doze answers late or not at all → `:replay_peer`. Before
  2026-08-31 that verdict had **no expiry and no re-probe** — one missed
  probe refused every `SignedRequest` until the phone's dist connection
  actually dropped (Doze keeps TCP alive, so: effectively forever;
  reproduced live with SIGSTOP/SIGCONT against a dev node). The gate
  is correct (a wedged peer is indistinguishable from a replay target);
  the phone is simply the worst-case probe subject.
- **Fixed 2026-08-31:** `:replay_peer` verdicts now expire too (default
  30 s). Expiry never opens the gate — reads keep refusing — but the next
  gate read schedules an async re-probe, so a recovered peer heals within
  one TTL instead of never. The knobs are wired:
  `config :arbor_security, :replay_peers, foreign_ttl_ms: …,
  replay_peer_ttl_ms: …, probe_timeout_ms: …` (see
  `Config.replay_peers_start_opts/0`); raise `foreign_ttl_ms` /
  `probe_timeout_ms` for high-RTT topologies. The duplicate gate read in
  `Security.verify_signed_request_authenticity` was dropped (Verifier
  gates; refusals now reach the events journal).
- **Action:** (1) still don't leave the phone dist-connected to a factory
  node — the brax3 comms adapter should `Node.connect → erpc → disconnect`
  in a short window, or live on a non-factory node; (2) the designed
  successor is per-nonce ownership / trust zones
  (`trust-zone-segmentation-architecture.md`). Never trust-list a node by
  hand — the module deliberately has no seam for that.

## 28. The ACP ToolServer requires its per-session bearer token (2026-09-27)

- **What:** `Arbor.AI.AcpPool.ToolServer` runs Jido actions through
  `authorize_and_execute/4` **as the owning agent**, so reaching its port means
  acting with that agent's capabilities. Loopback binding keeps it off the
  network. ex_mcp's Origin check (`validate_origin: true`, empty allow-list)
  already 403s browser pages, and CORS never emitted an allow-origin header. But
  any local non-browser process that found the port (a port scan is enough) was
  served with no credential (Imp review D6). Now `start/2` mints a 32-byte token,
  `ToolServer.BearerAuth` requires `authorization: Bearer <token>` (constant-time
  compare, 401 otherwise), CORS is off, and a loopback bind only answers loopback
  `Host` names (421, DNS rebinding).
- **Symptom:** a client of a ToolServer gets `401 {"error":"unauthorized"}` on
  `initialize` or any call. A hand-built descriptor with `"headers" => []` connects
  to nothing. A `Host` other than 127.0.0.1/localhost/::1 gets 421.
- **Action:** build the ACP descriptor with `ToolServer.mcp_servers_entry(info)`,
  passing the map `start/2` returned, and send its `headers` verbatim. That is the
  only place the token should live: `AcpPool` strips `:token` from the entry it
  keeps in pool state. Never log `mcp_servers`: the token is a live credential for
  the session's lifetime. `AcpSession.format_status/1` redacts header and env
  values in the bound list. See gate 12 for why `ExMCP.ACP.Client` stays at an
  `:info` floor. Regression: the `security regression (Imp review D6)` block in
  `tool_server_test.exs`.
- **Adapter-backed providers need launch-time delivery (fixed 2026-09-27).** Native
  ACP agents read `mcpServers` from `session/new`. ex_mcp 1.3.0's ClaudeSDK adapter
  ignores it there, so Claude never saw the ToolServer. The Codex/ZCode adapters
  refuse any MCP server that isn't authorized, so `session/new` failed outright
  once a ToolServer was bound. `AcpSession.McpLaunchCore` now handles both, keyed
  on the client's `:adapter`:
  - Claude: writes the servers to a 0600 `claude-mcp-config.json` in the private
    runtime home and passes `--mcp-config <path>` plus `--strict-mcp-config`.
    Never the JSON itself, since argv is visible to `ps`. It also appends
    `mcp__<name>` to `allowed_tools` after the tool-profile merge, because the
    ToolServer authorizes each call itself.
  - Codex/ZCode: `trusted_mcp_servers` is set to exactly the bound list, and any
    `:authorize_mcp_server` is dropped.
  - Pi and other adapters: fail the launch with `{:acp_mcp_servers_unsupported, adapter}`.
  Symptom of the old gap: a Claude ACP agent with `tool_modules` had no
  `mcp__arbor-tools__*` tools, and a Codex one failed with "MCP server is not
  authorized". Tests: `mcp_launch_core_test.exs` and the "adapter-backed providers
  receive the bound ToolServer" block in `acp_session_test.exs`.

## 29. `Gateway.call_mcp_tool` / `read_mcp_resource` require `:agent_id` (2026-09-27)

- **What:** both facade calls capability-check the calling agent against
  `arbor://mcp/<server>/<tool-or-resource>`. A nil or blank `:agent_id` used to
  skip the check entirely (Imp review D2). Only the literal `skip_auth: true` is a
  bypass now. `ToolBridge`/`ResourceBridge.authorize` also deny when the
  security subsystem is unavailable (fixed `592553074`; they used to allow
  everything while `CapabilityStore` was down).
- **Symptom:** `{:error, :missing_agent_id}` from `Arbor.Gateway.call_mcp_tool/4`
  or `read_mcp_resource/3`.
- **Action:** pass `agent_id:` for the principal the call acts for. Reserve
  `skip_auth: true` for trusted system code that has already authorized the call
  another way. Regression: `missing_agent_id_security_regression_test.exs`.

## 30. Agent-bound MCP servers need the operator's exact approval (2026-09-28)

- **What:** an agent's profile `mcp_servers` are connected on start/resume. For
  stdio that spawns the command, and for http it dials the URL, as that agent.
  Until Imp review D7 nothing checked a capability, so whatever could write the
  metadata got process spawn. Now `Arbor.Agent.set_mcp_config/2` (the operator's
  consent) grants the agent one capability per server,
  `arbor://mcp_server/connect/<sha256(name)>/<config digest>`
  (`Arbor.Security.mcp_server_approval_uri/2`), and revokes approvals for
  servers it no longer lists. `Arbor.Gateway.connect_mcp_server/2` requires that
  exact capability for any config carrying `:agent_id`. The digest covers
  `transport`/`command`/`env`/`url`/`server`, so editing any of them voids the
  approval. The dedicated `mcp_server` domain keeps it out of reach of
  `arbor://mcp/...` tool grants and `arbor://agent/...` wildcards.
- **Symptom:** an agent's configured MCP server doesn't connect, and the log
  says it `is not approved for its current config` (from
  `connect_mcp_server/2`, `{:error, :mcp_server_not_approved}`). Expect this for
  agents configured before 2026-09-28, and for any metadata edited outside
  `set_mcp_config/2`. `set_mcp_config/2` itself returns
  `{:error, {:invalid_mcp_server, server}}` for a server without a `:name`.
- **Action:** re-run `Arbor.Agent.set_mcp_config(agent_id, servers)` with the
  intended servers. Don't hand-grant the URI. Operator connections made
  without `:agent_id` are not gated here. Regressions:
  `mcp_server_approval_security_regression_test.exs` (gateway) and the
  `set_mcp_config/2 is the MCP server approval` block in `manager_test.exs`.

## 31. MCP bridges deny when the security subsystem is unavailable (2026-09-27)

- **What:** `Arbor.Gateway.MCP.ToolBridge.authorize/3` and
  `ResourceBridge.authorize/3` sit behind `Arbor.Gateway.call_mcp_tool/4` and
  `read_mcp_resource/3`. They used to return `:ok` ("permissive mode") whenever
  `security_available?/0` was false: the `:arbor_gateway, :security_module` was
  not loaded or lacked `authorize/3`, or `Arbor.Security.CapabilityStore` was not
  registered. So while security was booting or restarting, every external MCP
  tool call and resource read was granted, even with an `:agent_id`, which left
  gate 29's `:agent_id` requirement only as strong as security being up. The
  rescue/catch branches were already fail-closed
  (2026-06-09 Sentinel finding). The unavailable branch now denies too, matching
  `AcpPool.ToolServer`'s `{:error, :security_unavailable}`.
- **Symptom:** `{:error, :unauthorized, "security subsystem unavailable; cannot
  authorize arbor://mcp/<server>/<tool>"}` (resources:
  `arbor://mcp/<server>/resource/<name>`). You see it when a call lands while
  `arbor_security` is still starting or its `CapabilityStore` is restarting, in a
  test or app that never started security, or when `config :arbor_gateway,
  :security_module` names a module without `authorize/3`.
- **Action:** have `arbor_security` running before routing MCP calls. In tests,
  start `Arbor.Security.TestBootstrap` as `apps/arbor_gateway/test/test_helper.exs`
  does. A denial during a restart window is correct: retry once the store is back
  instead of adding a fallback. Do not reintroduce a dev/test permissive mode. A
  test that needs a specific decision should inject `:security_module` with an
  `authorize/3` that returns it. Regression:
  `security_unavailable_security_regression_test.exs`.
- **The same restart invariant applies inside ACP sessions.** A missing
  `CapabilityStore` must deny an ACP permission request instead of skipping
  `Security.authorize/4`, and a missing `Trust.Manager` must deny rather than
  erase the confirmation ceiling. Exercise the public permission path with the
  registered owner name temporarily absent; raise/exit-only tests do not cover
  an availability predicate that returns false (found 2026-10-07 while closing
  the kernel-runtime/security review ripple paths).

## 32. Agent Shell needs an explicit workdir with a filesystem grant (2026-09-24)

- **What:** generic agent Shell execution (`Arbor.Shell.authorize_and_execute/3`,
  `Arbor.Actions.Shell.Execute`, and anything that nests them, such as MCP
  agent endpoints and coding validation) runs under OS containment
  (`Arbor.Shell.AgentContainment`, commit `2dcfce8a7`). An executable
  capability alone grants no filesystem access. Each call needs an explicit,
  existing, absolute, canonical `cwd`, covered by a current signed ordinary
  `arbor://fs/read<dir>/**` grant, with Trust allowing it. `touch` also needs
  the matching write grant. Containment is qualified on macOS only. Contract:
  `docs/arbor/AGENT_SHELL_CONTAINMENT.md`.
- **Symptom:** `Shell execution failed: :agent_workdir_required` (no `cwd`, or
  one that is not canonical: a macOS temp dir under `/var/...` fails because it
  resolves to `/private/var/...`). `:agent_filesystem_unauthorized` means there
  is no covering grant or Trust refused it; `:agent_filesystem_protected` means
  the cwd is in a credential path (`.ssh`, `.git`, `.arbor`, ...). Off macOS:
  `{:agent_containment_unavailable, :platform_not_qualified}`.
- **Action:** pass `cwd`, resolved with `Arbor.Common.SafePath.resolve_real/1`.
  Grant `"arbor://fs/read" <> cwd <> "/**"` through `Arbor.Security.grant/1`, and
  put the Trust rule on the bare prefix `"arbor://fs/read" <> cwd`, because a `/**`
  trust rule never matches. Grant a narrow working directory, never a home
  directory or a root. Worked examples:
  `shell_filesystem_containment_security_regression_test.exs` (arbor_actions)
  and the Shell cases in `agent_endpoint_test.exs` (arbor_gateway).
  Test fixture roots need the same care: `.claude` is protected at every path
  segment, so a worktree-private `TMPDIR` beneath `.claude/worktrees` still
  produces `:agent_filesystem_protected`. Have the shared harness provision a
  canonical temp root outside protected segments; do not relax containment to
  clear test failures (observed in the 2026-10-15 security worktrees).

## 33. Security-state mutations need caller-owned authority (2026-10-06)

- **What:** capability grant, revoke, delegation and role assignment; identity
  registration/status changes; and issuer, URI and reflex registry mutations no
  longer accept an ambient in-VM caller. An in-process caller passes an
  `actor_authority` owned by that exact PID. A CLI holding a key file constructs
  an exact signed mutation request locally and submits only the proof; the target
  process never opens a caller-selected key path. Authorities cannot be handed
  to a GenServer and consumed there because the broker binds them to the opener
  PID.
- **Symptom:** `:capability_mutation_unauthorized`,
  `:identity_registration_unauthorized`, or `:issuer_mutation_unauthorized`
  after code calls an old one-argument facade or transfers an authority handle
  to another process.
- **Action:** keep the acquire-and-mutate sequence in one caller process, or put
  a long-lived authority inside the fixed supervised owner that performs the
  mutation. For key-file CLIs, use the matching `prepare_key_file_*` helper
  before application startup and submit the exact signed proof after startup.
  Tests setting up unrelated state use the compile-time `*_fixture` APIs; a
  production caller must never select them or regain a raw-key path.

## 34. Role owners claim key custody while their own app is still starting (2026-10-09)

- **What:** `SigningKeyStore.Owner` and `Identity.Registry` admit role owners
  (`trust_grant_owner`, `scheduler_owner`, `system_lifecycle_owner`, ...) only
  as the exact child at their configured supervision path, via
  `Arbor.Security.SupervisedOwner.authorized?/3`. Owners claim custody from a
  `handle_continue`, which still runs *inside* their application's `start/2`
  (`Scheduler.Application.start/2` even waits for it). On OTP 28,
  `:application_master.get_child/1` against an application whose `start/2` has
  not returned crashes that master with `badarg`
  (`erlang:is_process_alive(undefined)` in `get_child_i/3`); the application
  controller never hears `application_started` and keeps the app in
  `starting` forever. `application_root/1` now asks the master only once the app
  is in `Application.started_applications/0`. During `start/2` the root is bound
  from VM-maintained spawn parents (caller → … → root → start/2 process → that
  app's master), and the exact child ids are still checked top-down with
  bounded `which_children` calls. This is not "admit because the app is not
  started yet"; the parent chain cannot be forged by the caller.
- **Symptom:** `mix arbor.start` stalls at a partial app set (2026-10-09: 15/26,
  `arbor_trust` and everything after it missing, port 4000 dead) while the BEAM
  stays up. The log shows `init got unexpected: {'ETS-TRANSFER',
  arbor_trust_policy_host_claim, ...}` (the PolicyHost table falling to its
  `init` heir as the supervisor shuts down) and then a crash report from
  `Arbor.Trust.ApplicationSupervisor`, which rendered as `[error] nil` until the
  LogRedactor fix of the same day. `mix arbor.start` now fails fast with
  "`<app>` is stuck starting".
- **Action:** never call `:application_master.get_child/1` or
  `:application.get_supervisor/1` for an application that is not yet started.
  Inside `arbor_security` use `SupervisedOwner`; elsewhere,
  `Arbor.Common.supervised_registered_child_pid/4` (it fails closed while the
  app is starting). To diagnose a stuck boot, attach with the daemon's cookie
  home: `HOME=~/.arbor/distribution elixir --name probe@127.0.0.1 --erl
  "-kernel inet_dist_use_interface {127,0,0,1}" script.exs`. Then read
  `:application.info()[:starting]`. An app listed there whose
  `:application_controller.get_master/1` is `:undefined` died mid-start. To find
  what killed it, set `:erlang.trace(:all, true, [:procs, :call])` before boot,
  plus a `:receive` trace on that app's master (the group leader of its root
  supervisor).

## 35. Fresh-store dev boot gates (2026-10-09)

- **`ARBOR_SESSION_TOKEN_SECRET`:** since `ddf05e470` there is no committed dev
  secret. `arbor_security` refuses to start with
  `:session_token_secret_missing`. **Action:** set it in `.env` (see
  `.env.example`).
- **Pre-authenticated authority store:** records from before 2026-10-07
  (envelope v2 or the older raw layout) are refused with
  `:offline_migration_required`. The startup error now carries
  `%{authority_root: dir, action: ...}`, and the same text is logged.
  **Action:** stop Arbor and move the directory aside, e.g. `mv
  <repo>/.arbor/security ~/.arbor/backups/security-<date>`. Then start fresh.
  Identities, capabilities and grants are not carried over. No migration tool
  exists yet (deferred decision).
- **Scheduler dormant until provisioned (2026-10-10):** `ddf05e470` removed
  `Scheduler.Identity`'s self-grant. Its five required capabilities
  (`arbor://orchestrator/execute/**`, `arbor://security/identity/register`,
  `arbor://security/{grant,revoke}/**`,
  `arbor://security/identity/deregister/**`) must be granted by an operator.
  Without them the identity is created and registered but stays **dormant**.
  No authority is opened, mutations fail closed, and Oban runs in standby
  (`queues: false, plugins: false`: jobs insert, nothing executes, cron is
  off). The boot completes. **Symptom:** `[Scheduler.Identity] dormant:
  scheduler principal agent_... lacks ...`; `mix arbor.scheduler.provision
  --status` shows `dormant` / `Oban: standby`. **Action:** after genesis, run
  `mix arbor.scheduler.provision --key-file <operator key>`. It signs one grant
  per missing capability locally, submits only the proofs, then calls
  `Arbor.Scheduler.activate/0`, which re-bootstraps Identity and swaps Oban to
  its configured queues.
- **Scheduler start deadlock on its own run-lease store (fixed 2026-10-10):**
  `Scheduler.Application.start/2` waits for `RunIdentityReaper`, which waits
  for run-lease recovery. Recovery resolves its store through
  `Arbor.Common.supervised_registered_child_pid/4`, which used to fail closed
  until `:arbor_scheduler` was started. **Symptom:**
  `{:run_identity_reaper_start_failed, {:run_identity_reconciliation_failed,
  {:active_run_lease_lookup_failed, :recovery_in_progress}}}`. The helper now
  binds a starting app's root through `Arbor.Common.starting_application_root/3`
  (the spawn-parent chain from §34).
- **Genesis cannot write the operator key file (OPEN, 2026-10-10):**
  since `ddf05e470`, `IdentityStore.create_new/2` returns
  `Identity.public_only/1`. `mix arbor.user.init` creates the human identity
  but fails with `Failed to write operator key file ...: identity did not
  include a private key` (or `:missing_private_key`). Without a key file there
  is no genesis, so no administrator, so nothing can be provisioned (scheduler,
  Trust grant owner). Genesis tests use fixtures and never ran the CLI path.
  **Action:** pending a decision on how a locally created operator obtains its
  key (e.g. CLI-generated keypair with only the public part registered).
- **Local genesis is refused while OIDC is configured:** with `OIDC_ISSUER`
  and `OIDC_CLIENT_ID` set (for example in `.env`), `mix arbor.user.init`
  stops with "An OIDC provider is configured". This is by design (D1); OIDC
  genesis is an open item in the 2026-10-08 decision.
- **Worktree daemons share the main authority store:** `.env` sets
  `ARBOR_SECURITY_STATE_DIR`, so a daemon started from a worktree that uses
  the main `.env` writes the *main* checkout's `.arbor/security`. For an
  isolated store, export `ARBOR_SECURITY_STATE_DIR=<scratch dir>` before
  `mix arbor.start`; the `.env` loader never overrides a variable that is
  already set.
- **Trust grant owner dormant:** `[Trust.CapabilityGrantOwner] dormant:
  {:grant_owner_capability_not_provisioned, agent_id}` is by design until an
  operator runs `mix arbor.trust.grant_owner provision --key-file ...` after
  genesis. It does not block boot.
- **Reading a failed boot:** `mix arbor.start` prints the first `Could not start
  application` line, or the first `[error]` entry, from
  `~/.arbor/logs/arbor-dev.log`. Every restart rotates the log and keeps only 3
  generations, so repeated diagnostic restarts discard older failures. Copy the
  log out first if you need it.

## 36. Invocation receipts need an atom `action` and an encodable receipt (2026-09-28; payload v2 2026-10-01)

- **What:** with `config :arbor_security, invocation_receipts_enabled: true`
  (default `false`), every granted `Arbor.Security.authorize/4` builds an
  `InvocationReceipt` and has `SystemAuthority` sign it through
  `InvocationReceiptBroker`. The action is part of the signed payload, so it
  must be an atom (or `nil`); `InvocationReceipt.new/1` returns
  `{:error, :invalid_action}` otherwise. Since payload v2
  (`"arbor-receipt-sig-v2"`, landed on main 2026-10-11) every field is a typed,
  length-delimited term, so delegation-chain values must be binaries, atoms,
  numbers, proper lists, plain maps or `DateTime`s. Anything else gets
  `{:error, :invalid_receipt}` from the authority instead of crashing it.
- **Symptom:** a warning that no receipt was emitted for the call
  (`:invalid_action`, `:invalid_receipt`, or an unavailable authority). The call
  is still authorized; receipts are evidence of a decision already made, so a
  missing one is an audit gap, not a denial. A receipt that went through a JSON
  round trip no longer verifies, because v2 signs native types.
- **Action:** pass atom actions (`:execute`, `:read`). Rebuild a receipt with
  native types (atom keys, raw signature bytes, `DateTime`) before
  `InvocationReceipt.verify/2`. Unversioned v1 receipts do not verify, by design.
  Decision: `.arbor/decisions/2026-10-01-invocation-receipt-payload-v2.md`.
  Regression: `apps/arbor_security/test/arbor/security/invocation_receipt_security_regression_test.exs`.

## 37. Untrusted input must not reach host `Code.eval*` (2026-10-15)

- **What:** HTTP bodies, LLM output, and agent-provided files must not reach
  `Code.eval_string` / `Code.compile_string` in the Arbor VM. `POST /api/dev/eval`
  used to eval the JSON `code` field; that route now returns 403. Agents eval
  through `Arbor.Sandbox.authorize_eval/4` (Dune, `arbor://sandbox/eval`).
  Operators inspect the live node with `mix arbor.rpc` (cookie-gated, not HTTP).
  Remaining host loaders are allowlisted in
  `docs/security/code-eval-inventory.md` and
  `apps/arbor_kernel/test/arbor/contracts/code_loader_sites_lint_test.exs`.
- **Symptom:** a localhost POST of Elixir to `/api/dev/eval` used to run in the
  Gateway process (`send(self(), ...)` delivered). After the fix it 403s and
  the message is not received.
- **Action:** do not add `Code.eval_string` of request or model text. Use Dune
  (`authorize_eval/4`), parse-only `Code.string_to_quoted`, or an allowlisted
  AST. If a new host loader is truly required, add it to the inventory
  allowlist on purpose.

## 38. `/api/bridge/authorize_tool` is not an HTTP side door (2026-10-15)

- **What:** the unused `POST /api/bridge/authorize_tool` Plug route (Claude Code
  PreToolUse) is gone. `arbor_bridge_authorize.sh` was removed 2026-08-26 after
  it failed open on every tool call once `/api/*` gained auth (2026-02-07).
  Nothing in apps, scripts, JS, clients, or live hooks called the route.
- **Symptom:** authenticated `POST /api/bridge/authorize_tool` returns **404**,
  not a `{decision: allow|deny}` JSON body. The handler modules
  (`Arbor.Gateway.Bridge.Router`, `RegistrationAuthority`, `Schemas.Bridge`) are
  not on the code path.
- **Action:** do not re-add an HTTP authorize endpoint. Harness tool
  authorization is the signed-MCP / ACP path. In-process
  `ClaudeSession.authorize_tool/4` remains a fail-closed library API and still
  refuses ambient session minting without actor authority.
  Regression: `bridge_authorize_tool_route_security_regression_test.exs`.

## 39. ACP CLI argv values must not start with `-` (CVE-2026-96620, 2026-10-19)

- **What:** Claude Code treats a token after an optional-value flag (`--resume`,
  `--session-id`, `--model`, `--add-dir`, `--cwd` via adapter opts,
  `--resume-session-at`) as a new option when it starts with `-`. A caller
  `session_id` of `--mcp-config=/tmp/x.json` (or `-x`, or `" -x"`) becomes a
  second CLI flag. Arbor rejects that class of value before any provider
  process is launched. Claude caller resume/session IDs must also match the
  provider UUID. Arbor-built extra args use `--flag=value`.
- **Symptom:** `{:invalid_provider_session_id, :leading_dash}`,
  `{:invalid_provider_session_id, :claude_session_uuid}`, or
  `{:invalid_cli_argv_value, :leading_dash}` from `Acp.StartSession` /
  `acp_managed_start_session` with no child process.
- **Action:** pass a Claude session UUID to resume; never pass a dash-leading
  model, cwd, add-dir, or resume token. Do not "fix" this by forwarding the
  value as a following argv token.

## 2026-10-11 cross-library review — new gates and sharpened ones

- **Signal approval replies are sender-bound (F-003).** `Arbor.Comms.Router` routes a
  reply as an HITL interaction only when `from` equals the configured
  `interaction_recipient` (`SIGNAL_TO`) or an `authorized_senders` entry; otherwise the
  text is chat and an `comms.interaction_reply_unauthorized` signal fires.
  **Symptom:** "I replied APPROVE on Signal and nothing happened." **Action:** set
  `SIGNAL_TO` to the operator's own number (runtime.exs also derives
  `authorized_senders` from it). Never widen the chat allowlist to make approvals work.
- **Inbound chat is closed until someone is allowlisted (F-004).** An empty
  `:arbor_comms :handler authorized_senders` now denies every sender
  (`{:error, :no_authorized_senders}`, logged). **Action:** set `SIGNAL_TO` or the
  config key; the old "empty list = everyone" behaviour is gone.
- **Graph attributes can only tighten the ACP CLI (F-002).** `acp_permission_mode` of
  `bypass` / `bypass_permissions` / `auto` fails the compute node
  (`{:acp_permission_mode_refused, mode}`); `default`, `plan`, `dont_ask`,
  `accept_edits` still flow. **Symptom:** a pipeline that used `bypass` now fails at the
  compute node. **Action:** drop the attribute; grant the worker real Arbor capabilities
  instead of bypassing the ACP permission callback.
- **`comms_send_message` attachments need a path-scoped `arbor://fs/read` cap (F-010).**
  Each attachment goes through `FileGuard.authorize(principal, path, :read)`; with no
  bound principal attachments are refused. `egress_destination/2` is now the
  recipient, so scope `arbor://comms/send` per recipient instead of a blanket allow.
- **`session_memory.*` targets are the bound principal (F-009).** A params `agent_id`
  that differs from `context[:agent_id]` raises `principal_mismatch`. Pipelines that
  passed `session.agent_id` through still work (same id).
  This also applies to all five `session_goals.*` syscalls (2026-10-15): bind
  before any goal, intent, proposal or identity bridge. Pipeline-internal
  classification and an execution capability do not authorize another agent's
  mind state. Direct trusted in-VM calls retain the accepted params fallback.
- **`trust_apply_profile` cannot target the caller (F-005)** and `arbor://trust/write`
  / `auto_promote` are always-locked (never unattended, F-015). The InterviewAgent
  flow must run as the operator (session token) when it targets itself.
- **The dashboard binds loopback (F-001).** `ARBOR_DASHBOARD_BIND_IP=0.0.0.0` is the
  explicit LAN opt-in; set `DASHBOARD_USER`/`DASHBOARD_PASS` (now actually mounted,
  F-012) before doing so.
- **Dashboard mutations require the browser subject's real session proof
  (2026-10-15, F-020).** Proposal accept/reject/defer authorizes
  `arbor://memory/write/<target>`; channel creation authorizes
  `arbor://comms/channel/create` and records the authenticated owner. Only
  `{:ok, :authorized}` admits the mutation; approval, missing proof and Security
  failures refuse it. External-agent registration also requires a session token;
  `local_dev_operator?` never supplies `identity_verified`. **Action:** use a
  proved session with the required resource scope and explicit capability.
  The existing human-session scope list excludes memory, so the proposal
  mutation path remains closed pending an explicit scope/policy decision.
  Do not mint proof or grant capabilities from a page visit to clear a refusal.
- **Sensitivity now sees the prompt (F-006).** A turn whose prompt carries a detected
  secret classifies `:restricted`; the router may send it local or refuse the cloud
  provider. That is the consent promise working — don't "fix" it by removing the key.
- **Testing egress gates: a `:policy_module` stub is NOT consulted for egress.**
  `Arbor.Trust.authorize_egress/3` → `Policy.tighten_public_opts/2` → the local
  `Policy.egress_mode/2`, which reads the PolicyHost snapshot's `default_egress_modes`
  (dev/prod set `external_provider: :allow`; test leaves it `:ask`) and the profile's
  `egress_modes`. A stub module's `egress_mode/2` never fires — assert on outcomes
  (`:partial_success` + `egress_blocked`) or set a real profile instead (learned
  2026-10-11 writing the F-018 regression test).
- **Review record:** `.arbor/reviews/arbor-cross-library-20261011/` (40 findings;
  executive + technical reports).

---

<!-- applied-learning: do-not-telemetry-invert-distributed-security-state-sync -->
<a id="applied-learning-do-not-telemetry-invert-distributed-security-state-sync"></a>
**Telemetry and permanent audits are observations, not security-sync mutations.** Nonce, capability, and identity sync still require a real node-hop transport. In-process telemetry cannot replace it. A sync reducer must reject a `permanent: true` audit reflection before applying remote authority. `Arbor.Security.Identity.Registry` skips that marker, and `Arbor.Security.Identity.NonceCache` still applies remote `security.nonce_seen` as sync state. Do not let a delayed local suspension audit re-suspend an identity after resume. Keep the audit marker itself; do not add sync provenance to that payload. (Merged 2026-10-16 from 2 entries; first found 2026-07-07, last 2026-08-21.)

<!-- applied-learning: template-capability-grants-may-need-runtime-uri-expansion -->
<a id="applied-learning-template-capability-grants-may-need-runtime-uri-expansion"></a>
**Template capability grants may need runtime URI expansion.** Agent templates and trust presets can declare the human-readable coarse gate (`arbor://orchestrator/execute`), but mandatory Engine middleware authorizes per-node runtime resources like `arbor://orchestrator/execute/exec`. A trust rule prefix can stay bare; a capability covering the entire subtree needs `/**`, while a narrowly scoped fixture can grant each exact required URI. Compiled graphs also declare effect capabilities: a `compute` grant alone does not cover `arbor://orchestrator/execute/llm_query`. Inspect `CapabilityCheck.capability_resources/1` and the actual rejected node/envelope before changing grants or extending waits. Keep the production middleware enabled and provision the exact execution principal through the public Security and Trust facades. Diagnose the node status checkpoint, not just the top-level turn summary (found 2026-07-07 during CLI chat and reconfirmed 2026-10-04 when a real private-Branch privacy fixture failed before reaching its controlled provider).

<!-- applied-learning: trust-policy-rules-match-by-uri-prefix-not-glob-never-write -->
<a id="applied-learning-trust-policy-rules-match-by-uri-prefix-not-glob-never-write"></a>
**Trust-policy rules match by URI PREFIX, not glob — never write `/**` in a trust rule.** A bare `arbor://fs/read` already covers the whole subtree (`ApprovalGuard` longest-prefix match); a literal `arbor://fs/read/**` is a prefix of nothing real, so the rule *silently never fires* and the request falls to the baseline. `/**` is correct for **capabilities** (path scope) but dead in **trust rules** — the two forms look identical, which is the footgun. Failure mode is config-dependent: fail-**closed** under a `block` baseline (the Test Agent selected `file_read` but every read returned `{:error, :policy_denied}` despite the trust profile literally showing `"arbor://fs/read/**" => :allow`; 2026-07-06), but fail-**OPEN** for a `/** block` rule under an `allow` baseline. Diagnose by reproducing the exact `Security.authorize(agent, "arbor://fs/read", :execute, file_path: …)` the action makes, and inspect the profile with `Arbor.Trust.Store.get_profile/1`. (Same day, unrelated: `./bin/mix` served a **stale beam** for an edited *mix task* until an explicit `mix compile` — a first "Unknown provider"/old-behavior right after editing a `Mix.Tasks.*` module is un-recompiled code, not a wrong edit; force the compile before concluding.)

<!-- applied-learning: tests-must-explicitly-own-security-children-disabled-by-test-config -->
<a id="applied-learning-tests-must-explicitly-own-security-children-disabled-by-test-config"></a>
**Tests must explicitly own security children disabled by test config.** `config/test.exs` sets `arbor_security, start_children: false`, so a focused test that calls signing APIs such as `Arbor.Security.grant/1` must start `Identity.Registry` and `SystemAuthority` under ExUnit supervision. Do not rely on another test file to start shared infrastructure. Use `start_supervised!/1` rather than a raw linked `start_link/0` for ordinary test ownership, but do not rely on `on_exit` to call that child: ExUnit teardown can stop it before the callback runs. Restore mutable process state in a `try/after` while the process is still alive, or put the process under a longer-lived supervisor (found 2026-07-10 during Phase 5 isolated verification and confirmed by the stale ActionRegistry catalog regression).

<!-- applied-learning: do-not-confuse-arbor-security-keychain-with-macos-keychain-services -->
<a id="applied-learning-do-not-confuse-arbor-security-keychain-with-macos-keychain-services"></a>
**Do not confuse `Arbor.Security.Keychain` with macOS Keychain Services.** Arbor's module is an in-process cryptographic peer/session abstraction and does not invoke the macOS `security` tool or credential store. Repeating macOS prompts for a `Claude Code credentials` item can come from the Claude daemon itself; `~/.claude/daemon.log` reports `auth: no token found, will re-check keychain every 30s` when that happens. Diagnose the requesting process and daemon log before attributing a prompt to Arbor code (found 2026-07-10 while delegated tests were running).

<!-- applied-learning: long-lived-anonymous-signer-functions-can-become-invalid-after-hot-code-purge -->
<a id="applied-learning-long-lived-anonymous-signer-functions-can-become-invalid-after-hot-code-purge"></a>
**Long-lived anonymous signer functions can become invalid after hot code purge.** Session and heartbeat state currently retain the closure returned by `Arbor.Security.make_signer/2`; purging that defining module makes the stored function raise `BadFunctionError`, which the authorization boundary correctly projects as `:security_unavailable`. A restart regenerates the closure but is only a workaround. Long-lived owners need a reload-stable signer reference/factory and must refresh the short-lived closure before each turn or heartbeat without placing raw private keys in orchestrator state (found 2026-07-11 after recompiling during Phase 6 dogfood).

<!-- applied-learning: a-security-regression-must-reach-the-exact-field-that-was-vulnerable -->
<a id="applied-learning-a-security-regression-must-reach-the-exact-field-that-was-vulnerable"></a>
**A security regression must reach the exact field that was vulnerable.** A nearby counter or earlier closed-schema rejection can make a test fail while never exercising the cleanup flag, scalar alias, or identity check named in the claim. Keep each regression independent, mutate only the vulnerable field where possible, and overlay that exact test on the exact parent so an earlier guard cannot mask the intended failure (found 2026-07-11 reviewing coding benchmark parent evidence).

<!-- applied-learning: test-doubles-must-not-create-production-authorization-bypasses -->
<a id="applied-learning-test-doubles-must-not-create-production-authorization-bypasses"></a>
**Test doubles must not create production authorization bypasses.** Never mark a request identity-verified merely because a signer returned a noncanonical map so unit tests can use a stub. Production code must accept and verify the same typed proof it requires in reality; tests should construct a real proof or inject behind an explicitly test-only boundary that runtime input cannot select (found 2026-07-11 while reviewing the coding commit approval redesign).

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
**Template capability and trust changes are not retroactive for live principals.** A template update applies to agents created after it. An existing agent keeps its stored capabilities and `Arbor.Trust` profile across restart, so it can hold a newly granted capability while an older baseline still blocks the action. Before dogfood, compare `Arbor.Security.list_capabilities/1` and `Arbor.Trust.get_trust_profile/1` with the current template. Reconcile only the missing rules through those facades, or recreate the agent. Do not weaken the baseline to compensate. (Merged 2026-10-16 from 3 entries; first found 2026-07-10, last 2026-07-17.)

<!-- applied-learning: opaque-identifiers-in-capability-uris-must-not-become-uri-syntax -->
<a id="applied-learning-opaque-identifiers-in-capability-uris-must-not-become-uri-syntax"></a>
**Opaque identifiers interpolated into capability URIs must not become URI syntax.** A caller-supplied task id such as `**` can turn an intended exact grant like `arbor://agent/task/adopt/<task-id>` into a recursive wildcard capability. Before constructing a scoped capability URI, either encode/digest the opaque id into one safe segment or enforce a bounded single-segment alphabet; reject `/`, `*`, traversal segments, whitespace/control bytes, and invalid UTF-8 before any grant occurs (found 2026-07-21 while reviewing post-terminal coding-task adoption).

<!-- applied-learning: local-oidc-http-issuers-need-allow-http-wired-through-runtime-config -->
<a id="applied-learning-local-oidc-http-issuers-need-allow-http-wired-through-runtime-config"></a>
**Local OIDC HTTP issuers need `allow_http` wired through runtime config.** Discovery and AuthCodeFlow reject `http://` unless the provider map has `allow_http: true`. Setting `OIDC_ISSUER=http://localhost:8080` alone yields dashboard 502 `{:invalid_issuer, :scheme_not_allowed}`. `Arbor.Security.OIDC.Config.allow_http?/2` is the single resolver; `runtime.exs` and CLI fallbacks must call it. Production stays fail-closed unless `OIDC_ALLOW_HTTP=true`; non-prod loopback HTTP (`localhost` / `127.0.0.1` / `::1`) defaults open (found 2026-08-24 launching local Zitadel).

**Pinned endpoint origin gate:** configured `:endpoints` skip discovery fetching,
but `Discovery.authorize_origin/3` still requires the issuer origin or an exact
`:trusted_origins` entry. `allow_http: true` permits the scheme only. A fixture
with an HTTPS issuer and a loopback provider otherwise fails before `/device`,
surfacing as terminal-login `:unauthorized`. Add only the test-owned listener's
exact origin to that fixture configuration; do not widen production policy.
Trace the enforcing function even when module prose implies pins grant trust
(found 2026-09-30 during human-login cross-surface qualification).

**Distinguish browser instructions from credential transport.** When a supported
local IdP starts device authorization but login fails before showing its code,
check the returned verification URI at both the host and SDK validators before
changing grants or issuer configuration. A display-only `http://localhost` link
is compatible with explicit/resolved local OIDC HTTP policy; it does not justify
accepting DNS names for credential-bearing Gateway connections. Cover the actual
provider URI shape in a joined test and rebuild every client build used by the
manual launcher, not just the SDK test build (2026-09-30 local Zitadel handoff).
Check credential timestamps before treating a later generic denial as a new
grant failure. A client-side expiry check can clear the projection without any
new Gateway traffic; transport reconnect does not renew a login. Record initial
attachment and later refresh separately, because an atomic history/journal sync
can discard partial success (2026-09-30 manual terminal continuation).

**Separate login assertions from application-session lifetime.** Before choosing
a credential TTL, inspect existing browser and CLI session ownership. A valid
OIDC assertion can establish an application session with its own lifecycle.
For an open TUI, use connection ownership and authenticated keepalives, current
permission checks, and bounded unclaimed/reconnect cleanup; do not silently
turn a short token TTL into a user-visible total session limit. Trace every
client freshness check and immutable server binding when changing lifetime
semantics (user correction, 2026-09-30).
When adding idle authorization checks, trace their denial through the transport
owner to the renderer as well as through ordinary request replies. An unsolicited
revocation notice must retain the unauthorized state across reconnect and reach
the surface's private-data clearing path; classifying it as a recoverable
protocol error loses that invariant (2026-09-30 terminal keepalive review).

<!-- applied-learning: preserve-the-proof-subject-when-canonicalizing-an-owner -->
<a id="applied-learning-preserve-the-proof-subject-when-canonicalizing-an-owner"></a>
**Preserve the proof subject when canonicalizing an owner.** When linked identities
should share conversation state, verify the actual signed/session-token identity
and derive the canonical owner through a trusted, fail-closed boundary. Do not
rewrite the caller ID before an API that verifies exact proof equality, or relax
that equality to make aliases work. Trace receipt, sender, owner, grant and consent
bindings together; successful no-alias resolution differs from unavailable alias
state. A convenience resolver that returns its input on errors cannot establish
authoritative canonicalization. Keep the original subject for audit/revocation,
and test linked identities, unrelated proofs, resolver outages and recovery before
migrating histories (learned 2026-09-07 reviewing the entry-point convergence plan).
Trace credential acquisition separately from signature transport before making
raw-key export a prerequisite. An absent operator file does not imply missing
human signing: OIDC can already hold an encrypted key and return process-owned
signing authority. Shared key-file formats do not make an agent proof a human
proof, and a process-owned authority is not automatically usable by a remote
client (2026-09-29 terminal/MCP authentication audit).

<!-- applied-learning: a-tool-s-capability-uri-must-reflect-its-maximum-effect-not-its-default-action -->
<a id="applied-learning-a-tool-s-capability-uri-must-reflect-its-maximum-effect-not-its-default-action"></a>
**A tool's capability URI must reflect its maximum effect, not its default action.** `memory_review_queue` defaults to `action: "list"` but also accepts `approve`/`reject`/`approve_all`, and the approve path calls `Arbor.Memory.accept_proposal/2`, which CREATES a knowledge node. It was mapped to `arbor://memory/read`, so a read-only capability could mutate the graph through it (found 2026-08-25 auditing the memory tool surface). Any action-dispatching tool — one with an `action:`/`mode:`/`op:` parameter — has to be gated on the most powerful branch it can reach, because the capability is checked once at the tool boundary and never re-checked per branch. Two corollaries: when auditing a URI map, read each action's BRANCHES rather than its name or description; and this is a standing argument against merging read and write tools to slim a tool surface, since the merged tool must then carry the write capability for everyone who only wanted to list.

<a id="gate-new-action-uri-needs-cap-and-trust-rule-on-execution-principal"></a>
**Gate: a NEW action URI needs BOTH a capability AND a trust rule on the EXECUTION PRINCIPAL — `mix arbor.coding.grant` now closes both layers for the execution principal.** Hit 2026-08-31 dispatching fleet-dispatch-v1 (first `design_council_review` use on omats). Historical behavior through 2026-08-31: the grant loop filtered findings to `authenticated_caller` and granted only to the key-file caller, so `arbor.coding.grant` could print "converged" while the coordinator still lacked caps (`authority_horizon_missing` with `principal_role=execution_principal`). As of 2026-09-01 the Mix task grants each missing URI to the principal the finding names (key-file caller and `--agent-id` coordinator) and converges only when no role has missing findings. As of 2026-09-03 it also, after capability convergence, installs a bare-prefix trust rule on the execution principal for each required `arbor://action/coding/` URI with `user_match: nil` and effective `:block`/`:ask`, mirroring same-parent sibling coding-rule modes (`:auto` on today's coding-agent profiles). Remaining manual cases: `--no-trust-rules`, or a refuse (`:no_siblings` / `:conflicting_siblings` / wildcard/root). Symptom if the trust layer is still open: the pipeline reaches the action and dies `design_council_failed` with `ApprovalGuard ... Policy denied` (`user_match: nil`, egress-classed baseline `:block`). Action: run `mix arbor.coding.grant` for the plan (both layers). Verify with `Arbor.Trust.explain/2`. Do not hand-type `Arbor.Trust.Store.update_profile` / `Arbor.Trust.Authority.set_rule` as the operator path.

<!-- applied-learning: separate-stateful-authorization-from-non-consuming-continuation-checks -->
<a id="applied-learning-separate-stateful-authorization-from-non-consuming-continuation-checks"></a>
**Separate stateful authorization from non-consuming continuation checks.** `Arbor.Security.authorize/4` consumes rate allowances and `max_uses`, potentially revoking an exhausted grant. Do not repeat it as a read-only release or dispatch predicate. Authenticate once, charge once, and use a Security-owned continuation check that retains active identity, current capability, reflex, delegation, approval and stateless constraints. A split decision/effect path must also retain the public facade's `InvocationAudit.observe_authorization/3` failure gate before issuing authority. Reject unsupported finite-use continuation before charging; never accept a missing grant to work around automatic revocation. Verify a one-token rate allowance, explicit revocation, suspended identity and failed audit sink (found 2026-09-26 while implementing durable conversation ingress).

<!-- applied-learning: check-conversation-authority-before-allowance-effects-and-again-before-publication -->
<a id="applied-learning-check-conversation-authority-before-allowance-effects-and-again-before-publication"></a>
**Check conversation authority before allowance effects and again before publication.** Bind a signed request to the exact operation and preserve its proof subject separately from the canonical conversation owner. Resolve that owner and reject unsupported finite-use chat grants before spending allowances. Accepted-turn continuations recheck current subject grants and the pinned owner without charging the request again; check at transcript commit and response publication, not only admission. A post-commit denial suppresses disclosure but does not undo the committed pair. (found 2026-09-27 in alias, rate-limit and blocked-turn convergence regressions).

Reply admission does not authorize every observability subscriber to read that
reply. Keep private user/assistant content and recipient identity off agent-wide
signals, including the normal successful path; publish fixed metadata and let
surfaces read through scoped authenticated APIs. Subscribe as an ordinary
observer and prove both public text and structured replies still succeed while
their events contain no private fields. A bearer-echo rejection test alone
misses ordinary private-message leakage (2026-10-03 native notice signal witness).

Trace compute and streaming separately from final reply publication. Session
stream deltas and LlmHandler completion previews have different producers; a
transform-only successful turn cannot qualify either. Retain content in the
current generation's private buffer and scoped activity read, while shared
signals carry lengths and lifecycle metadata. Reuse Session-owned process-local
purpose evidence rather than a caller-controlled context flag, and preserve
separately intended autonomous/operator behavior. Verify actual provider chunks
through public ingress, authorized prefix reads, final SQL and an unprivileged
signal observer with matched predecessor/candidate sources (source-confirmed
2026-10-04; qualification remains separate from preparation).

<!-- applied-learning: never-downgrade-protected-content-to-plaintext-when-key-authority-is-unavailable -->
<a id="applied-learning-never-downgrade-protected-content-to-plaintext-when-key-authority-is-unavailable"></a>
**Never downgrade protected content to plaintext when key authority is unavailable.**
Retiring raw-key access, losing a crypto provider, or failing encryption must
refuse a private send before persistence or delivery. A “graceful fallback” that
keeps the operation successful silently changes confidentiality semantics. Test
both the returned denial and that no plaintext message was stored (found
2026-10-06 while closing the channel raw-private-key deputy).

<!-- applied-learning: retire-positive-tests-for-unauthenticated-mailbox-shapes-with-the-shape -->
<a id="applied-learning-retire-positive-tests-for-unauthenticated-mailbox-shapes-with-the-shape"></a>
**Retire positive tests for an unauthenticated mailbox shape when that shape is retired.**
After a subscriber moves to custody-bearing delivery, an old test that sends the
legacy tuple directly and expects a mutation is asserting the vulnerability. Turn
it into a rejection regression and prove legitimate delivery separately through
the authenticated public transport (found 2026-10-07 while hardening distributed
nonce propagation).

<!-- applied-learning: verify-named-ets-authority-owners-against-real-supervision -->
<a id="applied-learning-verify-named-ets-authority-owners-against-real-supervision"></a>
**Verify named ETS authority owners against the real supervision tree.** A protected
named table prevents other live processes from writing its owner row, but the table
disappears when its owner dies. A squatter can then recreate both the table and a
self-asserted live PID, so row equality plus PID liveness authenticates nothing.
Before routing an authority-bearing call, verify that the table owner and row PID
are the exact child at the configured application supervision path, or require an
opaque custody chain held by a predecessor that survives the restart. Never admit a
production owner merely because the application is not yet reported as started;
that creates a pre-start capture window (found 2026-10-07 while testing Security
owner-directory restart takeover).

<!-- applied-learning: authoritative-signal-mutations-must-deny-ambiguous-publisher-config -->
<a id="applied-learning-authoritative-signal-mutations-must-deny-ambiguous-publisher-config"></a>
**Authoritative signal mutations must deny ambiguous publisher configuration.**
An absent or malformed owner mapping cannot mean “ordinary event” when the event
changes replay, revocation, or identity state. Classify the mutation type first,
then require one exact supervised publisher; missing, malformed, duplicate, or
unsubscribed ownership fails closed before local delivery or relay. Keep this rule
narrow so unrelated security observability remains available without inventing a
state owner (found 2026-10-07 while reviewing distributed security-sync admission).
