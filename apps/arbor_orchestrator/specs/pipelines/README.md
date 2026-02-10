# Pipeline Specifications

DOT pipeline files that define orchestrator-driven workflows for Arbor.
These serve as both documentation and executable specs — once the LLM backend
is wired, these pipelines can build and rebuild themselves.

## Pipelines

| File | Purpose | Status |
|------|---------|--------|
| `sdlc.dot` | Software development lifecycle | In progress |
| `bdi-goal-decomposition.dot` | BDI goal planning and execution | Planned |
| `consensus-flow.dot` | Multi-party decision coordination | Planned |
| `memory-consolidation.dot` | Memory compression and archival | Planned |
| `security-auth-chain.dot` | Policy-visible authorization gates | Planned |

## Usage

```bash
# Validate a pipeline
mix arbor.pipeline.validate specs/pipelines/sdlc.dot

# Run a pipeline
mix arbor.pipeline.run specs/pipelines/sdlc.dot --workdir ./my_project
```

## Design Principles

From the council synthesis (2026-02-10):

1. **"Cortex, not Brainstem"** — Graph for reasoning flows, native OTP for reliability
2. **"Physics vs. Biology"** — OTP as immutable laws, DOT as evolvable behavior
3. **Shadow Mode Mandatory** — Run alongside hardcoded flows before cutover
4. **SLO-Gated** — Define latency/memory budgets before migration
