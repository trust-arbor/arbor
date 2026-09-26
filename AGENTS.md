# AGENTS.md

> **Note:** This file used to be a symlink to `CLAUDE.md`. It is now a standalone
> file so Cursor Cloud agents get dedicated startup guidance without inflating
> `CLAUDE.md` (which is under a CI-enforced 4,000-word ceiling — see
> `.claude/validate_applied_learning.rb`). **`CLAUDE.md` remains the
> authoritative engineering guide (architecture, patterns, security gates,
> Applied Learning) — read it for everything beyond environment startup.**

## Cursor Cloud specific instructions

Arbor is an Elixir/OTP umbrella. The toolchain is **mise-managed** (Erlang
`28.4.1` / Elixir `1.19.5-otp-28`, pinned in `.tool-versions`). Always run Mix
via **`./bin/mix`** (its header explains why) — it puts the mise-pinned
Erlang+Elixir first on PATH. Bare `mix`/`iex` are **not** on PATH; for a raw
`iex` session prepend `"$(mise where erlang)/bin"` and `"$(mise where elixir)/bin"`.

Standard commands are already documented — don't duplicate them here. See the
root `mix.exs` aliases (`setup`, `quality`, `security`, `test.fast`, `test.all`)
and the `mix arbor.*` tasks (`arbor.setup`, `arbor.start`, `arbor.doctor`, …).

Non-obvious caveats (these cost real time to rediscover):

- **The full running system (`phx.server` / the dashboard) requires PostgreSQL
  in dev — NOT SQLite.** `config/dev.exs` wires the
  `Arbor.Persistence.QueryableStore.Postgres` backend for the
  actions/comms/memory/orchestrator/trust stores. On SQLite the app **crashes at
  boot** (`arbor_scheduler` → trust-profile persist →
  `Exqlite ... unsupported type: %{...}`) because the store writes Elixir maps as
  `jsonb`. SQLite is fine only for `mix arbor.setup` and `mix test.fast`.
- **`ARBOR_DB` is a compile-time adapter selection.** `config/dev.exs` reads
  `ARBOR_DB` while compiling (and `.env` is loaded at compile time). To run on
  Postgres: set `ARBOR_DB=postgres` (env or `.env`) **and**
  `./bin/mix compile --force` — otherwise you hit
  `:repo_adapter ... different value ... during runtime compared to compile time`.
- Postgres dev connections: `Arbor.Persistence.Repo` → db `arbor_persistence_dev`,
  user `arbor_dev` (empty password), host `localhost`. The `arbor_persistence_ecto`
  EventStore defaults to `postgres`/`postgres`, db `trust_arbor_dev`. Migrations
  need the **pgvector** extension (`CREATE EXTENSION vector`); the package is
  `postgresql-16-pgvector`.
- Start Postgres in the Cloud VM (no systemd): `sudo pg_ctlcluster 16 main start`.
  Localhost auth is set to `trust` in `pg_hba.conf` so the empty-password
  `arbor_dev` role connects. Roles `arbor_dev` (SUPERUSER/CREATEDB) and
  `postgres` (password `postgres`) and dbs `arbor_persistence_dev` +
  `trust_arbor_dev` already exist in the snapshot.
- Bring up the app (Postgres):
  `ARBOR_DB=postgres ./bin/mix ecto.create -r Arbor.Persistence.Repo` →
  `ARBOR_DB=postgres ./bin/mix ecto.migrate -r Arbor.Persistence.Repo` →
  `ARBOR_DB=postgres ./bin/mix phx.server` (or `iex -S mix phx.server`).
  Dashboard: http://localhost:4001. Cold umbrella boot takes a while.
- Dashboard dev has `require_auth: false` (the `true` in `runtime.exs` is
  prod-only), so pages load without OIDC. But Settings → "External Agents"
  *registration* needs a signed-in human (OIDC), so it's unusable without
  `OIDC_ISSUER`/`OIDC_CLIENT_ID`. To create an agent without OIDC, from an
  `iex -S mix phx.server` session run
  `Arbor.Agent.Lifecycle.create("Name", template: "scout")` (templates live in
  `apps/arbor_agent/priv/templates/*.md`); the agent shows live on `/agents`.
- `mix arbor.setup` may fail at its internal "Fetching dependencies" step
  (`Hex.Stdlib ... undefined`) because it re-runs `deps.get` in the same session
  after `local.hex`. Harmless — run `./bin/mix deps.get` on its own; the env
  (.env/cookie/`~/.arbor`), db, and compile steps all work.
- Optional services log warnings at boot but never block: `signal-cli`
  (`{:executable_not_found, "signal-cli"}`), the Limitless poller,
  `CapabilitySync ... standalone mode`, and missing LLM API keys (real agent LLM
  turns need keys in `.env`).
- `test.fast` runs the whole umbrella and is slow cold (test-env compile of
  ~3k files). A handful of failures are **environment-specific to the sandbox
  VM, not code bugs**: distributed `:peer`-node tests, shell process-group/fork
  containment (`sh: Cannot fork`), a `/workspace` symlink-escape `FileGuard`
  test, and an embedding-provider test.
