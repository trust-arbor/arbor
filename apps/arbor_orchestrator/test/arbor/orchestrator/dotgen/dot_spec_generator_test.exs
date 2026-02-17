defmodule Arbor.Orchestrator.Dotgen.DotSpecGeneratorTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dotgen.DotSpecGenerator

  @simple_pipeline """
  digraph SimplePipeline {
    graph [goal="Process a file and validate output"]
    start [shape=Mdiamond type="start"]
    process [type="codergen" prompt="Process the file" llm_model="claude-sonnet-4-5-20250929"]
    validate [type="codergen" prompt="Validate the output"]
    done [shape=Msquare type="exit"]
    start -> process
    process -> validate
    validate -> done
  }
  """

  @branching_pipeline """
  digraph BranchPipeline {
    graph [goal="Conditional processing based on file type"]
    start [shape=Mdiamond type="start"]
    check [shape=diamond type="conditional"]
    path_a [type="codergen" prompt="Handle text files"]
    path_b [type="codergen" prompt="Handle binary files"]
    merge [type="codergen" prompt="Merge results"]
    done [shape=Msquare type="exit"]
    start -> check
    check -> path_a [condition="outcome=success"]
    check -> path_b [condition="outcome=fail"]
    path_a -> merge
    path_b -> merge
    merge -> done
  }
  """

  describe "generate_from_source/1" do
    test "generates spec from simple pipeline" do
      assert {:ok, spec} = DotSpecGenerator.generate_from_source(@simple_pipeline)
      assert is_binary(spec)
      assert spec =~ "# Pipeline: SimplePipeline"
      assert spec =~ "Process a file"
    end

    test "includes overview section" do
      {:ok, spec} = DotSpecGenerator.generate_from_source(@simple_pipeline)
      assert spec =~ "Overview"
      assert spec =~ "Process a file and validate output"
    end

    test "includes structure section" do
      {:ok, spec} = DotSpecGenerator.generate_from_source(@simple_pipeline)
      assert spec =~ "Structure"
      assert spec =~ "4"
    end

    test "includes node inventory" do
      {:ok, spec} = DotSpecGenerator.generate_from_source(@simple_pipeline)
      assert spec =~ "start"
      assert spec =~ "process"
      assert spec =~ "validate"
      assert spec =~ "done"
    end

    test "includes execution flow" do
      {:ok, spec} = DotSpecGenerator.generate_from_source(@simple_pipeline)
      assert spec =~ "start"
      assert spec =~ "process"
    end

    test "shows handler types" do
      {:ok, spec} = DotSpecGenerator.generate_from_source(@simple_pipeline)
      assert spec =~ "codergen"
    end

    test "returns error for invalid DOT" do
      assert {:error, msg} = DotSpecGenerator.generate_from_source("not valid dot")
      assert msg =~ "Failed to parse"
    end
  end

  describe "generate_from_source/1 with branching" do
    test "detects conditional branches" do
      {:ok, spec} = DotSpecGenerator.generate_from_source(@branching_pipeline)
      assert spec =~ "condition" or spec =~ "Condition"
    end

    test "shows both branch paths" do
      {:ok, spec} = DotSpecGenerator.generate_from_source(@branching_pipeline)
      assert spec =~ "path_a"
      assert spec =~ "path_b"
    end
  end

  describe "generate_from_graph/1" do
    test "produces non-empty string" do
      {:ok, graph} = Arbor.Orchestrator.Dot.Parser.parse(@simple_pipeline)
      spec = DotSpecGenerator.generate_from_graph(graph)
      assert is_binary(spec)
      assert String.length(spec) > 50
    end
  end

  describe "generate_from_file/1" do
    @tag :tmp_dir
    test "reads and generates from file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.dot")
      File.write!(path, @simple_pipeline)

      assert {:ok, spec} = DotSpecGenerator.generate_from_file(path)
      assert spec =~ "SimplePipeline"
    end

    test "returns error for missing file" do
      assert {:error, msg} = DotSpecGenerator.generate_from_file("/nonexistent/path.dot")
      assert msg =~ "Failed to read"
    end
  end

  describe "generate_from_files/2" do
    @tag :tmp_dir
    test "combines specs from multiple files", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "simple.dot")
      path2 = Path.join(tmp_dir, "branch.dot")
      File.write!(path1, @simple_pipeline)
      File.write!(path2, @branching_pipeline)

      assert {:ok, combined} =
               DotSpecGenerator.generate_from_files([path1, path2], title: "My Pipelines")

      assert combined =~ "My Pipelines"
      assert combined =~ "SimplePipeline"
      assert combined =~ "BranchPipeline"
    end

    @tag :tmp_dir
    test "returns error when any file fails", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "good.dot")
      File.write!(path1, @simple_pipeline)

      assert {:error, msg} = DotSpecGenerator.generate_from_files([path1, "/nonexistent.dot"])
      assert msg =~ "Failed"
    end
  end
end
