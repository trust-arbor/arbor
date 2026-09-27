# Reviewed media source adoption — 2026-09-27

The two reviewed dependency forks were published with user approval on
2026-09-27 to private sibling repositories on Arbor's existing Git host.
Multimedia now pins the full commits below; public GitHub publication and
upstream pull requests remain separate decisions. The device driver still
defaults to `Arbor.Multimedia.Driver.Unavailable`.

Fresh checkouts require authorized access to the LAN Forgejo host below; both
repositories return 404 to unauthenticated API lookups. Contained offline builds
use admitted materialized dependency sources. External contributors cannot fetch
these private pins without access; a public upstream or public mirror release
has not been approved.

| Private repository | Exact reviewed commit | Purpose |
| --- | --- | --- |
| `http://10.42.42.6:3000/trust-arbor/membrane_core.git` | `bc01d4f7d08522a5e5028078a082a311161b7b9c` | Opt-in private media diagnostics at actual framework process boundaries |
| `http://10.42.42.6:3000/trust-arbor/membrane_portaudio_plugin.git` | `3ecfad95d64b0edde79219c37934ac660083d9a6` | Bounded capture/playback, permission checks, exact completion and checked cleanup |

These are imported Hex source repositories, not clones of upstream Git history.
Core comes from Hex 1.3.4 and PortAudio from Hex 0.19.6. Preserve their original
Apache-2.0 licenses, Software Mansion attribution, package versions and both Hex
checksums from the preceding Hex lock, recorded below. Keep the import and patch history;
do not label the imported baseline commits as upstream commits. Reviewed Git
bundles, patches, reports and regression logs are retained in
`tmp/preserved/voice-device-prerequisites-20260927/`.

| Original Hex package | Inner checksum | Outer checksum |
| --- | --- | --- |
| `membrane_core` 1.3.4 | `c79944e8a98a965dcb83c1a452d47adb73436f07a9d3cdb21963a8f74cc2c435` | `610e98a5e98834c99171ce78715953919c3014430d0ec8610a166fa58c25f872` |
| `membrane_portaudio_plugin` 0.19.6 | `9ceec1405a2ef8b578a5443f7eb7708e864e167810e008e1c9ee8da25150360e` | `48ba05a9a445305972a6aa778caf15547cef0b2bf0ae89d74d9e6fa669c2240f` |

The lock was generated with Arbor's pinned Mix toolchain and verified with
`./bin/mix deps.get --check-locked` from the umbrella root. Only the two media
records changed. Run dependency resolution from the umbrella root: resolving
from a leaf app can omit other apps' constraints and float unrelated packages.

After fetching these exact refs, the isolated host qualification passed both
development and test compilation with warnings treated as errors, 60 owner/Core
diagnostics tests (including three independent forgery/raw-report probes), 23
sealed fake-plugin tests and 329 native C lifecycle assertions under ASan/UBSan.
All 159 tracked Core files and 49 tracked plugin files match their reviewed Git
blobs after compilation. The plugin fake suite reads the fetched checkout's
source directly and removes the real plugin code path before installing fakes.
No device enumeration, permission query/request, capture or playback was called.
This is host source/build evidence; the changed lock still requires renewed
Linux baseline admission before activation.

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

## Integration sequence

1. Complete: the private repositories preserve the reviewed import and patch
   histories; their published heads match the exact reviewed commits.
2. Complete: Multimedia uses immutable Git pins and an actual Mix lock, with the
   Core override required by transitive Hex constraints. The default driver
   remains unavailable during integration.
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
