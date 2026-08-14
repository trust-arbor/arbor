# Arbor Quickstart

Get from a fresh clone to a first agent reply in about fifteen minutes.
No PostgreSQL, no OIDC, and no paid API key required.

> Status: Arbor is under active development and **not production-ready**.
> This guide targets local development on a single machine.

## What you will do

1. Install the pinned Elixir/OTP toolchain
2. Bootstrap the project (SQLite by default)
3. Add a free OpenRouter API key
4. Start the server and dashboard
5. Create a conversationalist agent and get a reply

## Prerequisites

- A Unix-like machine (macOS or Linux)
- Git, curl, and a C toolchain (needed to build Erlang via mise on some platforms)
- [mise](https://mise.jdx.dev/getting-started.html) — Arbor pins Erlang and Elixir in `.tool-versions`

Postgres, OIDC, Docker, and paid LLM keys are **optional**. Skip them for this guide.

## 1. Clone and install the toolchain

```bash
git clone https://github.com/trust-arbor/arbor.git
cd arbor

# Install mise if you do not have it: https://mise.jdx.dev/getting-started.html
mise install          # installs Erlang + Elixir from .tool-versions
```

Always run Mix through the repo wrapper so the pinned toolchain is used
(mise does not activate in non-interactive shells):

```bash
./bin/mix --version
# Expect Elixir 1.19.x and OTP 28
```

## 2. Bootstrap

```bash
./bin/mix arbor.setup
```

This is idempotent. It will:

- Install Hex/Rebar and fetch dependencies
- Create `.env` from `.env.example` (if missing)
- Generate `ARBOR_COOKIE` into `.env`
- Create `~/.arbor/`
- Create and migrate the **SQLite** database (default)
- Compile the umbrella

When it finishes, note the printed next steps. If the internal
“Fetching dependencies” step fails with a Hex reload quirk, run
`./bin/mix deps.get` once and re-run `./bin/mix arbor.setup`.

## 3. Free LLM (first reply)

Arbor’s built-in default is already a free OpenRouter model
(`openrouter` / `openai/gpt-oss-120b:free`). You only need a key:

1. Create a free account and key at [openrouter.ai/keys](https://openrouter.ai/keys)
2. Put it in `.env`:

   ```bash
   OPENROUTER_API_KEY=sk-or-...
   ```

3. Let doctor write the provider/model defaults:

   ```bash
   ./bin/mix arbor.doctor --configure
   ```

### Other free options

| Option | When to use | How |
|---|---|---|
| **Groq free tier** | Fast cloud backup | `GROQ_API_KEY=...` then `./bin/mix arbor.doctor --configure` |
| **Already-logged-in CLI** (Claude / Codex / OpenCode) | You already have a CLI login / free OpenCode tier | Doctor detects ACP; no new API key. (Gemini CLI is deprecated; Antigravity/`agy` does not speak ACP yet.) |
| **Ollama** | Fully local, no cloud account | Install Ollama, pull a model, re-run doctor |

See `.env.example` for the full list.

## 4. Start Arbor

Prefer the background daemon (required for `mix arbor.*` agent commands):

```bash
# Cookie is already in .env after setup; export if your shell does not load it
set -a && source .env && set +a

./bin/mix arbor.start
./bin/mix arbor.status        # wait until ready (cold boot can take ~1 min)
```

Dashboard: [http://localhost:4001](http://localhost:4001)

In open-dev (no OIDC) you are signed in automatically as
**Local Dev Operator** — External Agents registration works without Zitadel.

### Interactive alternative

```bash
./bin/mix phx.server
# or: iex -S mix phx.server   (put mise Erlang+Elixir bins on PATH first)
```

`phx.server` serves the dashboard but does **not** satisfy
`mix arbor.agent` RPC (that needs `arbor.start` + `ARBOR_COOKIE`).

Useful companions: `./bin/mix arbor.stop`, `./bin/mix arbor.logs`,
`./bin/mix arbor.doctor`.

## 5. Create an agent and get a reply

```bash
./bin/mix arbor.agent templates
./bin/mix arbor.agent start conversationalist --name "Hello"
./bin/mix arbor.agent chat Hello "Say hello in one short sentence."
```

You should see a model reply in the terminal. In the dashboard:

- [http://localhost:4001/agents](http://localhost:4001/agents) — agent profile
- [http://localhost:4001/chat](http://localhost:4001/chat) — chat UI (select the agent)

### External Agents (optional)

Use this when you want **Claude Code / Codex / OpenCode** (or another MCP host)
to call Arbor as a verified principal — not for the in-cluster
conversationalist chat above.

1. Open [Settings](http://localhost:4001/settings) → **External Agents** →
   **Register New** (pick a type, e.g. Claude Code).
2. On success, local-dev **auto-saves** the private key to
   `~/.arbor/keys/<name>_<id8>.arbor.key` (mode `600`) and shows a ready-to-paste
   **MCP host config**. Copy that JSON into your client config, or hand it to an
   agent and ask it to add the Arbor MCP server.
3. Keep Arbor running (`arbor.start`). Gateway MCP is `http://localhost:4000/mcp`.
4. Smoke-test the signing proxy (optional — your MCP host will spawn this):

```bash
./bin/mix arbor.signer \
  --key-file ~/.arbor/keys/<the-file-shown-in-the-modal>.arbor.key \
  --upstream http://localhost:4000/mcp
```

If auto-save is disabled (non-dev) or fails, use **Download .key** from the modal
and substitute that path in the MCP config.

Full detail (Bearer vs signed proxy, tool disclosure, coding-task dispatch):
[EXTERNAL_MCP_CLIENT.md](arbor/EXTERNAL_MCP_CLIENT.md).

## 6. Day-2 quality checks (optional)

```bash
./bin/mix test.fast    # unit tests (excludes database / LLM / external)
./bin/mix quality      # format check + credo --strict + …
```

## Common footguns

| Symptom | Likely cause | Fix |
|---|---|---|
| Wrong Elixir/OTP / obscure compile errors | System Mix instead of pinned toolchain | Use `./bin/mix`, not bare `mix` |
| `:repo_adapter` compile_env mismatch | Switched `ARBOR_DB` without recompiling | `./bin/mix compile --force` |
| `mix arbor.agent` cannot reach the node | Server not started as daemon, or missing cookie | `source .env` then `./bin/mix arbor.start` |
| Agent runs but empty / error replies | No LLM key, or free-tier rate limit | Check `.env`, `./bin/mix arbor.doctor`, try Groq or a different free model |
| Want Postgres | Power-user / production path | `ARBOR_DB=postgres` in `.env`, ensure Postgres + pgvector, `compile --force`, `ecto.create` + `ecto.migrate` |

## Where next

- Vision and philosophy: [VISION.md](../VISION.md)
- OIDC / human identity: [docs/oidc-setup.md](oidc-setup.md)
- External MCP clients: [docs/arbor/EXTERNAL_MCP_CLIENT.md](arbor/EXTERNAL_MCP_CLIENT.md)
- DOT pipelines: [docs/arbor/DOT_PIPELINE_GUIDE.md](arbor/DOT_PIPELINE_GUIDE.md)
- Engineering guide (contributors / agents): [CLAUDE.md](../CLAUDE.md)
