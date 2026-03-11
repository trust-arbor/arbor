defmodule Arbor.Orchestrator.Middleware.SafeInputTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.{SafeInput, Token}

  defp make_token(attrs, assigns \\ %{}) do
    node = %Node{id: "safe_node", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{"safe_node" => node}, edges: [], attrs: %{}}
    %Token{node: node, context: context, graph: graph, assigns: assigns}
  end

  # --- skip conditions ---

  describe "before_node/1 skip conditions" do
    test "passes through when skip_safe_input is set" do
      token = make_token(%{"graph_file" => "../../../etc/passwd"}, %{skip_safe_input: true})
      result = SafeInput.before_node(token)
      refute result.halted
    end
  end

  # --- path traversal detection ---

  describe "path traversal detection" do
    test "halts for graph_file with .." do
      token = make_token(%{"graph_file" => "../../../etc/passwd"})
      result = SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "path traversal"
    end

    test "halts for source_file with .." do
      token = make_token(%{"source_file" => "../../../../secret"})
      result = SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "path traversal"
    end

    test "halts for cwd with .." do
      token = make_token(%{"cwd" => "/home/user/../../../root"})
      result = SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "path traversal"
    end

    test "halts for workdir with .." do
      token = make_token(%{"workdir" => "foo/../../bar"})
      result = SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "path traversal"
    end

    test "halts for embedded .. in middle of path" do
      token = make_token(%{"graph_file" => "/safe/path/../../../etc/shadow"})
      result = SafeInput.before_node(token)
      assert result.halted
    end

    test "includes attribute name in error message" do
      token = make_token(%{"graph_file" => "../exploit"})
      result = SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "graph_file"
    end

    test "reports multiple path violations" do
      token =
        make_token(%{
          "graph_file" => "../bad1",
          "source_file" => "../bad2"
        })

      result = SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "graph_file"
      assert result.halt_reason =~ "source_file"
    end

    test "outcome has fail status on path traversal" do
      token = make_token(%{"graph_file" => "../exploit"})
      result = SafeInput.before_node(token)
      assert result.outcome.status == :fail
      assert result.outcome.failure_reason =~ "Safe input validation"
    end
  end

  # --- safe paths ---

  describe "safe paths pass through" do
    test "absolute path without traversal" do
      token = make_token(%{"graph_file" => "/Users/test/project/graph.dot"})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "relative path without traversal" do
      token = make_token(%{"source_file" => "src/main.ex"})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "path with dots in filename (not traversal)" do
      token = make_token(%{"graph_file" => "/path/to/file.dot.bak"})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "empty path attributes" do
      # Non-path attrs should not trigger validation
      token = make_token(%{"prompt" => "hello world", "model" => "claude"})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "nil path attributes are skipped" do
      token = make_token(%{"graph_file" => nil})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "no path attributes at all" do
      token = make_token(%{})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "multiple safe paths all pass" do
      token =
        make_token(%{
          "graph_file" => "/safe/graph.dot",
          "source_file" => "/safe/main.ex",
          "cwd" => "/home/user/project",
          "workdir" => "/tmp/work"
        })

      result = SafeInput.before_node(token)
      refute result.halted
    end
  end
end
