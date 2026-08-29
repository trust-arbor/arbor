defmodule Arbor.Actions.Coding.CrossApp.ProgressFacadeTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CrossApp.ProgressCore
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @inv1 String.duplicate("a", 64)
  @inv2 String.duplicate("b", 64)
  @hex String.duplicate("c", 64)
  @static String.duplicate("d", 64)
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)

  test "progress facade delegates match ProgressCore and stay JSON-clean" do
    assert Actions.coding_cross_app_progress_schema_version() == ProgressCore.schema_version()
    assert Actions.coding_cross_app_progress_limits() == ProgressCore.limits()
    assert {:ok, state} = Actions.coding_cross_app_progress_new(fresh_bindings())
    assert Actions.coding_cross_app_progress_show(state) == ProgressCore.show(state)
    assert {:ok, _} = Jason.encode(Actions.coding_cross_app_progress_show(state))
    assert {:ok, ^state} = Actions.coding_cross_app_progress_admit(state, fresh_bindings())

    [first, second] = plan()

    assert {:ok, completed} =
             Actions.coding_cross_app_progress_advance(state, fresh_bindings(), %{
               "schema_version" => 1,
               "new_receipts" => [passed(first), passed(second)],
               "disposition" => %{"type" => "completed"}
             })

    assert completed["status"] == "completed"
    refute Jason.encode!(completed) =~ "fence_token"
    refute Jason.encode!(completed) =~ "authority"
    assert {:error, :malformed_state} = Actions.coding_cross_app_progress_new(:nope)
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
      "task_id" => "task_progress_facade",
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

  defp fresh_bindings do
    %{
      "identities" => identities(plan()),
      "planned_batches" => plan(),
      "static_stage_receipt_digest" => @static
    }
  end
end
