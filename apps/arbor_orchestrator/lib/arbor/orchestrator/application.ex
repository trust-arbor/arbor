defmodule Arbor.Orchestrator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Pipeline run tracking — shared ETS table written by Engine processes,
    # read by the PipelineStatus Facade. Public + write_concurrency so
    # multiple Engine processes can write simultaneously without blocking.
    # Read access goes through the Facade for trust-zone filtering.
    :ets.new(:arbor_pipeline_runs, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    event_log_name =
      Application.get_env(:arbor_orchestrator, :event_log_name, :orchestrator_events)

    event_log_backend =
      Application.get_env(:arbor_orchestrator, :event_log_backend, Arbor.Persistence.EventLog.ETS)

    children = [
      Arbor.Common.HandlerRegistry,
      {event_log_backend, name: event_log_name},
      {Arbor.Persistence.BufferedStore,
       name: :arbor_orchestrator_checkpoints, collection: "orchestrator_checkpoints"},
      {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry},
      Arbor.Orchestrator.SignalsBridge,
      Arbor.Orchestrator.JobRegistry,
      Arbor.Orchestrator.DotCache,
      {DynamicSupervisor, name: Arbor.Orchestrator.PipelineSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Arbor.Orchestrator.SessionRegistry},
      Arbor.Orchestrator.Session.Supervisor,
      Arbor.Orchestrator.Session.TaskSupervisor,
      Arbor.Orchestrator.RecoveryCoordinator
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
