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
./arbor-tui                       # no flags required — resumes the last agent, or starts unattached
./arbor-tui --agent agent_30b4…   # attach to a specific agent
./arbor-tui [--url ws://localhost:4000] [--key PATH]
```

No flag is required. With no agent resolved (no flag, no config, no remembered
agent) the client starts **unattached** — use `/agent <id>` inside the TUI to
attach. All flags are optional overrides:

- `--agent` (optional) — the agent to attach to (you must hold
  `arbor://chat/agent/<id>`; the agent's creator gets this grant automatically).
- `--url` — Gateway URL.
- `--key` — `.arbor.key` identity file.

### `.arbor.key` format

```
agent_id=agent_30b455…
private_key_b64=<base64 32- or 64-byte Ed25519 private key>
```

## Configuration

Settings come from four sources, in **descending precedence**: CLI flag >
config file > environment variable > built-in default.

Config file: `~/.arbor/tui.conf` — a simple dependency-free `key = value`
format. `#` comments and blank lines are ignored, whitespace is trimmed, a
leading `~` in a value is expanded to your home directory, and unknown keys are
tolerated.

```
# ~/.arbor/tui.conf
url   = ws://localhost:4000
key   = ~/.arbor/client.arbor.key
agent = agent_30b455…
```

| Setting | Precedence (highest → lowest) |
|---|---|
| `url`   | `--url`   > config `url`   > `$ARBOR_GATEWAY_URL` > `ws://localhost:4000` |
| `key`   | `--key`   > config `key`   > `$ARBOR_KEY` > `~/.arbor/client.arbor.key` |
| `agent` | `--agent` > config `agent` > remembered `last_agent` > _(none → unattached)_ |

### Remembered agent (`~/.arbor/tui.state`)

On a successful attach the client writes the agent id to `~/.arbor/tui.state`
(same `key = value` format, `last_agent = agent_…`). This is **auto-written**
state — keep it separate from the user-edited `tui.conf`. A bare `arbor-tui`
then resumes the previous agent. An explicit `--agent` or config `agent` always
wins over the remembered one.

### Best-effort startup attach

If a resolved agent can't be attached at startup (gateway down, agent not
running, unauthorized, upgrade rejected) the client does **not** abort and does
**not** retry-spam — it falls back to the unattached state with a message, so
you can `/agent <id>` to retry. The indefinite backoff-reconnect (see
[Reconnect](#reconnect)) only applies **after** at least one successful attach,
i.e. the server-restart case.

## Slash commands

Input starting with `/` is matched against a small **client-local** command set
first; anything else is forwarded to the attached agent (the server's own
slash-command handling, e.g. `/model`, `/status`).

Client-local (handled by the TUI, never sent to the agent):

| Command | Effect |
|---|---|
| `/agent <id>`   | attach to / switch to an agent (resets the transcript — a fresh conversation) |
| `/connect <url>`| change the gateway URL and reconnect (re-attaches the current agent if set) |
| `/help`         | list the client-local commands |
| `/quit`         | exit the TUI |

Everything else — plain messages and any other `/command` — is sent to the
attached agent. While **unattached**, sending a message or a server command
shows "Not attached — use /agent <id> first" instead.

## Keys

- `Enter` send · `Backspace` edit · `Esc` clear input · `Ctrl+C` quit

## Architecture

| Module | Role |
|---|---|
| `ArborTui.CLI` | escript entry — parse args, resolve settings, load identity, launch the runtime |
| `ArborTui.Config` | settings resolution (flag > `tui.conf` > env > default) + remembered-agent state |
| `ArborTui.App` | `TermUI.Elm` root — model / `event_to_msg` / `update` / `view` (incl. client-local slash commands) |
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

Once a target has **successfully attached at least once**, the `WSClient`
reconnects automatically on any later disconnect — a server `:close` frame, a
`Mint` transport error (e.g. the Gateway restarting), an outbound send/upgrade
failure. Every such path funnels into one place: the half-open connection is
torn down (identity/url/target are kept), an attempt counter is bumped, and a
`:reconnect` is scheduled after a jittered exponential backoff — base 500ms,
doubling per attempt, capped at 30s, retried **indefinitely**. A successful
upgrade resets the counter to 0 and cancels any pending retry.

The **first** attach to a target is best-effort (see
[Best-effort startup attach](#best-effort-startup-attach)): if it never
establishes, the client goes unattached instead of entering this backoff loop —
so a dead or unauthorized agent is not retry-spammed. The same applies to
`/agent <id>`.

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
