# Imperative Shell Pattern

The other half of [functional-core](functional-core.md) (CRC). The core decides; the **shell** does I/O and makes the core's decisions real. This is the half that rots — logic creeps back into the shell one `cond` at a time — so it gets its own discipline.

## What a shell is

A shell is the impure boundary: a GenServer callback, a Jido action's `run/2`, a LiveView `handle_event`, a Plug, an adapter. Its job is exactly three steps:

1. **Gather** — read the impure inputs (state, ETS, DB, `DateTime.utc_now()`, request params).
2. **Call one core pipeline** — `Core.new(...) |> Core.op(...) |> Core.show()`, or a reducer's `{:ok, new_state, effects} = Core.decide(state, input, now)`.
3. **Commit** — perform the effects (persist, emit, reply), update state, return.

A well-formed shell is almost all boilerplate plus a *single* core-pipeline line. If you can't see the pipeline at a glance, logic has leaked.

## The shell checklist

Before considering a shell done, verify:

- [ ] **No business branching.** No `cond`/multi-clause `case` on domain values, no `Enum.filter/map/reduce` over domain data. Branching on `{:ok, _}` vs `{:error, _}` from the core is fine; branching on *what the core should have decided* is a leak — move it into the core.
- [ ] **Time and IDs are generated here, passed in.** The shell calls `DateTime.utc_now()` / `make_ref()` and passes them to the core. The core never calls them.
- [ ] **One core pipeline, visible.** If a callback calls three unrelated cores and stitches them, the stitching logic is itself a decision — give it a core.
- [ ] **Effects come from the core as data; the shell only interprets them.** The shell does not *decide* which signal to emit; it emits what the core returned. (See effects-as-data in functional-core.)
- [ ] **Errors surface, not swallowed.** A core returning `{:error, reason}` becomes a reply/log/telemetry — the shell doesn't paper over it with a default that hides the decision.

## Effect interpreter

For reducer cores that return `{:ok, state, effects}`, the shell owns a small, dumb interpreter — the single place side effects happen:

```elixir
defp perform_effect({:emit, topic, payload}), do: Arbor.Signals.emit(topic, payload)
defp perform_effect({:persist, record}),      do: Store.put(record)
defp perform_effect({:grant, cap}),           do: Arbor.Security.grant(cap)
```

Keep it total and boring: one clause per effect kind, no logic beyond dispatch. When a new effect kind appears, it's a new clause here and a new tuple in the core's test — nowhere else.

## Smells that mean logic leaked back

- A GenServer callback longer than ~15 lines that isn't just message plumbing.
- A `handle_event` that transforms `socket.assigns` inline instead of calling a core.
- The same decision appearing in a GenServer AND a LiveView AND an action (the classic sign the core doesn't exist yet — extract once, call three times).
- A test that needs `start_supervised!` to check something that is really pure computation. That computation wants to be in a core with a plain `assert`.

## Relationship to the grain rule

Per `2026-06-15-orchestrator-as-pipeline-kernel.md`: a mechanical state transform inside a GenServer is **"functional core (CRC) + imperative shell — NOT a graph."** The shell is the GenServer; the core is the pure decision. Don't reach for a DOT graph to express what is really one pure function plus a commit. Conversely, don't bury a genuinely program-shaped, branchy, agent-authored flow inside a shell — that one IS a graph.
