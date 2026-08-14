# AGENTS.md

> **Note:** This file used to be a symlink to `CLAUDE.md`. It is standalone so
> Cursor Cloud agents get startup guidance without inflating `CLAUDE.md`
> (CI-enforced 4,000-word ceiling — see `.claude/validate_applied_learning.rb`).
> **`CLAUDE.md` remains the authoritative engineering guide** (architecture,
> patterns, security gates, Applied Learning).

## Cursor Cloud specific instructions

Arbor is an Elixir/OTP umbrella. Toolchain is **mise-managed** (Erlang `28.4.1` /
Elixir `1.19.5-otp-28` in `.tool-versions`). Always use **`./bin/mix`** — bare
`mix`/`iex` are not on PATH in non-interactive shells; for raw `iex` prepend
`"$(mise where erlang)/bin"` and `"$(mise where elixir)/bin"`.

Human first-run walkthrough: **`docs/QUICKSTART.md`**. Standard commands live in
root `mix.exs` aliases (`setup`, `quality`, `test.fast`, `test.all`) and
`mix arbor.*` (`arbor.setup`, `arbor.start`, `arbor.doctor`, …).

### Non-obvious caveats

- **SQLite is the real default** (`ARBOR_DB` unset). After the QueryableStore
  dual-adapter + Oban Lite/PG notifier fixes, `./bin/mix phx.server` boots the
  full dashboard on SQLite. Postgres (`ARBOR_DB=postgres`) remains the
  power-user / production path (pgvector, hybrid search).
- **`ARBOR_DB` is compile-time.** Switching adapters requires
  `./bin/mix compile --force` (or a clean `_build`) or you hit
  `:repo_adapter` compile_env mismatch. `.env` is loaded at compile time in
  `config/dev.exs` — keep `ARBOR_DB` consistent with how you last compiled.
- **Dev External Agents need no OIDC.** With `dev_local_operator: true` (set in
  `config/dev.exs`), `OidcAuth` auto-establishes a stable
  `human_42c59f5a…` / "Local Dev Operator" session when OIDC is unset and
  `require_auth` is false. `/settings` shows **Register New**. Prod stays
  fail-closed (`require_auth: true` → 503 without OIDC).
- **Free first LLM response:** add `OPENROUTER_API_KEY` (free account at
  openrouter.ai) then `./bin/mix arbor.doctor --configure`. Defaults are
  already `openrouter` / `openai/gpt-oss-120b:free`. Doctor priority is
  OpenRouter → Groq → ACP → local → paid. Groq via `GROQ_API_KEY` is a solid
  free backup; ACP reuses an already-authenticated claude/codex/gemini CLI.
- Cold umbrella boot is slow (~1 min). Dashboard: http://localhost:4001.
  Optional services (signal-cli, Limitless, LLM keys) log warnings and do not
  block boot.
- `test.fast` is large; a few failures are sandbox-specific (distributed
  `:peer`, fork/process-group containment, `/workspace` symlink-escape), not
  code bugs from this onboarding work.
- `mix arbor.setup` may fail its internal re-`deps.get` (`Hex.Stdlib` quirk);
  run `./bin/mix deps.get` alone first — env/db/compile steps still work.
