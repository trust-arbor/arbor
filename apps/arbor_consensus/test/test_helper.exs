# Add children to the empty app supervisors (start_children: false leaves them empty)
for child <- [Arbor.Consensus.EventStore, Arbor.Consensus.Coordinator] do
  Supervisor.start_child(Arbor.Consensus.Supervisor, child)
end

# Deterministic evaluator tests need shell processes
Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

ExUnit.start()
