defmodule Arbor.Orchestrator.CodingPlan.BudgetPolicyTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.BudgetPolicy

  @moduletag :fast

  describe "allocate/2 — normal (unscaled) allocation" do
    test "desired amounts fit under the 40% tail cap and are returned unscaled" do
      # wall_clock=3_000_000 -> tail_cap=1_200_000; desired=200k+300k+180k+30k=710k <= cap.
      assert {:ok, stages} = BudgetPolicy.allocate(3_000_000, 200_000)

      assert stages == %{
               "validation_ms" => 200_000,
               "approval_ms" => 300_000,
               "review_ms" => 180_000,
               "cleanup_ms" => 30_000,
               "worker_completion_reserve_ms" => 710_000,
               "validation_completion_reserve_ms" => 510_000,
               "review_completion_reserve_ms" => 30_000,
               "approval_completion_reserve_ms" => 210_000
             }
    end

    test "validation desired amount is capped at 600_000ms regardless of a larger program timeout" do
      # wall_clock=10_000_000 -> tail_cap=4_000_000; desired validation clipped to
      # 600_000 even though the reviewed validation timeout is much larger.
      assert {:ok, stages} = BudgetPolicy.allocate(10_000_000, 999_999_999)

      assert stages["validation_ms"] == 600_000
      assert stages["worker_completion_reserve_ms"] == 600_000 + 300_000 + 180_000 + 30_000
    end
  end

  describe "allocate/2 — scaled allocation" do
    test "scales stage amounts down by share when the desired total exceeds the 40% cap" do
      # wall_clock=600_000 -> tail_cap=240_000; desired=500k+300k+180k+30k=1_010_000 > cap.
      # 240_000 split 55/25/15/5 divides evenly (no remainder distribution needed).
      assert {:ok, stages} = BudgetPolicy.allocate(600_000, 500_000)

      assert stages == %{
               "validation_ms" => 132_000,
               "approval_ms" => 60_000,
               "review_ms" => 36_000,
               "cleanup_ms" => 12_000,
               "worker_completion_reserve_ms" => 240_000,
               "validation_completion_reserve_ms" => 108_000,
               "review_completion_reserve_ms" => 12_000,
               "approval_completion_reserve_ms" => 48_000
             }

      assert stages["validation_ms"] + stages["approval_ms"] + stages["review_ms"] +
               stages["cleanup_ms"] == 240_000
    end

    test "exact integer accounting distributes remainder deterministically by largest remainder" do
      # wall_clock=253 -> tail_cap=div(506,5)=101, which does not divide evenly by
      # 55/25/15/5. Bases sum to 100 with remainders 55/25/15/5 (validation largest),
      # so the single leftover unit goes to validation.
      assert {:ok, stages} = BudgetPolicy.allocate(253, 999_999_999)

      assert stages["validation_ms"] == 56
      assert stages["approval_ms"] == 25
      assert stages["review_ms"] == 15
      assert stages["cleanup_ms"] == 5

      total =
        stages["validation_ms"] + stages["approval_ms"] + stages["review_ms"] +
          stages["cleanup_ms"]

      assert total == 101
      assert stages["worker_completion_reserve_ms"] == total
    end

    test "smaller trusted context timeout recomputes a smaller scaled budget" do
      assert {:ok, wide} = BudgetPolicy.allocate(900_000, 600_000)
      assert {:ok, narrow} = BudgetPolicy.allocate(100_000, 600_000)

      refute wide == narrow
      assert wide["worker_completion_reserve_ms"] > narrow["worker_completion_reserve_ms"]

      assert narrow == %{
               "validation_ms" => 22_000,
               "approval_ms" => 10_000,
               "review_ms" => 6_000,
               "cleanup_ms" => 2_000,
               "worker_completion_reserve_ms" => 40_000,
               "validation_completion_reserve_ms" => 18_000,
               "review_completion_reserve_ms" => 2_000,
               "approval_completion_reserve_ms" => 8_000
             }
    end
  end

  describe "allocate/2 — boundary" do
    test "desired total exactly equal to the 40% cap is returned unscaled" do
      # wall_clock=1_500_000 -> tail_cap=600_000; desired=90k+300k+180k+30k=600_000 exactly.
      assert {:ok, stages} = BudgetPolicy.allocate(1_500_000, 90_000)

      assert stages == %{
               "validation_ms" => 90_000,
               "approval_ms" => 300_000,
               "review_ms" => 180_000,
               "cleanup_ms" => 30_000,
               "worker_completion_reserve_ms" => 600_000,
               "validation_completion_reserve_ms" => 510_000,
               "review_completion_reserve_ms" => 30_000,
               "approval_completion_reserve_ms" => 210_000
             }
    end

    test "one millisecond over the cap triggers scaling instead of the unscaled path" do
      # wall_clock=1_500_002 -> tail_cap=600_000 (integer division), but the
      # desired total (600_001, using validation=90_001) is one over.
      assert {:ok, stages} = BudgetPolicy.allocate(1_500_002, 90_001)

      total =
        stages["validation_ms"] + stages["approval_ms"] + stages["review_ms"] +
          stages["cleanup_ms"]

      assert total == 600_000
      refute stages["validation_ms"] == 90_001
    end

    test "a very small wall clock yields an all-zero, still-exact allocation" do
      assert {:ok, stages} = BudgetPolicy.allocate(1, 100)

      assert stages == %{
               "validation_ms" => 0,
               "approval_ms" => 0,
               "review_ms" => 0,
               "cleanup_ms" => 0,
               "worker_completion_reserve_ms" => 0,
               "validation_completion_reserve_ms" => 0,
               "review_completion_reserve_ms" => 0,
               "approval_completion_reserve_ms" => 0
             }
    end
  end

  describe "allocate/2 — deterministic" do
    test "repeated calls with identical input produce identical output" do
      results = for _ <- 1..25, do: BudgetPolicy.allocate(600_000, 500_000)

      assert Enum.uniq(results) == [{:ok, hd(results) |> elem(1)}]
    end

    test "no negative values are ever produced across a range of inputs" do
      for wall_clock_ms <- [1, 7, 101, 1_000, 30_000, 253, 600_000, 900_000, 5_000_000],
          validation_timeout_ms <- [1, 100, 90_000, 600_000, 999_999_999] do
        assert {:ok, stages} = BudgetPolicy.allocate(wall_clock_ms, validation_timeout_ms)

        for {_key, value} <- stages do
          assert value >= 0
        end
      end
    end
  end

  describe "allocate/2 — invalid inputs" do
    test "rejects non-positive or non-integer effective wall clock" do
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(0, 100)
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(-1, 100)
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate("900000", 100)
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(nil, 100)
    end

    test "rejects non-positive or non-integer validation timeout" do
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, 0)
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, -1)
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, "600000")
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, nil)
    end
  end
end
