# ConversationKit Arbor adapter

An independently packaged adapter connecting ConversationKit semantic views to
Arbor's authenticated durable conversation API. Its only Mix dependency is
`{:conversation_kit, path: "../core"}`. It has no Arbor compile dependency and no
Phoenix, Breeze, DASP, HTTP, or audio dependency. The default trusted facade is
`Arbor.Agent`; a host process must make that facade available at runtime.

```elixir
proof_provider = fn request ->
  # Fetch a current session token, or sign request with a NEW nonce each time.
  # request includes operation, caller, target, input, and paging options.
  {:ok, [session_token: current_token(request.caller)]}
end

{:ok, client} = ConversationKit.Arbor.new(human_id, agent_id, proof_provider)
{:ok, client} = ConversationKit.Arbor.sync(client)
snapshot = ConversationKit.Arbor.projection(client)
%{history: ordinal, commands: cursor} = ConversationKit.Arbor.position(client)

# The interface owner generates and retains this ID BEFORE the first request.
{:ok, client, delivery} = ConversationKit.Arbor.submit(client, stable_id, text)
{:ok, client, delivery} = ConversationKit.Arbor.command(client, stable_id)
```

`new/4`, `sync/1`, `submit/3`, and `command/2` return `{:error, safe_atom}` on
failure. Successful submit/read return `{:ok, new_client, semantic_delivery}`.
Submission requires an already pinned scope: call `sync/1` successfully first.
An unbound submit returns `:conversation_not_attached` without acquiring proof or
calling the host. A failed initial sync must leave the interface disconnected.
There is no implicit submission retry, locally generated command ID, or
optimistic transcript insertion. Identical submissions must retain their ID and
text. An ambiguous submit failure can already have admitted the command: keep
the outbox, read that ID, and only resubmit the same input when the host reports
`:not_found`. An acknowledged `:admitted` response permits clearing the ambiguous
outbox; delivery status remains visible independently.

Keep the client and proof closure in a trusted process. **Do not place them in
LiveView assigns, Breeze state, logs, URLs, renderer messages, or a serialized
checkpoint.** `Inspect` intentionally hides the complete client. Only
`projection/1`, `position/1`, and `sync_status/1` are display-safe. A renderer
owner must clear its private cache/outbox on `:unauthorized` or
`:conversation_scope_changed`; the immutable
adapter cannot erase the caller's previously held value. Scope mismatch or
conflicting response should also invalidate the displayed cache. Proof-provider
exceptions and arbitrary host errors become bounded error atoms.

The proof provider receives a new context on **every actual host call**, even
page-size retries. It must return exactly one proof, `{:ok, [session_token: t]}`
or `{:ok, [signed_request: r]}`. It can return `{:error, :unauthorized}` to signal
revocation. Other failures map to `:proof_unavailable`. Never reuse a signed
nonce. Request context contains the exact facade operation, caller/target,
input, and page options so a trusted transport can bind its signature correctly.
The adapter does not invent a signed-request wire format or cryptography.

## Independent streams and snapshots

`sync/1` requests transcript history first, then command events. The first
authenticated history response (even an empty page) pins the host-selected
private engagement. Later pages and command scopes must match it; command
agent must match the client. The canonical owner in the first authenticated
command response is pinned separately from the proof caller; linked callers may
legitimately have another canonical owner. Later commands must retain that owner.
A direct command response can bind the engagement before the first sync, and
history must subsequently agree. Journal pages carry `engagement_id` even when
empty and must also match the pinned engagement.
No caller-selected engagement is accepted. The host remains responsible for
authorizing and selecting the initial private engagement.

After the first binding, every request includes `expected_engagement_id`. This
is a comparison fence, never a routing option. The host rejects a changed owner
scope before read/admission with `:conversation_scope_changed`. Clear the cached
projection, draft and pending retry and require an explicit reconnect; never
carry an old command into the newly resolved owner scope.

Signed proof providers should call the host's canonical helper, then sign the
returned bytes with a fresh nonce:

```elixir
{:ok, payload} = Arbor.Agent.conversation_request_payload(
  request.operation, request.caller, request.target, request.input, request.options
)
{:ok, signed} = sign_with_fresh_nonce(payload)
{:ok, [signed_request: signed]}
```

The format is a **seven-element JSON array**,
`["arbor.conversation.v2", operation, caller, target, input, [after, through, limit], expected_engagement_id]`.
Absent page values and the initial fence are `null`; submit input is `[id, text]`.
Old six-element `v1` signatures are rejected. The caller stays the actual proof
subject even when the host's canonical owner differs.

Each stream keeps its own cursor and pinned head. Transcript ordinals may have
gaps and may advance across another engagement's filtered entries; journal
events must be contiguous and obey admitted → dispatch started → settlement.
Never combine their cursors or infer a command result from a transcript entry.

Trusted construction opts are `facade: module`, `page_limit: 1..100` (default 50),
and `max_pages: 1..100` (default 20). A sync reads at most `max_pages` successful
pages **per stream**, then returns a usable checkpoint retaining unfinished
pinned heads. `sync_status/1` reports `%{history: %{head: n, has_more: boolean},
commands: %{head: n, has_more: boolean}}`. Calling sync again continues those
prefixes. Completed streams poll for a new head on the next call. This prevents
a long conversation from being stranded behind a fixed total-history ceiling.

On `:page_too_large` the adapter halves that stream's requested limit, retaining
the successful lower limit. At most seven additional attempts per stream are
possible per sync. A failure at limit 1 remains explicit. Any error discards
**all local changes in that sync**, including successful pages of the other
stream; the original client remains the last complete checkpoint. Host effects
and proof nonce consumption are not rolled back. Requests are sequential.

The renderer snapshot is string-keyed and has `messages`, `deliveries`, `blocks`,
and `speech`. Message blocks have type `message`, id, role, text, timestamp, and
ordinal. Delivery blocks have type `delivery`, id, status, input_text,
result_text, reason, admitted_cursor, updated_cursor, and descriptive text.
Completed results stay delivery blocks; they never become assistant messages.
`dispatch_started` is explicitly "outcome unknown"; `uncertain` never becomes
completion. `speech` is empty for history, polling, submit, and reconnect until
a host provides an explicit new-content/playback policy.

The core's original event API stays unchanged. `ConversationKit.Snapshot` is the
pure generic projection for separate transcript/delivery records. No synthetic
events or command-to-message correlation are needed.

## Bounds and qualification

Submission input matches the host's 32,768 UTF-8 byte limit, successful delivery
results allow 131,072 bytes, and transcript entries allow 262,144 bytes. Content
is never truncated. IDs and known roles/statuses are validated; page shapes,
scope, lifecycle, event identity, cursor progression and exact duplicate
observations are checked before local commit. Future event kinds fail explicitly
with `:unsupported_event_kind`, requiring an adapter update rather than silent
cursor advancement. Additional private fields are rejected.

Run from this directory:

```sh
../bin/mix test
../bin/mix compile --warnings-as-errors
../bin/mix format --check-formatted
```

Tests cover fresh proofs, pinned multi-call paging, reconnect equivalence,
duplicate polling, ordinal gaps, late errors, changing scopes, unknown kinds,
invalid transitions, ambiguous statuses, safe projections, and the actual text
bounds. Real Arbor integration and shared web/TUI qualification are retained in
the surrounding experiment artifact.

This is a source package experiment, not a published package. It retains full
in-memory transcript and duplicate evidence; pagination bounds work per call,
not total cache size. Host journal reconstruction remains O(history). There is
no encrypted disk outbox, automatic transport, push subscription, actual audio,
or new production route. Reconnect reconstructs from zero; persisting cursor
numbers alone without the corresponding validated state is unsupported.
# Optional remote transport

Trusted owner configuration may supply `transport: fn context, proof -> result end`.
The adapter invokes the existing proof provider first, once per operation/page;
the callback receives that proof and the exact signed context (operation,
caller, target, input and options). The default public Arbor facade path is
unchanged. Successful results use the same host-map shape and pass all existing
scope, cursor, transition and projection validation. Arbitrary callback errors
are sanitized; malformed returns become `:invalid_transport_response`.

Transport callbacks, credentials and process handles belong only in private
owner state. Renderers receive projections and positions. A transport timeout
does not establish whether a submission took effect; retain its original
command ID. The Gateway companion package implements this callback over the
existing signed WebSocket protocol.
