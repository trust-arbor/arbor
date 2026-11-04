defmodule Arbor.Orchestrator.Feature do
  @moduledoc """
  Passive description of direct Orchestrator Application contributions.

  `children/1` takes exactly `event_log_backend`, `event_log_name`, `run_journal`,
  `journal_store_admission`, raw `engine_checkpoints` and
  `checkpoint_store_admission`. These are already resolved owner inputs, not
  child plans or permission to resolve runtime facts. Journal admission is
  `:not_requested`, `:start_link_exported` or `:start_link_not_exported`;
  checkpoint admission is `:not_requested` or `:start_link_exported`.
  The historical journal omission and checkpoint fail-closed paths are distinct.
  This module performs no module availability check or admission operation.

  Configured children can be rendered only for the audited two-key producers
  `Arbor.Persistence.BufferedStore` and `Arbor.Persistence.EventLog.ETS`.
  Unsupported configured producers are unresolved by the host, not presumed to
  have a GenServer spec. This reporting limit changes no startup admission rule.
  Journal options for an omitted/external store remain opaque data. Names and
  other raw options remain private in full maps and must never be serialized.

  Checkpoint input uses the existing pure explicit Config normalizer. Its raw
  nil/empty distinctions and validation precede the same child-name pinning as
  startup. Application.start, module loading, Registrar and preflight are never
  called. Existing Application wiring remains unchanged.

  The action catalog is the full catalog consumed by Registrar, physically
  supplied by Arbor.Actions. URI prefixes are NONEXCLUSIVE ACTION-CATALOG
  NAMESPACE REFERENCES, not delegation, ownership, grants or observed provider
  registration. Static app metadata identifies the separate registration actor.
  The two pure catalogs are captured at compilation; callbacks return data only.
  Optional graphs, routes and commands are undeclared. Health is unobserved.
  `requires/0` names the fixed host prerequisite, not an optional Shared-layer
  classification or the complete dependency closure.
  """

  @behaviour Arbor.Contracts.Feature

  alias Arbor.Orchestrator.Config

  @action_modules Arbor.Actions.all_actions()
  @uri_prefixes Arbor.Actions.capability_uri_prefixes()
  @known_store_producers [Arbor.Persistence.BufferedStore, Arbor.Persistence.EventLog.ETS]
  @invalid_snapshot "invalid or incomplete orchestrator feature snapshot"

  @impl true
  def id, do: :orchestrator

  @impl true
  def requires, do: [:core]

  @impl true
  def action_modules, do: @action_modules

  @impl true
  def uri_prefixes, do: @uri_prefixes

  @impl true
  def health, do: %{status: :unobserved}

  @impl true
  def children(
        %{
          event_log_backend: event_log_backend,
          event_log_name: event_log_name,
          run_journal: journal_opts,
          journal_store_admission: journal_admission,
          engine_checkpoints: raw_checkpoints,
          checkpoint_store_admission: checkpoint_admission
        } = snapshot
      )
      when map_size(snapshot) == 6 do
    with true <- keyword?(journal_opts),
         {:ok, checkpoint_opts} <- Config.fetch_engine_checkpoints(raw_checkpoints) do
      journal_store_children(journal_opts, journal_admission) ++
        checkpoint_store_children(checkpoint_opts, checkpoint_admission) ++
        [
          %{
            id: Arbor.Common.HandlerRegistry,
            start:
              {Arbor.Common.HandlerRegistry, :start_link,
               [
                 [
                   core_registration_authority: [
                     name: Arbor.Orchestrator.Handlers.RegistryAuthority,
                     directory: :arbor_orchestrator_handler_registry_authority,
                     application: :arbor_orchestrator,
                     child_path: [Arbor.Orchestrator.Handlers.RegistryAuthority]
                   ]
                 ]
               ]},
            type: :worker,
            restart: :permanent
          },
          worker(Arbor.Orchestrator.Handlers.RegistryAuthority),
          store_spec(event_log_backend, name: event_log_name),
          registry(:duplicate, Arbor.Orchestrator.EventRegistry),
          worker(Arbor.Orchestrator.SignalsBridge),
          %{
            id: Keyword.get(journal_opts, :name, Arbor.Orchestrator.RunJournal),
            start: {Arbor.Orchestrator.RunJournal, :start_link, [journal_opts]},
            type: :worker,
            restart: :permanent,
            shutdown: 5_000
          },
          worker(Arbor.Orchestrator.JobRegistry),
          worker(Arbor.Orchestrator.DotCache),
          %{
            id: Arbor.Orchestrator.PipelineSupervisor,
            start:
              {DynamicSupervisor, :start_link,
               [[name: Arbor.Orchestrator.PipelineSupervisor, strategy: :one_for_one]]},
            type: :supervisor
          },
          registry(:unique, Arbor.Orchestrator.SessionRegistry),
          %{
            id: Arbor.Orchestrator.Session.Supervisor,
            start: {Arbor.Orchestrator.Session.Supervisor, :start_link, [[]]},
            type: :supervisor
          },
          %{
            id: Arbor.Orchestrator.Session.TaskSupervisor,
            start: {Arbor.Orchestrator.Session.TaskSupervisor, :start_link, [[]]},
            type: :supervisor
          },
          worker(Arbor.Orchestrator.RecoveryCoordinator)
        ]
    else
      _ -> invalid_snapshot!()
    end
  end

  def children(_snapshot), do: invalid_snapshot!()

  defp journal_store_children(opts, admission) do
    backend = Keyword.get(opts, :backend)
    start_store = Keyword.get(opts, :start_store, true)

    case {backend, start_store, admission} do
      {nil, _, :not_requested} ->
        []

      {_, false, :not_requested} ->
        []

      {backend, true, :start_link_not_exported} when is_atom(backend) and not is_nil(backend) ->
        []

      {backend, true, :start_link_exported} when is_atom(backend) and not is_nil(backend) ->
        child_opts = Keyword.get(opts, :store_child_opts, [])

        if keyword?(child_opts) do
          child_opts =
            Keyword.put_new(
              child_opts,
              :name,
              Keyword.get(opts, :store_name, :arbor_pipeline_run_lifecycle)
            )

          [store_spec(backend, child_opts)]
        else
          invalid_snapshot!()
        end

      _ ->
        invalid_snapshot!()
    end
  end

  defp checkpoint_store_children(opts, admission) do
    if is_nil(opts[:store]) or opts[:start_store] == false do
      if admission == :not_requested, do: [], else: invalid_snapshot!()
    else
      if admission == :start_link_exported do
        child_opts = Keyword.put(opts[:store_child_opts], :name, opts[:store_name])
        [store_spec(opts[:store], child_opts)]
      else
        invalid_snapshot!()
      end
    end
  end

  defp store_spec(module, opts) when module in @known_store_producers do
    %{id: module, start: {module, :start_link, [opts]}}
  end

  defp store_spec(_module, _opts), do: invalid_snapshot!()

  defp worker(module), do: %{id: module, start: {module, :start_link, [[]]}}

  defp registry(keys, name) do
    %{
      id: name,
      start: {Registry, :start_link, [[keys: keys, name: name]]},
      type: :supervisor
    }
  end

  defp keyword?(value), do: is_list(value) and Keyword.keyword?(value)
  defp invalid_snapshot!, do: raise(ArgumentError, @invalid_snapshot)
end
