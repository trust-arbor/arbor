defmodule Arbor.Orchestrator.Handlers.ToolHandlerTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  if :os.type() != {:unix, :darwin},
    do:
      @moduletag(skip: "native handler mechanics require the qualified macOS containment backend")

  defmodule FilesystemAuthorizer do
    def authorize_filesystem(agent, uri, operation, _capability_id, _opts),
      do: Arbor.Security.authorize(agent, uri, operation, verify_identity: false)
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "handler_containment_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    :ok = File.mkdir(root)
    {:ok, root} = SafePath.resolve_real(root)
    cwd = Path.join(root, "work")
    :ok = File.mkdir(cwd)
    File.write!(Path.join(cwd, "fixture"), "synthetic handler input")
    File.write!(Path.join(root, "outside"), "outside handler data")
    {:ok, identity} = Arbor.Security.generate_identity(name: "synthetic handler containment")
    :ok = Arbor.Security.register_identity(identity)

    {:ok, _} =
      Arbor.Security.grant(principal: identity.agent_id, resource: "arbor://fs/read#{cwd}/**")

    previous = Application.get_env(:arbor_shell, :agent_authorizer)
    Application.put_env(:arbor_shell, :agent_authorizer, FilesystemAuthorizer)
    fixture = %{cwd: cwd, root: root, principal: identity.agent_id}
    Process.put(:shell_fixture, fixture)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_shell, :agent_authorizer),
        else: Application.put_env(:arbor_shell, :agent_authorizer, previous)

      {:ok, caps} = Arbor.Security.list_capabilities(identity.agent_id)
      for cap <- caps, do: Arbor.Security.revoke(cap.id)
      Arbor.Security.deregister_identity(identity.agent_id)
      File.rm_rf!(root)
    end)

    fixture
  end

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ToolHandler

  describe "real shell execution" do
    test "runs a successful command and captures output" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "echo hello"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, authorized_opts(graph, "echo"))

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "hello"
    end

    test "fails on non-zero exit code" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "false"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, authorized_opts(graph, "false"))

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "exited with code"
      assert outcome.context_updates["tool.output"] != nil
    end

    test "captures stderr in output" do
      node = %Node{
        id: "t1",
        attrs: %{
          "tool_command" => "ls /nonexistent_arbor_tool_handler_path"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, authorized_opts(graph, "ls"))

      assert outcome.status == :fail
      assert outcome.context_updates["tool.output"] =~ "nonexistent_arbor_tool_handler_path"
    end

    test "uses immutable workdir instead of context workdir" do
      File.write!(Path.join(Process.get(:shell_fixture).cwd, "marker.txt"), "found")

      node = %Node{id: "t1", attrs: %{"tool_command" => "cat marker.txt"}}
      context = Context.new(%{"workdir" => Process.get(:shell_fixture).cwd})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome =
        ToolHandler.execute(
          node,
          context,
          graph,
          authorized_opts(graph, "cat", Process.get(:shell_fixture).cwd)
        )

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "found"
    end

    test "uses immutable workdir instead of a mutable opts fallback" do
      File.write!(Path.join(Process.get(:shell_fixture).cwd, "opts_marker.txt"), "from_opts")

      node = %Node{id: "t1", attrs: %{"tool_command" => "cat opts_marker.txt"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome =
        ToolHandler.execute(
          node,
          context,
          graph,
          [workdir: "/tmp"] ++ authorized_opts(graph, "cat", Process.get(:shell_fixture).cwd)
        )

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "from_opts"
    end

    test "fails gracefully on missing executable" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "nonexistent_binary_xyz"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, authorized_opts(graph, "echo"))

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "direct-executable policy"
    end

    test "custom tool_command_runner overrides real execution" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "anything"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      runner = fn "anything" -> "custom_output" end
      outcome = ToolHandler.execute(node, context, graph, tool_command_runner: runner)

      assert outcome.status == :success
      assert outcome.context_updates["tool.output"] == "custom_output"
    end
  end

  describe "end-to-end via Orchestrator.run" do
    test "tool node executes real command in pipeline" do
      dot = """
      digraph ToolE2E {
        start [shape=Mdiamond]
        run_cmd [shape=parallelogram, tool_command="echo pipeline_works"]
        done [shape=Msquare]
        start -> run_cmd -> done
      }
      """

      opts = authorized_engine_opts("echo")
      assert {:ok, result} = Arbor.Orchestrator.run(dot, opts)
      assert result.final_outcome.status == :success, inspect(result.final_outcome)
      assert String.trim(result.context["tool.output"]) == "pipeline_works"
    end

    test "tool failure propagates in pipeline" do
      dot = """
      digraph ToolFail {
        start [shape=Mdiamond]
        fail_cmd [shape=parallelogram, tool_command="false"]
        done [shape=Msquare]
        start -> fail_cmd -> done
      }
      """

      opts = authorized_engine_opts("false")
      assert {:ok, result} = Arbor.Orchestrator.run(dot, opts)
      assert result.final_outcome.status == :fail
    end
  end

  describe "direct-executable policy (H3 regression)" do
    test "security regression (H3): dangerous command is rejected by the closed policy" do
      node = %Node{
        id: "rm_attempt",
        attrs: %{
          "tool_command" => "rm -rf /",
          "sandbox" => "basic"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, authorized_opts(graph, "echo"))

      assert outcome.status == :fail,
             "Dangerous command must be rejected by the sandbox — H3 regression. " <>
               "Got: #{inspect(outcome)}"

      assert outcome.failure_reason =~ "direct-executable policy",
             "Failure reason should mention direct policy — got #{inspect(outcome.failure_reason)}"
    end

    test "sandbox=none cannot widen policy but retains a canonical simple command" do
      node = %Node{
        id: "ok",
        attrs: %{
          "tool_command" => ~s(/bin/echo hello),
          "sandbox" => "none"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, authorized_opts(graph, "echo"))

      assert outcome.status == :success
    end
  end

  describe "tool-hook fail-closed policy (H5 regression)" do
    test "security regression (H5): a graph string tool_hooks.pre command never executes" do
      # H5 (codex command-execution.orchestrator-tool-hooks-shell): pre-fix,
      # ToolHooks ran graph-authored hook strings via `/bin/sh -c` with NO
      # sandbox authorization — unlike the tool *command* path (H3). An
      # agent-authored graph could put `rm -rf /` (or any dangerous command)
      # in tool_hooks.pre/post and bypass the gate the command path enforces.
      #
      # Behavioral proof of non-execution: if the historical shell hook executes,
      # the existing sentinel directory is removed.
      sentinel = Path.join(Process.get(:shell_fixture).cwd, "do_not_delete")
      File.mkdir_p!(sentinel)

      node = %Node{
        id: "hook_attack",
        attrs: %{
          "tool_command" => ~s(/bin/echo ran),
          "sandbox" => "basic",
          "tool_hooks.pre" => "rmdir #{sentinel}"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, authorized_opts(graph, "echo"))

      assert File.dir?(sentinel),
             "dangerous tool_hooks.pre command executed — the sandbox gate did not fire (H5 regression). " <>
               "Got outcome: #{inspect(outcome)}"

      # An unavailable pre-hook reports :skip, so the tool itself is skipped too.
      assert outcome.status == :skipped,
             "a sandbox-denied pre-hook must skip the tool — got #{inspect(outcome)}"
    end

    test "a trusted function pre-hook is allowed and the tool proceeds" do
      node = %Node{
        id: "hook_ok",
        attrs: %{
          "tool_command" => ~s(/bin/echo ran),
          "sandbox" => "basic"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome =
        ToolHandler.execute(
          node,
          context,
          graph,
          [tool_hooks: %{pre: fn _payload -> :ok end}] ++ authorized_opts(graph, "echo")
        )

      assert outcome.status == :success,
             "a benign pre-hook must not block the tool — got #{inspect(outcome)}"
    end
  end

  test "security regression: prepared ToolHandler retains immutable filesystem scope", fixture do
    graph = %Graph{id: "contained_tool", nodes: %{}, edges: [], attrs: %{}}
    node = %Node{id: "outside", attrs: %{"tool_command" => "cat #{fixture.root}/outside"}}
    context = Context.new(%{"session.agent_id" => "forged", "workdir" => fixture.root})

    outcome =
      ToolHandler.execute(
        node,
        context,
        graph,
        [workdir: fixture.root] ++ authorized_opts(graph, "cat")
      )

    assert outcome.status == :fail
    refute Map.get(outcome.context_updates, "tool.output", "") =~ "outside handler data"
    inside = %Node{id: "inside", attrs: %{"tool_command" => "cat fixture"}}

    assert %{status: :success} =
             ToolHandler.execute(inside, Context.new(), graph, authorized_opts(graph, "cat"))
  end

  defp authorized_opts(graph, command_name, workdir \\ Process.get(:shell_fixture).cwd) do
    principal = Process.get(:shell_fixture).principal

    {:ok, _} =
      Arbor.Security.grant(principal: principal, resource: "arbor://shell/exec/#{command_name}")

    {:ok, canonical_workdir} = SafePath.resolve_real(workdir)

    {:ok, authority} =
      RunAuthorization.new(%{graph | compiled: true},
        agent_id: principal,
        workdir: canonical_workdir
      )

    [run_authorization: authority]
  end

  defp authorized_engine_opts(command_name) do
    principal = Process.get(:shell_fixture).principal

    {:ok, _} =
      Arbor.Security.grant(principal: principal, resource: "arbor://orchestrator/execute/**")

    {:ok, _} = Arbor.Security.grant(principal: principal, resource: "arbor://shell/exec")

    {:ok, _} =
      Arbor.Security.grant(principal: principal, resource: "arbor://shell/exec/#{command_name}")

    [
      authorization: true,
      execution_principal: principal,
      workdir: Process.get(:shell_fixture).cwd,
      authorizer: fn
        ^principal, type when type in ["exec", "tool"] -> :ok
        _principal, _type -> {:error, :denied}
      end
    ]
  end
end
