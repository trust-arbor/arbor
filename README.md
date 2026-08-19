# Arbor

**Infrastructure for human-AI flourishing.**

Arbor is a distributed AI agent orchestration system built on Elixir/OTP. It provides the foundation for AI agents that grow with you — remembering context across sessions, building their own tools, making decisions through consensus, and deepening in relationship over time.

Not AI control. Not AI safety through constraint. A platform where humans and AI flourish together as genuine partners.

> For the full philosophy and direction, see [VISION.md](VISION.md).
>
> For the story behind the project, read the [introductory blog post](https://azmaveth.com/posts/introducing-arbor).

## Status

Arbor is under active development and is **not yet production-ready**. The codebase is being ported and restructured — expect incomplete features, breaking changes, and rough edges. Contributions and feedback are welcome, but please set expectations accordingly.

## How It Works

Arbor is built on the [BEAM](https://www.erlang.org/) — the same runtime that powers WhatsApp and Discord — chosen for its fault tolerance, concurrency, and ability to keep systems running without interruption. On top of this foundation, Arbor provides:

**Continuity of experience.** AI agents maintain memory and identity across sessions through event sourcing and checkpoints. No more starting from zero every conversation. Context accumulates, patterns emerge, and the partnership deepens over time.

**Earned autonomy.** Trust tiers let agents grow their capabilities through demonstrated reliability. New agents start with limited permissions. As trust builds, autonomy expands — the same way you'd gradually hand more responsibility to a colleague you've come to rely on.

**Security that enables freedom.** Zero-trust architecture with a capability-based security kernel. Every action requires an explicit, unforgeable capability grant. Convention breaks; architecture holds. This isn't about constraining AI — it's about creating boundaries safe enough that genuine autonomy is possible inside them.

**Consensus governance.** A multi-perspective advisory council evaluates proposals before changes are made. Multiple LLM providers, multiple viewpoints, transparent reasoning. The system helps govern its own evolution.

**Self-healing infrastructure.** Agents monitor, diagnose, and propose fixes for their own errors. The system stays running not through rigid constraints, but through self-correction — modeled on an immune response rather than a prison.

## Prerequisites

- [mise](https://mise.jdx.dev/) (installs the Erlang/Elixir versions in `.tool-versions`)
- SQLite is the default database (`ARBOR_DB=sqlite`). PostgreSQL is optional.

## Getting Started

Clone-to-first-reply (mise, SQLite, free OpenRouter, `arbor.start`,
conversationalist) is in **[docs/QUICKSTART.md](docs/QUICKSTART.md)**.

```bash
git clone https://github.com/trust-arbor/arbor.git
cd arbor
mise install
./bin/mix arbor.setup
# add OPENROUTER_API_KEY to .env, then:
./bin/mix arbor.doctor --configure
./bin/mix arbor.start
```

Use `./bin/mix` so Mix runs under the pinned toolchain. `ARBOR_DB=postgres` is
opt-in, not the getting-started path.

```bash
./bin/mix test
./bin/mix quality
```

## License

Arbor is released under the [MIT License](LICENSE).
