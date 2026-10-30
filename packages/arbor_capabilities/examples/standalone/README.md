# Standalone authority consumer

This fixture consumes the actual `arbor_capabilities` archive plus the public
Kernel, Custody, Support and OAuth artifacts. It contains no Kernel Runtime,
Common host facade, Signals, Trust, or optional OIDC protocol implementation.
The historical `Arbor.Security` public module names belong to the new
`:arbor_capabilities` application.

The consumer deliberately chooses the existing first-install **local-human
mode**, with `allow_local_human_identity: true` and no OIDC configuration. This
is not a claim about the default OIDC production enrollment policy. Identity
verification, signed capabilities, delegation verification, URI enforcement
and durable invocation auditing remain enabled. Every effect-admission probe runs through the public invocation wrapper and checks that its real attempt, authorization and outcome rows were durably appended. A real consumer-supervised
provisioner is admitted through an exact application/path/name descriptor in
`:scheduler_owner`; only its listed `:session` purpose is admitted. The two other required identity-registration descriptors name dormant consumer-owned children with empty signing-purpose lists; neither starts or supplies an authority fallback. It never
uses test helpers, raw signing-key reads, unsigned grants, or verification-off
options. Private absolute authority/master-key paths and an independently
located revocation ledger come from the qualifier's fresh state directory.

The public write phase generates caller-held operator keys, derives the local
human ID with the public IdentityStore API, and enrolls the public identity
through the existing opt-in Registry protocol. It writes a new mode-private
caller-owned key file through `Arbor.Security.write_key_file/2`, then passes an
open descriptor to `prepare_key_file_local_genesis/1` to sign the fixed genesis
payload. It never reads a Core-held private key. After genesis, ordinary
operations and every recovery phase use owner-bound broker authorities over
encrypted stored keys, rather than the caller-held key file. The fixture then
uses actor-authorized registration and grants. It proves genuine signed grant,
request and delegation paths; tampering and nonce replay refusal; required
verifier outage refusal; and issuer enrollment. The existing documented
`Arbor.Security.AuthDecision.check/4` module API leaves one-use capability
and rate allowance untouched while consuming each signed nonce. Ordinary
`Arbor.Security.authorize/4` still performs effect admission and consumes use and rate allowance.

A fresh VM recovers the operator, system identity, registered identities,
encrypted keys and delegated capability, then narrows the issuer envelope and
revokes through authenticated actor APIs. Another fresh VM proves usable root
authority remains while the revoked capability and issuer stay denied with
active identity and available key material. The assembled ERTS release repeats
that recovered-authority/refusal proof with actual Mix absence after only
copied qualification inputs and tools are hidden. Reports omit keys, bearer
references, proofs, tokens, file contents and authority records.

The added replay-peer regression separately exercises a real node announcing
the new application. Its legacy RED can use only passive presence because old
Main does not contain the package. Candidate acceptance must start the real
new application and prove live authority owners. A separately provenance-bound
legacy build is required to prove refusal against the actual old Security
application; running new code under an old application label is not evidence.

Use `python3 packages/arbor_capabilities/scripts/qualify_standalone.py --help`
for explicit pinned tool, source-cache, commit, legacy-manifest and fresh-label
inputs. The qualifier builds real archives, validates exact members/checksums
and public metadata, seeds only locked public dependency sources, compiles all
unpacked packages strictly, and compiles Support's C artifact afresh. All build
and runtime data is private; operator state, Main, stash and source inputs are
guarded. It neither fetches nor publishes, and retains failure evidence.

A portable invocation supplies absolute paths and full reviewed commit IDs:

```sh
python3 packages/arbor_capabilities/scripts/qualify_standalone.py \
  --repository "$CANDIDATE" --head "$REVIEWED_HEAD" --branch "$REVIEWED_BRANCH" \
  --main-root "$MAIN" --main-head "$REVIEWED_MAIN_HEAD" \
  --work-dir "$NEW_EVIDENCE_DIR" --deps-source-cache "$PUBLIC_SOURCE_CACHE" \
  --mix "$PINNED_MIX" --erlang-root "$PINNED_ERLANG_ROOT" \
  --elixir-root "$PINNED_ELIXIR_ROOT" --hex-archive "$PINNED_HEX_ARCHIVE" \
  --cc "$PINNED_CC" --rebar3 "$PINNED_REBAR3" \
  --legacy-manifest "$REVIEWED_LEGACY_MANIFEST"
```

The required legacy manifest uses schema
`arbor.capabilities.legacy-build.v1`, predecessor `head`
`3fbe6596fa2da06480fbdd75c3b516815d79a9d3`, absolute `repository` and
`build_root`, the complete SHA-256 `source_files` map under
`apps/arbor_security/lib/`, and a SHA-256 `files` map of reviewed build files
relative to `build_root`. It must include the actual old application and
Security BEAM. `peer_env_path` names reviewed Erlang term data whose bytes match
`peer_env_sha256`: one list of `{application, keyword_configuration}` pairs.
That data must give old Security its own explicit private authority root,
master-key path, independent revocation ledger and real old-owner boot
configuration. Missing, dirty, moved or byte-mismatched legacy evidence stops
the qualification; the tool never substitutes a renamed candidate application.

Full-tree startup also receives the mandatory closed approval-receipt issuer
owner descriptor. It names an unoccupied consumer-owned child,
`CapabilitiesStandaloneConsumer.DormantApprovalIssuer`; the fixture does not
start that issuer or claim approval authority. This satisfies the explicit
startup contract without adding a default or an authority fallback. The
optional authority-audit consumer remains unconfigured and cannot read or
retire the authority journal through its separate owner port.
