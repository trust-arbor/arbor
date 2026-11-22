defmodule Arbor.Orchestrator.FeatureTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Config

  @feature Arbor.Orchestrator.Feature
  @invalid "invalid or incomplete orchestrator feature snapshot"
  @application_sha256 "0de967c902880d1761a0e4ead7137436d4362464f6f6bbba438dafd024ddb3a3"

  # Finite callback-attempt audit. Setup and real comparison producers remain
  # outside the trace window; only MFA/arity is retained, never argument values.
  @forbidden_calls [
    {Code, :ensure_loaded, 1},
    {Code, :ensure_loaded?, 1},
    {:code, :ensure_loaded, 1},
    {:code, :is_loaded, 1},
    {:erlang, :function_exported, 3},
    {Application, :get_env, 2},
    {Application, :get_env, 3},
    {Application, :fetch_env, 2},
    {Application, :fetch_env!, 2},
    {Application, :get_all_env, 1},
    {Application, :put_env, 3},
    {Application, :put_env, 4},
    {Application, :put_all_env, 1},
    {Application, :put_all_env, 2},
    {Application, :delete_env, 2},
    {Application, :delete_env, 3},
    {Application, :ensure_all_started, 1},
    {Application, :ensure_all_started, 2},
    {Application, :ensure_started, 1},
    {Application, :ensure_started, 2},
    {Application, :start, 1},
    {Application, :start, 2},
    {Application, :stop, 1},
    {Supervisor, :child_spec, 2},
    {Supervisor, :start_link, 2},
    {Supervisor, :start_link, 3},
    {GenServer, :start, 2},
    {GenServer, :start, 3},
    {GenServer, :start_link, 2},
    {GenServer, :start_link, 3},
    {DynamicSupervisor, :start_link, 1},
    {DynamicSupervisor, :start_link, 2},
    {DynamicSupervisor, :start_link, 3},
    {:erlang, :make_ref, 0},
    {:erlang, :spawn, 1},
    {:erlang, :spawn, 3},
    {:erlang, :spawn_link, 1},
    {:erlang, :spawn_link, 3},
    {:erlang, :spawn_monitor, 1},
    {:erlang, :spawn_monitor, 3},
    {:erlang, :spawn_opt, 2},
    {:erlang, :spawn_opt, 4},
    {Task, :start, 1},
    {Task, :start, 3},
    {Task, :start_link, 1},
    {Task, :start_link, 3},
    {Task, :async, 1},
    {Task, :async, 3},
    {:ets, :new, 2},
    {:ets, :insert, 2},
    {:ets, :insert_new, 2},
    {:ets, :delete, 1},
    {:ets, :delete, 2},
    {:persistent_term, :get, 1},
    {:persistent_term, :get, 2},
    {:persistent_term, :put, 2},
    {:persistent_term, :erase, 1}
  ]

  test "finite callback guard detects a failed nonexistent loader attempt" do
    missing = :"Elixir.Arbor.Orchestrator.FeatureLoaderGuardPositiveControlMustRemainUnloaded"
    assert :code.is_loaded(missing) == false

    {outcome, calls} = observe_forbidden_calls(fn -> Code.ensure_loaded?(missing) end)
    assert outcome == {:returned, false}
    assert {Code, :ensure_loaded?, 1} in calls
    assert_raise ExUnit.AssertionError, fn -> assert_no_forbidden_calls(calls) end
    assert :code.is_loaded(missing) == false
  end

  test "real Orchestrator declaration and nonexclusive catalog-reference metadata" do
    assert apply(@feature, :id, []) == :orchestrator
    assert apply(@feature, :requires, []) == [:core]
    assert apply(@feature, :health, []) == %{status: :unobserved}
    assert Arbor.Contracts.Feature in apply(@feature, :module_info, [:attributes])[:behaviour]

    for callback <- [:graphs, :commands, :routes] do
      refute function_exported?(@feature, callback, 0)
    end

    assert Application.fetch_env!(:arbor_orchestrator, :arbor_feature) == @feature
    metadata = Application.fetch_env!(:arbor_orchestrator, :arbor_feature_metadata)
    assert metadata.id == :orchestrator
    assert metadata.requires == [:core]
    assert metadata.dependency_role == :fixed_host_prerequisite
    assert metadata.contribution_scope == :direct_application_entrypoint

    assert metadata.snapshot_required_keys ==
             [
               :event_log_backend,
               :event_log_name,
               :run_journal,
               :journal_store_admission,
               :engine_checkpoints,
               :checkpoint_store_admission
             ]

    assert metadata.sources.physical_catalog_owner == :arbor_actions
    assert metadata.sources.catalog_producer == Arbor.Actions
    assert metadata.sources.registering_actor == Arbor.Orchestrator.Registrar
    assert metadata.sources.uri_role == :nonexclusive_action_catalog_namespace_reference
    assert metadata.sources.uri_registration_actor == Arbor.Actions.Application
    assert metadata.sources.uri_registration_status == :unobserved
    refute "private-child-name-canary" in metadata.public_child_ids
    assert Enum.all?(metadata.public_child_ids, &is_atom/1)
  end

  test "Application wiring digest forces review independently of Feature compilation" do
    path = Path.expand("../../../lib/arbor/orchestrator/application.ex", __DIR__)

    assert Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower) ==
             @application_sha256
  end

  test "all13 fixed children match real producer maps with exact keys, args and order" do
    actual = children(snapshot())
    assert length(actual) == 13
    assert actual == fixed_specs([])
    assert Enum.all?(actual, &is_map/1)
    assert Enum.sort(Map.keys(Enum.at(actual, 0))) == [:id, :restart, :start, :type]
    assert Enum.sort(Map.keys(Enum.at(actual, 1))) == [:id, :start]
    assert Enum.sort(Map.keys(Enum.at(actual, 5))) == [:id, :restart, :shutdown, :start, :type]
    assert Enum.all?(actual, &(not Map.has_key?(&1, :modules)))
  end

  test "raw nil and empty checkpoint config keep normalization differences and real child spec" do
    assert {:ok, nil_opts} = Config.fetch_engine_checkpoints(nil)
    assert {:ok, empty_opts} = Config.fetch_engine_checkpoints([])
    refute Keyword.has_key?(nil_opts[:store_child_opts], :name)
    assert empty_opts[:store_child_opts][:name] == :arbor_orchestrator_checkpoints

    expected =
      [
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           [name: :arbor_orchestrator_checkpoints, collection: "orchestrator_checkpoints"]},
          []
        )
      ] ++
        fixed_specs([])

    for raw <- [nil, []] do
      actual =
        children(%{
          snapshot()
          | engine_checkpoints: raw,
            checkpoint_store_admission: :start_link_exported
        })

      assert length(actual) == 14
      assert actual == expected
    end
  end

  test "journal then checkpoint precede fixed children and retain distinct name rules" do
    journal = [
      backend: Arbor.Persistence.BufferedStore,
      store_name: :journal_target,
      store_child_opts: [name: :journal_supplied_name, collection: "journal"]
    ]

    checkpoints = [store_name: :checkpoint_target, store_child_opts: [collection: "checkpoint"]]

    actual =
      children(%{
        snapshot()
        | run_journal: journal,
          journal_store_admission: :start_link_exported,
          engine_checkpoints: checkpoints,
          checkpoint_store_admission: :start_link_exported
      })

    expected =
      [
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           [name: :journal_supplied_name, collection: "journal"]},
          []
        ),
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore, [name: :checkpoint_target, collection: "checkpoint"]},
          []
        )
      ] ++ fixed_specs(journal)

    assert actual == expected
    assert length(actual) == 15
    # Duplicate IDs are current producer behavior, not silently repaired here.
    assert Enum.at(actual, 0).id == Enum.at(actual, 1).id
  end

  test "journal omitted and externally managed branches never probe an unknown producer" do
    backend = :"Elixir.Arbor.Orchestrator.FeatureJournalMustRemainUnloaded"
    assert :code.is_loaded(backend) == false

    for {opts, fact} <- [
          {[], :not_requested},
          {[backend: backend, start_store: false], :not_requested},
          {[backend: backend], :start_link_not_exported}
        ] do
      assert children(%{snapshot() | run_journal: opts, journal_store_admission: fact}) ==
               fixed_specs(opts)
    end

    assert :code.is_loaded(backend) == false
  end

  test "explicit file-only and managed checkpoint branches do not load configured store" do
    store = :"Elixir.Arbor.Orchestrator.FeatureCheckpointMustRemainUnloaded"
    assert :code.is_loaded(store) == false

    for raw <- [[store: nil], [store: store, start_store: false]] do
      assert children(%{snapshot() | engine_checkpoints: raw}) == fixed_specs([])
    end

    assert :code.is_loaded(store) == false
    # Historical validation accepts nil because store_name is an atom; the raw
    # producer map is described without strengthening runtime admission rules.
    actual =
      children(%{
        snapshot()
        | engine_checkpoints: [store_name: nil],
          checkpoint_store_admission: :start_link_exported
      })

    assert elem(hd(actual).start, 2) == [[name: nil, collection: "orchestrator_checkpoints"]]
  end

  test "explicit Config errors precede construction and remain fixed-redacted by Feature" do
    for {raw, expected} <- [
          {"private-input-canary", :not_keyword},
          {[store: "bad", store_name: "bad"], :store_not_atom_or_nil},
          {[store_name: "bad", store_opts: %{}], :store_name_not_atom},
          {[store_opts: %{}, start_store: "yes"], :store_opts_not_keyword},
          {[start_store: "yes", store_child_opts: %{}], :start_store_not_boolean},
          {[store_child_opts: %{}, durability_class: :bad], :store_child_opts_not_keyword},
          {[durability_class: :bad, unknown: true], :invalid_durability_class},
          {[unknown: true, other: true], {:unknown_keys, [:unknown, :other]}},
          {[store_name: :canonical, store_child_opts: [name: :other]],
           {:store_child_name_conflict, :other, :canonical}}
        ] do
      assert Config.fetch_engine_checkpoints(raw) == {:error, expected}
      assert_redacted_failure(%{snapshot() | engine_checkpoints: raw})
    end
  end

  test "unsupported requested producers and incomplete admission never become GenServer guesses" do
    unknown = :"Elixir.Arbor.Orchestrator.FeatureUnknownProducerMustRemainUnloaded"
    assert :code.is_loaded(unknown) == false

    for input <- [
          %{snapshot() | event_log_backend: unknown},
          %{
            snapshot()
            | run_journal: [backend: unknown],
              journal_store_admission: :start_link_exported
          },
          %{
            snapshot()
            | engine_checkpoints: [store: unknown],
              checkpoint_store_admission: :start_link_exported
          },
          %{snapshot() | engine_checkpoints: [], checkpoint_store_admission: :not_requested},
          %{snapshot() | run_journal: [], journal_store_admission: :unobserved},
          %{snapshot() | run_journal: [], journal_store_admission: :start_link_not_exported},
          %{
            snapshot()
            | run_journal: [backend: Arbor.Persistence.BufferedStore, store_child_opts: %{}],
              journal_store_admission: :start_link_exported
          }
        ] do
      assert_redacted_failure(input)
    end

    assert :code.is_loaded(unknown) == false
  end

  test "missing fields, injected plans and malformed direct input fail without inspecting values" do
    for key <- Map.keys(snapshot()) do
      assert_redacted_failure(Map.delete(snapshot(), key))
    end

    for input <- [
          nil,
          [],
          %{},
          %{snapshot() | run_journal: "private-journal-canary"},
          Map.put(snapshot(), :children, [%{start: {__MODULE__, :not_called, []}}])
        ] do
      assert_redacted_failure(input)
    end
  end

  test "compiled full catalog and namespace references equal pure physical producers" do
    actual_actions = apply(@feature, :action_modules, [])
    assert Enum.sort(actual_actions) == Enum.sort(Arbor.Actions.all_actions())
    assert length(actual_actions) == 212
    assert length(Enum.uniq(actual_actions)) == 212
    actual_uris = apply(@feature, :uri_prefixes, [])
    assert actual_uris == Arbor.Actions.capability_uri_prefixes()
    assert actual_uris != []
    assert actual_uris == Enum.sort(Enum.uniq(actual_uris))
    assert Enum.all?(actual_uris, &String.starts_with?(&1, "arbor://action/"))
  end

  test "explicit snapshots do not read or mutate poisoned global config or start children" do
    app = :arbor_orchestrator
    keys = [:engine_checkpoints, :run_journal, :event_log_backend, :event_log_name]
    saved = for key <- keys, into: %{}, do: {key, Application.fetch_env(app, key)}

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(app, key, value)
        {key, :error} -> Application.delete_env(app, key)
      end)
    end)

    Enum.each(keys, &Application.put_env(app, &1, "poisoned global value"))

    names = [
      Arbor.Orchestrator.Supervisor,
      Arbor.Orchestrator.RunJournal,
      Arbor.Orchestrator.Handlers.RegistryAuthority
    ]

    before_pids = Enum.map(names, &Process.whereis/1)
    before_links = Process.info(self(), :links)
    expected = fixed_specs(snapshot().run_journal)
    assert children(snapshot()) == expected
    assert Enum.map(names, &Process.whereis/1) == before_pids
    assert Process.info(self(), :links) == before_links
    assert Enum.all?(keys, &(Application.fetch_env(app, &1) == {:ok, "poisoned global value"}))
  end

  defp children(input) do
    # Prewarm the real Feature outside the callback audit, never a fake consumer.
    Code.ensure_loaded?(@feature)
    # The permitted fixed owner normalizer is setup, never a configured producer.
    Code.ensure_loaded?(Config)
    assert_passive(fn -> apply(@feature, :children, [input]) end)
  end

  defp assert_passive(fun) do
    {outcome, calls} = observe_forbidden_calls(fun)
    assert_no_forbidden_calls(calls)

    case outcome do
      {:returned, result} -> result
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp assert_no_forbidden_calls(calls), do: assert(calls == [])

  defp observe_forbidden_calls(fun) do
    caller = self()
    tracer = spawn(fn -> collect_calls([]) end)

    try do
      Enum.each(@forbidden_calls, fn {module, _function, _arity} ->
        Code.ensure_loaded?(module)
      end)

      Enum.each(@forbidden_calls, fn pattern ->
        assert :erlang.trace_pattern(pattern, true, [:local]) > 0
      end)

      :erlang.trace(caller, true, [:call, :arity, {:tracer, tracer}])

      outcome =
        try do
          {:returned, fun.()}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      :erlang.trace(caller, false, [:call, :arity])
      marker = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^marker}, 1_000
      send(tracer, {:collected, caller})
      assert_receive {:feature_calls, ^tracer, calls}, 1_000
      {outcome, calls}
    after
      :erlang.trace(caller, false, [:call, :arity])
      Enum.each(@forbidden_calls, &:erlang.trace_pattern(&1, false, [:local]))
      Process.exit(tracer, :kill)
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _pid, :call, {module, function, arity}} when is_integer(arity) ->
        collect_calls([{module, function, arity} | calls])

      {:collected, caller} ->
        send(caller, {:feature_calls, self(), Enum.reverse(calls)})
    end
  end

  defp assert_redacted_failure(input) do
    error = assert_raise ArgumentError, fn -> children(input) end
    assert Exception.message(error) == @invalid
  end

  defp snapshot do
    %{
      event_log_backend: Arbor.Persistence.EventLog.ETS,
      event_log_name: :orchestrator_events,
      run_journal: [],
      journal_store_admission: :not_requested,
      engine_checkpoints: [store: nil],
      checkpoint_store_admission: :not_requested
    }
  end

  # Independent actual producers, executed only by isolated owning tests. These
  # are constructor calls; no child start MFA or registration API is invoked.
  defp fixed_specs(journal_opts) do
    raw = [
      Arbor.Common.handler_registry_child_spec(
        core_registration_authority:
          Arbor.Orchestrator.Handlers.RegistryAuthority.authority_config()
      ),
      Arbor.Orchestrator.Handlers.RegistryAuthority,
      {Arbor.Persistence.EventLog.ETS, name: :orchestrator_events},
      {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry},
      Arbor.Orchestrator.SignalsBridge,
      {Arbor.Orchestrator.RunJournal, journal_opts},
      Arbor.Orchestrator.JobRegistry,
      Arbor.Orchestrator.DotCache,
      {DynamicSupervisor, name: Arbor.Orchestrator.PipelineSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Arbor.Orchestrator.SessionRegistry},
      Arbor.Orchestrator.Session.Supervisor,
      Arbor.Orchestrator.Session.TaskSupervisor,
      Arbor.Orchestrator.RecoveryCoordinator
    ]

    Enum.map(raw, &Supervisor.child_spec(&1, []))
  end
end
