defmodule Arbor.Orchestrator.Handlers.ToolHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ToolHandler

  @test_dir System.tmp_dir!() |> Path.join("arbor_tool_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "real shell execution" do
    test "runs a successful command and captures output" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "echo hello"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "hello"
    end

    test "fails on non-zero exit code" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "false"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "exited with code"
      assert outcome.context_updates["tool.output"] != nil
    end

    test "captures stderr in output" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "bash -c 'echo error >&2'"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "error"
    end

    test "uses workdir from context" do
      File.write!(Path.join(@test_dir, "marker.txt"), "found")

      node = %Node{id: "t1", attrs: %{"tool_command" => "cat marker.txt"}}
      context = Context.new(%{"workdir" => @test_dir})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "found"
    end

    test "uses workdir from opts as fallback" do
      File.write!(Path.join(@test_dir, "opts_marker.txt"), "from_opts")

      node = %Node{id: "t1", attrs: %{"tool_command" => "cat opts_marker.txt"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, workdir: @test_dir)

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "from_opts"
    end

    test "fails gracefully on missing executable" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "nonexistent_binary_xyz"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "error"
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

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
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

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert result.final_outcome.status == :fail
    end
  end
end
