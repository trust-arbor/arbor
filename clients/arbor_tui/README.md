# arbor-tui

A terminal chat client for Arbor — an escript built on
[`term_ui`](https://github.com/pcharbon70/term_ui) (pure-Elixir Elm Architecture)
that connects to the Gateway chat WebSocket API and holds a conversation with an
agent.

It is modeled on coding-agent TUIs (Claude Code / opencode / codex): a single
scrolling transcript, a persistent input line, and a thin status bar. The Arbor
distinctive is that **proactive `💭` notifications** from the agent's heartbeat
interleave into the same transcript — the continuous mind made visible.

## Standalone by design

This is a **client**, not part of the Arbor umbrella. It lives in `clients/` (not
`apps/`) so it has its own build, dep tree, and release cadence, and stays out of
the server's library-hierarchy drift-guard. It reproduces only the tiny
`SignedRequest` signing surface (stdlib `:crypto` Ed25519 — see `ArborTui.Signer`),
so it has **zero coupling** to the server umbrella. The wire formats it mirrors:

- auth envelope ↔ `Arbor.Gateway.SignedRequestAuth`
- signing payload ↔ `Arbor.Contracts.Security.SignedRequest`
- chat frames ↔ `Arbor.Gateway.Chat.Protocol`

(If any of those server modules change, the corresponding client module must
follow — that's the cost of decoupling.)

## Build & run

```bash
mix deps.get
mix escript.build
./arbor-tui --agent agent_30b4… [--url ws://localhost:4000] [--key PATH]
```

- `--agent` (required) — the agent to attach to (you must hold
  `arbor://chat/agent/<id>`; the agent's creator gets this grant automatically).
- `--url` — Gateway URL (default `$ARBOR_GATEWAY_URL` or `ws://localhost:4000`).
- `--key` — `.arbor.key` identity file (default `$ARBOR_KEY` or
  `~/.arbor/client.arbor.key`).

### `.arbor.key` format

```
agent_id=agent_30b455…
private_key_b64=<base64 32- or 64-byte Ed25519 private key>
```

## Keys

- `Enter` send · `Backspace` edit · `Esc` clear input · `Ctrl+C` quit

## Architecture

| Module | Role |
|---|---|
| `ArborTui.CLI` | escript entry — parse args, load identity, launch the runtime |
| `ArborTui.App` | `TermUI.Elm` root — model / `event_to_msg` / `update` / `view` |
| `ArborTui.WSClient` | `Mint.WebSocket` transport — upgrade (signed), attach, pump frames |
| `ArborTui.Protocol` | client-side codec for the chat frames |
| `ArborTui.Signer` | identity load + Ed25519 request signing |

Async server frames reach the UI via `TermUI.Runtime.send_message/3`: the
`WSClient` pushes `{:server_event, event}` / `{:ws_status, …}` into the runtime,
which folds them through `App.update/2`.
```
WSClient ──{:server_event, event}──▶ TermUI.Runtime ──▶ App.update/2 ──▶ view
   ▲                                                          │
   └──────────── WSClient.send_command/2 ◀────────────────────┘
```
```

## Reconnect

The `WSClient` reconnects automatically on **any** disconnect — a server
`:close` frame, a `Mint` transport error (e.g. the Gateway restarting), an
outbound send/upgrade failure, or a failed initial connect. Every path funnels
into one place: the half-open connection is torn down (identity/url/target are
kept), an attempt counter is bumped, and a `:reconnect` is scheduled after a
jittered exponential backoff — base 500ms, doubling per attempt, capped at 30s,
retried **indefinitely**. A successful upgrade resets the counter to 0 and
cancels any pending retry.

The UI shows a `◍ reconnecting…` status with the live "attempt N, retrying in …"
tail. The **transcript is preserved** across reconnects (the server replays the
engagement transcript on re-attach), and outbound commands are dropped — not
sent into a dead socket — while disconnected.

## Status

Scaffold complete: compiles clean (`--warnings-as-errors`), escript builds, the
suite passes (incl. a real Ed25519 sign↔verify round-trip and WS auto-reconnect
coverage). Auto-reconnect is **implemented** (see above). **Not yet validated
against a live Gateway** — that's the next step (and becomes the standing
live-transport integration test for the chat API). Layout polish (viewport
scrolling, terminal-dimension-aware truncation) remains a follow-up.
