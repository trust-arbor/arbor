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

# Memory stores + durable knowledge-graph authority.
#
# Replaces a hand-rolled MemoryGoalsTableOwner that existed only to create the
# :arbor_memory_goals ETS table, on the since-outdated premise that
# "arbor_memory is a sibling app, not a dep of arbor_agent" — it IS a dep.
# GoalStore creates that table in its own init/1, so starting the real store is
# both simpler and closer to production. See Arbor.Memory.TestBootstrap.
# authority: false — SeedTest owns :arbor_memory_durable per-test so it can
# swap in a deliberately-failing backend for its outage security regressions. A
# suite-wide instance would make its start_supervised! a no-op and the matching
# stop_supervised! raise "not found".
Arbor.Memory.TestBootstrap.start!(authority: false)

if :ets.whereis(:arbor_memory_goals) == :undefined do
  raise "test_helper: :arbor_memory_goals missing after TestBootstrap (GoalStore did not start)"
end

# :integration/:slow run by default (hermetic — gating CI runs plain `mix test`);
# only backend-dependent tags are excluded. Fast loop: `mix test.fast`.
ExUnit.start(exclude: [:skip, :external, :llm, :llm_local])
