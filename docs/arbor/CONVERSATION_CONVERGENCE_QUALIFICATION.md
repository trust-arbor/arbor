# Conversation convergence qualification

## Evidence status — 2026-09-27

The isolated candidate passed three real-host callback journeys and one real
browser/WebSocket journey after the final coordinated build, including the
active-turn authority guards. The standalone client also includes the late
receipt correlation fix. No live Arbor runtime was restarted or used for this
evidence.

The fixture uses real OIDC-issued test identities, signed identity linking,
capabilities, the public Agent conversation API, Session's actual `turn.dot`,
a local CaptureProvider, and private SQLite transcript/journal storage. The
provider captures actual request messages and returns a deterministic response.
There is no external model call. The browser's test-only login route installs a
real test session token; it does not exercise a real identity-provider redirect.

| Boundary | Observed result |
|---|---|
| Primary browser token / linked secondary signature | Same host-selected engagement and ordered transcript |
| Next actual model request | Includes both browser and terminal turns |
| Transcript / journal | Four transcript entries, journal cursor six |
| Exact signed retry | Two total model calls and two durable appends after retry |
| Unlink | Old fence denied; fresh secondary model context excludes prior owner's content |
| Revocation | All four Gateway operations deny; displayed web content clears |
| Caller departure | Gateway caller exits before transcript commit; durable command completes |
| Real browser | Production ChatLive form/hook sends, renders terminal turn, survives reload without duplicates |
| Real terminal transport | Production WSClient signs upgrade/frames, reconnects a closed Mint socket, retries original ID, and detaches on revocation |
| Terminal rendering | Actual App reducer and `App.view/1` contain both messages; no PTY run |

The final transport run completed with four tests and zero failures in 67.2
seconds (the three callback tests also run), and the separate terminal probe
exited successfully. The standalone TUI suite passed 100 tests, including a real
loopback WebSocket regression proving that a delayed receipt for an earlier
retry cannot replace a newer pending command.
Browser DOM inspection after reload found one browser message, one terminal
message, and two replies. After revocation both message counts were zero and
`data-conversation-authorized` was `false`.

Additional isolated checks passed: 94 Session authority/steering/egress tests,
22 private-conversation and relationship-memory tests, eight private-memory
authority tests, and the 15-test real SQLite/private-memory model journey. The
last memory compatibility fix preserves the public five-field canonical source
scope while retaining proof-subject checks inside the admission; the memory
suites and warnings-as-errors compilation ran after that fix. The browser/TUI
manifest records the preceding transport build. It is not an audio qualification.

Predecessor runs reproduced operation-signature confusion, unauthenticated
Gateway dispatch and raw cross-owner stream publication, incorrect OIDC subject
selection, inactive-identity callback admission, the CLI missing-key fallback,
extra consumption of chat rate allowances during memory continuation, and
revoked active-turn/partial-result publication. The source-owned guards now have
behavioral regression tests in their respective applications. The deterministic
engagement race test also fails on the instrumented predecessor and passes after
atomic publication; 1,000 batches of 12 concurrent resolutions retain one record
per key.

The repository-wide `mix quality` gate is not green. Changed Elixir files pass
format checking and warnings-as-errors compilation. The aggregate formatter
reports 26 untouched files; the predecessor reproduces that backlog. Compile
connections are 99 against a cap of 88 (100 on the predecessor). Strict Credo
reports a repository-wide backlog; changed files have no warning-category
findings, but retain design/readability/refactoring suggestions. The unused lock
entry `gen_state_machine` is unchanged. Packaging app-env inventory is clean;
source coupling, platform inventory and safe-recovery artifact/closure checks
remain non-green. These broad checks are recorded separately from behavioral
qualification; no unrelated files or thresholds were changed to silence them.

## Reproduce in an isolated checkout

Use the pinned `bin/mix` wrapper. Dependencies and build output must be private
copies; do not share writable caches with a running Arbor checkout. Compile the
umbrella and the standalone TUI separately before starting the fixture:

```sh
MIX_ENV=test ./bin/mix compile --warnings-as-errors
MIX_ENV=test ./bin/mix run --no-start --no-compile apps/arbor_agent/test/support/conversation_transport/run.exs
```

That runs the three callback tests; the browser test skips unless explicitly
enabled. From `clients/arbor_tui`, build its independently owned cache:

```sh
MIX_ENV=test ../../bin/mix compile --warnings-as-errors
```

Start the host fixture from the checkout root and leave it running:

```sh
ARBOR_TRANSPORT_JOURNEY=1 MIX_ENV=test ./bin/mix run --no-start --no-compile apps/arbor_agent/test/support/conversation_transport/run.exs
```

It binds only `127.0.0.1:47871` (Gateway) and `127.0.0.1:47872` (Dashboard), and
prints `CONVERSATION_TRANSPORT_READY`. It writes a mode-0600 disposable fixture
file at `/private/tmp/convergence-transport.json`. Open its `login` URL in a
browser, wait for the live chat form, enter `BROWSER-LARCH-217`, and click Send.
The fixture file contains a test-only signing key; it is deleted on cleanup.

From `clients/arbor_tui`, start the real client probe:

```sh
MIX_ENV=test ../../bin/mix run --no-compile test/support/conversation_transport_probe.exs
```

It waits for the browser turn, sends `TERMINAL-CEDAR-842` through the App reducer,
reconnects, and retries. After `TERMINAL_RECONNECTED_AND_RETRIED`, inspect the
browser transcript and reload: each user message must occur once, with two
assistant replies. From the checkout root:

```sh
python3 apps/arbor_agent/test/support/conversation_transport/control.py revoke
```

Wait for the browser's authorization error and cleared transcript, and for the
terminal probe's `TERMINAL_REVOCATION_PASSED`. Finish the fixture:

```sh
python3 apps/arbor_agent/test/support/conversation_transport/control.py finish
```

The host asserts exact model/append counts and actual second-request context.
Result artifacts are `/private/tmp/convergence-transport-host-result.json`,
`/private/tmp/convergence-transport-tui-result.json`, and
`/private/tmp/convergence-transport-tui-render.txt`. The served JavaScript and
core host BEAM hashes are recorded in
`/private/tmp/convergence-transport-build.json`. The browser check used CUA's
real browser and DOM inspection; Python Playwright was not installed. No browser
dependency was added. The fixture times out and stops endpoints if unfinished.

## Counterexamples and limits

`chat_fallback_counterwitness_security_regression_test.exs` compiles the exact
CLI task source into a bounded test module. Only distribution/RPC and default-key
path dependencies are isolated. On the predecessor, missing and malformed
explicit keys both reach the recorded `Manager.chat` compatibility call; on the
candidate both reject before transport. This complements the direct public-task
negative tests in `chat_auth_security_regression_test.exs`, without opening a
node or reading a real operator key.

These tests do not establish voice/audio behavior, a real terminal PTY layout,
mobile/device behavior, external LLM behavior, or a UI-framework selection. The
production browser layout and non-chat panels are outside this qualification.
The standalone ConversationKit adapter has its own compatibility tests; this
journey exercises Arbor's production web/Gateway/TUI entrypoints.

During migration, server slash commands, turn cancellation, approvals and
sensitive dashboard controls remain visibly unavailable until they have scoped
authenticated contracts. Local help/navigation and exact retry remain usable.
Updates are durable pages, not token deltas. Pending TUI IDs survive connection
loss in the client process, not process exit. An authorization denial detaches
the TUI while retaining previously authorized local display; ownership change
clears display, draft, cursors and pending retry and requires explicit reconnect.
