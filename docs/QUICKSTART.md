# Quickstart

This guide will take you through initial setup to a first conversation with a
`conversationalist` agent.

For the software factory (reviewed coding dispatch), start here, then continue
with [arbor/SOFTWARE_FACTORY.md](arbor/SOFTWARE_FACTORY.md). External MCP
clients: [arbor/EXTERNAL_MCP_CLIENT.md](arbor/EXTERNAL_MCP_CLIENT.md).

## Prerequisites

- macOS or Linux
- [mise](https://mise.jdx.dev/) to install the versions in `.tool-versions`
  (currently Erlang `28.4.1`, Elixir `1.19.5-otp-28`)
- An LLM, any one of:
  - nothing at all — the keyless OpenCode Zen free tier (see step 3)
  - an API key for any supported provider (OpenRouter, Anthropic, OpenAI,
    Google Gemini, xAI, Groq, Cerebras, Z.ai, …)
  - a local runtime such as Ollama or LM Studio
  - a coding agent you already subscribe to, driven over the
    [Agent Client Protocol](https://agentclientprotocol.com/get-started/agents)
    (ACP) — Claude Code, Codex, Gemini CLI and others listed there

SQLite is the default database and needs no setup. PostgreSQL is optional
(`ARBOR_DB=postgres`, see step 2).

## 1. Clone and toolchain

```bash
git clone https://github.com/trust-arbor/arbor.git
cd arbor
mise install
./bin/mix deps.get
```

**About `./bin/mix`.** It is a thin wrapper that runs Mix under the Erlang and
Elixir versions pinned in `.tool-versions` (via mise), regardless of what your
shell's default toolchain is. If your default already *is* Erlang `28.4.1` and
Elixir `1.19.5-otp-28`, plain `mix` works too — but the wrapper stays correct
when the pinned versions change later, so this guide uses it everywhere.

`deps.get` is a separate step because `arbor.setup` is itself a Mix task in this
umbrella — Mix must resolve and compile the project before it can run it, so the
dependencies have to exist first. Skipping it fails with
`Can't continue due to errors on dependencies`.

## 2. Setup

```bash
./bin/mix arbor.setup
```

This copies `.env.example` → `.env`, generates `ARBOR_COOKIE`, creates the
SQLite database at `~/.arbor/arbor_dev.db`, runs migrations, and generates your
operator key at `~/.arbor/identity.key` (mode `0600`, never overwritten if one
already exists).

That key is your **agent** identity — `agent_<hex>` — used by
`mix arbor.signer` for signed MCP, by the software factory, and by the
checkpoint HMAC that makes `mix arbor.pipeline.resume` work. It is not an
operator *principal*; approval flows that need an authenticated human use a
separate `human_` id (step 5).

To use PostgreSQL instead of SQLite:

```bash
ARBOR_DB=postgres ./bin/mix arbor.setup
```

## 3. Pick an LLM

```bash
./bin/mix arbor.doctor --configure
```

`arbor.doctor` lists every provider it can see, then shows the ones that are
ready as a numbered menu — type a number (or just press Enter for the
recommended one) and it writes `ARBOR_DEFAULT_PROVIDER` /
`ARBOR_DEFAULT_MODEL` to `.env`:

```
  Available LLM providers:
    1) ACP: Claude Code     acp/claude  (recommended)
    2) ACP: Codex           acp/codex
    3) OpenCode Zen (free)  opencode_zen
    4) OpenRouter           openrouter  (needs OPENROUTER_API_KEY)
    5) Anthropic            anthropic  (needs ANTHROPIC_API_KEY)

  Choose a provider [1]:
```

Each installed ACP agent gets its own row, so you choose the agent, not just
"ACP".

A provider is "ready" when its API key is in `.env`, its local server is
running, its ACP agent is installed, or it needs nothing (the free tier).
Providers that only lack an API key are listed too — pick one and paste the
key at the prompt (input is hidden); it is saved to `.env` for you. So, before
running `--configure`:

- **Have an API key?** Either pick that provider from the menu and paste the
  key when asked, or put it in `.env` first (`OPENROUTER_API_KEY`,
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `XAI_API_KEY`, …;
  `.env.example` lists them all) so it shows up as ready.
- **Running Ollama or LM Studio?** Start it first; `--configure` detects it.
- **Subscribe to a coding agent?** For Arbor-owned OpenAI or xAI OAuth, run
  `./bin/mix arbor.login openai` or `./bin/mix arbor.login xai` (then
  `./bin/mix arbor.login status`). The rpc/manual complete flow remains the
  fallback — see [arbor/SOFTWARE_FACTORY.md](arbor/SOFTWARE_FACTORY.md). For
  Claude Code run `claude`, type `/login` inside it, exit, and check
  `claude -p "say ready"` prints `ready` — then run `--configure`; it will
  recommend `acp / <agent>`. Detection only checks the binary is on `PATH`,
  not that it is logged in, so do the check. Your agent then talks through
  that subscription: no API key, no free-tier data disclosure.
- **None of the above?** A new install can run **without an API key and
  without a subscription** on the OpenCode Zen free tier. Before the first
  request Arbor shows this disclosure, which you must acknowledge once (the
  acknowledgement is stored locally):

  ```
  OpenCode Zen free tier — data disclosure

  Before Arbor sends any request to OpenCode's API (https://opencode.ai/zen):

    1. Your prompts, and any context the agent includes — such as file
       contents and command output — are sent to OpenCode's API.
    2. Arbor makes NO representations or guarantees about OpenCode's
       data-handling or privacy claims, whatever their documentation states.
    3. Do not use this free tier for sensitive, confidential, or regulated data.
  ```

  `./bin/mix arbor.llm.free` lists the free models Arbor will use.

Without a terminal (piped input, scripts) or with `--non-interactive`, it takes
the recommended provider automatically. To name one directly and skip the menu:

```bash
./bin/mix arbor.doctor --configure --provider opencode_zen
./bin/mix arbor.doctor --configure --provider acp --acp-agent codex
```

The choice in `.env` is read when the server starts and becomes the default for
new agents. You can switch a running agent's model at any time from chat with
`/model <model-id>` (`/model list` shows what is available); `mix arbor.agent
status <name>` shows what it is currently using.

## 4. Start Arbor

```bash
./bin/mix arbor.start
```

This starts the server as a background daemon and prints the log path.

- Gateway MCP: `http://localhost:4000/mcp`
- Dashboard: `http://localhost:4001`

If those ports are taken, set `ARBOR_GATEWAY_PORT` and/or `ARBOR_DASHBOARD_PORT`
in `.env` before starting.

In local development mode no external authentication is required to use
Arbor. Production environments fail closed without an identity provider — see
the caveats at the end.

Useful afterwards: `./bin/mix arbor.status`, `./bin/mix arbor.restart`,
`./bin/mix arbor.stop`.

## 5. Local operator identity (development only)

```bash
./bin/mix arbor.user.init
```

Creates your **human** principal — the account agents and grants belong to —
with a real Ed25519 + X25519 keypair, and writes `~/.arbor/operator.key` so the
CLI can prove it is you.

The id is **deterministic**: it is a hash of `arbor://local` plus
`<os-username>@<hostname>`. Re-running the command loads the same identity
instead of minting a second one — but that also means a different OS user, a
renamed host, or an Arbor installation moved to another machine derives a
*different* id. Your grants and agents belong to the old one. Keep the key file,
and if you do move, fold the new id onto the original one:

```bash
./bin/mix arbor.user.link <new_id> --to <your_original_id>
```

> **This is a development-only path.** Arbor normally derives a human principal
> from an authenticated login through an identity provider, and refuses to
> register a `human_` identity any other way. A single-operator laptop has no
> identity provider, so this task mints one from local claims as an explicit,
> gated exception. Three independent gates keep it out of production:
> `allow_local_human_identity` must be `true` (default `false`, set only in
> `dev.exs`), no identity provider may be configured, and `MIX_ENV` must be
> `dev`.

When you later add a real identity-provider login, it derives its own id; link
it to this one the same way so your grants and agents carry over.

## 6. First reply (conversationalist)

```bash
./bin/mix arbor.agent start conversationalist --name river
./bin/mix arbor.agent chat river "Hello — what should we talk about?"
```

Or open `http://localhost:4001/chat` and talk to the agent there.

On the free tier the first reply can take 20–60 s, because it is a shared free
service. Through an ACP agent such as Claude Code it took 15–30 s in our runs.
`chat` exits non-zero and prints the server log path if the turn fails.

If a turn through an ACP agent fails and the server log shows
`OAuth session expired and could not be refreshed`, the CLI's login has
lapsed — open the CLI and `/login` again. Arbor never stores or refreshes those
credentials itself.

An ACP agent is the coding agent you already have, running in the Arbor
checkout's working directory. Every tool it wants to use is checked against
the Arbor agent's capabilities first (`permission_mode: :default`), so a
fresh `conversationalist` can talk but cannot read or change your files until
you grant it that.

Agents do not auto-resume after `mix arbor.restart` / `mix arbor.stop`. Bring
one back with `mix arbor.agent resume river`, or run
`mix arbor.agent auto-start river` once so it comes up with the server.

## Caveats

- **Do not treat this path as production.** Production requires an identity
  provider (OIDC or another configured authenticator) and `require_auth: true`.
  A missing provider with auth required returns 503 — it does not invent a
  local operator.
- **Private keys.** `~/.arbor/identity.key` and `~/.arbor/operator.key` are
  plaintext, mode `0600`. Never enable `auto_save_external_agent_keys` on a
  shared host.
- **AGENTS.md** in this repository is a symlink to `CLAUDE.md` for the coding
  harness. Do not replace it with a standalone onboarding doc; keep onboarding
  notes here.
- **Multi-node / durability.** SQLite is the single-machine default. Use
  `ARBOR_DB=postgres` when you need concurrent writers or a shared cluster
  database.
- **Stay single-node while onboarding.** Signed MCP refuses whenever this node
  is connected to a peer that also runs `:arbor_security`, because nonces are
  node-local and a captured request could be replayed against that peer. If
  `mix arbor.signer` returns 401, the response names the reason
  (`cluster_replay_protection_unavailable`); disconnect with
  `mix arbor.cluster disconnect <node>`. Both ends redial every 30s, and a
  third non-hidden node connected to both will re-mesh them regardless — see
  `mix help arbor.cluster`.
