# DOT Pipeline Execution

Run already-written `.dot` pipelines from Elixir code or the CLI. For *writing* pipelines, see [`dot-pipeline-authoring.md`](./dot-pipeline-authoring.md).

## The two entry points

```elixir
Arbor.Orchestrator.run(dot_string, opts)     # inline DOT (best for tests)
Arbor.Orchestrator.run_file(path, opts)      # file on disk (best for CLI / scheduled runs)
```

Both return `{:ok, %Result{}}` or `{:error, diagnostics}` where `Result` includes `completed_nodes`, `final_outcome`, and the final context. The DOT is validated before execution; bad DOTs come back as `{:error, [diagnostic, ...]}` without ever running.

Or from the shell:

```bash
mix arbor.pipeline.run path/to/pipeline.dot \
  --set repo_path=/abs/path \
  --set feature_name=add-thing \
  --logs-root /tmp/run1
```

`--set` accepts `key=value` repeated. Values are JSON-decoded so `--set count=3` gives an integer.

## Setting initial context

The DOT receives a context that's empty unless you populate it:

```elixir
Arbor.Orchestrator.run(dot,
  initial_values: %{
    "repo_path" => "/abs/path",
    "feature_name" => "add-thing",
    "session.agent_id" => "agent_test_mix"
  }
)
```

Nest keys with dots (`session.agent_id` becomes `context.session.agent_id`). The DOT reads them via `context.<key>` in conditions or `context_keys="<key>,..."` to pull them into action params.

## Required runtime services

Before a pipeline can run successfully, several Arbor subsystems must be alive. The mix task starts a minimal set for you; from tests or your own code you may need to start them explicitly.

| Need | Why | How |
|---|---|---|
| `Arbor.Orchestrator` app | Engine, ActionsExecutor, handler registry | `Application.ensure_all_started(:arbor_orchestrator)` (or call from a project that already starts it) |
| `Arbor.Common.ActionRegistry` populated | Resolves `action="<name>"` to module | `Arbor.Orchestrator.Registrar.register_core/0` (runs at boot) |
| `Arbor.Security.CapabilityStore` populated | `authorize_and_execute` blocks unauthorized calls | Grant the calling agent's principal the required URI before run |
| `Arbor.Shell.ExecutionRegistry` running | Any action that uses `Arbor.Shell.execute/2` (mix, git, raw shell) | In tests: `Arbor.Shell.ExecutionRegistry.start_link([])` — umbrella test config sets `arbor_shell, start_children: false` so app start is a no-op |

If a pipeline silently fails with `final_outcome.failure_reason` containing `:noproc` or `unauthorized`, that's almost always one of these.

## Reading results

```elixir
{:ok, result} = Arbor.Orchestrator.run(dot, opts)

result.completed_nodes        # ordered list of node IDs that ran
result.final_outcome          # %Outcome{status: :success | :fail, failure_reason: nil | binary()}
# To inspect the final context, read the checkpoint file:
{:ok, checkpoint} = Path.join(logs_root, "checkpoint.json") |> File.read!() |> Jason.decode()
checkpoint["context_values"]  # final context as a flat map
```

Inside the context, look for `exec.<node_id>.<key>` (action returns), `subgraph.<node_id>.<key>` (sub-pipeline returns), `last_response` (the most recent LLM/exec output), `outcome` (last node's status as string).

## Checkpoint + resume

Every pipeline writes a checkpoint after each node to `<logs_root>/checkpoint.json`. To resume after a crash or graceful pause:

```elixir
Arbor.Orchestrator.run(dot, logs_root: logs_root, resume: true)
```

The engine reads the checkpoint, content-hashes each prior node's outcome, and skips nodes whose state hasn't drifted. Unchanged prefix → cached results; first changed/new node and everything after re-runs.

To resume from a specific checkpoint file (e.g. one from a different machine):

```elixir
Arbor.Orchestrator.run(dot, resume_from: "/path/to/checkpoint.json")
```

## Streaming progress (LiveView, dashboards)

The orchestrator emits engine events you can subscribe to:

```elixir
Arbor.Orchestrator.run(dot,
  on_event: fn event ->
    # %{type: :node_started, node_id: "foo", ...}
    # %{type: :node_completed, node_id: "foo", outcome: %Outcome{...}, ...}
    # %{type: :pipeline_completed, ...}
    send(self(), {:pipeline_event, event})
  end,
  on_stream: fn stream_event ->
    # streaming LLM tokens, intermediate compute output
    send(self(), {:pipeline_stream, stream_event})
  end
)
```

Important: `Arbor.Orchestrator.run/2` is synchronous — it blocks the caller until the pipeline finishes. **Never call it from a LiveView event handler** (it'll wedge the socket). Spawn a `Task` and forward events to the LiveView via `Phoenix.PubSub` or process messages. See `apps/arbor_dashboard/lib/.../live_pipeline_view.ex` for the canonical async pattern.

## Composing pipelines from the caller side

Often you don't write one big DOT; you orchestrate small DOTs from Elixir code:

```elixir
# Run setup DOT, capture its result, feed into the next one.
{:ok, setup} = Arbor.Orchestrator.run_file("setup.dot", initial_values: %{...})

# Read the relevant output from the checkpoint
{:ok, checkpoint} = read_checkpoint(setup)
ready_input = checkpoint["context_values"]["exec.prepare.result"]

{:ok, work} =
  Arbor.Orchestrator.run_file("work.dot",
    initial_values: %{"input" => ready_input}
  )
```

This is often cleaner than a giant DOT that tries to express the control flow itself, especially when the orchestration decisions involve external state (database queries, message routing, user preferences).

## Mix tasks for ergonomics

| Task | Purpose |
|---|---|
| `mix arbor.pipeline.run <dot>` | Run with live progress output |
| `mix arbor.pipeline.validate <dot>` | Lint without running |
| `mix arbor.pipeline.viz <dot>` | Render to image (Graphviz) |
| `mix arbor.pipeline.list` | List registered named graphs |
| `mix arbor.pipeline.dotgen <name>` | Generate canonical DOT for a registered pipeline |
| `mix arbor.pipeline.compile <dot>` | Compile to optimized form |
| `mix arbor.pipeline.status <run_id>` | Inspect a running or completed pipeline's state |

## Anti-patterns

- **Don't block a LiveView socket on `Arbor.Orchestrator.run/2`.** Use Task + PubSub.
- **Don't bake secrets into DOT files** (they're checked into git). Read from environment via a `read` node or set via `initial_values`.
- **Don't assume the pipeline ran just because the call returned `:ok`.** Check `result.final_outcome.status` — a pipeline can complete with `:fail` status if its terminal node was reached via a failure branch.
- **Don't run long pipelines without `logs_root` set.** Without checkpoints you can't resume after a crash — and long pipelines crash.
- **Don't grant `arbor://orchestrator/execute/**` to non-system agents in production** to make a pipeline "just work." That wildcard exists in test_helper.exs for test isolation. Production grants should be narrow.

## See also

- [`dot-pipeline-authoring.md`](./dot-pipeline-authoring.md) — writing the pipelines
- [`apps/arbor_orchestrator/lib/mix/tasks/arbor.pipeline.run.ex`](../../apps/arbor_orchestrator/lib/mix/tasks/arbor.pipeline.run.ex) — the canonical CLI entry, good reference for what opts the engine accepts
- [`apps/arbor_orchestrator/test/arbor/orchestrator/mix_action_dot_test.exs`](../../apps/arbor_orchestrator/test/arbor/orchestrator/mix_action_dot_test.exs) — minimal worked example: tiny mix project + DOT + capability grant + run + assert
