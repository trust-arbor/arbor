# Handler Behaviour Enhancement Proposal

## Goal
Strengthen the existing `Arbor.Orchestrator.Handlers.Handler` behaviour with safe invocation wrappers (following the Ash `BehaviourHelpers` pattern) to improve runtime safety, Dialyzer quality, and consistency with CRC ideals.

## Changes

### 1. New File: `handlers/behaviour_helpers.ex`

```elixir
defmodule Arbor.Orchestrator.Handlers.BehaviourHelpers do
  @moduledoc """
  Safe invocation helpers for `Arbor.Orchestrator.Handlers.Handler` implementations.

  Provides wrapper functions that:
  - Enforce return type contracts at runtime
  - Improve Dialyzer inference via explicit @spec
  - Centralize error handling for invalid handler returns

  ## Usage

  Handlers should **never** be called directly. Always go through the wrapper:

      BehaviourHelpers.execute(handler_module, node, context, graph, opts)

  This is the Ash.BehaviourHelpers pattern adapted for the orchestrator.
  """

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Handler

  @doc """
  Executes a handler module through the validated wrapper.

  Raises `Arbor.Orchestrator.Handlers.InvalidReturnError` if the handler
  returns a value that does not match the expected `Outcome.t()` shape.
  """
  @spec execute(module(), Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
  def execute(handler_module, node, context, graph, opts \\ []) do
    result = handler_module.execute(node, context, graph, opts)

    if is_struct(result, Outcome) do
      result
    else
      raise Arbor.Orchestrator.Handlers.InvalidReturnError,
            "Handler #{inspect(handler_module)}.execute/4 must return %Outcome{}, got: #{inspect(result)}"
    end
  end

  @doc """
  Executes a handler using the three-phase protocol with validation.
  """
  @spec execute_three_phase(module(), Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
  def execute_three_phase(handler_module, node, context, graph, opts \\ []) do
    # Delegate to the existing implementation in Handler, then validate
    outcome = Handler.execute_three_phase(handler_module, node, context, graph, opts)

    if is_struct(outcome, Outcome) do
      outcome
    else
      raise Arbor.Orchestrator.Handlers.InvalidReturnError,
            "Three-phase handler #{inspect(handler_module)} must return %Outcome{}"
    end
  end
end
```

### 2. New File: `handlers/invalid_return_error.ex`

```elixir
defmodule Arbor.Orchestrator.Handlers.InvalidReturnError do
  defexception [:message]

  @impl true
  def exception(msg) when is_binary(msg) do
    %__MODULE__{message: msg}
  end
end
```

### 3. Recommended Update to `Engine`

In `engine.ex` (and any direct handler call sites), replace direct calls:

**Before:**
```elixir
handler_module.execute(node, context, graph, opts)
```

**After:**
```elixir
BehaviourHelpers.execute(handler_module, node, context, graph, opts)
```

### 4. Minor CRC Fix: `Engine.Context` — Completed

The recommended change was implemented (and extended) in May 2026:

- `set/5` and `apply_updates/4` now accept an explicit `step_now` (with nil fallback for backward compatibility).
- `Context` carries `pipeline_started_at`, which is automatically propagated into every `LineageEntry`.
- A proper `LineageEntry` typedstruct was introduced with `step_timestamp` + `pipeline_timestamp`.
- Full wiring through Engine, resume path, and Checkpoint serialization.
- Accessor helpers (`Context.step_timestamp/1`, `Context.pipeline_timestamp/1`, etc.) provide safe reading of both legacy and new shapes.

The Context purity work is considered complete. See the updated `CRC-AUDIT.md` and `arbor-orchestrator-spec.md` for the current model.

## Benefits

- Runtime enforcement of the `Outcome` return contract
- Better Dialyzer results on handler call sites
- Consistent with Ash and the CRC ideal
- Easier to add more validation later (e.g., idempotency class checks)

## Status (as of 2026-05)

**Implemented**

- `behaviour_helpers.ex` and `invalid_return_error.ex` created.
- Main dispatch path in `Authorization.authorize_and_execute` routes through the helpers.
- Distributed execution path in `Placement.local_execute` also routes through the helpers (added during Wave 2).
- The key safety property (raising `InvalidReturnError` on bad returns) is tested.
- Several handlers already declare `@behaviour` and use `@impl`.

**Remaining (lower priority / incremental)**
- Audit and wrap any remaining intra-handler composition calls if desired for consistency.
- ~~Add `@impl Handler` annotations across the full set of handlers~~ **Done** — all 28 `*_handler.ex` modules declare `@behaviour`.
- ~~Strengthen error handling inside `Handler.execute_three_phase` itself so bad returns are turned into a clean failure instead of crashing the `with`.~~ **Done (2026-05-26)** — a catch-all `else` clause converts any non-`{:ok, _}`/non-`{:error, _}` callback return into a fail `Outcome` whose reason names the invalid return (was raising `WithClauseError`). Regression-tested in `behaviour_helpers_test.exs`.

The core safety goal of the proposal is achieved.