defmodule Arbor.Orchestrator.RunAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.TestFixtures.BindingOriginalAction
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.{Authorization, Context, Executor, RunAuthorization}
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

  defmodule LobbyOnlySecurity do
    def authorize(_principal, resource, _action, opts) do
      if pid = Application.get_env(:arbor_orchestrator, :phase5_security_test_pid) do
        send(pid, {:authorized_resource, resource, opts})
      end

      if String.starts_with?(resource, "arbor://orchestrator/execute") do
        {:ok, :authorized}
      else
        {:error, :no_effect_capability}
      end
    end

    def list_capabilities(_principal, _opts), do: {:ok, []}
    def capability_authorizes?(_capability, _resource, _opts), do: false
    def normalize_authorization_resource_uri(resource, _opts), do: {:ok, resource}
  end

  defmodule AllowAllSecurity do
    def authorize(_principal, _resource, _action, _opts), do: {:ok, :authorized}
    def list_capabilities(_principal, _opts), do: {:ok, [:allow_all]}
    def capability_authorizes?(:allow_all, _resource, _opts), do: true
    def normalize_authorization_resource_uri(resource, _opts), do: {:ok, resource}
  end

  defmodule RevocableCallerSecurity do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{allowed: true, checks: []} end, name: __MODULE__)
    end

    def authorize(_principal, _resource, _action, _opts), do: {:ok, :authorized}

    def list_capabilities(_principal, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        capabilities = if state.allowed, do: [:caller_capability], else: []
        {{:ok, capabilities}, %{state | checks: [opts | state.checks]}}
      end)
    end

    def capability_authorizes?(:caller_capability, _resource, _opts), do: true
    def normalize_authorization_resource_uri(resource, _opts), do: {:ok, resource}
    def revoke, do: Agent.update(__MODULE__, &%{&1 | allowed: false})
    def checks, do: Agent.get(__MODULE__, &Enum.reverse(&1.checks))
  end

  setup do
    originals = %{
      security_module: Application.get_env(:arbor_orchestrator, :security_module),
      security_available_override:
        Application.get_env(:arbor_orchestrator, :security_available_override),
      test_pid: Application.get_env(:arbor_orchestrator, :phase5_security_test_pid)
    }

    Application.put_env(:arbor_orchestrator, :security_available_override, true)
    Application.put_env(:arbor_orchestrator, :phase5_security_test_pid, self())

    root =
      Path.join(
        System.tmp_dir!(),
        "phase5_run_authority_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)

    on_exit(fn ->
      restore(:security_module, originals.security_module)
      restore(:security_available_override, originals.security_available_override)
      restore(:phase5_security_test_pid, originals.test_pid)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "security regression: authorization true fails closed without a trusted principal" do
    dot = "digraph MissingPrincipal { start [shape=Mdiamond] done [shape=Msquare] start -> done }"

    assert {:error, :execution_principal_required} =
             Arbor.Orchestrator.run(dot,
               authorization: true,
               authorizer: fn _, _ -> :ok end
             )
  end

  test "security regression: initial context cannot spoof principal or fixed workdir", %{
    root: root
  } do
    use_security(LobbyOnlySecurity)
    test_pid = self()

    dot = """
    digraph ContextSpoof {
      start [shape=Mdiamond]
      principal [type="transform", transform="identity", source_key="session.agent_id", output_key="observed_principal"]
      cwd [type="transform", transform="identity", source_key="workdir", output_key="observed_workdir"]
      done [shape=Msquare]
      start -> principal -> cwd -> done
    }
    """

    authorizer = fn principal, type ->
      send(test_pid, {:handler_authorized, principal, type})
      :ok
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               authorization: true,
               agent_id: "agent_real",
               caller_id: "agent_real",
               authorizer: authorizer,
               workdir: root,
               resumable: false,
               initial_values: %{
                 "session.agent_id" => "agent_spoofed",
                 "workdir" => Path.join(root, "redirect")
               }
             )

    assert result.context["observed_principal"] == "agent_real"
    assert result.context["observed_workdir"] == Path.expand(root)
    assert_received {:handler_authorized, "agent_real", "transform"}
    refute_received {:handler_authorized, "agent_spoofed", _}
  end

  test "security regression: graph node agent_id override is rejected before execution", %{
    root: root
  } do
    use_security(AllowAllSecurity)

    dot = """
    digraph NodeSpoof {
      start [shape=Mdiamond]
      spoof [type="transform", transform="constant", expression="ran", output_key="spoof_ran", agent_id="agent_other"]
      done [shape=Msquare]
      start -> spoof -> done
    }
    """

    assert {:error, {:graph_principal_override, "spoof"}} =
             Arbor.Orchestrator.run(dot, authorized_opts(root))
  end

  test "security regression: nested subgraph preserves the exact execution identity", %{
    root: root
  } do
    use_security(AllowAllSecurity)
    test_pid = self()

    child = """
    digraph Child {
      start [shape=Mdiamond]
      observe [type="transform", transform="identity", source_key="session.agent_id", output_key="observed"]
      done [shape=Msquare]
      start -> observe -> done
    }
    """

    parent = """
    digraph Parent {
      start [shape=Mdiamond]
      child [type="graph.compose", source_key="child_dot", pass_all_context="true", result_mapping="observed:nested_principal"]
      done [shape=Msquare]
      start -> child -> done
    }
    """

    opts =
      authorized_opts(root,
        authorizer: fn principal, type ->
          send(test_pid, {:nested_authorized, principal, type})
          :ok
        end,
        initial_values: %{
          "child_dot" => child,
          "session.agent_id" => "agent_nested_spoof"
        }
      )

    assert {:ok, result} = Arbor.Orchestrator.run(parent, opts)
    assert result.context["nested_principal"] == "agent_executor"
    assert_received {:nested_authorized, "agent_executor", "graph.compose"}
    assert_received {:nested_authorized, "agent_executor", "transform"}
    refute_received {:nested_authorized, "agent_nested_spoof", _}
  end

  test "security regression: traversal lobby alone cannot write files", %{root: root} do
    use_security(LobbyOnlySecurity)
    output = Path.join(root, "blocked.txt")

    dot = """
    digraph FileWriteDenied {
      start [shape=Mdiamond]
      write [type="file.write", content_key="payload", output="blocked.txt"]
      done [shape=Msquare]
      start -> write -> done
    }
    """

    assert {:ok, result} =
             Arbor.Orchestrator.run(
               dot,
               authorized_opts(root,
                 task_id: "task_effect_scope",
                 session_id: "session_effect_scope",
                 initial_values: %{"payload" => "must not be written"}
               )
             )

    refute File.exists?(output)
    refute Map.has_key?(result.context, "file.written.write")

    assert_received {:authorized_resource, "arbor://fs/write", auth_opts}
    assert auth_opts[:file_path] == output
    assert auth_opts[:workdir] == Path.expand(root)
    assert auth_opts[:task_id] == "task_effect_scope"
    assert auth_opts[:session_id] == "session_effect_scope"
  end

  test "security regression: traversal lobby alone cannot execute shell or tool with sandbox none",
       %{root: root} do
    use_security(LobbyOnlySecurity)
    shell_marker = Path.join(root, "shell-owned")
    tool_marker = Path.join(root, "tool-owned")

    for {type, marker} <- [{"shell", shell_marker}, {"tool", tool_marker}] do
      dot = """
      digraph CommandDenied {
        start [shape=Mdiamond]
        command [type="#{type}", command="printf owned > #{marker}", tool_command="printf owned > #{marker}", sandbox="none"]
        done [shape=Msquare]
        start -> command -> done
      }
      """

      assert {:ok, _result} = Arbor.Orchestrator.run(dot, authorized_opts(root))
      refute File.exists?(marker)
      assert_received {:authorized_resource, "arbor://shell/exec", _opts}
    end
  end

  test "security regression: pure handler traversal remains available with the lobby grant", %{
    root: root
  } do
    use_security(LobbyOnlySecurity)

    dot = """
    digraph PureTraversal {
      start [shape=Mdiamond]
      copy [type="transform", transform="identity", source_key="value", output_key="copied"]
      done [shape=Msquare]
      start -> copy -> done
    }
    """

    assert {:ok, result} =
             Arbor.Orchestrator.run(
               dot,
               authorized_opts(root, initial_values: %{"value" => "safe"})
             )

    assert result.context["copied"] == "safe"
    assert_received {:authorized_resource, "arbor://orchestrator/execute/transform", _opts}
  end

  test "security regression: caller authority is rechecked and revocation stops a later node", %{
    root: root
  } do
    start_supervised!(RevocableCallerSecurity)
    use_security(RevocableCallerSecurity)

    dot = """
    digraph CallerRevocation {
      start [shape=Mdiamond]
      first [type="transform", transform="identity", source_key="value", output_key="first_seen"]
      second [type="transform", transform="identity", source_key="first_seen", output_key="second_seen"]
      done [shape=Msquare]
      start -> first -> second -> done
    }
    """

    on_event = fn
      %{type: :stage_completed, node_id: "first"} -> RevocableCallerSecurity.revoke()
      _ -> :ok
    end

    opts =
      authorized_opts(root,
        caller_id: "human_caller",
        task_id: "task_revocation",
        session_id: "session_revocation",
        initial_values: %{"value" => "first"},
        on_event: on_event
      )

    assert {:ok, result} = Arbor.Orchestrator.run(dot, opts)
    assert result.context["first_seen"] == "first"
    refute Map.has_key?(result.context, "second_seen")

    assert [first_check, second_check] = RevocableCallerSecurity.checks()
    assert first_check[:task_id] == "task_revocation"
    assert second_check[:session_id] == "session_revocation"
  end

  test "security regression: parallel branch nodes cannot bypass Authorization", %{root: root} do
    use_security(AllowAllSecurity)

    dot = """
    digraph ParallelAuthorization {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all", fan_out="false"]
      branch [type="transform", transform="constant", expression="ran", output_key="branch_ran"]
      join [shape=tripleoctagon]
      done [shape=Msquare]
      start -> parallel
      parallel -> branch
      branch -> join
      join -> done
    }
    """

    authorizer = fn _principal, type ->
      if type == "transform", do: {:error, :branch_denied}, else: :ok
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, authorized_opts(root, authorizer: authorizer))

    [branch_result] = result.context["parallel.results"]
    assert branch_result["status"] == "fail"
    refute Map.has_key?(branch_result["context_updates"], "branch_ran")
  end

  test "security regression: bound parallel dispatch rejects a missing handler binding", %{
    root: root
  } do
    use_security(AllowAllSecurity)

    dot = """
    digraph BoundParallel {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all", fan_out="false"]
      branch [type="transform", transform="constant", expression="ran", output_key="branch_ran"]
      join [shape=tripleoctagon]
      done [shape=Msquare]
      start -> parallel
      parallel -> branch
      branch -> join
      join -> done
    }
    """

    graph = compiled_graph!(dot)
    graph_hash = RunAuthorization.graph_hash(graph)
    {manifest, _digest} = execution_manifest!(graph, graph_hash)

    handlers = Enum.reject(manifest["handlers"], &(&1["handler_type"] == "transform"))

    nodes =
      Enum.reject(manifest["nodes"], &(&1["handler_type"] == "transform"))

    incomplete_manifest =
      manifest
      |> Map.put("handlers", handlers)
      |> Map.put("nodes", nodes)

    {:ok, incomplete_digest} = ExecutionManifest.digest(incomplete_manifest)

    assert {:ok, result} =
             Engine.run(
               graph,
               authorized_opts(root,
                 execution_manifest: incomplete_manifest,
                 execution_manifest_digest: incomplete_digest
               )
             )

    [branch_result] = result.context["parallel.results"]
    assert branch_result["status"] == "fail"
    refute Map.has_key?(branch_result["context_updates"], "branch_ran")
  end

  test "security regression: actual handler dispatch rejects missing, module-drifted, and BEAM-drifted bindings",
       %{root: root} do
    graph =
      compiled_graph!("""
      digraph HandlerDispatch {
        start [shape=Mdiamond]
        copy [type="transform", transform="identity", source_key="value", output_key="copied"]
        done [shape=Msquare]
        start -> copy -> done
      }
      """)

    graph_hash = RunAuthorization.graph_hash(graph)
    {manifest, digest} = execution_manifest!(graph, graph_hash)

    {:ok, authority} =
      RunAuthorization.new(graph,
        agent_id: "agent_handler_binding",
        workdir: root,
        execution_manifest: manifest,
        execution_manifest_digest: digest
      )

    node = graph.nodes["copy"]
    opts = [authorization: true, run_authorization: authority, authorizer: fn _, _ -> :ok end]

    missing = %{
      authority
      | pinned_handler_bindings: Map.delete(authority.pinned_handler_bindings, "transform")
    }

    missing_outcome =
      Authorization.authorize_and_execute(
        node.handler_module,
        node,
        Context.new(),
        graph,
        Keyword.put(opts, :run_authorization, missing)
      )

    assert missing_outcome.status == :fail
    assert missing_outcome.failure_reason =~ "missing_handler_binding"

    module_outcome =
      Authorization.authorize_and_execute(
        Arbor.Orchestrator.TestHandlers.AlternateExec,
        node,
        Context.new(),
        graph,
        opts
      )

    assert module_outcome.status == :fail
    assert module_outcome.failure_reason =~ "handler_binding_mismatch"
    assert module_outcome.failure_reason =~ "module"

    stale_transform =
      Map.update!(authority.pinned_handler_bindings["transform"], "beam_sha256", fn _digest ->
        String.duplicate("0", 64)
      end)

    stale = %{
      authority
      | pinned_handler_bindings:
          Map.put(authority.pinned_handler_bindings, "transform", stale_transform)
    }

    stale_outcome =
      Authorization.authorize_and_execute(
        node.handler_module,
        node,
        Context.new(),
        graph,
        Keyword.put(opts, :run_authorization, stale)
      )

    assert stale_outcome.status == :fail
    assert stale_outcome.failure_reason =~ "handler_binding_mismatch"
    assert stale_outcome.failure_reason =~ "beam_sha256"
  end

  test "security regression: nested child derives a distinct valid subset binding", %{root: root} do
    parent =
      compiled_graph!("""
      digraph ParentBinding {
        start [shape=Mdiamond]
        parent_work [type="transform", transform="identity", source_key="value", output_key="parent_value"]
        done [shape=Msquare]
        start -> parent_work -> done
      }
      """)

    child =
      compiled_graph!("""
      digraph ChildBinding {
        start [shape=Mdiamond]
        child_work [type="transform", transform="identity", source_key="value", output_key="child_value"]
        done [shape=Msquare]
        start -> child_work -> done
      }
      """)

    parent_hash = RunAuthorization.graph_hash(parent)
    {parent_manifest, parent_manifest_digest} = execution_manifest!(parent, parent_hash)
    assert parent_manifest["version"] == 2
    refute Map.has_key?(parent_manifest, "nested_graphs")

    {:ok, parent_authority} =
      RunAuthorization.new(parent,
        agent_id: "agent_parent_binding",
        caller_id: "caller_parent_binding",
        author_id: "author_parent_binding",
        task_id: "task_parent_binding",
        session_id: "session_parent_binding",
        workdir: root,
        execution_manifest: parent_manifest,
        execution_manifest_digest: parent_manifest_digest
      )

    assert {:ok, {child_authority, child_opts}} =
             RunAuthorization.prepare(child,
               authorization: true,
               run_authorization: parent_authority
             )

    assert child_authority.graph_hash == RunAuthorization.graph_hash(child)
    assert child_authority.execution_manifest["version"] == 2
    refute Map.has_key?(child_authority.execution_manifest, "nested_graphs")
    refute child_authority.graph_hash == parent_authority.graph_hash
    assert child_authority.parent_binding_digest == parent_authority.binding_digest
    refute child_authority.binding_digest == parent_authority.binding_digest
    refute child_authority.execution_manifest_digest == parent_authority.execution_manifest_digest
    assert child_authority.execution_principal == parent_authority.execution_principal
    assert child_authority.caller_id == parent_authority.caller_id
    assert child_authority.workdir == parent_authority.workdir
    assert child_authority.workdir_identity == parent_authority.workdir_identity

    assert :ok =
             ExecutionManifest.require_subset(child_authority.execution_manifest, parent_manifest)

    assert child_opts[:run_authorization] == child_authority
    assert child_opts[:execution_manifest] == child_authority.execution_manifest
    assert child_opts[:pinned_handler_bindings] == child_authority.pinned_handler_bindings
    assert child_opts[:pinned_node_bindings] == child_authority.pinned_node_bindings
  end

  test "security regression: reviewed nested council graph derives only from its declared closure",
       %{root: root} do
    parent_dot =
      File.read!(Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot"))

    {:ok, %{source: child_dot}} = Arbor.Actions.reviewed_pipeline("code_review_council")

    parent = compiled_graph!(parent_dot)
    child = compiled_graph!(child_dot)
    {:ok, catalog} = ActionCatalog.snapshot()

    parent_hash = RunAuthorization.graph_hash(parent)

    {:ok, {parent_manifest, parent_manifest_digest}} =
      ExecutionManifest.build(parent, catalog, parent_hash)

    assert [%{"id" => "code_review_council", "execution_manifest" => nested_manifest}] =
             parent_manifest["nested_graphs"]

    assert "parallel" in Enum.map(parent_manifest["handlers"], & &1["handler_type"])
    assert "compute" in Enum.map(parent_manifest["handlers"], & &1["handler_type"])
    assert "consensus_decide" in Enum.map(parent_manifest["actions"], & &1["name"])

    assert {:ok, child_compiled_graph_hash} = ExecutionManifest.compiled_graph_hash(child)
    assert nested_manifest["compiled_graph_hash"] == child_compiled_graph_hash

    {:ok, parent_authority} =
      RunAuthorization.new(parent,
        agent_id: "agent_declared_council_closure",
        caller_id: "caller_declared_council_closure",
        author_id: "author_declared_council_closure",
        task_id: "task_declared_council_closure",
        session_id: "session_declared_council_closure",
        workdir: root,
        execution_manifest: parent_manifest,
        execution_manifest_digest: parent_manifest_digest
      )

    assert {:ok, {child_authority, child_opts}} =
             RunAuthorization.prepare(child,
               authorization: true,
               run_authorization: parent_authority
             )

    assert child_authority.graph_hash == RunAuthorization.graph_hash(child)
    refute child_authority.binding_digest == parent_authority.binding_digest
    assert child_authority.parent_binding_digest == parent_authority.binding_digest
    assert child_opts[:run_authorization] == child_authority

    changed_child_dot =
      String.replace(
        child_dot,
        "  collect -> decide -> done",
        "  collect -> done\n  decide -> done"
      )

    refute changed_child_dot == child_dot
    changed_child = compiled_graph!(changed_child_dot)

    assert {:error, {:child_execution_manifest_failed, :child_graph_not_declared_by_parent}} =
             RunAuthorization.prepare(changed_child,
               authorization: true,
               run_authorization: parent_authority
             )

    undeclared_parent =
      parent_dot
      |> String.replace("    nested_graphs=\"code_review_council\"\n", "")
      |> compiled_graph!()

    undeclared_parent_hash = RunAuthorization.graph_hash(undeclared_parent)

    {:ok, {undeclared_manifest, undeclared_manifest_digest}} =
      ExecutionManifest.build(undeclared_parent, catalog, undeclared_parent_hash)

    {:ok, undeclared_authority} =
      RunAuthorization.new(undeclared_parent,
        agent_id: "agent_undeclared_council_closure",
        caller_id: "caller_undeclared_council_closure",
        author_id: "author_undeclared_council_closure",
        task_id: "task_undeclared_council_closure",
        session_id: "session_undeclared_council_closure",
        workdir: root,
        execution_manifest: undeclared_manifest,
        execution_manifest_digest: undeclared_manifest_digest
      )

    assert {:error,
            {:child_execution_manifest_failed,
             {:child_binding_not_pinned_by_parent, :action, "consensus_decide"}}} =
             RunAuthorization.prepare(child,
               authorization: true,
               run_authorization: undeclared_authority
             )
  end

  test "security regression: RunAuthorization rejects a recomputed forged reviewed child closure",
       %{root: root} do
    parent_dot = """
    digraph ForgedReviewedChildClosure {
      graph [nested_graphs="code_review_council"]
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    {:ok, reviewed_pipeline} = Arbor.Actions.reviewed_pipeline("code_review_council")

    forged_child_dot =
      String.replace(
        reviewed_pipeline.source,
        "  collect -> decide -> done",
        "  collect -> done\n  decide -> done"
      )

    refute forged_child_dot == reviewed_pipeline.source

    parent = compiled_graph!(parent_dot)
    forged_child = compiled_graph!(forged_child_dot)
    {:ok, catalog} = ActionCatalog.snapshot()
    parent_hash = RunAuthorization.graph_hash(parent)
    forged_child_hash = RunAuthorization.graph_hash(forged_child)

    {:ok, {parent_manifest, _parent_digest}} =
      ExecutionManifest.build(parent, catalog, parent_hash)

    {:ok, {forged_child_manifest, forged_child_digest}} =
      ExecutionManifest.build(forged_child, catalog, forged_child_hash)

    assert :ok =
             ExecutionManifest.validate(
               forged_child_manifest,
               forged_child_digest,
               forged_child_hash
             )

    [reviewed_child] = parent_manifest["nested_graphs"]

    forged_child_binding =
      Map.merge(reviewed_child, %{
        "graph_hash" => forged_child_hash,
        "compiled_graph_hash" => forged_child_manifest["compiled_graph_hash"],
        "execution_manifest" => forged_child_manifest,
        "execution_manifest_digest" => forged_child_digest
      })

    assert forged_child_binding["source_id"] == reviewed_child["source_id"]
    assert forged_child_binding["source_sha256"] == reviewed_child["source_sha256"]
    refute forged_child_binding["graph_hash"] == reviewed_child["graph_hash"]
    refute forged_child_binding["compiled_graph_hash"] == reviewed_child["compiled_graph_hash"]

    forged_parent_manifest = Map.put(parent_manifest, "nested_graphs", [forged_child_binding])
    {:ok, forged_parent_digest} = ExecutionManifest.digest(forged_parent_manifest)

    assert {:error,
            {:invalid_execution_manifest_entry, :nested_graphs, 0,
             {:nested_graph_closure_mismatch, "code_review_council"}}} =
             RunAuthorization.new(parent,
               agent_id: "agent_forged_reviewed_child_closure",
               workdir: root,
               execution_manifest: forged_parent_manifest,
               execution_manifest_digest: forged_parent_digest
             )
  end

  test "security regression: declaring parent cannot downgrade its manifest to v2", %{root: root} do
    parent_dot =
      File.read!(Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot"))

    parent = compiled_graph!(parent_dot)
    parent_hash = RunAuthorization.graph_hash(parent)
    {:ok, catalog} = ActionCatalog.snapshot()

    {:ok, {manifest, _manifest_digest}} =
      ExecutionManifest.build(parent, catalog, parent_hash)

    assert manifest["version"] == 3

    downgraded_manifest =
      manifest
      |> Map.delete("nested_graphs")
      |> Map.put("version", 2)

    {:ok, downgraded_digest} = ExecutionManifest.digest(downgraded_manifest)
    assert :ok = ExecutionManifest.validate(downgraded_manifest, downgraded_digest, parent_hash)

    binding_opts = [
      agent_id: "agent_downgraded_nested_manifest",
      workdir: root,
      execution_manifest: downgraded_manifest,
      execution_manifest_digest: downgraded_digest
    ]

    assert {:error, {:execution_manifest_field_mismatch, :version}} =
             RunAuthorization.new(parent, binding_opts)

    assert {:error, {:execution_manifest_field_mismatch, :version}} =
             RunAuthorization.prepare(parent, [authorization: true] ++ binding_opts)
  end

  test "security regression: RunAuthorization and Engine reject a changed compiled graph paired with an old manifest",
       %{root: root} do
    approved =
      compiled_graph!("""
      digraph CompiledGraphBinding {
        start [shape=Mdiamond]
        invoke [type="exec", target="action", action="binding_action", param.value="hello"]
        done [shape=Msquare]
        start -> invoke -> done
      }
      """)

    changed =
      compiled_graph!("""
      digraph CompiledGraphBinding {
        start [shape=Mdiamond]
        invoke [type="exec", target="shell", command="printf should-not-run"]
        done [shape=Msquare]
        start -> invoke -> done
      }
      """)

    graph_hash = RunAuthorization.graph_hash(approved)
    {:ok, catalog} = ActionCatalog.snapshot(modules: [BindingOriginalAction])
    {:ok, {manifest, digest}} = ExecutionManifest.build(approved, catalog, graph_hash)

    binding_opts = [
      agent_id: "agent_compiled_graph_binding",
      workdir: root,
      graph_hash: graph_hash,
      execution_manifest: manifest,
      execution_manifest_digest: digest
    ]

    assert {:error, {:execution_manifest_field_mismatch, :compiled_graph_hash}} =
             RunAuthorization.new(changed, binding_opts)

    assert {:error, {:execution_manifest_field_mismatch, :compiled_graph_hash}} =
             Engine.run(
               changed,
               Keyword.merge(authorized_opts(root), binding_opts)
             )
  end

  test "security regression: nested child cannot introduce an unpinned action, handler, or capability",
       %{root: root} do
    parent =
      compiled_graph!("""
      digraph ParentMinimal {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """)

    parent_hash = RunAuthorization.graph_hash(parent)
    {parent_manifest, parent_digest} = execution_manifest!(parent, parent_hash)

    {:ok, authority} =
      RunAuthorization.new(parent,
        agent_id: "agent_parent_minimal",
        workdir: root,
        execution_manifest: parent_manifest,
        execution_manifest_digest: parent_digest
      )

    action_child =
      compiled_graph!("""
      digraph ChildActionEscalation {
        start [shape=Mdiamond]
        invoke [type="exec", target="action", action="session_classify", param.input="hello"]
        done [shape=Msquare]
        start -> invoke -> done
      }
      """)

    assert {:error,
            {:child_execution_manifest_failed,
             {:child_binding_not_pinned_by_parent, :action, "session_classify"}}} =
             RunAuthorization.prepare(action_child,
               authorization: true,
               run_authorization: authority
             )

    handler_child =
      compiled_graph!("""
      digraph ChildHandlerEscalation {
        start [shape=Mdiamond]
        transform [type="transform", transform="constant", expression="new authority"]
        done [shape=Msquare]
        start -> transform -> done
      }
      """)

    assert {:error,
            {:child_execution_manifest_failed,
             {:child_binding_not_pinned_by_parent, :handler, "transform"}}} =
             RunAuthorization.prepare(handler_child,
               authorization: true,
               run_authorization: authority
             )

    {:ok, live_catalog} = ActionCatalog.snapshot()
    child_hash = RunAuthorization.graph_hash(action_child)

    {:ok, {child_manifest, _child_digest}} =
      ExecutionManifest.build(action_child, live_catalog, child_hash)

    refute Enum.empty?(child_manifest["capability_uris"])
    assert Enum.empty?(parent_manifest["capability_uris"])
  end

  test "security regression: authorized graph adaptation is rejected before execution", %{
    root: root
  } do
    use_security(AllowAllSecurity)

    dot = """
    digraph AuthorizedAdaptation {
      start [shape=Mdiamond]
      adapt [type="graph.adapt"]
      done [shape=Msquare]
      start -> adapt -> done
    }
    """

    assert {:error, {:authorized_graph_adaptation_forbidden, "adapt"}} =
             Arbor.Orchestrator.run(dot, authorized_opts(root))
  end

  test "security regression: authorized remote placement requires a serializable signed lease", %{
    root: root
  } do
    graph =
      compiled_graph!("""
      digraph RemoteLease {
        start [shape=Mdiamond]
        remote [type="transform", transform="constant", expression="ran", placement="node:unreachable@nowhere"]
        done [shape=Msquare]
        start -> remote -> done
      }
      """)

    node = graph.nodes["remote"]
    {:ok, authority} = RunAuthorization.new(graph, agent_id: "agent_executor", workdir: root)

    {outcome, _retries} =
      Executor.execute_with_retry(node, Context.new(), graph, %{},
        authorization: true,
        run_authorization: authority
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "authorized_remote_placement_requires_signed_lease"
  end

  test "security regression: checkpoint resume requires an exact authority binding", %{root: root} do
    use_security(AllowAllSecurity)
    checkpoint_root = Path.join(root, "checkpoint")
    File.mkdir_p!(checkpoint_root)
    private_key = :crypto.strong_rand_bytes(32)
    run_id = "phase5_authority_checkpoint"

    dot = """
    digraph AuthorityCheckpoint {
      start [shape=Mdiamond]
      copy [type="transform", transform="identity", source_key="value", output_key="copied"]
      done [shape=Msquare]
      start -> copy -> done
    }
    """

    opts =
      authorized_opts(checkpoint_root,
        caller_id: "human_original",
        task_id: "task_checkpoint",
        run_id: run_id,
        logs_root: checkpoint_root,
        identity_private_key: private_key,
        resumable: true,
        initial_values: %{"value" => "persisted"}
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, opts)

    checkpoint_path = Path.join(checkpoint_root, "checkpoint.json")
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    projection = checkpoint["run_authorization"]

    assert projection["execution_principal"] == "agent_executor"
    assert projection["caller_id"] == "human_original"
    assert projection["task_id"] == "task_checkpoint"
    assert is_binary(projection["binding_digest"])

    assert {:error, :run_authorization_mismatch} =
             Arbor.Orchestrator.run(
               dot,
               authorized_opts(checkpoint_root,
                 caller_id: "human_different",
                 task_id: "task_checkpoint",
                 run_id: run_id,
                 logs_root: checkpoint_root,
                 identity_private_key: private_key,
                 resume_from: checkpoint_path,
                 resumable: true
               )
             )
  end

  test "security regression: signed checkpoint resume binds the full execution manifest", %{
    root: root
  } do
    use_security(AllowAllSecurity)
    :ok = Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access("agent_executor")
    checkpoint_root = Path.join(root, "bound-checkpoint")
    private_key = :crypto.strong_rand_bytes(32)
    run_id = "phase5_execution_manifest_checkpoint"

    dot = """
    digraph BoundCheckpoint {
      start [shape=Mdiamond]
      copy [type="transform", transform="identity", source_key="value", output_key="copied"]
      done [shape=Msquare]
      start -> copy -> done
    }
    """

    graph = compiled_graph!(dot)
    graph_hash = sha256(dot)
    {manifest, manifest_digest} = execution_manifest!(graph, graph_hash)

    opts =
      authorized_opts(root,
        graph_hash: graph_hash,
        execution_manifest: manifest,
        execution_manifest_digest: manifest_digest,
        run_id: run_id,
        logs_root: checkpoint_root,
        identity_private_key: private_key,
        resumable: true,
        cache: false,
        initial_values: %{"value" => "persisted"}
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, opts)

    checkpoint_path = Path.join(checkpoint_root, "checkpoint.json")
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    projection = checkpoint["run_authorization"]

    assert projection["execution_manifest"] == manifest
    assert projection["execution_manifest_digest"] == manifest_digest
    assert projection["workdir_identity"]["inode"] > 0

    assert Enum.any?(projection["execution_manifest"]["handlers"], fn binding ->
             binding["handler_type"] == "transform"
           end)

    # Mirrors are deliberately omitted. RunAuthorization derives both indexes
    # from the full manifest before comparing the signed checkpoint projection.
    assert {:ok, _resumed} =
             Arbor.Orchestrator.run(
               dot,
               opts
               |> Keyword.delete(:initial_values)
               |> Keyword.put(:resume_from, checkpoint_path)
             )

    altered_handlers =
      Enum.map(manifest["handlers"], fn
        %{"handler_type" => "transform"} = binding ->
          Map.put(binding, "beam_sha256", String.duplicate("0", 64))

        binding ->
          binding
      end)

    altered_nodes =
      Enum.map(manifest["nodes"], fn
        %{"handler_type" => "transform", "stack" => [wrapper | rest]} = binding ->
          stale_wrapper = Map.put(wrapper, "beam_sha256", String.duplicate("0", 64))
          Map.put(binding, "stack", [stale_wrapper | rest])

        binding ->
          binding
      end)

    altered_manifest =
      manifest
      |> Map.put("handlers", altered_handlers)
      |> Map.put("nodes", altered_nodes)

    {:ok, altered_digest} = ExecutionManifest.digest(altered_manifest)

    assert {:error, :run_authorization_mismatch} =
             Arbor.Orchestrator.run(
               dot,
               opts
               |> Keyword.put(:execution_manifest, altered_manifest)
               |> Keyword.put(:execution_manifest_digest, altered_digest)
               |> Keyword.put(:resume_from, checkpoint_path)
             )

    assert {:error, :invalid_execution_manifest_binding} =
             Arbor.Orchestrator.run(
               dot,
               opts
               |> Keyword.delete(:execution_manifest_digest)
               |> Keyword.put(:resume_from, checkpoint_path)
             )
  end

  test "security regression: full manifest, not caller mirrors, reconstructs pinned indexes", %{
    root: root
  } do
    graph =
      compiled_graph!("""
      digraph ActionIndexBinding {
        start [shape=Mdiamond]
        invoke [type="exec", target="action", action="binding_action", param.value="hello"]
        done [shape=Msquare]
        start -> invoke -> done
      }
      """)

    graph_hash = RunAuthorization.graph_hash(graph)
    {:ok, catalog} = ActionCatalog.snapshot(modules: [BindingOriginalAction])
    {:ok, {manifest, digest}} = ExecutionManifest.build(graph, catalog, graph_hash)

    assert {:ok, authority} =
             RunAuthorization.new(graph,
               agent_id: "agent_index_binding",
               workdir: root,
               execution_manifest: manifest,
               execution_manifest_digest: digest
             )

    assert authority.pinned_action_bindings["binding_action"] == hd(manifest["actions"])
    assert map_size(authority.pinned_handler_bindings) == length(manifest["handlers"])
    assert map_size(authority.pinned_node_bindings) == length(manifest["nodes"])
    assert RunAuthorization.projection(authority)["execution_manifest"] == manifest

    assert {:error, {:execution_manifest_index_mismatch, :action}} =
             RunAuthorization.new(graph,
               agent_id: "agent_index_binding",
               workdir: root,
               execution_manifest: manifest,
               execution_manifest_digest: digest,
               pinned_action_bindings: %{}
             )

    assert {:error, {:execution_manifest_index_mismatch, :handler}} =
             RunAuthorization.new(graph,
               agent_id: "agent_index_binding",
               workdir: root,
               execution_manifest: manifest,
               execution_manifest_digest: digest,
               pinned_handler_bindings: %{}
             )

    assert {:error, {:execution_manifest_index_mismatch, :node}} =
             RunAuthorization.new(graph,
               agent_id: "agent_index_binding",
               workdir: root,
               execution_manifest: manifest,
               execution_manifest_digest: digest,
               pinned_node_bindings: %{}
             )
  end

  test "security regression: canonical workdir replacement is denied before handler dispatch", %{
    root: root
  } do
    graph =
      compiled_graph!("""
      digraph WorkdirDispatch {
        start [shape=Mdiamond]
        copy [type="transform", transform="identity", source_key="value", output_key="copied"]
        done [shape=Msquare]
        start -> copy -> done
      }
      """)

    graph_hash = RunAuthorization.graph_hash(graph)
    {manifest, digest} = execution_manifest!(graph, graph_hash)
    outside = Path.join(root, "outside-workdir")
    File.mkdir_p!(outside)

    for replacement <- [:symlink, :new_directory] do
      workdir = Path.join(root, "dispatch-workdir-#{replacement}")
      original = workdir <> "-original"
      File.mkdir_p!(workdir)

      {:ok, authority} =
        RunAuthorization.new(graph,
          agent_id: "agent_workdir_dispatch",
          workdir: workdir,
          execution_manifest: manifest,
          execution_manifest_digest: digest
        )

      File.rename!(workdir, original)

      case replacement do
        :symlink -> File.ln_s!(outside, workdir)
        :new_directory -> File.mkdir_p!(workdir)
      end

      node = graph.nodes["copy"]

      outcome =
        Authorization.authorize_and_execute(
          node.handler_module,
          node,
          Context.new(%{"value" => "blocked"}),
          graph,
          authorization: true,
          run_authorization: authority,
          authorizer: fn _, _ -> :ok end
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "run_authorization_workdir_changed"
    end
  end

  test "security regression: scheduler-to-Engine workdir symlink race and resume replacement fail closed",
       %{root: root} do
    use_security(AllowAllSecurity)

    dot = "digraph WorkdirEntry { start [shape=Mdiamond] done [shape=Msquare] start -> done }"
    outside = Path.join(root, "entry-outside")
    raced_path = Path.join(root, "scheduler-canonical-workdir")
    File.mkdir_p!(outside)
    File.ln_s!(outside, raced_path)

    assert {:error, :run_authorization_workdir_not_canonical} =
             Arbor.Orchestrator.run(dot, authorized_opts(raced_path))

    for replacement <- [:symlink, :new_directory] do
      workdir = Path.join(root, "resume-workdir-#{replacement}")
      moved = workdir <> "-original"
      checkpoint_root = Path.join(root, "resume-checkpoint-#{replacement}")
      private_key = :crypto.strong_rand_bytes(32)
      File.mkdir_p!(workdir)

      graph = compiled_graph!(dot)
      graph_hash = sha256(dot)
      {manifest, digest} = execution_manifest!(graph, graph_hash)

      opts =
        authorized_opts(workdir,
          graph_hash: graph_hash,
          execution_manifest: manifest,
          execution_manifest_digest: digest,
          run_id: "workdir-resume-#{replacement}",
          logs_root: checkpoint_root,
          identity_private_key: private_key,
          resumable: true,
          cache: false
        )

      assert {:ok, _result} = Arbor.Orchestrator.run(dot, opts)
      checkpoint_path = Path.join(checkpoint_root, "checkpoint.json")
      File.rename!(workdir, moved)

      case replacement do
        :symlink -> File.ln_s!(outside, workdir)
        :new_directory -> File.mkdir_p!(workdir)
      end

      result =
        Arbor.Orchestrator.run(
          dot,
          Keyword.put(opts, :resume_from, checkpoint_path)
        )

      case replacement do
        :symlink -> assert {:error, :run_authorization_workdir_not_canonical} = result
        :new_directory -> assert {:error, :run_authorization_mismatch} = result
      end
    end
  end

  defp authorized_opts(root, overrides \\ []) do
    Keyword.merge(
      [
        authorization: true,
        agent_id: "agent_executor",
        caller_id: "agent_executor",
        author_id: "author_pipeline",
        authorizer: fn _principal, _type -> :ok end,
        workdir: root,
        logs_root: Path.join(root, "logs-#{System.unique_integer([:positive])}"),
        resumable: false
      ],
      overrides
    )
  end

  defp use_security(module) do
    Application.put_env(:arbor_orchestrator, :security_module, module)
  end

  defp compiled_graph!(dot) do
    {:ok, graph} = Parser.parse(dot)
    {:ok, compiled} = IRCompiler.compile(graph)
    compiled
  end

  defp execution_manifest!(graph, graph_hash) do
    {:ok, {manifest, digest}} =
      ExecutionManifest.build(graph, %{"actions" => []}, graph_hash)

    {manifest, digest}
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
