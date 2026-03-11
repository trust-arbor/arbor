defmodule Mix.Tasks.Arbor.Pipeline.RunTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  describe "module availability" do
    test "task module is loaded" do
      assert {:module, Mix.Tasks.Arbor.Pipeline.Run} =
               Code.ensure_loaded(Mix.Tasks.Arbor.Pipeline.Run)
    end
  end

  describe "option parsing" do
    test "parses --set options" do
      {opts, _files, _} =
        OptionParser.parse(
          ["test.dot", "--set", "model=claude", "--set", "provider=anthropic"],
          strict: [
            logs_root: :string,
            workdir: :string,
            set: :keep,
            resume: :boolean,
            resume_from: :string
          ]
        )

      set_values = Keyword.get_values(opts, :set)
      assert "model=claude" in set_values
      assert "provider=anthropic" in set_values
    end

    test "parses --logs-root and --workdir" do
      {opts, _files, _} =
        OptionParser.parse(
          ["test.dot", "--logs-root", "/tmp/logs", "--workdir", "/tmp/work"],
          strict: [
            logs_root: :string,
            workdir: :string,
            set: :keep,
            resume: :boolean,
            resume_from: :string
          ]
        )

      assert opts[:logs_root] == "/tmp/logs"
      assert opts[:workdir] == "/tmp/work"
    end

    test "parses --resume flag" do
      {opts, _files, _} =
        OptionParser.parse(
          ["test.dot", "--resume"],
          strict: [
            logs_root: :string,
            workdir: :string,
            set: :keep,
            resume: :boolean,
            resume_from: :string
          ]
        )

      assert opts[:resume] == true
    end

    test "parses --resume-from path" do
      {opts, _files, _} =
        OptionParser.parse(
          ["test.dot", "--resume-from", "/tmp/checkpoint.json"],
          strict: [
            logs_root: :string,
            workdir: :string,
            set: :keep,
            resume: :boolean,
            resume_from: :string
          ]
        )

      assert opts[:resume_from] == "/tmp/checkpoint.json"
    end

    test "separates file args from options" do
      {_opts, files, _} =
        OptionParser.parse(
          ["my_pipeline.dot", "--set", "x=1"],
          strict: [
            logs_root: :string,
            workdir: :string,
            set: :keep,
            resume: :boolean,
            resume_from: :string
          ]
        )

      assert files == ["my_pipeline.dot"]
    end
  end

  describe "orchestrator parse integration" do
    test "orchestrator module is available" do
      assert Code.ensure_loaded?(Arbor.Orchestrator)
    end

    test "orchestrator exposes parse function" do
      assert function_exported?(Arbor.Orchestrator, :parse, 1)
    end

    test "parser can parse minimal DOT" do
      dot = """
      digraph test {
        start [type="start"];
        finish [type="exit"];
        start -> finish;
      }
      """

      assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
      assert map_size(graph.nodes) >= 2
    end
  end
end
