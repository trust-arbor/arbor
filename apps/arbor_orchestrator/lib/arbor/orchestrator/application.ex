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
        case checkpoint_store_child_spec(checkpoint_opts) do
          {:error, reason} ->
            # start_store: true with an unloadable / non-startable store must not
            # leave Application up while Engine targets a missing process.
            {:error, reason}

          {:ok, checkpoint_children} ->
            start_with_children(
              journal_opts,
              checkpoint_children,
              event_log_backend,
              event_log_name
            )
        end
    end
  end

  defp start_with_children(journal_opts, checkpoint_children, event_log_backend, event_log_name) do
    children =
      maybe_run_journal_store_child(journal_opts) ++
        checkpoint_children ++
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

  @doc false
  # Pure startup decision for the Engine checkpoint store child.
  #
  # Returns:
  #   `{:ok, []}` — no supervised child (`store: nil` or `start_store: false`)
  #   `{:ok, [{module, child_opts}]}` — child to place before Engine consumers
  #   `{:error, {:checkpoint_store_unstartable, reason}}` — fail closed when
  #     `start_store: true` but the module cannot be loaded / has no start_link/1
  #
  # `store_name` always wins over any `store_child_opts[:name]`.
  # Does not start processes; safe to call from tests without touching the live app.
  @spec checkpoint_store_child_spec(keyword()) ::
          {:ok, [tuple()]} | {:error, {:checkpoint_store_unstartable, term()}}
  def checkpoint_store_child_spec(opts) when is_list(opts) do
    store = Keyword.get(opts, :store)
    start_store? = Keyword.get(opts, :start_store, true)
    store_name = Keyword.get(opts, :store_name)
    store_child_opts = Keyword.get(opts, :store_child_opts, [])

    cond do
      # Explicit file-only or externally managed store — no Application child.
      is_nil(store) or start_store? == false ->
        {:ok, []}

      not is_atom(store) ->
        {:error, {:checkpoint_store_unstartable, :store_not_atom}}

      not is_atom(store_name) ->
        {:error, {:checkpoint_store_unstartable, :store_name_not_atom}}

      not is_list(store_child_opts) or not Keyword.keyword?(store_child_opts) ->
        {:error, {:checkpoint_store_unstartable, :store_child_opts_not_keyword}}

      true ->
        case ensure_module_exports_start_link(store) do
          :ok ->
            # store_name is the code-owned operation target; never start under a
            # conflicting child name from store_child_opts.
            child_opts = Keyword.put(store_child_opts, :name, store_name)
            {:ok, [{store, child_opts}]}

          {:error, reason} ->
            {:error, {:checkpoint_store_unstartable, reason}}
        end
    end
  end

  defp ensure_module_exports_start_link(store) when is_atom(store) do
    # Must load before function_exported?/3 — a valid but not-yet-loaded module
    # would otherwise look like a missing export and be silently omitted.
    case Code.ensure_loaded(store) do
      {:module, ^store} ->
        if function_exported?(store, :start_link, 1) do
          :ok
        else
          {:error, :missing_start_link}
        end

      {:error, reason} ->
        {:error, {:module_not_loadable, reason}}
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
