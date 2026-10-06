# ConversationKit Arbor adapter

A renderer-neutral adapter between the independent ConversationKit core and
Arbor’s authenticated conversation facade. The package depends only on
`conversation_kit`; a local host supplies the public `Arbor.Agent` facade at
runtime, or an optional Gateway transport supplies the same closed responses.
No Phoenix, Breeze, audio or Arbor umbrella application is imported here.

This maintained source package is `0.1.0-dev`, unpublished. The name remains
provisional. Host integrations use:

```elixir
{:conversation_kit_arbor, path: "../../packages/conversation_kit_arbor"}
```

An Arbor host also needs its conversation SQL schema deployed to the active
Persistence Repo. Conversation Home and native controls require migrations
`20261003000001` and `20261003000002`; building the adapter or starting the host
does not apply them. See the [host schema prerequisites](../../docs/arbor/CONVERSATION_HOST_BOUNDARY.md#conversation-interface-schema)
before an existing-host upgrade. The independent core and adapter tests do not
establish that a running Arbor database has this schema.

## Native interface connection

`ConversationKit.Arbor.Connection` privately owns credentials, scope fences,
request IDs and one monitored host operation at a time. A renderer receives only
its PID and closed `{:conversation_updated, pid, snapshot}` messages. Every
read, admission and explicit retry acquires fresh proof. Polling uses one bounded
history window and, when needed, the current command receipt; initial display
does not replay all prior messages or journal events.

```elixir
{:ok, connection} = ConversationKit.Arbor.Connection.start(
  caller: human_id,
  target: agent_id,
  proof_provider: fn _request -> {:ok, [session_token: current_token()]} end,
  poll_interval_ms: 1_000
)

# Keep the ID before sending; retries use the same ID and text.
ConversationKit.Arbor.Connection.act(connection, :send, %{id: stable_id, text: text})
ConversationKit.Arbor.Connection.act(connection, :older)
ConversationKit.Arbor.Connection.act(connection, :newer)
ConversationKit.Arbor.Connection.act(connection, :latest)
```

Host calls run outside the connection’s receive loop. A send racing a background
read is queued once. A renderer’s exit stops the worker and transport; already
admitted host work retains its host-owned lifetime. An admission acknowledgement
clears only the matching submitted draft, even if the following refresh fails.
Access loss or changed ownership clears all private display and pending text.
The renderer must also clear its native focused input and any browser draft
storage on a `private_cleared` snapshot.

## Immutable adapter API

`Arbor.new/4`, `window/2`, `submit/3` and `command/2` return validated replacement
client values. `window/2` returns `{:ok, client, window_bounds}`. Omit direction
for the latest page, or pass exclusive `before`/`after` ordinal anchors and an
optional `through` snapshot head. `limit` is 1–100, default50. Entries remain
ascending; gaps from other engagements are valid. Window reads replace retained
transcript records instead of accumulating them. The cache retains at most one
window and50 recently observed command receipts. Selecting a window releases
any earlier replay cache, keeping only recent delivery receipts. A window client
rejects `sync/1` with `:incompatible_replay_mode`; construct a fresh client to
start a contiguous replay instead of treating a displayed tail as a full prefix.

Only `projection/1`, `controls_projection/1`, `position/1` and `sync_status/1` are display-safe. Client
values and proof/transport callbacks must never enter LiveView assigns, Breeze
state, logs, URLs or serialized checkpoints. Inspect hides private client data.
The host independently resolves the canonical owner and engagement on every
operation. `expected_engagement_id` is a comparison fence, never routing authority.

A failed submit may already have taken effect. Check its original ID; resubmit
that same input only after an authenticated `not_found` or `admitted` receipt.
No automatic submission retry, optimistic transcript insertion or transcript
inference establishes completion. Saved delivery results remain delivery blocks.
History, reconnect and polling do not trigger speech playback.

The older `sync/1` API remains available for validated, contiguous full-history
and delivery-journal replay. It bounds work per call, retains full replay state,
and is deliberately not used as a production long-history UI cache. Cursor-only
checkpoints cannot reconstruct that replay state.

Local signed callers use `Arbor.Agent.conversation_request_payload/5` and a fresh
nonce. Gateway callers use the optional companion package. Existing v2 payloads
are unchanged; the bounded-window operation uses the distinct
`arbor.conversation.window.v1` payload, binding direction, head, limit, caller,
target and expected engagement. Validation rejects unknown fields, malformed
pages, conflicting retained content, changed scopes and invalid lifecycle updates.

From this directory:

```sh
../../bin/mix test
../../bin/mix compile --warnings-as-errors
../../bin/mix format --check-formatted
```

## Disposable activity and interaction controls

`activity/2` reads one newest-first active host page (default 20, limit 1–50).
The immutable `{admitted_event_number, command_id}` tuple sorts descending;
`next_cursor` selects strictly older tuples. Earlier work/F8 follows that cutoff,
and latest work/F12 resets it. Each page observes live state and fresh source/index
watermarks, with explicit lag rather than a historical snapshot promise.
`interactions/2` reads one exact command, and `controls/2` replaces the disposable
controls observation. Aggregate
controls use an independent activity window of at most eight commands, one
activity request and at most eight prompt requests. They never follow a cursor
automatically. A fresh proof covers each exact caller, target, input and pinned
engagement. Empty prompt lists still require exact command/scope correlation.

Aggregate state contains at most 50 prompts and 256 KiB of closed JSON. Each
host control response is bounded to 128 KiB. Task IDs, source handles, session
bindings, callbacks, credentials, deadline plumbing and termination evidence are
validated where applicable and omitted from Controls display records. A budget
cut marks `truncated`; its private next cursor resumes at the last fully read
command, keeping older active commands discoverable. The first nonempty command's
whole prompt batch must fit before admission; if necessary the adapter removes
activity preview text and marks it truncated, then checks the full combined
budget again. Unexpected failure refuses the observation instead of publishing
a cursor that skips that command. Maximum128KiB activity/prompt fixtures verify
that all32 first-command prompts fit. Host index lag and eligible
`not_observed` execution mark discovery incomplete. Queued or unobserved commands
do not trigger prompt reads; this omits discovery, without asserting an absence
of prompts or changing delivery/cancellation facts. Explicit refresh can observe
them when the host reports a current running execution.

`Connection` snapshots add `controls`, `controls_available`,
`controls_discovery` (`has_more`, `incomplete`, `truncated`) and
`approval_answer_allowed`. `controls` is a pure Controls projection with no
speech. Ordinary polling retains the last successful observation and sets
`busy` separately, preserving focused decision/note drafts. An actual failed
control read clears stale actionable records. Access loss clears every private
record. The history browsing anchor and unsent draft remain independent.

```elixir
alias ConversationKit.Arbor.Connection

Connection.act(connection, :cancel, %{command_id: command_id})
Connection.act(connection, :choose, %{
  command_id: command_id, request_id: request_id, operation_id: operation_id,
  revision: 1, choice_id: choice_id
})
Connection.act(connection, :more_activity)
Connection.act(connection, :latest_activity)
```

Actions must pass pure `Controls.intent/2` membership validation. One action may
queue against a read; it is checked again against the finished fresh observation.
Only one action may be in flight. Answers never optimistically consume prompts,
create a local terminal ledger, or retry automatically. An unconfirmed answer
clears controls; an explicit fresh read is required before trying again. The
public immutable APIs `cancel/2`, `answer_choice/2` and `answer_approval/2` return
correlated receipts while leaving the cached control snapshot unchanged.

Protected UI actions use `:approve` with exact command/request/operation/revision,
`decision: "approved" | "denied"` and `note` (UTF-8, at most 1024 bytes; no control
characters). Connection translates the decision to the host's `:approve`/`:deny`.
Trusted browser integration may set top-level `approval_answer_allowed: true`;
this flag grants no authority. The actual host requires fresh general-human
session proof and its scoped approval capability. The default false setting
shows a browser-review handoff. Signed proof and terminal-purpose leases do not
bypass that host requirement.

The replay reader understands `cancel_requested` and `cancel_acknowledged` v2
journal records before cancellation writes are used. Requested and confirmed
cancellation remain independent of admitted, claimed, completed or uncertain
delivery, including legal cancellation records after a saved completed result.
Dispatch after a cancellation request and contradictory cursors are refused.
No writer flag changes legacy records or fabricates settlement.

In-memory recovery lasts for the connection owner's lifetime. Durable encrypted
outboxes and authoritative streaming remain separate host integrations. The
normal standalone tests include monitored owner death, conservative control
outages, discovery navigation, bounded aggregation, strict correlation and
cancellation replay. Scripted host fixtures establish adapter behavior; actual
host/Engine and native surface acceptance are separate integration lanes.
Connection's total operation timeout conservatively retires a slow read; these
fixtures do not establish production SQL/network latency or availability.

## Composer commands

`ConversationKit.Arbor.classify_composer_input/1` is a pure, bounded classifier.
It returns ordinary message bytes unchanged, finite `{:local, action}` intents,
management/runtime guidance, or `{:error, :invalid_input}` for nonbinary, invalid
UTF-8 or input above 32 KiB. Leading whitespace before `/` is classified as slash
input. Local commands accept no arguments. The classifier does not execute
commands or grant authority; renderers interpret intents through their existing
private Connection. Runtime slash input is never sent as a chat message.

Local names are `/help`, `/quit`, `/retry`, `/refresh`, `/disconnect`, `/reconnect`,
`/older`, `/newer`, `/latest`, `/work`, `/more-work` and `/latest-work`. Platform
help and quit behavior belong to the surface. Retry checks the saved original
command ID with fresh proof; it does not resend a slash command as new chat.
Management words such as `/agents`, `/agent`, `/attach` and `/connect` provide
guidance to separately authorized operator tools. Chat-purpose credentials do
not gain agent-management or runtime-configuration permission.
