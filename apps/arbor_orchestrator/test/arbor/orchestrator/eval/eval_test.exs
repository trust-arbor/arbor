defmodule Arbor.Orchestrator.EvalTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Eval
  alias Arbor.Orchestrator.Eval.Graders.{Composite, Contains, ExactMatch, JsonValid, RegexMatch}
  alias Arbor.Orchestrator.Eval.Metrics

  describe "grader registry" do
    test "resolves known graders" do
      assert Eval.grader("exact_match") == ExactMatch
      refute Eval.grader("exact_match") == Arbor.Eval.Graders.ExactMatch
      assert Eval.grader("contains") == Contains
      refute Eval.grader("contains") == Arbor.Eval.Graders.Contains
      assert Eval.grader("regex") == RegexMatch
      assert Eval.grader("json_valid") == JsonValid
      assert Eval.grader("dot_diff") == Eval.Graders.DotDiff
      assert Eval.grader("composite") == Composite
      assert Eval.grader("compile_check") == Eval.Graders.CompileCheck
      assert Eval.grader("functional_test") == Eval.Graders.FunctionalTest
      assert Eval.grader("code_quality") == Eval.Graders.CodeQuality
      assert Eval.grader("embedding_similarity") == Eval.Graders.EmbeddingSimilarity
      assert Eval.grader("intent_conformance") == Eval.Graders.IntentConformance
      assert Eval.grader("precision_at_1") == Eval.Graders.PrecisionAt1
      assert Eval.grader("precision_at_5") == Eval.Graders.PrecisionAt5
      assert Eval.grader("recall_at_5") == Eval.Graders.RecallAt5
    end

    test "returns nil for unknown grader" do
      assert Eval.grader("nonexistent") == nil
      assert Eval.grader("Arbor.Eval.Graders.Contains") == nil
      assert Eval.grader(Contains) == nil
    end

    test "lists all grader names" do
      names = Eval.grader_names()
      assert "exact_match" in names
      assert "dot_diff" in names
      # retrieval graders added for the preprocessor tool-retrieval eval
      assert "precision_at_1" in names
      assert "precision_at_5" in names
      assert "recall_at_5" in names
      assert names == Enum.uniq(names)
      assert length(names) == 14
    end

    test "compatibility wrappers delegate to common implementations" do
      cases = [
        {Contains, Arbor.Eval.Graders.Contains, ["hello world", "world", []]},
        {RegexMatch, Arbor.Eval.Graders.RegexMatch, ["hello123", "hello\\d+", []]},
        {JsonValid, Arbor.Eval.Graders.JsonValid, [~s|{"a":1}|, nil, []]},
        {Composite, Arbor.Eval.Graders.Composite,
         [
           "hello world",
           "world",
           [
             graders: [{Contains, 1.0}, {ExactMatch, 1.0}],
             strategy: :any_pass
           ]
         ]},
        {Eval.Graders.PrecisionAt1, Arbor.Eval.Graders.PrecisionAt1,
         [
           ~s|["Arbor.Actions.File"]|,
           %{"primary" => "Arbor.Actions.File", "matches" => ["Arbor.Actions.File"]},
           []
         ]},
        {Eval.Graders.PrecisionAt5, Arbor.Eval.Graders.PrecisionAt5,
         [
           ~s|["Arbor.Actions.File","Other"]|,
           %{"primary" => "Arbor.Actions.File", "matches" => ["Arbor.Actions.File"]},
           []
         ]},
        {Eval.Graders.RecallAt5, Arbor.Eval.Graders.RecallAt5,
         [
           ~s|["Arbor.Actions.File","Arbor.Actions.Shell"]|,
           %{"matches" => ["Arbor.Actions.File", "Arbor.Actions.Shell"]},
           []
         ]},
        {Eval.Graders.PrecisionAtK, Arbor.Eval.Graders.PrecisionAtK,
         [
           ~s|["Arbor.Actions.File"]|,
           %{"primary" => "Arbor.Actions.File", "matches" => ["Arbor.Actions.File"]},
           [k: 1]
         ]},
        {Eval.Graders.RecallAtK, Arbor.Eval.Graders.RecallAtK,
         [
           ~s|["Arbor.Actions.File"]|,
           %{"matches" => ["Arbor.Actions.File"]},
           [k: 1]
         ]}
      ]

      for {compat, canonical, [actual, expected, opts]} <- cases do
        assert compat.grade(actual, expected, opts) ==
                 canonical.grade(actual, expected, opts)
      end
    end

    test "unknown grader names fail closed in run_eval" do
      samples = [%{"id" => "s1", "input" => "hello", "expected" => "hello"}]

      assert [result] =
               Eval.run_eval(samples, Eval.Subjects.Passthrough, [
                 "unknown",
                 "Arbor.Eval.Graders.ExactMatch"
               ])

      assert result["scores"] == []
      assert result["passed"] == true
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

    test "delegates exactly to the common implementation" do
      opts = [trim: true, case_sensitive: false]

      assert ExactMatch.grade(" Hello ", "hello", opts) ==
               Arbor.Eval.Graders.ExactMatch.grade(" Hello ", "hello", opts)
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

    test "delegates every metric to common" do
      results = [
        %{"id" => "sample", "passed" => true, "score" => 1.0},
        %{"id" => "sample", "passed" => false, "score" => 0.0}
      ]

      for {name, opts} <- [{"accuracy", []}, {"mean_score", []}, {"pass_at_k", [k: 2]}] do
        assert Metrics.compute(name, results, opts) ==
                 Arbor.Eval.Metrics.compute(name, results, opts)
      end

      assert Metrics.known_metrics() == Arbor.Eval.Metrics.known_metrics()
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

    test "delegates loading with identical seeded shuffle and generated ids", %{tmp: tmp} do
      path = Path.join(tmp, "compat.jsonl")

      File.write!(path, """
      {"input":"one","expected":"one"}
      invalid
      {"input":"two","expected":"other"}
      {"input":"three","expected":"three"}
      """)

      opts = [shuffle: true, seed: 73, limit: 2]

      assert Eval.load_dataset(path, opts) == Arbor.Eval.Pipeline.load_dataset(path, opts)
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

    test "delegates to common pipeline with compatibility module identities" do
      samples = [
        %{
          "id" => "s1",
          "input" => " Hello ",
          "expected" => "hello",
          "metadata" => %{"source" => "compat"}
        }
      ]

      opts = [trim: true, case_sensitive: false]

      expected =
        Arbor.Eval.Pipeline.run_eval(
          samples,
          Eval.Subjects.Passthrough,
          [ExactMatch],
          opts
        )

      assert Eval.run_eval(samples, Eval.Subjects.Passthrough, ["exact_match"], opts) == expected

      assert Eval.Subjects.Passthrough.run("value", opts) ==
               Arbor.Eval.Subjects.Passthrough.run("value", opts)
    end
  end
end
