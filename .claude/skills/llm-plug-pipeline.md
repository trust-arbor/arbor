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

Plugs pipe with `|>`. `use Arbor.LLM.Plug` attaches the behaviour — nothing more. Halted handling is the plug author's responsibility (Phoenix Plug took the same route; `defoverridable` doesn't combine cleanly with multi-clause user defs). Two patterns:

**Mutating plug** — should skip halted calls. Add an explicit halted-first clause:

```elixir
defmodule Arbor.LLM.Plugs.MyPlug do
  use Arbor.LLM.Plug
  alias Arbor.LLM.Call

  def call(%Call{halted: true} = call), do: call

  def call(%Call{} = call) do
    # ... transform the call ...
    call
  end
end
```

**Observability plug** — should run on halted calls too. No halted clause:

```elixir
defmodule Arbor.LLM.Plugs.MyTelemetry do
  use Arbor.LLM.Plug
  alias Arbor.LLM.Call

  def call(%Call{} = call) do
    # ... emit telemetry, log, warn, whatever ...
    call
  end
end
```

`Arbor.LLM.Pipeline.through/2` does NOT short-circuit on halted — it hands every call to every plug and lets each one decide. This is what makes `Plugs.StalenessWarn` work: Replay halts the call, but StalenessWarn still fires to flag the stale fixture.

## CRC alignment

This is Arbor's [Construct-Reduce-Convert](./functional-core.md) pattern at the call layer:

- **Construct**: `Arbor.LLM.Call.new/2` builds the call struct.
- **Reduce**: each plug is a pure-ish state transition (`Call.t() -> Call.t()`). Side effects allowed but explicit and named (e.g., `Plugs.Record` writes a file).
- **Convert**: the adapter extracts `Map.fetch!(:result)` at the pipeline tail to return the upstream-expected result shape.

## Adding a new plug

1. Create `apps/arbor_llm/lib/arbor/llm/plugs/<name>.ex`.
2. `use Arbor.LLM.Plug` to attach the behaviour.
3. Decide: mutating (skip halted) or observability (run on halted)?
4. Mutating: add `def call(%Call{halted: true} = call), do: call` as the first clause. Observability: skip that clause.
5. Implement `call/1` for the main case. Pattern-match on what you need from the `Call` struct.
6. Use `Call.halt/1`, `Call.put_metadata/2`, `Call.assign/3` for the standard transformations.
7. Add to the application's pipeline config or wire into a test fixture.

```elixir
defmodule Arbor.LLM.Plugs.CostTracker do
  @moduledoc """
  Aggregate per-agent LLM spend from `usage.total_cost`.
  Reads `agent_id` from `call.assigns`; expects the caller to have
  assigned it before the pipeline runs.

  Observability plug — runs on halted (replayed) calls too. Replayed
  responses still have valid usage data, and we want their cost in
  the aggregate.
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

The pipeline boundary carries upstream result types. In particular, a live
completion is `{:ok, %ReqLLM.Response{}}`; conversion to
`%Arbor.LLM.Response{}` happens only after the pipeline returns. Record/replay
fixtures must serialize that real typed boundary and reconstruct a minimal
`%ReqLLM.Response{}` on replay. A test plug returning an already-normalized
Arbor response does not exercise production record/replay and can hide a
broken fixture contract.

## Conventional pipelines

| Context | Pipeline |
|---|---|
| Production default | `[ResponseLimit, Dispatch, RateLimitBackoff, Usage]` |
| Test replay | `[Replay, Dispatch, StalenessWarn]` |
| Recording new fixtures | `[Replay, Dispatch, Record, StalenessWarn]` |
| Replay with usage protection | `[Replay, Dispatch, Usage]` (`Usage` skips halted replay) |

The order matters: `Replay` before `Dispatch` so a fixture short-circuits the real call; `Throttle` before `Dispatch` so it can refuse the call before it costs anything; `CostTracker` and `Telemetry` after `Dispatch` so they see the result.

## Applied learning

**Exercise fixtures at the production typed boundary (2026-07-22).** Record
and replay the value the pipeline actually sees, then let the normal adapter
conversion run. Normalized test doubles can make both recording and replay
look correct while live calls are serialized as an opaque raw outcome.

**Usage belongs to the authoritative completion owner (2026-07-22).** An
eager streaming completion may account final usage after assembly and boundary
validation. A lazy stream can be partially consumed, abandoned, or cancelled,
so it needs an explicit normal-completion contract before it can emit terminal
usage; do not infer billing from an intermediate metadata chunk.

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
