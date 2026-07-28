defmodule Arbor.Orchestrator.CodingPlan.DeadlineBudgetTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.DeadlineBudget

  @moduletag :fast

  test "legacy path preserves the requested timeout" do
    assert {:ok, 5_000} = DeadlineBudget.cap(5_000, nil, nil, 7_000)
  end

  test "caps the requested timeout to the remaining budget" do
    assert {:ok, 2_500} = DeadlineBudget.cap(5_000, 10_000, 500, 7_000)
  end

  test "does not extend a shorter requested timeout" do
    assert {:ok, 1_000} = DeadlineBudget.cap(1_000, 10_000, 0, 7_000)
  end

  test "allows a zero completion reserve" do
    assert {:ok, 3_000} = DeadlineBudget.cap(5_000, 10_000, 0, 7_000)
  end

  test "reports an exhausted budget" do
    assert {:error, :budget_exhausted} = DeadlineBudget.cap(5_000, 10_000, 3_000, 7_000)
  end

  test "rejects partial budget metadata" do
    assert {:error, :invalid_budget_metadata} = DeadlineBudget.cap(5_000, 10_000, nil, 7_000)
    assert {:error, :invalid_budget_metadata} = DeadlineBudget.cap(5_000, nil, 500, 7_000)
  end

  test "rejects malformed and nonpositive inputs" do
    invalid_inputs = [
      {0, 10_000, 500, 7_000},
      {-1, 10_000, 500, 7_000},
      {"5_000", 10_000, 500, 7_000},
      {5_000, 0, 500, 7_000},
      {5_000, -1, 500, 7_000},
      {5_000, 10_000, -1, 7_000},
      {5_000, 10_000, 500, "7_000"}
    ]

    for input <- invalid_inputs do
      assert {:error, :invalid_budget_metadata} =
               apply(DeadlineBudget, :cap, Tuple.to_list(input))
    end
  end
end
