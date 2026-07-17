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
