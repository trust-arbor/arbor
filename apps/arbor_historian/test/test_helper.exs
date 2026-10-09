is_watch = System.get_env("MIX_TEST_WATCH") == "true"
is_ci = System.get_env("CI") == "true"

# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [
      {Arbor.Persistence.EventLog.ETS, name: Arbor.Historian.EventLog.ETS, mode: :projection},
      {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
    ] do
  Supervisor.start_child(Arbor.Historian.Supervisor, child)
end

exclude =
  cond do
    is_watch -> [:database, :integration, :distributed, :chaos, :slow, :llm, :llm_local]
    is_ci -> [:database, :distributed, :chaos, :llm, :llm_local]
    true -> [:database, :integration, :distributed, :chaos, :llm, :llm_local]
  end

ExUnit.start(exclude: exclude, async: !is_ci)
