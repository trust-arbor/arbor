defmodule Arbor.Eval.GradersTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval

  alias Arbor.Eval.Graders.{
    CodeQuality,
    CompileCheck,
    Composite,
    Contains,
    ExactMatch,
    FunctionalTest,
    JsonValid,
    PrecisionAt1,
    PrecisionAt5,
    PrecisionAtK,
    RecallAt5,
    RecallAtK,
    RegexMatch
  }

  @catalog_names [
    "exact_match",
    "contains",
    "regex",
    "json_valid",
    "composite",
    "compile_check",
    "functional_test",
    "code_quality",
    "precision_at_1",
    "precision_at_5",
    "recall_at_5"
  ]

  describe "closed grader catalog" do
    test "exposes established public names and resolves to canonical modules" do
      assert Enum.sort(Eval.grader_names()) == Enum.sort(@catalog_names)

      assert Eval.grader("exact_match") == ExactMatch
      assert Eval.grader("contains") == Contains
      assert Eval.grader("regex") == RegexMatch
      assert Eval.grader("json_valid") == JsonValid
      assert Eval.grader("composite") == Composite
      assert Eval.grader("compile_check") == CompileCheck
      assert Eval.grader("functional_test") == FunctionalTest
      assert Eval.grader("code_quality") == CodeQuality
      assert Eval.grader("precision_at_1") == PrecisionAt1
      assert Eval.grader("precision_at_5") == PrecisionAt5
      assert Eval.grader("recall_at_5") == RecallAt5
    end

    test "fails closed for unknown or module-like names" do
      assert Eval.grader("nonexistent") == nil
      assert Eval.grader("precision_at_k") == nil
      assert Eval.grader("recall_at_k") == nil
      assert Eval.grader("dot_diff") == nil
      assert Eval.grader("embedding_similarity") == nil
      assert Eval.grader("intent_conformance") == nil
      assert Eval.grader("Arbor.Eval.Graders.Contains") == nil
      assert Eval.grader(Contains) == nil
      assert Eval.grader("Arbor.Orchestrator.Eval.Graders.ExactMatch") == nil
    end
  end

  describe "deterministic grader parity" do
    test "Contains, RegexMatch, JsonValid, and Composite preserve scoring" do
      assert Contains.grade("hello world", "world") ==
               %{score: 1.0, passed: true, detail: "all 1 keywords found"}

      assert Contains.grade("hello world", "xyz").passed == false

      assert RegexMatch.grade("hello123", "hello\\d+") ==
               %{score: 1.0, passed: true, detail: "regex match"}

      assert RegexMatch.grade("hello", "[invalid").passed == false

      assert JsonValid.grade(~s|{"a":1}|, nil) ==
               %{score: 1.0, passed: true, detail: "valid JSON"}

      assert JsonValid.grade("not-json", nil).passed == false

      composite =
        Composite.grade("hello world", "world",
          graders: [{ExactMatch, 1.0}, {Contains, 1.0}],
          strategy: :any_pass
        )

      assert composite.passed == true
      assert composite.score == 0.5
    end

    test "retrieval graders compute precision and recall at k" do
      ranked = ~s|["Arbor.Actions.File","Arbor.Actions.Shell","Other"]|

      expected = %{
        "primary" => "Arbor.Actions.File",
        "matches" => ["Arbor.Actions.File", "Arbor.Actions.Shell"]
      }

      assert PrecisionAt1.grade(ranked, expected) ==
               PrecisionAtK.grade(ranked, expected, k: 1)

      assert PrecisionAt1.grade(ranked, expected).score == 1.0

      assert PrecisionAt5.grade(ranked, expected) ==
               PrecisionAtK.grade(ranked, expected, k: 5)

      assert PrecisionAt5.grade(ranked, expected).score == 1.0

      assert RecallAt5.grade(ranked, expected) ==
               RecallAtK.grade(ranked, expected, k: 5)

      assert RecallAt5.grade(ranked, expected).score == 1.0
      assert RecallAtK.grade([], expected).passed == false
    end

    test "CompileCheck extract_code is pure and catalog-wired" do
      fenced = "```elixir\ndefmodule Foo do\n  def bar, do: :ok\nend\n```"
      assert CompileCheck.extract_code(fenced) == "defmodule Foo do\n  def bar, do: :ok\nend"
      assert Eval.grader("compile_check") == CompileCheck
      assert Eval.grader("functional_test") == FunctionalTest
      assert Eval.grader("code_quality") == CodeQuality
    end
  end

  describe "catalog-selected pipeline grading" do
    test "runs contains through the closed string catalog" do
      samples = [
        %{"id" => "s1", "input" => "hello world", "expected" => "world"},
        %{"id" => "s2", "input" => "hello world", "expected" => "missing"}
      ]

      [pass, fail] = Eval.run_eval(samples, "passthrough", ["contains"])
      assert pass["passed"] == true
      assert fail["passed"] == false
    end

    test "unknown grader names remain ignored rather than resolved from modules" do
      samples = [%{"id" => "s1", "input" => "x", "expected" => "y"}]

      assert [result] =
               Eval.run_eval(samples, "passthrough", [
                 "unknown",
                 "Arbor.Eval.Graders.Contains",
                 "dot_diff"
               ])

      assert result["scores"] == []
      assert result["passed"] == true
    end
  end
end
