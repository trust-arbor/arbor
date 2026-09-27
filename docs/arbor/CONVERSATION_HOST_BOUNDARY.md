# Conversation host boundary

The `Arbor.Agent` conversation API separates interface connections from
delivery ownership. A web, terminal or voice adapter can admit a stable command,
disconnect, then read its saved state with fresh authentication. Session still
executes the turn and writes its existing transcript. This API does not replace
Session, select a renderer, or require ConversationKit or DASP.

The entry points are:

| Function | Purpose |
| --- | --- |
| `submit_conversation_command(caller, agent, %{id: id, text: text}, opts)` | Durably admit or replay a delivery command |
| `conversation_command(caller, agent, id, opts)` | Read a saved command |
| `conversation_events(caller, agent, after_cursor, opts)` | Page through command lifecycle events |
| `conversation_history(caller, agent, opts)` | Page through the caller's private legacy transcript |

Every request requires exactly one `:session_token` or `:signed_request`, for an
active human principal authorized for `arbor://chat/agent/<agent>`. A signed
request needs a fresh nonce on every request, including retries, and its payload
must match the exact operation, caller, target, input, page options and optional
engagement fence. Build those bytes with
`Arbor.Agent.conversation_request_payload/5` before signing. Mismatch is rejected
before nonce consumption or receipt issuance.

Security preserves the exact proof subject for grants, audit and revocation.
After authentication, its strict alias resolver selects the canonical human who
owns the conversation. Both identities must remain active. Missing, unavailable,
malformed or chained alias state denies admission; it cannot create a fallback
thread. Linking identities does not transfer grants or migrate secondary history.
The command projection's `principal_id` is the canonical owner; it is not the
identity that supplied the proof.

The host derives the private engagement from that pinned owner. An optional
`expected_engagement_id` is a compare-only fence: it must match the derived ID
or return `:conversation_scope_changed`. It never selects a conversation or
grants access. A client should pin the ID from its first authenticated history
read, include it on every later operation, and discard cached display/drafts
before explicitly attaching to a changed scope. Never resend an old pending
command into a newly resolved owner. Caller-selected routes, collaborator
modules, verification flags and duplicate options are rejected.

The signing layout is the JSON encoding of:

```text
["arbor.conversation.v2", operation, exact_caller, full_agent_id, input,
 [after_or_null, through_or_null, limit_or_null], expected_engagement_id_or_null]
```

`input` is `[id, text]` for submit, the command ID for command lookup, the journal
cursor for events, and null for history. Page options encode the supplied values;
absent options are null. Timeout does not change the delivery identity.

Conversation admission requires a reusable capability (`max_uses: nil`). Finite
use grants are rejected before consuming a use: the existing capability system
automatically revokes an exhausted grant, which cannot safely be distinguished
from explicit revocation by a later continuation. Ordinary rate constraints are
charged once per authenticated API request. Subsequent release and dispatch
checks retain current identity, capability and policy checks without charging the
same request again. This restriction also applies to generic authenticated chat
receipts, because those receipts establish the same continuation authority.
Rejections return `:unsupported_conversation_capability` before spending uses;
non-chat finite-use capabilities retain their existing behavior.

Session rechecks that pinned authority before applying a turn result, before
transcript append, after acknowledged append, and before releasing its response.
Cancellation, timeout and failed-engine cleanup use the same check before any
partial transcript write. Revocation cannot undo an already acknowledged append,
but it denies further publication and response release. Private memory retains
the original proof subject inside its admission and exposes only the canonical
durable conversation scope to memory-source consumers.

## Stable commands and delivery ownership

```elixir
command = %{id: "device-generated-unique-id", text: "Hello"}
{:ok, history} = Arbor.Agent.conversation_history(human_id, agent_id, session_token: token)
proof = [session_token: token, expected_engagement_id: history.engagement_id]
{:ok, accepted} = Arbor.Agent.submit_conversation_command(human_id, agent_id, command, proof)
{:ok, current} = Arbor.Agent.conversation_command(human_id, agent_id, command.id, proof)
```

Generate the command ID before attempting delivery and retain it across network
retries. IDs are unique per canonical owner across destinations. Reusing an ID with
different text or a different destination conflicts. Equal retries return saved
state after fresh authentication. They do not allocate a second delivery attempt.

The returned command has `id`, `name`, `text`, `principal_id`, `agent_id`,
`engagement_id`, `status`, `outcome`, `admitted_cursor` and `updated_cursor`.

| Status | Meaning |
| --- | --- |
| `:admitted` | Admission committed; no durable dispatch claim yet |
| `:dispatch_started` | A worker durably claimed one attempt; outcome is not known |
| `:completed` | The scrubbed successful Session delivery result was durably saved |
| `:uncertain` | The host saved an immutable uncertain delivery outcome |

Completion includes `%{status: :completed, text: text}`. Uncertainty includes
`%{status: :uncertain, reason: :delivery_unknown}`. Neither status promises a
separate LLM turn: existing Session steering can make concurrent messages share
a delivery result. Admission returns before the turn finishes. `:timeout` bounds
the existing delivery call (default 30 seconds, maximum 300 seconds).

A supervised worker owns delivery independently of the requesting process. Its
private dispatch claim is committed before calling Session. A command with an
existing claim is never automatically dispatched again. If the worker or BEAM
dies between claiming and saving a result, `:dispatch_started` remains factual
evidence of an unresolved attempt. This is not an exactly-once external-effect
guarantee. Credentials, receipts and private claim tokens are omitted from saved
public projections.

## Two independent cursors

```elixir
{:ok, page} = Arbor.Agent.conversation_events(human_id, agent_id, 0, proof ++ [limit: 50])
{:ok, next} = Arbor.Agent.conversation_events(
  human_id, agent_id, page.cursor, proof ++ [through: page.head, limit: 50]
)
```

Command pages return `%{engagement_id: engagement_id, events: events,
cursor: cursor, head: head, has_more: boolean}`, including empty pages. Each event includes a stable `id`, contiguous `cursor`,
`kind` and the command state at that event. Kinds are `"admitted"`,
`"dispatch_started"` and `"settled"`. Retain `head` as `:through` while paging a
fixed prefix. Omit `:through` when polling for newer events. Limits are 1–100.

History uses `:after`, `:through` and `:limit`, and returns `engagement_id`,
`entries`, `cursor`, `head` and `has_more`. Its cursor is a committed transcript
entry ordinal. Ordinal gaps are valid because an agent session also contains
other engagements. Filtering happens before limiting. Entries expose only `id`,
string `role`, text `content`, ISO8601 `timestamp` and `entry_ordinal`.
Non-text blocks are omitted; this is a display projection, not provenance-bearing
cognitive input. Oversized pages return `:page_too_large`; clients can retry with
a smaller limit. Database failures remain explicit errors.

The two cursors cover separate storage commits. Do not combine them into one
resume token or treat a transcript entry as proof that a command settled. There
is currently no durable command-to-transcript correlation that can safely
reconstruct a missing journal outcome after a crash.

## Storage and integration scope

Comms owns command reduction and delegates durable append to the public
Persistence facade. The default journal backend is explicitly
`Arbor.Persistence.EventLog.Ecto`, with the configured Persistence Repo and its
existing migrations. The ordinary in-memory EventLog is not an admission
barrier. The host returns acceptance only after a verified durable commit.

Journal reconstruction reads bounded pages through a pinned head and validates
the full prefix. It currently costs O(total command-journal history); production
scale indexing, snapshots and retention are follow-up work. Command identities
must not be evicted merely to bound an in-memory deduplication cache.

The existing Dashboard ChatLive and Gateway/TUI private chat routes use these
methods. The Dashboard uses its verified OIDC session proof; a static local-dev
operator ID alone cannot open private chat. Gateway requires a fresh signature
on every WebSocket operation, independently of the upgrade signature. Both
surfaces read bounded durable pages with separate transcript and journal
cursors. Agent-wide signal payloads are not authenticated private history.
Browser session storage retains a pending command and newer draft separately;
TUI retry state currently survives connection loss within one client process.
Neither automatically redispatches a delivery with an unknown result.

Approval, group-chat and server slash controls without proof-aware source
contracts report that they are unavailable on this private-chat surface. Other
operator pages remain separate. This convergence changes delivery wiring and
does not implement Dashboard Home or replace the renderer.

CLI chat requires a valid local operator key (`mix arbor.user.init`, or
`--key-file <path>`). It signs locally and retains the authenticated synchronous
message path, whose receipt selects the same canonical engagement. Missing keys
and proof failures cannot use compatibility delivery. It does not offer the
journal retry semantics of the web/TUI API.

Elixir/RPC callers of authenticated `send_message` must finalize the complete
`UserMessage` (including `sender_id`, timestamp and metadata), then sign bytes
from `Arbor.Agent.message_request_payload/3`. Its `arbor.message.v1` envelope
binds a deterministic hash of that exact native message. Signing only the chat
resource is insufficient. Cross-language clients should use the JSON
conversation API above.

Voice binding, durable transcript freshness, actual audio and DASP protocol
conformance remain separate integrations; see
[the bounded Voice convergence design](CONVERSATION_VOICE_CONVERGENCE.md).
Existing legacy transcripts remain stored without implicit rewriting or backfill.

Deploy with a normal runtime restart: the engagement cache now publishes its
record and resolution index atomically in one ETS table. This work does not
provide an in-place migration of a running cache or merge existing histories.

The [standalone ConversationKit adapter experiment](CONVERSATION_KIT_ADAPTER.md)
consumes these methods from independent LiveView and Breeze clients and qualifies
them against a real Session executing a deterministic local DOT pipeline.
