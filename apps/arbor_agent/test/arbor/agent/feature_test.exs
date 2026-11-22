defmodule Arbor.Agent.FeatureTest do
  use ExUnit.Case, async: false

  @feature Arbor.Agent.Feature
  @invalid "invalid or incomplete agent feature snapshot"
  @application_sha256 "528dbd2dc0911dea311f625668f50f0d40ab782e2f1e65e2210bb6cbe8394fd9"

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
    missing = :"Elixir.Arbor.Agent.FeatureLoaderGuardPositiveControlMustRemainUnloaded"
    assert :code.is_loaded(missing) == false

    {outcome, calls} = observe_forbidden_calls(fn -> Code.ensure_loaded?(missing) end)
    assert outcome == {:returned, false}
    assert {Code, :ensure_loaded?, 1} in calls
    assert_raise ExUnit.AssertionError, fn -> assert_no_forbidden_calls(calls) end
    assert :code.is_loaded(missing) == false
  end

  test "real Agent declaration, static metadata and scoped contribution semantics" do
    assert apply(@feature, :id, []) == :agent
    assert apply(@feature, :requires, []) == [:core]
    assert apply(@feature, :action_modules, []) == []
    assert apply(@feature, :uri_prefixes, []) == []
    assert apply(@feature, :health, []) == %{status: :unobserved}
    assert Arbor.Contracts.Feature in apply(@feature, :module_info, [:attributes])[:behaviour]

    for callback <- [:graphs, :commands, :routes] do
      refute function_exported?(@feature, callback, 0)
    end

    assert Application.fetch_env!(:arbor_agent, :arbor_feature) == @feature
    metadata = Application.fetch_env!(:arbor_agent, :arbor_feature_metadata)
    assert metadata.id == :agent
    assert metadata.requires == [:core]
    assert metadata.dependency_role == :fixed_host_prerequisite
    assert metadata.contribution_scope == :direct_application_entrypoint
    assert metadata.snapshot_required_keys == [:start_children]

    assert metadata.snapshot_conditional_required_keys.start_children[true] ==
             [
               :profile_backend,
               :user_config_backend,
               :recovery_backend,
               :recovery_durability,
               :reconciliation_backend,
               :reconciliation_durability,
               :system_lifecycle_token
             ]

    assert metadata.snapshot_conditional_required_keys.start_children[false] == []
    expected_ids = Enum.map(expected_specs(fixture(make_ref()), :backend), & &1.id)
    assert Enum.sort(metadata.public_child_ids) == Enum.sort(expected_ids)
    assert metadata.sources.action_catalog == :no_additional_direct_global_contribution_declared
    assert metadata.sources.uri_provider == :no_additional_direct_global_contribution_declared
  end

  test "Application wiring digest forces a separate descriptor review on startup drift" do
    path = Path.expand("../../../lib/arbor/agent/application.ex", __DIR__)

    assert Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower) ==
             @application_sha256
  end

  test "disabled children require no fabricated backend, durability or private facts" do
    alias_before = Application.fetch_env(:arbor_capabilities, :identity_alias_resolver)
    links_before = Process.info(self(), :links)
    assert children(%{start_children: false}) == []
    assert Application.fetch_env(:arbor_capabilities, :identity_alias_resolver) == alias_before
    assert Process.info(self(), :links) == links_before
  end

  test "all27 real producer maps match independently maintained startup fixtures" do
    for {profile_backend, user_backend, expected_ack} <- [
          {Arbor.Persistence.QueryableStore.Postgres, nil, :backend},
          {nil, Arbor.Persistence.QueryableStore.Postgres, :cache}
        ] do
      snapshot =
        fixture(make_ref())
        |> Map.put(:profile_backend, profile_backend)
        |> Map.put(:user_config_backend, user_backend)

      actual = children(snapshot)
      assert length(actual) == 27
      assert actual == expected_specs(snapshot, expected_ack)

      assert Enum.at(actual, 0) == %{
               id: :arbor_agents_pg,
               start: {:pg, :start_link, [:arbor_agents]}
             }

      assert Enum.all?(actual, &is_map/1)
      assert Enum.all?(actual, &(not Map.has_key?(&1, :modules)))
    end
  end

  test "one supplied real reference is retained identically in all three lifecycle args" do
    first = make_ref()
    second = make_ref()
    first_specs = children(fixture(first))
    second_specs = children(fixture(second))
    assert Enum.take(first_specs, 24) == Enum.take(second_specs, 24)

    for {spec, module} <-
          Enum.zip(
            Enum.drop(first_specs, 24),
            [Arbor.Agent.SystemLifecycleAuthority, Arbor.Agent.Bootstrap, Arbor.Agent.Reconciler]
          ) do
      assert spec == %{
               id: module,
               start: {module, :start_link, [[system_lifecycle_token: first]]}
             }

      {^module, :start_link, [opts]} = spec.start
      assert Keyword.fetch!(opts, :system_lifecycle_token) === first
    end
  end

  test "four store IDs, exact argument wrapping and acknowledgement omissions are retained" do
    snapshot = fixture(make_ref()) |> Map.put(:profile_backend, nil)
    specs = children(snapshot)

    stores =
      Enum.filter(specs, fn spec -> elem(spec.start, 0) == Arbor.Persistence.BufferedStore end)

    assert Enum.map(stores, & &1.id) ==
             [
               :arbor_agent_profiles,
               :arbor_user_config,
               :arbor_agent_task_control_recovery,
               :arbor_agent_template_authority_reconciliation
             ]

    assert Enum.all?(stores, &(Enum.sort(Map.keys(&1)) == [:id, :start]))
    {_, :start_link, [profile_opts]} = Enum.at(stores, 0).start
    {_, :start_link, [user_opts]} = Enum.at(stores, 1).start
    {_, :start_link, [recovery_opts]} = Enum.at(stores, 2).start
    {_, :start_link, [reconciliation_opts]} = Enum.at(stores, 3).start
    assert profile_opts[:ack_mode] == :cache
    refute Keyword.has_key?(user_opts, :ack_mode)
    assert recovery_opts[:ack_mode] == :backend
    assert reconciliation_opts[:ack_mode] == :backend
    assert recovery_opts[:backend] == snapshot.recovery_backend
    assert reconciliation_opts[:backend] == snapshot.reconciliation_backend
  end

  test "durability observations remain separate and invalid facts never become empty success" do
    base = fixture(make_ref())

    for field <- [:recovery_durability, :reconciliation_durability],
        value <- [:unobserved, :volatile, :process_lifetime, :application_restart, nil] do
      assert_redacted_failure(Map.put(base, field, value))
    end

    for field <- [:recovery_backend, :reconciliation_backend] do
      assert_redacted_failure(Map.put(base, field, nil))
    end
  end

  test "missing keys, malformed snapshots, injected plans and invalid tokens fail redacted" do
    base = fixture(make_ref())

    for key <- Map.keys(base) do
      assert_redacted_failure(Map.delete(base, key))
    end

    for input <- [
          nil,
          [],
          %{},
          %{start_children: nil},
          Map.put(base, :children, [%{start: {__MODULE__, :not_called, []}}]),
          Map.put(base, :profile_backend, "private-backend-canary"),
          Map.put(base, :user_config_backend, %{}),
          Map.put(base, :system_lifecycle_token, :placeholder),
          Map.put(base, :system_lifecycle_token, "private-reference-canary"),
          %{start_children: false, system_lifecycle_token: make_ref()}
        ] do
      assert_redacted_failure(input)
    end
  end

  test "explicit snapshots ignore poisoned environment and never load a profile backend" do
    app = :arbor_agent

    keys = [
      :start_children,
      :profile_storage_backend,
      :task_control_recovery_backend,
      :template_authority_reconciliation_backend
    ]

    saved = for key <- keys, into: %{}, do: {key, Application.fetch_env(app, key)}

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(app, key, value)
        {key, :error} -> Application.delete_env(app, key)
      end)
    end)

    Enum.each(keys, &Application.put_env(app, &1, "poisoned global value"))
    backend = :"Elixir.Arbor.Agent.FeatureProfileBackendMustRemainUnloaded"
    assert :code.is_loaded(backend) == false
    alias_before = Application.fetch_env(:arbor_capabilities, :identity_alias_resolver)
    links_before = Process.info(self(), :links)
    snapshot = fixture(make_ref()) |> Map.put(:profile_backend, backend)
    assert children(snapshot) == expected_specs(snapshot, :backend)
    assert :code.is_loaded(backend) == false
    assert Application.fetch_env(:arbor_capabilities, :identity_alias_resolver) == alias_before
    assert Process.info(self(), :links) == links_before
    assert Enum.all?(keys, &(Application.fetch_env(app, &1) == {:ok, "poisoned global value"}))
  end

  defp children(input) do
    # Prewarm the real Feature outside the callback audit, never a fake consumer.
    Code.ensure_loaded?(@feature)
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

  defp fixture(token) do
    %{
      start_children: true,
      profile_backend: Arbor.Persistence.QueryableStore.Postgres,
      user_config_backend: Arbor.Persistence.QueryableStore.Postgres,
      recovery_backend: Arbor.Persistence.QueryableStore.Postgres,
      recovery_durability: :node_restart,
      reconciliation_backend: Arbor.Persistence.QueryableStore.Postgres,
      reconciliation_durability: :node_restart,
      system_lifecycle_token: token
    }
  end

  # These real producers are evaluated only in the isolated owning test lane.
  # No child start MFA or backend attestation is invoked. The supplied facts and
  # reference are test-owned comparison inputs, not observed production authority.
  defp expected_specs(snapshot, expected_profile_ack) do
    raw = [
      {%{id: :arbor_agents_pg, start: {:pg, :start_link, [:arbor_agents]}}, []},
      {{Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry}, []},
      {{Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry}, []},
      {{Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry}, []},
      {{Registry, keys: :unique, name: Arbor.Agent.ActionCycleRegistry}, []},
      {{Registry, keys: :unique, name: Arbor.Agent.MaintenanceRegistry}, []},
      {{Registry, keys: :unique, name: Arbor.Agent.RuntimeAdmissionRegistry}, []},
      {Arbor.Agent.RuntimeAdmission.Supervisor, []},
      {{Arbor.Persistence.BufferedStore,
        name: :arbor_agent_profiles,
        backend: snapshot.profile_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        ack_mode: expected_profile_ack,
        collection: "agent_profiles"}, [id: :arbor_agent_profiles]},
      {Arbor.Agent.ProfileAuthorityOwner, []},
      {{Arbor.Persistence.BufferedStore,
        name: :arbor_user_config,
        backend: snapshot.user_config_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        collection: "user_config"}, [id: :arbor_user_config]},
      {Arbor.Agent.Registry, []},
      {Arbor.Agent.SummaryCache, []},
      {Arbor.Agent.Fitness, []},
      {Arbor.Agent.SessionManager, []},
      {{Task.Supervisor, name: Arbor.Agent.Orchestration.TaskSupervisor}, []},
      {{Arbor.Persistence.BufferedStore,
        name: :arbor_agent_task_control_recovery,
        backend: snapshot.recovery_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "task_control_recovery"}, [id: :arbor_agent_task_control_recovery]},
      {{Arbor.Persistence.BufferedStore,
        name: :arbor_agent_template_authority_reconciliation,
        backend: snapshot.reconciliation_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "template_authority_reconciliation"},
       [id: :arbor_agent_template_authority_reconciliation]},
      {Arbor.Agent.Orchestration.TaskStore, []},
      {Arbor.Agent.Orchestration.LeaseGrantOwner, []},
      {Arbor.Agent.ActionCycleSupervisor, []},
      {Arbor.Agent.MaintenanceSupervisor, []},
      {Arbor.Agent.Supervisor, []},
      {Arbor.Agent.UserSupervisor, []},
      {{Arbor.Agent.SystemLifecycleAuthority,
        system_lifecycle_token: snapshot.system_lifecycle_token}, []},
      {{Arbor.Agent.Bootstrap, system_lifecycle_token: snapshot.system_lifecycle_token}, []},
      {{Arbor.Agent.Reconciler, system_lifecycle_token: snapshot.system_lifecycle_token}, []}
    ]

    Enum.map(raw, fn {spec, overrides} -> Supervisor.child_spec(spec, overrides) end)
  end
end
