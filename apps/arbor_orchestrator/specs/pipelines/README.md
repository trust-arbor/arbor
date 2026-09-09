# Pipeline Specifications

DOT pipeline files that define orchestrator-driven workflows for Arbor.
Some are selected by production owners; others are optional examples. Parsing or
explicit registration does not establish a production caller or prove execution.

## Pipelines

| File | Purpose | Status |
|------|---------|--------|
| `sdlc.dot` | Software development lifecycle | In progress |
| `bdi-goal-decomposition.dot` | BDI goal planning and execution | Planned |
| `consensus-flow.dot` | Multi-party decision coordination | Planned |
| `memory-consolidation.dot` | Illustrates compression into an output file; does not read/write live Memory stores | Optional design example |
| `security-auth-chain.dot` | Policy-visible authorization gates | Planned |
| `session/turn.dot` | One conversational turn | Production Session default |
| `session/heartbeat.dot` | One autonomous cognitive cycle | Production heartbeat default |
| `session/bdi-cycle.dot` | Historical alternative BDI topology | Optional example; not the production heartbeat |

The two optional memory examples retain their file paths and explicit loading,
registration and validation support. They are not automatically registered or
executed by Session. Callers must provide their required inputs and authority;
the examples do not establish private-memory ownership or cold recovery.

Session owns the acknowledged user/assistant transcript append and its optional
checkpoint adapter after admitting a graph result. The turn and BDI graphs no
longer invoke `session_memory.checkpoint`: that retained action returns
`{:error, :session_checkpoint_retired}` for older callers. Engine checkpoints
belong to Engine job recovery and do not prove a Session checkpoint was saved.

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
