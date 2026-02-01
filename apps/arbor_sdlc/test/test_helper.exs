# Add children to the empty app supervisor (start_children: false leaves it empty)
config = Arbor.SDLC.Config.new()

for child <- [
      {Arbor.SDLC.PersistentFileTracker, [name: Arbor.SDLC.FileTracker, config: config]},
      {Task.Supervisor, name: Arbor.SDLC.TaskSupervisor}
    ] do
  Supervisor.start_child(Arbor.SDLC.Supervisor, child)
end

ExUnit.start()
