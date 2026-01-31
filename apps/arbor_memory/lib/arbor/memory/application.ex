defmodule Arbor.Memory.Application do
  @moduledoc false

  use Application

  @graph_ets :arbor_memory_graphs
  @working_memory_ets :arbor_working_memory

  @impl true
  def start(_type, _args) do
    # Create graph ETS table eagerly to avoid race conditions
    if :ets.whereis(@graph_ets) == :undefined do
      :ets.new(@graph_ets, [:named_table, :public, :set])
    end

    # Create working memory ETS table (Phase 2)
    if :ets.whereis(@working_memory_ets) == :undefined do
      :ets.new(@working_memory_ets, [:named_table, :public, :set])
    end

    children = [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Memory.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
