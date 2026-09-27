# Voice native dependency admission

2026-09-27 — VP-07B0 operator preflight, prepared; live activation pending.

`arbor_multimedia` is an L0 facade scaffold with no device API. Its locked direct
dependencies are Membrane Core 1.3.4, PortAudio plugin 0.19.6, and RawAudio 0.12.3.
Bundlex precompiled OS dependencies are disabled for the PortAudio plugin. The
plugin compiles against image-owned PortAudio through pkg-config. No microphone
permission, device enumeration, capture, playback, or provider request was used.

## Bound evidence

| Input | Exact identity |
| --- | --- |
| Repository `mix.lock` SHA-256 | `5527a14f00fabca2936d39e2d46506a57257ed90878dcb1dcb7394dd9fcc6341` |
| Linux platform | `linux/arm64` |
| Toolchain | Erlang 28.4.1; Elixir 1.19.5-otp-28 |
| Image index | `sha256:996d5d520e140ce5f7d355a075b07106d88d8942d4ee45d263e574a945b4d2ca` |
| Image manifest | `sha256:491b5cc000a4774305c59fdb4660605e3556c4d50ff51e4be57dbfff9107e5ea` |
| Dependency tree SHA-256 | `d3f58a8ab1c1a457e01724f3b49a480eba5d56b5cee90d807f6d2fdb37968c11` |
| Manifest file SHA-256 | `764c76ff5672c9511a1628baf151c4309744f6918f93d68314fc8af03b06645c` |
| PortAudio | 19.7.0, official source archive SHA-256 `47efbf42c77c19a05d22e627d42873e991ec0c1357219c0d74ce6a2948cb2def` |
| pkg-config/pkgconf/pkgconf-bin/libpkgconf3 | Debian `1.8.1-1` |
| libasound2/libasound2-dev | Debian `1.2.8-1+b1` |
| libasound2-data | Debian `1.2.8-1` |

The dependency receipt inventories 6,834 entries and 82,349,613 regular-file bytes.
The image attests native inputs; the receipt attests the dependency source. Both
must agree with the repository lock and tracked Bundlex configuration.

The image also caches checksum-verified archives for existing locked Exqlite
0.34.0 and lazy_html 0.1.8 dependencies. Their ARM64 and AMD64 checksums come from
those packages' `checksum.exs`. Only ARM64 execution was qualified.

The existing sqlite_vec 0.1.5 upstream ARM64 archive contains an ELF32 ARM binary.
The unchanged architecture guard rejected it. The candidate tree instead contains
an offline ARM64 build of upstream tag v0.1.5, commit
`ee3654701f7b8efe4802ff1caed24514f43443dd`, with the locked Exqlite SQLite headers.
Its SHA-256 is `a96f3f2664ec09eb0b057d7e9187b78874b085d7d1e5e0ac37d29fce8b7ee175`.
No guard or upstream C source was weakened or patched.

## Qualification

macOS development and test warnings-as-errors compilation passed. All three
PortAudio native modules loaded without opening devices. The dependency hierarchy
guard passed 4 tests and the validation toolchain guard passed 3 tests.

A new Linux-native source tree was fetched with the exact lock. A separate copy
was compiled with an empty build directory, a read-only repository and root
filesystem, private writable dependency/build directories, and networking disabled.
The full umbrella compiled with warnings-as-errors. Dependency compiler warnings
remain visible; this is not a claim that all dependencies compile without warnings.
The proof observed only the loopback network interface and no `/dev/snd`.
It loaded all three actual PortAudio NIF modules and loaded sqlite_vec into a real
in-memory SQLite database, returning `v0.1.5`. The untouched source tree was then
rehashed and used to generate the canonical receipt through `Arbor.Shell`.

| Produced PortAudio NIF | Bytes | SHA-256 |
| --- | ---: | --- |
| pa_devices | 115,680 | `88cc3698aa3fa175d18c5149a6a0ea201e30046d8081d1c963c82be14a842cab` |
| source | 139,288 | `4bd0fabd87cf0fcd57bc36ead6c768ae9b4b4f734ecf8a6b96356952a79b54cc` |
| sink | 151,832 | `ad6b525034ad237d25c065a25b87140dfb88a00d1d6769663954c0cff93695df` |

`hex.audit` reported 14 existing advisories and `deps.audit` reported 7 existing
advisories. None concern the 18 newly locked packages; the overall audit is not
clean. Existing dependencies were not upgraded in this admission slice.

License inventory from locked package metadata: Apache-2.0 for bunch,
bunch_native, bundlex, elixir_uuid, membrane_common_c, membrane_core,
membrane_portaudio_plugin, membrane_precompiled_dependency_provider,
membrane_raw_audio_format, mockery, shmex and unifex; MIT for bimap, coerce,
numbers, qex, ratio and zarex. PortAudio uses its MIT-style license. The image's
Debian copyright files record LGPL-2.1-or-later for ALSA and ISC plus component
notices for pkgconf (BSD-2, BSD-4, X11 and the pkg.m4 GPL exception). Those notices
are retained in the evidence package. No repository license-audit command was
found; this records source/package declarations, not legal clearance.

## Prepared promotion and remaining gate

Reviewable local evidence and the installer are in
`tmp/preserved/voice-native-admission-20260927/`. The installer follows the existing
root-owned baseline procedure: pin the reviewed script, copy and verify payloads
in privileged staging, check exact tree inventory and file hashes, retain the old
config, prepare the root-owned candidate, and activate by atomic replacement.
It has a digest-checked rollback operation. Neither preparation nor activation
has been executed.

The proposed installed tree is
`/usr/local/share/arbor/apple-container/deps-5527a14f-d3f58a8a`; the proposed config
is `/usr/local/etc/arbor/apple-container.candidate-5527a14f-d3f58a8a.json`.
The policy retains an external digest reference. Its non-connectable local
execution alias was provisioned separately and exercised by the inventory probe.

Before VP-07B device implementation: obtain approval for privileged installation,
config activation and Arbor restart; prepare the candidate; verify runtime-user
readiness; activate; restart normally; then verify the live baseline lock matches
the repository and the full contained admission path loads the audio NIF without
a sound device. The successful manual offline proof does not replace this final
live-authority check. No claim of VP-07B0 completion or hardware readiness is made.
