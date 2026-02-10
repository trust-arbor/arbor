defmodule Arbor.Orchestrator.Eval.Graders.DotDiffTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.Graders.DotDiff

  @simple_dot """
  digraph T {
    graph [goal="test"]
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  @medium_dot """
  digraph T {
    graph [goal="test pipeline"]
    start [shape=Mdiamond]
    work [prompt="Do some work"]
    check [shape=diamond]
    done [shape=Msquare]
    start -> work -> check -> done
  }
  """

  @full_dot """
  digraph T {
    graph [goal="full pipeline"]
    start [shape=Mdiamond]
    plan [prompt="Plan the implementation"]
    implement [prompt="Write the code", goal_gate=true]
    compile [type="tool", tool_command="mix compile"]
    test [type="tool", tool_command="mix test"]
    review [shape=diamond]
    done [shape=Msquare]
    start -> plan -> implement -> compile -> test -> review
    review -> done [condition="outcome=success"]
    review -> implement [condition="outcome=fail"]
  }
  """

  describe "grade/3" do
    test "identical DOT files score 1.0" do
      result = DotDiff.grade(@simple_dot, @simple_dot)
      assert result.score == 1.0
      assert result.passed == true
    end

    test "identical medium pipelines score 1.0" do
      result = DotDiff.grade(@medium_dot, @medium_dot)
      assert result.score == 1.0
      assert result.passed == true
    end

    test "identical full pipelines score 1.0" do
      result = DotDiff.grade(@full_dot, @full_dot)
      assert result.score == 1.0
      assert result.passed == true
    end

    test "parse error in actual returns 0.0" do
      result = DotDiff.grade("not valid dot", @simple_dot)
      assert result.score == 0.0
      assert result.passed == false
      assert result.detail =~ "Parse error"
    end

    test "parse error in expected returns 0.0" do
      result = DotDiff.grade(@simple_dot, "not valid dot")
      assert result.score == 0.0
      assert result.passed == false
    end

    test "simple vs full pipeline: lower score" do
      result = DotDiff.grade(@simple_dot, @full_dot)
      assert result.score < 0.8
      assert result.detail =~ "nodes:"
      assert result.detail =~ "edges:"
    end

    test "medium vs full pipeline: moderate score" do
      result = DotDiff.grade(@medium_dot, @full_dot)
      assert result.score > 0.2
      assert result.score < 1.0
    end

    test "custom pass_threshold" do
      result = DotDiff.grade(@medium_dot, @full_dot, pass_threshold: 0.1)
      assert result.passed == true

      result2 = DotDiff.grade(@medium_dot, @full_dot, pass_threshold: 0.99)
      assert result2.passed == false
    end

    test "custom weights" do
      # Only weight node count — same graph should be 1.0
      result =
        DotDiff.grade(@full_dot, @full_dot,
          weights: %{node_count: 1.0, edge_count: 0.0, handler_dist: 0.0, keyword_coverage: 0.0}
        )

      assert result.score == 1.0
    end

    test "detail contains all 4 dimensions" do
      result = DotDiff.grade(@full_dot, @full_dot)
      assert result.detail =~ "nodes:"
      assert result.detail =~ "edges:"
      assert result.detail =~ "handlers:"
      assert result.detail =~ "keywords:"
    end

    test "score is always between 0.0 and 1.0" do
      result = DotDiff.grade(@simple_dot, @full_dot)
      assert result.score >= 0.0
      assert result.score <= 1.0
    end

    test "compares real pipeline specs" do
      path = "specs/pipelines/sdlc.dot"

      if File.exists?(path) do
        source = File.read!(path)
        result = DotDiff.grade(source, source)
        assert result.score == 1.0
        assert result.passed == true
      end
    end
  end
end
