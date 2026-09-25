# Arbor Orchestrator

Spec-conformant orchestration runtime for autonomous AI workflows, implementing the [Attractor specification](specs/attractor/attractor-spec.md).

Defines multi-stage AI pipelines as directed graphs using Graphviz DOT syntax. Nodes are tasks (LLM calls, human approvals, conditional branches, parallel fan-out), edges define flow. The execution engine traverses the graph deterministically with checkpoint/resume support.

## Key Features

- **DOT-based pipeline definition** — declarative, visual, version-controllable workflows
- **Pluggable node handlers** — start, exit, tool, conditional, parallel, fan-in, human gate, manager loop, codergen
- **Checkpoint and resume** — serializable state after each node for crash recovery
- **Human-in-the-loop** — approval gates with multiple interviewer backends (console, callback, queue, recording)
- **Unified LLM client** — multi-provider abstraction (Anthropic, OpenAI, Gemini) with tool calling and streaming
- **Coding agent loop** — iterative LLM interaction with tool call round-trips
- **Transform pipeline** — variable expansion, model stylesheets, custom transforms
- **Validation and linting** — graph structure, attribute types, node connectivity checks

## Usage

```elixir
# Parse a DOT pipeline
{:ok, graph} = Arbor.Orchestrator.parse(dot_source)

# Validate
diagnostics = Arbor.Orchestrator.validate(dot_source)

# Run with options
{:ok, result} = Arbor.Orchestrator.run(dot_source,
  interviewer: my_interviewer,
  on_event: &handle_event/1
)

# Check spec conformance
Arbor.Orchestrator.conformance_matrix()
```

## Architecture

`arbor_orchestrator` is an L7 umbrella app. It depends downward on
`arbor_actions`, `arbor_security`, `arbor_ai`, `arbor_memory`, `arbor_trust`,
`arbor_shell`, `arbor_comms`, `arbor_llm`, `arbor_persistence`, and
`arbor_kernel_runtime`. Only `arbor_commands`, `arbor_voice`, and
`arbor_dashboard` sit above it.

The engine walks a compiled DOT graph node-by-node, dispatching each node to
its typed handler. `Engine.run/2` returning `{:ok, run_result}` means execution
produced a result envelope — callers must inspect `run_result.final_outcome.status`
and admit only `:success` or an explicitly supported `:partial_success`.

## Specs

- [Attractor Specification](specs/attractor/attractor-spec.md) — pipeline definition and execution
- [Coding Agent Loop](specs/attractor/coding-agent-loop-spec.md) — iterative LLM agent pattern
- [Unified LLM Client](specs/attractor/unified-llm-spec.md) — multi-provider LLM abstraction
