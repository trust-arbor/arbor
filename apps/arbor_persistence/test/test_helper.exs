# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ] do
  Supervisor.start_child(Arbor.Persistence.Supervisor, child)
end

# Exclude database tests by default (require PostgreSQL setup)
# Run with: mix test --include database
ExUnit.start(exclude: [:database])
