defmodule Arbor.Orchestrator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry},
      {DynamicSupervisor, name: Arbor.Orchestrator.PipelineSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Arbor.Orchestrator.SessionRegistry},
      Arbor.Orchestrator.Session.Supervisor,
      Arbor.Orchestrator.Session.TaskSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Orchestrator.Supervisor)
  end
end
