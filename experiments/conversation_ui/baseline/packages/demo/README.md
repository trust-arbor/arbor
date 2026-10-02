# Arbor conversation surfaces

This standalone demo adds two native surfaces over `../adapter`:
`ConversationDemo.ArborChatLive` at `/arbor`, and
`ConversationDemo.ArborBreezeView` in the terminal. They share an authenticated
Arbor conversation while retaining independent drafts and two replay positions.
Phoenix LiveView 1.1.33 and Breeze 0.5.3 remain pinned. The dependency-free semantic
projection is in the separate `../core` package.

The new views call Arbor's existing public conversation facade through the
adapter. They introduce no network transport, authentication endpoint or UI
migration in Arbor. The [integration harness](../integration/) runs the views
with real Arbor Security, Comms and Persistence in an isolated host checkout.
Starting the demo alone does not start Arbor; `/arbor` shows a bounded
configuration error until trusted server configuration supplies the connection.

## Trusted binding

Install this configuration in the hosting BEAM before either renderer mounts:

```elixir
Application.put_env(:conversation_demo, :arbor_client_options,
  caller: human_id,
  target: agent_id,
  proof_provider: fn context -> fresh_proof_for(context) end,
  adapter_options: [facade: Arbor.Agent, page_limit: 50, max_pages: 20]
)
```

The proof provider returns `{:ok, [session_token: token]}` or
`{:ok, [signed_request: request]}`. It is called anew for every host request,
including every page, status check and retry. A signed request must have a fresh
nonce and bind the exact supplied operation context. The trusted caller and
target never come from form values, query parameters or browser session data.

Each renderer starts a monitored `ArborClient` owner process. This owner keeps
the private adapter, proof callback and any unresolved submission. Renderer
assigns contain only the owner's pid, a closed display snapshot and a local
draft. A renderer process exit also stops its client owner.

The trusted terminal mount can use the application default or explicit options:

```elixir
ConversationDemo.ArborBreezeView.run()
# Tests, without taking over the terminal:
session = Breeze.Test.start!(ConversationDemo.ArborBreezeView,
  size: {90, 36}, start_opts: [client_options: trusted_options])
```

The copied demo endpoint uses loopback port **4791** so the prior experiment on
4781 can remain running. Its default dev command is `../bin/mix run --no-halt`.
Use the isolated integration launch instructions when exercising real Arbor;
the facade and its configured storage must be available in the hosting BEAM.

## Interaction and limits

- Send uses a fresh command ID only for a new explicit submission. An ambiguous
  admission keeps its original ID and text in the client owner and disables new
  sends. **Check / retry** first reads that ID; only an explicit `:not_found`
  permits resubmitting the identical ID and text.
- Acknowledged admission clears the composer even if the following refresh
  fails, but only when its current text still matches the acknowledged draft.
  A newer draft survives an earlier request's retry acknowledgement in both
  the server assigns and the browser's focused input. A deterministic rejection releases the pending slot so the user can
  correct the message. Acknowledged `dispatch_started` or `uncertain` statuses
  remain visible as unknown outcomes; retry does not repeat their execution.
- Refresh polls independent transcript and command-journal prefixes. Reconnect
  resumes those cursors; it preserves a local draft. Disconnect disables host
  requests from that surface. It is an application-level pause, not a physical
  WebSocket close, and admitted delivery continues on the host.
- Authorization denial clears private projection, cursors, draft and pending
  submission. The web hook also clears a focused browser input, whose local
  value LiveView would otherwise preserve. No raw host error or proof is shown.
- Drafts and the ambiguous-admission outbox live only as long as the renderer's
  owner process. They are **not a durable offline outbox**. After process loss,
  acknowledged host records rehydrate by replay; an unacknowledged local ID does
  not. Durable device checkpoints are a separate follow-on.
- No automatic polling or push subscription is installed. Refresh explicitly
  advances a bounded sequence; the web view reports when more pages remain.
- The speech list is a non-playing preview. This adapter has no new-versus-replay
  speech classification, so its current speech list is empty. Neither view
  offers mock approval/cancel actions for the real host.

Terminal keys: Enter sends, F3 refreshes, F4 disconnects, F5 reconnects, F6 checks
or retries the saved request, and Escape exits. Breeze's native transcript
viewport scrolls independently. Narrow rows are constrained to terminal width.

## Verification

From this directory:

```sh
../bin/mix compile --warnings-as-errors
../bin/mix test
```

`test/arbor_interfaces_test.exs` exercises real LiveView and Breeze runtimes over
a deterministic facade: cross-surface updates, independent drafts, fresh proofs,
disconnection, stable ambiguous retries, admission followed by a failed refresh,
rejection, private-state clearing after revocation, owner cleanup, native Unicode
input and narrow terminal rendering. The real-boundary integration tests are
separate under `../integration`, and use the same view modules and trusted binding.

Native input testing caught a Breeze 0.5.3 integration detail: the single-line
`Breeze.Implicit.Input` emits changes but does not submit on Enter. The parent
view handles the unconsumed Enter event explicitly. The rendered input also
needs its draft content slot and an explicit full-width constraint. A direct
`chat:send` event test alone does not exercise either detail.

The previous fixture comparison remains available at `/`, through `BreezeView`
and `TermUIView`, with its existing six tests. Its mock actions and local-host
semantics are separate from `/arbor`. Historical benchmark and browser evidence
remain in the unchanged
[`conversation-framework-spike-20260926`](../../conversation-framework-spike-20260926/)
artifact; copied old log files in this demo are historical, not new validation.

The adapter now pins the host-selected engagement and canonical owner separately
from the authenticated caller. Every subsequent host call includes the signed
`expected_engagement_id` fence. Ownership changes clear private display state,
draft, replay cursors and the pending admission; the operator must reconnect
explicitly. No old pending command is retried in the new owner's conversation.
Ordinary refresh/reconnect and acknowledgement of an older draft still preserve
a newer local draft when ownership remains unchanged. See the adapter README
for the seven-element `arbor.conversation.v2` signature format.
