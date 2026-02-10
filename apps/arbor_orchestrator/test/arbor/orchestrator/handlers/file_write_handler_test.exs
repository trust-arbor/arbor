defmodule Arbor.Orchestrator.Handlers.FileWriteHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.FileWriteHandler

  @test_dir System.tmp_dir!() |> Path.join("arbor_file_write_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "execute/4 - basic writes" do
    test "writes string content from context to file" do
      path = Path.join(@test_dir, "output.txt")

      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "content_key" => "data", "output" => path}
      }

      context = Context.new(%{"data" => "hello world"})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert File.read!(path) == "hello world"
      assert outcome.context_updates["file.written.w1"] == path
      assert outcome.notes =~ "11 bytes"
    end

    test "writes JSON-formatted content" do
      path = Path.join(@test_dir, "output.json")

      node = %Node{
        id: "w1",
        attrs: %{
          "type" => "file.write",
          "content_key" => "data",
          "output" => path,
          "format" => "json"
        }
      }

      context = Context.new(%{"data" => %{"key" => "value", "num" => 42}})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      parsed = Jason.decode!(File.read!(path))
      assert parsed["key"] == "value"
      assert parsed["num"] == 42
    end

    test "appends to existing file" do
      path = Path.join(@test_dir, "append.txt")
      File.write!(path, "line1\n")

      node = %Node{
        id: "w1",
        attrs: %{
          "type" => "file.write",
          "content_key" => "data",
          "output" => path,
          "append" => "true"
        }
      }

      context = Context.new(%{"data" => "line2\n"})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert File.read!(path) == "line1\nline2\n"
    end

    test "creates parent directories automatically" do
      path = Path.join(@test_dir, "sub/dir/file.txt")

      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "content_key" => "data", "output" => path}
      }

      context = Context.new(%{"data" => "nested content"})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert File.read!(path) == "nested content"
    end
  end

  describe "execute/4 - path resolution" do
    test "resolves relative paths against workdir from context" do
      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "content_key" => "data", "output" => "relative.txt"}
      }

      context = Context.new(%{"data" => "relative content", "workdir" => @test_dir})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert File.read!(Path.join(@test_dir, "relative.txt")) == "relative content"
    end

    test "resolves relative paths against workdir from opts" do
      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "content_key" => "data", "output" => "from_opts.txt"}
      }

      context = Context.new(%{"data" => "opts content"})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, workdir: @test_dir)

      assert outcome.status == :success
      assert File.read!(Path.join(@test_dir, "from_opts.txt")) == "opts content"
    end

    test "resolves absolute paths directly" do
      abs_path = Path.join(@test_dir, "absolute.txt")

      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "content_key" => "data", "output" => abs_path}
      }

      context = Context.new(%{"data" => "absolute content"})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert File.read!(abs_path) == "absolute content"
    end
  end

  describe "execute/4 - error cases" do
    test "fails when content_key not specified" do
      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "output" => "out.txt"}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "content_key"
    end

    test "fails when output not specified" do
      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "content_key" => "data"}
      }

      context = Context.new(%{"data" => "content"})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "output"
    end

    test "fails when content_key not in context" do
      path = Path.join(@test_dir, "missing.txt")

      node = %Node{
        id: "w1",
        attrs: %{"type" => "file.write", "content_key" => "missing", "output" => path}
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = FileWriteHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "missing"
    end
  end

  describe "end-to-end via Orchestrator.run" do
    test "file.write handler writes graph goal to file" do
      path = Path.join(@test_dir, "e2e.txt")

      dot = """
      digraph FileWriteE2E {
        graph [goal="end-to-end works"]
        start [shape=Mdiamond]
        write [type="file.write", content_key="graph.goal", output="#{path}"]
        done [shape=Msquare]
        start -> write -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert result.context["file.written.write"] == path
      assert File.read!(path) == "end-to-end works"
    end

    test "file.write resolves relative path via workdir opt" do
      dot = """
      digraph FileWriteWorkdir {
        graph [goal="workdir test"]
        start [shape=Mdiamond]
        write [type="file.write", content_key="graph.goal", output="workdir_out.txt"]
        done [shape=Msquare]
        start -> write -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot, workdir: @test_dir)
      assert result.context["workdir"] == @test_dir
      assert File.read!(Path.join(@test_dir, "workdir_out.txt")) == "workdir test"
    end

    test "graph.label is mirrored into context" do
      dot = """
      digraph LabelMirror {
        graph [goal="g", label="My Pipeline"]
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert result.context["graph.label"] == "My Pipeline"
    end
  end
end
