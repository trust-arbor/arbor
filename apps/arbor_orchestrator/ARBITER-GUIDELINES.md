# Arbor Orchestrator — AI Agent Guidelines (Derived from High-Quality Elixir Projects)

This document adapts the architectural patterns and best practices from Elixir core, Phoenix, Ash, Ecto, and Broadway to the `arbor_orchestrator` app.

It builds on the existing `AGENTS.md` and `CLAUDE.md` already present in the project.

## Alignment with Researched Patterns

### Strong Alignment Already Present

**CRC Pattern (Construct-Reduce-Convert)**  
Arbor's `cores/` directories implement exactly the "pure functional core, effectful shell" pattern we observed in top Elixir projects:
- `new/1` — construct (pure)
- Transformation functions — reduce (pure)
- `show/1` or formatters — convert (pure)
- All functions are side-effect free (no DB, no GenServer, no IO).

This matches Ecto Changesets, Ash Changesets, and Phoenix conn pipelines perfectly.

**Engine Architecture**  
`Arbor.Orchestrator.Engine` follows excellent modular design:
- Delegates to focused submodules (`Executor`, `Router`, `State`, `Checkpoint`, `Context`, etc.).
- Uses clear `@type` definitions and `@spec`.
- Separates graph traversal (pure logic) from handler dispatch (effect boundary via `Handlers.Registry`).

This mirrors Broadway's pipeline + handler separation and Ash's behaviour dispatch.

**DOT Pipeline + Handlers**  
The handler system (`Handlers/`) is a natural use of behaviours/protocols for extensibility:
- Different node shapes/types dispatch to specialized handlers (`ExecHandler`, `LlmHandler`, `ConditionalRouter`, etc.).
- This is very similar to Ash's behaviour wrappers and Broadway's processor behaviours.

**Contract-First + Library Hierarchy**  
The umbrella enforces strict layering (Level 0 contracts → Level 1/2 libraries). This prevents the kind of tight coupling that plagues many large codebases.

**Session + Heartbeat**  
`Session` (GenServer) and `HeartbeatService` correctly isolate stateful orchestration from pure pipeline execution — aligning with OTP best practices seen in Phoenix LiveView and Broadway topologies.

### Opportunities to Strengthen Alignment

1. **Behaviours for Handler Contracts** (Recommended)
   - Currently handlers are dispatched via `Handlers.Registry`.
   - Consider formalizing with a `@behaviour Arbor.Orchestrator.Handler` (similar to `Ash.Resource.Change` or `Broadway.Processor`).
   - Add wrapper functions (like `Ash.BehaviourHelpers.call_and_validate_return/5`) to enforce return shapes (`{:ok, context}`, `{:error, reason}`, etc.) and improve Dialyzer.

2. **More Explicit Purity Boundaries**
   - The Engine already does a good job, but ensure every new handler clearly documents whether it is pure or effectful.
   - Keep LLM calls, file writes, and external actions strictly in handler implementations; never in core graph traversal or context logic.

3. **Documentation Style (from Phoenix + Elixir core)**
   - Ensure every public module and function in `arbor_orchestrator` has a concise first-paragraph `@moduledoc` / `@doc`.
   - Example for Engine:
     ```elixir
     @moduledoc """
     Executes DOT pipeline graphs with checkpointing, conditional routing, and lifecycle events.
     """
     ```

4. **Testing Patterns**
   - Follow the security regression test rule already in CLAUDE.md.
   - For pipeline changes: add tests that exercise retry edges, goal gates, and resume-from-checkpoint.
   - Use property-based testing (StreamData) on graph traversal where possible (pure logic).

5. **Formatter & DSL Extensions**
   - The project likely has custom locals_without_parens for any pipeline-building macros. Keep `.formatter.exs` updated when adding new DSL forms.

## Specific Instructions for AI Agents on arbor_orchestrator

When modifying or extending the orchestrator:

- **Prefer CRC cores** for any new pure logic (context transformation, routing decisions, outcome evaluation).
- **Introduce behaviours** when adding new handler types or extension points.
- **Keep the Engine pure** — it should only orchestrate; actual work (LLM, actions, I/O) belongs in handlers.
- **Use the existing event system** (`EventEmitter`) for observability instead of adding new side effects.
- **Respect the library hierarchy** — never import from higher-level apps directly.
- **Update AGENTS.md** when changing pipeline syntax or handler behaviour so downstream agent users stay in sync.
- **Add regression tests** for any change that affects execution semantics, retry logic, or checkpointing.

## Recommended Next Steps

1. Formalize the Handler behaviour + validation wrapper (high value, low risk).
2. Audit a few core modules (e.g., `Context`, `Router`) for full CRC compliance.
3. Generate a visual architecture diagram of the Engine + handlers (using the existing viz tools).
4. Create targeted guidelines for other Arbor apps (`arbor_agent`, `arbor_memory`, etc.) using the same template.

This keeps `arbor_orchestrator` aligned with the quality bar of Phoenix, Ash, and Elixir core while respecting its existing sophisticated design (DOT pipelines, CRC, contract-first, capability security).

---

*Derived from research on Elixir, Phoenix, Ash, Ecto, Broadway + direct inspection of Arbor's CLAUDE.md, AGENTS.md, Engine, and handler structure.*