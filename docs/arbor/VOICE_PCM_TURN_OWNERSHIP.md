# VP-07A1: one bounded PCM conversation turn

Design checkpoint, 2026-09-27. The pure contracts and reducers described below
are implemented. Session, ResourceOwner and public audio entry-point integration
remain pending the private conversation binding slice. This document does not
qualify a device, a live provider journey, or an external tuple-addressed RPC.

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
5. Recheck authority and persist the actual transcript/final assistant pair.
6. Recheck after acknowledged persistence, obtain the guarded presentation, close
   the backend positively, recheck authority and return the bounded result.

The next utterance starts a fresh authenticated Voice Session. The normalized
backend protocol does not currently carry provider item/response correlation;
reusing a connection could associate a delayed prior transcript with a later
utterance. This slice therefore does not provide reusable provider sessions.
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

## Integration acceptance still required

The public `audio_mode: :pcm16`, tuple-keyed audio turn and exact-operation cancel
are not enabled by the pure-module commit. They must wait for source-owned
conversation admission and all continuation fences. The final result must have
only operation id, durable reply, durable input transcript and presentation.

The integrated shell must emit exactly one closed `[:arbor_voice, :turn]`
telemetry event at admitted operation settlement, and none for pre-admission
errors. Timing comes from source clocks and actual utterance-end evidence, not
from these pure reducers. `:telemetry` must become a direct Voice dependency.
No telemetry implementation or VOICE-32 qualification is claimed by this slice.

Remaining behavioral proofs include send/receive/cancel races, denial during
provider work and append, real utterance timestamp persistence, exact result and
telemetry shapes, suppression of audio after D1 rewrite, positive final close,
text compatibility and no PCM in status, logs, errors or durable records.

## Pure-slice validation

On 2026-09-27 the private A1 checkout built the umbrella test environment with
warnings as errors and ran the three new contract/reducer/presentation files:
16 tests, 0 failures. The suite includes exact-text guard rewriting, screen-only
silence, completed STT ordering, intermediate-wave disposal and output bounds.
These are pure decision proofs; they do not substitute for the integration
acceptance above, and no historical production security counterwitness is claimed
for newly introduced modules.
