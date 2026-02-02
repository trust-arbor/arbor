# Add children to the empty app supervisors (start_children: false leaves them empty)
# Order matters: Registry first, then Supervisor, then EventStore, then Coordinator
children = [
  Arbor.Consensus.EventStore,
  {Registry, keys: :unique, name: Arbor.Consensus.EvaluatorAgent.Registry},
  Arbor.Consensus.EvaluatorAgent.Supervisor,
  Arbor.Consensus.Coordinator
]

for child <- children do
  Supervisor.start_child(Arbor.Consensus.Supervisor, child)
end

# Deterministic evaluator tests need shell processes
Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

ExUnit.start()
