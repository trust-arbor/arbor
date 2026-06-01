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

Add entries to this file when:
- Removing an auto-grant or implicit elevation
- Tightening a fail-open path so dev/test scenarios that depended on it now fail
- Choosing a hard cutover over a migration
- Locking a previously-public-by-default surface behind a capability

**Don't** add entries for:
- Bug fixes that strictly reduce the attack surface without breaking documented behavior
- Internal refactors with no API surface change
- New regression tests
