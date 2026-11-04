defmodule Arbor.KernelRuntime.FeatureReportTest do
  use ExUnit.Case, async: false

  alias Arbor.KernelRuntime.FeatureReport

  @app :arbor_feature_report_test_fixture
  @fixture Module.concat(__MODULE__, Declaration)
  @loader_positive_control :"Elixir.Arbor.KernelRuntime.FeatureReportLoaderPositiveControlMustRemainUnloaded"
  @loader_calls [
    {Code, :ensure_loaded, 1},
    {Code, :ensure_loaded?, 1},
    {:code, :ensure_loaded, 1}
  ]

  setup do
    on_exit(fn ->
      Application.unload(@app)
      :code.purge(@fixture)
      :code.delete(@fixture)
    end)

    :ok
  end

  test "unloaded declarations remain metadata without callback invocation or loading" do
    fixture()
    :code.purge(@fixture)
    :code.delete(@fixture)
    assert :code.is_loaded(@fixture) == false

    report = assert_no_loader_calls(fn -> feature(%{}) end)
    assert report.state == :declared_module_unloaded
    assert report.callback_data == :unresolved
    assert :code.is_loaded(@fixture) == false
    refute_received :feature_children_called
  end

  test "a configured module must belong to the loaded application's module list" do
    fixture(%{}, FeatureReport)
    report = feature(%{})
    assert report.state == :declaration_ownership_mismatch
    assert report.callback_data == :unresolved
    refute_received :feature_children_called
  end

  test "missing conditional facts remain unresolved before calling children" do
    fixture()
    report = feature(%{enabled: true, observer: self()})
    assert report.children.state == :snapshot_unresolved
    refute_received :feature_children_called
  end

  test "a complete disabled branch needs no invented private facts" do
    fixture()
    report = feature(%{enabled: false, observer: self()})
    assert report.children.state == :declaration_read
    assert report.children.specifications == []
    assert_received :feature_children_called
    assert report.children.identity_match == :unobserved
    assert report.health == %{state: :declared, status: :unobserved, measured_here: false}
  end

  test "public projection drops start arguments, private values and unknown identities" do
    fixture()
    private = make_ref()
    secret_id = {:private_identity, private}
    report = feature(%{enabled: true, observer: self(), private: private, child_id: secret_id})

    assert report.children.state == :declaration_read

    assert [%{id: :redacted, provided_fields: [:id, :start, :shutdown]}] =
             report.children.specifications

    refute contains_private_term?(report)
    refute inspect(report) =~ "private constructor value"
    refute Map.has_key?(hd(report.children.specifications), :start)
    refute Map.has_key?(hd(report.children.specifications), :shutdown)
  end

  test "known public identities support a separately supplied identity mismatch report" do
    fixture()
    snapshot = %{enabled: true, observer: self(), private: make_ref(), child_id: :public_child}
    report = feature(snapshot, %{@app => %{child_ids: [:different_child]}})

    assert [%{id: :public_child}] = report.children.specifications
    assert report.children.identity_match == false
    assert :child_identity_mismatch in report.mismatches
    assert report.children.private_arguments_compared == false
  end

  test "an observation match does not claim startup or private argument equality" do
    fixture()
    snapshot = %{enabled: true, observer: self(), private: make_ref(), child_id: :public_child}
    report = feature(snapshot, %{@app => %{child_ids: [:public_child]}})

    assert report.children.identity_match == true
    assert report.children.private_arguments_compared == false
    whole = apply(FeatureReport, :inspect_loaded, [%{@app => snapshot}])
    assert whole.runtime_or_startup_admission_credit == false
  end

  test "a callback exception never exports its private message or input" do
    fixture()

    report =
      feature(%{
        enabled: true,
        observer: self(),
        private: make_ref(),
        child_id: :public_child,
        raise_private_error: true
      })

    assert report.children.state == :snapshot_unresolved
    refute inspect(report) =~ "private constructor value"
    refute contains_private_term?(report)
  end

  test "optional callbacks stay undeclared instead of becoming verified empty lists" do
    fixture()
    report = feature(%{enabled: false, observer: self()})
    assert report.contributions.action_modules == %{state: :declared, count: 0}
    assert report.contributions.uri_prefixes == %{state: :declared, count: 0}
    assert report.contributions.graphs == %{state: :undeclared}
    assert report.contributions.routes == %{state: :undeclared}
    assert report.contributions.commands == %{state: :undeclared}
  end

  test "missing snapshot schema is invalid metadata and never invokes callbacks" do
    fixture(%{snapshot_required_keys: :invalid})
    report = feature(%{enabled: false, observer: self()})
    assert report.state == :invalid_declaration_metadata
    refute_received :feature_children_called
  end

  test "metadata disagreements are reported without changing runtime selection" do
    fixture(%{id: :declared_fixture, requires: [:core]})
    report = feature(%{enabled: false, observer: self()})
    assert report.id == :declared_fixture
    assert :id_mismatch in report.mismatches
    assert :requires_mismatch in report.mismatches
    assert report.dependency_role == :fixed_host_prerequisite
    assert report.contribution_scope == :direct_application_entrypoint
  end

  test "missing conditional discriminator is unresolved even outside the base required list" do
    fixture(%{snapshot_required_keys: [:observer]})
    report = feature(%{observer: self()})
    assert report.children.state == :snapshot_unresolved
    refute_received :feature_children_called
    refute contains_private_term?(report)
  end

  test "the whole conditional schema is validated including unused branches" do
    invalid_conditions = [
      %{nil => %{true => []}},
      %{true => %{true => []}},
      %{enabled: []},
      %{enabled: %{true => [:private, :child_id], false => :not_a_list}},
      %{enabled: %{true => [:private, :child_id], false => [make_ref()]}},
      %{enabled: %{true => [:private, :child_id], false => [nil]}},
      %{enabled: %{make_ref() => []}},
      %{enabled: %{[true] => []}}
    ]

    for conditions <- invalid_conditions do
      fixture(%{snapshot_conditional_required_keys: conditions})

      report =
        feature(%{enabled: true, observer: self(), private: make_ref(), child_id: :public_child})

      assert report.state == :invalid_declaration_metadata
      refute_received :feature_children_called
      refute contains_private_term?(report)
    end
  end

  test "unknown or non-scalar conditional facts refuse children before invocation" do
    fixture()

    for value <- [:unknown, make_ref(), self(), fn -> :private end, %{}, [true], {true}] do
      report =
        feature(%{enabled: value, observer: self(), private: make_ref(), child_id: :public_child})

      assert report.children.state == :snapshot_unresolved
      refute_received :feature_children_called
      refute contains_private_term?(report)
    end
  end

  test "actual source-role metadata spellings survive while private values and paths are dropped" do
    sources = %{
      application: Arbor.Orchestrator.Application,
      physical_catalog_owner: :arbor_actions,
      catalog_producer: Arbor.Actions,
      registering_actor: Arbor.Orchestrator.Registrar,
      action_catalog_scope: :full_registration_catalog,
      uri_role: :nonexclusive_action_catalog_namespace_reference,
      uri_registration_actor: Arbor.Actions.Application,
      uri_registration_status: :unobserved,
      action_catalog: :no_additional_direct_global_contribution_declared,
      uri_provider: :no_additional_direct_global_contribution_declared,
      direct_global_action_catalog: :none_declared_here,
      direct_global_uri_provider: :none_declared_here,
      observation: :unobserved,
      routes: %{owner: Arbor.Dashboard.Router, coverage: :top_level_mounts},
      ranch_constructor: %{physical_owner: :ranch, source: "private constructor path"},
      coverage: :direct_entrypoint,
      scope: "private source-role value",
      module: fn -> :private end,
      private: make_ref(),
      path: "private source path",
      sha256: "private source hash",
      startup_effects: [:not_exported_as_a_list]
    }

    fixture(%{sources: sources})
    report = feature(%{enabled: false, observer: self()})

    for key <- [
          :application,
          :physical_catalog_owner,
          :catalog_producer,
          :registering_actor,
          :action_catalog_scope,
          :uri_role,
          :uri_registration_actor,
          :uri_registration_status,
          :action_catalog,
          :uri_provider,
          :direct_global_action_catalog,
          :direct_global_uri_provider,
          :observation,
          :routes,
          :coverage
        ] do
      assert report.sources[key] == sources[key]
    end

    for key <- [:scope, :module, :private, :path, :sha256, :startup_effects] do
      refute Map.has_key?(report.sources, key)
    end

    refute contains_private_term?(report)
    refute inspect(report) =~ "private source"
    assert report.sources.ranch_constructor == %{physical_owner: :ranch}
    refute inspect(report) =~ "private constructor path"
  end

  test "supplied malformed observations are explicitly invalid rather than unobserved" do
    fixture()
    snapshot = %{enabled: true, observer: self(), private: make_ref(), child_id: :public_child}

    for observation <- [
          nil,
          :invalid,
          [],
          %{child_ids: "private observation"},
          %{child_ids: make_ref()},
          %{child_ids: fn -> :private end}
        ] do
      report = feature(snapshot, %{@app => observation})
      assert report.children.identity_match == :invalid_observation
      assert report.children.private_arguments_compared == false
      refute contains_private_term?(report)
      refute inspect(report) =~ "private observation"
    end

    assert feature(snapshot).children.identity_match == :unobserved
  end

  test "child identity observations are multisets with duplicate counts and no argument proof" do
    fixture(%{public_child_ids: [:public_child, :second_child]})

    snapshot = %{
      enabled: true,
      observer: self(),
      private: make_ref(),
      child_id: :public_child,
      child_ids: [:public_child, :second_child]
    }

    reordered = feature(snapshot, %{@app => %{child_ids: [:second_child, :public_child]}})
    assert reordered.children.identity_match == true
    assert reordered.children.private_arguments_compared == false

    extra =
      feature(snapshot, %{@app => %{child_ids: [:public_child, :public_child, :second_child]}})

    assert extra.children.identity_match == false

    duplicated = Map.put(snapshot, :child_ids, [:public_child, :second_child, :public_child])

    report =
      feature(duplicated, %{@app => %{child_ids: [:public_child, :public_child, :second_child]}})

    assert report.children.identity_match == true
    assert report.children.duplicate_declared_ids == true
    assert :duplicate_declared_child_ids in report.mismatches
    assert report.children.private_arguments_compared == false
  end

  test "malformed provided optional spec values are refused without exporting their values" do
    fixture()
    snapshot = %{enabled: true, observer: self(), private: make_ref(), child_id: :public_child}

    for fields <- [
          %{restart: :invalid},
          %{restart: fn -> :private end},
          %{shutdown: -1},
          %{shutdown: make_ref()},
          %{shutdown: "private shutdown"},
          %{type: :invalid},
          %{type: self()},
          %{modules: :invalid},
          %{modules: [make_ref()]},
          %{significant: :invalid},
          %{significant: self()}
        ] do
      report = feature(Map.put(snapshot, :spec_fields, fields))
      assert report.children.state == :snapshot_unresolved
      refute contains_private_term?(report)
      refute inspect(report) =~ "private shutdown"
    end
  end

  test "valid provided optional values remain present without filling omitted defaults" do
    fixture()
    snapshot = %{enabled: true, observer: self(), private: make_ref(), child_id: :public_child}

    for fields <- [
          %{restart: :permanent, shutdown: 0, type: :worker, modules: [], significant: false},
          %{
            restart: :transient,
            shutdown: :infinity,
            type: :supervisor,
            modules: [__MODULE__],
            significant: true
          },
          %{
            restart: :temporary,
            shutdown: :brutal_kill,
            type: :worker,
            modules: :dynamic,
            significant: false
          }
        ] do
      report = feature(Map.put(snapshot, :spec_fields, fields))
      assert report.children.state == :declaration_read

      assert [
               %{
                 id: :public_child,
                 provided_fields: [
                   :id,
                   :start,
                   :restart,
                   :shutdown,
                   :type,
                   :modules,
                   :significant
                 ]
               }
             ] = report.children.specifications

      refute contains_private_term?(report)
    end

    assert [%{provided_fields: [:id, :start, :shutdown]}] =
             feature(snapshot).children.specifications
  end

  test "malformed graphs are refused as contract data without exposing private terms" do
    fixture(%{}, @fixture, "@impl true\ndef graphs, do: [make_ref(), fn -> :private end]")
    report = feature(%{enabled: false, observer: self()})
    assert report.contributions.graphs == %{state: :invalid_declaration_data}
    refute contains_private_term?(report)
  end

  test "declared empty graphs and binary name-path pairs retain their distinct data meaning" do
    for {body, count} <- [{"[]", 0}, {"[{\"named\", \"priv/graph.dot\"}]", 1}] do
      fixture(%{}, @fixture, "@impl true\ndef graphs, do: " <> body)
      report = feature(%{enabled: false, observer: self()})
      assert report.contributions.graphs == %{state: :declared, count: count}
      assert report.contributions.routes == %{state: :undeclared}
    end
  end

  test "graph paths honor Path.t chardata without filesystem admission" do
    for body <- [
          "[{\"named\", ~c\"priv/graph.dot\"}]",
          "[{\"named\", [\"priv/\", [0x03BB], ~c\".dot\"]}]"
        ] do
      fixture(%{}, @fixture, "@impl true\ndef graphs, do: " <> body)
      report = feature(%{enabled: false, observer: self()})
      assert report.contributions.graphs == %{state: :declared, count: 1}
    end

    for body <- ["[{\"named\", [make_ref()]}]", "[{\"named\", [-1]}]", "[{\"named\", [0xD800]}]"] do
      fixture(%{}, @fixture, "@impl true\ndef graphs, do: " <> body)
      report = feature(%{enabled: false, observer: self()})
      assert report.contributions.graphs == %{state: :invalid_declaration_data}
      refute contains_private_term?(report)
    end
  end

  test "the unloaded-declaration guard detects an attempted failed loader" do
    fixture()
    :code.purge(@fixture)
    :code.delete(@fixture)

    for target <- [@fixture, @loader_positive_control], loader <- @loader_calls do
      {module, function, 1} = loader
      assert :code.is_loaded(target) == false
      {outcome, calls} = observe_loader_calls(fn -> apply(module, function, [target]) end)

      case loader do
        {Code, :ensure_loaded?, 1} -> assert outcome == {:returned, false}
        _ -> assert {:returned, {:error, _reason}} = outcome
      end

      assert loader in calls
      assert_raise ExUnit.AssertionError, fn -> assert(calls == []) end
      assert :code.is_loaded(target) == false
    end
  end

  defp assert_no_loader_calls(fun) do
    {outcome, calls} = observe_loader_calls(fun)
    assert calls == []

    case outcome do
      {:returned, result} -> result
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  # Bounded fixed-declaration/control loader guard; only MFA/arity reaches
  # the tracer. It does not classify unrelated loads or prove VM provenance.
  defp observe_loader_calls(fun) do
    caller = self()
    tracer = spawn(fn -> collect_loader_calls([]) end)
    match_spec = [{[@fixture], [], [true]}, {[@loader_positive_control], [], [true]}]

    try do
      Enum.each(@loader_calls, fn {module, _function, _arity} -> Code.ensure_loaded?(module) end)

      Enum.each(@loader_calls, fn pattern ->
        assert :erlang.trace_pattern(pattern, match_spec, [:local]) > 0
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
      assert_receive {:feature_loader_calls, ^tracer, calls}, 1_000
      {outcome, calls}
    after
      :erlang.trace(caller, false, [:call, :arity])
      Enum.each(@loader_calls, &:erlang.trace_pattern(&1, false, [:local]))
      Process.exit(tracer, :kill)
    end
  end

  defp collect_loader_calls(calls) do
    receive do
      {:trace, _pid, :call, {module, function, arity}} when is_integer(arity) ->
        collect_loader_calls([{module, function, arity} | calls])

      {:collected, caller} ->
        send(caller, {:feature_loader_calls, self(), Enum.reverse(calls)})
    end
  end

  defp fixture(overrides \\ %{}, declaration \\ @fixture, extra_callbacks \\ "") do
    apply(FeatureReport, :inspect_loaded, [%{}])
    Application.unload(@app)
    :code.purge(@fixture)
    :code.delete(@fixture)

    Code.compile_string("""
    defmodule #{inspect(@fixture)} do
      @behaviour Arbor.Contracts.Feature
      @impl true
      def id, do: :fixture
      @impl true
      def requires, do: []
      @impl true
      def action_modules, do: []
      @impl true
      def uri_prefixes, do: []
      @impl true
      def health, do: %{status: :unobserved, private: make_ref()}
      @impl true
      def children(snapshot) do
        send(Map.fetch!(snapshot, :observer), :feature_children_called)
        if snapshot[:raise_private_error], do: raise(ArgumentError, "private constructor value")
        if snapshot.enabled do
          ids = Map.get(snapshot, :child_ids, [snapshot.child_id])
          Enum.map(ids, fn id ->
            Map.merge(
              %{id: id,
                start: {__MODULE__, :start_link, [[private: snapshot.private, password: "private constructor value"]]},
                shutdown: 5000},
              Map.get(snapshot, :spec_fields, %{})
            )
          end)
        else
          []
        end
      end
      #{extra_callbacks}
    end
    """)

    metadata =
      Map.merge(
        %{
          id: :fixture,
          requires: [],
          dependency_role: :fixed_host_prerequisite,
          contribution_scope: :direct_application_entrypoint,
          public_child_ids: [:public_child],
          snapshot_required_keys: [:enabled, :observer],
          snapshot_conditional_required_keys: %{
            enabled: %{true => [:private, :child_id], false => []}
          },
          sources: %{uri_prefixes: %{kind: :nonexclusive_action_catalog_namespace_reference}}
        },
        overrides
      )

    :ok =
      :application.load(
        {:application, @app,
         [
           description: ~c"Owned FeatureReport test fixture",
           vsn: ~c"0",
           modules: [@fixture],
           applications: [:kernel, :stdlib],
           env: [arbor_feature: declaration, arbor_feature_metadata: metadata]
         ]}
      )
  end

  defp feature(snapshot, observations \\ %{}) do
    apply(FeatureReport, :inspect_loaded, [%{@app => snapshot}, observations])
    |> Map.fetch!(:features)
    |> Enum.find(&(&1.app == @app))
  end

  defp contains_private_term?(term) when is_reference(term) or is_pid(term) or is_function(term),
    do: true

  defp contains_private_term?(term) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} ->
        contains_private_term?(key) or contains_private_term?(value)
      end)

  defp contains_private_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_private_term?/1)

  defp contains_private_term?(term) when is_list(term),
    do: Enum.any?(term, &contains_private_term?/1)

  defp contains_private_term?(_), do: false
end
