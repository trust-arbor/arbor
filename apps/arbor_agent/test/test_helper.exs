# Add children to the empty app supervisor (start_children: false leaves it empty)
children = [
  {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
  {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
  Arbor.Agent.Registry,
  Arbor.Agent.Supervisor
]

for child <- children do
  Supervisor.start_child(Arbor.Agent.AppSupervisor, child)
end

ExUnit.start(exclude: [:skip])
