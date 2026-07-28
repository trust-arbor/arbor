defmodule Arbor.Orchestrator.CodingPlan.DeadlineBudget do
  @moduledoc """
  Pure deadline-budget calculations for bounded coding operations.

  A request without budget metadata follows the legacy path unchanged. When
  metadata is supplied, the requested timeout is capped by the remaining
  deadline after reserving time for completion.
  """

  @type timeout_ms :: pos_integer()
  @type deadline_unix_ms :: pos_integer() | nil
  @type completion_reserve_ms :: non_neg_integer() | nil
  @type now_unix_ms :: integer()
  @type result :: {:ok, timeout_ms()} | {:error, :budget_exhausted | :invalid_budget_metadata}

  @spec cap(timeout_ms(), deadline_unix_ms(), completion_reserve_ms(), now_unix_ms()) :: result()
  def cap(requested_timeout_ms, nil, nil, _now_unix_ms)
      when is_integer(requested_timeout_ms) and requested_timeout_ms > 0 do
    {:ok, requested_timeout_ms}
  end

  def cap(requested_timeout_ms, run_deadline_unix_ms, completion_reserve_ms, now_unix_ms)
      when is_integer(requested_timeout_ms) and requested_timeout_ms > 0 and
             is_integer(run_deadline_unix_ms) and run_deadline_unix_ms > 0 and
             is_integer(completion_reserve_ms) and completion_reserve_ms >= 0 and
             is_integer(now_unix_ms) do
    remaining_ms = run_deadline_unix_ms - now_unix_ms - completion_reserve_ms

    if remaining_ms <= 0 do
      {:error, :budget_exhausted}
    else
      {:ok, min(requested_timeout_ms, remaining_ms)}
    end
  end

  def cap(_requested_timeout_ms, _run_deadline_unix_ms, _completion_reserve_ms, _now_unix_ms),
    do: {:error, :invalid_budget_metadata}
end
