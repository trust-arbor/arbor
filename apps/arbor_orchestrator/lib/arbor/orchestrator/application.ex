defmodule Arbor.Orchestrator.Application do
  @moduledoc false

  use Application

  alias Arbor.Orchestrator.Config

  @impl true
  def start(_type, _args) do
    # Hot lifecycle ETS is owned exclusively by RunJournal (created in its
    # init, private, dies with the journal process). Do not create
    # :arbor_pipeline_runs here — a table that outlives the journal would
    # reintroduce public/orphaned hot state.

    event_log_name =
      Application.get_env(:arbor_orchestrator, :event_log_name, :orchestrator_events)

    event_log_backend =
      Application.get_env(:arbor_orchestrator, :event_log_backend, Arbor.Persistence.EventLog.ETS)

    journal_opts = run_journal_opts()

    case Config.fetch_engine_checkpoints() do
      {:error, reason} ->
        # Fail closed on malformed operator config rather than silently picking
        # another checkpoint backend or the historical default incorrectly.
        {:error, {:invalid_engine_checkpoints, reason}}

      {:ok, checkpoint_opts} ->
        children =
          maybe_run_journal_store_child(journal_opts) ++
            maybe_checkpoint_store_child(checkpoint_opts) ++
            [
              Arbor.Common.HandlerRegistry,
              {event_log_backend, name: event_log_name},
              {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry},
              Arbor.Orchestrator.SignalsBridge,
              # Canonical current-run lifecycle store (optional durable Store via config)
              {Arbor.Orchestrator.RunJournal, journal_opts},
              # Historical JobRegistry only — no current-run lifecycle dual-write
              Arbor.Orchestrator.JobRegistry,
              Arbor.Orchestrator.DotCache,
              {DynamicSupervisor,
               name: Arbor.Orchestrator.PipelineSupervisor, strategy: :one_for_one},
              {Registry, keys: :unique, name: Arbor.Orchestrator.SessionRegistry},
              Arbor.Orchestrator.Session.Supervisor,
              Arbor.Orchestrator.Session.TaskSupervisor,
              Arbor.Orchestrator.RecoveryCoordinator
            ]

        result =
          Supervisor.start_link(children,
            strategy: :one_for_one,
            name: Arbor.Orchestrator.Supervisor
          )

        # Populate handler DI registries with core entries after supervision tree is up
        case result do
          {:ok, _pid} ->
            Arbor.Orchestrator.Registrar.register_core()
            maybe_preflight_models()

          _ ->
            :ok
        end

        result
    end
  end

  defp run_journal_opts do
    Application.get_env(:arbor_orchestrator, :run_journal, [])
  end

  # When a Store backend is configured, start it as an explicit supervised
  # sibling *before* RunJournal. Never as a hidden linked child of RunJournal.
  # Incomplete backends (no start_link/1) are not started silently — either
  # the operator supplies reviewed child opts, or the process must already run.
  defp maybe_run_journal_store_child(opts) do
    backend = Keyword.get(opts, :backend)
    store_name = Keyword.get(opts, :store_name, :arbor_pipeline_run_lifecycle)
    start_store? = Keyword.get(opts, :start_store, true)
    store_child_opts = Keyword.get(opts, :store_child_opts, [])

    cond do
      is_nil(backend) or not start_store? ->
        []

      function_exported?(backend, :start_link, 1) ->
        child_opts =
          store_child_opts
          |> Keyword.put_new(:name, store_name)

        [{backend, child_opts}]

      true ->
        # Configured backend cannot be supervised here — require it already
        # running. RunJournal will surface durable errors if it is not.
        []
    end
  end

  # Derive the Engine checkpoint store child from the same Config authority
  # Engine uses for persist/load/cleanup. Placed before Engine consumers
  # (RunJournal/RecoveryCoordinator/sessions). Supports store:nil and
  # start_store:false (externally managed).
  defp maybe_checkpoint_store_child(opts) when is_list(opts) do
    store = Keyword.get(opts, :store)
    start_store? = Keyword.get(opts, :start_store, true)
    store_name = Keyword.get(opts, :store_name)
    store_child_opts = Keyword.get(opts, :store_child_opts, [])

    cond do
      is_nil(store) or not start_store? ->
        []

      not is_atom(store) ->
        # Validated by Config already; belt-and-braces.
        []

      function_exported?(store, :start_link, 1) ->
        child_opts =
          store_child_opts
          |> Keyword.put_new(:name, store_name)

        [{store, child_opts}]

      true ->
        # Configured store cannot be supervised here — operator must start it
        # externally (start_store: false is the explicit form of that).
        []
    end
  end

  # Warn-only preflight: verify configured local LLM models are actually loaded on
  # their providers. Runs async so it never blocks/delays startup; failures only warn.
  # Disabled in :test (see config/test.exs) so tests don't poke local providers.
  defp maybe_preflight_models do
    if Application.get_env(:arbor_orchestrator, :preflight_models_on_start, true) do
      Task.start(fn -> Arbor.LLM.Preflight.check_and_log() end)
    end

    :ok
  end
end
