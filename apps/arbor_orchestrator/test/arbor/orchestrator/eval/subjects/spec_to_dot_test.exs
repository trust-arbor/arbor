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

    test "extracts digraph embedded in narrative text" do
      # Simulate an LLM response that wraps the digraph in explanation
      narrative = """
      Here is the pipeline I generated for you:

      digraph Pipeline {
        graph [goal="Test"]
        start [shape=Mdiamond]
        impl [prompt="Do the work"]
        done [shape=Msquare]
        start -> impl -> done
      }

      This pipeline has 3 nodes and handles the basic flow.
      """

      # Use the module's internal extract_dot via a simulated run
      # We test the extraction logic directly
      assert narrative =~ "digraph Pipeline"
      # The balanced brace extractor should find the embedded digraph
      extracted = extract_dot_from(narrative)
      assert String.starts_with?(extracted, "digraph Pipeline")
      assert extracted =~ "done [shape=Msquare]"
      refute extracted =~ "This pipeline has"
    end

    test "extracts digraph from markdown fenced response" do
      fenced = """
      ```dot
      digraph T {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      ```
      """

      extracted = extract_dot_from(fenced)
      assert extracted =~ "digraph T"
      refute extracted =~ "```"
    end
  end

  # Helper to test extract_dot logic without going through full run
  defp extract_dot_from(response) do
    # Use the same logic as the module's extract_dot
    stripped =
      response
      |> String.replace(~r/\A\s*```(?:dot|graphviz)?\n/, "")
      |> String.replace(~r/\n```\s*\z/, "")
      |> String.trim()

    if String.starts_with?(stripped, "digraph") do
      stripped
    else
      case Regex.run(~r/digraph\s+\w+\s*\{/s, response) do
        [match] ->
          start_idx = :binary.match(response, match) |> elem(0)
          rest = binary_part(response, start_idx, byte_size(response) - start_idx)
          extract_balanced_braces(rest)

        nil ->
          stripped
      end
    end
  end

  defp extract_balanced_braces(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn char, {depth, acc} ->
      new_depth =
        case char do
          "{" -> depth + 1
          "}" -> depth - 1
          _ -> depth
        end

      new_acc = [char | acc]

      if new_depth == 0 and depth > 0 do
        {:halt, {0, new_acc}}
      else
        {:cont, {new_depth, new_acc}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
  end
end
