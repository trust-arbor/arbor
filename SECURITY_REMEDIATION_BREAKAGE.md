# Security Remediation — Intentional Breakages

**Branch:** `security/p0-h-remediation`
**Started:** 2026-05-31

Aggregated list of things the security audit fixes intentionally broke, deferred, or made harder. These are **not regressions** — each one is the desired least-privilege posture; the previous behavior was a backdoor or fail-open. They are collected here so a restoration plan can be made after all remediation work lands, rather than scrambling per fix.

A useful frame: every entry below answers the question *"what dev/operator action restores the behavior I used to have, and is that action itself the right shape?"* In several cases the restoration is genuinely operator-driven and we're done; in a few the right next step is to add a `mix` task or onboarding doc.

Status legend:
- **Unaddressed** — break exists, no restoration path written yet
- **Documented** — restoration path written, hasn't been exercised
- **Restored** — restoration shipped (mix task, doc, role mapping, etc.)
- **Accepted** — confirmed not worth restoring; this is the new posture

---

## Open Questions Inbox

Aggregated from per-entry `Open question:` lines so they don't get lost when the doc grows. Each links back to the entry that raised it. When a question is answered or no longer relevant, mark it ✅ resolved (link to commit / decision) and leave it here as history.

| # | From | Question |
|---|---|---|
| OQ-1 | B-A-1 | Does OidcAuth's `ensure_role/1` (calling `Arbor.Security.assign_role/2` with `default_role: :admin`) currently grant `arbor://consensus/admin` end-to-end? If the `:admin` role's capability map already includes it, B-A-1 is narrower than stated — only operators without a custom `:default_role` config are affected. Worth verifying before designing the dev-bootstrap restoration. |
| OQ-2 | B-A-2 | If we eventually want "dev mode" where Always Allow is back to one click, the cleanest shape is probably a `:dev_admin` role that bundles `arbor://consensus/admin` + `arbor://trust/auto_promote/**`, behind an explicit config flag (`:arbor_security, :enable_dev_admin_role`). Is that posture acceptable, or do we want Always Allow to always require an explicit per-target grant? |
| OQ-3 | B-A-4 | Ship a one-time `mix arbor.security.drop_stale_signed_records` task that purges `CapabilityStore` / signed-receipt records whose `issuer_id` no longer matches the live `SystemAuthority.agent_id()` after the P0-5 cutover, or just let them sit as dead weight? Dead weight is fine for now (records are filtered out at verify time anyway), but a purge keeps the store tidy and surfaces the cutover explicitly. |
| OQ-4 | B-B-1 | Should `POST /api/memory/summarize` require its own resource (`arbor://memory/summarize/{target}`) rather than reusing `arbor://memory/read/{target}`? Separating them lets "X can see summaries of Y but not Y's raw recall" be expressible. Probably overkill for now, but worth pinning before granting broad `read` to any caller. |
| OQ-5 | B-B-4 | Ship a built-in capability-based `Arbor.Consensus.Authorizer` implementation (checks `arbor://consensus/propose/{topic}` or similar) so production can flip `:require_authorizer` on without forcing every operator to roll their own module. And: should `Arbor.Consensus.propose/2` call `authorize_propose/3` internally so callers can't accidentally bypass the gate by going through the wrong facade? |

When a fix surfaces something that genuinely needs a separate decision — not the restoration shape itself, but a design or policy call — capture it both **inline** in the entry it came from AND **here** as a new OQ-N row. Inline preserves context; the index makes it scannable.

---

## Cluster A breaks

### B-A-1. Dashboard `/consensus` Approve / Deny buttons require explicit role assignment

**Closed by:** H11 (`7815a8f3`) + H11b (`d3c33809`)
**Status:** Unaddressed

**Before:** Any OIDC user who logged in (H11) or simply visited `/consensus` (H11b) was auto-granted `arbor://consensus/admin`. Force-approve and force-reject worked out of the box.

**After:** Neither code path grants admin. Pressing Approve / Deny from the dashboard fails with a denial unless the acting user already holds `arbor://consensus/admin` via explicit role mapping.

**Restoration shape:**
- For the single-user dev case (Hysun): one-time grant via `Arbor.Security.grant(principal: "human_<hash>", resource: "arbor://consensus/admin", metadata: %{source: :manual_dev})`, or via `Arbor.Security.assign_role/2` once a role-to-capability mapping for `:admin` is wired in.
- For onboarding: a `mix arbor.security.grant_role` task or an `arbor.dev_admin/0` REPL helper would make this two seconds of work instead of REPL surgery.

**Open question:** does OidcAuth's `ensure_role/1` (which calls `Arbor.Security.assign_role/2` with `default_role: :admin`) actually grant `arbor://consensus/admin` end-to-end? If `:admin` role's capability map already includes it, this break is partial — only users whose OIDC config doesn't define `:default_role` are affected. Worth verifying.

---

### B-A-2. Dashboard "Always Allow" requires `arbor://trust/auto_promote`

**Closed by:** H13 (`585dd511`)
**Status:** Unaddressed

**Before:** Any user who could approve a proposal could one-click promote the agent's trust profile to `:auto` for the proposed resource — including `arbor://shell/execute` and `arbor://fs/write/**`.

**After:** The Always Allow flow requires the acting user to hold `arbor://trust/auto_promote/{target_agent_id}`. This capability is **intentionally not auto-granted anywhere** — it's a high-privilege escalation primitive.

**Restoration shape:**
- Manual grant: `Arbor.Security.grant(principal: <user>, resource: "arbor://trust/auto_promote/<target>", ...)`. Per-target by design.
- For a "trust everything for this agent" admin posture: grant a wildcard variant (`arbor://trust/auto_promote/**`) — but this is essentially equivalent to "I am god for trust". Make sure that's actually what you want.

**Open question:** if we eventually want a "dev mode" where Always Allow is back to one click, the cleanest shape is probably a `:dev_admin` role that grants both `arbor://consensus/admin` AND `arbor://trust/auto_promote/**`, behind an explicit config flag like `:arbor_security, :enable_dev_admin_role`. Worth proposing.

---

### B-A-3. Human OIDC users no longer auto-pass `:requires_approval` decisions

**Closed by:** H12 (`641278a8`)
**Status:** Accepted (this *is* the fix)

**Before:** Any `human_*` actor that hit `AuthDecision.check → {:requires_approval, _cap}` for `arbor://consensus/admin` was auto-approved.

**After:** Treated identically to agents — returns `{:error, {:unauthorized, :pending_approval}}` and goes through the explicit approval flow.

**Restoration shape:** None needed. The bypass was a backdoor. If the trust profile's approval gating is too aggressive for human OIDC users in practice, the right answer is to adjust the trust profile, not re-introduce the bypass.

---

### B-A-4. All previously-issued capabilities, receipts, and endorsements become unverifiable on first persistent boot

**Closed by:** P0-5 (`434b2655`) — Path C, hard cutover
**Status:** Documented (the strategy *is* the documentation; just needs operator awareness)

**Before:** Plaintext authority key on disk. Silent rotation on load failure. Existing capabilities verified against the same long-lived (insecurely-stored) key.

**After:**
- On first boot in `:persistent` mode after this commit: the pre-v2 plaintext `system_authority_keypair` record is deleted. A fresh Ed25519 + X25519 keypair is generated and persisted via `SigningKeyStore` (AES-GCM at rest).
- Every signed capability, signed receipt, signed endorsement, and signed-request token in the system was signed by the *old* authority key. The new authority can't verify any of them.

**Restoration shape:**
- Single-user dev case: re-grant whatever capabilities the operator needs from scratch. There aren't many — Hysun's own dashboard admin grant, any per-agent caps, the OIDC default-role caps (regranted on next login automatically).
- Operationally cleaner: a `mix arbor.security.bootstrap_dev` task that re-grants Hysun's known set in one shot. Worth a small helper.
- **There is no migration path back** to old-signed caps. They are cryptographically unverifiable. Per the operator's explicit choice (Path C), this is fine.

**Open question:** consider running a one-time post-deploy script that drops `CapabilityStore` records older than `<timestamp of authority key creation>` from the JSONFile backend — they're guaranteed dead weight after the cutover.

---

### B-A-5. `Arbor.Security.Kernel.grant_capability/1` now signs — anything that depended on unsigned caps will fail

**Closed by:** H15 (`4155970b`)
**Status:** Accepted (nothing legitimately depended on unsigned caps)

**Before:** `Kernel.grant_capability/1` skipped `SystemAuthority.sign_capability/1`. Caps in the store via this path had no `issuer_id` and no `issuer_signature`.

**After:** Routed through `SystemAuthority.sign_capability/1` like the public `Security.grant/1` facade. Caps are now verifiable.

**Restoration shape:** None. Audit showed only `kernel_test.exs` called this path; no production data should exist. If any unsigned caps DO exist in someone's `CapabilityStore`, they will continue to be retrievable but won't pass `SystemAuthority.verify_capability_signature/1` — those need to be re-granted via either facade path (both now sign).

---

### B-A-6. Production dashboard returns 503 if no OIDC provider is configured

**Closed by:** P0-1 (`0bcde54a`)
**Status:** Accepted

**Before:** Production deployment with no OIDC config silently exposed the dashboard with no auth.

**After:** When `:require_auth` is true AND no OIDC provider is configured, the OidcAuth plug halts with a 503 and an error log.

**Restoration shape:** None — this is the desired posture. The "restoration" is to configure an OIDC provider in `runtime.exs`. Dev mode (`:require_auth` not set or false) is unaffected.

---

### B-A-7. Unknown atoms in persisted job records / agent specs resolve to `nil`

**Closed by:** H9 (`f320a913`)
**Status:** Accepted

**Before:** Unknown `owner_node` strings and unknown `provider` strings in persisted data were silently converted to fresh atoms via `String.to_atom`. DoS vector.

**After:** Unknown atoms resolve to `nil`. Owner: entry becomes unclaimable on the unknown node (correct). Provider: spec falls back to the previous provider via `safe_to_atom(p) || spec.provider`.

**Restoration shape:** None needed. If there's stale persisted data with truly unknown atom names that *should* still be valid, the migration is to write them in as proper atoms before they're persisted, not to weaken the parser.

---

---

## Cluster B breaks

### B-B-1. Memory router requires authenticated caller AND a cap for the target's memory

**Closed by:** P0-4 (this commit)
**Status:** Unaddressed

**Before:** `Arbor.Gateway.Memory.Router.authorize_memory_access/2` authorized the *target* `agent_id` (the value in the URL/body) as the principal. Any authenticated caller could read or mutate any other agent's memory just by supplying the target's id. The function also fell through to `:ok` on every non-explicit-error branch, on `Code.ensure_loaded?` returning false, and on every rescue.

**After:**
- The caller comes from `conn.assigns.agent_id` (set by the gateway's signed-request / JWT auth pipeline), never from the request body.
- The target comes from the body/URL but is only used to build the *resource URI* — never as the principal.
- Only `{:ok, :authorized}` allows. Every other AuthDecision shape — pending approval, `{:error, _}`, security unavailable, missing caller, unexpected — returns `{:error, _}` and the route responds with 403.
- `POST /summarize`, which previously had no authorization at all, now requires the caller to hold `arbor://memory/read/{target_agent_id}`.

**Restoration shape:**
- Any client that talked to `/api/memory/*` and relied on the gateway not actually checking caller identity needs to start authenticating. With signed-request or JWT auth already enforced by the upstream `:require_auth_unless_health` plug, this should already be the case in practice — but if a deployment had a workaround route or a test fixture that bypassed auth, it now 403s.
- For an authenticated agent to access **another** agent's memory, the *caller* needs an explicit grant of `arbor://memory/{read|write}/{target_agent_id}`. There is no broad "memory admin" cap; per-target by design.
- For a "memory ops" superuser role: a wildcard cap on `arbor://memory/{read|write}/**` is the cleanest shape. Same `:dev_admin` discussion as OQ-2 applies.

**Open question (OQ-4 below):** the post-fix `POST /summarize` now requires `arbor://memory/read/{target}`. Is that the right resource? An argument could be made for a separate `arbor://memory/summarize/{target}` so that "let X see summaries of Y but not raw recall" is expressible. Probably overkill for now, but worth pinning before broadly granting `read`.

---

### B-B-5. AuthDecision honors registry status for humans; rescue/catch paths fail closed in strict mode

**Closed by:** H5 (this commit)
**Status:** Mostly accepted; one knob worth flipping in prod

**Before:**
- `check_identity/1` short-circuited `String.starts_with?(pid, "human_")` to `{:ok, auth}` — suspended or revoked humans kept authorizing for as long as their capabilities existed.
- `check_identity_status/2`'s `rescue` clause returned `{:ok, auth}` unconditionally — any exception during a registry lookup silently authorized.
- `find_matching_capability/2`'s `rescue` and `:exit` clauses fell through to `try_preloaded_capabilities/2`, which uses `AuthContext.capabilities` (caller-supplied or replay-derived, not re-signature-verified) when the CapabilityStore is unreachable.

**After:**
- Humans go through `check_identity_status/2` like agents. Suspended → `{:error, {:unauthorized, :identity_suspended}}`. Revoked → `{:error, {:unauthorized, :identity_revoked}}`.
- `rescue` and `:exit` in `check_identity_status/2` now consult `strict_identity_mode?` and deny when strict (matching the existing `:exit` behavior).
- CapabilityStore unavailable now denies in strict mode rather than falling back to preloaded caps. Permissive (dev/test default) preserves the existing fallback for legitimate test paths.

**Restoration shape:**
- For the human suspension fix: nothing to restore. The audit's prescribed behavior is now the default; revoking a human identity actually does something.
- For strict-mode CapabilityStore denials: production deployments should set `:arbor_security, :strict_identity_mode, true`. Test setups that wire `AuthContext.capabilities` directly (rather than putting caps in the store) keep working because dev defaults are permissive.

**Open question:** Currently `strict_identity_mode?` doubles as the strict-CapabilityStore-mode knob (one config). Worth splitting if an operator wants strict-identity-but-permissive-store or vice versa — but no concrete need yet.

---

### B-B-4. Consensus Coordinator refuses to authorize proposals without an authorizer module in strict mode

**Closed by:** M6 (this commit)
**Status:** Unaddressed (config flag required to flip on; production should set it)

**Before:** `Coordinator.maybe_authorize(nil, _proposal) -> :ok` — any agent could submit any proposal on any topic. Combined with H11 (auto-grant of consensus/admin — closed) and H12 (human_ bypass — closed), this was the third leg of "every OIDC user is root."

**After:** `maybe_authorize(nil, _)` now checks `:arbor_consensus, :require_authorizer` config (defaults to `Mix.env() == :prod`). When strict, returns `{:error, :no_authorizer_configured}`. Dev/test default to permissive so existing test setups that don't wire an authorizer keep working — tests that need to exercise the deny branch set the config explicitly.

**Restoration shape:**
- Production deployments need to set `config :arbor_consensus, :require_authorizer, true` AND start the Coordinator with `:authorizer` pointing at an implementation of `Arbor.Consensus.Authorizer`. There is currently no built-in capability-based authorizer — that's worth shipping before recommending the flip in prod.
- Dev defaults are unchanged; existing scripts and dashboards keep working without wiring an authorizer until the user explicitly opts in.

**Open question (OQ-5 below):** the audit's recommendation also includes "make `propose/2` call `authorize_propose/3` internally rather than requiring callers to opt in." That's a structural change to the public facade. It doesn't close additional surface beyond what M6's strict-mode flag closes (since `authorize_propose/3` consults the same authorizer), so it's left for a separate cleanup pass.

---

### B-B-3. `IdentityAliases.link/3` and `unlink/2` require `arbor://identity/alias/manage`

**Closed by:** M5 (this commit)
**Status:** Unaddressed

**Before:** `IdentityAliases.link/2` and `unlink/1` checked only self-aliasing and circular alias chains. Any code path that could call `link` could redirect a victim's future OIDC logins to an attacker-controlled identity — and inherit whatever capabilities had been granted to the victim's primary id.

**After:**
- Signature changed: `link(caller_id, secondary_id, primary_id)` and `unlink(caller_id, secondary_id)`. The caller_id is required and must hold `arbor://identity/alias/manage`.
- Both functions audit-log on success (`Logger.info "[IdentityAliases] caller=… linking/unlinking …"`).
- `resolve/1` and `list_aliases/1` remain ungated (read-only).
- `link/2` and `unlink/1` no longer exist.

**Restoration shape:**
- Nothing in the tree called `link/2` or `unlink/1` before this commit, so production code is unaffected. Operator REPL bootstrap or any future admin LiveView wiring needs to use the new arities and pass the operator's identity as `caller_id`.
- To use the function: grant the operator's `human_*` identity `arbor://identity/alias/manage` first (one-time, same dev-bootstrap shape as B-A-1).
- The capability is intentionally not auto-granted anywhere — it's an admin-class operation.

---

### B-B-2. `arbor_status` MCP tool requires explicit `agent_id` AND a caller cap per component

**Closed by:** M8 (this commit)
**Status:** Unaddressed

**Before:**
- `arbor_status` with `component: "memory"|"capabilities"|"goals"` and no `agent_id` silently called `find_first_agent_id/0` and returned that agent's memory/caps/goals. Any authenticated MCP client could enumerate state without naming a target.
- None of the components actually checked the authenticated caller's capabilities — the `authenticated_agent_id/0` helper existed but was never consulted.
- The `"overview"` component embedded `get_memory_summary/0`, which had the same first-agent default *and* leaked the chosen agent's id + note count to every caller.

**After:**
- Each of `"memory"`, `"capabilities"`, `"goals"` requires an explicit, non-empty `agent_id`. Omission returns "arbor_status requires an explicit `agent_id`…" instead of leaking the first agent's data.
- An authorization check binds the caller (`authenticated_agent_id/0`) to `arbor://status/{component}/{target_id}`. Missing caller → denial. Security subsystem unreachable → denial. No-cap → denial.
- The `"overview"` component reports only the aggregate ("Memory subsystem reachable; N agent(s) registered…") — no specific agent named.
- `find_first_agent_id/0` is deleted as dead code.

**Restoration shape:**
- Any MCP client that previously relied on the implicit-first-agent default must now name the target explicitly. The denial messages are written to be self-explanatory in the MCP response stream so this surfaces immediately.
- For a single authenticated caller to inspect any other agent's status, they need `arbor://status/{memory|capabilities|goals}/{target_id}` per target. The `:dev_admin` shape from OQ-2 should probably bundle a `arbor://status/**` wildcard for the dev case — same restoration pattern.
- No restoration for the overview leak — the aggregate is the right shape.

---

## Cross-cutting consequences

### Operator restoration cheat-sheet (sketch)

Once Cluster A merges, the smallest operator action that brings dev back to a fully-functional state is:

```elixir
# Run in iex after first boot post-merge.
# Replace agent_id below with your own (see SystemAuthority.agent_id() on the old key —
# or just find the human_ identity in CapabilityStore after first OIDC login).
human_id = "human_..."

# Cluster A breaks restored:
Arbor.Security.grant(principal: human_id, resource: "arbor://consensus/admin", metadata: %{source: :dev_bootstrap})
Arbor.Security.grant(principal: human_id, resource: "arbor://trust/auto_promote/**", metadata: %{source: :dev_bootstrap})

# Plus whatever per-agent caps were in CapabilityStore before P0-5's key rotation.
```

If this becomes annoying to do by hand, it earns a `mix arbor.security.bootstrap_dev` task.

### Tests vs deploy parity

Most regression tests use the public APIs and per-test setup, so they don't depend on the dev-bootstrap state. But the dashboard's existing LiveView tests (`consensus_live_test.exs`, `chat_live_test.exs`, etc.) may interact with the now-gated paths. If any of those go red after B+C work, the fix is in the test setup (grant the caps the test needs), not in the production code.

### Documentation TODO

- README or CONTRIBUTING.md should call out the post-pull-to-this-branch bootstrap step.
- The OIDC provider docs should explicitly say `default_role: :admin` is *not* sufficient to make the dashboard work — the `:admin` role's capability map must include `arbor://consensus/admin` (and probably `arbor://trust/auto_promote/**` for a true admin role).

---

## Process note

Going forward, every fix in this remediation effort should append an entry here as part of the commit, in the same style. That avoids a second sweep at the end and keeps the breakage inventory accurate. After Cluster B+C+D land, this doc becomes the input to the restoration plan: each `Unaddressed` entry gets a concrete restoration action, the `Accepted` entries get marked closed, and the result is the list of follow-up tickets needed before this branch can ship.

Add **breakage entries** to this file when:
- Removing an auto-grant or implicit elevation
- Tightening a fail-open path so dev/test scenarios that depended on it now fail
- Choosing a hard cutover over a migration
- Locking a previously-public-by-default surface behind a capability

Add **open question rows** to the Open Questions Inbox when a fix surfaces a design or policy decision that:
- Isn't directly the restoration shape (which lives in the entry's `Restoration shape:` block)
- Needs an answer before the restoration plan can be finalized
- Came up during the fix but is worth resolving with fresh eyes rather than in-the-moment

Capture open questions both **inline** in the entry that raised them AND as a new row in the Open Questions Inbox table.

**Don't** add entries for:
- Bug fixes that strictly reduce the attack surface without breaking documented behavior
- Internal refactors with no API surface change
- New regression tests
