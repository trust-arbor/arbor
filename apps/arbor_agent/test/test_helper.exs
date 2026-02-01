# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [Arbor.Agent.Registry, Arbor.Agent.Supervisor] do
  Supervisor.start_child(Arbor.Agent.AppSupervisor, child)
end

ExUnit.start(exclude: [:skip])
