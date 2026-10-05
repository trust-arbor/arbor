# Arbor Client

A standalone Gateway transport and signing library shared by terminal renderers
and ConversationKit's remote Arbor binding. Version `0.1.0-dev` is maintained in
`clients/arbor_client` and has not been published to Hex. It depends on Mint, Mint
WebSocket and Jason; it does not depend on the Arbor server or a terminal UI.

For another project in this checkout, add a path dependency relative to that
project's `mix.exs`, for example from a sibling client:

```elixir
{:arbor_client, path: "../arbor_client"}
```

`Arbor.Client` is the public facade for login, socket transport, signing and wire
encoding. The existing `Login`, `Socket`, `Signer` and `Protocol` modules remain
available for compatibility. This library deliberately leaves transcript state,
delivery reconciliation and UI rendering to its caller. A caller must validate
host response schemas before updating private conversation state.

`Arbor.Client.Signer.load_key/1` loads regular, owner-private key files and retains
either an `agent_` or `human_` proof subject. `authorization_for_payload/2` makes
a fresh one-use signature for the exact operation payload. The host remains the
authority for linked identity, canonical engagement and every operation grant.

`Arbor.Client.Socket.start_link/1` requires `owner:`, `identity:` and
`gateway_url:`. Its owner receives `{:arbor_socket, socket_pid, :connected}`,
`{:arbor_socket, socket_pid, {:frame, text}}` and a final closed event with a
bounded reason atom. `send_frame/3` accepts an absolute monotonic millisecond
deadline and checks it in the actual send handler. Only the owner may send.
`close/1` synchronously retires the exact socket generation; `:ok` means it has
exited, while `{:error, :close_failed}` is not a closure receipt. Owner exit also
retires the socket.

The socket has no conversation reducer, retry, reconnect or replay policy. A
caller must preserve separate transcript and journal cursors, fence canonical
engagement, and reconcile uncertain delivery using the original command ID.
Because wire replies have no request ID, the ConversationKit binding admits one
request at a time and retires a timed-out generation before another request.
The legacy TUI compatibility owner retains its existing renderer policy.
Session upgrade alone may retry an HTTP 409 while a previous socket retires,
within the original five-second connection deadline and cumulative wire budget.
It never retries a conversation operation or follows a redirect.

Plain `ws` is accepted only for loopback; remote hosts require `wss` with Mint's
normal certificate verification. Upgrade is bounded by one five-second deadline
and 64 KiB of transport data before upgrade, outgoing operation text by 256 KiB,
and incoming text by 8 MiB / 128 WebSocket fragments. Fragment headers are
checked before Mint accumulates payload. Binary frames and compression are not
accepted. Transport errors and system status do not expose identity or frames.

The tests use disposable local TCP peers and throwaway keys. They do not require
a running Gateway, operator credentials, external network or terminal. Run with
the repository's pinned wrapper from this directory:

```sh
../../bin/mix deps.compile
../../bin/mix compile --warnings-as-errors
../../bin/mix test --include slow
```

Use a private source/dependency/build copy while the Arbor server is running.
The committed standalone lock selects the tested graph independently of the
umbrella. The upgrade deadline regression deliberately waits five seconds.

## Conversation protocol

`Arbor.Client.conversation_payload/5` preserves the canonical
`arbor.conversation.v2` submit, lookup, history and events payloads. Commands keep
their original delivery ID across an uncertain result; a reconnecting owner
must look up that ID before considering an exact retry. Transcript ordinals and
journal cursors are independent.

`Arbor.Client.conversation_window_payload/3` encodes the separately versioned
`arbor.conversation.window.v1` read. `before:` and `after:` are exclusive
transcript ordinals; omit both to read the newest entries. `through:` pins the
observed transcript head and `expected_engagement_id:` fences the conversation
owner. The Gateway defaults `limit:` to 20 and accepts 1 through 100. It validates
selectors; the codec does not invent local entries or pagination metadata.

```elixir
Arbor.Client.conversation_window_payload("human_owner", "agent_target",
  before: 41,
  through: 60,
  limit: 20,
  expected_engagement_id: "eng_current"
)
```

Use `signed_operation/5` with `:window` for signed-key mode, or the payload as the
session-authenticated conversation operation's payload. `decode/1` returns
`{:ok, {:conversation_window, page}}`, preserving the Gateway's `agent_id`,
`engagement_id`, `entries`, `head`, `first`, `last`, `has_older` and `has_newer` fields. Window
entries retain host message IDs and ordinals. This codec addition does not
change the v2 full-history or event response formats.

## Human device login

`Arbor.Client.Login.start(gateway_url, target)` returns a redacted `Pending`
struct. Print only its `verification_uri` and `user_code`; never print its
private `handle`. Poll with `Login.poll/2` at the supplied interval until it
returns a redacted `Session` struct. Failed or cancelled flows use `cancel/2`.
The host performs OIDC; this standalone client never receives provider tokens
or signing keys. The receipt declares `lifetime: :connection`. The host keeps
the session while its authenticated socket is healthy, including idle periods,
and enforces initial-attachment and reconnect deadlines itself. There is no
client wall-clock expiry. `logout/2` accepts the Session or its opaque credential.

Pass `session: session` instead of `identity:` to `Socket.start_link/1`; both
options together are refused. Session authorization appears only in the upgrade
header. Login and session mode require TLS except for literal loopback addresses
127.0.0.1 and ::1. Signed-key mode retains its localhost compatibility. HTTP and
WebSocket schemes select the same fixed Gateway origin; redirects, URL secrets,
queries and arbitrary paths are rejected. Provider verification links may have
queries and are printed without opening a browser automatically.

HTTP start has a 35-second deadline to accommodate bounded host discovery; poll,
cancel and logout each have five seconds. Responses have closed schemas,
canonical 32-byte handles/credentials, a 16 KiB body/header limit and a 64 KiB
wire limit checked before Mint parsing. JSON duplicate keys and content encoding
are refused. Public errors are fixed atoms. Socket ownership, keepalives and
bounded reconnect grace cover ordinary failure; abrupt VM termination cannot
promise a logout receipt. A revoked grant, host restart or expired reconnect
window requires a new login; no command is automatically replayed.

## Conversation controls

After a history or window attaches the socket, use `conversation_payload/5`
with the operations below. `signed_operation/5` creates a fresh signature;
`session_operation/5` creates the closed session-mode envelope using the
socket's server-held proof. Neither function sends or retries an operation.

| Operation | Input | Options beyond `expected_engagement_id:` |
| --- | --- | --- |
| `:activity` | `nil` | `cursor: %{admitted_event_number: n, command_id: id}`, `limit: 1..50`, `control_timeout: 1..30_000` |
| `:cancel` | Command ID | `control_timeout: 1..30_000` |
| `:interactions` | Command ID | None |
| `:interaction_choice` | Exact map of `command_id`, `request_id`, `operation_id`, `revision: 1`, `choice_id` | None |
| `:interaction_approval` | Exact map of `command_id`, `request_id`, `operation_id`, `revision: 1`, `decision`, `note` | None |

New control payloads reject extra keys, duplicate options, oversized values and
caller-supplied proof fields with `{:error, :invalid_control_request}`. They
preserve every accepted identifier without trimming or replacing it. Choices
use IDs, so duplicate display labels never select an answer. Approval decisions
are `approve`, `deny` or `rework` as atoms or strings. Notes are `nil` or valid
UTF-8 up to 1,024 bytes with no ASCII controls. The host remains responsible
for current source, expiry, choice membership, authorization and one-use answers.

Replies decode as `:conversation_activity`, `:conversation_cancellation`,
`:conversation_interactions` or `:conversation_interaction_answer` with the
host's result map. All carry authenticated `agent_id` and `engagement_id`.
Prompt reads retain `command_id` even when empty; answers additionally retain
`request_id`, `operation_id` and `revision`. Control data is bounded to 131,584
bytes, including Gateway correlation metadata. Activity and prompt lists contain
at most 50 entries. A cancellation `requested` result with `unconfirmed`
termination does not mean execution has stopped.

Serialize operations and retire a timed-out socket before sending another;
a late generic error must not be interpreted as the next operation's result.
Use a fresh read before explicitly retrying an answer. Terminal chat leases
cannot answer protected approvals, and a signed payload cannot substitute for
a general human session plus its original approval capability. This package
does not introduce a broader login or approval flow.

## Release boundary

The package metadata includes the MIT license, README and owned source files.
Publishing requires a separate release decision; this development version is
consumed from source. Gateway authorization and host session compatibility must
be qualified independently of these local transport tests. No identity provider
tokens, signing keys, provider calls or live server state are needed for the
standalone suite.

Signed discovery and operator HTTP calls are available through the public facade:

```elixir
{:ok, identity} = Arbor.Client.load_key("/private/operator.arbor.key")
{:ok, %{agents: agents, truncated: false}} = Arbor.Client.list_agents(identity, gateway_url)
{:ok, exact_target} = Arbor.Client.resolve_agent(identity, gateway_url, "cedar")
{:ok, %{aliases: aliases}} = Arbor.Client.list_aliases(identity, gateway_url)
Arbor.Client.set_alias(identity, gateway_url, "cedar", exact_target)
Arbor.Client.remove_alias(identity, gateway_url, "cedar")
Arbor.Client.create_agent(identity, gateway_url, %{template: "researcher", name: "Cedar"})
Arbor.Client.start_agent(identity, gateway_url, exact_target)
Arbor.Client.stop_agent(identity, gateway_url, exact_target)
```

These calls accept only an explicit signing identity, never a human conversation
session or bearer credential. Discovery and aliases belong to that exact signing
principal; a linked human's navigation or ownership does not confer operator
capabilities. The Gateway independently checks create, restore, and exact-target
stop capabilities for every command. Pending approval returns
`{:error, :approval_required}` without a continuation or automatic retry.

Every request signs the exact method, encoded path, and once-encoded body with a
fresh nonce. Calls use one owned HTTP connection and one total deadline, close
on all outcomes, and never follow redirects or retry. Options are closed to
`timeout_ms: 1..30_000` (default 10,000) and `max_entries: 1..100` (default 50).
Response bodies are bounded to 128 KiB, headers to 16 KiB, and received wire
bytes to 256 KiB. Catalog results expose `truncated: true` when the row limit is
reached; the existing host directory has no cursor API. An oversized or malformed
reply is an error, not an invented partial directory.

A mutation whose response cannot be confirmed returns
`{:error, :management_unconfirmed}`. It may have taken effect. Inspect the agent
list, aliases, or authenticated Console before explicitly deciding to issue a
new command. The host has no idempotent lifecycle request API, so the client
never retries these mutations automatically. These APIs do not switch an active
conversation or migrate its transcript, pending request, or draft.
