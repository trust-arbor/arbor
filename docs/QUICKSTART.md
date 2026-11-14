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
- A C compiler and `make` (Xcode Command Line Tools on macOS,
  `build-essential` on Debian/Ubuntu). Arbor compiles a small sandbox
  launcher in C. If mise has no prebuilt Erlang for your platform it builds
  OTP from source, which also needs the OpenSSL and ncurses development
  headers (`libssl-dev libncurses-dev` on Debian/Ubuntu).
- Network access to hex.pm and github.com for `deps.get` and the first compile
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

### Optional voice

The default build excludes `arbor_voice` and `arbor_multimedia` from dependency
resolution, compilation, and application startup. The dashboard works without
them and hides local voice controls when the voice libraries are unavailable.
Leaving old voice dependencies in `deps/` does not enable them automatically.
The shared `mix.lock` retains pins for both build modes; an unused-lock check in
core mode will also report the optional voice dependency closure.

Voice currently requires the pinned `membrane_core` and
`membrane_portaudio_plugin` forks declared in `apps/arbor_multimedia/mix.exs`.
They are hosted on a private network and are not available to public users.
If you have access, enable voice **in your shell before running Mix**:

```bash
export ARBOR_VOICE=true
./bin/mix deps.get
./bin/mix compile
ARBOR_AUDIO_DRIVER=native ./bin/mix arbor.start
```

Keep `ARBOR_VOICE=true` set for subsequent Mix commands, including voice tests
and release builds. This is a build selector, so putting it only in `.env` is
too late. `ARBOR_AUDIO_DRIVER=native` selects host audio at runtime; it does not
fetch or enable the optional apps. Enabling voice without access to the forks
will fail during `deps.get`; leave `ARBOR_VOICE` unset (or set it to `false`)
to run core Arbor. Restart your own Arbor node after changing the build selector.
Existing microphone permissions, provider credentials, and voice capability
requirements still apply.

### Optional features (off by default)

A fresh install runs single-node and sends every model call through the one
provider `mix arbor.doctor --configure` sets up (step 3), including context
summaries and spawned workers. These extras are off until you switch them on
in `.env`. They are read when Arbor boots, so restart after changing them:

| Variable | Turns on | Needs |
|---|---|---|
| `ARBOR_PROVIDER_ROUTE_PROFILE=true` | The reviewed OAuth routing profile | `arbor.login openai` and `arbor.login xai` |
| `ARBOR_PREPROCESSOR=true` | The pre-turn preprocessor and the boot-time local-model check | LM Studio on `localhost:1234` with the configured models loaded |
| `ARBOR_CLUSTER=true` | Signals relay to peers, hardware scouting, cluster redials | More than one node (see the tip on staying single-node below) |
| `ARBOR_DAILY_PIPELINES=true` | The maintainer's daily scheduler pipelines | Their signing issuer; they fail closed elsewhere |

To pin a different model for one job, set `ARBOR_SUMMARIZER_MODEL` +
`ARBOR_SUMMARIZER_PROVIDER`, `ARBOR_WORKER_MODEL` + `ARBOR_WORKER_PROVIDER`, or
`ARBOR_ACP_CLAUDE_MODEL` (Claude Code over ACP uses Claude Code's `sonnet`
alias unless you set it). `.env.example` lists them all.

## 2. Setup

```bash
./bin/mix arbor.setup
```

This copies `.env.example` → `.env`, generates `ARBOR_COOKIE`, creates the
SQLite database at `~/.arbor/arbor_dev.db`, runs migrations, and generates your
operator key at `~/.arbor/identity.key` (mode `0600`, never overwritten if one
already exists).

`ARBOR_COOKIE` is the Erlang distribution cookie. `mix arbor.start` copies it
to `~/.arbor/distribution/.erlang.cookie` (directory `0700`, file `0600`); the
daemon reads it from there, so the value never appears in the daemon's
command line or environment. The daemon accepts no node connections until
that cookie is in place. All other daemon state, including the security
store (`~/.arbor/security/master.key` and the revocation ledger), lives
directly under `~/.arbor`.

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

### Upgrading an install that ran Arbor between 2026-10-07 and 2026-11-13

Daemons in that window ran with `HOME` set to the cookie directory, so they
kept their security store and other state under
`~/.arbor/distribution/.arbor/` instead of `~/.arbor/`. `arbor.start` refuses
to launch while that directory exists. Move it back once:

```bash
./bin/mix arbor.stop
```

```bash
./bin/mix arbor.home.migrate
```

The dry run prints the plan and changes nothing. Files only in the old
location move; identical copies are dropped. When both locations hold
different versions of a file, the old-location copy wins, because it is the
one the daemon was using, and the current copy is kept beside it as
`<name>.pre-home-migration-<YYYYMMDD>`. Symlinks, a file facing a directory,
or a SQLite database present in both places block the migration until you
resolve them by hand. When the plan looks right:

```bash
./bin/mix arbor.home.migrate --apply
```

Then start Arbor again. The cookie file stays in `~/.arbor/distribution/`.

### If the server does not start

When startup fails, `arbor.start` prints the first failure from
`~/.arbor/logs/arbor-dev.log`. It also reports a node stuck mid-boot instead of
waiting out the full timeout. Common first-run causes:

- **`:session_token_secret_missing`**: set `ARBOR_SESSION_TOKEN_SECRET` in
  `.env` to at least 32 random bytes (for example `openssl rand -base64 48`).
- **Older daemon state under `~/.arbor/distribution/.arbor`**: run
  `mix arbor.home.migrate` (see the previous section).
- **`:offline_migration_required`**: the security store in `.arbor/security`
  was written by an older Arbor (before 2026-10-07), and there is no migration
  tool yet. The error names the directory. To start fresh, stop Arbor, move the
  directory aside as a backup, and start again:

  ```bash
  ./bin/mix arbor.stop
  ```

  ```bash
  mkdir -p ~/.arbor/backups && mv .arbor/security ~/.arbor/backups/security-$(date +%Y%m%d)
  ```

  Identities, capabilities and grants in the old store do not carry over; run
  §5 again afterwards.

A half-started server may still be running after a failure. Stop it with
`./bin/mix arbor.stop` before starting again.

## 5. Local operator identity (development only)

```bash
./bin/mix arbor.user.init
```

Creates your **human** principal — the account agents and grants belong to.
The task generates an Ed25519 keypair on your machine and writes the private key
to `~/.arbor/operator.key` (mode `0600`) so the CLI can prove it is you. Only
the public key is registered with the server, which never holds your private
key. Keep the file: it is the only copy.

On a fresh install it also completes **genesis**: every grant needs an actor
that already holds a matching capability, so nothing can be granted until a
first administrator exists. The task signs a genesis request with the key file,
and while no administrator exists yet the server grants this identity
`arbor://**`. Later runs report that genesis is already closed and grant
nothing. Run it before configuring an identity provider — genesis is refused
once one is configured.

The id is **deterministic**: it is a hash of `arbor://local` plus
`<os-username>@<hostname>`. Re-running the command with the same key file loads
the same identity instead of minting a second one. If the identity exists but
its key file is missing, the task stops instead of generating a second key:
restore the file, or pass `--key-file PATH`.

Because the id comes from the user and host, a different OS user, a renamed
host, or an Arbor installation moved to another machine derives a *different*
id. Your grants and agents belong to the old one. Keep the key file,
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

### Provision the scheduler

The scheduler never grants itself authority. On a fresh install it starts
**dormant**: Arbor runs normally, but scheduled jobs are held in standby and
nothing executes or fires from cron. Once genesis has made you an
administrator, grant it its capabilities with your key file:

```bash
./bin/mix arbor.scheduler.provision --key-file ~/.arbor/operator.key
```

`./bin/mix arbor.scheduler.provision --status` shows whether it is still
dormant and which capabilities it lacks. A provisioned scheduler runs your own
jobs; the maintainer's daily pipelines stay off unless
`ARBOR_DAILY_PIPELINES=true`.

## 6. First reply (conversationalist)

```bash
./bin/mix arbor.agent start conversationalist --name river
./bin/mix arbor.agent chat river "Hello — what should we talk about?"
```

`start` and `chat` sign with `~/.arbor/operator.key` from §5 (pass
`--key-file PATH` if yours is elsewhere). Only the signed request reaches the
server; the private key stays in the file.

The dashboard's conversation page (`http://localhost:4001`) needs a signed-in
session, which the local operator from §5 does not have yet, so talk to the
agent through the CLI.

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
  `mix arbor.cluster disconnect <node>`. With `ARBOR_CLUSTER=true` both ends
  redial every 30s, and a third non-hidden node connected to both will re-mesh
  them regardless — see `mix help arbor.cluster`. When you do go multi-node,
  set `ARBOR_CLUSTER=true` on every node so signals reach peers.
