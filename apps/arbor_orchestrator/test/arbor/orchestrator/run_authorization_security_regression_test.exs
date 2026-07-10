defmodule Arbor.Orchestrator.RunAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Orchestrator.Engine.{Context, Executor, RunAuthorization}

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

  test "security regression: authorized remote placement requires a serializable signed lease", %{
    root: root
  } do
    {:ok, graph} =
      Arbor.Orchestrator.parse("""
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

  defp restore(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
