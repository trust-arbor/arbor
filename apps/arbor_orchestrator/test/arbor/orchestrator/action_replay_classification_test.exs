defmodule Arbor.Orchestrator.ActionReplayClassificationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.TestFixtures.{
    ReplayContradictoryWriteAction,
    ReplayDefaultAction,
    ReplayDriftOriginalAction,
    ReplayDriftReplacementAction,
    ReplayIdempotentAction,
    ReplayReadOnlyAction
  }

  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.{ContentHash, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.{ExecHandler, ExtractHandler, Handler}
  alias Arbor.Orchestrator.IR.Compiler
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal

  alias Arbor.Orchestrator.TestFixtures.{
    ReplayActionsExecutor,
    ReplayRevocableCapabilitySecurity
  }

  @fixture_bindings %{
    "test_replay_contradictory_write" => ReplayContradictoryWriteAction,
    "test_replay_default" => ReplayDefaultAction,
    "test_replay_drift" => ReplayDriftOriginalAction,
    "test_replay_idempotent" => ReplayIdempotentAction,
    "test_replay_read_only" => ReplayReadOnlyAction
  }

  setup do
    ensure_action_registry_started!()
    snapshot = ActionRegistry.snapshot()
    install_fixture_bindings!(@fixture_bindings)

    previous_pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid)
    previous_hook = Application.get_env(:arbor_orchestrator, :action_replay_drift_hook)
    previous_security = Application.get_env(:arbor_orchestrator, :security_module)

    previous_security_available =
      Application.get_env(:arbor_orchestrator, :security_available_override)

    previous_capability_counter =
      Application.get_env(:arbor_orchestrator, :replay_capability_counter)

    Application.put_env(:arbor_orchestrator, :action_replay_test_pid, self())
    Application.delete_env(:arbor_orchestrator, :action_replay_drift_hook)
    Application.delete_env(:arbor_orchestrator, :replay_capability_counter)

    on_exit(fn ->
      if Process.whereis(ActionRegistry), do: ActionRegistry.restore(snapshot)
      restore_env(:action_replay_test_pid, previous_pid)
      restore_env(:action_replay_drift_hook, previous_hook)
      restore_env(:security_module, previous_security)
      restore_env(:security_available_override, previous_security_available)
      restore_env(:replay_capability_counter, previous_capability_counter)
    end)

    :ok
  end

  test "IR enrichment uses trusted action declarations and ignores DOT idempotency attrs" do
    read_only = compiled_graph!(action_dot("test_replay_read_only"))
    assert read_only.nodes["task"].idempotency == :read_only
    assert_receive :replay_read_only_classified

    default =
      compiled_graph!(
        action_dot("test_replay_default", ~s(idempotency="read_only", replay="idempotent"))
      )

    assert default.nodes["task"].idempotency == :side_effecting

    unresolved = compiled_graph!(action_dot("test_replay_missing"))
    assert unresolved.nodes["task"].idempotency == :side_effecting
  end

  test "tool, shell, function, and unknown exec targets remain side_effecting" do
    assert Handler.idempotency_of(ExecHandler) == :side_effecting

    for attrs <- [
          %{"target" => "tool"},
          %{"target" => "shell"},
          %{"target" => "function"},
          %{"target" => "unknown"},
          %{"target" => "action"},
          %{"target" => "action", "action" => "test_replay_missing"}
        ] do
      node = %Arbor.Orchestrator.Graph.Node{id: "task", attrs: attrs}
      assert Handler.idempotency_of(ExecHandler, node) == :side_effecting
    end
  end

  test "security regression: read-only actions are replayable but never content-hash skipped" do
    graph = compiled_graph!(action_dot("test_replay_read_only"))
    node = graph.nodes["task"]

    assert {:ok, %{idempotency: :read_only, binding: binding}} =
             Handler.execution_classification(ExecHandler, node, [])

    assert binding.action_module == ReplayReadOnlyAction

    refute ContentHash.can_skip?(
             node,
             "same",
             "same",
             :read_only,
             %Outcome{status: :success}
           )
  end

  test "security regression: contradictory action declarations fail before effect preparation" do
    journal = start_isolated_journal("action_replay_contradiction")
    jopts = [server: journal.name]
    graph = compiled_graph!(action_dot("test_replay_contradictory_write"))

    assert graph.nodes["task"].idempotency == :side_effecting

    assert {:error,
            {:execution_classification_failed, "task",
             :execution_idempotency_effect_class_conflict}} =
             Engine.run(graph,
               run_id: journal.run_id,
               logs_root: tmp_logs("action_replay_contradiction"),
               journal_opts: jopts
             )

    record = PipelineStatus.get_record(journal.run_id, jopts)
    assert record.current_effect == nil
    refute_received :replay_contradictory_write_executed
  end

  test "security regression: injected executors and forged IR cannot bypass journaling" do
    journal = start_isolated_journal("action_replay")
    jopts = [server: journal.name]

    read_graph = compiled_graph!(action_dot("test_replay_read_only"))
    assert_receive :replay_read_only_classified

    assert {:ok, _result} =
             Engine.run(read_graph,
               run_id: journal.run_id <> "_read",
               logs_root: tmp_logs("action_replay_read"),
               journal_opts: jopts,
               actions_executor: ReplayActionsExecutor,
               replay_execution_binding: %{
                 executor: ReplayActionsExecutor,
                 action_name: "spoofed_action",
                 injected_executor: true
               }
             )

    assert_receive {:replay_executor_called, "test_replay_read_only", read_execution_id}
    assert is_binary(read_execution_id)

    read_record = PipelineStatus.get_record(journal.run_id <> "_read", jopts)
    assert read_record.current_effect["status"] == "settled"
    assert read_record.current_effect["idempotency_class"] == "side_effecting"
    assert read_record.current_effect["execution_id"] == read_execution_id

    default_graph = compiled_graph!(action_dot("test_replay_default"))
    default_node = default_graph.nodes["task"]

    default_graph =
      put_in(default_graph.nodes["task"], %{
        default_node
        | handler_module: Arbor.Orchestrator.Handlers.StartHandler,
          idempotency: :idempotent
      })

    assert {:ok, _result} =
             Engine.run(default_graph,
               run_id: journal.run_id <> "_default",
               logs_root: tmp_logs("action_replay_default"),
               journal_opts: jopts,
               actions_executor: ReplayActionsExecutor
             )

    assert_receive {:replay_executor_called, "test_replay_default", execution_id}
    assert is_binary(execution_id)

    default_record = PipelineStatus.get_record(journal.run_id <> "_default", jopts)
    assert default_record.current_effect["status"] == "settled"
    assert default_record.current_effect["idempotency_class"] == "side_effecting"
    assert default_record.current_effect["execution_id"] == execution_id
  end

  test "security regression: handler binding drift denies a would-be content-hash skip" do
    graph = cacheable_loop_graph!()
    test_pid = self()

    {ExtractHandler, original_beam, original_filename} =
      :code.get_object_code(ExtractHandler)

    on_exit(fn -> restore_loaded_module!(ExtractHandler, original_filename, original_beam) end)

    on_event = fn
      %{type: :stage_completed, node_id: "cache"} ->
        send(test_pid, :replay_cacheable_handler_executed)

      %{type: :stage_completed, node_id: "mark"} ->
        replace_extract_handler!()

      _event ->
        :ok
    end

    opts =
      graph
      |> cacheable_execution_opts("cache_handler_drift")
      |> Keyword.put(:on_event, on_event)

    assert {:error, {:cached_node_authorization_failed, "cache", reason}} =
             Engine.run(graph, opts)

    assert reason =~ "execution_module_loaded_code_mismatch"
    assert_receive :replay_cacheable_handler_executed
    refute_receive :replay_cacheable_handler_executed
    refute_received :replay_cacheable_replacement_executed
  end

  test "security regression: capability denial denies a would-be content-hash skip" do
    graph = cacheable_loop_graph!()
    test_pid = self()
    {:ok, capability_counter} = Agent.start_link(fn -> 0 end)
    {:ok, authorizer_counter} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(capability_counter), do: Agent.stop(capability_counter)
      if Process.alive?(authorizer_counter), do: Agent.stop(authorizer_counter)
    end)

    Application.put_env(
      :arbor_orchestrator,
      :security_module,
      ReplayRevocableCapabilitySecurity
    )

    Application.put_env(:arbor_orchestrator, :security_available_override, true)
    Application.put_env(:arbor_orchestrator, :replay_capability_counter, capability_counter)

    authorizer = fn _principal, handler_type ->
      if handler_type == "extract" do
        Agent.update(authorizer_counter, &(&1 + 1))
      end

      :ok
    end

    on_event = fn
      %{type: :stage_completed, node_id: "cache"} ->
        send(test_pid, :replay_cacheable_handler_executed)

      _event ->
        :ok
    end

    opts =
      graph
      |> cacheable_execution_opts("cache_capability_denial")
      |> Keyword.put(:authorizer, authorizer)
      |> Keyword.put(:on_event, on_event)

    assert {:error, {:cached_node_authorization_failed, "cache", reason}} =
             Engine.run(graph, opts)

    assert reason =~ "Capability check failed"
    assert Agent.get(authorizer_counter, & &1) == 2
    assert Agent.get(capability_counter, & &1) == 2
    assert_receive :replay_cacheable_handler_executed
    refute_receive :replay_cacheable_handler_executed
  end

  test "security regression: revoked action capability denies a would-be content-hash skip" do
    graph = cacheable_action_loop_graph!()
    agent_id = "agent_replay_cache_#{System.unique_integer([:positive, :monotonic])}"
    resource = Arbor.Actions.canonical_uri_for(ReplayIdempotentAction, %{})
    :ok = Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(agent_id)

    {:ok, action_capability} =
      Capability.new(
        resource_uri: resource,
        principal_id: agent_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    assert {:ok, :stored} = CapabilityStore.put(action_capability)
    on_exit(fn -> Arbor.Orchestrator.TestCapabilities.revoke_all(agent_id) end)

    on_event = fn
      %{type: :stage_completed, node_id: "cache"} ->
        :ok = Arbor.Security.revoke(action_capability.id)

      _event ->
        :ok
    end

    opts =
      graph
      |> cacheable_execution_opts(
        "cache_action_capability_denial",
        action_catalog!([ReplayIdempotentAction]),
        agent_id
      )
      |> Keyword.put(:on_event, on_event)

    assert {:error, {:cached_node_authorization_failed, "cache", reason}} =
             Engine.run(graph, opts)

    assert reason == "Capability check failed: #{resource} (:unauthorized)"
    assert_receive :replay_idempotent_action_executed
    refute_receive :replay_idempotent_action_executed
  end

  test "security regression: replay classification pins the exact action across registry drift" do
    graph = compiled_graph!(action_dot("test_replay_drift"))
    node = graph.nodes["task"]
    assert node.idempotency == :read_only

    graph_hash = RunAuthorization.graph_hash(graph)
    {:ok, catalog} = ActionCatalog.snapshot(modules: [ReplayDriftOriginalAction])
    {:ok, {manifest, digest}} = ExecutionManifest.build(graph, catalog, graph_hash)

    {:ok, root} =
      "action_replay_drift"
      |> tmp_logs()
      |> Arbor.Common.SafePath.resolve_real()

    {:ok, authority} =
      RunAuthorization.new(graph,
        agent_id: "agent_test",
        workdir: root,
        execution_manifest: manifest,
        execution_manifest_digest: digest
      )

    Application.put_env(:arbor_orchestrator, :action_replay_drift_hook, fn ->
      replace_fixture_binding!("test_replay_drift", ReplayDriftReplacementAction)
    end)

    binding_opts = [
      execution_manifest: manifest,
      execution_manifest_digest: digest,
      pinned_action_bindings: authority.pinned_action_bindings
    ]

    assert {:ok, %{idempotency: :read_only, binding: binding}} =
             Handler.execution_classification(ExecHandler, node, binding_opts)

    assert binding.action_module == ReplayDriftOriginalAction
    assert binding.descriptor["execution_idempotency"] == "read_only"
    assert {:ok, ReplayDriftReplacementAction} = ActionRegistry.resolve("test_replay_drift")

    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
    end)

    tracer = self()

    Task.async(fn ->
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])

      ActionsExecutor.execute_bound(
        "test_replay_drift",
        %{},
        root,
        binding,
        Keyword.merge(binding_opts, agent_id: "system")
      )
    end)
    |> Task.await()

    assert_receive {:trace, _pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     ["system", ReplayDriftOriginalAction, %{}, _context]}}

    refute_received :replay_drift_replacement_executed
  end

  defp action_dot(action_name, extra_attrs \\ nil) do
    extra = if is_binary(extra_attrs), do: ", " <> extra_attrs, else: ""

    """
    digraph ActionReplay {
      start [shape=Mdiamond]
      task [type="exec", target="action", action="#{action_name}"#{extra}]
      done [shape=Msquare]
      start -> task -> done
    }
    """
  end

  defp compiled_graph!(dot) do
    {:ok, graph} = Parser.parse(dot)
    {:ok, compiled} = Compiler.compile(graph)
    compiled
  end

  defp cacheable_loop_graph! do
    compiled_graph!("""
    digraph CacheAuthorization {
      start [shape=Mdiamond]
      cache [type="extract", source_key="source", output_key="clean", enum="safe"]
      check [type="gate", shape=diamond, predicate="expression", expression="done"]
      mark [type="transform", transform="identity", source_key="true_value", output_key="done"]
      done [shape=Msquare]

      start -> cache -> check
      check -> done [condition="context.done=true"]
      check -> mark [condition="context.done!=true"]
      mark -> cache
    }
    """)
  end

  defp cacheable_action_loop_graph! do
    compiled_graph!("""
    digraph CacheActionAuthorization {
      start [shape=Mdiamond]
      cache [type="exec", target="action", action="test_replay_idempotent"]
      check [type="gate", shape=diamond, predicate="expression", expression="done"]
      mark [type="transform", transform="identity", source_key="true_value", output_key="done"]
      done [shape=Msquare]

      start -> cache -> check
      check -> done [condition="context.done=true"]
      check -> mark [condition="context.done!=true"]
      mark -> cache
    }
    """)
  end

  defp cacheable_execution_opts(
         graph,
         label,
         catalog \\ %{"actions" => []},
         agent_id \\ "agent_test"
       ) do
    root = tmp_logs(label)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    graph_hash = RunAuthorization.graph_hash(graph)

    {:ok, {manifest, digest}} =
      ExecutionManifest.build(graph, catalog, graph_hash)

    [
      authorization: true,
      agent_id: agent_id,
      authorizer: fn _principal, _handler_type -> :ok end,
      execution_manifest: manifest,
      execution_manifest_digest: digest,
      initial_values: %{"done" => false, "source" => "safe", "true_value" => true},
      logs_root: root,
      resumable: false,
      run_id: "#{label}_#{System.unique_integer([:positive, :monotonic])}",
      workdir: root
    ]
  end

  defp action_catalog!(modules) do
    {:ok, catalog} = ActionCatalog.snapshot(modules: modules)
    catalog
  end

  defp replace_extract_handler! do
    Code.compile_string("""
    defmodule #{inspect(ExtractHandler)} do
      @behaviour Arbor.Orchestrator.Handlers.Handler

      def execute(_node, _context, _graph, _opts) do
        if pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid) do
          send(pid, :replay_cacheable_replacement_executed)
        end

        %Arbor.Orchestrator.Engine.Outcome{status: :success}
      end

      def idempotency, do: :idempotent
    end
    """)

    :ok
  end

  defp ensure_action_registry_started! do
    unless Process.whereis(ActionRegistry) do
      start_supervised!({ActionRegistry, []})
    end
  end

  defp install_fixture_bindings!(bindings) do
    {entries, locked?} = ActionRegistry.snapshot()
    names = Map.keys(bindings)

    retained =
      Enum.reject(entries, fn {name, _module, _metadata, _failures, _core?} -> name in names end)

    fixtures =
      Enum.map(bindings, fn {name, module} ->
        {name, module, %{category: :test}, 0, false}
      end)

    :ok = ActionRegistry.restore({fixtures ++ retained, locked?})
  end

  defp replace_fixture_binding!(name, replacement) do
    {entries, locked?} = ActionRegistry.snapshot()

    replaced =
      Enum.map(entries, fn
        {^name, _module, metadata, failures, core?} ->
          {name, replacement, metadata, failures, core?}

        entry ->
          entry
      end)

    :ok = ActionRegistry.restore({replaced, locked?})
  end

  defp start_isolated_journal(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    run_id = "#{label}_run_#{suffix}"

    {:ok, _journal} =
      start_supervised({RunJournal, name: name, ets_table: ets_table, backend: nil})

    %{name: name, run_id: run_id}
  end

  defp tmp_logs(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp restore_loaded_module!(module, filename, beam) do
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, filename, beam)
    :code.purge(module)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
