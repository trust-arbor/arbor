# Local voice checks

The first device test uses the microphone and speaker **on the Arbor host**.
The browser control is available only on a direct localhost connection. This
does not yet capture audio from a phone or another browser device.

The native driver requires the reviewed Core and PortAudio dependency pins and
their renewed native build admission. After that adoption, select it with
`ARBOR_AUDIO_DRIVER=native` in the host environment and perform a managed Arbor
restart. Driver selection does not ask for microphone access or record audio.
The default remains `unavailable` until explicitly selected. Changing this
environment variable in a CLI process does not change the running server.

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
opening the microphone or speaker.

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

Each Desk turn reserves at most its remaining 60-second permit and the configured
session/daily ceilings. Cleanup releases unused allowance so another short turn
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
3. Choose **Test mic & speaker**. When the status says **Recording**, say a short
   phrase. Three seconds are recorded and replayed from memory. This check does
   not contact the speech provider or add a conversation turn.
4. Choose **Record voice turn** and speak a short question after **Recording**
   appears. This sends the clip to the configured speech provider and uses the
   current conversation's authority. The user/assistant transcript pair should
   appear in the same chat. Playback uses only the guarded response audio; a
   response that cannot safely be spoken remains on screen.
5. Send a typed follow-up in the same chat, then reload the page. Both voice and
   typed turns should remain in that conversation without duplicate messages.
6. Repeat once, then try **Cancel** during capture, provider processing, or
   playback. Another recording must remain blocked until device and provider
   cleanup are confirmed. Closing the tab stops renewal of the three-second
   lease; cancellation begins on the next deadline check after expiry. The server
   retains any unresolved cleanup.

The initial control uses system-default devices, mono PCM, and fixed three-second
clips. Progress cues and speech fallback are screen-only in this slice. The
normal voice turn has a fixed 60-second outer deadline; cleanup can outlive it.
Audio stays in memory, including loopback. The transcript is durable; raw audio
is not written to a temporary file or returned to the browser.

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
