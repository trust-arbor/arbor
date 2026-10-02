# Shared comparison boundary

`store.mjs` owns the connection-local cache; the authenticated Arbor host owns the transcript and command journal. Web and Ink receive its frozen semantic snapshots and call its methods. They do not add optimistic durable messages, copy delivery results into assistant messages, create authorization, or play replayed history as audio.

`wire.mjs` mirrors the existing `arbor.conversation.v2` session frames and response envelopes. Transcript and journal cursors advance independently. Pages bind the exact agent and engagement, command observations bind the canonical owner returned by Arbor, and stream updates commit together. The Gateway has no response correlation IDs, so `transport.mjs` admits one request at a time and retires a timed-out channel. A replacement channel must attach through history before command lookup or submission.

A failed send preserves its original command ID privately. A visible **Check saved request** reconnects, restores history, and performs host lookup. Only an authoritative `not_found` without a contradictory known record permits **Retry saved request**, using that same ID and text. Host-terminal uncertainty remains a delivery result; it is distinct from transport uncertainty and permits a new independent turn. Disconnect clears renderer data while retaining private recovery state; access loss erases both and rejects late frames.

The richer interaction is a controlled fixture convention, not a production Arbor interaction contract or capability approval. An authoritative assistant message can contain `@conversation-question/v1 ` followed by `{id,revision,prompt,options}` with exactly three choices. Confirmation sends an ordinary chat message with `@conversation-answer/v1 ` followed by `{question_id,revision,option_id}`. Local selection is disposable and pinned to the question's source message and revision. Accepted/completed status requires a matching host delivery and an answer belonging to that source; a reissued question does not inherit an older source's answer.

`fixture.mjs` is a deterministic, wire-shaped host double used by both UI tests. Its injected timeout and revocation controls prove local state behavior; they do not prove a real Gateway, provider, device, or microphone journey.

`node-channel.mjs` is the privileged Node socket shell. The session credential remains inside the upgrade Authorization header and never enters renderer state, a URL, or a log. It uses the pinned `ws` package because the browser/native WebSocket API cannot set Arbor's required upgrade header. Plain HTTP is restricted to loopback, redirects and compression are disabled, and only the existing SDK's bounded upgrade-409 attachment race is retried. The browser requires an injected authenticated host owner or backend bridge; this spike does not invent a browser credential transport.

Local dependency-free checks:

```sh
node --test --test-reporter=tap typescript/tests/store.test.mjs typescript/tests/transport.test.mjs typescript/tests/node-channel.test.mjs
```

The socket-shell unit tests inject a fake socket class. `tests/real_gateway.mjs` is a separate real-host entrypoint invoked with the `tsx` loader by the isolated Elixir fixture and a temporary mode-0600 configuration. It mounts both actual assistant-ui renderers around the same authenticated store, confirms the question through web controls, sends a Unicode follow-up through Ink's composer, and verifies both host projections. It also checks disconnect clearing, stable IDs after reconnect, and active renderer clearing after local access loss. Local access loss is not evidence of Gateway credential revocation. It emits counts, named claims, and a hash only. That integration is pending until the normal-terminal qualification runner executes it with installed dependencies.
