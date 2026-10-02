# ConversationKit Arbor Gateway adapter spike

This private package connects the existing ConversationKit Arbor adapter to
Arbor's signed Gateway WebSocket. It depends on the renderer-neutral
`arbor_client` package, not a terminal renderer or the Arbor umbrella. The
relative dependency path is for this isolated experiment.

```elixir
{:ok, remote} =
  ConversationKit.Arbor.Gateway.start_link(
    owner: self(),
    identity: private_identity,
    target: "agent_...",
    gateway_url: "wss://gateway.example",
    request_timeout_ms: 5_000
  )

{:ok, options} = ConversationKit.Arbor.Gateway.client_options(remote)
{:ok, client} = ConversationDemo.ArborClient.start(options)
# Or pass caller, target, proof_provider and adapter_options to Kit.Arbor.new/4.
```

Keep these options and process handles inside the trusted connection owner.
Only Demo's closed snapshots belong in renderer state. Choose a lifetime owner
that outlives its user-facing client only intentionally. The remote process
monitors that lifetime owner; its exit retires the remote process and socket.
The optional trusted Demo disconnect callback closes the actual socket on F4
and on Demo client retirement. `Gateway.close/1` retires the remote owner;
`Gateway.disconnect/1` closes only the channel.

Each operation acquires a fresh real `Signature` proof for the exact canonical
payload. The raw socket independently signs the HTTP upgrade. Configuration
selects a destination; neither rendered events nor wire messages can select an
identity, proof provider or backend module. Use a separately provisioned and
linked human key, not browser cookies or provider credentials.

The protocol has no request correlation ID. There is one in-flight request per
channel; concurrent requests return `:transport_busy`. Absolute monotonic
deadlines reach the raw send handler. Timeouts retire the channel, and old
channel messages cannot satisfy a new operation. There is no automatic
operation retry. A fresh channel accepts history only; call `Kit.sync/1` to
reattach with the client's existing engagement fence before command reads or
submissions. JSON conversion enumerates fields and statuses; Kit still checks
scope, transitions and both independent cursor streams.

Unknown submit outcomes retain the original ID and text. A saved
`:admitted` command may be resubmitted with that same ID to recover a failed
worker start; already-claimed commands are never re-executed by the host.
A later refusal does not erase an earlier unresolved admission. Pending IDs
are currently process-local; this spike does not promise durable outbox
recovery after a client process or device restart.

Request deadlines are configurable (default 5 seconds, accepted range
1–60,000 ms). Socket connection and bounded close deadlines remain the shared
client's separate limits. Receipt failure is not proof that no turn occurred.
Raw wire bounds do not claim complete memory/DoS qualification.

Focused selectors, from this package with the pinned wrapper:

```sh
../../source/bin/mix test test/wire_test.exs test/gateway_test.exs --seed 0
```

Eleven tests cover closed JSON normalization, real TCP/Socket signatures,
reattachment, late replies, concurrent operation refusal and an expired queued
submit. The scripted TCP peer is only a transport unit fixture. The separate
host integration lane uses real Gateway authentication, linked identities,
Agent/Session/Engine and persistence; native Breeze and physical Voice
acceptance remain explicit additional gates.

## Human session mode

Use `session: login_session` in place of `identity:` after `Arbor.Client.Login`
finishes the Gateway-hosted device flow. Its target must equal this connection's
configured target. The private proof callback holds the opaque credential; each
wire frame contains only the canonical payload and `authentication:
"conversation_session"`. The host validates fresh conversation authority on
every operation and before publication. Neither rendered snapshots nor chat
frames contain the credential. Signed-key mode remains available unchanged.

The standalone `integration/remote_breeze.exs` launcher accepts `--gateway URL
--agent ID` for human login, or adds `--key FILE` for the existing key mode. It
prints bounded public verification instructions, polls within the flow expiry,
cancels failed flows and closes the socket before logout on ordinary exit. It
starts client dependencies only, does not open a browser automatically and never
writes credentials or provider tokens.
