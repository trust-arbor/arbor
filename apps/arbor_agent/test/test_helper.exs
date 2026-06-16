# Add children to the empty app supervisor (start_children: false leaves it empty)
children = [
  {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
  {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
  Arbor.Agent.Registry,
  Arbor.Agent.SessionManager,
  Arbor.Agent.Supervisor
]

for child <- children do
  Supervisor.start_child(Arbor.Agent.AppSupervisor, child)
end

# arbor_memory is a sibling app at Level 2, not a dep of arbor_agent,
# so it doesn't start in this isolated test env. But arbor_agent's
# Lifecycle.set_initial_goals/2 eventually calls
# Arbor.Memory.GoalStore.{get_active_goals, add_goal}/_ which expect the
# `:arbor_memory_goals` named ETS table to exist. The read path was made
# resilient (returns [] on missing table) but writes need the table.
#
# Spawn a long-lived owner process that creates the table at suite start
# and holds it for the entire run. Public + set semantics match the
# production GoalStore.init/1 setup.
if :ets.whereis(:arbor_memory_goals) == :undefined do
  parent = self()

  spawn(fn ->
    :ets.new(:arbor_memory_goals, [:named_table, :public, :set])
    send(parent, :goal_store_table_ready)
    Process.sleep(:infinity)
  end)

  receive do
    :goal_store_table_ready -> :ok
  after
    2_000 -> raise "test_helper: timed out waiting for :arbor_memory_goals ETS table"
  end
end

# :integration/:slow run by default (hermetic — gating CI runs plain `mix test`);
# only backend-dependent tags are excluded. Fast loop: `mix test.fast`.
ExUnit.start(exclude: [:skip, :external, :llm, :llm_local])
