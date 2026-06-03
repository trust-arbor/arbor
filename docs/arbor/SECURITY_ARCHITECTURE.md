# Arbor Security Architecture — Current State and Target

This document captures the layered security architecture Arbor is migrating toward, the threat model that motivates each layer, and a phased migration path. It's intended as both an internal direction-setting document and material for enterprise-customer conversations about security posture.

## Scope and audience

- **For internal engineering:** what we're building toward and why; what each piece of work unlocks
- **For enterprise prospects:** the security model Arbor is engineered around, including which threats are addressed at which layer
- **Not a specification:** implementation details are deferred to layer-specific design docs as work begins

The current operational reality (single-operator dev box) is one valid configuration of this architecture. Production deployments will be different configurations of the same model.

## Threat model

The threats Arbor's identity and execution architecture must address, in rough order of immediacy:

| ID | Threat | Realistic for |
|---|---|---|
| T1 | Other unix users on the host reading sensitive files | Multi-tenant systems, shared hosts |
| T2 | External attacker compromises the operator's shell / SSH key / dev tools | Any deployment |
| T3 | Operator clumsiness — accidentally `cat`ing a key into a log, pasting into chat, etc. | Any deployment |
| T4 | Compromised Arbor agent inside the BEAM reading key material or other secrets | Any deployment where agents handle untrusted input — i.e., all of them |
| T5 | Compromised agent invoking sensitive operations via granted capabilities | Same as T4 |
| T6 | Compromised daemon — the BEAM is fully owned by the attacker | Network-exposed deployments |
| T7 | Compromised CLI binary / tampered mix task / supply-chain attack | Any deployment |
| T8 | Cross-operator attack: one operator forges or replays another operator's signed artifacts | Multi-operator deployments |
| T9 | Insider attack: a trusted human exfiltrates keys or signed artifacts | Enterprise / regulated environments |

The architecture below is designed so that each layer addresses a distinct subset of these threats, and adopting layers incrementally produces a meaningful security improvement at each step.

## Current state (Layer 0)

What's in place today:

- **Single UID model.** The operator's UID runs the BEAM. Agents in the BEAM share that UID.
- **Identity key on filesystem.** `~/.arbor/identity.key`, mode `0600`. Loaded via `Arbor.Orchestrator.Mix.Helpers.load_identity/1`.
- **Key in BEAM memory.** Captured in the signer closure; passed as `:identity_private_key` in `Engine.run/2` opts. Anything in the BEAM can in principle read it.
- **CLI runs in-process.** `mix arbor.pipeline.run` spawns its own BEAM, separate from any other Arbor BEAM on the box. State is per-invocation.
- **Checkpoint HMAC bound to operator identity.** HKDF(operator_private_key, "arbor-checkpoint-hmac-v1") derives the secret; AAD includes run_id + current_node + graph_hash. Resume requires the same operator's identity.
- **Capability system enforces what agents can do.** `Arbor.Security` evaluates resource URI access against granted caps. URI matcher rejects `..` traversal at the cap layer.
- **FileGuard exists but wiring is partial.** Only invoked when callers pass `:file_path` opt to `Security.authorize/4`. Most production callers don't. Tracked as a defense-in-depth follow-up.
- **Shell sandbox** provides command allowlist / metacharacter check via `Arbor.Shell.Sandbox`.

Threats addressed at this layer:

- ✓ T1 (file perm 0600, though irrelevant on single-user host)
- ✓ T8 (HMAC binding rejects cross-operator forgery)
- ✗ T2, T3, T4, T6 — anything that compromises the operator's UID or the BEAM's process space defeats this layer

## Target architecture (Layers 1–4)

The full target is four independent trust boundaries, each adding meaningful defense against a distinct threat class:

```
┌───────────────────────────┐
│ Operator's shell          │  azmaveth UID
│ (mix arbor.* commands)    │
└────────────┬──────────────┘
             │ Layer 2: RPC + operator auth (mTLS / signed requests)
             ▼
┌───────────────────────────┐
│ Arbor daemon              │  arbor UID
│ - Pipeline engine         │  Layer 1: service-account isolation
│ - Capability evaluator    │
│ - Agents in BEAM          │
└────────────┬──────────────┘
             │ Layer 3: signing requests over UNIX socket
             ▼
┌───────────────────────────┐
│ Arbor signer              │  arbor-signer UID or same arbor UID
│ - Holds private key       │  Layer 4: hardware shim
│ - Exposes sign / derive   │
│ - Rate-limits, audits     │
└────────────┬──────────────┘
             │ Layer 4: hardware-backed key operations
             ▼
┌───────────────────────────┐
│ Secure Enclave / TPM /    │  Hardware
│ HSM                       │
└───────────────────────────┘
```

### Layer 1 — Dedicated `arbor` service account

The Arbor daemon runs under a dedicated `arbor` UID, in a dedicated `arbor` group. The operator's shell runs under their own UID. Filesystem access is scoped by ownership and group membership.

**What it addresses:**

- **T1** strengthened — `arbor` UID's files are unreadable by other users without `sudo`
- **T2** — external attacker who compromises the operator's shell sees their own UID, not `arbor`'s. The identity key, the daemon's working state, and the BEAM's process memory are all behind a UID boundary.
- **T3** — operator can't accidentally `cat ~/.arbor/identity.key` because their normal shell doesn't have read access to the daemon's files

**What it does NOT address:**

- **T4** — agents inside the BEAM still run under `arbor` UID; they retain whatever filesystem and process access the daemon has. Same problem, different UID.
- **T6** — compromised daemon owns everything under `arbor`

**Group scoping:**

The `arbor` group enables clean filesystem scoping. Resources agents may touch (workspace dirs, scratch space, shared logs) are group-owned `*:arbor` with appropriate read/write bits. The operator can join the `arbor` group selectively for read-only access to logs, but the key file remains user-only (`arbor:arbor` mode 0600). The shape lets you express policies like "agents can read workspace, can't read /etc, can't read the operator's home" purely via filesystem perms.

**Operational shape:**

- Daemon launched at boot via systemd (Linux) or launchd (macOS)
- Working directory: `/var/lib/arbor` or `/opt/arbor` (FHS-compliant on Linux)
- Logs: `/var/log/arbor/` (or daemon-managed via systemd-journald)
- Key file: `/var/lib/arbor/.arbor/identity.key`, owner `arbor:arbor`, mode `0600`
- Operator's CLI no longer spawns Arbor — it talks to the running daemon (see Layer 2)

### Layer 2 — CLI as authenticated RPC client

CLI commands (`mix arbor.pipeline.*`) become thin RPC clients to the running daemon. Operators authenticate to the daemon at each invocation; the daemon is the source of truth for all pipeline state.

**Authentication options (decision deferred to implementation):**

- **mTLS:** operator client certs, daemon presents a cert. Standard for production services.
- **Signed requests:** the operator's existing Ed25519 identity signs each RPC. The daemon verifies the signature against the operator's registered public key. Reuses existing crypto.
- **OIDC bridge:** for enterprise SSO integration. The daemon validates OIDC tokens issued by the customer's IdP and maps them to operator identities.

The right answer for Arbor is probably "signed requests for self-hosted operators + mTLS for service-to-service + OIDC for enterprise SSO." All three can be supported behind a common auth interface.

**What it addresses:**

- **T2** strengthened — compromised shell can attempt CLI calls, but without a valid operator credential the daemon refuses
- **T7** — tampered CLI binary can't bypass the auth boundary; the daemon enforces what the operator was actually authorized to do
- **T8** — multi-operator deployments get per-operator audit on every action

**What it does NOT address:**

- T4, T6 — once the daemon accepts an authenticated request, agents still execute inside the BEAM with whatever capabilities the request authorized

**Operational shape:**

- Daemon exposes pipeline operations via existing `arbor_gateway` HTTP endpoints (or a parallel UNIX socket for local-only deployments)
- Operator's CLI reads their identity key, signs each RPC, sends it
- The daemon's response includes the run_id; operators query / resume via the daemon, not by touching files directly

**Implications for checkpoint HMAC (recommended option):**

The Option D we shipped (operator-identity-bound HMAC) splits in service mode. Two identities now matter: the **operator** (CLI client) and the **daemon** (the BEAM doing the work). Three reasonable bindings:

| Binding | Tradeoff |
|---|---|
| Daemon-only | Simpler. Loses per-operator audit on the checkpoint. Resume by any authenticated operator is fine |
| Operator-only | Preserves the property we have today. But the operator key has to enter the daemon's process space → defeats half the point of service mode |
| **Both bound (recommended)** | Daemon authenticates operator via Layer 2, then derives the checkpoint HMAC as `HKDF(daemon_key, "checkpoint-" <> operator_id <> "-" <> run_id)`. Resume requires the same daemon AND the same operator. Strong audit story. Neither raw key ever enters the resumer's process space. Implementation lives in Layer 3 (the signer) — daemon asks the signer to derive a per-(operator, run) HMAC |

The "both bound" choice tells a clean enterprise story: every signed checkpoint identifies the operator who started it, the daemon that ran it, and (with Layer 4) the host it was produced on.

### Layer 3 — External signer process

A small dedicated process holds the private key and exposes only signing / key-derivation operations over a UNIX socket. The Arbor daemon's BEAM never has the raw key.

**What it addresses:**

- **T4** — even a compromised agent can only request signatures the signer is configured to allow, at the signer's rate limit. The agent can't exfiltrate the key because the key isn't in the BEAM.
- **T6** — compromised daemon owns everything under its UID, but the signer is a separate process under its own UID; the daemon can request signatures (auditable, rate-limitable) but can't extract the key

**Operational shape:**

- Signer process runs under `arbor-signer` UID (separate from `arbor`) or as `arbor` (less isolation but simpler)
- UNIX socket at `/var/run/arbor/signer.sock`, mode `0600`, owned `arbor:arbor` so only the daemon can connect
- Minimal protocol: `sign(payload, purpose)`, `derive_hmac(salt, purpose)`. Maybe `health_check`. Nothing else.
- Audit log: every signing request gets a structured event (timestamp, caller PID, purpose, payload hash). Forwarded to whatever audit infrastructure the operator configures
- Rate limiting: per-purpose budgets (e.g., "no more than 100 checkpoint signatures per minute per run_id") so a runaway pipeline can't ask the signer to sign forever
- Optional human-in-the-loop: certain signature purposes (e.g., signing a new capability grant) can require operator confirmation via a separate notification channel

**Signer protocol design notes (deferred to implementation):**

- Simple line-oriented or length-prefixed binary protocol over UNIX socket
- Could be a small Elixir app, but a Go or Rust binary has the advantage of being deployable independently of the BEAM (smaller footprint, separate update cadence)
- A pure-Erlang version using Erlang distribution between two nodes is possible but conflates the trust boundary with BEAM-internal communication
- The "right" answer probably depends on whether enterprise customers care about minimizing the trusted code base (in which case: small Rust binary)

**Backward compatibility with the current signer closure:**

The current `Arbor.Orchestrator.Engine` uses a `signer = fn resource -> ... end` closure threaded through opts. Layer 3 swaps this closure for one that delegates to the signer process. The interface stays the same; the implementation changes. All in-tree callers see no API change.

### Layer 4 — Hardware-backed signer

The signer process becomes a thin shim to hardware. The private key is generated in and never leaves a hardware security boundary.

**Platform options:**

- **Apple Secure Enclave** (macOS, M-series and T2 Macs): native API, key generation + signing without the key bytes ever entering the OS
- **TPM 2.0** (most Linux servers and many Windows workstations): standard PKCS#11 interface, well-supported toolchain
- **HSM** (enterprise): network-attached or PCIe-attached hardware security module; PKCS#11 or vendor-specific API
- **Cloud KMS** (cloud deployments): AWS KMS, GCP Cloud KMS, Azure Key Vault; signing operations remote to a cloud-provider HSM

**What it addresses:**

- **T6** fully — the daemon can request signatures but cannot extract the key under any compromise scenario
- **T9** — insider with root on the box can request signatures (auditable) but cannot copy the key off the device
- Attestation: hardware can produce a signed statement asserting "this key lives in hardware that meets X compliance bar." Enterprise compliance requirements (FIPS 140-2, Common Criteria) become satisfiable

**Operational shape:**

- For dev / single-operator self-hosted: macOS Secure Enclave or TPM is free and zero-config
- For enterprise: customer brings their own HSM (or cloud KMS), Arbor's signer process is configured to use it
- For air-gapped: dedicated HSM appliance, no network egress required from the signing path

The hardware layer is what makes Arbor a credible component of a FIPS / SOC 2 / HIPAA / FedRAMP story for enterprise customers. The signer process's interface to hardware is platform-specific; the daemon's interface to the signer is stable across all hardware choices.

## Migration path

The four layers can be adopted independently. Each is a meaningful security improvement; none requires the others to land first. A reasonable phased path:

### Phase 1 — Identity facade refactor (low effort, near-term)

Pull identity-loading and signing operations out of `Helpers.load_identity/1` and the ad-hoc signer closures into a proper `Arbor.Identity` facade. File-backed today, but with a clean interface (`resolve/1`, `sign/2`, `derive_secret/2`) that can be re-implemented to delegate to Layer 3 without API changes.

Zero security improvement on its own. Sets up the seam for everything that follows. Roughly an afternoon's work.

### Phase 2 — Service account documentation + tooling

Document how to set up the `arbor` UID, `arbor` group, directory layout, launchd/systemd unit. Provide reference configs. Update IDENTITY.md to cover service-mode deployment alongside dev-mode.

No code change in Arbor itself. But the operational tooling and docs are real work — installer scripts, sample unit files, group permission setup. Maybe a `mix arbor.deploy.init` task that scaffolds the layout.

Adds Layer 1 for operators willing to do the setup. Doesn't change the per-invocation CLI model yet.

### Phase 3 — CLI as RPC client

Migrate `mix arbor.pipeline.*` from in-process pipeline execution to RPC against a running daemon. Existing `arbor_gateway` already has HTTP endpoints; this phase mostly extends them and writes a thin CLI client.

This is the big phase — touches gateway, CLI, auth, possibly session/state management. Multiple commits over several days. The deliverable is "you can `mix arbor.pipeline.run foo.dot` and it executes on the running daemon under `arbor` UID rather than spinning up your own BEAM as `azmaveth`."

Adds Layer 2 (with Layer 1 already in place). The "both bound" checkpoint HMAC decision lands here.

### Phase 4 — External signer process

Build the signer binary (probably Rust or Go for footprint reasons, but pure-Elixir is also fine to start). Define the UNIX socket protocol. Update `Arbor.Identity` (from Phase 1) to delegate to the signer process. The signer holds the key; the daemon does not.

Adds Layer 3. Meaningful step toward the agent-in-BEAM threat (T4) that nothing else addresses.

### Phase 5 — Hardware backing

Integrate Secure Enclave for macOS dev installs and TPM/PKCS#11 for Linux production installs. The signer's interface to hardware is platform-specific; both implementations live behind the same API.

Adds Layer 4. Makes Arbor a credible component of compliance-regulated deployments.

## Trade-offs at each layer

For each layer, what it costs and what it can defer:

| Layer | Engineering cost | Operational cost | Can defer? |
|---|---|---|---|
| 1 (service account) | Low (mostly docs + scripts) | Moderate (operators learn new setup) | Yes — single-UID dev works fine |
| 2 (RPC CLI) | High (real refactor) | Low (daemon runs in background, CLI is the same UX) | Yes — single-operator dev can stay in-process |
| 3 (external signer) | Medium-high (new component) | Low (transparent to operators) | Yes — only matters once you care about T4 |
| 4 (hardware) | Medium (platform integration) | Varies (free for Mac/TPM, cost for HSM) | Yes — enterprise prereq, not single-user |

The architecture rewards staged adoption. Each layer's value is independently legible to the customer at that layer's tier.

## Open questions / future decisions

These are deliberately not pinned down here — each becomes its own design conversation at the relevant phase:

- **Daemon process model:** long-running OTP app vs spawned-per-run vs Erlang distribution cluster?
- **Operator authentication to daemon (Phase 3):** signed requests (reuse existing identity), mTLS, OIDC bridge — or all three behind a common interface?
- **Signer protocol (Phase 4):** custom binary protocol, gRPC, or Erlang-distribution between two cookied nodes?
- **Signer language (Phase 4):** Elixir / Erlang for simplicity, Go / Rust for smaller trusted codebase footprint?
- **Audit infrastructure:** structured log lines forwarded to OpenTelemetry, dedicated immutable store, or operator's existing SIEM?
- **Key rotation flow:** how does the daemon learn about a new operator key? Manual restart, signal, or watchable file?
- **Multi-tenancy:** if a single daemon serves multiple operators, where does the trust boundary live? Per-operator BEAM nodes? Per-operator capability namespacing within a shared BEAM?

These questions will be answered as the corresponding phases land. Capturing them here so they're not forgotten and so enterprise conversations have a clear picture of where the architecture has decided vs. where it has deliberately left flexibility.

## Related

- [`docs/arbor/IDENTITY.md`](./IDENTITY.md) — operator-facing guide to identity keys (Layer 0 setup)
- [`.arbor/roadmap/5-completed/security-checkpoints-unverified-by-default.md`](../../.arbor/roadmap/5-completed/security-checkpoints-unverified-by-default.md) — checkpoint HMAC fix (Layer 0 work)
- [`.arbor/roadmap/5-completed/security-uri-matcher-path-traversal-fail-open.md`](../../.arbor/roadmap/5-completed/security-uri-matcher-path-traversal-fail-open.md) — URI matcher hardening (Layer 0 work)
- [`apps/arbor_security/lib/arbor/security/crypto.ex`](../../apps/arbor_security/lib/arbor/security/crypto.ex) — HKDF implementation (used by Layer 0+ checkpoint HMAC; will be wrapped by Layer 3 signer)
- [`apps/arbor_gateway/`](../../apps/arbor_gateway/) — existing gateway with HTTP endpoints; substrate for Phase 3
