defmodule Arbor.Memory.Application do
  @moduledoc false

  use Application

  @graph_ets :arbor_memory_graphs
  @working_memory_ets :arbor_working_memory
  @proposals_ets :arbor_memory_proposals

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_memory, :start_children, true) do
        # Create ETS tables eagerly to avoid race conditions.
        # Tables must be owned by a long-lived process (the Application starter),
        # not by transient test or request processes.
        ensure_ets(@graph_ets)
        ensure_ets(@working_memory_ets)
        ensure_ets(@proposals_ets)

        [
          {Registry, keys: :unique, name: Arbor.Memory.Registry},
          {Arbor.Memory.IndexSupervisor, []},
          {Arbor.Persistence.EventLog.ETS, name: :memory_events},
          # Seed/Host Phase 3 stores
          {Arbor.Memory.GoalStore, []},
          {Arbor.Memory.IntentStore, []},
          {Arbor.Memory.Thinking, []},
          {Arbor.Memory.CodeStore, []}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Memory.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_ets(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end
end
