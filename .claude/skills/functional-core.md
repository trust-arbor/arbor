# Functional Core Pattern (CRC)

Build pure functional modules that separate business logic from side effects using the Construct-Reduce-Convert pattern.

> **The core is one half of the pattern. The [imperative shell](imperative-shell.md) is the other half — read it too.** A core with no disciplined shell just moves the mess; the shell is the half that rots.

## Pattern Overview

A functional core is a module containing pure functions that:
- Take plain data structures as input
- Return plain data structures as output
- Have no side effects (no DB calls, no GenServer calls, no external APIs, no IO)
- Are easily testable in isolation

### The metric: extract a core when a pure decision has no unit test

"Get as much code as possible onto CRC" is the **wrong** goal — it produces identity `new/show` wrappers around code that was already fine. The right trigger for extraction: **is there a pure decision here that currently has no unit test?** If yes, extract it and write the test — that IS the work. If a module is an adapter, transport, supervisor, or thin CRUD store with no decision to make, leave it alone; a "core" there is ceremony. (Nearly every "sophisticated machinery, unwired last mile" bug in Arbor has been a shell doing decision work with no core to test.)

### Two shapes of core (they differ, don't conflate them)

- **Transform cores** — filter / sort / format a snapshot for display (most dashboard cores). `new` = ingest/identity, operations = pure views, `show` = view-model. Stateless per call.
- **Reducer cores** — decide a *state transition* (memory, session, config, auth, mode selection). `new` = reconstruct typed state from JSON/records, operations = transitions, `show` = serialize back. These are the load-bearing ones, and they use the **effects-as-data** return convention (see below). When you hear "this should be a testable state machine," that's a reducer core.

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

1. **Pure Functions Only** (this is mechanically enforced — see Purity Lint)
   - No `Repo` calls or ETS reads
   - No `GenServer.call` or process messaging
   - No HTTP requests or file I/O
   - **No `DateTime.utc_now()`, `System.*_time`, `:rand`, `:erlang.unique_integer`, `make_ref` — time and randomness are IMPURE.** Pass `now` and any id/rand generator as an explicit parameter, defaulted at the *shell* boundary, never called inside the core. (Standard signatures: `new(params, now)` or `new(params, opts)` with `opts[:now]`, `opts[:id_fn]`.) This is not pedantry: it's what makes cores property-testable and replayable — load-bearing for the event-sourced design.
   - No `Application.get_env` — pass config as parameters
   - **Cores depend only on cores + `arbor_contracts` structs** — never another library's facade or a sibling GenServer. One impure transitive dep silently kills the whole testability claim.

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

## Effects as Data (the return convention for reducer cores)

A pure core can't *perform* a side effect — but a decision core often decides that one *should* happen (emit signal X, persist record Y, grant capability Z). Do NOT leak the effect into the core, and do NOT re-derive it in the shell. Instead **return effects as data** and let the [shell](imperative-shell.md) interpret them:

```elixir
# Core: pure decision, returns state + a list of effect descriptions
def apply_result(state, result, now) do
  new_state = %{state | turns: state.turns + 1, last: result}
  effects = [
    {:emit, "session.turn_complete", %{turn: new_state.turns}},
    {:persist, {:turn, new_state.turns, result}}
  ]
  {:ok, new_state, effects}
end
```

```elixir
# Shell: interprets the effects — the ONLY place side effects happen
{:ok, new_state, effects} = SessionCore.apply_result(state, result, now())
Enum.each(effects, &perform_effect/1)   # emit / persist / grant
{:noreply, %{state | core: new_state}}
```

Why this is the highest-leverage addition for Arbor: it makes "which signal fires / what gets persisted / whether auth denies" **unit-testable by asserting on the effect list — no mocks, no process setup**. It's exactly what the security, memory, session, and consensus reducers need. (Prior art: Elm's `update` returning commands; the Engine already collects node outcomes this way.) Effects are plain terms — `{:emit, topic, payload}`, `{:persist, record}`, `{:grant, cap}` — never closures or pids.

## Purity Lint (the pattern is only real if it's checked)

CRC drift is silent: a `DateTime.utc_now()` sneaks into a core and nothing complains until replay breaks. Guard it the same way the library hierarchy is guarded — a committed test that greps every `*_core.ex`:

```elixir
# Fails CI if any *_core.ex contains an impure call.
@forbidden ~r/DateTime\.utc_now|System\.(monotonic|os|system)_time|:rand\.|:erlang\.unique_integer|make_ref|Application\.get_env|GenServer\.|Repo\.|:ets\.|Logger\./
test "functional cores contain no impurity" do
  for path <- Path.wildcard("apps/*/lib/**/*_core.ex") do
    src = File.read!(path)
    refute Regex.match?(@forbidden, src), "impure call in #{path}"
  end
end
```

Add allowed-exception annotations sparingly (a `# purity-lint:allow reason` comment the test skips) rather than weakening the regex. This is the CRC analogue of the hierarchy drift-guard.

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

Don't use for (these are stopping rules, not soft guidance — a core here is ceremony):
- ❌ Database operations (use persistence layer)
- ❌ GenServer state management (use the GenServer, call the core from it)
- ❌ External API calls (use adapters)
- ❌ File I/O (use Shell/File facades)
- ❌ Process management (use supervisors)
- ❌ Adapters, transports, thin CRUD stores with no decision to make
- ❌ Chasing coverage in a library that's already CRC-heavy (e.g. dashboard) — the untested decision logic lives in the cognition band (agent / orchestrator / memory / security), not the UI

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
