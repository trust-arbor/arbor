defmodule Arbor.Orchestrator.Eval.Subjects.SpecToDotTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.Subjects.SpecToDot

  describe "run/2" do
    test "returns simulated DOT when no LLM available" do
      {:ok, dot} = SpecToDot.run("Some spec text", simulate: true)
      assert dot =~ "digraph"
      assert dot =~ "start"
      assert dot =~ "done"
    end

    test "accepts string input" do
      {:ok, dot} = SpecToDot.run("Implement a parser module", simulate: true)
      assert is_binary(dot)
      assert dot =~ "digraph"
    end

    test "accepts map input with subsystem key" do
      input = %{
        "subsystem" => "Parser spec text here",
        "goal" => "Implement the DOT parser",
        "files" => ["lib/parser.ex", "lib/lexer.ex"]
      }

      {:ok, dot} = SpecToDot.run(input, simulate: true)
      assert is_binary(dot)
    end

    test "strips markdown code fences from response" do
      # The extract_dot function should handle fenced responses
      {:ok, dot} = SpecToDot.run("test", simulate: true)
      refute dot =~ "```"
    end

    test "simulated response is parseable" do
      {:ok, dot} = SpecToDot.run("test", simulate: true)
      assert {:ok, _graph} = Arbor.Orchestrator.parse(dot)
    end
  end
end
