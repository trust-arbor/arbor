defmodule Arbor.Comms.PendingApprovalSettlementTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Comms
  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRegistry.Authority
  alias Arbor.Contracts.Coding.PendingApprovalIdentity
  alias Arbor.Contracts.Coding.PendingApprovalResourceId
  alias Arbor.Contracts.Comms.Interaction

  setup do
    if Process.whereis(InteractionRegistry) == nil do
      start_supervised!(InteractionRegistry)
    end

    InteractionRegistry.reset()
    :ok
  end

  test "exact match settles by abandonment and proves no longer pending" do
    {:ok, interaction} = put_approval("agent_settle", "user_a", "task_1")
    {:ok, expected} = PendingApprovalIdentity.from_interaction(interaction)
    fields = settle_fields(expected)

    assert {:ok, receipt} = Comms.compare_and_settle_pending_approval(fields)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_type"] == "pending_approval"
    assert receipt["active"] == false
    assert receipt["status"] == "removed"

    assert :not_found = InteractionRegistry.get(interaction.request_id)
    assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)
    assert terminal.status == :abandoned
    assert terminal.reason == :reconciliation_settled
  end

  test "security regression: volatile settlement reuses abandon terminal effects" do
    {:ok, interaction} = put_approval("agent_vol_effects", "user_a", "task_vol")
    {:ok, expected} = PendingApprovalIdentity.from_interaction(interaction)

    assert {:ok, receipt} =
             Comms.compare_and_settle_pending_approval(settle_fields(expected))

    assert receipt["outcome"] == "settled"

    # Same authoritative terminal surface as ordinary abandon: retained terminal,
    # no pending row, late respond rejected.
    assert :not_found = InteractionRegistry.get(interaction.request_id)
    assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)
    assert terminal.status == :abandoned
    assert terminal.reason == :reconciliation_settled
    assert terminal.response == nil

    assert {:error, {:already_terminal, :abandoned}} =
             InteractionRegistry.resolve(interaction.request_id,
               response: :approved,
               metadata: %{decision: :approve}
             )
  end

  test "replay while terminal evidence retained returns already_absent" do
    {:ok, interaction} = put_approval("agent_replay", "user_a", "task_2")
    {:ok, expected} = PendingApprovalIdentity.from_interaction(interaction)
    fields = settle_fields(expected)

    assert {:ok, first} = Comms.compare_and_settle_pending_approval(fields)
    assert first["outcome"] == "settled"

    assert {:ok, second} = Comms.compare_and_settle_pending_approval(fields)
    assert second["outcome"] == "already_absent"
    assert second["active"] == false
  end

  test "security regression: discovery not_found cannot become successful settlement receipt" do
    # Never admitted — Tracker has no authority for this request_id.
    {:ok, resource_id} =
      PendingApprovalResourceId.resource_id("interaction", "irq_undiscovered")

    fields = %{
      "resource_id" => resource_id,
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "approval_id" => "irq_undiscovered",
        "source" => "interaction",
        "task_id" => "task_x",
        "agent_id" => "agent_x",
        "principal_id" => "agent_x",
        "approver_id" => "user_a",
        "resource_uri" => "arbor://shell/exec",
        "action" => "execute",
        "status" => "pending",
        "created_at" => nil
      }
    }

    assert {:error, :current_identity_unavailable} =
             Comms.compare_and_settle_pending_approval(fields)

    assert {:error, :current_identity_unavailable} =
             InteractionRegistry.compare_and_settle_pending_approval(fields)
  end

  test "security regression: stale identity cannot mutate pending interaction" do
    {:ok, interaction} = put_approval("agent_stale", "user_a", "task_stale")
    {:ok, expected} = PendingApprovalIdentity.from_interaction(interaction)
    stale = Map.put(expected, "task_id", "task_other")

    assert {:error, {:reconciliation_identity_conflict, conflict}} =
             Comms.compare_and_settle_pending_approval(settle_fields(stale))

    assert conflict["current_identity"]["task_id"] == "task_stale"
    assert {:ok, %Interaction{}} = InteractionRegistry.get(interaction.request_id)
  end

  test "security regression: duplicate outer keys cannot settle a pending interaction" do
    {:ok, interaction} = put_approval("agent_duplicate", "user_a", "task_duplicate")
    {:ok, expected} = PendingApprovalIdentity.from_interaction(interaction)

    duplicate_keys =
      expected
      |> settle_fields()
      |> Map.put(:resource_id, expected["resource_id"])

    assert {:error, :invalid_reconciliation_settle_fields} =
             Comms.compare_and_settle_pending_approval(duplicate_keys)

    assert {:ok, %Interaction{}} = InteractionRegistry.get(interaction.request_id)
  end

  test "security regression: incomplete source identity is unavailable without mutation" do
    {:ok, interaction} = put_approval("agent_incomplete", "user_a", "task_inc")
    {:ok, expected} = PendingApprovalIdentity.from_interaction(interaction)

    # Corrupt the authoritative pending interaction so projection fails closed.
    # Must not invent kind/submitted_at defaults and settle.
    :sys.replace_state(Authority, fn state ->
      entry = Map.fetch!(state.entries, interaction.request_id)
      broken = %{entry | interaction: %{entry.interaction | agent_id: ""}}
      put_in(state.entries[interaction.request_id], broken)
    end)

    assert {:error, :current_identity_unavailable} =
             Comms.compare_and_settle_pending_approval(settle_fields(expected))

    # Still pending under the authority (restore path not applied).
    assert %{status: :pending} =
             :sys.get_state(Authority).entries[interaction.request_id]
  end

  test "security regression: non-approval kind is rejected without mutation" do
    {:ok, interaction} =
      Interaction.new(%{
        kind: :clarification,
        agent_id: "agent_clarify",
        user_id: "user_a",
        description: "what?",
        metadata: %{task_id: "task_c"}
      })

    assert {:ok, interaction} = InteractionRegistry.put(interaction)

    {:ok, resource_id} =
      PendingApprovalResourceId.resource_id("interaction", interaction.request_id)

    fields = %{
      "resource_id" => resource_id,
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "approval_id" => interaction.request_id,
        "source" => "interaction",
        "task_id" => "task_c",
        "agent_id" => "agent_clarify",
        "principal_id" => "agent_clarify",
        "approver_id" => "user_a",
        "resource_uri" => nil,
        "action" => "clarification",
        "status" => "pending",
        "created_at" => DateTime.to_iso8601(interaction.submitted_at)
      }
    }

    assert {:error, :not_approval_interaction} =
             Comms.compare_and_settle_pending_approval(fields)

    assert {:ok, %Interaction{kind: :clarification}} =
             InteractionRegistry.get(interaction.request_id)
  end

  test "ordinary respond remains available and is not rewritten by settlement" do
    {:ok, interaction} = put_approval("agent_respond", "user_a", "task_resp")

    assert {:ok, ^interaction} =
             InteractionRegistry.resolve(interaction.request_id,
               response: :approved,
               metadata: %{decision: :approve}
             )

    {:ok, expected} = PendingApprovalIdentity.from_interaction(interaction)

    assert {:ok, receipt} =
             Comms.compare_and_settle_pending_approval(settle_fields(expected))

    # Authority observed terminal responded — already_absent, response preserved.
    assert receipt["outcome"] == "already_absent"
    assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)
    assert terminal.status == :responded
    assert terminal.response == :approved
  end

  test "ordinary abandon remains available" do
    {:ok, interaction} = put_approval("agent_abandon", "user_a", "task_ab")
    assert :ok = Comms.abandon_interaction(interaction.request_id, :await_timeout)
    assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)
    assert terminal.status == :abandoned
  end

  test "malformed settle fields are rejected" do
    assert {:error, :invalid_reconciliation_settle_fields} =
             Comms.compare_and_settle_pending_approval(%{})
  end

  test "malformed identity is rejected before approval authority discovery" do
    approval_id = String.duplicate("x", 257)
    resource_id = "approval_" <> String.duplicate("0", 64)

    fields = %{
      "resource_id" => resource_id,
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "approval_id" => approval_id,
        "source" => "interaction",
        "task_id" => "task_malformed",
        "agent_id" => "agent_malformed",
        "principal_id" => "agent_malformed",
        "approver_id" => "user_malformed",
        "resource_uri" => "arbor://shell/exec",
        "action" => "execute",
        "status" => "pending",
        "created_at" => nil
      }
    }

    assert {:error, :invalid_reconciliation_settle_fields} =
             Comms.compare_and_settle_pending_approval(fields)
  end

  defp put_approval(agent_id, user_id, task_id) do
    {:ok, interaction} =
      Interaction.new(%{
        kind: :approval,
        agent_id: agent_id,
        user_id: user_id,
        description: "approve",
        resource_uri: "arbor://shell/exec",
        metadata: %{
          principal_id: agent_id,
          action: "execute",
          task_id: task_id
        }
      })

    InteractionRegistry.put(interaction)
  end

  defp settle_fields(expected) do
    %{
      "resource_id" => expected["resource_id"],
      "expected_identity" => expected
    }
  end
end
