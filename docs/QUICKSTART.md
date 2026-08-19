# Quickstart

Clone-to-first-reply path for a local Arbor node. Created 2026-08-19.

This is the default onboarding path: **SQLite**, **no OIDC**, a **free OpenRouter
model** (or local/ACP), then a `conversationalist` agent. PostgreSQL, OIDC, and
paid APIs are optional.

For the software factory (reviewed coding dispatch), start here, then continue
with [arbor/SOFTWARE_FACTORY.md](arbor/SOFTWARE_FACTORY.md). External MCP
clients: [arbor/EXTERNAL_MCP_CLIENT.md](arbor/EXTERNAL_MCP_CLIENT.md).

## Prerequisites

- macOS or Linux
- [mise](https://mise.jdx.dev/) to install the versions in `.tool-versions`
  (currently Erlang `28.4.1`, Elixir `1.19.5-otp-28`)
- An [OpenRouter](https://openrouter.ai/) key with access to a free model, **or**
  a local runtime (Ollama / LM Studio), **or** an ACP CLI agent such as Claude
  Code

PostgreSQL is **not** required. The default is `ARBOR_DB=sqlite`.

## 1. Clone and toolchain

```bash
git clone https://github.com/trust-arbor/arbor.git
cd arbor
mise install
```

Use `./bin/mix` for every Mix command so the pinned Erlang/Elixir versions run.

## 2. SQLite setup

```bash
./bin/mix arbor.setup
```

This copies `.env.example` → `.env`, generates `ARBOR_COOKIE`, creates
`~/.arbor/arbor_dev.db`, and migrates. To use PostgreSQL instead:

```bash
ARBOR_DB=postgres ./bin/mix arbor.setup
```

## 3. Pick a free LLM

Put a free-tier key in `.env`:

```bash
OPENROUTER_API_KEY=...
```

Then let doctor prefer OpenRouter / local / ACP over paid APIs:

```bash
./bin/mix arbor.doctor --configure
```

Local alternatives: start Ollama or LM Studio before `--configure`. ACP CLIs
(Claude Code, Codex, Gemini CLI) are also preferred over paid cloud keys.

## 4. Start Arbor

```bash
./bin/mix arbor.start
```

- Gateway MCP: `http://localhost:4000/mcp`
- Dashboard: `http://localhost:4001`

Local-dev does **not** require OIDC. The dashboard establishes a stable
`human_dashboard` operator session so **Settings → External Agents** can
register a key. Production still sets `require_auth: true` and fails closed
without OIDC.

On first Register New in local-dev, Arbor auto-saves
`~/.arbor/keys/<name>_<id8>.arbor.key` at mode `0600` (never overwrites). The
success UI also shows ready-to-paste `mcpServers` JSON for `mix arbor.signer`.
Download remains the fallback. Disable auto-save with
`auto_save_external_agent_keys: false`.

## 5. First reply (conversationalist)

```bash
./bin/mix arbor.agent start conversationalist --name river
./bin/mix arbor.agent chat river "Hello — what should we talk about?"
```

Or open `http://localhost:4001/chat` and talk to the agent there.

## Cloud / onboarding caveats

- **Do not treat this path as production.** Production requires OIDC (or another
  configured authenticator) and `require_auth: true`. A missing OIDC provider
  with auth required returns 503 — it does not invent a local operator.
- **Private keys.** Auto-save is local-dev only. Never enable
  `auto_save_external_agent_keys` on a shared host.
- **AGENTS.md** in this repository is a symlink to `CLAUDE.md` for the coding
  harness. Do not replace it with a standalone onboarding doc; keep onboarding
  notes here.
- **Multi-node / durability.** SQLite is the clone-laptop default. Use
  `ARBOR_DB=postgres` when you need concurrent writers or a shared cluster
  database.
- **Paid APIs** (Anthropic, OpenAI, Gemini, xAI) work, but
  `mix arbor.doctor --configure` will not pick them while OpenRouter, a local
  server, or ACP is available.
