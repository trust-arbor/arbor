defmodule Arbor.Orchestrator.Handlers.ShellHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ShellHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp make_node(id, attrs) do
    # Tests run without Arbor.Shell — use sandbox="none" to allow direct execution.
    # In production, sandbox defaults to "basic" and requires Arbor.Shell.
    %Node{id: id, attrs: Map.merge(%{"type" => "shell", "sandbox" => "none"}, attrs)}
  end

  describe "execute/4" do
    test "runs a simple command" do
      node = make_node("echo_test", %{"command" => "echo hello"})
      context = Context.new()

      assert %Outcome{status: :success} = ShellHandler.execute(node, context, @graph, [])
    end

    test "captures command output in context" do
      node = make_node("echo_test", %{"command" => "echo hello_world"})
      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert String.contains?(outcome.context_updates["last_response"], "hello_world")
      assert outcome.context_updates["shell.echo_test.exit_code"] == 0
    end

    test "fails on non-zero exit code by default" do
      node = make_node("fail_test", %{"command" => "sh -c 'exit 1'"})
      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :fail
      assert outcome.context_updates["shell.fail_test.exit_code"] == 1
    end

    test "on_error=warn returns success with warning" do
      node = make_node("warn_test", %{"command" => "sh -c 'exit 1'", "on_error" => "warn"})
      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert String.contains?(outcome.notes, "code 1")
    end

    test "on_error=continue returns success" do
      node =
        make_node("continue_test", %{"command" => "sh -c 'exit 42'", "on_error" => "continue"})

      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert outcome.context_updates["shell.continue_test.exit_code"] == 42
    end

    test "missing command fails" do
      node = make_node("no_cmd", %{})
      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "requires 'command'")
    end

    test "respects cwd from node attribute" do
      node = make_node("cwd_test", %{"command" => "pwd", "cwd" => "/tmp"})
      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      # /tmp may resolve to /private/tmp on macOS
      assert String.contains?(outcome.context_updates["last_response"], "tmp")
    end

    test "respects cwd from context workdir" do
      node = make_node("cwd_ctx", %{"command" => "pwd"})
      context = Context.new(%{"workdir" => "/tmp"})

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert String.contains?(outcome.context_updates["last_response"], "tmp")
    end

    test "timeout produces error" do
      node = make_node("timeout_test", %{"command" => "sleep 10", "timeout" => "100"})
      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "timeout")
    end

    test "output with multiple lines captured" do
      # Use a single command that produces multi-line output
      node = make_node("multi", %{"command" => "ls /tmp"})
      context = Context.new()

      outcome = ShellHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      output = outcome.context_updates["last_response"]
      assert String.length(output) > 0
    end
  end

  describe "idempotency/0" do
    test "returns :side_effecting" do
      assert ShellHandler.idempotency() == :side_effecting
    end
  end

  describe "registry" do
    test "shell type resolves to ExecHandler (Phase 4 delegation)" do
      node = make_node("reg_test", %{})

      assert Arbor.Orchestrator.Handlers.Registry.resolve(node) ==
               Arbor.Orchestrator.Handlers.ExecHandler
    end

    test "shell type injects target attribute via resolve_with_attrs" do
      node = make_node("reg_test", %{})
      {handler, resolved_node} = Arbor.Orchestrator.Handlers.Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ExecHandler
      assert resolved_node.attrs["target"] == "shell"
    end
  end
end
