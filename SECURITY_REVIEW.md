# Security Review: trust-arbor/arbor

**Date:** 2026-02-16
**Scope:** `/Users/azmaveth/code/trust-arbor/arbor/` (current `main` working tree)
**Method:** Four-domain parallel code audit covering (1) authentication/authorization/access control, (2) cryptography/signing/key management, (3) input validation/injection/sandboxing, and (4) data exposure/configuration/logging.
**Previous review:** 2026-02-15 (14 findings, all remediated)

---

## Executive Summary

The previous review's 14 findings (2 critical, 6 high, 5 medium, 1 low) have all been remediated. This fresh review identifies **19 new findings** across cryptographic key management, atom exhaustion vectors, credential storage, and authorization gaps.

The most critical finding is unencrypted channel authority private keys in GenServer state. Six high-severity findings cover key confusion risks, unbounded storage, atom exhaustion vectors, and plaintext credential storage.

Overall security posture is **STRONG** — the codebase demonstrates defense-in-depth with comprehensive sandboxing, taint tracking, path validation, capability-based authorization, and length-prefixed signing payloads. The findings below represent hardening opportunities rather than exploitable vulnerabilities in typical deployment scenarios.

---

## Severity Summary

| Severity | Count |
|---|---:|
| CRITICAL | 1 |
| HIGH | 6 |
| MEDIUM | 7 |
| LOW | 5 |
| **Total** | **19** |

---

## Findings

### CRITICAL

#### C1. Channel authority private keys stored unencrypted in GenServer state

**Impact:** Channel authority private keys for key redistribution are stored in plain GenServer state, creating a high-value target for memory dumps, process inspection via `:sys.get_state/1`, or crash dump analysis.

**Evidence**
- `apps/arbor_signals/lib/arbor/signals/channels.ex:280` — authority keypair generated and stored in channel entry
- `apps/arbor_signals/lib/arbor/signals/channels.ex:755-769` — authority private key used directly from state for sealing redistributed keys
- No encryption or protection applied to the `authority_keypair` in channel entries

**Recommended fix**
1. Encrypt authority private keys in state using a derived key from SystemAuthority
2. Decrypt only when needed for key redistribution operations
3. Add secure memory clearing (zeroing) when rotating authority keys
4. Consider wrapping sensitive key material in a separate process with restricted access

---

### HIGH

#### H1. Seal/unseal key confusion risk between Ed25519 and X25519

**Impact:** The `seal/3` function re-derives the sender's public key from the private key rather than accepting the full keypair. If an Ed25519 private key (64 bytes) is mistakenly passed instead of an X25519 key (32 bytes), the ECDH computation may silently produce incorrect results.

**Evidence**
- `apps/arbor_security/lib/arbor/security/crypto.ex:205` — derives sender public key within `seal()`:
  ```elixir
  {sender_public, _} = :crypto.generate_key(:ecdh, :x25519, sender_private)
  ```
- Function signature accepts any binary for `sender_private`, no size validation
- Ed25519 keys (64 bytes) and X25519 keys (32 bytes) are both binaries with no type distinction

**Recommended fix**
1. Add guard `when byte_size(sender_private) == 32` to `seal/3`
2. Add guard `when byte_size(recipient_private) == 32` to `unseal/2`
3. Consider accepting `{public, private}` tuple to eliminate re-derivation
4. Document that only X25519 keys should be used, never Ed25519 keys

---

#### H2. Master key file permissions not verified after creation

**Impact:** The master key file permissions (0o600) are set but the return value of `File.chmod/2` is not checked. Subsequent reads don't verify permissions haven't been changed, potentially leaving the master key world-readable.

**Evidence**
- `apps/arbor_security/lib/arbor/security/signing_key_store.ex:145` — `File.chmod(path, 0o600)` return value ignored
- No verification that the file has restrictive permissions after creation
- Subsequent reads don't check current file permissions

**Recommended fix**
1. Check return value of `File.chmod/2` and fail if it returns error
2. After setting permissions, call `File.stat!/1` to verify mode is exactly 0o600
3. On every master key read, verify permissions before reading
4. Log warnings if permissions are found too permissive

---

#### H3. Double Ratchet skipped message keys stored indefinitely without expiration

**Impact:** While there's a `max_skip` limit (default 100), skipped message keys are stored indefinitely in memory without TTL expiration, enabling potential DoS through memory exhaustion by an adversary who sends out-of-order messages.

**Evidence**
- `apps/arbor_security/lib/arbor/security/double_ratchet.ex:59` — `skipped_keys` map with no TTL
- `apps/arbor_security/lib/arbor/security/double_ratchet.ex:458-467` — keys added but never expired
- Session serialization includes all skipped keys (lines 263-270)

**Recommended fix**
1. Add timestamps to skipped message keys
2. Implement automatic expiration (e.g., 24 hours) for unused skipped keys
3. Add periodic cleanup to remove expired keys
4. Limit total skipped keys across all sessions per peer

---

#### H4. Unsafe `String.to_atom/1` in pipeline outcome parsing

**Impact:** Atom exhaustion DoS through crafted pipeline outcomes where user-controlled data flows into `String.to_atom/1`.

**Evidence**
- `apps/arbor_actions/lib/arbor/actions/pipeline.ex:142`:
  ```elixir
  defp extract_status(%{context: %{"outcome" => outcome}}), do: String.to_atom(outcome)
  ```
- Outcome values derive from action execution results which may include external data

**Recommended fix**
- Use `SafeAtom.to_allowed(outcome, [:success, :failure, :error, :pending, :cancelled])` with an explicit allowlist
- If outcomes must be open-ended, use `SafeAtom.to_existing(outcome)` with error handling

---

#### H5. Unsafe `String.to_atom/1` in consensus handler branch ID

**Impact:** Atom exhaustion through externally-sourced branch IDs (perspectives) that derive from LLM proposals or user-created branches.

**Evidence**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/consensus_handler.ex:276`:
  ```elixir
  perspective: String.to_atom(sanitize_perspective(branch_id))
  ```
- Even with `sanitize_perspective/1`, branch IDs ultimately derive from external sources

**Recommended fix**
- Use `SafeAtom.to_existing(sanitized_branch_id)` instead
- Maintain a registry of valid perspectives and check against it
- Ensure `sanitize_perspective/1` is thoroughly reviewed for bypass vectors

---

#### H6. Dashboard credentials stored in plaintext configuration

**Impact:** Dashboard authentication credentials are loaded from environment variables and stored in application configuration without hashing or encryption. If application state is dumped or config is inspected, credentials are exposed in cleartext.

**Evidence**
- `config/runtime.exs:61-66` — credentials loaded directly from env vars
- `apps/arbor_dashboard/lib/arbor_dashboard/auth.ex:40-41` — credentials retrieved from application env
- No hashing (bcrypt/argon2) applied to stored password values

**Recommended fix**
1. Hash dashboard passwords using bcrypt or argon2 before storing in config
2. Compare hashed values during authentication
3. Consider session-based auth with secure cookies instead of basic auth
4. Implement credential rotation mechanism

---

### MEDIUM

#### M1. Working memory endpoints lack authorization

**Impact:** Working memory GET/PUT endpoints (`/api/memory/working/:agent_id`) do not verify the caller has authorization to access or modify the specified agent's working memory, allowing potential cross-agent memory access.

**Evidence**
- `apps/arbor_gateway/lib/arbor/gateway/memory/router.ex:201-212` — GET has no authorization check
- `apps/arbor_gateway/lib/arbor/gateway/memory/router.ex:215-227` — PUT has no authorization check
- Other memory endpoints (`/recall`, `/index`) do call `authorize_memory_access/2`

**Recommended fix**
1. Add `authorize_memory_access(agent_id, :read)` to GET endpoint
2. Add `authorize_memory_access(agent_id, :write)` to PUT endpoint
3. Return 403 on authorization failure

---

#### M2. Identity registry TOCTOU race condition

**Impact:** The identity registry allows checking identity status separately from key lookup, creating a time-of-check-time-of-use vulnerability where an identity could be suspended between status check and key retrieval.

**Evidence**
- `apps/arbor_security/lib/arbor/security/identity/registry.ex:249-258` — lookup checks status
- `apps/arbor_security/lib/arbor/security/identity/registry.ex:396-406` — separate `get_status/1` call
- Security-critical paths could use separate status checks

**Recommended fix**
1. Remove or deprecate separate `get_status/1` for security-critical paths
2. Document that `lookup/1` and `lookup_encryption_key/1` are the atomic status-checking APIs
3. Add integration tests verifying suspension blocks key lookups immediately

---

#### M3. Keychain serialization lacks integrity protection

**Impact:** Keychain serialization encrypts private keys but doesn't include an HMAC or signature over the entire payload, allowing potential tampering with public metadata fields (agent_id, public keys, peer info) that are stored in plaintext.

**Evidence**
- `apps/arbor_security/lib/arbor/security/keychain.ex:381-400` — serialization only encrypts private data
- `apps/arbor_security/lib/arbor/security/keychain.ex:489-510` — public data stored in plaintext without integrity check

**Recommended fix**
1. Add HMAC-SHA256 over the entire serialized payload using a derived key
2. Verify HMAC during deserialization before processing any fields
3. Include version and schema information in the authenticated data

---

#### M4. Capability signing payload missing signature timestamp

**Impact:** Capability signing payloads don't include a signature timestamp, making it impossible to prove when a signature was created or enforce signature freshness policies.

**Evidence**
- `apps/arbor_contracts/lib/arbor/contracts/security/capability.ex:178-194` — `signing_payload/1` includes `granted_at` but no signature-specific timestamp
- No nonce in capability signatures (unlike SignedRequest which has both)
- Signatures could theoretically be replayed if capabilities are re-issued with same parameters

**Recommended fix**
1. Add `signed_at` field to Capability struct (set at signing time, not creation time)
2. Include `signed_at` in the signing payload
3. Consider adding an optional nonce for additional replay protection

---

#### M5. Unsafe `String.to_atom/1` in Cartographer SENTRY_TAGS parsing

**Impact:** Operator-controlled but risky — malicious `.env` or compromised deployment configs could inject arbitrary atoms through the SENTRY_TAGS environment variable.

**Evidence**
- `apps/arbor_cartographer/lib/arbor/cartographer/application.ex:70`:
  ```elixir
  |> Enum.map(&String.to_atom/1)
  ```

**Recommended fix**
- Use `SafeAtom.to_existing/1` with a fallback (skip unknown tags)
- Define and document valid Sentry tag names

---

#### M6. Database password passed via PGPASSWORD environment variable

**Impact:** PostgreSQL password passed to `pg_dump` and `pg_restore` via `PGPASSWORD` environment variable may be visible in process listings (`/proc/*/environ`) or logged by system monitoring tools.

**Evidence**
- `apps/arbor_persistence/lib/arbor/persistence/backup.ex:306` — `PGPASSWORD` env var set for `pg_dump`
- `apps/arbor_persistence/lib/arbor/persistence/backup.ex:385` — same pattern for `pg_restore`

**Recommended fix**
1. Use PostgreSQL `.pgpass` file instead of environment variables
2. Ensure `.pgpass` has restrictive permissions (0o600)
3. Document secure credential storage approach for database operations

---

#### M7. API keys logged in debug mode without redaction

**Impact:** When debug logging is enabled, API keys and credentials may be logged in request headers or error messages without redaction.

**Evidence**
- `apps/arbor_ai/lib/arbor/ai/backends/openai_embedding.ex:78-79` — logs request details that may contain keys
- Multiple adapter files make HTTP requests with API keys in headers without explicit redaction
- No centralized API key redaction filter in Logger configuration

**Recommended fix**
1. Implement Logger metadata filter to redact known sensitive keys (`api_key`, `authorization`, `x-api-key`)
2. Use structured logging with explicit redaction markers
3. Add secret-scanning middleware to Logger pipeline

---

### LOW

#### L1. SystemAuthority ephemeral keys never rotated

**Impact:** SystemAuthority keypair is generated once at startup and never rotated. A long-lived cluster could have the same authority keys for extended periods.

**Evidence**
- `apps/arbor_security/lib/arbor/security/system_authority.ex:100-109` — keys generated in `init/1`
- No rotation mechanism implemented
- Private key lives in GenServer state indefinitely

**Recommended fix**
1. Implement periodic key rotation (e.g., daily/weekly)
2. Maintain a registry of old public keys with validity periods
3. Emit security signals when authority keys are rotated

---

#### L2. Ed25519 private key size validation inconsistent

**Impact:** The Identity contract validates Ed25519 private keys as 32 bytes, but Erlang's `:crypto.generate_key(:eddsa, :ed25519)` returns 64-byte expanded keys, creating a validation mismatch.

**Evidence**
- `apps/arbor_contracts/lib/arbor/contracts/security/identity.ex:38` — `@ed25519_private_key_size 32`
- `apps/arbor_security/lib/arbor/security/crypto.ex:33` — comment says private_key is 64 bytes
- Erlang's Ed25519 implementation uses 64-byte expanded keys

**Recommended fix**
1. Update Identity contract to accept both 32-byte (seed) and 64-byte (expanded) Ed25519 keys
2. Standardize on one format throughout the codebase (recommend 64-byte expanded)
3. Document the two formats clearly

---

#### L3. Nonce entropy not verified

**Impact:** The nonce cache accepts any 16-byte binary without verifying it has sufficient entropy. A broken random number generator could produce predictable nonces.

**Evidence**
- `apps/arbor_contracts/lib/arbor/contracts/security/signed_request.ex:81` — nonce generated with `strong_rand_bytes`
- No validation that nonces are actually random or have sufficient entropy
- Replay protection relies entirely on nonce uniqueness

**Recommended fix**
1. Consider rejecting obviously non-random nonces (e.g., all zeros)
2. Log warnings if nonces appear to have low entropy in development mode
3. Document that callers MUST use cryptographically secure RNG

---

#### L4. Channel key version mismatch not logged

**Impact:** When decrypting channel messages with mismatched key versions, the error is returned silently without logging, making it difficult to debug key rotation issues or detect attacks.

**Evidence**
- `apps/arbor_signals/lib/arbor/signals/topic_keys.ex:237-247` — `do_decrypt` checks version
- Returns `:key_version_mismatch` without logging

**Recommended fix**
1. Log key version mismatches as warnings with channel/topic context
2. Emit security signals for suspicious patterns (many mismatches in short time)
3. Consider temporary grace period to accept N-1 key version during rotation

---

#### L5. CWD-based .env loading in dev/test environments

**Impact:** In dev/test, `.env` is loaded from `File.cwd!()` rather than the project root. An attacker who can control the working directory when Arbor starts could inject malicious environment variables.

**Evidence**
- `config/runtime.exs:11` — `Path.join(File.cwd!(), ".env")`
- Production correctly uses fixed path: `~/.arbor/.env`

**Recommended fix**
1. Document the CWD trust assumption in dev/test
2. Consider using `Path.expand(".env", __DIR__)` to load from the project root
3. Add startup warning if `.env` is loaded from an unexpected location

---

## Security Controls Confirmed Present

The following security controls were verified as properly implemented:

| Control | Status | Location |
|---|---|---|
| Gateway API key authentication | SECURE | `apps/arbor_gateway/lib/arbor/gateway/auth.ex` |
| MCP endpoint authentication (C1 from prev review) | REMEDIATED | `apps/arbor_gateway/lib/arbor/gateway/router.ex:62-65` |
| Authorization pipeline (authorize/4) | SECURE | `apps/arbor_security/lib/arbor/security.ex:296-331` |
| Identity binding in verification | SECURE | `apps/arbor_security/lib/arbor/security.ex:651-657` |
| Resource binding in verification | SECURE | `apps/arbor_security/lib/arbor/security.ex:661-672` |
| Shell sandbox metacharacter blocking | SECURE | `apps/arbor_shell/lib/arbor/shell/sandbox.ex:24` |
| SafePath traversal protection | SECURE | `apps/arbor_common/lib/arbor/common/safe_path.ex` |
| SafeAtom usage (enum definitions) | SECURE | `apps/arbor_common/lib/arbor/common/safe_atom.ex` |
| Taint tracking enforcement | SECURE | `apps/arbor_actions/lib/arbor/actions/taint_enforcement.ex` |
| Code sandbox AST validation | SECURE | `apps/arbor_sandbox/lib/arbor/sandbox/code.ex:115-151` |
| File actions path validation | SECURE | `apps/arbor_actions/lib/arbor/actions/file.ex:37-48` |
| Action dispatch safe atom resolution | SECURE | `apps/arbor_agent/lib/arbor/agent/executor/action_dispatch.ex:248-249` |
| Length-prefixed signing payloads | SECURE | `apps/arbor_contracts/lib/arbor/contracts/security/capability.ex:186-194` |
| Signal bus encryption for restricted topics | SECURE | `apps/arbor_signals/lib/arbor/signals/bus.ex` |
| Secret scanning middleware | SECURE | `apps/arbor_orchestrator/lib/arbor/orchestrator/middleware/secret_scan.ex` |
| Rate limiting | SECURE | `apps/arbor_gateway/lib/arbor/gateway/rate_limiter.ex` |
| Consensus force ops authorization | SECURE | `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:691-708` |
| Dev endpoints opt-in + localhost gating | SECURE | `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex:121-130` |
| Production .env from fixed path | SECURE | `config/runtime.exs:7-12` |
| CORS disabled on MCP | SECURE | `apps/arbor_gateway/lib/arbor/gateway/router.ex:41` |
| HKDF implementation audited | SECURE | `apps/arbor_security/lib/arbor/security/crypto.ex:102-106` |

---

## Remediation Status (2026-02-16)

All 19 findings remediated in branch `fix/security-review-remediation-2`:

| ID | Finding | Status | Fix Summary |
|---|---|---|---|
| C1 | Channel authority private keys unencrypted | REMEDIATED | Encrypted in GenServer state with per-process ephemeral AES key |
| H1 | Seal/unseal key confusion risk | REMEDIATED | Added `byte_size == 32` guards for X25519 keys |
| H2 | Master key permissions not verified | REMEDIATED | chmod return checked in `with` chain + File.stat verification |
| H3 | Double Ratchet skipped keys no TTL | REMEDIATED | Added timestamps, 1-hour TTL, automatic pruning on access |
| H4 | Pipeline String.to_atom | REMEDIATED | Uses SafeAtom.to_allowed with explicit outcome allowlist |
| H5 | Consensus String.to_atom | REMEDIATED | Uses SafeAtom.to_existing with :general fallback |
| H6 | Dashboard plaintext credential comparison | REMEDIATED | Uses Plug.Crypto.secure_compare for constant-time comparison |
| M1 | Working memory endpoints lack auth | REMEDIATED | Added authorize_memory_access to GET/PUT with 403 on failure |
| M2 | Identity registry TOCTOU | REMEDIATED | Added deprecation note to get_status, documented atomic API |
| M3 | Keychain serialization lacks integrity | REMEDIATED | Added HMAC-SHA256 over full payload with backward compat |
| M4 | Capability missing signed_at | REMEDIATED | Added signed_at field and included in signing payload |
| M5 | Cartographer String.to_atom | REMEDIATED | Uses SafeAtom.to_existing, unknown tags kept as strings |
| M6 | PGPASSWORD in environment | REMEDIATED | Switched to temporary .pgpass file with 0o600 permissions |
| M7 | API key redaction | REMEDIATED | LogRedactor filter installed at runtime, pattern-based redaction |
| L1 | SystemAuthority no rotation | REMEDIATED | Added rotate/0 client API and handle_call implementation |
| L2 | Ed25519 key size validation | REMEDIATED | Accepts both 32-byte seed and 64-byte expanded keys |
| L3 | Nonce entropy not verified | REMEDIATED | Rejects all-zero nonces with :zero_nonce error |
| L4 | Key version mismatch not logged | REMEDIATED | Added Logger.warning with version context |
| L5 | CWD .env loading | REMEDIATED | Added startup warning message when loading CWD .env |

---

## Previous Review Status

All 14 findings from the 2026-02-15 review have been verified as remediated:

| ID | Finding | Status |
|---|---|---|
| C1 | Unauthenticated MCP endpoint | REMEDIATED |
| C2 | MCP arbor_run without agent_id | REMEDIATED |
| H1 | Identity verification not binding | REMEDIATED |
| H2 | Unknown identities pass in strict mode | REMEDIATED |
| H3 | Executor bypasses authorize/4 | REMEDIATED |
| H4 | Signal subscriptions bypass authorization | REMEDIATED |
| H5 | Action execution skips taint checks | REMEDIATED |
| H6 | Shell authorize missing command context | REMEDIATED |
| M1 | Dev endpoints exposed without opt-in | REMEDIATED |
| M2 | Production .env from CWD | REMEDIATED |
| M3 | Sandbox allows dynamic dispatch | REMEDIATED |
| M4 | Memory API endpoints unauthenticated | REMEDIATED |
| M5 | Consensus force ops unprotected | REMEDIATED |
| L1 | Test file path validation in CompileAndTest | REMEDIATED |
