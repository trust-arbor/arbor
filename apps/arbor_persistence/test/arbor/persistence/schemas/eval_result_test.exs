defmodule Arbor.Persistence.Schemas.EvalResultTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Schemas.EvalResult

  @valid_attrs %{
    id: "result-001",
    run_id: "test-run-001",
    sample_id: "explain_genserver"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      cs = EvalResult.changeset(%EvalResult{}, @valid_attrs)
      assert cs.valid?
    end

    test "valid with all fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          input: "Explain GenServer",
          expected: "init, handle_call, handle_cast",
          actual: "GenServer is a behaviour that...",
          passed: true,
          scores: %{"contains" => %{"score" => 1.0, "passed" => true}},
          duration_ms: 3200,
          ttft_ms: 450,
          tokens_generated: 256,
          metadata: %{category: "explanation"}
        })

      cs = EvalResult.changeset(%EvalResult{}, attrs)
      assert cs.valid?
    end

    test "invalid without required fields" do
      cs = EvalResult.changeset(%EvalResult{}, %{})
      refute cs.valid?

      errors = errors_on(cs)
      assert :id in errors
      assert :run_id in errors
      assert :sample_id in errors
    end

    test "defaults" do
      cs = EvalResult.changeset(%EvalResult{}, @valid_attrs)
      changes = Ecto.Changeset.apply_changes(cs)
      assert changes.passed == false
      assert changes.scores == %{}
      assert changes.duration_ms == 0
      assert changes.ttft_ms == nil
      assert changes.tokens_generated == nil
      assert changes.metadata == %{}
    end

    test "nullable timing fields" do
      attrs = Map.merge(@valid_attrs, %{ttft_ms: nil, tokens_generated: nil})
      cs = EvalResult.changeset(%EvalResult{}, attrs)
      assert cs.valid?
    end
  end

  defp errors_on(changeset) do
    changeset.errors |> Keyword.keys()
  end
end
