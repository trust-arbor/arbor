# Voice native dependency admission

2026-09-27 — VP-07B0 installed, activated and qualified through the live runtime.

`arbor_multimedia` is an L0 facade scaffold with no device API. Its locked direct
dependencies are Membrane Core 1.3.4, PortAudio plugin 0.19.6, and RawAudio 0.12.3.
Bundlex precompiled OS dependencies are disabled for the PortAudio plugin. The
plugin compiles against image-owned PortAudio through pkg-config. This baseline
admission used no microphone permission, device enumeration, capture, playback,
or provider request. The separate device-prerequisite work and its harness incident
are recorded in [`VOICE_DEVICE_NATIVE_PREFLIGHT.md`](VOICE_DEVICE_NATIVE_PREFLIGHT.md).

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

## Installed baseline and live proof

The user authorized privileged installation, activation and a managed restart on
2026-09-27. The reviewed payload was copied through privileged staging, checked
against literal installer and payload digests, and installed root-owned. The active
config is `/usr/local/etc/arbor/apple-container.json`; its predecessor is retained
at `apple-container.json.pre-5527a14f-d3f58a8a` for digest-checked rollback.

| Installed input | Identity |
| --- | --- |
| Dependency root | `/usr/local/share/arbor/apple-container/deps-5527a14f-d3f58a8a` |
| Candidate config | `/usr/local/etc/arbor/apple-container.candidate-5527a14f-d3f58a8a-v2.json` |
| Active/candidate config SHA-256 | `aa0e87d2948bc16bd8b3ccad8d4d1ba3e29586d054039d2381f30dd000a92f4d` |
| Installed v2 installer SHA-256 | `ca804e9afff1d34dc27fbd520c1884d09e8c8ce53b57b2f2a6c7fcca7664f368` |
| Predecessor config SHA-256 | `b350d9acfba975d4af4cf8d2c529a581825ad37c4b7c718d04797334b77b5a57` |

Full candidate admission caught two setup mismatches before activation. PATH selected
Homebrew Container 1.4.1 while Arbor pins `/usr/local/bin/container` 1.1.0. Its API
service was restarted from the same pinned installation, commit
`5973b9cc626a3e7a499bb316a958237ebe14e2ed`. The first candidate also retained a
PATH-only environment from the older image. V2 pins all five exact environment
entries from the reviewed image recipe. No parser or admission gate was weakened;
the failed candidate and probe logs remain in the evidence package.

The managed Arbor server was already stopped at the start of promotion. After
candidate admission and host warnings-as-errors compilation, `./bin/mix arbor.restart`
started `arbor_dev_045c@127.0.0.1` with all 26 umbrella apps ready. The unrelated
ConversationKit demo process was left alone.

The final proof used genuine Workspace acquisition and `Arbor.Actions.Mix` validation
resource ownership on the running server, with an isolated fixture at
`e2aa44be0ac7eae8b90c6a693e6b94d2bf72a3b4` (production source `dc7edff1d` plus the
committed qualification test). Both the umbrella warnings-as-errors compile and
`1 test, 0 failures` passed. The test observed Linux ARM64, loopback only, no
`/dev/snd`, all three loaded audio NIFs and sqlite_vec `v0.1.5`. Its final resource
inventory was complete, empty and untruncated; the owned worktree was removed and
the live baseline lock still matched. Completion: `2026-09-27T20:37:16Z`, task
`native_audio_admission_20260927_a7dfa6045815a705`.

| Live contained NIF | Bytes | SHA-256 |
| --- | ---: | --- |
| pa_devices | 115,800 | `5545401c4657e51ee3791a75ad5b8578a1dada88f65b1bb6b6a4a384cc4577b2` |
| source | 139,440 | `4fc92482edf8920c80172e9c4aec6bba7a87385ba8fddc236cd2615cfcb520eb` |
| sink | 152,000 | `94a74f1906999a74d20b6e85ec1f6d267e122d9bb43b688bdc3b9d1015a3230a` |

These record the live build's artifacts; the earlier manual-build hashes above
remain separate evidence. The source receipt is not a bit-reproducible-build claim.
The first live test fixture had invalid ExUnit tags; that failed attempt and the
corrected fixture are retained, rather than counted as a native-library failure.

Reviewable local evidence is in `tmp/preserved/voice-native-admission-20260927/`,
including `live-contained-proof.json`, per-command results, exact scripts, candidate
failure logs, installed-file inventory, config/installer digests and rollback backup.

## Readiness performance and remaining device gate

The operator proof uses the public full `validation_runtime_probe/0`, which runs
the existing complete admission procedure with its canonical execution budget.
The separate coding-dispatch readiness API has a 30-second budget and intermittently
refused this larger baseline with `:deadline_exhausted`. A successful timed probe
used 26.995 seconds; six full baseline verifications accounted for 21.786 seconds.
The 35-second executor callback and 45-second MCP budget make an isolated inner
timeout increase inappropriate. An isolated optimization is being qualified to
share an authority's freshly verified receipt with its policy at the initial and
final boundaries, preserving per-image and final drift checks. This performance
issue is not fixed by the successful operator proof.

B0 establishes the original locked native baseline. It does not qualify microphone
capture, audible playback, updated native forks or the desk conversation journey.
The bounded device implementation first needs the reviewed PortAudio lifecycle and
Membrane diagnostics prerequisites. Any changed dependency source needs fresh
attestation and contained qualification before activation.
