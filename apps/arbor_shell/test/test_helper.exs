# Add children to the empty app supervisor (start_children: false leaves it empty)
Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

ExUnit.start()
