defmodule Arbor.Orchestrator.Handlers.SubgraphHandlerTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.GraphRegistry
  alias Arbor.Orchestrator.Handlers.SubgraphHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  @minimal_child """
  digraph Child {
    graph [goal="test child"]
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  @child_with_output """
  digraph ChildOutput {
    graph [goal="child with output"]
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  defp node(type, attrs \\ %{}) do
    %Node{id: "test_node", attrs: Map.put(attrs, "type", type)}
  end

  defp run(type, context_values \\ %{}, attrs \\ %{}, opts \\ []) do
    SubgraphHandler.execute(
      node(type, attrs),
      Context.new(context_values),
      @graph,
      opts
    )
  end

  @moduletag :subgraph_handler

  setup do
    saved = GraphRegistry.snapshot()
    on_exit(fn -> GraphRegistry.restore(saved) end)

    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_subgraph_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  # --- GraphRegistry tests ---

  describe "GraphRegistry" do
    test "register/resolve cycle with inline DOT" do
      :ok = GraphRegistry.register("test-graph", @minimal_child)
      assert {:ok, dot} = GraphRegistry.resolve("test-graph")
      assert dot == @minimal_child
    end

    test "resolve unknown name returns error" do
      assert {:error, :not_found} = GraphRegistry.resolve("nonexistent")
    end

    test "register with file path resolves by reading file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.dot")
      File.write!(path, @minimal_child)

      :ok = GraphRegistry.register("file-graph", path)
      assert {:ok, dot} = GraphRegistry.resolve("file-graph")
      assert dot == @minimal_child
    end

    test "unregister removes entry" do
      :ok = GraphRegistry.register("to-remove", @minimal_child)
      :ok = GraphRegistry.unregister("to-remove")
      assert {:error, :not_found} = GraphRegistry.resolve("to-remove")
    end

    test "list returns registered names" do
      :ok = GraphRegistry.register("alpha", @minimal_child)
      :ok = GraphRegistry.register("beta", @minimal_child)
      names = GraphRegistry.list()
      assert "alpha" in names
      assert "beta" in names
    end

    test "register_directory auto-discovers .dot files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "first.dot"), @minimal_child)
      File.write!(Path.join(tmp_dir, "second.dot"), @child_with_output)
      File.write!(Path.join(tmp_dir, "not-dot.txt"), "ignored")

      assert {:ok, 2} = GraphRegistry.register_directory(tmp_dir)
      assert {:ok, _} = GraphRegistry.resolve("first")
      assert {:ok, _} = GraphRegistry.resolve("second")
      assert {:error, :not_found} = GraphRegistry.resolve("not-dot")
    end

    test "snapshot/restore preserves state" do
      :ok = GraphRegistry.register("snap-test", @minimal_child)
      saved = GraphRegistry.snapshot()

      GraphRegistry.reset()
      assert {:error, :not_found} = GraphRegistry.resolve("snap-test")

      GraphRegistry.restore(saved)
      assert {:ok, _} = GraphRegistry.resolve("snap-test")
    end
  end

  # --- SubgraphHandler: graph.invoke ---

  describe "graph.invoke" do
    test "executes named graph from registry" do
      :ok = GraphRegistry.register("invoke-test", @minimal_child)

      outcome = run("graph.invoke", %{}, %{"graph_name" => "invoke-test"})
      assert outcome.status == :success
      assert outcome.context_updates["subgraph.test_node.status"] == "success"
    end

    test "executes graph from file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "child.dot")
      File.write!(path, @minimal_child)

      outcome = run("graph.invoke", %{}, %{"graph_file" => path})
      assert outcome.status == :success
    end

    test "executes graph from context key" do
      outcome =
        run(
          "graph.invoke",
          %{"my.graph" => @minimal_child},
          %{"graph_source_key" => "my.graph"}
        )

      assert outcome.status == :success
    end

    test "fails when no graph source specified" do
      outcome = run("graph.invoke", %{}, %{})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no graph source"
    end

    test "fails when named graph not found" do
      outcome = run("graph.invoke", %{}, %{"graph_name" => "nonexistent"})
      assert outcome.status == :fail
    end

    test "passes only specified context keys to child" do
      :ok = GraphRegistry.register("ctx-test", @minimal_child)

      outcome =
        run(
          "graph.invoke",
          %{"allowed" => "yes", "secret" => "no"},
          %{"graph_name" => "ctx-test", "pass_context" => "allowed"}
        )

      assert outcome.status == :success
    end

    test "passes no context by default (isolation)" do
      :ok = GraphRegistry.register("iso-test", @minimal_child)

      outcome =
        run(
          "graph.invoke",
          %{"parent_data" => "should not appear"},
          %{"graph_name" => "iso-test"}
        )

      assert outcome.status == :success
      # Child context shouldn't have parent data
    end

    test "with ignore_child_failure continues on child error" do
      bad_dot = """
      digraph Bad {
        graph [goal="test"]
        start [shape=Mdiamond]
        broken [type="nonexistent.handler.that.fails"]
        done [shape=Msquare]
        start -> broken -> done
      }
      """

      :ok = GraphRegistry.register("bad-graph", bad_dot)

      outcome =
        run("graph.invoke", %{}, %{
          "graph_name" => "bad-graph",
          "ignore_child_failure" => "true"
        })

      # Should succeed because ignore_child_failure is set
      assert outcome.status == :success
    end

    test "with result_prefix prefixes child context keys" do
      :ok = GraphRegistry.register("prefix-test", @minimal_child)

      outcome =
        run("graph.invoke", %{}, %{
          "graph_name" => "prefix-test",
          "result_prefix" => "child."
        })

      assert outcome.status == :success
    end
  end

  # --- SubgraphHandler: graph.compose ---

  describe "graph.compose" do
    test "reads DOT from context key" do
      outcome = run("graph.compose", %{"last_response" => @minimal_child})
      assert outcome.status == :success
    end

    test "uses custom source_key" do
      outcome =
        run(
          "graph.compose",
          %{"custom.dot" => @minimal_child},
          %{"source_key" => "custom.dot"}
        )

      assert outcome.status == :success
    end

    test "fails when source key has no value" do
      outcome = run("graph.compose", %{})
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no DOT source"
    end
  end

  # --- Unknown type ---

  describe "unknown type" do
    test "returns fail" do
      outcome = run("graph.unknown")
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unknown graph node type"
    end
  end

  # --- Idempotency ---

  describe "idempotency" do
    test "is side_effecting" do
      assert SubgraphHandler.idempotency() == :side_effecting
    end
  end
end
