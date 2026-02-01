# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.TopicKeys, []},
      {Arbor.Signals.Channels, []},
      {Arbor.Signals.Bus, []}
    ] do
  Supervisor.start_child(Arbor.Signals.Supervisor, child)
end

ExUnit.start()
