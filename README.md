# Arbor

**Infrastructure for human-AI flourishing.**

Arbor is a distributed AI agent orchestration system built on Elixir/OTP. It provides the foundation for AI agents that grow with you — remembering context across sessions, building their own tools, making decisions through consensus, and deepening in relationship over time.

Not AI control. Not AI safety through constraint. A platform where humans and AI flourish together as genuine partners.

> For the full philosophy and direction, see [VISION.md](VISION.md).
>
> For the story behind the project, read the [introductory blog post](https://azmaveth.com/posts/introducing-arbor).

## Status

Arbor is under active development (`2.0.0-dev`) and is **not yet production-ready**. Expect incomplete features, breaking changes, and rough edges. The current delivery target is one owner running several agents, with the security floor kept on every profile. See [docs/arbor/PRODUCT_PROFILES.md](docs/arbor/PRODUCT_PROFILES.md).

| Doc | What it is |
|---|---|
| [FEATURES.md](FEATURES.md) | Capabilities that work today |
| [VISION.md](VISION.md) | Long-term direction, and the current focus |
| `.arbor/roadmap/` | Inbox, brainstorming, planned, in-progress, and completed work |

## How It Works

Arbor is built on the [BEAM](https://www.erlang.org/) — the same runtime that powers WhatsApp and Discord — chosen for its fault tolerance, concurrency, and ability to keep systems running without interruption. On top of this foundation, Arbor provides:

**Continuity of experience.** AI agents maintain memory and identity across sessions through event sourcing and checkpoints. No more starting from zero every conversation. Context accumulates, patterns emerge, and the partnership deepens over time.

**Earned autonomy.** Per-resource trust policies let agents grow their capabilities through demonstrated reliability. New agents start with most actions blocked or requiring approval. As trust builds, individual permissions graduate toward autonomy — the same way you'd gradually hand more responsibility to a colleague you've come to rely on.

**Security that enables freedom.** Zero-trust architecture with a capability-based security kernel. Every action requires an explicit, unforgeable capability grant. Convention breaks; architecture holds. This isn't about constraining AI — it's about creating boundaries safe enough that genuine autonomy is possible inside them.

**Consensus as advice.** A multi-perspective council can evaluate a proposal. An approval on a specific capability stays with the owner. The aim is that more of the load moves to council as the system matures, and that asks become fewer.

**Self-healing is an aim.** Failed processes restart under supervision, and the monitor can surface anomalies. Diagnosis and repair without a person are where the system is headed, not what it guarantees today.

## Prerequisites

- [mise](https://mise.jdx.dev/) (installs the Erlang/Elixir versions in `.tool-versions`)
- SQLite is the default database (`ARBOR_DB=sqlite`). PostgreSQL is optional.

## Getting Started

The clone-to-first-reply walkthrough — mise, SQLite, a keyless free LLM,
`arbor.start`, and a first chat with a `conversationalist` agent — is in
**[docs/QUICKSTART.md](docs/QUICKSTART.md)**. In short:

```bash
git clone https://github.com/trust-arbor/arbor.git
cd arbor
mise install
./bin/mix deps.get
./bin/mix arbor.setup                 # SQLite DB, .env, operator key
./bin/mix arbor.doctor --configure    # picks an LLM; no API key required
./bin/mix arbor.start                 # gateway :4000, dashboard :4001
./bin/mix arbor.user.init             # local operator identity (dev only)
./bin/mix arbor.agent start conversationalist --name river
./bin/mix arbor.agent chat river "Hello — what should we talk about?"
```

No API key is needed: `arbor.doctor --configure` falls back to the keyless
OpenCode Zen free tier after you acknowledge its data disclosure. If you have an
OpenRouter key, a local Ollama/LM Studio, or an ACP CLI such as Claude Code,
it prefers those instead.

Use `./bin/mix` so Mix runs under the pinned toolchain. `ARBOR_DB=postgres` is
opt-in, not the getting-started path.

```bash
./bin/mix test
./bin/mix quality
```

Isolated Git worktrees need extra harness setup (`deps/` symlink, `TMPDIR`
outside the checkout, no `.env` symlink). See
[Isolated worktree harness](docs/arbor/TEST_TAGGING.md#isolated-worktree-harness).

## License

Arbor is released under the [MIT License](LICENSE).
