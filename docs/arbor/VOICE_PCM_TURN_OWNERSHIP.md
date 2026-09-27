# VP-07A1: one bounded PCM conversation turn

Implementation checkpoint, 2026-09-27. The pure contracts, reducers, authenticated
Session/ResourceOwner lifecycle and bounded public audio entry point are
implemented. This document qualifies hermetic protocol and lifecycle behavior;
it does not qualify a device, a live provider journey, or an external
tuple-addressed RPC.

## Source authority and ownership

The session tuple remains `{authenticated_subject, agent}`. A Voice-owned
conversation binding pins the authenticated subject, canonical owner, target,
engagement and reusable HMAC session proof. Fresh admission precedes the audio
reservation. Its continuation check remains required at every provider effect,
tool dispatch, transcript write, guarded output and final publication; the same
binding survives egress-turn finalization and backend cleanup. A pure reducer
cannot establish live authorization from a cached boolean.

Use the existing single Session, ResourceOwner, BackendWorker and cleanup lease.
The BackendWorker remains the only owner of an opaque provider handle. A0's
reservation continues to contain only format, byte count and an opaque
owner/generation/token ticket; the input PCM handoff remains asynchronous.

A0's default disposition stays `:close`. A1 adds an owner-authenticated
`reserve_audio_turn/4` path with a source-owned receive disposition. A valid send
result transfers that exact ticket into a receive phase. A timeout, cancellation,
authority denial, malformed result or ambiguous send retires the backend.

One source-owned absolute deadline covers the entire admitted audio operation,
with a 30-second ceiling independent of the longer Session budget. The owner's
timer survives send acceptance and bounds all later callbacks; the Session has
an independent timer and checks expiry before append, after acknowledgment and
before final reply. Callback deadlines remain no greater than their configured
owner bound. Neither empty receive windows nor late STT renew this budget.

Receive uses an asynchronous request tagged by the active ticket and a fresh
callback token. Session retains the request reference, caller monitor and pure
redacted reducer state, and can service cancellation while a backend callback is
blocked. No second callback executes concurrently. Late request replies and
old-generation results cannot reach a new reducer or durable write.

## One audio turn per Session

The approved bounded lifecycle is:

1. Admit the fresh proof against the pinned conversation and validate input.
2. Reserve and hand off PCM under the source-owned send deadline.
3. Receive bounded events, retain completed STT and admit tools through the same
   conversation authority.
4. Select final source-owned assistant text, including the existing D1 rewrite.
5. Recheck authority and persist the actual transcript/final assistant pair,
   accepting only the exact acknowledged count `{:ok, 2}`.
6. Recheck after acknowledged persistence, obtain the guarded presentation, close
   the backend positively, recheck authority and return the bounded result.

The next utterance starts a fresh authenticated Voice Session. The normalized
backend protocol does not currently carry provider item/response correlation;
reusing a connection could associate a delayed prior transcript with a later
utterance. This slice therefore does not provide reusable provider sessions.
PCM-mode sessions also reject text turns before admission or provider effects,
so a prior text response cannot contaminate the sole audio operation's stream.
Connection and configuration latency recur for every utterance. No first-audio
latency target or real playback performance is qualified here.

Cleanup uncertainty yields `:cleanup_pending`, never successful presentation.
Cancellation retires the Session/backend. Cancellation cannot roll back a pair
already durably committed; no success acknowledgment may imply otherwise.
An ambiguous cancellation must not permit backend reuse or claim that an
in-flight durable effect was rolled back. External transports must additionally
bind their requests to the authenticated Session lifetime; a tuple alone is not
an authentication or replay boundary.

## Pure data boundaries

`Voice.Contracts.AudioTurn` validates the exact PCM input and duplicate-free
operation options. The input limit is the smaller of 60 seconds at the declared
mono s16le rate and 2 MiB. It preserves the supplied UTC utterance-end evidence;
it neither generates a substitute timestamp nor authenticates its source.
Capture-source qualification belongs to the later owned capture boundary.

`Session.AudioTurnCore` delegates existing text/tool validation to `TurnCore`.
It keeps one nonblank UTF-8 completed transcript of at most 8 KiB; exact duplicates
are idempotent and conflicts fail closed. A partial transcript cannot authorize
a tool. If a final response arrives before STT, its bounded terminal is held
until completed STT arrives or the shell's deadline/cancellation retires it.
No placeholder user text is manufactured.

Output chunks are nonempty, even-byte PCM, at most 64 KiB per event and 8 MiB
across the complete operation, including discarded intermediate waves. The core
holds reversed flat iodata under `Redacted`. Tool-bearing waves discard their
text/audio while preserving the transcript. Only the final non-tool wave reaches
presentation. Delta fallback text remains distinguishable from actual provider
terminal text, so a missing terminal text cannot silently authorize audio.

`Session.AudioPresentationCore` runs only after persistence and a live authority
check. It receives the provider terminal text, D1's exact final authoritative
text, Speakable's verdict and independently guarded string, final-wave audio,
and source-validated output formats. PCM is released only when texts and formats
match exactly, the verdict is `{:speak, guarded}`, the guarded text equals that
exact final text, and bounded PCM is valid.
Rewrites, truncation, sensitive/screen-only verdicts or missing/invalid media
return nil audio and format. Guard mismatch or malformed guard produces a silent
screen-only envelope, never raw fallback text. A screen-only verdict always has
empty `spoken_text`; its display text remains in the verdict and durable reply.
The audio path does not invoke
legacy `speech_output`; progress and exhaustion cues remain separately owned.

## Public boundary and telemetry

The public `audio_mode: :pcm16`, tuple-keyed `audio_turn/4` and exact-operation
`cancel_audio_turn/3` are integrated with source-owned conversation admission and
continuation fences. The result contains only operation id, durable reply,
durable input transcript and presentation. Invalid pre-admission input has no
provider effect or terminal telemetry. Cancellation success retires the current
operation; another id cannot cancel it.

The shell emits exactly one closed `[:arbor_voice, :turn]` telemetry event at
admitted operation settlement. `:telemetry` is a direct Voice dependency.
This covers normal source-owned success, failure, cancellation and timeout
settlement. It is not a crash-durable event log: forced Session `:kill` relies on
owner-monitor cleanup and cannot guarantee a terminal telemetry event.
`ack_ms` is nil. `first_audio_ms` is the arrival time of the first chunk in the
final eligible provider wave, relative to the actual utterance-end evidence;
tool-wave resets clear it, and suppressed media or any failed turn reports nil.
This is a provider-arrival diagnostic, not audible playback timing or a device
acknowledgment. `total_ms` measures the admitted operation through settlement.
VOICE-32 remains planned for device timing and measured latency qualification.

No microphone, speaker, live provider or transport endpoint is opened by these
tests. Actual device acknowledgment, audible latency, capture qualification and
long-lived provider response correlation remain separate work.

## Pure-slice validation

On 2026-09-27 the private A1 checkout built the umbrella test environment with
warnings as errors and ran the three new contract/reducer/presentation files:
16 tests, 0 failures. The suite includes exact-text guard rewriting, screen-only
silence, completed STT ordering, intermediate-wave disposal and output bounds.
These are pure decision proofs; they do not substitute for the integration
acceptance above, and no historical production security counterwitness is claimed
for newly introduced modules.

The public audio lifecycle file subsequently passed 14 tests, including exact
durable STT/timestamp/result, asynchronous blocked-receive cancel/stop/caller
death/hard timeout, total deadline after successful send, pending STT expiry,
tool-wave disposal, D1 text replacement, guarded PCM suppression, redacted state,
durable-ack barrier, transcript failure and rejection of a prior text turn in
PCM mode. The separate real Security/SQLite
journey passed 15 tests, including web-to-audio-to-web continuity, revoked receive
denial, pinned owner checks and exact pair acknowledgments. The final complete
Voice suite passed 513 tests with those 15 isolated-database cases excluded; the
15 cases passed separately. Both development and test umbrella builds passed with
warnings as errors, all 25 changed Voice Elixir files passed scoped formatting,
and strict VOICE conformance passed with planned device/latency markers intact.

The predecessor `6c03e94797a8d43be23a652beed266a14e4dcdca` was built independently.
The same 11 applicable binding/pair-ack security witnesses fail through old public
admissions or replies; none rely on an undefined new audio API. Fixture SQLite
paths include the OS process id to keep concurrent independent BEAMs isolated.

Independent integration acceptance at `2c5ae98b4` combined this slice with the
native dependency scaffold, transcript freshness and source engagement fence.
An isolated checkout with private dependencies/build output passed test
warnings-as-errors compilation, all 513 Voice tests, and the separate 15-case
real Security/SQLite journey. This verifies the integrated source; the running
Arbor instance, native baseline activation and sound devices were unchanged.
