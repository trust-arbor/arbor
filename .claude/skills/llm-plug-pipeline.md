# LLM Plug Pipeline Pattern

Compose cross-cutting concerns (record/replay, cost tracking, telemetry, throttling, retry, circuit breaking) for LLM calls as a chain of `Arbor.LLM.Plug` modules piped through an `Arbor.LLM.Call` struct.

## When to use

Reach for this pattern when adding a concern that wraps every LLM call but doesn't belong to a specific operation (`:complete`, `:stream`, `:embed_cloud`, `:embed_local`). Examples:

- Recording responses for replay in tests
- Aggregating per-agent cost from `usage.total_cost`
- Emitting `Arbor.Signals.durable_emit` events at the call boundary
- Rate-limiting per agent, per provider, or per budget window
- Warning when replayed fixtures are stale
- Retrying transient `:error` results before propagating to the caller

Reach for something else when the concern is operation-specific (it belongs inside `Plugs.Dispatch` or before/after the pipeline) or call-site-specific (it belongs in the caller, not the LLM layer).

## Pattern overview

A plug is a module implementing `Arbor.LLM.Plug`:

```elixir
@callback call(Arbor.LLM.Call.t()) :: Arbor.LLM.Call.t()
```

`Arbor.LLM.Call` is the conn-like struct threaded through the chain:

```elixir
%Arbor.LLM.Call{
  operation: :complete | :stream | :embed_cloud | :embed_local,
  request: tuple(),         # args for the dispatch
  result: term() | nil,     # set by Plugs.Dispatch (or short-circuited)
  halted: boolean(),        # short-circuit flag
  metadata: map(),          # pipeline-shared (timestamps, replay provenance)
  assigns: map()            # per-plug scratch space
}
```

Plugs pipe with `|>`. The `use Arbor.LLM.Plug` macro injects a halted-passthrough clause so plugs that don't act on halted calls don't need to think about it:

```elixir
defmodule Arbor.LLM.Plugs.MyPlug do
  use Arbor.LLM.Plug
  alias Arbor.LLM.Call

  # Runs only when halted: false (the use-injected clause handles halted: true).
  def call(%Call{} = call) do
    # ... transform the call ...
    call
  end
end
```

## CRC alignment

This is Arbor's [Construct-Reduce-Convert](./functional-core.md) pattern at the call layer:

- **Construct**: `Arbor.LLM.Call.new/2` builds the call struct.
- **Reduce**: each plug is a pure-ish state transition (`Call.t() -> Call.t()`). Side effects allowed but explicit and named (e.g., `Plugs.Record` writes a file).
- **Convert**: the adapter extracts `Map.fetch!(:result)` at the pipeline tail to return the upstream-expected result shape.

## Adding a new plug

1. Create `apps/arbor_llm/lib/arbor/llm/plugs/<name>.ex`.
2. `use Arbor.LLM.Plug` to inherit halted-passthrough.
3. Implement `call/1` for the non-halted case. Pattern-match on what you need from the `Call` struct.
4. Use `Call.halt/1`, `Call.put_metadata/2`, `Call.assign/3` for the standard transformations.
5. Override the halted-passthrough clause explicitly if your plug should run on halted calls (telemetry, post-hoc observability).
6. Add to the application's pipeline config or wire into a test fixture.

```elixir
defmodule Arbor.LLM.Plugs.CostTracker do
  @moduledoc """
  Aggregate per-agent LLM spend from `usage.total_cost`.
  Reads `agent_id` from `call.assigns`; expects the caller to have
  assigned it before the pipeline runs.
  """
  use Arbor.LLM.Plug
  alias Arbor.LLM.Call

  def call(%Call{result: {:ok, response}, assigns: %{agent_id: agent_id}} = call)
      when not is_nil(agent_id) do
    cost = get_in(response.usage, [:total_cost]) || 0.0
    Arbor.AI.UsageStats.add_cost(agent_id, cost)
    Call.put_metadata(call, %{cost_recorded: cost})
  end

  def call(%Call{} = call), do: call  # no result, no agent_id, no result map
end
```

## Pipeline composition

Two shapes:

**Static (compile-time-known pipeline):**

```elixir
defp call_req_llm(model_spec, messages, opts) do
  Call.new(:complete, {model_spec, messages, opts})
  |> Plugs.Replay.call()
  |> Plugs.Dispatch.call()
  |> Plugs.Record.call()
  |> Plugs.StalenessWarn.call()
  |> Map.fetch!(:result)
end
```

**Dynamic (config-driven):**

```elixir
defp call_req_llm(model_spec, messages, opts) do
  Call.new(:complete, {model_spec, messages, opts})
  |> Pipeline.through(Application.get_env(:arbor_llm, :pipeline, [Plugs.Dispatch]))
  |> Map.fetch!(:result)
end
```

The current `Arbor.LLM.Adapter.ReqLLM` uses the dynamic shape so test environments can swap pipelines without touching the adapter.

## Conventional pipelines

| Context | Pipeline |
|---|---|
| Production default | `[Dispatch]` |
| Test replay | `[Replay, Dispatch, StalenessWarn]` |
| Recording new fixtures | `[Replay, Dispatch, Record, StalenessWarn]` |
| Cost-tracked production (future) | `[Dispatch, CostTracker, Telemetry]` |
| Throttled production (future) | `[Throttle, Dispatch, CostTracker, Telemetry]` |

The order matters: `Replay` before `Dispatch` so a fixture short-circuits the real call; `Throttle` before `Dispatch` so it can refuse the call before it costs anything; `CostTracker` and `Telemetry` after `Dispatch` so they see the result.

## Anti-patterns

- **Don't bypass the pipeline for "just one quick concern."** Each one-off bypass is the seed of the next mode-flag mess this pattern was meant to replace. If the concern doesn't fit a plug, that's a design signal to rethink — not to bypass.
- **Don't make plugs depend on each other's plug type.** Plug A shouldn't import or alias Plug B. Cross-plug data flows through `metadata` (shared) or `assigns` (per-plug). The pipeline composition order is what enforces sequencing.
- **Don't put dispatch logic outside `Plugs.Dispatch`.** If you find yourself calling `ReqLLM.*` from a plug, ask why. Dispatch is the single point that translates `(operation, request)` into an upstream call.

## See also

- `apps/arbor_llm/lib/arbor/llm/plug.ex` — the behaviour + `use` macro
- `apps/arbor_llm/lib/arbor/llm/call.ex` — the call struct
- `apps/arbor_llm/lib/arbor/llm/pipeline.ex` — `through/2` helper
- `apps/arbor_llm/lib/arbor/llm/plugs/` — the in-tree plugs
- [`functional-core.md`](./functional-core.md) — the CRC pattern this builds on
- `.arbor/roadmap/0-inbox/advisory-mode-cost-aware-quotas.md` — the cost-quota roadmap item that motivates `Plugs.CostTracker`
