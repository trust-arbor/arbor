# Code Review: arbor_orchestrator

**Date**: 2026-05-20  
**Reviewer**: Hermes Agent (Grok-4.3)  
**Focus**: Suitability as foundation for self-modifying agent pipelines and remote BEAM execution

---

## Executive Summary

`arbor_orchestrator` is a sophisticated DOT-driven pipeline execution engine with strong foundations for both **self-modifying agent behavior** (via `GraphMutation` + `AdaptHandler`) and **distributed BEAM execution** (via `Placement` + Cartographer hooks). The architecture is thoughtful, but there are critical gaps in security, distributed coordination, and mutation safety that must be addressed before using it as the foundation for autonomous, self-modifying agents running across a cluster.

---

## Strengths

### 1. Self-Modification Foundation is Already Present

- `GraphMutation` module + `adapt_handler.ex` provide a working mechanism for agents to mutate their own DOT pipelines at runtime.
- Trust-tier gating in `AdaptHandler` (`untrusted` → `autonomous`) is a good start for controlling mutation power.
- Context key `__adapted_graph__` + engine detection enables dynamic graph swapping mid-execution.

### 2. Distributed Execution Hooks Exist

- `Engine.Placement` parses `placement` attributes and supports capability-based scheduling via `Arbor.Cartographer.Scheduler`.
- `remote_execute/6` + `:rpc.call` provides a path for cross-node handler execution.
- Explicit node targeting (`node:foo@host`) and strategy-based scheduling are supported.

### 3. Solid Core Abstractions

- Handler registry + middleware chain is clean.
- Checkpointing, content-hash skip logic, and outcome routing are well-designed.
- DOT-first approach is excellent for agent-driven evolution (agents can literally rewrite their own workflow graphs).

---

## Critical Concerns

### 1. Self-Modification Security is Incomplete

- Trust-tier checks in `AdaptHandler` rely on `session.trust_tier` in context — this can be spoofed or missing unless the session layer enforces it.
- No capability-based authorization on mutations themselves (e.g., an agent with `arbor://pipeline/mutate` capability).
- `GraphMutation.validate/3` prevents operating on completed nodes but does not prevent dangerous structural changes (removing critical goal gates, creating infinite loops, etc.).
- No mutation audit log or version history persisted.

### 2. Remote Execution is Fragile

- `Placement.resolve/1` falls back to local execution if `Arbor.Cartographer.Scheduler` is not loaded — silent degradation.
- `:rpc.call` strips some opts but does not propagate capabilities or trust context across the wire.
- No automatic retry or failover when a remote node becomes unavailable mid-pipeline.
- Distributed checkpoint coordination is missing — a node crash can leave orphaned remote state.

### 3. Engine Monolith

- `engine.ex` is ~993 lines and mixes traversal, checkpointing, event emission, and placement logic.
- Hard to test individual concerns in isolation.

### 4. Missing Pieces for Your Use Cases

- No first-class "agent owns its pipeline" ownership model.
- No safe sandbox for proposed mutations before applying them.
- No cluster-wide registry of running agent pipelines with migration support.

---

## Architecture Improvement Ideas

### For Self-Modifying Agents

1. **Introduce a Mutation Capability**
   Add a new capability URI pattern: `arbor://pipeline/mutate/{pipeline_id}`. `AdaptHandler` should call `Arbor.Security.authorize/4` before applying mutations. This makes mutation a granted right rather than purely trust-tier based.

2. **Add a Safe Mutation Preview / Dry-Run + Simulation Mode**
   Extend the existing `dry_run` attribute. Before applying, produce a diff of the resulting graph and require either:
   - Human approval gate, or
   - Another `graph.adapt` node with higher trust tier.

3. **Pipeline Versioning + History**
   Store mutated graphs in `arbor_persistence` (or a dedicated `PipelineVersion` table) with parent hash links. This gives agents (and humans) an evolutionary history they can reflect on or roll back.

4. **Structural Safety Rules**
   Add lint rules that reject mutations creating:
   - Unreachable nodes
   - Cycles without exit paths
   - Removal of required goal gates
   These should live in `GraphMutation.validate/3`.

### For Remote BEAM Execution

1. **Capability Propagation Across RPC**
   Modify `remote_execute` to carry a signed capability token or serialized capability set. The receiving node must re-authorize before executing the handler.

2. **Distributed Checkpointing**
   When a node has a `placement` attribute, the checkpoint should be written to a shared store (Postgres via `arbor_persistence_ecto` or a replicated ETS) rather than local disk. Add a `RecoveryCoordinator` that can resume across nodes.

3. **Placement-Aware Handler Registry**
   Make the handler registry placement-aware so certain handlers (e.g., those touching local filesystem) refuse to run remotely unless explicitly allowed.

4. **Cartographer as a Required Dependency or Graceful Stub**
   Either make `arbor_cartographer` a real umbrella dependency or provide a robust local-only scheduler implementation so the fallback isn't silent.

### Cross-Cutting Improvements

- **Split the Engine**: Extract `Traversal`, `CheckpointManager`, and `PlacementCoordinator` into focused modules.
- **Stronger CRC Pattern**: Many handlers still mix logic and side effects. Push more pure logic into `cores/` directories.
- **Event Sourcing for Mutations**: Emit `pipeline_mutated` signals with before/after graphs so dashboards and the agent itself can observe its own evolution.

---

## Recommended Next Steps

### Immediate (Security)

- Add capability check inside `AdaptHandler.execute/4`.
- Write a regression test that proves an untrusted agent cannot mutate a pipeline.

### Short-term (Self-modification)

- Implement mutation preview + structural safety rules in `GraphMutation`.
- Persist mutation history.

### Medium-term (Distribution)

- Harden `Placement.remote_execute` with capability propagation and better error handling.
- Prototype distributed checkpointing using the existing `Checkpoint` module + persistence layer.

---

## Files of Interest

| Area                        | Key Files                                                                 |
|----------------------------|---------------------------------------------------------------------------|
| Self-modification          | `graph_mutation.ex`, `handlers/adapt_handler.ex`                          |
| Distributed execution      | `engine/placement.ex`, `engine/executor.ex`                               |
| Core engine                | `engine.ex`, `graph.ex`, `session.ex`                                     |
| Validation & safety        | `validation/validator.ex`, `validation/rules/*.ex`                        |
| DOT handling               | `dot/parser.ex`, `dotgen/*.ex`                                            |

---

*This review was generated to support the goal of using `arbor_orchestrator` as the foundation for agent-controlled, self-modifying code and remote BEAM execution.*