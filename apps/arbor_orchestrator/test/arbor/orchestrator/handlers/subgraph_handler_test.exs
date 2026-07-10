defmodule Arbor.Orchestrator.Handlers.SubgraphHandlerTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.GraphRegistry
  alias Arbor.Orchestrator.Handlers.SubgraphHandler
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

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

  defp node(type, attrs) do
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

  describe "taint inheritance across the subgraph boundary (taint-rebuild Phase 3)" do
    test "subgraph outputs inherit the provenance of passed-in keys" do
      :ok = GraphRegistry.register("taint-child", @minimal_child)

      # Parent has an :untrusted key that it passes into the child. Without
      # boundary inheritance the subgraph node's outputs would be unlabeled
      # (fail-open) and a downstream parent control sink would not be gated.
      parent_ctx =
        Context.new(%{"secret" => "x"})
        |> Context.record_output_taint(["secret"], :untrusted)

      outcome =
        SubgraphHandler.execute(
          node("graph.invoke", %{"graph_name" => "taint-child", "pass_context" => "secret"}),
          parent_ctx,
          @graph,
          []
        )

      assert outcome.status == :success
      assert outcome.output_taint.level == :untrusted
    end

    test "no passed-in taint leaves the subgraph outputs unlabeled" do
      :ok = GraphRegistry.register("taint-child2", @minimal_child)

      parent_ctx = Context.new(%{"plain" => "x"})

      outcome =
        SubgraphHandler.execute(
          node("graph.invoke", %{"graph_name" => "taint-child2", "pass_context" => "plain"}),
          parent_ctx,
          @graph,
          []
        )

      assert outcome.status == :success
      assert outcome.output_taint == nil
    end
  end

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

      outcome = run("graph.invoke", %{"workdir" => tmp_dir}, %{"graph_file" => path})
      assert outcome.status == :success
    end

    test "security regression: in-workdir graph symlink cannot read outside", %{tmp_dir: tmp_dir} do
      outside = tmp_dir <> "_outside"
      outside_dot = Path.join(outside, "outside.dot")
      link = Path.join(tmp_dir, "escaped.dot")
      File.mkdir_p!(outside)
      File.write!(outside_dot, @minimal_child)
      File.ln_s!(outside_dot, link)
      on_exit(fn -> File.rm_rf(outside) end)

      outcome =
        run(
          "graph.invoke",
          %{"workdir" => tmp_dir},
          %{"graph_file" => "escaped.dot"}
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "path_traversal"
    end

    test "security regression: graph source replacement after authorization is denied", %{
      tmp_dir: tmp_dir
    } do
      outside = tmp_dir <> "_replacement_outside"
      outside_dot = Path.join(outside, "outside.dot")
      source = Path.join(tmp_dir, "replaceable.dot")
      File.mkdir_p!(outside)
      File.write!(outside_dot, @minimal_child)
      File.write!(source, @minimal_child)

      {:ok, canonical_workdir} = Arbor.Common.SafePath.resolve_real(tmp_dir)

      {:ok, authority} =
        RunAuthorization.new(compiled_graph!(@minimal_child),
          agent_id: "agent_subgraph_source",
          workdir: canonical_workdir
        )

      File.rm!(source)
      File.ln_s!(outside_dot, source)
      on_exit(fn -> File.rm_rf(outside) end)

      outcome =
        run(
          "graph.invoke",
          %{},
          %{"graph_file" => "replaceable.dot"},
          run_authorization: authority
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "path_traversal"
    end

    test "security regression: ancestor replacement during graph read discards bytes", %{
      tmp_dir: tmp_dir
    } do
      source_dir = Path.join(tmp_dir, "source_component")
      original_dir = Path.join(tmp_dir, "source_component_original")
      outside = tmp_dir <> "_read_race_outside"
      source = Path.join(source_dir, "child.dot")

      File.mkdir_p!(source_dir)
      File.mkdir_p!(outside)
      File.write!(source, @minimal_child)
      File.write!(Path.join(outside, "child.dot"), @minimal_child)
      on_exit(fn -> File.rm_rf(outside) end)

      replace_component = fn _resolved_path ->
        File.rename!(source_dir, original_dir)
        File.ln_s!(outside, source_dir)
      end

      outcome =
        run(
          "graph.invoke",
          %{"workdir" => tmp_dir},
          %{"graph_file" => "source_component/child.dot"},
          source_file_post_read_hook: replace_component
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "source_file_changed_during_read"
      assert {:ok, ^outside} = File.read_link(source_dir)
    end

    test "security regression: opened descriptor defeats a restored-path graph double-swap", %{
      tmp_dir: tmp_dir
    } do
      source_dir = Path.join(tmp_dir, "descriptor_source")
      held_dir = Path.join(tmp_dir, "descriptor_source_held")
      alternate_dir = Path.join(tmp_dir, "descriptor_source_alternate")
      source = Path.join(source_dir, "child.dot")
      alternate_source = Path.join(alternate_dir, "child.dot")
      alternate_dot = "digraph { broken syntax {{{{"

      File.mkdir_p!(source_dir)
      File.mkdir_p!(alternate_dir)
      File.write!(source, @minimal_child)
      File.write!(alternate_source, alternate_dot)

      install_alternate = fn _resolved_path ->
        File.rename!(source_dir, held_dir)
        File.rename!(alternate_dir, source_dir)
      end

      restore_original = fn _resolved_path ->
        File.rename!(source_dir, alternate_dir)
        File.rename!(held_dir, source_dir)
      end

      outcome =
        run(
          "graph.invoke",
          %{"workdir" => tmp_dir},
          %{"graph_file" => "descriptor_source/child.dot"},
          source_file_after_open_hook: install_alternate,
          source_file_post_read_hook: restore_original
        )

      assert outcome.status == :success
      assert outcome.context_updates["subgraph.test_node.status"] == "success"
      assert File.read!(source) == @minimal_child
      assert File.read!(alternate_source) == alternate_dot
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

  defp compiled_graph!(dot) do
    {:ok, graph} = Parser.parse(dot)
    {:ok, compiled} = IRCompiler.compile(graph)
    compiled
  end
end
