# Security Design Review — Cryptography (2026-06-09)

Scope: design-level review of cryptography use in `arbor`. Sources: `docs/arbor/SECURITY_ARCHITECTURE.md`, `docs/arbor-security-design.md`, `docs/arbor/IDENTITY.md`, and the crypto-bearing modules in `arbor_security`, `arbor_contracts`, `arbor_orchestrator`, `arbor_signals`. Code was read to verify what the design actually does; this is not a full implementation audit.

## Summary

Primitive selection is sound (Ed25519, X25519, AES-256-GCM, HKDF-SHA256, HMAC-SHA256, all via OTP `:crypto`), payload canonicalization is done correctly (length-prefixed fields), and the layered key-isolation roadmap (Layers 0–4) is honest about its current gaps. The significant problems are protocol/composition issues, not primitive choice: unsigned security-relevant capability fields, a static-static ECDH `seal` with no forward secrecy or sender authentication, pre-authentication deserialization in session tokens, and single-node replay protection. The known D1–D4 items in `arbor-security-design.md` (unauthenticated `/mcp`, signer-not-bound-to-principal) remain the highest-impact issues overall — the crypto layer cannot compensate for an unauthenticated ingress.

## What's done well

- Canonical signing payloads use 32-bit length prefixes on every variable field (`SignedRequest`, `Capability.signing_payload/1`) — prevents field-boundary ambiguity.
- Self-certifying agent IDs: `agent_id = "agent_" <> hex(SHA-256(pubkey))`, enforced at registration (`Identity.Registry`), so an existing agent ID cannot be re-bound to a different key.
- SignedRequest replay defense: timestamp freshness + random 16-byte nonce + nonce cache, with cheapest-check-first ordering; zero-nonce rejection guards a failed entropy source.
- Hand-rolled HKDF matches RFC 5869 (zero-salt extract, correct expand loop, domain-separation info strings used consistently: `arbor-seal-v1`, `arbor-dr-*`, `arbor-checkpoint-hmac-v1`).
- Checkpoint HMAC is fail-closed on resume and AAD-bound to `run_id` + `current_node` + `graph_hash`.
- SessionToken uses `:crypto.hash_equals/2` (constant-time compare).
- DoubleRatchet follows the Signal construction (root/chain/message KDF chains, header in AAD, bounded skipped keys with 1h expiry).
- Capability attenuation (`uri_subset?`, `constraints_subset?`, `envelope_subset?`, delegation depth/expiry/max_uses min-merge) rejects widening, including the `Map.merge` override trap.
- The SECURITY_ARCHITECTURE threat model explicitly concedes T4 (key readable from inside the BEAM) rather than overclaiming.

## Findings

| # | Severity | Area | Issue |
|---|---|---|---|
| C1 | High | Capability signing | `principal_scope`, `allowed_delegatees`, `metadata` not covered by issuer signature |
| C2 | High | Sealed messages | `seal/unseal` is static-static ECDH: no forward secrecy, no sender authentication, one key per pair forever |
| C3 | High (known) | Identity protocol | D3/D4: verified signer not bound to principal; unknown identities proceed — crypto verification exists but isn't load-bearing |
| C4 | Medium | Session tokens | `binary_to_term` on attacker-supplied bytes before HMAC verification; non-canonical serialization; no revocation |
| C5 | Medium | Replay protection | NonceCache is single-node, in-memory — replay across nodes and across restarts within the drift window |
| C6 | Medium | Key at rest | SigningKeyStore KEK lives beside the data it protects, same UID; brief 0644 window on master key creation |
| C7 | Medium | Checkpoint HMAC | Silent HKDF→HMAC derivation fallback; signing key reused as HKDF IKM conflicts with the Layer 3/4 plan |
| C8 | Low–Med | Capability semantics | Concrete (non-wildcard) cap URI implicitly grants the entire subtree |
| C9 | Low | Ed25519 usage | `:sha512` digest parameter passed to `:crypto.sign(:eddsa, ...)` — semantics version-dependent/confusing; use `:none` |
| C10 | Low | Registry | Unauthenticated `register/1` (first-come), non-unique names, JSON persistence with no integrity protection |
| C11 | Low | Hygiene | Unused `Capability.signature` field alongside `issuer_signature`; DoubleRatchet decrypt raises on malformed ciphertext |

### C1 — Capability issuer signature does not cover all security-relevant fields (High)

`Capability.signing_payload/1` signs: id, resource_uri, principal_id, issuer_id, granted_at, expires_at, not_before, delegation_depth, max_uses, session_id, task_id, constraints, signed_at.

It omits `principal_scope` (the multi-user binding), `allowed_delegatees` (delegation restriction), `parent_capability_id`, and `metadata`. Anyone who can mutate a capability in storage or in transit (JSON file backend, gateway boundary) can strip the user binding or the delegatee allowlist without invalidating `issuer_signature`. Since the design's stated purpose of signing is "unforgeable grants" that survive an untrusted store, every field the authorizer reads must be in the payload. Fix: extend `signing_payload/1` (version the payload — `signed_at`/`v` field exists for this) and re-sign on migration.

### C2 — `Crypto.seal/unseal` provides weaker guarantees than callers likely assume (High)

`seal/3` is static-static X25519 ECDH → HKDF(fixed info, no salt) → AES-GCM. Consequences:

- One symmetric key per (sender, recipient) pair, forever. No forward secrecy: compromise of either static X25519 key decrypts all recorded traffic. Random 96-bit IVs under a fixed key also carry the NIST ~2^32-message bound.
- No sender authentication: `sender_public` travels in-band and `unseal/2` derives the key from whatever arrives. Any party can seal a message and claim any unregistered "sender". Authenticity holds only if the caller separately verifies `sender_public` against `Registry.lookup_encryption_key/1` — `Signals.Channels` partially leans on layered signal auth for this, but the primitive's contract doesn't require it.
- No replay protection at this layer.

Recommendation: either (a) make seal ECIES-style (ephemeral sender key per message) plus an Ed25519 signature over `ephemeral_pub || ciphertext` binding sender identity, or (b) document `seal` as "confidentiality only, unauthenticated, no FS" and require call sites to use DoubleRatchet (which exists and is good) for anything long-lived. The channel-invitation flow should verify the inviter's key against the registry before trusting an unsealed channel key.

### C3 — Crypto verification exists but is not load-bearing (High, already tracked as D3/D4)

`maybe_verify_identity/1` verifies the Ed25519 signature but does not check that the verified `agent_id` equals the `principal_id` being authorized, and `:not_found` identities proceed. This converts a correct signature scheme into a no-op: an attacker with any registered key can sign requests authorized as someone else. The delta register already flags this P0 — endorsed; nothing else in this review matters more except `/mcp` ingress auth (D1/D2).

### C4 — SessionToken: parse-before-verify and non-canonical encoding (Medium)

`verify/1` runs `:erlang.binary_to_term(bytes, [:safe])` on caller-supplied tokens before checking the HMAC. `[:safe]` blocks atom creation, but arbitrary nested terms are still materialized pre-authentication (DoS surface), and the pattern is fragile — one refactor away from a deserialization bug. Also: `term_to_binary` map encoding is not guaranteed stable across OTP releases (HMAC computed over re-serialized payload may diverge after an upgrade, invalidating live sessions); 24h TTL with no revocation; secret only defined in `config/dev.exs` (prod raises — fail-closed, good, but provisioning is undocumented). Recommendation: HMAC over the exact transported payload bytes (verify, then decode), or replace with `Phoenix.Token`/PASETO; add a session revocation hook; document prod secret provisioning.

### C5 — Nonce cache is per-node and volatile (Medium)

`NonceCache` is an in-memory GenServer with no persistence and no cluster distribution (unlike `Identity.Registry`, which syncs via signals). A signed request can be replayed against a second node, or against the same node after restart, within `timestamp_max_drift_seconds`. Acceptable single-node; should be stated as an explicit design assumption, and revisited before any multi-node deployment (cluster-wide cache, or accept-once semantics in a shared store).

### C6 — Encryption at rest where the KEK sits next to the data (Medium)

`SigningKeyStore` encrypts agent private keys with a key derived from `~/.arbor/security/master.key` — same filesystem, same UID, mode 0600. Against the threats that matter (T2–T4), this is obfuscation, which the architecture doc implicitly concedes; say so explicitly in the module doc so nobody counts it as a control. Mechanical issue: `File.write` then `File.chmod` leaves a umask-dependent window where the master key may be world-readable; create with restrictive permissions atomically (write to temp file with 0600, rename).

### C7 — Checkpoint HMAC derivation has two silent code paths and a hardware-key conflict (Medium)

`derive_checkpoint_hmac_secret/1` uses HKDF when `Arbor.Security.Crypto` is loaded, else `HMAC(key, label)`. Both are sound in isolation, but a checkpoint signed in one mode fails verification in the other — a silent availability/correctness hazard. Pick one (plain `HMAC(key, label)` is sufficient here) or fail loudly when the preferred module is absent.

Design tension: deriving the HMAC secret from the raw Ed25519 private key (key reuse across signing and MAC purposes) requires an extractable key — exactly what Layers 3/4 eliminate. The SECURITY_ARCHITECTURE doc already plans `derive_hmac` in the signer process with the "both bound" formulation (`HKDF(daemon_key, "checkpoint-" <> operator_id <> ...)`) — that's the right design; treat today's scheme as explicitly transitional and keep the derivation behind the Phase 1 `Arbor.Identity` facade so it can swap.

### C8 — Concrete capability URIs implicitly grant subtrees (Low–Medium)

`grants_access?/2` treats `arbor://fs/read/project` as covering `arbor://fs/read/project/anything/below`, and `uri_subset?` codifies "parent is concrete; its prefix rule already covers subtree access." So a concrete-looking grant is semantically `/**`. This is a coherent choice but violates least-surprise — an operator granting one path has granted a subtree. Recommend requiring explicit `/**` for subtree grants and making concrete URIs exact-match (breaking change; at minimum document loudly in the capability moduledoc and grant tooling).

### C9 — `:sha512` digest parameter on eddsa operations (Low)

`Crypto.sign/verify` pass `:sha512` to `:crypto.sign(:eddsa, ...)`. OTP's handling of the digest parameter for eddsa has been ignored/inconsistent across versions; pure Ed25519 (RFC 8032) hashes internally. Sign/verify are symmetric in-tree so it works today, but it risks version-dependent prehash semantics and breaks interop assumptions with standard Ed25519 verifiers. Use `:none` and add a cross-version test vector (sign a fixed message, pin the expected signature).

### C10 — Registry trust model (Low)

`Registry.register/1` has no caller authorization — first-come registration. Self-certifying IDs prevent impersonating an existing key, but anyone who can reach the API can mint identities and squat names (`lookup_by_name` is explicitly non-unique; ensure nothing makes authz decisions by name). The persisted identity store (JSON backend) has no integrity protection — within the conceded T4/T6 threat, but a signed or HMAC'd identity file would be cheap defense-in-depth and is a natural Layer 3 signer purpose.

### C11 — Hygiene (Low)

- `Capability` carries both `signature` and `issuer_signature`; only the latter is used. Remove the dead field before someone trusts it.
- `DoubleRatchet.decrypt_with_key` pattern-match raises on ciphertext shorter than 28 bytes — return `{:error, :malformed}` instead of crashing the calling process.
- DoubleRatchet `to_map/1` exports private keys and chain keys; safety rests entirely on Keychain encryption (which rests on C6's master key). Acceptable, but the dependency chain should be documented in one place.

## Priorities

1. (P0, existing) D1–D4 from `arbor-security-design.md` — ingress auth and signer↔principal binding. The signature scheme is only as useful as this binding.
2. C1 — sign all capability fields; this is the cheapest high-value fix in this review.
3. C2 — fix or re-scope `seal`; verify inviter keys in channel invitations.
4. C4, C5 — token verify-before-parse; document/fix nonce cache scope.
5. C7 — collapse checkpoint-HMAC derivation to one path; keep it behind the identity facade for Layer 3.
6. C6, C8–C11 — hardening and hygiene batch.

Primitive choices need no changes. The roadmap in SECURITY_ARCHITECTURE.md (facade → service account → RPC → external signer → hardware) is the right shape; the findings above are mostly about making today's Layer 0 honest and keeping it swappable.
