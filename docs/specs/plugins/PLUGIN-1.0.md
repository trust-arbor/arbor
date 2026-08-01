# PLUGIN-1.0 — Plugin Infrastructure / Unified Artifact Channel Specification

**Status:** Draft (2026-07-13)
**Scope:** the signed-artifact channel (contracts, signing, Engine verification,
revocation), the artifact registry and lifecycle (`apps/arbor_artifacts`), plugin
bundles (actions, DOT pipelines, signal hooks, UI views), dashboard runtime
dispatch, distribution, generative-path guards, and node isolation.
**Plan:** `.arbor/roadmap/2-planned/plugin-infrastructure.md` (design rationale) ·
`.arbor/decisions/2026-07-13-unified-artifact-channel.md` (channel decision) ·
`.arbor/decisions/2026-07-04-dot-signing-and-adapt-node-policy.md` (security posture).
**Conformance:** every statement below is proven by tests tagged `@tag spec: "<ID>"`.
Run `mix arbor.spec.coverage` for the current proof map. Statements marked `(planned)`
describe committed direction not yet implemented; they are excluded from `--strict`.
Work packets in `docs/specs/plugins/packets/` implement these statements and say
which `(planned)` markers they remove.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as described in
RFC 2119.

## Architecture summary (non-normative)

One channel, four stages: **manifest → review → sign → register/activate.** An
*artifact* is a versioned, signed unit: a declarative manifest plus payload files
(pre-built Elixir modules, `.dot` graphs, assets). Kinds at 1.0: `:plugin`,
`:template`; `:skill` is reserved (migration later). Plugins are artifacts whose
activation registers namespaced entries into the *existing* runtime registries
(`Arbor.Common.ActionRegistry`/`HandlerRegistry` post-`lock_core`, orchestrator
`Handlers.Registry`, `TemplateRegistry` overlay), grants declared capabilities,
starts supervised signal hooks, and contributes UI nav/views served by a runtime
dispatch LiveView. Authenticity (signing, verification, revocation) lives in
`arbor_security` (L2); lifecycle (catalog, activation) lives in a new
`arbor_artifacts` app (L8); the dashboard (L9) reads the registry. The Engine
(L7) consults only `Arbor.Security` — never the registry — so verification is
fail-closed without upward deps. Generative installs (agent-generated code) are
post-1.0 and gated by an AST static gate plus mandatory node isolation.

## Artifact model

- **PLUGIN-1** (MUST): Every artifact MUST be described by an
  `Arbor.Contracts.Artifact.Manifest` declaring at minimum: `kind`, `name`,
  `version`, `author` (principal id), `requires_capabilities`,
  `provides_capabilities`, payload file list with SHA-256 digests, and (for
  plugins) the registration sections it needs (`actions`, `handlers`, `templates`,
  `signal_hooks`, `ui`).

- **PLUGIN-2** (MUST): Manifest canonical encoding MUST be deterministic —
  byte-identical for equal content (sorted keys, fixed number/string forms) —
  following the `Arbor.Security.Capability.Signer.canonical_payload/1` pattern.
  All signatures over an artifact are computed over this canonical encoding.

- **PLUGIN-3** (MUST): Artifact names MUST be dot-namespaced identifiers usable as
  the plugin prefix for post-lock registry entries (RegistryBase requires `"."` in
  plugin-registered names). Everything an artifact registers MUST live under its
  own name prefix (e.g. artifact `browser` registers `browser.*` only).

- **PLUGIN-4** (MUST): Plugins, DOT templates, and (when migrated) skills MUST use
  this same manifest, signing, admission, and registry path. New artifact kinds
  MUST NOT introduce parallel signing or registration channels.

- **PLUGIN-5** (MUST): An artifact version is immutable: any payload or manifest
  change MUST produce a new `version` and a new signature. Digest mismatch against
  the signed manifest is tampering (see PLUGIN-12).

- **PLUGIN-6** (MUST): Every artifact MUST carry provenance: author principal,
  signing authority used, and (when produced by a pipeline) the producing run id.

## Signing (arbor_security)

- **PLUGIN-7** (MUST): Artifact signing MUST use Ed25519 via the `Arbor.Security`
  facade backed by `SigningKeyStore` and the signing-authority broker. Raw private
  keys MUST NOT leave `arbor_security`. Signing/authority references MUST be
  opaque `Arbor.Contracts.Security.SigningAuthority` values and MUST NOT be
  serialized into Engine context or checkpoints.

- **PLUGIN-8** (MUST): A `.dot` payload's signed bytes MUST be the canonical
  `Arbor.Orchestrator.Viz.DotSerializer.serialize/2` output with
  `strip_internal: true` — signing and verification MUST serialize with identical
  options.

- **PLUGIN-9** (MUST): Signatures MUST be detached (a sidecar signature envelope
  listing signer, key id, algorithm, signed digest, timestamp), leaving payload
  bytes untouched.

- **PLUGIN-10** (MUST): A revocation record for an artifact (name+version or
  key id) MUST cause verification to fail from the moment it is persisted.
  Revocation state MUST be consultable through `Arbor.Security` alone.

## Verification (Engine, fail-closed)

- **PLUGIN-11** (MUST): The Engine MUST verify artifact signatures in the
  run-authorization path before the first node of any graph whose source is
  stdlib or the shared library executes. Verification failure MUST refuse the run
  (fail-closed) — there is no warn-and-continue mode for stdlib/shared graphs.

- **PLUGIN-12** (MUST): Tampered (digest mismatch) or revoked artifacts MUST be
  refused at verification, and a security signal MUST be emitted identifying the
  artifact, reason, and caller.

- **PLUGIN-13** (MUST): Unsigned agent-authored DOT MUST execute only under the
  requesting caller's own authority and taint, never with stdlib/shared authority.
  A graph claiming stdlib/shared origin without a verifiable signature MUST be
  refused.

- **PLUGIN-14** (MUST): Verification MUST be TOCTOU-safe: the digest verified MUST
  be computed from the same bytes that are compiled/executed (content-addressed
  handoff from verify to execute).

- **PLUGIN-15** (MUST): LLM-compiled or sanitizer-auto-modified graphs MUST be
  unsignable for shared/stdlib authority until a review gate approves them
  (per the 2026-07-04 adapt-node decision).

## Registry and lifecycle (arbor_artifacts)

- **PLUGIN-16** (MUST): The artifact registry MUST track each installed artifact
  with manifest, signature envelope, status
  (`:installed | :active | :inactive | :failed | :revoked`), receipt, and
  timestamps, persisted durably (ETS front + `Arbor.Persistence.BufferedStore`
  pattern) so state survives restart.

- **PLUGIN-17** (MUST): Status transitions MUST emit signals
  (`artifact.installed`, `artifact.activated`, `artifact.deactivated`,
  `artifact.failed`, `artifact.revoked`) carrying artifact name, version, and actor.

- **PLUGIN-18** (MUST): Lower-hierarchy libraries (orchestrator and below) MUST
  NOT depend on the artifact registry. Anything the Engine needs at run time
  (signature status, revocation) MUST be answerable by `Arbor.Security`.

## Activation

- **PLUGIN-19** (MUST): Activation MUST register only entries prefixed by the
  artifact name into the runtime registries (post-`lock_core` plugin namespace),
  and MUST record every registration in the receipt. Core entries MUST NOT be
  overwritten.

- **PLUGIN-20** (MUST): Deactivation MUST reverse every effect recorded in the
  receipt — deregister actions/handlers, remove template overlays, revoke
  activation-time capability grants, terminate signal hooks, and remove UI
  contributions — leaving no live references to the artifact.

- **PLUGIN-21** (MUST): Artifact signal subscriptions MUST be owned by supervised
  processes under a per-artifact supervisor that unsubscribe on terminate;
  deactivation MUST terminate the artifact's supervision subtree. Bare
  `Arbor.Signals.subscribe/2` handler closures without an owning process are not
  permitted for artifacts.

- **PLUGIN-22** (MUST): Capabilities declared in `requires_capabilities` MUST be
  granted at activation and revoked at deactivation; `provides_capabilities` MUST
  be published as capability descriptors only while the artifact is active.
  Artifact code MUST NOT receive grants beyond its declared requirements.

- **PLUGIN-23** (MUST): Activation MUST be idempotent and crash-safe: re-running
  activation for an already-active artifact MUST NOT duplicate registrations,
  grants, or supervisors; a failed activation MUST roll back its partial effects
  (or mark `:failed` with a receipt sufficient to clean up).

## Install / uninstall

- **PLUGIN-24** (MUST): Install and uninstall MUST run as stdlib DOT pipelines
  (`install-artifact.dot`, `uninstall-artifact.dot`): verify → (admission when
  shared) → stage → activate → receipt. Install MUST refuse before any side
  effect when verification fails.

- **PLUGIN-25** (MUST): The receipt MUST record every side effect of install and
  activation — files written, registry entries, capability grants, signal hooks,
  UI contributions — and uninstall MUST reverse using the receipt. Uninstall
  without a receipt MUST refuse unless forced by operator authority, and a forced
  uninstall MUST be signalled as such.

- **PLUGIN-26** (MUST): During install, file writes MUST be confined to the
  artifact's own bundle directory; an install pipeline attempting to write
  outside it MUST be refused. Artifact bundles MUST NOT contain path-traversal
  entries.

## Dependencies

- **PLUGIN-27** (MUST): Artifact dependencies MUST be declared as capabilities
  (`requires_capabilities`), not artifact names. Resolution binds a requirement to
  whichever active artifact (or core) provides the capability.

- **PLUGIN-28** (MUST): Deactivating or uninstalling a provider whose capabilities
  have active dependents MUST follow policy: block by default; proceed only with
  explicit force, emitting a signal naming the dependents.

## Admission (council review)

- **PLUGIN-29** (MUST): Admission to the shared library or stdlib MUST require a
  recorded council decision (via `Arbor.Consensus`) before the artifact is signed
  with shared/stdlib authority; the decision id MUST be recorded in the receipt
  and registry entry.

- **PLUGIN-30** (SHOULD): Pre-generation review SHOULD happen at the `.dot` level
  (prompts, write targets, commands, capability claims) — it is a screening gate,
  not a guarantee, and MUST NOT weaken PLUGIN-11…15 or PLUGIN-33…35.

## UI

- **PLUGIN-31** (MUST): Plugin views MUST be served through a runtime dispatch
  LiveView (catch-all route consulting the registry per navigation), never by
  compile-time router edits. Requests for inactive/unknown artifacts MUST render
  not-found without crashing the socket.

- **PLUGIN-32** (MUST): Nav items contributed by an artifact MUST appear only
  while it is `:active` and MUST disappear on deactivation without dashboard
  restart.

## Distribution (default: deterministic pre-built)

- **PLUGIN-33** (MUST): The default install path MUST be deterministic pre-built
  payloads. Import of an external bundle MUST verify digests, signature, and
  revocation before any registry or filesystem effect. `(planned)`

- **PLUGIN-34** (MUST): Community/marketplace artifacts MUST NOT execute
  in-process by default: they run isolated (hidden BEAM node or MCP/Gateway
  client). A full-mesh distribution member is NOT isolation. In-process execution
  is reserved for first-party artifacts that passed council review. `(planned)`

## Generative path (post-1.0, flag-gated)

- **PLUGIN-35** (MUST): Generated Elixir source MUST pass an AST static gate
  (`Code.string_to_quoted` + deny-walk: security internals, `System`/`:os`/
  `Code`/`Port`, dynamic atom creation, side-effecting module attributes such as
  `@on_load`/`@before_compile`) BEFORE any compile — Elixir macros execute at
  compile time, so compilation is execution. `(planned)`

- **PLUGIN-36** (MUST): Generative installs MUST compile and test on an isolated
  node from day one and MUST refuse when isolation is unavailable
  (`:artifact_isolation` set to `:none`). `(planned)`

- **PLUGIN-37** (MUST): Emergent crystallization MUST follow
  generate → validate → invoke: agents author new artifacts that pass the full
  verify/review/sign pipeline; in-place structural mutation of running graphs is
  prohibited (2026-07-04 adapt-node decision). `(planned)`

## Library / marketplace (Stage 2)

- **PLUGIN-38** (SHOULD): Artifact discovery SHOULD be semantic (embedding index
  over manifests + descriptions), reusing the existing retrieval machinery rather
  than a bespoke search stack. `(planned)`

- **PLUGIN-39** (MUST): Publishing to the shared library MUST run the admission
  gate (PLUGIN-29); unsigned community artifacts MUST NOT be distributable.
  `(planned)`
