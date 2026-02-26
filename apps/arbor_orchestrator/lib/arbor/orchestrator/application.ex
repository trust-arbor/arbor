defmodule Arbor.Orchestrator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry},
      Arbor.Orchestrator.SignalsBridge,
      Arbor.Orchestrator.JobRegistry,
      Arbor.Orchestrator.DotCache,
      {DynamicSupervisor, name: Arbor.Orchestrator.PipelineSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Arbor.Orchestrator.SessionRegistry},
      Arbor.Orchestrator.Session.Supervisor,
      Arbor.Orchestrator.Session.TaskSupervisor
    ]

    result =
      Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Orchestrator.Supervisor)

    # Populate handler DI registries with core entries after supervision tree is up
    case result do
      {:ok, _pid} -> Arbor.Orchestrator.Registrar.register_core()
      _ -> :ok
    end

    result
  end
end
