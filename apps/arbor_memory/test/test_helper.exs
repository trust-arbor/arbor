# Add children to the empty app supervisor (start_children: false leaves it empty)
# Create ETS tables first (same as Application.start/2 does)
for table <- [:arbor_memory_graphs, :arbor_working_memory, :arbor_memory_proposals, :arbor_chat_history, :arbor_preferences] do
  if :ets.whereis(table) == :undefined do
    :ets.new(table, [:named_table, :public, :set])
  end
end

for child <- [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events},
      # Seed/Host Phase 3 stores
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []},
      {Arbor.Memory.ChatHistory, []}
    ] do
  Supervisor.start_child(Arbor.Memory.Supervisor, child)
end

# Signal system — emit functions need Store + Bus running
for child <- [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.Bus, []}
    ] do
  Supervisor.start_child(Arbor.Signals.Supervisor, child)
end

# Exclude database tests by default (require postgres + pgvector)
# Run them with: mix test --include database
ExUnit.configure(exclude: [:database, :llm, :llm_local])
ExUnit.start()
