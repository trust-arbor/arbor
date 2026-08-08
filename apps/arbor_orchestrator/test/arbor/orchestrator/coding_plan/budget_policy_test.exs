defmodule Arbor.Orchestrator.CodingPlan.BudgetPolicyTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.BudgetPolicy

  @moduletag :fast

  defp assert_worker_uses_reserve(stages) do
    assert stages["worker_completion_reserve_ms"] ==
             stages["validation_reserve_ms"] + stages["approval_ms"] + stages["review_ms"] +
               stages["cleanup_ms"]

    assert stages["validation_completion_reserve_ms"] ==
             stages["approval_ms"] + stages["review_ms"] + stages["cleanup_ms"]
  end

  describe "allocate/2 — normal (unscaled) allocation" do
    test "desired reserve amounts fit under the 40% tail cap and are returned unscaled" do
      # wall_clock=3_000_000 -> tail_cap=1_200_000; desired=200k+300k+180k+30k=710k <= cap.
      assert {:ok, stages} = BudgetPolicy.allocate(3_000_000, 200_000)

      assert stages == %{
               "validation_ms" => 200_000,
               "validation_reserve_ms" => 200_000,
               "approval_ms" => 300_000,
               "review_ms" => 180_000,
               "cleanup_ms" => 30_000,
               "worker_completion_reserve_ms" => 710_000,
               "validation_completion_reserve_ms" => 510_000,
               "review_completion_reserve_ms" => 30_000,
               "approval_completion_reserve_ms" => 210_000
             }

      assert_worker_uses_reserve(stages)
    end

    test "validation action cap may exceed the 600_000ms guaranteed reserve" do
      # wall_clock=10_000_000 -> tail_cap=4_000_000; action cap keeps the large
      # source timeout while the guaranteed reserve clips to 600_000.
      assert {:ok, stages} = BudgetPolicy.allocate(10_000_000, 4_200_000)

      assert stages["validation_ms"] == 4_200_000
      assert stages["validation_reserve_ms"] == 600_000
      assert stages["validation_ms"] > stages["validation_reserve_ms"]

      assert stages["worker_completion_reserve_ms"] ==
               600_000 + 300_000 + 180_000 + 30_000

      assert_worker_uses_reserve(stages)
      refute stages["worker_completion_reserve_ms"] == 4_200_000 + 300_000 + 180_000 + 30_000
    end

    test "action cap is bounded by the effective wall clock" do
      # wall=3_000_000 bounds the 4.2M source; reserve desired still clips to 600k
      # and fits under tail_cap=1_200_000 unscaled.
      assert {:ok, stages} = BudgetPolicy.allocate(3_000_000, 4_200_000)

      assert stages["validation_ms"] == 3_000_000
      assert stages["validation_reserve_ms"] == 600_000
      assert stages["validation_ms"] > stages["validation_reserve_ms"]
      assert_worker_uses_reserve(stages)
    end
  end

  describe "allocate/2 — scaled allocation" do
    test "scales reserve stages down by share when the desired total exceeds the 40% cap" do
      # wall_clock=600_000 -> tail_cap=240_000; desired=500k+300k+180k+30k=1_010_000 > cap.
      # 240_000 split 55/25/15/5 divides evenly (no remainder distribution needed).
      # Action cap stays at min(500k, 600k)=500k and is not scaled.
      assert {:ok, stages} = BudgetPolicy.allocate(600_000, 500_000)

      assert stages == %{
               "validation_ms" => 500_000,
               "validation_reserve_ms" => 132_000,
               "approval_ms" => 60_000,
               "review_ms" => 36_000,
               "cleanup_ms" => 12_000,
               "worker_completion_reserve_ms" => 240_000,
               "validation_completion_reserve_ms" => 108_000,
               "review_completion_reserve_ms" => 12_000,
               "approval_completion_reserve_ms" => 48_000
             }

      assert stages["validation_reserve_ms"] + stages["approval_ms"] + stages["review_ms"] +
               stages["cleanup_ms"] == 240_000

      assert stages["validation_ms"] > stages["validation_reserve_ms"]
      assert_worker_uses_reserve(stages)
    end

    test "exact integer accounting distributes remainder deterministically by largest remainder" do
      # wall_clock=253 -> tail_cap=div(506,5)=101, which does not divide evenly by
      # 55/25/15/5. Bases sum to 100 with remainders 55/25/15/5 (validation largest),
      # so the single leftover unit goes to validation reserve.
      assert {:ok, stages} = BudgetPolicy.allocate(253, 999_999_999)

      assert stages["validation_ms"] == 253
      assert stages["validation_reserve_ms"] == 56
      assert stages["approval_ms"] == 25
      assert stages["review_ms"] == 15
      assert stages["cleanup_ms"] == 5

      total =
        stages["validation_reserve_ms"] + stages["approval_ms"] + stages["review_ms"] +
          stages["cleanup_ms"]

      assert total == 101
      assert stages["worker_completion_reserve_ms"] == total
      assert_worker_uses_reserve(stages)
    end

    test "smaller trusted context timeout recomputes cap and reserves with post-validation headroom" do
      assert {:ok, wide} = BudgetPolicy.allocate(900_000, 4_200_000)
      assert {:ok, narrow} = BudgetPolicy.allocate(100_000, 4_200_000)

      refute wide == narrow
      assert wide["validation_ms"] > narrow["validation_ms"]
      assert wide["worker_completion_reserve_ms"] > narrow["worker_completion_reserve_ms"]

      assert narrow == %{
               "validation_ms" => 100_000,
               "validation_reserve_ms" => 22_000,
               "approval_ms" => 10_000,
               "review_ms" => 6_000,
               "cleanup_ms" => 2_000,
               "worker_completion_reserve_ms" => 40_000,
               "validation_completion_reserve_ms" => 18_000,
               "review_completion_reserve_ms" => 2_000,
               "approval_completion_reserve_ms" => 8_000
             }

      # Post-validation gates retain headroom under the scaled tail.
      assert narrow["validation_completion_reserve_ms"] > 0
      assert_worker_uses_reserve(narrow)
    end
  end

  describe "allocate/2 — boundary" do
    test "desired total exactly equal to the 40% cap is returned unscaled" do
      # wall_clock=1_500_000 -> tail_cap=600_000; desired=90k+300k+180k+30k=600_000 exactly.
      assert {:ok, stages} = BudgetPolicy.allocate(1_500_000, 90_000)

      assert stages == %{
               "validation_ms" => 90_000,
               "validation_reserve_ms" => 90_000,
               "approval_ms" => 300_000,
               "review_ms" => 180_000,
               "cleanup_ms" => 30_000,
               "worker_completion_reserve_ms" => 600_000,
               "validation_completion_reserve_ms" => 510_000,
               "review_completion_reserve_ms" => 30_000,
               "approval_completion_reserve_ms" => 210_000
             }

      assert_worker_uses_reserve(stages)
    end

    test "one millisecond over the cap triggers scaling instead of the unscaled path" do
      # wall_clock=1_500_002 -> tail_cap=600_000 (integer division), but the
      # desired total (600_001, using validation_reserve=90_001) is one over.
      assert {:ok, stages} = BudgetPolicy.allocate(1_500_002, 90_001)

      total =
        stages["validation_reserve_ms"] + stages["approval_ms"] + stages["review_ms"] +
          stages["cleanup_ms"]

      assert total == 600_000
      assert stages["validation_ms"] == 90_001
      refute stages["validation_reserve_ms"] == 90_001
      assert_worker_uses_reserve(stages)
    end

    test "a very small wall clock yields a nonnegative exact allocation" do
      assert {:ok, stages} = BudgetPolicy.allocate(1, 100)

      assert stages == %{
               "validation_ms" => 1,
               "validation_reserve_ms" => 0,
               "approval_ms" => 0,
               "review_ms" => 0,
               "cleanup_ms" => 0,
               "worker_completion_reserve_ms" => 0,
               "validation_completion_reserve_ms" => 0,
               "review_completion_reserve_ms" => 0,
               "approval_completion_reserve_ms" => 0
             }

      assert_worker_uses_reserve(stages)
    end
  end

  describe "allocate/2 — deterministic" do
    test "repeated calls with identical input produce identical output" do
      results = for _ <- 1..25, do: BudgetPolicy.allocate(600_000, 500_000)

      assert Enum.uniq(results) == [{:ok, hd(results) |> elem(1)}]
    end

    test "no negative values are ever produced across a range of inputs" do
      for wall_clock_ms <- [1, 7, 101, 1_000, 30_000, 253, 600_000, 900_000, 5_000_000],
          validation_source_ms <- [1, 100, 90_000, 600_000, 4_200_000, 999_999_999] do
        assert {:ok, stages} = BudgetPolicy.allocate(wall_clock_ms, validation_source_ms)

        for {_key, value} <- stages do
          assert value >= 0
        end

        assert stages["validation_ms"] == min(validation_source_ms, wall_clock_ms)
        assert_worker_uses_reserve(stages)

        assert stages["worker_completion_reserve_ms"] <=
                 div(wall_clock_ms * 2, 5)
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

    test "rejects non-positive or non-integer validation action source" do
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, 0)
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, -1)
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, "600000")
      assert {:error, :invalid_budget_policy_input} = BudgetPolicy.allocate(900_000, nil)
    end
  end
end
