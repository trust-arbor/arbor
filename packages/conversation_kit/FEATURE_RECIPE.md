# Adding a shared conversation feature

Put a decision shared by interfaces into a pure module. Keep host authority,
transport, device operations and native controls at their respective boundaries.
The maintained web and Breeze clients both use `ConversationKit.Composer` for
drafts and delayed acknowledgements; neither duplicates those decisions.

## Example: preserve edits made while a message is pending

The renderer passes input to `Composer.draft/2`. Its shell generates a request ID
once and passes the current send availability to `Composer.submit/3`:

```elixir
composer = ConversationKit.Composer.new()
composer = ConversationKit.Composer.draft(composer, "Hello 東京")
{:send, request, pending} = ConversationKit.Composer.submit(composer, true, "saved-request")

# The user can continue editing while the host confirms the first message.
edited = ConversationKit.Composer.draft(pending, "My next message")
acknowledged = ConversationKit.Composer.acknowledge(edited, request)
%{draft: "My next message", submitted: nil} = acknowledged
```

`true` above is local send availability, not permission. A host still authenticates
and authorizes every submission. Only its validated acknowledgement can release
the matching submission. A request ID or a rendered transcript row cannot prove
admission or completion. Retry retains the original ID and input; a newer draft
is a separate value.

Each edit increments a local revision. An acknowledgement clears an unchanged
draft, but preserves edits even when the user edited away and back to identical
text. A definite rejection can call `Composer.reject/2`; a timeout cannot.
Access or ownership loss calls `Composer.clear/1` and also clears the native
input and private browser storage. An ordinary transport disconnect keeps the
draft for reconnect.

## Native integration

The LiveView surface owns a Composer value on its socket. A textarea change
updates it; submitting interprets the returned `{:send, request, next}` decision
through its private connection owner. The browser hook keeps the same request
identity across reload and asks for its status before any retry.

The Breeze editor owns the same value. Native textarea changes and submissions
call the same functions, and validated connection snapshots deliver matching
acknowledgements. Unicode editing, caret scrolling, focus and paste belong to the
terminal library. The web chooses its own keyboard shortcuts and scroll anchor.

Arbor's private `ConversationKit.Arbor.Connection` supplies bounded snapshots and
freshly authenticated operations. Another host can supply its own adapter and
use Composer unchanged. Its implementation must validate returned identity,
scope and delivery status before forwarding an acknowledgement.

## Verification

Test the shared decision once against its semantic counterexamples: foreign
acknowledgement, newer edit, identical-text newer revision, definite rejection,
and privacy clear. Then test each native consumer's input and effect wiring.
Rendered text alone cannot prove an input handler or a real terminal decoder.
The package's `test/composer_test.exs` exercises the decisions; the maintained
LiveView and Breeze suites exercise their integrations.

Conversation history remains host-owned. The bounded display cache can be
reconstructed without replaying every record. Voice rendering is a separate
device operation: reading history or reconnecting must never replay speech.

## Native activity and human controls

Normalize a fresh authenticated host response into the exact bounded fields in
the [controls contract](CONTRACT.md#bounded-controls-observation-2026-10-03), then
replace the disposable observation. Host task/source identifiers and proofs stay
inside the adapter. The native renderer owns progress layout, focus, selection
and buttons; the shared model owns which observed commands and prompts can
produce request data.

```elixir
{:ok, controls} = ConversationKit.Controls.replace(old_controls, normalized)
{:ok, display} = ConversationKit.Controls.project(controls)
{:ok, request} = ConversationKit.Controls.intent(controls, %{
  "kind" => "cancel", "command_id" => selected_command_id
})
```

The connection owner interprets the request through its authenticated host
operation. It disables the native control while that request is in flight and
refreshes the observation after the reply. There is no optimistic cancellation
or answer resolution. A timeout retains uncertainty; an explicit retry requires
a fresh pending observation. A human answer is never automatically retried.
The host rechecks every identity, scope, expiry and winning transition even when
the shared model accepted the intent.

Ordinary choices send exact choice IDs, so duplicate labels remain unambiguous.
Protected approvals use the separate approval action and preserve exact request,
operation and revision identity. A display block, progress event or local intent
is never approval authority. Reading, replacing or reconnecting these observations
produces no speech. Clear the observation when the connection loses its owner
or engagement scope; the connection owns that scope fence.

`test/controls_test.exs` checks unknown execution versus stopped, cancellation
requested versus confirmed, immutable uncertain delivery, exact prompt identity,
duplicate labels, protected route separation, terminal actionability and byte
bounds. Native integration tests must additionally prove real input wiring and
the host's final authentication and durable transition; model tests cannot prove
those effects.
