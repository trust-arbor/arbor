defmodule Arbor.Persistence.Repo.Migrations.AddRunIdentityToEvalRuns do
  use Ecto.Migration

  @moduledoc """
  Run-identity fields for longitudinal eval comparison.

  Without these, eval runs can't answer "did this change improve the system?":
  results weren't bound to the code under test (git_sha), the exact model
  serving identity (provider alone is ambiguous — the 2026-05-26 needs_tools
  sweep found the same model/quant behaving oppositely on Ollama vs LM Studio),
  or the dataset contents (edits silently invalidate comparisons).

  All fields nullable — existing rows and legacy callers remain valid.
  See .arbor/roadmap/1-brainstorming/eval-system-architecture.md.
  """

  def change do
    alter table(:eval_runs) do
      # Code under test
      add(:git_sha, :text)
      add(:git_dirty, :boolean)

      # Full model serving identity (model + provider already exist)
      add(:quant, :text)
      add(:endpoint, :text)

      # Dataset + config identity
      add(:dataset_hash, :text)
      add(:config_fingerprint, :text)

      # Eval-system-architecture joins
      # layer: "task" (prompt→output, Layer 1) | "system" (Arbor-in-the-loop, Layer 2)
      add(:layer, :text)
      # task_id: joins to the LLM task inventory (e.g. "preprocessor.needs_tools")
      add(:task_id, :text)
    end

    create(index(:eval_runs, [:git_sha]))
    create(index(:eval_runs, [:task_id]))
    create(index(:eval_runs, [:task_id, :model, :inserted_at]))
  end
end
