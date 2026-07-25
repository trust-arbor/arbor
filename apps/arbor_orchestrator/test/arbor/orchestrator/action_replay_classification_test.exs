defmodule Arbor.Orchestrator.ActionReplayClassificationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.TestFixtures.{
    ReplayDefaultAction,
    ReplayDriftOriginalAction,
    ReplayDriftReplacementAction,
    ReplayReadOnlyAction
  }

  alias Arbor.Common.ActionRegistry
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.{Context, EffectOwner, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.{ExecHandler, Handler}
  alias Arbor.Orchestrator.IR.Compiler
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.TestFixtures.ReplayActionsExecutor

  @fixture_bindings %{
    "test_replay_default" => ReplayDefaultAction,
    "test_replay_drift" => ReplayDriftOriginalAction,
    "test_replay_read_only" => ReplayReadOnlyAction
  }

  setup do
    ensure_action_registry_started!()
    snapshot = ActionRegistry.snapshot()
    install_fixture_bindings!(@fixture_bindings)

    previous_pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid)
    previous_hook = Application.get_env(:arbor_orchestrator, :action_replay_drift_hook)
    Application.put_env(:arbor_orchestrator, :action_replay_test_pid, self())
    Application.delete_env(:arbor_orchestrator, :action_replay_drift_hook)

    on_exit(fn ->
      if Process.whereis(ActionRegistry), do: ActionRegistry.restore(snapshot)
      restore_env(:action_replay_test_pid, previous_pid)
      restore_env(:action_replay_drift_hook, previous_hook)
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

  test "declared read-only action executes without an effect while default action is journaled" do
    journal = start_isolated_journal("action_replay")
    jopts = [server: journal.name]

    read_graph = compiled_graph!(action_dot("test_replay_read_only"))
    assert_receive :replay_read_only_classified

    assert {:ok, _result} =
             Engine.run(read_graph,
               run_id: journal.run_id <> "_read",
               logs_root: tmp_logs("action_replay_read"),
               journal_opts: jopts,
               actions_executor: ReplayActionsExecutor
             )

    assert_receive :replay_read_only_classified
    refute_receive :replay_read_only_classified
    assert_receive {:replay_executor_called, "test_replay_read_only", nil}

    read_record = PipelineStatus.get_record(journal.run_id <> "_read", jopts)
    assert read_record.current_effect == nil

    default_graph = compiled_graph!(action_dot("test_replay_default"))

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

  test "pinned registry drift is rejected before an unjournaled action can execute" do
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

    idempotency = Handler.idempotency_of(ExecHandler, node)
    assert idempotency == :read_only
    refute EffectOwner.journaled?(idempotency)
    assert {:ok, ReplayDriftReplacementAction} = ActionRegistry.resolve("test_replay_drift")

    outcome =
      ExecHandler.execute(
        node,
        Context.new(),
        graph,
        authorization: true,
        run_authorization: authority
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "action_binding_mismatch"
    refute_received :replay_drift_original_executed
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

  defp restore_env(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
