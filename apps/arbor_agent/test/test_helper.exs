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
# Supervised test-only owner (see Arbor.Agent.Test.MemoryGoalsTableOwner):
# deterministic/idempotent startup under AppSupervisor, reaped on
# application shutdown so the suite never leaks an unsupervised sleeper.
ensure_memory_goals_table_owner = fn ->
  if :ets.whereis(:arbor_memory_goals) != :undefined do
    :ok
  else
    case Supervisor.start_child(
           Arbor.Agent.AppSupervisor,
           Arbor.Agent.Test.MemoryGoalsTableOwner
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, {:already_present, _}} ->
        case Supervisor.restart_child(
               Arbor.Agent.AppSupervisor,
               Arbor.Agent.Test.MemoryGoalsTableOwner
             ) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> raise "test_helper: failed to restart MemoryGoalsTableOwner: #{inspect(other)}"
        end

      other ->
        raise "test_helper: failed to start MemoryGoalsTableOwner: #{inspect(other)}"
    end
  end

  # Deterministic readiness: named table must exist before tests run.
  if :ets.whereis(:arbor_memory_goals) == :undefined do
    raise "test_helper: :arbor_memory_goals ETS table missing after owner start"
  end

  :ok
end

ensure_memory_goals_table_owner.()

# :integration/:slow run by default (hermetic — gating CI runs plain `mix test`);
# only backend-dependent tags are excluded. Fast loop: `mix test.fast`.
ExUnit.start(exclude: [:skip, :external, :llm, :llm_local])
