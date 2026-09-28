# Arbor Persistence Ecto

Postgres-backed event storage for Arbor, implementing the EventLog
behaviour on Commanded's `eventstore` library. Use this when ETS-backed
`arbor_persistence` is not enough and streams must survive process
restarts.

```elixir
alias Arbor.Persistence.Ecto.EventLog
alias Arbor.Persistence.Event

event = Event.new("agent-123", "StateChanged", %{old: "foo", new: "bar"})
{:ok, [_persisted]} = EventLog.append("agent-123", event, [])
{:ok, events} = EventLog.read_stream("agent-123", [])
```

Configure `Arbor.Persistence.Ecto.EventStore` under `:arbor_persistence_ecto`,
then:

```bash
mix event_store.create -e Arbor.Persistence.Ecto.EventStore
mix event_store.init -e Arbor.Persistence.Ecto.EventStore
```

Some EventLog callbacks (for example `list_streams/1`) are still stubs and
return empty results with a warning. Check `Arbor.Persistence.Ecto.available?/0`
before treating Postgres as the active backend.

This is an umbrella app (L4). It depends on `arbor_kernel` and
`arbor_persistence`.

## License

MIT
