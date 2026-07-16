defmodule Arbor.Orchestrator.Test.CheckpointResumeHelper do
  @moduledoc false
  # Process-loss interruption/recovery helpers for checkpoint-resume tests.
  # Mirrors engine_effect_recovery_l3c_test reopen-as-recovering without
  # mutating authoritative effect evidence (current_effect / effect_generation).

  import ExUnit.Assertions

  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunLifecycle.Record

  @doc "Stable unique run_id for one interruption/recovery pair."
  def unique_run_id(prefix) when is_binary(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc """
  Model process-loss recovery on an existing journal record.

  Reopens only established lifecycle terminal fields as `:interrupted`, then
  claims for recovery (`:recovering`). **Does not** clear or rewrite
  `current_effect` or `effect_generation` — settled receipts must remain for
  L3C recovery consistency checks.

  Journal target opts (e.g. `server:`) may be passed as the second argument.
  """
  def reopen_as_recovering!(run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    rec = PipelineStatus.get_record(run_id, opts)
    assert %Record{} = rec

    reopened = %Record{
      rec
      | status: :interrupted,
        failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil,
        logs_root: rec.logs_root
    }

    assert :ok = PipelineStatus.put(reopened, opts)
    assert {:ok, _} = PipelineStatus.claim_for_recovery_record(run_id, node(), opts)
    reopened
  end

  @doc "Register on_exit cleanup for a canonical journal record created by a test."
  def schedule_journal_cleanup(run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    ExUnit.Callbacks.on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id, opts)
      catch
        :exit, _ -> :ok
      end
    end)
  end
end
