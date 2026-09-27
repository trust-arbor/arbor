# Reviewed media source adoption — 2026-09-27

The next integration step needs two patched dependencies. The proposed source is
Arbor's existing private Git host, using sibling repositories under `trust-arbor`.
Publication has not been authorized or performed; repository availability has not
been checked. Public GitHub publication and upstream pull requests are separate
decisions.

| Proposed repository | Exact reviewed commit | Purpose |
| --- | --- | --- |
| `trust-arbor/membrane_core` | `bc01d4f7d08522a5e5028078a082a311161b7b9c` | Opt-in private media diagnostics at actual framework process boundaries |
| `trust-arbor/membrane_portaudio_plugin` | `3ecfad95d64b0edde79219c37934ac660083d9a6` | Bounded capture/playback, permission checks, exact completion and checked cleanup |

These are imported Hex source repositories, not clones of upstream Git history.
Core comes from Hex 1.3.4 and PortAudio from Hex 0.19.6. Preserve their original
Apache-2.0 licenses, Software Mansion attribution, package versions and both Hex
checksums recorded in the current `mix.lock`. Keep the import and patch history;
do not label the imported baseline commits as upstream commits. Reviewed Git
bundles, patches, reports and regression logs are retained in
`tmp/preserved/voice-device-prerequisites-20260927/`.

## Why immutable Git dependencies

This fits Arbor's existing writable dependency materialization and exact lock
admission. A plain vendored `path:` dependency does not: Mix resolves it directly
to candidate source, bypassing `MIX_DEPS_PATH`, and it has no immutable lock entry.
Unifex writes generated files beside `c_src/*.spec.exs` on each compile
(`deps/unifex/lib/unifex/interface_IO.ex`); Bundlex resolves project source from
the dependency directory, and Mix can symlink `priv` back into that directory.
A writable build directory alone therefore cannot make this compile against the
read-only candidate projection.

A portable unpublished alternative would require an attested source-to-dependency
materializer or compiler relocation changes. That is substantially broader than
two immutable remote Git pins. Do not use absolute `/private/tmp` paths, local Git
URLs, writable candidate source, or a weakened baseline check as a shortcut.

## Proposed publication and integration

1. After approval, verify the two sibling repository names on Arbor's configured
   Git host (`http://10.42.42.6/trust-arbor/arbor.git` identifies the existing
   namespace). Create only absent repositories and push the reviewed histories
   without overwriting or force-pushing any existing reference. Preserve the
   imported-source provenance with the repositories.
2. Pin the full commits in Multimedia's dependencies and generate the lock with
   the pinned Mix toolchain. Use the Core override needed by the plugin's
   transitive requirement. Keep the default device driver unavailable during
   integration.
3. Implement the bounded Membrane driver against these exact APIs, with sensitive
   Core processes, private notifications, executor generation checks, and permit
   rechecks immediately before every create/start after asynchronous waits.
4. Provision fresh Linux dependency sources and immutable image/manifest evidence
   for the new lock and source tree. Renew contained no-network compilation with
   read-only candidate source and private writable dependencies/build output.
   Verify the patched module identities, Linux NIF architecture and hashes, fake
   lifecycle/security tests, absent sound devices and loopback-only networking.
5. Promote only that qualified baseline through the operator procedure. Physical
   microphone/speaker and Voice session journeys follow as distinct acceptance
   steps.

Original VP-07B0 evidence attests the original Hex dependencies. It does not
attest these patched binaries. The multimedia owner tests prove its cleanup and
correlation contract with a fake driver; they do not complete VP-07B or establish
audible end-to-end voice behavior.

See [native prerequisite findings and qualification](VOICE_DEVICE_NATIVE_PREFLIGHT.md)
and the tracked [Voice specification](specs/VOICE-1.0.md). The local VP-07B
implementation packet is maintained under the intentionally ignored `docs/specs/`.
