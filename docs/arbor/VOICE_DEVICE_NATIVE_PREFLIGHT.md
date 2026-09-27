# Bounded audio device prerequisite

Source review, 2026-09-27. This is the VP-07B prerequisite design, not device
qualification. The reviewed sources are Membrane Core 1.3.4, PortAudio plugin
0.19.6, and the installed PortAudio 19.7.0 public header. No device was opened.
The existing `Arbor.Multimedia` facade remains the consumer boundary.

## Findings and bounded implementation

The pinned Source/Sink interfaces do not expose enough evidence to meet the
planned capture/playback contract. An Arbor owner can enforce a deadline and
retain a cleanup fence, but cannot recover errors discarded inside a native
callback. The isolated corrections and approved source adoption are recorded
below; do not patch the live dependency directory.

| Required behavior | Source finding | Smallest proposed correction |
| --- | --- | --- |
| Capture has a hard data bound | `source.c` sends every callback without downstream demand. Its callback-visible `frame_size` is assigned after `init_pa` has already started the stream. | Initialize callback fields before start. Admit a fixed frame cap, clip the last callback and stop production at that cap. A distinct early-finish operation stops callbacks and reports the final produced count for push-to-talk release. No general streaming credit protocol is needed. |
| Permission denial is observable | `osx_permissions.m` requests asynchronously and immediately returns success; denial only prints a warning. | In bounded mode, query closed OS authorization states at initialization and immediately before opening; proceed only while already authorized. Missing platform permission support fails closed. A permission request requires a separate explicit flow. |
| Playback consumes the exact payload | Sink ignores native overrun and its callback leaves a sub-block tail in the ring buffer. | Check writes, count the admitted payload frames, consume the final partial block with zero padding, and return `paComplete` at the exact payload count. |
| Successful playback means completion | Upstream EOS and ring-buffer demand do not prove device completion. | Use `Pa_SetStreamFinishedCallback` plus the operation's completion disposition and count. PortAudio documents completion after generated samples play; Abort also invokes this callback, so notification alone is insufficient. |
| Cleanup is positively known | Native destroy discards stop/close errors and may free callback storage despite failed close. ResourceGuard logs cleanup failures and still returns success. | Preserve checked close results and storage ownership on uncertainty. Keep ResourceGuard as fallback, not success evidence. A media error followed by confirmed close may release the fence. |
| PCM stays out of ordinary diagnostics | Actual OTP processes are `Membrane.Core.Element`/`Pipeline`, not the Arbor callback module; Core also directly logs options, actions and exceptions. | Qualify a narrow opt-in sensitive mode at actual process and diagnostic boundaries. Avoid PCM in startup options. Test status, current-message crashes and direct error logging. |

An operation deadline ends admission and presentation, not cleanup ownership.
On uncertain native close, return `:cleanup_pending` and retain a supervised
owner and device fence. Callback storage must outlive the BEAM resource: the
original destructor queues a copied state while PortAudio still holds a pointer
to the original allocation. Transfer stable native storage to the cleanup owner
instead of freeing it while callbacks may continue. Do not promise that killing a BEAM caller cancels a
blocked native call. Do not free storage that a callback may still use.

A fixed native helper process could provide stronger failure isolation, but is
outside the current no-subprocess L0 design. Adopting it would require a separate
hierarchy/transport amendment; shell commands or temporary PCM files are not an
implicit fallback.

## Qualification before use

Use a fake native driver to reproduce callback-before-initialization, partial
tail, overrun, failed close and cancellation races. Applicable behavioral tests
must fail on the unchanged dependency revision. Run actual Core processes with
unique PCM sentinels to test both OTP formatting and direct framework logs.
Normal diagnostics for unrelated components should retain their existing value.
The opt-in policy covers ordinary framework diagnostics. Deliberate `:sys.log`,
`:sys.trace`, `:sys.get_state`, caller-provided Logger metadata and direct callback
`Logger` calls remain trusted-VM operations outside that policy. In particular,
OTP debug history appears outside GenServer's status formatter; never enable it
for private PCM pipelines or put PCM in startup options, names or log metadata.

Early capture finish and cancellation are distinct. After checked stop, join the
reported final frame count with the received PCM byte count; threaded payload and
finish-notification arrival order alone is not evidence. Zero frames is an empty
clip, and failed stop cannot publish a completed clip. Positive close is still
required independently of capture completion.

Only after review should Arbor adopt an immutable source revision. Changed
native source requires renewed dependency/build/NIF attestation and contained
no-device proof. Original B0 evidence does not attest a later patched binary.
Real microphone/speaker qualification follows these gates.

## Integration constraints retained from A1

- Use one fresh authenticated PCM Voice Session per utterance. A1 rejects prior
  text turns and closes the backend before successful presentation.
- A CLI user string or distribution cookie does not establish the requested
  human's conversation proof. Bind an existing authenticated subject and preserve
  canonical-owner separation; do not mint a token for an arbitrary `--user`.
- The short-lived RPC worker is not the long-lived terminal caller. Define
  caller-loss and lease expiry explicitly before exposing desk operations.
- Queue-time authorization is insufficient for playback. Retain and recheck the
  immutable conversation binding after A1's Session closes and before playback.
- Serialize progress, exhaustion and final output under one presentation owner.
  Audio, guarded fallback speech and screen-only output remain distinct outcomes.

This review changes the prerequisite work for VP-07B. It does not select another
visual UI stack or settle the later assistant-ui comparison.

## Isolated qualification checkpoint

Membrane Core candidate `bc01d4f7d08522a5e5028078a082a311161b7b9c` is prepared in
`/private/tmp/arbor-membrane-sensitive-20260927`. Independent root verification
reproduced 27 passing tests and 24 behavioral payload-leak failures on the unchanged
production-source predecessor `3d79183` (two ordinary controls pass; one new-API
test is excluded there). No live dependency was replaced. A Git bundle, full patch,
qualification report and root test logs are preserved under
`tmp/preserved/voice-device-prerequisites-20260927/`.

PortAudio candidate `3ecfad95d64b0edde79219c37934ac660083d9a6` is prepared in
`/private/tmp/arbor-portaudio-bounded-20260927`. Independent root verification
reproduced 329 native C assertions with ASan/UBSan, 23 sealed fake-BEAM tests and
five fake Objective-C permission outcomes. The unchanged-source predecessor
fails seven native lifecycle assertions. A subsequent test-bearing predecessor
also reproduces three write/close failures; writes, starts, finishes and cleanup
now share the native executor, and late operations fail closed. Missing Darwin
permission support has a separate behavioral fail-before/pass-after witness.
These final harnesses do not open devices. Bundles, full patches, regression
logs and metadata for both dependency candidates are preserved together.

A 2026-09-27 source-identity audit found that the earlier ordinary compile logs
used a copied dependency with pre-serialization Sink/SyncExecutor source. The
sealed behavioral harness already compiled the exact final source directly.
The isolated copy was refreshed from the exact Git revision and all four dev/test
dependency/umbrella compilation checks passed again. Fresh remote-fetch adoption
checks independently passed 60 owner/Core tests, 23 sealed plugin tests and 329
native assertions, with all 208 tracked dependency files matched to their pins.
The corrected report supersedes the old compile claim; both sets of logs remain
preserved under `tmp/preserved/voice-device-prerequisites-20260927/`.

The approved portable adoption uses full immutable refs on Arbor's existing
private Git host. Both forks were published privately on 2026-09-27 and are
pinned by the prepared adoption candidate. See [the source adoption record](VOICE_MEDIA_SOURCE_ADOPTION.md).
The default driver remains unavailable. Fresh host and contained Linux builds
pass; root-owned baseline admission/activation and physical device qualification
remain distinct pending steps.

A separate first BEAM ownership harness had a failed mock boundary: Mockery
interception was not compiled into the dependency, so four attempted fake native
creates could reach real PortAudio initialization. Three recorded results fail at
the channel-capability check before `Pa_OpenStream`; the fourth test discarded its
result, so absence of a stream open/capture cannot be claimed categorically for
that attempt. No permission request/status function was called by that harness.
The test VM exited. The failed log is retained at
`/private/tmp/portaudio-ownership-tests.log`. The replacement harness removes the
real plugin code path, verifies real native modules are unloaded, installs checked
fake native modules, and compiles the exact Source, Sink and executor under test, making native
fallback impossible. This incident is not device qualification or user audio
acceptance, and the earlier general claim of no capture is withdrawn.
