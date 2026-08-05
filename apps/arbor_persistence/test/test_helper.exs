# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [
      {Arbor.Persistence.Checkpoint.Store.ETS, []},
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ] do
  Supervisor.start_child(Arbor.Persistence.Supervisor, child)
end

# Exclude database and isolated-repo tests by default.
# Run database tests with: mix test --include database
# Run the real SQLite pool proof with: mix test --include database --include isolated_repo
ExUnit.start(exclude: [:database, :isolated_repo, :llm, :llm_local])
