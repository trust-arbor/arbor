defmodule Arbor.Agent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_agent, :start_children, true) do
        [
          {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
          Arbor.Agent.Registry,
          Arbor.Agent.Supervisor
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Agent.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
