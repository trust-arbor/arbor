defmodule Arbor.Orchestrator.EvalTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval
  alias Arbor.Orchestrator.Eval.Graders.{ExactMatch, Contains, RegexMatch, JsonValid, Composite}
  alias Arbor.Orchestrator.Eval.Metrics

  describe "grader registry" do
    test "resolves known graders" do
      assert Eval.grader("exact_match") == ExactMatch
      assert Eval.grader("contains") == Contains
      assert Eval.grader("regex") == RegexMatch
      assert Eval.grader("json_valid") == JsonValid
      assert Eval.grader("dot_diff") == Eval.Graders.DotDiff
      assert Eval.grader("composite") == Composite
    end

    test "returns nil for unknown grader" do
      assert Eval.grader("nonexistent") == nil
    end

    test "lists all grader names" do
      names = Eval.grader_names()
      assert "exact_match" in names
      assert "dot_diff" in names
      assert length(names) == 10
    end
  end

  describe "ExactMatch grader" do
    test "exact match passes" do
      result = ExactMatch.grade("hello", "hello")
      assert result.score == 1.0
      assert result.passed == true
    end

    test "mismatch fails" do
      result = ExactMatch.grade("hello", "world")
      assert result.score == 0.0
      assert result.passed == false
    end

    test "case insensitive option" do
      result = ExactMatch.grade("Hello", "hello", case_sensitive: false)
      assert result.passed == true
    end

    test "trim option" do
      result = ExactMatch.grade("  hello  ", "hello", trim: true)
      assert result.passed == true
    end
  end

  describe "Contains grader" do
    test "substring found passes" do
      result = Contains.grade("hello world", "world")
      assert result.passed == true
    end

    test "substring not found fails" do
      result = Contains.grade("hello world", "xyz")
      assert result.passed == false
    end

    test "case insensitive" do
      result = Contains.grade("Hello World", "hello", case_sensitive: false)
      assert result.passed == true
    end
  end

  describe "RegexMatch grader" do
    test "pattern match passes" do
      result = RegexMatch.grade("hello123", "hello\\d+")
      assert result.passed == true
    end

    test "no match fails" do
      result = RegexMatch.grade("hello", "\\d+")
      assert result.passed == false
    end

    test "invalid regex" do
      result = RegexMatch.grade("hello", "[invalid")
      assert result.passed == false
      assert result.detail =~ "invalid regex"
    end

    test "flags option" do
      result = RegexMatch.grade("HELLO", "hello", flags: "i")
      assert result.passed == true
    end
  end

  describe "JsonValid grader" do
    test "valid JSON passes" do
      result = JsonValid.grade(~s|{"key": "value"}|, "")
      assert result.passed == true
    end

    test "invalid JSON fails" do
      result = JsonValid.grade("not json", "")
      assert result.passed == false
    end

    test "valid JSON array" do
      result = JsonValid.grade("[1, 2, 3]", "")
      assert result.passed == true
    end
  end

  describe "Composite grader" do
    test "weighted average of two graders" do
      result =
        Composite.grade("hello", "hello",
          graders: [
            {ExactMatch, 1.0},
            {Contains, 1.0}
          ],
          strategy: :weighted_avg
        )

      assert result.score == 1.0
      assert result.passed == true
    end

    test "all_pass strategy" do
      result =
        Composite.grade("hello", "world",
          graders: [
            {ExactMatch, 1.0},
            {Contains, 1.0}
          ],
          strategy: :all_pass
        )

      assert result.passed == false
    end

    test "any_pass strategy" do
      result =
        Composite.grade("hello world", "world",
          graders: [
            {ExactMatch, 1.0},
            {Contains, 1.0}
          ],
          strategy: :any_pass
        )

      assert result.passed == true
    end
  end

  describe "Metrics" do
    test "accuracy computation" do
      results = [
        %{"passed" => true, "score" => 1.0},
        %{"passed" => true, "score" => 1.0},
        %{"passed" => false, "score" => 0.0}
      ]

      assert_in_delta Metrics.compute("accuracy", results, []), 0.6667, 0.01
    end

    test "mean_score computation" do
      results = [
        %{"score" => 1.0},
        %{"score" => 0.5},
        %{"score" => 0.0}
      ]

      assert Metrics.compute("mean_score", results, []) == 0.5
    end

    test "empty results" do
      assert Metrics.compute("accuracy", [], []) == 0.0
      assert Metrics.compute("mean_score", [], []) == 0.0
    end

    test "known_metrics" do
      assert "accuracy" in Metrics.known_metrics()
      assert "mean_score" in Metrics.known_metrics()
      assert "pass_at_k" in Metrics.known_metrics()
    end
  end

  describe "load_dataset/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "eval_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, tmp: tmp}
    end

    test "loads JSONL file", %{tmp: tmp} do
      path = Path.join(tmp, "test.jsonl")

      File.write!(path, """
      {"id": "s1", "input": "hello", "expected": "hello"}
      {"id": "s2", "input": "world", "expected": "earth"}
      """)

      {:ok, samples} = Eval.load_dataset(path)
      assert length(samples) == 2
      assert hd(samples)["id"] == "s1"
    end

    test "limit option", %{tmp: tmp} do
      path = Path.join(tmp, "test.jsonl")

      lines =
        Enum.map(1..10, fn i -> ~s|{"id": "s#{i}", "input": "i#{i}", "expected": "e#{i}"}| end)

      File.write!(path, Enum.join(lines, "\n"))

      {:ok, samples} = Eval.load_dataset(path, limit: 3)
      assert length(samples) == 3
    end

    test "missing file returns error" do
      assert {:error, _} = Eval.load_dataset("/nonexistent/path.jsonl")
    end
  end

  describe "run_eval/4" do
    test "evaluates samples with passthrough subject" do
      samples = [
        %{"id" => "s1", "input" => "hello", "expected" => "hello"},
        %{"id" => "s2", "input" => "world", "expected" => "earth"}
      ]

      results = Eval.run_eval(samples, Eval.Subjects.Passthrough, ["exact_match"])
      assert length(results) == 2

      [r1, r2] = results
      assert r1["passed"] == true
      assert r2["passed"] == false
    end
  end
end
