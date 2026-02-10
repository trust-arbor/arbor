defmodule Arbor.Orchestrator.Handlers.PipelineRunHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.PipelineRunHandler

  @child_dot """
  digraph Child {
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  @invalid_dot "digraph { broken syntax {{{{"

  @test_dir System.tmp_dir!() |> Path.join("arbor_pr_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "execute/4 - source from context" do
    test "runs child pipeline from context key" do
      node = %Node{
        id: "r1",
        attrs: %{"type" => "pipeline.run", "source_key" => "child_dot"}
      }

      context = Context.new(%{"child_dot" => @child_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert outcome.context_updates["pipeline.ran.r1"] == true
      assert outcome.context_updates["pipeline.child_status.r1"] == "success"
      assert outcome.context_updates["pipeline.child_nodes_completed.r1"] == 2
    end

    test "uses default source_key of last_response" do
      node = %Node{id: "r1", attrs: %{"type" => "pipeline.run"}}

      context = Context.new(%{"last_response" => @child_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert outcome.context_updates["pipeline.ran.r1"] == true
    end

    test "fails on invalid DOT source" do
      node = %Node{
        id: "r1",
        attrs: %{"type" => "pipeline.run", "source_key" => "bad_dot"}
      }

      context = Context.new(%{"bad_dot" => @invalid_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.context_updates["pipeline.ran.r1"] == false
    end

    test "fails when source key not in context" do
      node = %Node{
        id: "r1",
        attrs: %{"type" => "pipeline.run", "source_key" => "missing"}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no DOT source found"
    end
  end

  describe "execute/4 - source from file" do
    test "runs child pipeline from source_file" do
      path = Path.join(@test_dir, "child.dot")
      File.write!(path, @child_dot)

      node = %Node{
        id: "r1",
        attrs: %{"type" => "pipeline.run", "source_file" => path}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert outcome.context_updates["pipeline.ran.r1"] == true
      assert outcome.context_updates["pipeline.child_nodes_completed.r1"] == 2
    end

    test "resolves relative source_file against workdir" do
      File.write!(Path.join(@test_dir, "relative.dot"), @child_dot)

      node = %Node{
        id: "r1",
        attrs: %{"type" => "pipeline.run", "source_file" => "relative.dot"}
      }

      context = Context.new(%{"workdir" => @test_dir})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :success
    end

    test "fails when source_file not found" do
      node = %Node{
        id: "r1",
        attrs: %{"type" => "pipeline.run", "source_file" => "/nonexistent/path.dot"}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no DOT source found"
    end
  end

  describe "execute/4 - child context promotion" do
    test "promotes scalar child context values into parent" do
      # Use a child pipeline with a goal that ends up in context
      child_dot = """
      digraph ChildWithGoal {
        graph [goal="test goal"]
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """

      node = %Node{
        id: "r1",
        attrs: %{"type" => "pipeline.run", "source_key" => "child_dot"}
      }

      context = Context.new(%{"child_dot" => child_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineRunHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      # graph.* keys are NOT promoted (filtered out)
      refute Map.has_key?(outcome.context_updates, "pipeline.child.r1.graph.goal")
    end
  end

  describe "end-to-end via Orchestrator.run" do
    test "pipeline.run executes child from source_file" do
      child_path = Path.join(@test_dir, "inner.dot")

      File.write!(child_path, """
      digraph Inner {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """)

      dot = """
      digraph RunE2E {
        start [shape=Mdiamond]
        run_child [type="pipeline.run", source_file="#{child_path}"]
        done [shape=Msquare]
        start -> run_child -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert result.context["pipeline.ran.run_child"] == true
      assert result.context["pipeline.child_status.run_child"] == "success"
      assert result.context["pipeline.child_nodes_completed.run_child"] == 2
    end

    test "chained validate then run" do
      child_path = Path.join(@test_dir, "validated_child.dot")

      File.write!(child_path, """
      digraph ValidChild {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """)

      dot = """
      digraph ValidateThenRun {
        start [shape=Mdiamond]
        validate [type="pipeline.validate", source_file="#{child_path}"]
        run_it [type="pipeline.run", source_file="#{child_path}"]
        done [shape=Msquare]
        start -> validate -> run_it -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert result.context["pipeline.valid.validate"] == true
      assert result.context["pipeline.ran.run_it"] == true
      assert result.context["pipeline.child_status.run_it"] == "success"
    end
  end
end
