# Local voice checks

The first device test uses the microphone and speaker **on the Arbor host**.
The browser control is available only on a direct localhost connection. This
does not yet capture audio from a phone or another browser device.

The current Arbor-owned Git pins are Membrane Core
`c2e9c7aff031dd600d2318b72193a4825b0da95f` and PortAudio
`1270de06ce99f3cd025a4416239f85986e7e4589`. Use a qualified native build for
those exact pins and the current Arbor sources; a lockfile or source checkout
alone does not establish the loaded code or native library identity. Select the
driver with `ARBOR_AUDIO_DRIVER=native` in the host environment and perform a
managed Arbor restart. Driver selection does not ask for microphone access or
record audio. The default remains `unavailable` until explicitly selected.
Changing this environment variable in a CLI process does not change the running
server.

When changing the media dependency pins, explicitly rebuild their compiled
artifacts before restarting:

```sh
./bin/mix deps.compile membrane_core membrane_portaudio_plugin --force
./bin/mix arbor.restart
```

Do this between audio operations. A clean dependency checkout and a successful
application restart can still reuse old dependency BEAMs. In the restarted
operator console, both `Membrane.PortAudio.Source.__struct__()` and
`Membrane.PortAudio.Sink.__struct__()` must include `:executor_identity`,
`:startup_token`, and `:stream_token`. This checks the loaded API without
opening the microphone or speaker. With the current native driver selected,
`Arbor.Multimedia.manual_capture_finish_supported?/0` should return `true`;
that capability check does not open a device or establish OS permission.

Loopback needs no speech-provider credentials. The default conversation backend
uses xAI OAuth; check `./bin/mix arbor.login status` for `xai_oauth` readiness.
The selected agent also needs its normal conversation and provider-egress
authorization. A configured API key alone does not establish OAuth readiness;
the voice control does not create identities or grant missing permissions.

Conversation turns also require the durable daily voice-budget ledger. The
non-test `ARBOR_AUDIO_DRIVER=native` boot setting selects
`Arbor.Persistence.QueryableStore.Postgres` with the canonical
`Arbor.Persistence.Repo` (the adapter supports both Arbor SQL database modes).
The Repo must be running with its migrations applied. In a connected operator
console, check `Arbor.Voice.BudgetLedger.readiness()` for
`{:ok, %{durability: :node_restart}}`, then verify an actual read using
`Arbor.Voice.BudgetLedger.remaining(user_id, Date.to_iso8601(Date.utc_today()), daily_ms)`
with the signed-in user's ID and the configured daily allowance. Readiness
attests the backend contract; only the read checks that the running database is
available. Neither check records audio, contacts a speech provider, or reserves
allowance. Loopback alone does not test this prerequisite.

Each Desk turn reserves at most its remaining configured Desk permit and the
configured session/daily ceilings. Cleanup releases unused allowance so another short turn
can begin; the daily consumed total remains durable.

## Browser

1. Open `http://localhost:4001`, sign in, and open an authorized private agent
   conversation. The intended agent must already be running, and your signed-in
   identity must have chat permission for that specific agent. If it is stopped,
   ask an operator to resume it with `./bin/mix arbor.agent resume <agent-id>`
   from the server's checkout, then reopen the conversation. **View conversation**
   in Agents only opens history; it does not start an agent or grant permission.
2. In **Local voice check**, choose **Check mic access**. Use **Allow microphone**
   only when you want macOS to request access. Respond to the OS prompt and check
   access again. If denied, update the host application's permission under
   macOS **Privacy & Security → Microphone**.
3. Choose **Recording length (seconds)**, then **Test mic & speaker**. The default
   is 10 seconds; the field shows the operator's allowed range (normally 0.1–30
   seconds). Decimal seconds are accepted to millisecond precision. Wait through
   **Starting microphone—wait to speak.** until the **Recording / speak now** cue
   appears, then say a short phrase. The cue confirms the first valid PCM sample
   delivery, not audio quality or completed capture. The chosen duration is
   recorded and replayed from memory; this check does not contact the speech
   provider or add a conversation turn.
4. Choose **Record voice turn**, wait for the same speak-now cue, and ask a short
   question. This sends the clip to the configured speech provider and uses the
   current conversation's authority. The user/assistant transcript pair should
   appear in the same chat. Only exact, guarded final response audio is played.
   The UI distinguishes **response finished playing through the host speaker**
   from **response is on screen; no audio was played**. Check actual audibility
   separately; a successful text result does not prove playback.
5. Send a typed follow-up in the same chat, then reload the page. Both voice and
   typed turns should remain in that conversation without duplicate messages.
6. Repeat once and verify your recording length stays selected, then try **Cancel**
   during capture, provider processing, or
   playback. Another recording must remain blocked until device and provider
   cleanup are confirmed. Closing the tab stops renewal of the three-second
   lease; cancellation begins on the next deadline check after expiry. The server
   retains any unresolved cleanup.

The control uses system-default devices and mono PCM. Your recording-length
choice stays in the current LiveView across turns; reopening or reloading the
page restores the operator default. The selector is locked during an operation,
and the server checks the current configured interval again before capture.
Progress cues are displayed on screen; this slice does not synthesize fallback
TTS. Cleanup can outlive an operation's deadline.
Audio stays in memory, including loopback. The transcript is durable; raw audio
is not written to a temporary file or returned to the browser.

Operators can set these Application settings in the server's configuration:

```elixir
config :arbor_voice,
  desk_recording_default_ms: 10_000,
  desk_recording_min_ms: 100,
  desk_recording_max_ms: 30_000,
  audio_speech_max_words: nil
```

All three values must be integers with
`100 <= min <= default <= max <= 30_000`. Invalid configuration disables
recording; a submitted duration outside the interval is rejected before capture.
`Arbor.Voice.desk_recording_options/0` returns the validated policy. The native
device path already supports 30 seconds at the Desk's 16 kHz mono PCM format.
These limits do not change the independent voice budget or operation deadlines.
Existing `:tool_router_timeout_ms`, `:audio_turn_timeout_ms`, and
`:desk_timeout_ms` defaults are 60,000, 90,000, and 120,000 ms, respectively;
their existing validation and remaining-budget clipping still apply. They are
operator settings, not controls in the recording-length field. Every inner
allowance is shortened by the enclosing deadline and remaining Session/daily
budget; recording settings do not renew an active permit.

PCM final speech defaults to `audio_speech_max_words: nil`, which disables word
truncation while retaining text/PCM byte bounds and all speech guards. A positive
cap must be an integer of at least eight words. The PCM `start_session/3` option,
or operator `desk_session_options: [audio_speech_max_words: 120]`, overrides the
Application default. The option is rejected on text Sessions; text turns and
fixed cues keep the legacy 60-word default. Provider PCM plays only when its
terminal text, final authoritative reply and guarded speech text match exactly
and its authorized format is valid. Truncation, rewriting, sensitivity
restrictions or missing audio withhold PCM; durable conversation text is kept.

**Cancel discards capture; it does not finish and send a shorter recording.**
The current native path exposes **Finish and send** during a voice recording,
or **Finish and play** during loopback, after the device owner issues its private
control and status reports `can_finish: true`. The current Core/PortAudio pins
include manual finish; the running host still needs the matching qualified build.
Control delivery alone is not a speak-now cue. Finish may be requested before the
first-sample receipt, but acknowledgement does not prove capture or cleanup has
completed; the status stays **Finishing** until capture closes. Drivers without
manual-finish support keep timed capture and do not expose this button.

Test early finish after speaking, then verify the whole shorter clip plays or
becomes one voice turn. The device
path joins the exact stopped frame count with queued PCM and confirmed native
closure before proceeding. Finishing before the configured minimum returns a
short-recording error after cleanup and does not call the provider. The selected
recording length remains the maximum and its existing deadline is not extended.
A cancelled recording cannot later become a successful partial recording.

`Arbor.Multimedia.capture_pcm/2` accepts a local controller and minimum duration;
`finish_capture/1` acknowledges only the finish request. It never returns PCM or
attests cleanup. `Arbor.Voice.finish_desk_turn/1` rechecks conversation access and
uses that private control. Public status exposes `can_finish`, `:preparing_capture`
before sample readiness and `:finishing` after a Finish request, plus ordinary
bounded metadata. The device control and audio remain server-side.

## CLI

The CLI is an alternative for an existing registered human operator signing key
with chat permission for the target agent. OIDC deployments should use the
signed-in browser unless such a key is already available; this command does not
create identities or grant permission.
Run these commands from the candidate checkout used by the managed server.

```sh
./bin/mix arbor.voice devices
./bin/mix arbor.voice permission
./bin/mix arbor.voice permission --request
./bin/mix arbor.voice talk agent_ID --loopback --seconds 3 --key-file /path/to/operator.key
./bin/mix arbor.voice talk agent_ID --seconds 3 --key-file /path/to/operator.key
```

`--input ID` and `--output ID` select enumerated devices. `--seconds` accepts 1–10.
The default key path is `~/.arbor/operator.key`. The command talks to the already
running local server and renews the operation lease while waiting. It never
transports raw PCM or a reusable session token over RPC. The server exchanges
the signed request for a short-lived proof limited to the selected conversation.

## What a successful check establishes

Audible loopback establishes that the selected physical device path works on
this host. A successful voice question adds the provider and durable conversation
path. Automated fake-device/provider tests cover lifecycle and authorization
races; they cannot establish microphone quality, audible output, provider
latency, or the macOS permission dialog. Record those observations separately
before marking physical voice qualification complete.

For each manual check, record whether capture and playback were audible, whether
the transcript matched, and whether cancellation allowed a fresh attempt after
cleanup. If the interface stays at **Cleanup pending**, preserve the operation
status for diagnosis; restarting or clearing the device fence would not establish
that its resources closed.
