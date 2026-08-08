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
  exceed that cap, the cap itself is distributed across the four reserve
  stages by approximate share (validation 55%, approval 25%, review 15%,
  cleanup 5%) using the largest-remainder method, so the allocation is exact
  (sums to the cap), deterministic, and never negative.

  `worker_completion_reserve_ms` includes only the guaranteed validation
  reserve (not the larger opportunistic action cap).
  """

  @desired_validation_max_ms 600_000
  @desired_approval_ms 300_000
  @desired_review_ms 180_000
  @desired_cleanup_ms 30_000

  # Tail reserve ceiling as a ratio of the effective wall clock: 40% = 2/5.
  @tail_reserve_max_ratio_num 2
  @tail_reserve_max_ratio_den 5

  @stage_order [:validation, :approval, :review, :cleanup]
  @shares %{validation: 55, approval: 25, review: 15, cleanup: 5}

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

  # Largest-remainder (Hamilton) apportionment of `tail_cap_ms` across the
  # four reserve stages by their approximate share. Exact integer accounting:
  # the resulting amounts always sum to exactly `tail_cap_ms`, and are never
  # negative. Deterministic tie-break: stages with equal remainders are
  # ordered by @stage_order (validation, approval, review, cleanup).
  defp scale_down(tail_cap_ms) do
    bases_and_remainders =
      Enum.map(@stage_order, fn stage ->
        share = Map.fetch!(@shares, stage)
        numerator = tail_cap_ms * share
        {stage, div(numerator, 100), rem(numerator, 100)}
      end)

    base_sum =
      Enum.reduce(bases_and_remainders, 0, fn {_stage, base, _rem}, acc -> acc + base end)

    leftover = tail_cap_ms - base_sum

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
