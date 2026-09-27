# Reviewed media source adoption — 2026-09-27

The two reviewed dependency forks were published with user approval on
2026-09-27 to private sibling repositories on Arbor's existing Git host.
The clean adoption candidate `57bca1c470a619a335b271778b51a6133ed0e909` pins
the full commits below. It is prepared separately from the active checkout while
root-owned baseline promotion awaits macOS administrator authentication. Public
GitHub publication and upstream pull requests remain separate decisions. The device driver still
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
No device enumeration, permission query/request, capture or playback was called
in this adoption qualification. Fresh contained Linux umbrella compilation and
actual ARM64 NIF/SQLite loading also passed with only loopback and no sound
devices. This does not invoke the native device APIs or qualify hardware. Full
root-owned candidate admission and managed activation remain pending.

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

## Publication and integration state

Both repositories are private. Authenticated API checks and Git remote reads
verified their exact heads; unauthenticated API reads returned 404. The annotated
`arbor-prerequisite-20260927` tags retain original Hex checksums, import baselines,
reviewed commits, license attribution and scope. Tag objects are
`78d2919108d69c8c973e87024ef672449273e978` (Core) and
`07b0c77a713913b82ff2f770e56ffbad018cb8c4` (PortAudio). Neither imported history was
rewritten. Publication evidence is preserved beside the qualification package.

The new Linux source tree contains 6,921 entries and 82,840,004 regular-file bytes.
The runtime image derives from the exact original native-equipped image and
changes only the source/lock labels; its native system inputs remain unchanged.

| Prepared baseline input | Exact identity |
| --- | --- |
| Lock SHA-256 | `e4378b2578fc7041948225bef442a244ec29717af672bedc32c3181fc89c9365` |
| Source tree SHA-256 | `5464f8ddcd0439b729ee2d585a6e892eb75b8d1109ef74e07ab0508fb4067a71` |
| Image index | `sha256:471c256a63697eed1eee27698c5806c4a783fb50011c11b52235666ce7ad73ac` |
| Image manifest | `sha256:e9da3b58c374f09a39826640a58ed2f04b6044fa844bf710bd27eef3c5e144f0` |
| Manifest file SHA-256 | `83423d84dc015339f39e216d82162e95e304e0e3abf91b628857fc8ccd12389c` |
| Candidate config SHA-256 | `d3cd16c0f033ef09d0d8de81094dd9c9d02fe40c8e576c2934bd8aae4620418a` |
| Installer SHA-256 | `48f0843a7d74477c71563ba6e6d5868c72472c1774e75ff9af3354ff5ab9c245` |

The installer and full inventory were independently reviewed. Evidence and the
literal-digest installer are in `tmp/preserved/voice-native-git-admission-20260927/`.
The current active baseline remains the original B0 baseline. Remaining steps:

1. Complete macOS administrator authentication to prepare the root-owned files.
   Stop/drain the managed runtime, run full admission against the prepared config,
   and activate only after acceptance. Preserve the checked predecessor config.
2. Integrate the adoption candidate, fetch and compile the host dependencies while
   the server is stopped, then restart through the managed lifecycle. Verify live
   readiness, exact module identities and baseline/lock agreement.
3. Execute the prepared genuine Workspace/Mix contained proof and require positive
   workspace/container cleanup. Its fixture is `e10c9c32d2c245eebb778eb4efafd5328203f608`;
   this test has been prepared, not executed. Config rollback also requires
   coordinating the repository lock and live runtime; it is not a code rollback.
4. Complete the separately reviewed [native driver follow-up](VOICE_NATIVE_DRIVER_PLAN.md):
   executor-enforced deadlines/revocation, gated element custody, Source open/start
   separation, native event correlation, bounded enumeration and dormant driver
   activation. Preserve the published prerequisite tips and use new immutable refs
   for follow-up changes. Renew admission when those sources change.
5. Qualify explicit physical capture/playback and the bounded Voice session journey
   before returning to the assistant-ui comparison. Keep the default driver
   unavailable until the device implementation is qualified.

Original VP-07B0 evidence attests the original Hex dependencies. It does not
attest these patched binaries. The multimedia owner tests prove its cleanup and
correlation contract with a fake driver; they do not complete VP-07B or establish
audible end-to-end voice behavior.

See [native prerequisite findings and qualification](VOICE_DEVICE_NATIVE_PREFLIGHT.md)
and the tracked [Voice specification](specs/VOICE-1.0.md). The local VP-07B
implementation packet is maintained under the intentionally ignored `docs/specs/`.
