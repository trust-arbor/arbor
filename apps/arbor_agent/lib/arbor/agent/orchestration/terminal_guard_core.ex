defmodule Arbor.Agent.Orchestration.TerminalGuardCore do
  @moduledoc """
  Pure decision: may the TaskStore finalize a given terminal for a task right now?

  A `task_runner_failed` or `task_owner_died` terminal asserts that the task's
  runner is gone. While the TaskStore still holds a monitor ref for that task's
  runner, the assertion is false by construction, and archiving it would shadow
  the runner's real terminal (the task terminal archive is first-writer). The
  2026-09-04 composer runs lost three binding reviews this way: a lifecycle
  placeholder landed ~10 minutes into a live run and the real terminal could not
  be archived afterwards.

  No side effects: the caller passes the refs map it holds.
  """

  @runner_gone_codes ~w(task_runner_failed task_owner_died)

  @doc "Terminal codes that claim the runner is gone."
  @spec runner_gone_codes() :: [String.t()]
  def runner_gone_codes, do: @runner_gone_codes

  @doc "Extract the outcome code from a canonical terminal envelope map."
  @spec terminal_code(term()) :: String.t()
  def terminal_code(%{"outcome" => %{"code" => code}}) when is_binary(code), do: code
  def terminal_code(_envelope), do: "unknown"

  @doc """
  True when `code` claims the runner is gone but `refs` (monitor ref => task id)
  still maps a live runner ref to `task_id`.
  """
  @spec contradicts_live_runner?(String.t(), String.t(), map()) :: boolean()
  def contradicts_live_runner?(task_id, code, refs)
      when is_binary(task_id) and code in @runner_gone_codes and is_map(refs) do
    Enum.any?(refs, fn
      {ref, ^task_id} when is_reference(ref) -> true
      _ -> false
    end)
  end

  def contradicts_live_runner?(_task_id, _code, _refs), do: false
end
