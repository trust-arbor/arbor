defmodule Arbor.Orchestrator.CodingPlan.TerminalReclassifyCore do
  @moduledoc """
  Pure reclassification of a pipeline's terminal status from the failed
  nodes' bounded reasons.

  The reviewed graph can only route on node outcomes, not on *why* a node
  failed, so `review_change` failing for an environmental reason — the
  wall-clock budget was already spent (typically because the host suspended
  during validation) — lands on the same `review_failed` status as a council
  that ran and failed. That misreports an unreviewed candidate as a rejected
  one (2026-08-28, login-cli v2). The executor applies this core before
  mapping the terminal so the public outcome says `review_unavailable`
  (origin `runtime`, retry `new_session`, candidate preserved) instead.
  """

  @review_node "review_change"

  @budget_patterns [
    "timeout budget rejected action execution",
    ":budget_exhausted",
    "budget_exhausted"
  ]

  @doc """
  `{:ok, status}` with the status to map, and `{:reclassified, from, to, reason}`
  as the second element when a change was made so the caller can record it.
  """
  @spec reclassify(String.t() | nil, term()) ::
          {String.t() | nil, nil | %{from: String.t(), to: String.t(), reason: String.t()}}
  def reclassify("review_failed", reasons) when is_map(reasons) do
    case review_reason(reasons) do
      reason when is_binary(reason) ->
        if budget_exhausted?(reason),
          do:
            {"review_unavailable",
             %{from: "review_failed", to: "review_unavailable", reason: reason}},
          else: {"review_failed", nil}

      _ ->
        {"review_failed", nil}
    end
  end

  def reclassify(status, _reasons), do: {status, nil}

  @doc "True when a bounded failure reason says the timeout budget was already spent."
  @spec budget_exhausted?(term()) :: boolean()
  def budget_exhausted?(reason) when is_binary(reason),
    do: Enum.any?(@budget_patterns, &String.contains?(reason, &1))

  def budget_exhausted?(_reason), do: false

  defp review_reason(reasons),
    do: Map.get(reasons, @review_node) || Map.get(reasons, String.to_atom(@review_node))
end
