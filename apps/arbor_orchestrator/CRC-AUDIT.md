# CRC Audit — arbor_orchestrator

**Date**: 2026-05-20  
**Scope**: Primary modules in `arbor_orchestrator` (Engine, Session, RunState, Context, Router, handlers, cores)  
**Goal**: Assess adherence to the Construct-Reduce-Convert (CRC) pattern and identify refactoring opportunities. CRC guidelines were introduced after most of the orchestrator was built.

## Executive Summary

The `arbor_orchestrator` implementation shows **strong overall adherence** to CRC principles, especially in the explicitly named core modules. The design already separates pure business logic from side effects better than most large Elixir codebases.

**Strengths**
- Explicit CRC documentation in `RunState.Core` and `SessionCore`.
- Thin boundary layers (Engine + GenServer wrappers) correctly own ETS, timing, and handler dispatch.
- Most graph traversal, routing, and state transformation logic is pure.
- Good use of focused submodules (`engine/router.ex`, `engine/state.ex`, `engine/context.ex`).

**Main Opportunities**
1. `DateTime.utc_now()` leakage into otherwise pure modules (`Engine.Context`).
2. Inconsistent CRC adoption across older modules that pre-date the pattern.
3. Some handler dispatch and result processing still mixes concerns.
4. Lack of a formal `@behaviour` for handlers (would strengthen the pattern).

## Detailed Module Audit

### Excellent CRC Compliance

**`RunState.Core`** (`lib/arbor/orchestrator/run_state/core.ex`)
- Explicitly documents purity and the ETS boundary layer.
- `new/4` correctly requires `:now` to be passed in (avoids impurity).
- Clean Construct → Reduce → Convert pipeline in moduledoc example.
- **Verdict**: Model example.

**`SessionCore`** (`lib/arbor/orchestrator/session_core.ex`)
- Clear CRC breakdown in moduledoc.
- All functions are pure transformations on session state.
- Removed default `DateTime.utc_now()` from the public builder APIs (`build_user_message`, `build_assistant_message`, `append_user_message`, `apply_llm_response`). Callers (boundary layers) must now supply timestamps.
- `parse_timestamp` fallbacks no longer silently stamp "now".
- GenServer wrapper + `Builders` capture time at the effect boundary.
- **Verdict**: Excellent (and now strictly pure on the timestamp dimension).

**`Engine.Router`** (`lib/arbor/orchestrator/engine/router.ex`)
- Pure graph navigation and conditional edge selection.
- No side effects.
- **Verdict**: Very good.

**`Engine.State`** and **`Engine.Outcome`**
- Focused data structures with pure transformation functions.
- **Verdict**: Good.

### Minor Purity Violations (Easy Fixes)

**`Engine.Context`** (`lib/arbor/orchestrator/engine/context.ex`)
- ~~`set/4` and `apply_updates/3` call `DateTime.utc_now()` internally when tracking lineage.~~ **Completed (2026-05)**.
- The module now accepts explicit `step_now` (and carries `pipeline_started_at` for dual-clock lineage tracking via a proper `LineageEntry` struct).
- Full injection, resume persistence, and accessor helpers (`step_timestamp/1`, `pipeline_timestamp/1`) implemented and tested.
- **Status**: Done. The pattern is now the reference for other timestamp-sensitive cores.

**`Engine`** (`lib/arbor/orchestrator/engine.ex`)
- Correctly uses `System.monotonic_time/1` and `DateTime.utc_now()` because it is the effectful orchestrator shell.
- Handler dispatch now consistently goes through `BehaviourHelpers` (via `Authorization` and `Placement`).
- **Status**: Handler safety layer enforcement largely complete (Wave 2).

### Areas with Refactoring Potential

1. **Handler System** (`lib/arbor/orchestrator/handlers/`)
   - Currently dispatched via `Handlers.Registry`.
   - Many handlers mix pure logic with effectful calls (LLM, tool execution, file I/O).
   - **Opportunity**: Introduce `@behaviour Arbor.Orchestrator.Handler` with required callbacks and a wrapper validation function (inspired by `Ash.BehaviourHelpers`).
   - This would make the CRC boundary explicit: handlers declare whether they are pure or effectful.

2. **Result Processing & Event Emission**
   - `session/result_processor.ex` contains a `send/2`.
   - Some result aggregation mixes context updates with telemetry/signals.
   - **Recommendation**: Keep pure aggregation in a `Result.Core` module; move `send` and event emission to the Session or a dedicated emitter boundary.

3. **Graph & Pipeline Modules**
   - `graph.ex`, `graph_mutation.ex`, and DOT parsing modules are mostly pure.
   - Some older modules lack the explicit CRC section headers that newer cores have.
   - **Recommendation**: Add consistent `@moduledoc` CRC sections and move any remaining side-effect code out.

4. **Checkpoint & Recovery**
   - Checkpointing logic is reasonably isolated but could benefit from a dedicated `Checkpoint.Core` for the pure serialization/deserialization parts.

## Refactoring Roadmap (Prioritized)

| Priority | Change | Effort | Benefit | CRC Alignment |
|----------|--------|--------|---------|---------------|
| High | Pass `now` / timestamp into `Context.set/4` and `apply_updates/3` | Low | High testability | Stronger purity | **Completed 2026-05** (dual-clock `LineageEntry` + `pipeline_started_at`) |
| High | Define `Arbor.Orchestrator.Handler` behaviour + validation wrapper | Medium | High extensibility & safety | Matches Ash pattern | **Complete** (2026-05) — helpers exist, main paths protected, all 28 handlers declare `@behaviour`, three-phase error hardening done (malformed callback returns → fail `Outcome` instead of `WithClauseError`, regression-tested). |
| Medium | Extract `RunState.Boundary` module for ETS sync | Medium | Cleaner Engine | Clearer shell/core split |
| Medium | Add CRC moduledoc sections to all engine/* modules | Low | Consistency | Documentation |
| Low | Create `Result.Core` for pure aggregation logic | Medium | Testability | Better separation |

## Recommendations for AI Agents

When working on `arbor_orchestrator`:

- **New pure logic** → Always create or extend a `*.Core` module following the existing CRC template.
- **Timestamps** → Never call `DateTime.utc_now()` or `System.monotonic_time` inside core modules. Accept them as parameters.
- **Handlers** → Treat handler implementations as the primary effect boundary. Keep their pure parts minimal and well-tested.
- **Engine** → Only the Engine (and thin boundary layers) may perform timing, ETS writes, handler dispatch, and event emission.
- **Documentation** → Update both `AGENTS.md` and this audit file when making structural changes.

## Conclusion

The orchestrator is already in much better shape than a typical post-hoc CRC retrofit would suggest. The main issues are localized and mechanical (timestamp leakage) rather than fundamental architectural problems. Implementing the high-priority items above would bring the codebase into full alignment with the CRC ideal used elsewhere in Arbor and in the best Elixir projects (Ecto, Ash, Phoenix).

---

*Audit performed by direct source inspection of the cloned and live Arbor repositories.*