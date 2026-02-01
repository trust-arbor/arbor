# Add children to the empty app supervisors (start_children: false leaves them empty)
# arbor_actions tests need shell and persistence processes
Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

for child <- [
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ] do
  Supervisor.start_child(Arbor.Persistence.Supervisor, child)
end

ExUnit.start()
