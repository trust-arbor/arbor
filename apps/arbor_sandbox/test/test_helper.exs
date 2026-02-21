# Add children to the empty app supervisor (start_children: false leaves it empty)
Supervisor.start_child(Arbor.Sandbox.Supervisor, Arbor.Sandbox.Registry)

ExUnit.start(exclude: [:llm, :llm_local])
