defmodule Arbor.Orchestrator.Handlers.ExecutionDelegateBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.TestFixtures.BindingOriginalAction
  alias Arbor.Common.{ComputeRegistry, PipelineResolver}
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.{ComposeHandler, ComputeHandler, ExecHandler}
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

  alias Arbor.Orchestrator.TestHandlers.{
    AlternateActionsExecutor,
    AlternateComposeDelegate,
    AlternateComputeDelegate
  }

  setup do
    ensure_registry_started(ComputeRegistry)
    ensure_registry_started(PipelineResolver)
    :ok = Arbor.Orchestrator.Registrar.register_core()

    compute_snapshot = ComputeRegistry.snapshot()
    pipeline_snapshot = PipelineResolver.snapshot()
    previous_pid = Application.get_env(:arbor_orchestrator, :phase5_delegate_binding_test_pid)
    Application.put_env(:arbor_orchestrator, :phase5_delegate_binding_test_pid, self())

    root =
      Path.join(
        System.tmp_dir!(),
        "phase5_delegate_binding_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)

    on_exit(fn ->
      restore_registry(ComputeRegistry, compute_snapshot)
      restore_registry(PipelineResolver, pipeline_snapshot)
      restore_env(:phase5_delegate_binding_test_pid, previous_pid)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "security regression: compute registry replacement is rejected at delegate dispatch", %{
    root: root
  } do
    graph =
      compiled_graph!("""
      digraph ComputeDelegateBinding {
        start [shape=Mdiamond]
        route [type="compute", purpose="routing"]
        done [shape=Msquare]
        start -> route -> done
      }
      """)

    authority = authority!(graph, root)
    :ok = ComputeRegistry.reset()
    :ok = ComputeRegistry.register("routing", AlternateComputeDelegate)

    outcome =
      ComputeHandler.execute(
        graph.nodes["route"],
        Context.new(),
        graph,
        run_authorization: authority
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "execution_delegate_binding_mismatch"
    assert outcome.failure_reason =~ "module"
    refute_received :alternate_compute_delegate_executed
  end

  test "security regression: stale delegate BEAM binding is rejected immediately before invocation",
       %{root: root} do
    graph =
      compiled_graph!("""
      digraph ComputeDelegateBeamBinding {
        start [shape=Mdiamond]
        route [type="compute", purpose="routing"]
        done [shape=Msquare]
        start -> route -> done
      }
      """)

    graph_hash = RunAuthorization.graph_hash(graph)
    {manifest, _digest} = manifest!(graph, graph_hash)

    stale_manifest =
      update_stack_binding(manifest, "route", "compute:routing", fn binding ->
        Map.put(binding, "beam_sha256", String.duplicate("0", 64))
      end)

    {:ok, stale_digest} = ExecutionManifest.digest(stale_manifest)

    {:ok, authority} =
      RunAuthorization.new(graph,
        agent_id: "agent_stale_delegate",
        workdir: root,
        execution_manifest: stale_manifest,
        execution_manifest_digest: stale_digest
      )

    outcome =
      ComputeHandler.execute(
        graph.nodes["route"],
        Context.new(),
        graph,
        run_authorization: authority
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "execution_delegate_binding_mismatch"
    assert outcome.failure_reason =~ "beam_sha256"
  end

  test "security regression: compose resolver replacement is rejected at delegate dispatch", %{
    root: root
  } do
    graph =
      compiled_graph!("""
      digraph ComposeDelegateBinding {
        start [shape=Mdiamond]
        child [type="compose", mode="compose", source_key="child_dot"]
        done [shape=Msquare]
        start -> child -> done
      }
      """)

    authority = authority!(graph, root)
    :ok = PipelineResolver.reset()
    :ok = PipelineResolver.register("compose", AlternateComposeDelegate)

    outcome =
      ComposeHandler.execute(
        graph.nodes["child"],
        Context.new(),
        graph,
        run_authorization: authority
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "execution_delegate_binding_mismatch"
    assert outcome.failure_reason =~ "module"
    refute_received :alternate_compose_delegate_executed
  end

  test "security regression: exec cannot replace its pinned actions executor", %{root: root} do
    graph =
      compiled_graph!("""
      digraph ExecDelegateBinding {
        start [shape=Mdiamond]
        invoke [type="exec", target="action", action="binding_action", param.value="hello"]
        done [shape=Msquare]
        start -> invoke -> done
      }
      """)

    graph_hash = RunAuthorization.graph_hash(graph)
    {:ok, catalog} = ActionCatalog.snapshot(modules: [BindingOriginalAction])
    {:ok, {manifest, digest}} = ExecutionManifest.build(graph, catalog, graph_hash)

    {:ok, authority} =
      RunAuthorization.new(graph,
        agent_id: "agent_exec_delegate",
        workdir: root,
        execution_manifest: manifest,
        execution_manifest_digest: digest
      )

    outcome =
      ExecHandler.execute(
        graph.nodes["invoke"],
        Context.new(),
        graph,
        authorization: true,
        run_authorization: authority,
        actions_executor: AlternateActionsExecutor
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "execution_delegate_binding_mismatch"
    assert outcome.failure_reason =~ "module"
    refute_received :alternate_actions_executor_executed
  end

  defp authority!(graph, root) do
    graph_hash = RunAuthorization.graph_hash(graph)
    {manifest, digest} = manifest!(graph, graph_hash)

    {:ok, authority} =
      RunAuthorization.new(graph,
        agent_id: "agent_delegate_binding",
        workdir: root,
        execution_manifest: manifest,
        execution_manifest_digest: digest
      )

    authority
  end

  defp manifest!(graph, graph_hash) do
    {:ok, {manifest, digest}} =
      ExecutionManifest.build(graph, %{"actions" => []}, graph_hash)

    {manifest, digest}
  end

  defp update_stack_binding(manifest, node_id, slot, fun) do
    nodes =
      Enum.map(manifest["nodes"], fn
        %{"node_id" => ^node_id} = node ->
          stack =
            Enum.map(node["stack"], fn
              %{"slot" => ^slot} = binding -> fun.(binding)
              binding -> binding
            end)

          Map.put(node, "stack", stack)

        node ->
          node
      end)

    Map.put(manifest, "nodes", nodes)
  end

  defp compiled_graph!(dot) do
    {:ok, graph} = Parser.parse(dot)
    {:ok, compiled} = IRCompiler.compile(graph)
    compiled
  end

  defp ensure_registry_started(registry) do
    if is_nil(Process.whereis(registry)) do
      start_supervised!({registry, []})
    end
  end

  defp restore_registry(registry, snapshot) do
    # A registry started by this test is stopped by the ExUnit test supervisor.
    if Process.whereis(registry) do
      registry.restore(snapshot)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
