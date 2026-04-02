# Functional Core Pattern (CRC)

Build pure functional modules that separate business logic from side effects using the Construct-Reduce-Convert pattern.

## Pattern Overview

A functional core is a module containing pure functions that:
- Take plain data structures as input
- Return plain data structures as output
- Have no side effects (no DB calls, no GenServer calls, no external APIs, no IO)
- Are easily testable in isolation

## Structure

```elixir
defmodule Arbor.<Library>.<CoreName> do
  @moduledoc """
  Pure business logic for [domain concept].
  All functions are pure and side-effect free.
  """

  @doc "Construct: Transform external input into internal representation."
  def new(params) do
    # Parse, validate, normalize
  end

  @doc "Reduce: Core business logic transformation."
  def operation(state, params) do
    # Pure transformation — same input always produces same output
  end

  @doc "Convert: Format internal state for output/display."
  def show(state) do
    # Format for display, serialization, or API response
  end
end
```

## Key Principles

1. **Pure Functions Only**
   - No `Repo` calls or ETS reads
   - No `GenServer.call` or process messaging
   - No HTTP requests or file I/O
   - No `DateTime.utc_now()` or random values — pass as parameters if needed
   - No `Application.get_env` — pass config as parameters

2. **Data In, Data Out**
   - Accept simple types (strings, integers, maps, lists)
   - Return simple types or tagged tuples (`{:ok, result}`, `{:error, reason}`)
   - Structs are OK if they're simple data containers
   - Pipeable: `input |> Core.new() |> Core.transform(params) |> Core.show()`

3. **Testability**
   - Every function can be tested without mocks, setup, or teardown
   - Same input always produces same output
   - No `start_supervised!` or process setup needed

4. **Boundary Functions**
   - `new/1` — Construct from external input (strings, maps, API responses)
   - Various operations — Core transformations (the "Reduce" step)
   - `show/1` or `to_*` — Convert to output format

## Arbor-Specific Patterns

### Extracting from GenServers

Before (mixed concerns):
```elixir
defmodule Arbor.Agent.SomeServer do
  def handle_call(:compute, _from, state) do
    # Business logic mixed with state management
    result = state.data
    |> Enum.filter(&(&1.score > threshold()))
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(10)
    |> Enum.map(&format_entry/1)

    {:reply, result, state}
  end
end
```

After (separated):
```elixir
defmodule Arbor.Agent.SomeCore do
  def new(entries), do: entries

  def top_entries(entries, threshold, limit \\ 10) do
    entries
    |> Enum.filter(&(&1.score > threshold))
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  def show(entries), do: Enum.map(entries, &format_entry/1)
end

defmodule Arbor.Agent.SomeServer do
  def handle_call(:compute, _from, state) do
    result = SomeCore.new(state.data) |> SomeCore.top_entries(threshold()) |> SomeCore.show()
    {:reply, result, state}
  end
end
```

### Extracting from LiveViews

Before:
```elixir
def handle_event("filter", %{"query" => q}, socket) do
  filtered = socket.assigns.agents
  |> Enum.filter(&String.contains?(&1.name, q))
  |> Enum.sort_by(& &1.last_active, {:desc, DateTime})
  {:noreply, assign(socket, filtered_agents: filtered, query: q)}
end
```

After:
```elixir
# Pure core
defmodule AgentListCore do
  def new(agents), do: agents
  def filter(agents, query), do: Enum.filter(agents, &String.contains?(&1.name, query))
  def sort_by_active(agents), do: Enum.sort_by(agents, & &1.last_active, {:desc, DateTime})
  def show(agents), do: agents  # or format for display
end

# LiveView just delegates
def handle_event("filter", %{"query" => q}, socket) do
  filtered = AgentListCore.new(socket.assigns.agents)
  |> AgentListCore.filter(q)
  |> AgentListCore.sort_by_active()
  {:noreply, assign(socket, filtered_agents: filtered, query: q)}
end
```

## When to Use

Use functional cores for:
- ✅ Calculations and transformations
- ✅ Business rules and validations
- ✅ Data formatting and parsing
- ✅ Classification and routing decisions
- ✅ Taint propagation rules
- ✅ Policy evaluation
- ✅ Message/context formatting

Don't use for:
- ❌ Database operations (use persistence layer)
- ❌ GenServer state management (use the GenServer, call the core from it)
- ❌ External API calls (use adapters)
- ❌ File I/O (use Shell/File facades)
- ❌ Process management (use supervisors)

## Testing Pattern

```elixir
defmodule Arbor.<Library>.<CoreName>Test do
  use ExUnit.Case, async: true

  alias Arbor.<Library>.<CoreName>

  describe "new/1" do
    test "constructs from valid input" do
      assert <CoreName>.new("input") == expected
    end

    test "handles edge cases" do
      assert <CoreName>.new("") == empty_state
    end
  end

  describe "pipeline" do
    test "works end to end with pipes" do
      result =
        "input"
        |> <CoreName>.new()
        |> <CoreName>.transform(params)
        |> <CoreName>.show()

      assert result == expected
    end
  end
end
```

## Identifying Extraction Opportunities

Signs a module needs a functional core extracted:
1. **GenServer callbacks contain business logic** — not just state management
2. **LiveView handle_event contains data transformations** — not just assign updates
3. **Same logic duplicated** across GenServer + LiveView + API endpoint
4. **Tests require process setup** for what should be pure computation
5. **Functions that don't use `self()`, `send()`, or process dictionary**
