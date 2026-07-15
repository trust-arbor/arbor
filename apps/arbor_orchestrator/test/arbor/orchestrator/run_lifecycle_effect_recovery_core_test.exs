defmodule Arbor.Orchestrator.RunLifecycleEffectRecoveryCoreTest do
  @moduledoc """
  Pure table tests for L3C EffectRecoveryCore decisions.
  No journal, Engine, or IO — decision data only.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.EffectOwner
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.RunLifecycle.EffectEnvelope
  alias Arbor.Orchestrator.RunLifecycle.EffectRecoveryCore
  alias Arbor.Orchestrator.RunLifecycle.Record

  @digest_a EffectOwner.outcome_result_digest(%Outcome{
              status: :success,
              context_updates: %{"k" => "v"}
            })

  @digest_b EffectOwner.outcome_result_digest(%Outcome{
              status: :success,
              context_updates: %{"k" => "other"}
            })

  describe "nil / absent current_effect" do
    test "continues and leaves legacy intent handling to the Engine" do
      record = base_record(current_effect: nil)
      checkpoint = %{completed_nodes: ["start"], outcomes: %{}}

      assert {:ok, :continue} = EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "pending" do
    test "halts as indeterminate even when checkpoint looks advanced" do
      effect = pending_effect("task", "exec_abc")
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      checkpoint = %{
        completed_nodes: ["start"],
        outcomes: %{"start" => %Outcome{status: :success}}
      }

      assert {:error, {:indeterminate_effect, "task", "exec_abc"}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "never returns reconcile or continue for pending" do
      effect = pending_effect("task", "exec_pending")
      record = base_record(current_effect: effect)

      # Empty checkpoint (as if crash mid-handler)
      assert {:error, {:indeterminate_effect, "task", "exec_pending"}} =
               EffectRecoveryCore.decide(record, %{completed_nodes: [], outcomes: %{}})
    end
  end

  describe "completed without checkpoint-applied outcome" do
    test "halts as completed-but-unapplied when node missing from checkpoint" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_1", outcome)
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      checkpoint = %{
        completed_nodes: ["start"],
        outcomes: %{"start" => %Outcome{status: :success}}
      }

      assert {:error, {:completed_effect_unapplied, "task", "exec_1"}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "progress disagree when record has node but checkpoint does not" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_2", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start"],
        outcomes: %{"start" => %Outcome{status: :success}}
      }

      assert {:error, {:effect_recovery_inconsistent, :progress_disagree}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "completed with exact checkpoint match" do
    test "settles directly when durable progress already agrees" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_ok", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome}
      }

      assert {:ok, :reconcile, [{:settle, 1, "exec_ok"}]} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "syncs checkpoint progress then settles when durable record is behind" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_behind", outcome)
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome}
      }

      assert {:ok, :reconcile,
              [
                {:sync_progress, ["start", "task"]},
                {:settle, 1, "exec_behind"}
              ]} = EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "completed with receipt/progress inconsistency" do
    test "halts on outcome status mismatch" do
      effect_outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      ckpt_outcome = %Outcome{status: :fail, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_st", effect_outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => ckpt_outcome}
      }

      assert {:error, {:effect_recovery_inconsistent, :outcome_status_mismatch}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "halts on result digest mismatch" do
      effect_outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      ckpt_outcome = %Outcome{status: :success, context_updates: %{"k" => "other"}}
      effect = completed_effect("task", "exec_dg", effect_outcome)

      assert effect["result_digest"] == @digest_a
      assert EffectOwner.outcome_result_digest(ckpt_outcome) == @digest_b
      assert @digest_a != @digest_b

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => ckpt_outcome}
      }

      assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "settled" do
    test "continues when record and checkpoint agree with exact receipt" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = settled_effect("task", "exec_set", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome}
      }

      assert {:ok, :continue} = EffectRecoveryCore.decide(record, checkpoint)
    end

    test "halts when settled node missing from durable progress" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = settled_effect("task", "exec_set2", outcome)
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome}
      }

      assert {:error, {:effect_recovery_inconsistent, :settled_progress_missing}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "halts on settled digest mismatch" do
      effect_outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      ckpt_outcome = %Outcome{status: :success, context_updates: %{"k" => "other"}}
      effect = settled_effect("task", "exec_set3", effect_outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => ckpt_outcome}
      }

      assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "invalid envelope" do
    test "rejects malformed current_effect" do
      record = base_record(current_effect: %{"status" => "pending"})

      assert {:error, {:invalid_current_effect, _}} =
               EffectRecoveryCore.decide(record, %{completed_nodes: [], outcomes: %{}})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_record(opts) do
    %Record{
      run_id: "run_l3c_core",
      pipeline_id: "run_l3c_core",
      status: :recovering,
      total_nodes: 3,
      completed_count: length(Keyword.get(opts, :completed_nodes, [])),
      completed_nodes: Keyword.get(opts, :completed_nodes, []),
      effect_generation: 1,
      current_effect: Keyword.get(opts, :current_effect)
    }
  end

  defp pending_effect(node_id, execution_id) do
    {:ok, effect} =
      EffectEnvelope.new_pending(%{
        "generation" => 1,
        "run_id" => "run_l3c_core",
        "node_id" => node_id,
        "execution_id" => execution_id,
        "handler" => "Arbor.Orchestrator.Handlers.ExecHandler",
        "input_hash" => String.duplicate("a", 64),
        "idempotency_class" => "side_effecting",
        "started_at" => "2026-07-15T12:00:00.000000Z"
      })

    effect
  end

  defp completed_effect(node_id, execution_id, %Outcome{} = outcome) do
    pending = pending_effect(node_id, execution_id)

    {:ok, receipt} =
      EffectOwner.receipt_attrs(outcome, "2026-07-15T12:00:01.000000Z")

    {:ok, completed} = EffectEnvelope.complete(pending, receipt)
    completed
  end

  defp settled_effect(node_id, execution_id, %Outcome{} = outcome) do
    completed = completed_effect(node_id, execution_id, outcome)
    {:ok, settled} = EffectEnvelope.settle(completed)
    settled
  end
end
