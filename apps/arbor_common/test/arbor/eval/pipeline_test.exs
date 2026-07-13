defmodule Arbor.Eval.PipelineTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval
  alias Arbor.Eval.{Graders.ExactMatch, Pipeline, Subjects.Passthrough}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "common_eval_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "closed pipeline catalogs" do
    test "expose symbolic passthrough and the established public grader names" do
      assert Eval.subject_names() == ["passthrough"]
      assert Eval.subject("passthrough") == Passthrough
      assert Eval.grader("exact_match") == ExactMatch
      assert "contains" in Eval.grader_names()
      assert "regex" in Eval.grader_names()
      assert "json_valid" in Eval.grader_names()
      assert "composite" in Eval.grader_names()
      assert "compile_check" in Eval.grader_names()
      assert "functional_test" in Eval.grader_names()
      assert "code_quality" in Eval.grader_names()
      assert "precision_at_1" in Eval.grader_names()
      assert "precision_at_5" in Eval.grader_names()
      assert "recall_at_5" in Eval.grader_names()
      assert length(Eval.grader_names()) == 11

      assert Eval.subject("Arbor.Eval.Subjects.Untrusted") == nil
      assert Eval.grader("Arbor.Eval.Graders.Untrusted") == nil
      assert Eval.subject(Passthrough) == nil
      assert Eval.grader(ExactMatch) == nil
    end

    test "rejects an unknown subject without resolving a caller-selected module" do
      assert_raise ArgumentError, ~r/unknown eval subject/, fn ->
        Eval.run_eval([], "Arbor.Eval.Subjects.Untrusted", ["exact_match"])
      end
    end
  end

  describe "JSONL to graded results" do
    test "runs the complete facade vertical path with exact result maps", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "samples.jsonl")

      File.write!(path, """
      {"id":"fixed","input":" Hello ","expected":"hello","metadata":{"split":"test"}}
      not-json
      {"input":"world","expected":"earth"}
      """)

      assert {:ok, samples} = Eval.load_dataset(path)

      assert samples == [
               %{
                 "id" => "fixed",
                 "input" => " Hello ",
                 "expected" => "hello",
                 "metadata" => %{"split" => "test"}
               },
               %{"id" => "sample_2", "input" => "world", "expected" => "earth"}
             ]

      results =
        Eval.run_eval(samples, "passthrough", ["exact_match"],
          trim: true,
          case_sensitive: false
        )

      assert results == [
               %{
                 "id" => "fixed",
                 "input" => " Hello ",
                 "expected" => "hello",
                 "actual" => " Hello ",
                 "scores" => [%{score: 1.0, passed: true, detail: "exact match"}],
                 "passed" => true,
                 "metadata" => %{"split" => "test"}
               },
               %{
                 "id" => "sample_2",
                 "input" => "world",
                 "expected" => "earth",
                 "actual" => "world",
                 "scores" => [%{score: 0.0, passed: false, detail: "no match"}],
                 "passed" => false,
                 "metadata" => nil
               }
             ]

      assert Eval.compute_metric("accuracy", results) == 0.5
      assert Eval.compute_metric("mean_score", results) == 0.5

      assert Eval.format_report(results, %{"accuracy" => 0.5}, "terminal") =~
               "Samples: 2 | Passed: 1 | Failed: 1"
    end

    test "applies seeded shuffle before limit deterministically", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "shuffle.jsonl")

      content =
        1..8
        |> Enum.map_join("\n", fn index ->
          ~s({"id":"s#{index}","input":"#{index}","expected":"#{index}"})
        end)

      File.write!(path, content)

      assert {:ok, shuffled} = Eval.load_dataset(path, shuffle: true, seed: 41)

      assert {:ok, limited_once} =
               Eval.load_dataset(path, shuffle: true, seed: 41, limit: 3)

      assert {:ok, limited_twice} =
               Eval.load_dataset(path, shuffle: true, seed: 41, limit: 3)

      assert limited_once == Enum.take(shuffled, 3)
      assert limited_twice == limited_once
      assert length(limited_once) == 3
    end

    test "returns the established read error text" do
      assert {:error, "Failed to read dataset: :enoent"} =
               Eval.load_dataset("/definitely/not/an/eval-dataset.jsonl")
    end

    test "trusted module seam retains unknown-grader compatibility" do
      samples = [%{"id" => "s1", "input" => "value", "expected" => "different"}]

      assert [result] = Eval.run_eval(samples, "passthrough", ["unknown"])
      assert result["scores"] == []
      assert result["passed"] == true

      assert Pipeline.run_eval(samples, Passthrough, [ExactMatch]) ==
               Eval.run_eval(samples, "passthrough", ["exact_match"])
    end

    test "run_eval_modules runs already-resolved trusted modules" do
      samples = [
        %{"id" => "ok", "input" => "same", "expected" => "same"},
        %{"id" => "no", "input" => "left", "expected" => "right"}
      ]

      results = Eval.run_eval_modules(samples, Passthrough, [ExactMatch])

      assert results ==
               Pipeline.run_eval(samples, Passthrough, [ExactMatch])

      assert results == Eval.run_eval(samples, "passthrough", ["exact_match"])
      assert Enum.map(results, & &1["passed"]) == [true, false]
    end
  end
end
