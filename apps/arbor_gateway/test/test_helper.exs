# Add children to the empty app supervisors (start_children: false leaves them empty)
# arbor_gateway memory router tests need memory processes
for table <- [
      :arbor_memory_graphs,
      :arbor_working_memory,
      :arbor_memory_proposals,
      :arbor_chat_history,
      :arbor_preferences
    ] do
  if :ets.whereis(table) == :undefined do
    :ets.new(table, [:named_table, :public, :set])
  end
end

# Gracefully handle --no-start: only add children if the supervisor is running
if Process.whereis(Arbor.Memory.Supervisor) do
  for child <- [
        {Registry, keys: :unique, name: Arbor.Memory.Registry},
        {Arbor.Memory.IndexSupervisor, []},
        {Arbor.Persistence.EventLog.ETS, name: :memory_events}
      ] do
    Supervisor.start_child(Arbor.Memory.Supervisor, child)
  end
end

ExUnit.start()
