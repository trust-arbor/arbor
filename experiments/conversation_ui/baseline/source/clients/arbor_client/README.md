# Arbor Client

A standalone Gateway transport and signing library shared by terminal renderers
and ConversationKit's remote Arbor binding. It depends on Mint, Mint WebSocket
and Jason; it does not depend on the Arbor server or a terminal UI.

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
the repository's pinned `../../bin/mix test --include slow`; the upgrade deadline
regression deliberately waits five seconds.

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
