# Conversation host boundary

The opt-in `Arbor.Agent` conversation API separates interface connections from
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
request needs a fresh nonce on every request, including retries. The host derives
the private engagement from the verified principal. Client-selected engagements,
collaborator modules, verification flags and duplicate options are rejected.

Conversation admission requires a reusable capability (`max_uses: nil`). Finite
use grants are rejected before consuming a use: the existing capability system
automatically revokes an exhausted grant, which cannot safely be distinguished
from explicit revocation by a later continuation. Ordinary rate constraints are
charged once per authenticated API request. Subsequent release and dispatch
checks retain current identity, capability and policy checks without charging the
same request again. This restriction applies only to the new conversation API.

## Stable commands and delivery ownership

```elixir
command = %{id: "device-generated-unique-id", text: "Hello"}
proof = [session_token: token]
{:ok, accepted} = Arbor.Agent.submit_conversation_command(human_id, agent_id, command, proof)
{:ok, current} = Arbor.Agent.conversation_command(human_id, agent_id, command.id, proof)
```

Generate the command ID before attempting delivery and retain it across network
retries. IDs are unique per principal across destinations. Reusing an ID with
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

Command pages return `%{events: events, cursor: cursor, head: head,
has_more: boolean}`. Each event includes a stable `id`, contiguous `cursor`,
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

These APIs are additive. Existing web/TUI/voice routes have not migrated. A
transport adapter must bind authenticated connection identity to these methods
and map the returned semantic data into its presentation model. Network
endpoints, live subscriptions, actual audio and DASP protocol conformance are
separate integrations.
