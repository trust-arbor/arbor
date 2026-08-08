defmodule Arbor.Orchestrator.CodingPlan.BudgetPolicy do
  @moduledoc """
  Deterministic terminal-gate wall-clock budget allocation for the coding
  DOT pipeline.

  Pure CRC core (no IO, no time, no config lookups): given the effective task
  wall clock and the largest timeout present on the reviewed validation
  program, allocates:

  1. An **opportunistic validation action cap** (`validation_ms`) —
     `min(source_timeout, effective_wall_clock)`. This is *not* scaled under
     the tail ceiling; runtime still clamps via DeadlineBudget against the
     owner deadline and post-validation completion reserve.
  2. A **guaranteed validation reserve** (`validation_reserve_ms`) plus the
     other terminal stages (approval, council review, cleanup). The reserve
     desired amount is `min(action_cap, 600_000)` and is scaled with the
     other stages under the 40% tail ceiling.

  The guaranteed tail reserve (validation_reserve + approval + review +
  cleanup) is capped at 40% of the effective wall clock so the worker phase
  always keeps the majority of the budget. When the desired total would
  exceed that cap, the cap itself is distributed across the reserve stages
  using the largest-remainder method, so the allocation is exact (sums to the
  cap), deterministic, and never negative.

  `worker_completion_reserve_ms` includes only the guaranteed validation
  reserve (not the larger opportunistic action cap).

  ## Why approval is allocated before the proportional split

  Approval is the one stage measured in *human* time, and human review time
  does not scale with the machine budget: a 230-line diff takes the same time
  to read whether the worker ran for five minutes or fifty. Under a purely
  proportional split its 25% share of a 40% tail made the guaranteed human
  review floor **10% of the wall clock** — 90s on the 900s default, which is
  not enough to read a diff, check the call sites, and re-run tests.

  The incentive also ran backwards: the slower and more complex the change,
  the less review time remained, yet that is exactly the change that most
  needs review. (Measured 2026-08-07 on `task_d3e06b44`; register F-139.)

  So approval is satisfied first, up to `@desired_approval_ms`, bounded by
  `@approval_tail_share_max_*` so it can never starve the machine stages.
  The remainder is apportioned across validation/review/cleanup by their
  existing relative shares. Note this trades guaranteed *validation reserve*
  for guaranteed *review time*; the opportunistic validation action cap
  (`validation_ms`) is a separate number and is unaffected.

  This does not make a short wall clock sufficient for human review — at 900s
  the honest ceiling on the whole tail is 360s. A plan that gates on a human
  must budget wall clock for one. See
  `.arbor/decisions/2026-08-07-human-review-budget-floor.md`.
  """

  @desired_validation_max_ms 600_000
  @desired_approval_ms 300_000
  @desired_review_ms 180_000
  @desired_cleanup_ms 30_000

  # Tail reserve ceiling as a ratio of the effective wall clock: 40% = 2/5.
  @tail_reserve_max_ratio_num 2
  @tail_reserve_max_ratio_den 5

  # Ceiling on approval's share OF THE TAIL when the tail is scaled down, so
  # protecting human review can never starve validation/review/cleanup: 1/2.
  @approval_tail_share_max_num 1
  @approval_tail_share_max_den 2

  @shares %{validation: 55, approval: 25, review: 15, cleanup: 5}

  # Stages sharing the tail remaining after approval is satisfied, and their
  # relative weights (the original shares, renormalized by apportionment).
  @post_approval_stage_order [:validation, :review, :cleanup]

  @type stage_ms :: %{String.t() => non_neg_integer()}
  @type allocate_error :: :invalid_budget_policy_input

  @doc """
  Allocate deterministic terminal-gate tail budgets and the opportunistic
  validation action cap.

  `effective_wall_clock_ms` is the owner-computed effective task wall clock
  (`min(plan wall clock, trusted execution-context timeout)`).
  `validation_action_source_ms` is the largest positive timeout already present
  in the reviewed validation program static parameters. Both must be positive
  integers.

  Returns a flat, JSON-clean, string-keyed map with:

    - `validation_ms` — opportunistic action cap (`min(source, wall)`), not scaled
    - `validation_reserve_ms` — guaranteed validation reserve (≤ 600_000 desired,
      then scaled with the other stages under the 40% tail ceiling)
    - `approval_ms`, `review_ms`, `cleanup_ms` — stage amounts
    - cumulative completion reserves:
      - `worker_completion_reserve_ms` — validation_reserve + approval + review + cleanup
      - `validation_completion_reserve_ms` — approval + review + cleanup
      - `review_completion_reserve_ms` — cleanup
      - `approval_completion_reserve_ms` — review + cleanup
  """
  @spec allocate(pos_integer(), pos_integer()) :: {:ok, stage_ms()} | {:error, allocate_error()}
  def allocate(effective_wall_clock_ms, validation_action_source_ms)
      when is_integer(effective_wall_clock_ms) and effective_wall_clock_ms > 0 and
             is_integer(validation_action_source_ms) and validation_action_source_ms > 0 do
    action_cap_ms = min(validation_action_source_ms, effective_wall_clock_ms)

    desired = %{
      validation: min(action_cap_ms, @desired_validation_max_ms),
      approval: @desired_approval_ms,
      review: @desired_review_ms,
      cleanup: @desired_cleanup_ms
    }

    desired_total = desired.validation + desired.approval + desired.review + desired.cleanup

    tail_cap_ms =
      div(effective_wall_clock_ms * @tail_reserve_max_ratio_num, @tail_reserve_max_ratio_den)

    stages =
      if desired_total <= tail_cap_ms do
        desired
      else
        scale_down(tail_cap_ms)
      end

    {:ok, build_stage_ms(action_cap_ms, stages)}
  end

  def allocate(_effective_wall_clock_ms, _validation_action_source_ms),
    do: {:error, :invalid_budget_policy_input}

  # Satisfy the human-review floor first (bounded so it cannot starve the
  # machine stages), then apportion what remains across the other three.
  # Still exact: approval + apportion(remainder) == tail_cap_ms.
  defp scale_down(tail_cap_ms) do
    approval_ceiling_ms =
      div(tail_cap_ms * @approval_tail_share_max_num, @approval_tail_share_max_den)

    approval_ms = min(@desired_approval_ms, approval_ceiling_ms)

    tail_cap_ms
    |> Kernel.-(approval_ms)
    |> apportion(@post_approval_stage_order)
    |> Map.put(:approval, approval_ms)
  end

  # Largest-remainder (Hamilton) apportionment of `total_ms` across `stages` by
  # their @shares weight. Exact integer accounting: the resulting amounts always
  # sum to exactly `total_ms`, and are never negative. Deterministic tie-break:
  # stages with equal remainders are ordered by their position in `stages`.
  #
  # Weights need not sum to 100 — the divisor is their actual sum — so the same
  # function serves the full four-stage split and the post-approval three-stage
  # one without a second table of numbers to keep in sync.
  defp apportion(total_ms, stages) do
    weight_sum = Enum.reduce(stages, 0, fn stage, acc -> acc + Map.fetch!(@shares, stage) end)

    bases_and_remainders =
      Enum.map(stages, fn stage ->
        numerator = total_ms * Map.fetch!(@shares, stage)
        {stage, div(numerator, weight_sum), rem(numerator, weight_sum)}
      end)

    base_sum =
      Enum.reduce(bases_and_remainders, 0, fn {_stage, base, _rem}, acc -> acc + base end)

    leftover = total_ms - base_sum

    ranked =
      bases_and_remainders
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_stage, _base, remainder}, index} -> {-remainder, index} end)

    {final, _remaining} =
      Enum.reduce(ranked, {%{}, leftover}, fn {{stage, base, _remainder}, _index},
                                              {acc, remaining} ->
        if remaining > 0 do
          {Map.put(acc, stage, base + 1), remaining - 1}
        else
          {Map.put(acc, stage, base), remaining}
        end
      end)

    final
  end

  defp build_stage_ms(action_cap_ms, %{validation: v, approval: a, review: r, cleanup: c}) do
    %{
      "validation_ms" => action_cap_ms,
      "validation_reserve_ms" => v,
      "approval_ms" => a,
      "review_ms" => r,
      "cleanup_ms" => c,
      "worker_completion_reserve_ms" => v + a + r + c,
      "validation_completion_reserve_ms" => a + r + c,
      "review_completion_reserve_ms" => c,
      "approval_completion_reserve_ms" => r + c
    }
  end
end
