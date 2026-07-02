defmodule Arbor.Persistence.Repo.Migrations.AddLayer2MetricsToEvalResults do
  use Ecto.Migration

  @moduledoc """
  First-class, SQL-queryable metrics for Layer-2 (agent-in-the-loop) evals.

  eval_results already had `passed`, `duration_ms`, `ttft_ms`, `tokens_generated`
  (output only). Trending cost / prompt+total tokens / tool-call efficiency /
  run-validity across code versions requires these to be typed columns, not
  buried in the free-form `metadata` map (JSON blobs aren't aggregatable in SQL,
  so regression detection + the dashboard can't use them).

  - cost / prompt_tokens / total_tokens: model-selection is the point of the eval
    system (the ToolLoop already accumulates these across tool rounds — free to
    capture). tokens_generated already covers output tokens.
  - tool_call_count: tool-loop health (loops / hallucinated / denied calls show up
    here); the metric that surfaced the file_list loop + shell-escalation bugs.
  - precondition_met: did the agent actually ENGAGE the scenario (read the configs,
    hit the poisoned tool)? A run where it didn't is vacuous — a pass there is
    meaningless. Making this queryable lets us filter vacuous runs out of rates.

  All nullable — existing rows and Layer-1 callers stay valid.
  See .arbor/roadmap/1-brainstorming/eval-system-architecture.md.
  """

  def change do
    alter table(:eval_results) do
      add(:cost, :float)
      add(:prompt_tokens, :integer)
      add(:total_tokens, :integer)
      add(:tool_call_count, :integer)
      add(:precondition_met, :boolean)
    end
  end
end
