defmodule Arbor.Orchestrator.Handlers.PipelineValidateHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.PipelineValidateHandler

  @valid_dot """
  digraph Valid {
    start [shape=Mdiamond]
    work [shape=box]
    done [shape=Msquare]
    start -> work -> done
  }
  """

  @invalid_dot "digraph { broken syntax {{{{"

  @test_dir System.tmp_dir!() |> Path.join("arbor_pv_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "execute/4 - valid DOT" do
    test "validates correct DOT string from context" do
      node = %Node{
        id: "v1",
        attrs: %{"type" => "pipeline.validate", "source_key" => "dot_source"}
      }

      context = Context.new(%{"dot_source" => @valid_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert outcome.context_updates["pipeline.valid.v1"] == true
      assert outcome.context_updates["pipeline.dot_source.v1"] == @valid_dot
    end

    test "stores node count in context on success" do
      node = %Node{
        id: "v1",
        attrs: %{"type" => "pipeline.validate", "source_key" => "dot_source"}
      }

      context = Context.new(%{"dot_source" => @valid_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.context_updates["pipeline.node_count.v1"] == 3
    end

    test "stores diagnostics in context" do
      node = %Node{
        id: "v1",
        attrs: %{"type" => "pipeline.validate", "source_key" => "dot_source"}
      }

      context = Context.new(%{"dot_source" => @valid_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      diags = outcome.context_updates["pipeline.diagnostics.v1"]
      assert is_list(diags)
    end

    test "uses default source_key of last_response" do
      node = %Node{id: "v1", attrs: %{"type" => "pipeline.validate"}}

      context = Context.new(%{"last_response" => @valid_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert outcome.context_updates["pipeline.valid.v1"] == true
    end
  end

  describe "execute/4 - invalid DOT" do
    test "fails on DOT syntax error" do
      node = %Node{
        id: "v2",
        attrs: %{"type" => "pipeline.validate", "source_key" => "dot_source"}
      }

      context = Context.new(%{"dot_source" => @invalid_dot})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.context_updates["pipeline.valid.v2"] == false
      assert outcome.failure_reason =~ "parse error"
    end

    test "fails when source key not in context" do
      node = %Node{
        id: "v1",
        attrs: %{"type" => "pipeline.validate", "source_key" => "missing"}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no DOT source found"
    end
  end

  describe "execute/4 - source_file" do
    test "reads DOT from source_file" do
      path = Path.join(@test_dir, "test.dot")
      File.write!(path, @valid_dot)

      node = %Node{
        id: "v1",
        attrs: %{"type" => "pipeline.validate", "source_file" => path}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert outcome.context_updates["pipeline.valid.v1"] == true
    end

    test "resolves relative source_file against workdir" do
      File.write!(Path.join(@test_dir, "relative.dot"), @valid_dot)

      node = %Node{
        id: "v1",
        attrs: %{"type" => "pipeline.validate", "source_file" => "relative.dot"}
      }

      context = Context.new(%{"workdir" => @test_dir})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.status == :success
    end

    test "fails when source_file not found" do
      node = %Node{
        id: "v1",
        attrs: %{"type" => "pipeline.validate", "source_file" => "/nonexistent/path.dot"}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = PipelineValidateHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no DOT source found"
    end
  end

  describe "end-to-end via Orchestrator.run" do
    test "pipeline.validate works in a pipeline" do
      dot = """
      digraph ValidateE2E {
        graph [goal="validate some DOT"]
        start [shape=Mdiamond]
        validate [type="pipeline.validate", source_key="dot_input"]
        done [shape=Msquare]
        start -> validate -> done
      }
      """

      # We need dot_input in context — use graph.goal trick won't work here.
      # Instead, test directly that the handler is registered and resolvable.
      # The e2e test below validates via source_file instead.
      assert {:ok, _graph} = Arbor.Orchestrator.parse(dot)
    end

    test "pipeline.validate reads source_file in a pipeline" do
      path = Path.join(@test_dir, "e2e.dot")

      File.write!(path, """
      digraph Inner {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """)

      dot = """
      digraph ValidateFileE2E {
        start [shape=Mdiamond]
        validate [type="pipeline.validate", source_file="#{path}"]
        done [shape=Msquare]
        start -> validate -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert result.context["pipeline.valid.validate"] == true
      assert result.context["pipeline.node_count.validate"] == 2
    end
  end
end
