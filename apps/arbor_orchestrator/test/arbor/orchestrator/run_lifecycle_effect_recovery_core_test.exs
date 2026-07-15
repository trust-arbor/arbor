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

  @input_hash_a String.duplicate("a", 64)
  @input_hash_b String.duplicate("b", 64)

  describe "nil / absent current_effect" do
    test "continues and leaves legacy intent handling to the Engine" do
      record = base_record(current_effect: nil)
      checkpoint = %{completed_nodes: ["start"], outcomes: %{}, execution_digests: %{}}

      assert {:ok, :continue} = EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "pending" do
    test "halts as indeterminate even when checkpoint looks advanced" do
      effect = pending_effect("task", "exec_abc")
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => %Outcome{status: :success}},
        execution_digests: %{
          "task" => marker("exec_abc", @input_hash_a, :success)
        }
      }

      assert {:error, {:indeterminate_effect, "task", "exec_abc"}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "never returns reconcile or continue for pending" do
      effect = pending_effect("task", "exec_pending")
      record = base_record(current_effect: effect)

      assert {:error, {:indeterminate_effect, "task", "exec_pending"}} =
               EffectRecoveryCore.decide(record, %{
                 completed_nodes: [],
                 outcomes: %{},
                 execution_digests: %{}
               })
    end
  end

  describe "completed without matching current-visit marker" do
    test "halts as completed-but-unapplied when marker is absent" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_1", outcome)
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      # Outcome alone is not enough without the visit marker.
      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome},
        execution_digests: %{}
      }

      assert {:error, {:completed_effect_unapplied, "task", "exec_1"}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "stale repeated-node marker cannot settle a newer execution (same result digest)" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      # Current effect is a newer visit of the same node with identical outcome bytes.
      effect = completed_effect("task", "exec_new", outcome, input_hash: @input_hash_a)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      # Checkpoint still carries the prior visit's marker (same node_id, same digest).
      checkpoint = %{
        completed_nodes: ["start", "task", "task"],
        outcomes: %{"task" => outcome},
        execution_digests: %{
          "task" => marker("exec_old", @input_hash_a, :success)
        }
      }

      assert effect["result_digest"] == @digest_a

      assert {:error, {:completed_effect_unapplied, "task", "exec_new"}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "completed with same-execution marker mismatches" do
    test "input_hash mismatch is structural inconsistency" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_h", outcome, input_hash: @input_hash_a)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome},
        execution_digests: %{
          "task" => marker("exec_h", @input_hash_b, :success)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :input_hash_mismatch}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "marker outcome_status mismatch is structural inconsistency" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_st", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome},
        execution_digests: %{
          "task" => marker("exec_st", @input_hash_a, :fail)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :outcome_status_mismatch}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "result digest mismatch is structural inconsistency" do
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
        outcomes: %{"task" => ckpt_outcome},
        execution_digests: %{
          "task" => marker("exec_dg", @input_hash_a, :success)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "matching marker but missing outcome is structural inconsistency" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_mo", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{},
        execution_digests: %{
          "task" => marker("exec_mo", @input_hash_a, :success)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :outcome_missing}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "ordered progress (including duplicates)" do
    test "equal lists settle directly" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_ok", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = matching_checkpoint(["start", "task"], "task", "exec_ok", outcome)

      assert {:ok, :reconcile, [{:settle, 1, "exec_ok"}]} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "record strict prefix of checkpoint permits progress sync then settle" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_behind", outcome)
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      checkpoint = matching_checkpoint(["start", "task"], "task", "exec_behind", outcome)

      assert {:ok, :reconcile,
              [
                {:sync_progress, ["start", "task"]},
                {:settle, 1, "exec_behind"}
              ]} = EffectRecoveryCore.decide(record, checkpoint)
    end

    test "checkpoint-behind is structural inconsistency (never overwrite durable progress)" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_cb", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      # Checkpoint has only start, but marker+outcome claim task was applied —
      # ordered lists disagree (record ahead).
      checkpoint = %{
        completed_nodes: ["start"],
        outcomes: %{"task" => outcome},
        execution_digests: %{
          "task" => marker("exec_cb", @input_hash_a, :success)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :ordered_progress_inconsistent}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "same-length divergent lists are structural inconsistency" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_div", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "other"],
        outcomes: %{"task" => outcome},
        execution_digests: %{
          "task" => marker("exec_div", @input_hash_a, :success)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :ordered_progress_inconsistent}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "duplicate node IDs compare as ordered lists (equal with two visits)" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_dup", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task", "task"])

      checkpoint =
        matching_checkpoint(["start", "task", "task"], "task", "exec_dup", outcome)

      assert {:ok, :reconcile, [{:settle, 1, "exec_dup"}]} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "duplicate node IDs: record with one visit is strict prefix of two-visit checkpoint" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_dup2", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint =
        matching_checkpoint(["start", "task", "task"], "task", "exec_dup2", outcome)

      assert {:ok, :reconcile,
              [
                {:sync_progress, ["start", "task", "task"]},
                {:settle, 1, "exec_dup2"}
              ]} = EffectRecoveryCore.decide(record, checkpoint)
    end

    test "duplicate node IDs: same length but different multiplicity positions diverge" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = completed_effect("task", "exec_dup3", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task", "exit"])

      checkpoint = %{
        completed_nodes: ["start", "exit", "task"],
        outcomes: %{"task" => outcome},
        execution_digests: %{
          "task" => marker("exec_dup3", @input_hash_a, :success)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :ordered_progress_inconsistent}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "settled" do
    test "continues when marker, outcome, and ordered progress agree" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = settled_effect("task", "exec_set", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = matching_checkpoint(["start", "task"], "task", "exec_set", outcome)

      assert {:ok, :continue} = EffectRecoveryCore.decide(record, checkpoint)
    end

    test "halts when settled ordered progress is not equal" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = settled_effect("task", "exec_set2", outcome)
      record = base_record(current_effect: effect, completed_nodes: ["start"])

      checkpoint = matching_checkpoint(["start", "task"], "task", "exec_set2", outcome)

      assert {:error, {:effect_recovery_inconsistent, :ordered_progress_inconsistent}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "halts when settled marker is missing" do
      outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      effect = settled_effect("task", "exec_set3", outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => outcome},
        execution_digests: %{}
      }

      assert {:error, {:effect_recovery_inconsistent, :settled_marker_missing}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end

    test "halts on settled digest mismatch" do
      effect_outcome = %Outcome{status: :success, context_updates: %{"k" => "v"}}
      ckpt_outcome = %Outcome{status: :success, context_updates: %{"k" => "other"}}
      effect = settled_effect("task", "exec_set4", effect_outcome)

      record =
        base_record(current_effect: effect, completed_nodes: ["start", "task"])

      checkpoint = %{
        completed_nodes: ["start", "task"],
        outcomes: %{"task" => ckpt_outcome},
        execution_digests: %{
          "task" => marker("exec_set4", @input_hash_a, :success)
        }
      }

      assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
               EffectRecoveryCore.decide(record, checkpoint)
    end
  end

  describe "invalid envelope" do
    test "rejects malformed current_effect" do
      record = base_record(current_effect: %{"status" => "pending"})

      assert {:error, {:invalid_current_effect, _}} =
               EffectRecoveryCore.decide(record, %{
                 completed_nodes: [],
                 outcomes: %{},
                 execution_digests: %{}
               })
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

  defp pending_effect(node_id, execution_id, opts \\ []) do
    input_hash = Keyword.get(opts, :input_hash, @input_hash_a)

    {:ok, effect} =
      EffectEnvelope.new_pending(%{
        "generation" => 1,
        "run_id" => "run_l3c_core",
        "node_id" => node_id,
        "execution_id" => execution_id,
        "handler" => "Arbor.Orchestrator.Handlers.ExecHandler",
        "input_hash" => input_hash,
        "idempotency_class" => "side_effecting",
        "started_at" => "2026-07-15T12:00:00.000000Z"
      })

    effect
  end

  defp completed_effect(node_id, execution_id, %Outcome{} = outcome, opts \\ []) do
    pending = pending_effect(node_id, execution_id, opts)

    {:ok, receipt} =
      EffectOwner.receipt_attrs(outcome, "2026-07-15T12:00:01.000000Z")

    {:ok, completed} = EffectEnvelope.complete(pending, receipt)
    completed
  end

  defp settled_effect(node_id, execution_id, %Outcome{} = outcome, opts \\ []) do
    completed = completed_effect(node_id, execution_id, outcome, opts)
    {:ok, settled} = EffectEnvelope.settle(completed)
    settled
  end

  defp marker(execution_id, input_hash, outcome_status) do
    %{
      execution_id: execution_id,
      input_hash: input_hash,
      outcome_status: outcome_status,
      completed_at: "2026-07-15T12:00:01.000000Z"
    }
  end

  defp matching_checkpoint(completed_nodes, node_id, execution_id, %Outcome{} = outcome) do
    %{
      completed_nodes: completed_nodes,
      outcomes: %{node_id => outcome},
      execution_digests: %{
        node_id => marker(execution_id, @input_hash_a, outcome.status)
      }
    }
  end
end
