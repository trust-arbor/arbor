defmodule Arbor.Orchestrator.Handlers.PipelineRunHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.PipelineRunHandler
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

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

      context = Context.new(%{"workdir" => @test_dir})
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

    test "security regression: in-workdir source symlink cannot read an outside pipeline" do
      outside = @test_dir <> "_outside"
      outside_dot = Path.join(outside, "outside.dot")
      link = Path.join(@test_dir, "escaped.dot")
      File.mkdir_p!(outside)
      File.write!(outside_dot, @child_dot)
      File.ln_s!(outside_dot, link)
      on_exit(fn -> File.rm_rf(outside) end)

      node = %Node{
        id: "symlink_escape",
        attrs: %{"type" => "pipeline.run", "source_file" => "escaped.dot"}
      }

      outcome =
        PipelineRunHandler.execute(
          node,
          Context.new(%{"workdir" => @test_dir}),
          %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}},
          []
        )

      assert outcome.status == :fail
      refute outcome.context_updates["pipeline.ran.symlink_escape"] == true
    end

    test "security regression: source replacement after run authorization is denied" do
      outside = @test_dir <> "_replacement_outside"
      outside_dot = Path.join(outside, "outside.dot")
      source = Path.join(@test_dir, "replaceable.dot")
      graph = compiled_graph!(@child_dot)
      File.mkdir_p!(outside)
      File.write!(outside_dot, @child_dot)
      File.write!(source, @child_dot)

      {:ok, canonical_workdir} = Arbor.Common.SafePath.resolve_real(@test_dir)

      {:ok, authority} =
        RunAuthorization.new(graph,
          agent_id: "agent_pipeline_source",
          workdir: canonical_workdir
        )

      File.rm!(source)
      File.ln_s!(outside_dot, source)
      on_exit(fn -> File.rm_rf(outside) end)

      node = %Node{
        id: "replacement_escape",
        attrs: %{"type" => "pipeline.run", "source_file" => "replaceable.dot"}
      }

      outcome =
        PipelineRunHandler.execute(node, Context.new(), graph, run_authorization: authority)

      assert outcome.status == :fail
      refute outcome.context_updates["pipeline.ran.replacement_escape"] == true
    end

    test "security regression: ancestor replacement during source read discards bytes" do
      source_dir = Path.join(@test_dir, "source_component")
      original_dir = Path.join(@test_dir, "source_component_original")
      outside = @test_dir <> "_read_race_outside"
      source = Path.join(source_dir, "child.dot")

      File.mkdir_p!(source_dir)
      File.mkdir_p!(outside)
      File.write!(source, @child_dot)
      File.write!(Path.join(outside, "child.dot"), @child_dot)
      on_exit(fn -> File.rm_rf(outside) end)

      replace_component = fn _resolved_path ->
        File.rename!(source_dir, original_dir)
        File.ln_s!(outside, source_dir)
      end

      node = %Node{
        id: "component_race",
        attrs: %{"type" => "pipeline.run", "source_file" => "source_component/child.dot"}
      }

      outcome =
        PipelineRunHandler.execute(
          node,
          Context.new(%{"workdir" => @test_dir}),
          %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}},
          source_file_post_read_hook: replace_component
        )

      assert outcome.status == :fail
      assert {:ok, ^outside} = File.read_link(source_dir)
      refute outcome.context_updates["pipeline.ran.component_race"] == true
    end

    test "security regression: opened descriptor defeats a restored-path source double-swap" do
      source_dir = Path.join(@test_dir, "descriptor_source")
      held_dir = Path.join(@test_dir, "descriptor_source_held")
      alternate_dir = Path.join(@test_dir, "descriptor_source_alternate")
      source = Path.join(source_dir, "child.dot")

      File.mkdir_p!(source_dir)
      File.mkdir_p!(alternate_dir)
      File.write!(source, @child_dot)
      File.write!(Path.join(alternate_dir, "child.dot"), @invalid_dot)

      install_alternate = fn _resolved_path ->
        File.rename!(source_dir, held_dir)
        File.rename!(alternate_dir, source_dir)
      end

      restore_original = fn _resolved_path ->
        File.rename!(source_dir, alternate_dir)
        File.rename!(held_dir, source_dir)
      end

      node = %Node{
        id: "descriptor_double_swap",
        attrs: %{"type" => "pipeline.run", "source_file" => "descriptor_source/child.dot"}
      }

      outcome =
        PipelineRunHandler.execute(
          node,
          Context.new(%{"workdir" => @test_dir}),
          %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}},
          source_file_after_open_hook: install_alternate,
          source_file_post_read_hook: restore_original
        )

      assert outcome.status == :success
      assert outcome.context_updates["pipeline.ran.descriptor_double_swap"] == true
      assert File.read!(source) == @child_dot
      assert File.read!(Path.join(alternate_dir, "child.dot")) == @invalid_dot
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

      # P0-3: pipeline.run now requires arbor://pipeline/run. This test
      # exercises the runtime path, not the cap check; opt out explicitly.
      assert {:ok, result} =
               Arbor.Orchestrator.run(dot, authorization: false, workdir: @test_dir)

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

      # P0-3: pipeline.run now requires arbor://pipeline/run; opt out
      # explicitly for this runtime test.
      assert {:ok, result} =
               Arbor.Orchestrator.run(dot, authorization: false, workdir: @test_dir)

      assert result.context["pipeline.valid.validate"] == true
      assert result.context["pipeline.ran.run_it"] == true
      assert result.context["pipeline.child_status.run_it"] == "success"
    end
  end

  defp compiled_graph!(dot) do
    {:ok, graph} = Parser.parse(dot)
    {:ok, compiled} = IRCompiler.compile(graph)
    compiled
  end
end
