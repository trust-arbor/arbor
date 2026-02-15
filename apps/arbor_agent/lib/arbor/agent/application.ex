defmodule Arbor.Agent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_agent, :start_children, true) do
        base_children = [
          {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry},
          Arbor.Agent.Registry,
          Arbor.Agent.SummaryCache,
          Arbor.Agent.Fitness,
          Arbor.Agent.SessionManager,
          Arbor.Agent.Supervisor
        ]

        # Optionally start DebugAgent for self-healing
        if Application.get_env(:arbor_agent, :start_debug_agent, false) do
          base_children ++ [Arbor.Agent.DebugAgent]
        else
          base_children
        end
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Agent.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
