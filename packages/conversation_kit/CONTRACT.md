# ConversationKit spike contract (2026-09-26)

The package under `core/` has no runtime or framework dependencies. Its only
public data format is string-keyed JSON-compatible maps. A caller constructs
state with `ConversationKit.new("conversation-id")`, then applies authoritative
events using `apply/2`, or calls `replay(events, state)` (`replay/1` starts `demo`).
Both return `{:ok, state}` or `{:error, reason}`. Persist an event log or trusted
checkpoint together with its evidence; this spike reconstructs imported state
by replaying events, and does not validate arbitrary imported state snapshots.
Decode JSON in the shell using `JSON.decode!/1` or `Jason.decode!/1`, which map
JSON null to Elixir nil. OTP `:json.decode/1` defaults to the atom `:null`; using
it without an explicit null mapping fails closed at the event validator.

## Event envelope and data

All events have exactly `id`, `revision`, `kind`, and `data` fields. IDs are
caller-supplied ASCII identifiers of 1–128 bytes. Revision starts at 1 and is
contiguous. An exact duplicate of a saved event is harmless; a changed duplicate,
event ID reuse, unknown kind, or gap is rejected without advancing state. The
full event list retained by this spike is duplicate evidence, not a scalable
retention policy. `replay/2` returns no partial checkpoint on a failed batch.

| kind | exact data fields |
| --- | --- |
| `admitted` | `command_id`, `name` (currently `chat.send`) |
| `message` | `message`: `{id, role: user\|assistant, text, command_id}` |
| `settled` | `command_id`, `outcome`: `{status, output, error}` |
| `tool_started` | `id`, `command_id`, `name`, `text` |
| `tool_finished` | `id`, `status: completed\|failed\|cancelled`, `text` |
| `approval_requested` | `id`, `command_id`, `text`, `protected: boolean` |
| `approval_resolved` | `id`, `decision: approved\|denied` |
| `notice` (fixture 1.1 extension) | `id`, `text`, `severity: info\|warning` |

A completed outcome has `output: {message_id, text}` and `error: null`, and must
match an existing assistant message belonging to that command. Failed/uncertain
outcomes have `output: null` and `error: {code, message, retryable: boolean}`.
A cancelled outcome has both output and error null. A terminal command cannot
settle again or accept further message/tool/approval updates. Host execution and
cleanup completion remain host obligations; projection is not execution proof.

All text is valid UTF-8 of at most 16,000 bytes. `event.schema.json` documents
that byte bound with `x-maxUtf8Bytes`; standard JSON Schema measures string
length in Unicode code points, so the reducer additionally enforces bytes.

## Projection

`project(state)` returns `id`, `revision`, `messages` (list), `commands` (list in
admission order), `tools`, `approvals`, `notices`, `blocks`, and `speech`.
Blocks carry `type`, stable `id`, `text`, and `status`, plus kind-specific data.
Renderers own presentation, layout and input. A renderer that does not recognize
a block type uses its plain text fallback. Unknown authoritative event kinds
must still reject: the fallback is a rendering compatibility rule, not permission
to silently skip state transitions.

Tool and approval projections also carry `authoritative_status`. If an owning
command becomes terminal while a tool is recorded running or approval pending,
the projection uses `status: unresolved`, with `active: false` or
`actionable: false`. This disables active controls without fabricating a tool
completion or an approval resolution; the original facts remain in state.
Protected approval speech escalation is only emitted while the owning command
is pending. This correctness adjustment precedes the measured notice extension.

Speech entries are descriptions, not playback effects: `utterance` entries have
`utterance_id` and `text`. Only completed assistant messages become utterances.
Protected pending approvals produce `screen_required` entries with
`interaction_id` and generic text that does not contain the approval details.
The host must classify sensitive content before providing speakable text; this
spike is not a classifier or an audio engine. A device owns playback claims and
its interruption policy separately from the replay cursor.

## Intents and transient state

`intent(state, "send", %{"text" => text})`, `intent(state, "cancel",
%{"command_id" => id})`, and `intent(state, "approve", %{"approval_id" => id,
"decision" => "approved" | "denied"})` return an `{:ok, intent}` map with
`name` (`chat.send`, `chat.cancel`, `approval.respond`), `conversation_id`, and
`input`. The shell generates durable command IDs, authenticates, authorizes,
admits and performs work. Intent normalization never modifies state or grants
authority. In particular, producing an approval intent is not approving a
capability.

`progress(local_map, %{"command_id" => id, "text" => text})` returns an updated
disposable map without changing the durable conversation or revision. Drafts,
selection, viewport and playback bookkeeping are also adapter/device state.
Progress can disappear on reconnect; saved final messages reconstruct history.

Versioned fixtures live at `fixtures/v1/`. Their wrapper contains
`schema_version`, `id`, and `events`; the schema version is not a network
negotiation mechanism. No transport or DASP types are imported by the package.

## Measured extension

After the renderer baselines passed, fixture `v1/notice.json` introduced the
`notice` event. Its projected block has `type: notice`, `status` equal to severity,
and a plain `text` fallback. It is passive visual content; the speech projection
deliberately stays unchanged. Adding visible content does not automatically
request spoken playback.

The frozen previous reducer rejects this unknown authoritative event; the
upgraded reducer validates it and produces the block. Tests exercise both exact
source versions. This shows the distinction between upgrading shared semantics
once and requiring every renderer to add a widget. Measurements and source
snapshots are retained under `fixtures/measurements/`. The unrelated terminal
actionability correction is recorded separately before the extension baseline.

## Bounded controls observation (2026-10-03)

`ConversationKit.Controls` is separate from the event reducer and Snapshot API.
Its value is a disposable observation, never a trusted checkpoint, command log,
proof or authorization. `new/0` returns empty `activities` and `interactions`.
`replace(current, observation)` validates and replaces the entire value, returning
`{:ok, observation}` or `{:error, :invalid_snapshot}`. The previous value is not
retained. All keys and enum values below are strings. Unknown fields, structs,
atom keys, invalid UTF-8 and duplicate command/request/operation/choice IDs reject.
Labels may duplicate because selection uses the exact choice ID.

The top-level map has exactly `activities` and `interactions`, with at most 50
entries each. Its entire JSON encoding must be at most 262,144 bytes. Every
activity has exactly:

| field | value |
| --- | --- |
| `command_id` | ASCII letters, digits, `_` or `-`, 1–128 bytes |
| `delivery_status` | `admitted`, `dispatch_started`, `completed`, `uncertain` |
| `execution` | `running`, `queued`, `not_observed` |
| `cancellation` | exactly `{status: none\|requested\|confirmed}` |
| `preview` | valid UTF-8, at most 32,768 bytes |
| `preview_truncated` | boolean |
| `progress` | null or exactly `{type, node_id}` |

Progress type is `pipeline_started`, `pipeline_completed`, `pipeline_failed`,
`stage_started`, `stage_completed`, `stage_failed` or `stage_retrying`. Its node
ID is null or 1–256 ASCII letters, digits, `_`, `-`, `.`, `:` bytes. A progress
event never changes delivery or proves termination. Cancellation confirmation
is a distinct source fact, including when immutable delivery remains uncertain.
Execution `not_observed` never means stopped.

Each interaction has exactly `command_id`, `request_id`, `operation_id`,
`revision`, `kind`, `status`, `text`, `choices`. Command ID uses the activity
bound. Request/operation/choice IDs are 1–256 ASCII letters, digits, `_` or `-`
bytes. Revision is an integer from 1 through 2,147,483,647. Kind is `choice` or
`approval`. Status is `pending`, `responded`, `expired`, `abandoned`, `retired` or
`cancelled`.
Text is valid UTF-8 of at most 4,096 bytes. A choice has 1–32 options, each exactly
`{id, label}` with a nonblank UTF-8 label of at most 512 bytes. An approval has
an empty choices list. The host classifies protected approval details before
passing them into this visual observation.

`project(observation)` returns `{:ok, projection}` with `activities`,
`interactions`, combined `blocks` and `speech: []`. Activities expose separate
delivery/execution/cancellation text and `cancel_actionable`. Interactions expose
`protected` and `actionable`. Routing IDs remain data for native event handlers;
renderers must not display them as content. The input bounds also bound output
size: projection adds a fixed amount of display data per bounded entry.

`intent(observation, action)` returns `{:ok, %{name, input}}` or an error:

| exact action fields | request name |
| --- | --- |
| `kind: cancel`, `command_id` | `conversation.cancel` |
| `kind: choose`, `command_id`, `request_id`, `operation_id`, `revision`, `choice_id` | `interaction.choose` |
| `kind: approve`, `command_id`, `request_id`, `operation_id`, `revision`, `decision`, `note` | `approval.answer` |

Cancel is eligible for admitted, started or uncertain delivery with cancellation
`none`, even if execution is not observed. A completed command or requested or
confirmed cancellation is ineligible. Answers require the exact currently
pending prompt of the matching kind and its eligible owning command. Approval
decision is `approved` or `denied`; note is UTF-8 of at most 4,096 bytes. Missing,
stale or changed identity/revision and terminal prompts never become an intent.
All input fields except `kind` are retained in answer request data.

Intents never mutate observations or keep a consumed/replay ledger. The same
current observation can describe a request more than once; it grants no
authority. The connection owner serializes in-flight actions and permits an
explicit retry only after a fresh pending observation. It must never
automatically retry a human answer. Every operation still requires host
authentication, exact owner/engagement scope, generation/source membership,
deadline checks and the winning durable compare-and-set transition. This pure
module has no clock and does not decide expiry; host status owns that fact.

Before calling this API, adapters normalize source records into the exact fields
above. Host task/source/session IDs, handles, proofs, callbacks, credentials,
termination evidence and scope bookkeeping cannot enter the core. Reconnecting,
replacing observations or reading activity never requests speech or executes
work. None of these controls modify the existing reducer's event semantics.
