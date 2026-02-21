defmodule Arbor.Agent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_agent, :start_children, true) do
        [
          # Registries (must start before supervisors that use them)
          {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ActionCycleRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.MaintenanceRegistry},
          # Named processes
          Arbor.Agent.Registry,
          Arbor.Agent.SummaryCache,
          Arbor.Agent.Fitness,
          Arbor.Agent.SessionManager,
          # Dynamic supervisors (Phase 3: three-loop architecture)
          Arbor.Agent.ActionCycleSupervisor,
          Arbor.Agent.MaintenanceSupervisor,
          # Agent supervisor (must be last)
          Arbor.Agent.Supervisor
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Agent.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
