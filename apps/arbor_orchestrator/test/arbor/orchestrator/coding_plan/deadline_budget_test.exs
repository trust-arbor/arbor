defmodule Arbor.Orchestrator.CodingPlan.DeadlineBudgetTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.DeadlineBudget

  @moduletag :fast

  describe "binding_parameter/1" do
    test "recognizes absent, default, and explicit action parameter bindings" do
      assert {:ok, nil} = DeadlineBudget.binding_parameter(%{})

      binding = %{
        "timeout_budget.deadline_key" => "session.run_deadline_unix_ms",
        "timeout_budget.cap_key" => "coding_budget.validation_ms",
        "timeout_budget.reserve_key" => "coding_budget.validation_completion_reserve_ms"
      }

      assert {:ok, "timeout"} = DeadlineBudget.binding_parameter(binding)

      assert {:ok, "stage_timeout"} =
               DeadlineBudget.binding_parameter(
                 Map.put(binding, "timeout_budget.param", "stage_timeout")
               )
    end

    test "rejects partial bindings and invalid action parameter names" do
      partial = %{
        "timeout_budget.deadline_key" => "session.run_deadline_unix_ms",
        "timeout_budget.cap_key" => "coding_budget.validation_ms"
      }

      assert {:error, :invalid_timeout_budget_attrs} =
               DeadlineBudget.binding_parameter(partial)

      assert {:error, :invalid_timeout_budget_attrs} =
               DeadlineBudget.binding_parameter(%{"timeout_budget.param" => "timeout"})

      assert {:error, :invalid_timeout_budget_metadata} =
               partial
               |> Map.put(
                 "timeout_budget.reserve_key",
                 "coding_budget.validation_completion_reserve_ms"
               )
               |> Map.put("timeout_budget.param", "not.valid")
               |> DeadlineBudget.binding_parameter()
    end
  end

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
