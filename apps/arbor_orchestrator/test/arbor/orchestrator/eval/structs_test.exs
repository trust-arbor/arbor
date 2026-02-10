defmodule Arbor.Orchestrator.Eval.StructsTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.{Sample, EvalResult}

  describe "Sample" do
    test "from_map builds struct from JSON-decoded map" do
      map = %{
        "id" => "parser",
        "input" => %{"spec" => "Parser spec"},
        "expected" => "digraph { start -> done }",
        "metadata" => %{"has_spec" => true}
      }

      sample = Sample.from_map(map)
      assert sample.id == "parser"
      assert sample.input == %{"spec" => "Parser spec"}
      assert sample.expected == "digraph { start -> done }"
      assert sample.metadata == %{"has_spec" => true}
    end

    test "from_map generates id when missing" do
      sample = Sample.from_map(%{"input" => "test"})
      assert is_binary(sample.id)
      assert String.length(sample.id) > 0
    end

    test "from_jsonl_line parses JSON line" do
      line = ~s|{"id":"test","input":"hello","expected":"world"}|
      sample = Sample.from_jsonl_line(line)
      assert sample.id == "test"
      assert sample.input == "hello"
      assert sample.expected == "world"
    end

    test "is JSON encodable" do
      sample = %Sample{id: "test", input: "in", expected: "out"}
      assert {:ok, json} = Jason.encode(sample)
      assert json =~ "test"
    end
  end

  describe "EvalResult" do
    test "avg_score computes mean of all grader scores" do
      result = %EvalResult{scores: %{"exact" => 1.0, "contains" => 0.5}}
      assert EvalResult.avg_score(result) == 0.75
    end

    test "avg_score returns 0.0 for empty scores" do
      result = %EvalResult{scores: %{}}
      assert EvalResult.avg_score(result) == 0.0
    end

    test "to_map produces string-keyed map" do
      result = %EvalResult{
        sample_id: "test",
        actual: "output",
        scores: %{"exact" => 1.0},
        passed: true,
        duration_ms: 42
      }

      map = EvalResult.to_map(result)
      assert map["sample_id"] == "test"
      assert map["actual"] == "output"
      assert map["passed"] == true
      assert map["duration_ms"] == 42
    end

    test "is JSON encodable" do
      result = %EvalResult{sample_id: "test", passed: true}
      assert {:ok, json} = Jason.encode(result)
      assert json =~ "test"
    end
  end
end
