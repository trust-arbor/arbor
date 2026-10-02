# Arbor Voice

`Arbor.Voice.start_desk_turn/3` runs one authenticated, bounded microphone turn
on the server's audio device. It returns an opaque operation ID immediately;
`desk_turn_status/1` renews a three-second controller lease and returns metadata,
while `cancel_desk_turn/1` revokes that exact operation. Poll at least once per
second. An operation defaults to a fixed 120-second deadline. No PCM crosses
these control APIs.

Provide exactly one `session_token` or purpose-bound `signed_request`, plus the
principal and agent IDs. Signed requests are exchanged through the Security
facade on the server. Optional `expected_engagement_id` pins an already displayed
conversation before microphone capture. `origin_node` must have the server's
exact host component; this locality check supplements authentication. Public
options cannot select collaborators or override ownership.

The default `:conversation` mode captures mono signed 16-bit little-endian PCM at
16 kHz, opens a fresh Voice Session bound to the same immutable conversation,
executes `audio_turn`, waits for positive Session cleanup, and presents only the
guarded final provider audio. Text-only, rewritten, truncated, or sensitive
presentation uses the screen. `mode: :loopback` records and replays the same
bounded clip without a provider call or transcript append. Capture duration is
100–10,000 milliseconds; input/output device IDs default to `:default`.

Only `terminal: true` confirms this operation's cleanup. `:cleanup_pending`
retains the exclusive slot; process disappearance alone never proves closure.
Completed conversation text remains subject to fresh authorization on every
status read. Operation records retire after sixty seconds. Ordinary process
status and crash diagnostics are redacted; privileged VM debugging is outside
this boundary.

The 2026-09-27 initial desk slice keeps fixed progress cues and speech fallback
on screen. It does not qualify audible fixed cues, fallback TTS, interruption of
existing speech, or the full VP-07C presentation matrix. Native device opt-in,
OS permission, real hardware, and provider acceptance remain separate gates;
starting Voice itself performs none of these effects.

## Time allowances

Operator configuration sets finite allowances for a full Agent consultation,
the provider audio turn, and the enclosing capture-to-presentation Desk:

```elixir
config :arbor_voice,
  tool_router_timeout_ms: 60_000,
  audio_turn_timeout_ms: 90_000,
  desk_timeout_ms: 120_000
```

These are the defaults. Hard maxima are 300,000 / 330,000 / 360,000 ms,
respectively. Consultation includes authorization, memory and preprocessing,
model/tool work, and durable completion. The defaults tolerate ordinary
preparation and provider latency; they do not guarantee a provider responds
within 60 seconds. Progress remains a single cue after 2 seconds.

Every inner deadline is shortened by its enclosing deadline and the remaining
Session/daily allowance. The exact audio deadline reaches ResourceOwner without
renewal while queued. Tool activation and Agent delivery use its remaining time;
cancellation discards late output and keeps the existing positive-cleanup gate.
The physical send/receive and cleanup bounds are unchanged.

`start_session/3` accepts tool/audio timeout overrides. An explicit operator
setting is their ceiling; absent it, the source-owned maximum applies. Desk
callers cannot raise the operator permit. Invalid configuration fails before
capture or network startup. A shorter enclosing allowance always wins, including
when it is smaller than a configured inner allowance.
