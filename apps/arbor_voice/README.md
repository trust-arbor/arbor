# Arbor Voice

`Arbor.Voice.start_desk_turn/3` runs one authenticated, bounded microphone turn
on the server's audio device. It returns an opaque operation ID immediately;
`desk_turn_status/1` renews a three-second controller lease and returns metadata.
Poll at least once per second. `finish_desk_turn/1` requests early recording
completion; `cancel_desk_turn/1` revokes that exact operation. No PCM crosses
these control APIs. The enclosing Desk deadline is configurable and defaults
to 120,000 milliseconds.

Provide exactly one `session_token` or purpose-bound `signed_request`, plus the
principal and agent IDs. Signed requests are exchanged through the Security
facade on the server. Optional `expected_engagement_id` pins an already displayed
conversation before capture. `origin_node`, when provided, must have the server's
exact host component; this locality check supplements authentication. Public
options cannot select collaborators or override ownership.

## Recording and controls

The default `:conversation` mode captures mono signed 16-bit little-endian PCM at
16 kHz, opens a fresh Voice Session bound to the same immutable conversation,
executes `audio_turn`, waits for positive Session cleanup, and presents the guarded
final response. `mode: :loopback` records and replays the same bounded clip without
a provider call or transcript append. Input/output device IDs default to `:default`.
Both modes use the microphone and speaker on the Arbor host. The current
Dashboard controls require a direct local connection; phone or remote-browser
capture is not implemented.

Recording defaults to 10,000 ms. The native interval is 100–30,000 ms; operator
configuration may narrow it and choose a default within that interval. Callers
select `duration_ms` within the effective policy. The dashboard shows the effective
range in seconds and keeps the selected duration for subsequent turns while that
page is open. Recording length does not extend the enclosing deadline or budget.

The initial cue is "Starting microphone—wait to speak." It changes to a speak-now
cue only after the first authenticated valid nonempty PCM sample delivery for the
matching active capture. Receiving a finish control alone is not readiness, and
sample delivery proves neither audio quality nor capture completion. A driver
without that receipt remains in `:preparing_capture` until its timed capture ends.

When the driver supports manual finish, status exposes `can_finish: true`. Finish
may be requested before the sample-delivery receipt; the UI then remains in
`:finishing`. Its acknowledgement is not capture or cleanup completion. Captured
bytes must still meet the configured minimum duration, and short recordings fail
after cleanup rather than padding silence. "Finish and send" or "Finish and play"
continues only after positive microphone closure. Cancel stops the current audio
operation and discards uncommitted capture; any conversation text already saved
is retained. Neither Finish nor Cancel makes a new recording safe before cleanup.

Only `terminal: true` confirms the Desk operation's cleanup. `:cleanup_pending`
retains the exclusive slot; process disappearance alone never proves closure.
Completed conversation text remains subject to fresh authorization on every
status read. Completed operation records retire after sixty seconds. Ordinary process
status and crash diagnostics are redacted; privileged VM debugging is outside
this boundary.

## Configuration and time allowances

These are the default Application settings; durations and allowances are in ms:

```elixir
config :arbor_voice,
  desk_recording_min_ms: 100,
  desk_recording_default_ms: 10_000,
  desk_recording_max_ms: 30_000,
  tool_router_timeout_ms: 60_000,
  audio_turn_timeout_ms: 90_000,
  desk_timeout_ms: 120_000,
  audio_speech_max_words: nil
```

The recording policy must satisfy `100 <= min <= default <= max <= 30_000`.
The hard maxima for consultation, the audio turn, and the enclosing Desk are
300,000 / 330,000 / 360,000 ms, respectively. Consultation includes authorization,
memory and preprocessing, model/tool work, and durable completion. These are
allowances, not guaranteed response times. The progress cue threshold defaults
to 2,000 ms.

Every inner deadline is shortened by its enclosing deadline and the remaining
Session/daily allowance. The exact audio deadline reaches ResourceOwner without
renewal while queued. Tool activation and Agent delivery use its remaining time;
cancellation discards late output and retains the positive-cleanup gate. Changing
recording or timeout settings does not renew an active operation's permit.

`start_session/3` accepts tool/audio timeout overrides. An explicit operator
setting is their ceiling; absent it, the source-owned maximum applies. Desk
callers cannot raise the operator permit. Invalid recording/time configuration
fails before capture. A shorter enclosing allowance always wins, even when it is
smaller than a configured inner allowance.

## Final speech presentation

`audio_speech_max_words` controls only the final speech of a PCM Session. Its
default `nil` disables word truncation; existing text/PCM byte bounds, sensitivity
classification, format checks, and fresh conversation authorization still apply.
A positive cap must be an integer of at least eight words so the stock guard
pointers fit. Invalid values fail before PCM Session resource/backend effects.

The public PCM Session option overrides the Application setting, including an
explicit `nil`. For example:

```elixir
Arbor.Voice.start_session(user_id, agent_id,
  session_token: session_token,
  audio_mode: :pcm16,
  audio_speech_max_words: 120
)
```

Operators may also set `desk_session_options: [audio_speech_max_words: 120]` for
Desk-created Sessions. The option is rejected on text Sessions, even when `nil`;
text turns and fixed progress cues retain Speakable's legacy 60-word default.

Provider PCM is retained only when its terminal text, the final authoritative
reply, and the guarded speech text match exactly, with the authorized valid
format. Rewriting, truncation, sensitivity restrictions, missing audio, or a
failed guard withholds provider PCM. Speech presentation never rewrites durable
conversation text. There is no fallback TTS that synthesizes a replacement in
this Desk slice.

The dashboard distinguishes a response that finished playing through the host
speaker from one displayed on screen with no audio played. Loopback has its own
finished-playing message. A displayed completion message is not an independent
operator audibility or audio-quality test.

Native device opt-in, OS permission, real hardware, and provider acceptance remain
separate gates; starting Voice itself performs none of these effects. Fixed cues
are displayed on screen. Audible fixed cues, fallback TTS, automatic barge-in or
interruption of a separate prior speech stream, and the full VP-07C presentation
matrix remain outside this Desk slice. Cancel can stop this Desk's own playback.
