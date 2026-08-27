defmodule Arbor.Actions.Coding.CrossApp.ContinuationFacadeTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CrossApp.ContinuationCore, as: Core
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @inv1 String.duplicate("a", 64)
  @inv2 String.duplicate("b", 64)
  @hex String.duplicate("c", 64)
  @token "fence-token-1"
  @claimed_at "2026-08-27T12:00:00Z"
  @mid "2026-08-27T12:30:00Z"
  @expires_at "2026-08-27T13:00:00Z"
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)

  test "facade new/show/limits/transitions match ContinuationCore and stay JSON-clean" do
    assert Actions.coding_cross_app_continuation_schema_version() == Core.schema_version()
    assert Actions.coding_cross_app_continuation_limits() == Core.limits()
    assert {:ok, state} = Actions.coding_cross_app_continuation_new(fresh_attrs())
    assert Actions.coding_cross_app_continuation_show(state) == Core.show(state)
    assert {:ok, _} = Jason.encode(Actions.coding_cross_app_continuation_show(state))

    {:ok, claimed, effects} =
      Actions.coding_cross_app_continuation_claim(state, claim_attrs())

    assert {:ok, ^claimed, ^effects} = Core.claim(state, claim_attrs())
    assert {:ok, _} = Jason.encode(effects)

    [first | _] = plan()

    assert {:ok, after_first, _} =
             Actions.coding_cross_app_continuation_accept_passed_receipt(
               claimed,
               fence(claimed, @mid, %{"receipt" => passed(first)})
             )

    structural = v3_handoff(plan(), [], nil, plan(), "structural")

    assert {:ok, _handed, mint_effects} =
             Actions.coding_cross_app_continuation_accept_capacity_handoff(
               claimed,
               fence(claimed, @mid, %{"handoff" => structural})
             )

    assert Enum.any?(mint_effects, &(&1["op"] == "mint_successor"))

    assert {:ok, failed, _} =
             Actions.coding_cross_app_continuation_fail(claimed, fence(claimed, @mid))

    assert failed["status"] == "failed"

    claimed2 = claimed_from(fresh_attrs())

    assert {:ok, cancelled, _} =
             Actions.coding_cross_app_continuation_cancel(claimed2, fence(claimed2, @mid))

    assert cancelled["status"] == "cancelled"

    claimed3 = claimed_from(fresh_attrs())

    assert {:error, :not_expired} =
             Actions.coding_cross_app_continuation_expire_claim(
               claimed3,
               fence(claimed3, @mid)
             )

    assert {:ok, revoked, _} =
             Actions.coding_cross_app_continuation_revoke_claim(
               claimed3,
               fence(claimed3, @mid)
             )

    assert revoked["claim"] == nil

    assert {:error, :incomplete_plan} =
             Actions.coding_cross_app_continuation_complete(
               after_first,
               fence(after_first, @mid)
             )

    assert {:error, :malformed_state} = Actions.coding_cross_app_continuation_new(:nope)

    assert {:error, :malformed_state} =
             Actions.coding_cross_app_continuation_show(DateTime.utc_now())
  end

  test "facade lineage_key and retained_effects are Actions-owned and JSON-clean" do
    {:ok, state} = Actions.coding_cross_app_continuation_new(fresh_attrs())
    {:ok, key} = Actions.coding_cross_app_continuation_lineage_key(state)
    {:ok, core_key} = Core.lineage_key(state)
    assert key == core_key
    assert key =~ ~r/\Axappc_[0-9a-f]{64}\z/

    shuffled = state["identities"] |> Enum.shuffle() |> Map.new()

    {:ok, shuffled_key} =
      Actions.coding_cross_app_continuation_lineage_key(Map.put(state, "identities", shuffled))

    assert shuffled_key == key

    {:ok, claimed, _} = Actions.coding_cross_app_continuation_claim(state, claim_attrs())
    {:ok, retained} = Actions.coding_cross_app_continuation_retained_effects(claimed)
    assert retained["successor"] == nil
    assert retained["terminal"] == nil
    assert {:ok, _} = Jason.encode(retained)

    {:ok, digest} = Actions.coding_cross_app_continuation_digest(%{"operation_id" => "op-1"})
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp plan do
    [batch(1, 2, 1, @inv1), batch(2, 2, 1, @inv2)]
  end

  defp batch(index, total, count, inventory) do
    %{
      "index" => index,
      "total" => total,
      "count" => count,
      "label" => "batch-#{index}-of-#{total}-n#{count}-#{inventory}",
      "inventory_sha256" => inventory
    }
  end

  defp passed(batch), do: Map.put(batch, "outcome", "passed")

  defp identities(plan) do
    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    %{
      "task_id" => "task_continuation_slice1",
      "work_packet_digest" => "sha256:" <> @hex,
      "base_commit" => @base_oid,
      "base_tree_oid" => @base_tree_oid,
      "candidate_head" => @base_oid,
      "candidate_tree_oid" => @candidate_tree_oid,
      "validation_plan_digest" => digest,
      "toolchain_digest" => String.duplicate("3", 64),
      "dependency_baseline_digest" => String.duplicate("4", 64),
      "wrapper_digest" => String.duplicate("5", 64),
      "validator_id" => "coding_cross_app_validate",
      "principal_id" => "agent_principal",
      "configuration_digest" => String.duplicate("6", 64)
    }
  end

  defp fresh_attrs do
    plan = plan()

    %{
      "identities" => identities(plan),
      "planned_batches" => plan,
      "per_batch_budget_ms" => 1_000,
      "static_stage_receipt_digest" => String.duplicate("d", 64)
    }
  end

  defp claim_attrs do
    %{
      "fence_token" => @token,
      "claimed_at" => @claimed_at,
      "expires_at" => @expires_at,
      "now" => @claimed_at
    }
  end

  defp claimed_from(attrs) do
    {:ok, open} = Actions.coding_cross_app_continuation_new(attrs)
    {:ok, claimed, _} = Actions.coding_cross_app_continuation_claim(open, claim_attrs())
    claimed
  end

  defp fence(state, now, extra \\ %{}) do
    Map.merge(
      %{
        "fence_token" => state["claim"]["fence_token"],
        "fence_generation" => state["claim"]["fence_generation"] || state["fence_generation"],
        "now" => now
      },
      extra
    )
  end

  defp v3_handoff(planned, completed, interrupted, unstarted, phase) do
    digest_subject = if interrupted, do: [interrupted | unstarted], else: unstarted
    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(digest_subject)
    completed_files = Enum.reduce(completed, 0, fn batch, acc -> acc + batch["count"] end)
    interrupted_files = if is_map(interrupted), do: interrupted["count"], else: 0
    unstarted_files = Enum.reduce(unstarted, 0, fn batch, acc -> acc + batch["count"] end)

    {:ok, descriptor} =
      ValidationCapacityHandoff.new(%{
        "schema_version" => ValidationCapacityHandoff.schema_version(),
        "phase" => phase,
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 1_000,
        "completed_batch_count" => length(completed),
        "completed_file_count" => completed_files,
        "unstarted_batch_count" => length(unstarted),
        "unstarted_file_count" => unstarted_files,
        "total_batch_count" => length(planned),
        "total_file_count" => completed_files + interrupted_files + unstarted_files,
        "ordered_plan_sha256" => digest,
        "interrupted_batch" => interrupted,
        "unstarted_batches" => unstarted
      })

    ValidationCapacityHandoff.to_map(descriptor)
  end
end
