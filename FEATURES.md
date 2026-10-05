# Arbor Features

What a running Arbor can do today. Aims are in [VISION.md](VISION.md). Work that
is not shipped is in `.arbor/roadmap/`.

Checked against the tree on 2026-09-28. This replaced the 2026-07-04 inventory,
which had drifted into module counts, retired trust tiers, and claims about
apps that have since been folded into `arbor_kernel` and `arbor_kernel_runtime`.

## Keeping this file true

Update this file in the same change that adds, removes, or changes a
user-visible capability. One bullet, naming the facade, command, or route a
reader can open.

Do not record counts, conformance scores, test totals, or a catalog of every
action and Mix task. Those go stale on their own, and generating them would
list code that exists rather than behavior that is wired.

If a bullet is no longer true, delete it in the change that removes the
behavior.

## Agents

- `Arbor.Agent.Lifecycle` creates an agent. The agent runs under a
  `BranchSupervisor` (`rest_for_one`): APIAgent host, executor, session, then
  an optional heartbeat.
- `mix arbor.agent start` and `mix arbor.agent chat` are the local operator
  path. Chat signs with the operator key from `mix arbor.user.init`.
- Heartbeats run a DOT pipeline on a cadence and can select a cognitive mode.
  Mode selection is still a stateless rule.
- The conversation host admits a command, then lets a client disconnect and
  read the saved result. Dashboard chat and the gateway/TUI private-chat
  routes use it. Entry points are `Arbor.Agent.submit_conversation_command/4`,
  `conversation_command/4`, `conversation_events/4`, and `conversation_history/3`.
  Each call needs a session token or a fresh signed request. See
  [docs/arbor/CONVERSATION_HOST_BOUNDARY.md](docs/arbor/CONVERSATION_HOST_BOUNDARY.md).
- One private engagement is derived from the authenticated owner and the agent.
  A client can pin that id as a compare-only fence. It cannot choose a
  different conversation with it.

## Trust and security

- `Arbor.Security` grants and checks unforgeable capability tokens on resource
  URIs, and holds per-agent Ed25519 identity.
- `Arbor.Trust` decides whether a held capability may run. A profile is
  URI-prefix rules in `block`, `ask`, `allow`, and `auto`, with security
  ceilings. There is no scalar trust tier.
- Graduation widens one capability rule after repeated confirmations. It is a
  suggestion path. Shell, governance, and hot load do not become `auto`
  (`Arbor.Trust.ApprovalGuard`).
- An `ask` escalates through `Arbor.Security.Escalation`. The dashboard chat
  card can approve or deny.
- File access is path-scoped. Egress of sensitive data is a separate gate from
  ordinary capability checks. Taint is tracked on data and on pipeline nodes.
- Sensitive-disclosure consent is part of the security floor. Coverage is not
  complete on every outbound path.

## Memory

- `Arbor.Memory` stores per-agent working memory, a knowledge graph, and a
  vector index, and can recall by similarity.
- A user turn receives recalled memories. The session graph passes
  `session.recalled_memories` into prompt construction, which adds a "Relevant
  memories from past sessions" section when recall is non-empty.
- Goals, relationships, and chat history have their own stores. A single
  human-editable memory page is not built yet.

## Models and tools

- `Arbor.LLM` calls models through ReqLLM. Cloud providers are whatever
  ReqLLM lists. Arbor adds `ollama`, `lm_studio`, and keyless `opencode_zen`.
  `mix arbor.doctor --configure` selects one.
- Coding agents (Claude Code, Codex, Gemini CLI, and others) are reached
  through ACP in `arbor_ai`.
- Side effects are Jido actions in `arbor_actions`, each gated by a capability
  URI. Sessions disclose tools progressively (`tool_find_tools`, `tool_help`)
  rather than loading the whole set into the prompt.
- `Arbor.Shell.execute/2` runs a host command in `:none`, `:basic`, or
  `:strict`. For agents, macOS applies an OS policy, and other platforms
  refuse with `:agent_containment_unavailable`. `:none` cannot widen that
  policy. See [docs/arbor/AGENT_SHELL_CONTAINMENT.md](docs/arbor/AGENT_SHELL_CONTAINMENT.md).
- `Arbor.Shell.execute_spawn_capable/3` runs a trusted Mix tool inside an
  admitted validation runtime. The boot-pinned runtime in that path is Apple
  Container; the OCI plan core targets Podman.

## Orchestration

- `Arbor.Orchestrator.Engine` runs a DOT graph. Core node types are the map in
  `Arbor.Orchestrator.Handlers.Registry` (including `sanitize` and `extract`).
  Handlers are registered by type string in `Arbor.Common.HandlerRegistry`.
- The engine checkpoints, checks capabilities per node, and carries taint.
  `Engine.run/2` returns a result envelope. Callers have to read
  `final_outcome.status`.
- `Arbor.Scheduler` runs pipelines and actions once, after a delay, or from
  the Oban cron list in config. The cron list is edited in config, not through
  a runtime API.

## Interfaces

Surfaces share an engagement. The wire protocol for "leave and return to the
same actor session" is [DASP](https://dasp-protocol.github.io/dasp/). The
conversation host above is the implementation that dashboard, gateway/TUI, and
CLI use today. It does not speak DASP, and it does not require a DASP client.

- Dashboard (`arbor_dashboard`, port 4001 in the quickstart): landing, chat,
  agents, memory, channels, signals, events, consensus, monitor, telemetry,
  eval, roadmap, settings.
- Gateway (`arbor_gateway`, port 4000): MCP server on `/mcp`, MCP client to
  external servers, health. `ex_mcp` 1.3.0 is pinned to `protocol_mode:
  :legacy_only`.
- CLI via `mix arbor.*`, run through `./bin/mix`.
- Terminal: `arbor-tui` in `clients/arbor_breeze`, using Breeze and shared
  ConversationKit/Client packages. `arbor-tui-legacy` in `clients/arbor_tui`
  retains the previous TermUI client for explicit rollback.
- Voice (`Arbor.Voice`): authenticated text and one-shot PCM turns share the
  private conversation. The local Desk captures and plays the Arbor host's audio
  through direct localhost Dashboard controls, with configurable recording length,
  sample-readiness cues, early Finish and Cancel. Final PCM speech has a configurable
  word cap (default `nil`) and exact-text, format and authorization guards; the UI
  distinguishes playback from screen-only completion. Each utterance uses a fresh
  Session. DASP conformance and continuous microphone streaming remain outside
  this interface. See [local voice checks](docs/arbor/VOICE_LOCAL_TEST_GUIDE.md) and
  [voice convergence](docs/arbor/CONVERSATION_VOICE_CONVERGENCE.md).
- Signal (`Arbor.Comms`, via `signal-cli`) can send and receive. Limitless is
  a second inbound channel. Signal as a full engagement surface is still
  planned. It is not a DASP client.

## Council, factory, and operations

- `mix arbor.consult` runs a multi-perspective advisory council.
  `Arbor.Consensus` can also submit a proposal and record a decision. Neither
  replaces a human approval on a capability ask.
- Coding dispatch is a signed MCP tool, `arbor_dispatch_task`. It produces
  reviewable changes. It does not merge or authorize on its own. Operator
  setup is [docs/arbor/CODING_TASK_DISPATCH.md](docs/arbor/CODING_TASK_DISPATCH.md)
  and [docs/arbor/SOFTWARE_FACTORY.md](docs/arbor/SOFTWARE_FACTORY.md).
- SQLite is the default database. Postgres is `ARBOR_DB=postgres`.
- `Arbor.Signals` and `Arbor.Monitor` live in `arbor_kernel_runtime`.
  `Arbor.Historian` stores events. Contracts are `Arbor.Contracts` in
  `arbor_kernel`.

## Retired claims

These were in the old feature list and are not current behavior.

- Scalar trust tiers, and any score that mints capabilities.
- Standalone apps named `arbor_contracts`, `arbor_common`, `arbor_signals`,
  or `arbor_monitor`.
- A published MCP conformance score or a frozen test-pass count.
- "Container mode" as something that is only planned. Spawn-capable execution
  has a pinned container runtime; native `execute/2` still uses the host
  sandbox modes above.
