# VP-07A0: bounded PCM operation ownership

Historical A0 checkpoint, 2026-09-27. This prerequisite added no public audio-turn
or device API; its internal Session send seam proved one backend send, not a
completed conversational turn or transcript. The subsequent
[implemented A1 lifecycle](VOICE_PCM_TURN_OWNERSHIP.md) adds the authenticated
public audio turn and an explicitly owned receive phase. The A0 close disposition
below remains the default for its internal send-only operation.

## Authority and wire format

`PcmFormat` admits only atom-keyed, exact maps with `encoding: :pcm`,
`sample_format: :s16le`, `channels: 1`, and an integer `sample_rate` from 8,000
through 192,000. Input and output descriptors are independently authoritative;
metadata with no admitted PCM (text-only or not yet provider-confirmed) has
both descriptors set to `nil`. PCM is nonempty, has an
even byte length, and is at most 2 MiB. The xAI backend admits 16 kHz input and
24 kHz output only after provider confirmation. Output events are additionally
limited to 64 KiB. A requested audio mode cannot prove provider output encoding.

The ResourceOwner validates backend metadata and compares explicitly configured
input/output descriptors exactly. Metadata is refreshed after configuration. xAI configuration owns its bounded
provider acknowledgement: initial default session events do not establish the
requested format, and no PCM is admitted until the exact update is confirmed.
The BackendWorker additionally checks the closed wire-event and format shapes.
The xAI decoder rejects missing/invalid base64, empty/odd/oversized audio and
conflicting format declarations, retaining no permissive empty-binary fallback.

xAI documents initial 24 kHz defaults in both directions and a startup sequence
where `session.created` precedes `session.updated`. Both text and audio
configuration therefore explicitly request 16 kHz/24 kHz PCM over JSON. One
configure deadline covers the write and acknowledgement; known startup control
events do not renew it. Missing, mismatched or binary-transport acknowledgements
close the latest transport handle. No PCM is sent or returned before confirmation.
See the official [audio format and transport documentation](https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech)
and [Realtime event sequence](https://docs.x.ai/developers/rest-api-reference/inference/voice),
reviewed 2026-09-27. The positive fixture replays that documented sequence; this
qualification makes no live provider or microphone claim.

## Reservation, handoff and terminal protocol

`ResourceOwner.reserve_audio(owner, input_format, byte_count, timeout_ms)` is an
owner-authenticated control call containing no PCM. It admits one opaque ticket
with owner pid, operation id, worker generation, secret token and absolute
monotonic deadline. Reservation is exclusive; audio is never put in the deferred
queue. `handoff_audio(owner, ticket, pcm)` uses an asynchronous GenServer request
from the registered Session owner. ResourceOwner validates the ticket and byte
count, submits exactly one BackendWorker operation using the original deadline,
and retains only control metadata. Session retains only ticket, caller monitor
and request correlation. Neither control process stores PCM in its state.

The existing authenticated worker request/effect/result/ack protocol remains the
sole backend-handle authority. No second backend callback runs concurrently.
Only a matching authenticated result received within the deadline can commit the
worker's latest opaque handle. One terminal result goes to the registered Session
owner; duplicate, foreign, stale or mismatched results cannot create a turn.

The backend send deadline covers framing, encoding and socket backpressure, not
just the caller's wait. A bounded worker watchdog owns cancellation independently
of the caller. Session remains in its normal GenServer loop during handoff/send.

## Close table

| Event | Disposition |
| --- | --- |
| Valid result before cancellation | Accept the one result, then close before notifying Session. |
| Cancellation before result | Fence first; retire the worker; ignore any late result; close. |
| Reservation expires before handoff | Refuse handoff, settle one timeout result, close. |
| Send deadline or hard Session timeout | Fence before retirement; close and refuse reuse. |
| Calling process dies | Session closes its owner, atomically fencing the admitted operation. |
| Session owner dies or stop is requested | ResourceOwner fences immediately and closes. |
| ResourceOwner dies | Existing worker/cleanup-lease monitors retain cleanup responsibility. |
| Close cannot be positively acknowledged | Report cleanup pending; never claim a reusable session. |

Successful send means provider bytes escaped and a response may be pending. Until
VP-07A1 owns receiving that response, this slice closes even after success. A1 can
replace that temporary terminal transition with an explicitly owned receive phase;
it must not treat send acknowledgement as conversational completion.

## Redaction and verification

Session, ResourceOwner and BackendWorker status callbacks redact current message,
logs, reasons and unapproved state fields. Tickets and worker arguments have
redacted inspection. Bounded transient copies in caller/mailbox/encoder/Mint/socket
buffers die with their respective owners.

Tests cover pure shape/byte tables, strict decoder failures, current-message crash
redaction, blocked transport stop/caller-death/hard-timeout serviceability, ticket
and generation races, and closure after ambiguous send. Security witnesses run
against both candidate and predecessor. Full voice tests, strict VOICE coverage,
changed-file formatting and umbrella warnings-as-errors compilation run in an
isolated clone with private dependency/build copies.

## Qualification — 2026-09-27

The isolated candidate passed development and test umbrella compilation with
warnings as errors, 482 Voice tests, a warning-clean 15-test xAI focused rerun,
strict VOICE coverage, changed Elixir formatting and `git diff --check`.
Four final xAI security regressions copied to predecessor `d09df63cf` fail at the
old public backend behavior: malformed output becomes audio, empty input is
sent, and conflicting declarations are ignored. The Session crash regression
also fails there because its fixture secret appears in the current-message log.
These are behavior counterexamples, not missing-new-helper failures.

An independent checkout combining this slice with conversation convergence
`11d209431` passed test compilation with warnings as errors, the focused
82-test ownership/codec lane and the complete 482-test Voice suite. The first
full replay exposed a 100 ms ExUnit scheduler wait in the existing transport
probe. Its report wait is now 1 second; the deterministic 100 ms fake-clock
deadline and exact unconsumed-message assertion are unchanged.

Evidence logs: `/private/tmp/voice-pcm-full.log`,
`/private/tmp/voice-pcm-xai-final.log`, `/private/tmp/voice-pcm-spec.log`,
`/private/tmp/voice-pcm-baseline-xai.log` and
`/private/tmp/voice-pcm-baseline-crash.log`.

## Applied learning

For a terminal operation that retires its resource owner, register the close
waiter in the same owner transition that fences cancellation. Separate
cancel-then-close calls can lose positive cleanup evidence when the owner exits
between them. A late caller may consume the exact private terminal ticket as
acknowledgment, but a bare monitor DOWN is still not proof of completed cleanup
(2026-09-27, PCM send/stop race review).
