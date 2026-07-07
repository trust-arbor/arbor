---
name: AttackSurface
description: >
  Maintain a living attack-surface inventory of everything Hysun has deployed —
  hosts, sites, APIs, databases, vendors, SaaS accounts. Use when adding/removing
  infrastructure, after any deploy, when a new vendor/account is created, or on the
  scheduled review cadence. Keeps .security/attacksurface.md current. Pairs with the
  /assess-attack-surface workflow (active assessment of one asset).
---

# AttackSurface — Living Inventory Maintenance

## Scope & safety (read first)

- **Defensive, inventory-only.** This skill DOCUMENTS assets Hysun owns/operates.
  It never scans, probes, or tests live systems — that is `/assess-attack-surface`,
  and only against assets Hysun authorizes.
- **The file is an attacker's map.** `.security/attacksurface.md` lives in a
  gitignored path because the `arbor` repo is PUBLIC. Never move it into tracked
  space, never paste its contents into a public issue/PR/blog, never commit it.
  If asked to share it, produce a redacted excerpt, not the file.
- **No secrets in the file.** Reference *how* auth works ("Ed25519 SignedRequest",
  "OIDC device flow via Zitadel") and *where* a secret lives ("1Password / .env"),
  never the secret value. If a real credential is ever discovered in a repo during
  maintenance, that's a P0 finding, not a thing to record verbatim.

## The asset record schema (one block per asset)

Every entry uses this shape so records stay comparable and the assess workflow
can consume them:

```
### <asset name>
- **Kind:** web property | API | database | host/node | SaaS account | vendor account | network fabric
- **Tech:** stack/platform + version if known
- **Hosting:** self-hosted (which node) | third-party (which vendor)
- **Exposure:** public | internal-only | VPN/WireGuard-only | localhost — and to which audience
- **Auth in:** the mechanism (Ed25519 SignedRequest / OIDC device flow / SSH key / API key / OAuth / basic / none)
- **Defenses:** firewall (pf/nftables rules), TLS, capability gating, rate limit, WAF, isolation tier, MFA
- **Deployed there:** what actually runs on/in it (services, data classes, other assets it fronts)
- **Common issues:** the known misconfig/vuln classes for THIS platform (see the class library below)
- **Blast radius:** what falls if this is owned (which zones/data/other assets)
- **Criticality:** crown-jewel | high | medium | low  (drives assess cadence)
- **Last assessed:** date + link to the assessment note
```

## Maintenance loop (how this stays "living")

1. **Trigger on change.** New deploy, new vendor account, DNS change, firewall
   edit, node added/removed, new public endpoint → update the record same day.
   The change IS the trigger; don't wait for the review cadence.
2. **Discovery passes** (inventory only — repo/config evidence, not live probing):
   - grep mounted repos for hosts/IPs/domains, vendor SDK usage, deploy configs,
     `.env.example` keys (each key ≈ a vendor account/secret to inventory),
     CI/CD config, DNS/ACME references.
   - Reconcile against the last inventory: flag NEW (undocumented), GONE
     (decommissioned — mark, don't delete; decommissioned assets are audit
     history), and CHANGED exposure.
3. **Never delete, always supersede.** A removed asset becomes
   `status: decommissioned <date>` — "we turned that off" is security-relevant.
4. **Cross-link Arbor's own zones.** Map each asset to its trust zone from
   `1-brainstorming/trust-zone-segmentation-architecture.md` (core / compute /
   edge / lab / sensor) so the inventory and the zone model stay consistent.
5. **Regenerate the summary tables** (exposure matrix, criticality roll-up,
   assessment-due list) from the records — computed, never hand-maintained
   (the drift-guard discipline).

## The vuln-class library (per-platform "common issues" prompts)

When filling `Common issues` for an asset, pull the relevant class set. Keep this
list growing as new platforms are adopted:

- **Public web (static/Phoenix):** missing security headers (CSP/HSTS), TLS
  config (weak ciphers, no OCSP staple), subdomain takeover on stale DNS,
  source-map/`.git` exposure, verbose error pages.
- **Gateway / API (Phoenix/Cowboy, SignedRequest):** authz-vs-authn gaps (a
  valid signature that skips a capability check), replay window on nonce/expiry,
  rate-limit bypass, WS upgrade auth, fail-open fallbacks (the 2026-04-07 class).
- **Database (Postgres/SQLite):** default/weak creds, listening on non-loopback,
  missing TLS, over-broad grants, backups unencrypted or world-readable.
- **Self-hosted git/CI (Forgejo):** exposed admin, webhook SSRF, runner escapes,
  token scope creep, stored secrets in CI config, public repo leaking secrets.
- **Cloud edge (OpenBSD/pf VPS):** SSH exposure (key-only? fail2ban?), pf rule
  drift, ACME/cert renewal failure, dist-port exposure (EPMD 4369 / 9100-9155),
  the DMZ-becomes-mesh-member regression.
- **Network fabric (WireGuard):** key rotation, over-broad AllowedIPs, a peer
  bridging two zones, endpoint IP leakage.
- **BEAM cluster:** shared cookie = all-or-nothing trust, no intra-mesh authz,
  a public node joined to the mesh (see cluster-network-security-dmz).
- **Vendor/SaaS accounts (LLM providers, GitHub, HuggingFace, DNS registrar):**
  API key sprawl/rotation, missing MFA, over-scoped tokens, OAuth app grants,
  billing/quota abuse if a key leaks, account-recovery path (the real backdoor).
- **Local inference (Ollama/LM Studio):** default bind to 0.0.0.0, no auth on the
  inference port, model-pull supply chain.
- **Edge device (Android/Termux beamapp):** roaming exposure, on-device key
  storage, the bridge-client-not-mesh-peer rule.

## Output discipline

- Keep records terse — this is an operational index, not prose.
- The file opens with a **change log** (date · what changed) and the three
  generated summary tables, then the per-asset records grouped by trust zone.
- When done, report to Hysun: what's NEW since last pass, what CHANGED exposure,
  and the top-3 assessment-due items by (criticality × staleness).
