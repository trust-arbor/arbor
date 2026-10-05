# ConversationKit Arbor Gateway adapter

This private connection package connects the maintained ConversationKit Arbor
adapter to Arbor's authenticated Gateway WebSocket. It depends on the
renderer-neutral `arbor_client` package and repository-relative ConversationKit
packages. It does not depend on the Arbor umbrella or a terminal renderer.
Version `0.1.0-dev` remains unpublished.

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
{:ok, connection} = ConversationKit.Arbor.Connection.start(options)
```

Keep these options and process handles inside a trusted connection owner. Only
the Connection's closed snapshots belong in renderer state. The Connection
starts with a bounded authenticated window and follows host updates; it does
not replay the complete transcript or delivery journal for native startup.
Older/newer windows use exclusive ordinal anchors and a pinned head. Latest
returns to following the host. `ConversationKit.Arbor.window/2` provides the
same read for explicit clients; `sync/1` retains its separate full-prefix API.
The shared native `ConversationKit.Composer` tracks draft revisions and stable
submission acknowledgements independently of durable transcript data.

Choose a lifetime owner that outlives its user-facing client only intentionally.
The remote process monitors that owner; its exit retires the remote process and
socket. The Connection's trusted disconnect callback closes the actual channel
on manual disconnect and retirement. `Gateway.close/1` retires the remote owner;
`Gateway.disconnect/1` closes only the channel. A surface retains an unsent draft
across manual disconnect, while access or ownership loss clears active private
state.

Signed-key mode acquires a fresh real `Signature` proof for each exact canonical
operation payload. Its raw socket independently signs the HTTP upgrade.
Configuration selects a destination; renderer events and wire messages cannot
select an identity, proof provider or backend module. Use an explicitly
provisioned signing key for this mode. Browser cookies and provider credentials
are not client credentials.

The protocol has no request correlation ID. One request may be in flight per
channel; concurrent requests return `:transport_busy`. Absolute monotonic
deadlines reach the raw send handler. Timeouts retire the channel, and an old
channel cannot satisfy a new operation. There is no automatic conversation
operation retry. A fresh channel accepts bounded windows or history, which
reestablish the client's existing engagement fence before other operations.

Window payloads use `arbor.conversation.window.v1`; existing submit, lookup,
history and events retain their exact `arbor.conversation.v2` bytes. The Gateway
window envelope has exactly `agent_id`, `engagement_id`, `entries`, `head`,
`first`, `last`, `has_older` and `has_newer`. The decoder verifies the target
before removing `agent_id`, enumerates accepted fields and statuses, and refuses
unknown nested fields. The local adapter validates window selectors, bounds,
ordering, identities, overlap consistency and engagement scope before returning
a replacement client. Transcript ordinals and journal cursors stay independent.

An unknown submit outcome retains its original ID and text. Explicit retry
first looks up that ID. A still-admitted command may be resubmitted with the
same ID to recover a failed worker start; a claimed command is never
re-executed by the host. A later refusal does not erase earlier unresolved
admission. Pending IDs are process-local; this package does not promise durable
outbox recovery after a client process or device restart.

Request deadlines are configurable: default 5 seconds, accepted range
1–60,000 ms. Socket connection and bounded close deadlines remain the shared
client's separate limits. A missing receipt does not prove that no turn
occurred. Raw wire bounds do not establish complete memory/DoS qualification.

From this package, use the pinned wrapper in an isolated source/dependency/build
copy while the server is running:

```sh
../../bin/mix deps.compile
../../bin/mix compile --warnings-as-errors
../../bin/mix test test/wire_test.exs test/gateway_test.exs --seed 0
```

The standalone tests cover closed JSON normalization and semantic validation,
real local TCP/Socket signatures, bounded-window startup, target tampering and
recovery, engagement fencing, reattachment, deadlines, late replies, concurrency
and session authorization loss. Their scripted TCP peers are transport unit
fixtures. A separate host integration lane uses real Gateway authentication,
linked identities, Agent/Session/Engine and persistence. Physical terminal,
microphone and live-provider acceptance remain separate gates.

## Human session mode

Use `session: login_session` instead of `identity:` after `Arbor.Client` finishes
the Gateway-hosted device flow. Its target must equal the connection's configured
target. The private owner holds the opaque credential; conversation frames
contain only the canonical payload and `authentication: "conversation_session"`.
The credential appears only in the SDK's upgrade header. The host validates
fresh authority for every operation and publication. Rendered snapshots contain
no credential. Signed-key mode remains available unchanged.

The maintained opt-in `clients/arbor_breeze` launcher accepts `--url URL --agent
ID` for human device sign-in, or `--key FILE` for explicit signed-key mode.
It prints only public verification instructions, polls within flow expiry,
cancels failed flows, and closes its connection before attempting logout on
ordinary exit. It never writes provider tokens or credentials. The archived
comparison launcher is historical evidence and is not a production entrypoint.

## Scoped controls over the same private channel

Activity, cancellation, prompt discovery, ordinary choices and protected answer
requests use the SDK's closed canonical control payloads and the agreed
`conversation_activity`, `conversation_cancellation`,
`conversation_interactions` and `conversation_interaction_answer` events. Each
reply must match the authenticated target and attached engagement. Empty prompt
lists include the exact command; answers include exact command, request,
operation and integer revision. Cancellation is a single command observation,
with delivery and cancellation kept separate. V2 cancellation journal DTOs are
read without inventing a completed delivery.

Control reply data is at most 131584 bytes (128 KiB host data plus the added
agent field); the local adapter applies its own host/aggregate limits. Closed
JSON decoding rejects duplicate keys at every depth, unknown fields, enum
values and malformed correlation. Invalid replies retire the actual channel;
late replies and older generations cannot fulfill a later request. Unknown
errors remain generic fixed atoms without server bodies or proof material.

`client_options/1` always supplies `approval_answer_allowed: false`. A terminal
human login lease is chat-only: protected approval is refused before a frame is
sent with `:approval_answer_required`. Its UI should show browser review. Signed
approval payloads can be created, but the host's protected general-human gate
still applies. No credential upgrade or bypass is provided here.

New tests include actual SDK Socket control round trips with fresh signatures,
exact empty-list matching, wrong-answer channel retirement, chat-lease approval
refusal and conservative explicit recovery. Their private scripted TCP peer
qualifies transport behavior, not host human identity issuance or production
network availability. Run all package tests with `../../bin/mix test` in an
isolated source, dependency and build image.
