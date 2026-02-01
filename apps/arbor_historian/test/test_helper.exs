is_watch = System.get_env("MIX_TEST_WATCH") == "true"
is_ci = System.get_env("CI") == "true"

# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [
      {Arbor.Persistence.EventLog.ETS, name: Arbor.Historian.EventLog.ETS},
      {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
    ] do
  Supervisor.start_child(Arbor.Historian.Supervisor, child)
end

exclude =
  cond do
    is_watch -> [:integration, :distributed, :chaos, :slow]
    is_ci -> [:distributed, :chaos]
    true -> [:integration, :distributed, :chaos]
  end

ExUnit.start(exclude: exclude, async: !is_ci)
