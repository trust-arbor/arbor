defmodule Arbor.Contracts.Coding.PendingApprovalResourceIdTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.PendingApprovalResourceId

  @moduletag :fast

  test "derives deterministic domain-separated approval resource ids" do
    assert {:ok, consensus_id} = PendingApprovalResourceId.resource_id("consensus", "irq_one")
    assert {:ok, consensus_again} = PendingApprovalResourceId.resource_id(:consensus, "irq_one")
    assert {:ok, interaction_id} = PendingApprovalResourceId.resource_id("interaction", "irq_one")

    assert consensus_id == consensus_again
    assert consensus_id != interaction_id
    assert PendingApprovalResourceId.valid?(consensus_id)
    assert PendingApprovalResourceId.valid?(interaction_id)
    assert String.match?(consensus_id, ~r/\Aapproval_[0-9a-f]{64}\z/)

    preimage =
      IO.iodata_to_binary([
        "arbor:coding:reconciliation:pending_approval:v1",
        0,
        "consensus",
        0,
        "irq_one"
      ])

    expected =
      "approval_" <> Base.encode16(:crypto.hash(:sha256, preimage), case: :lower)

    assert consensus_id == expected
  end

  test "fails closed on malformed or oversized inputs" do
    assert {:error, :invalid_pending_approval_resource_id} =
             PendingApprovalResourceId.resource_id("comms", "irq_one")

    assert {:error, :invalid_pending_approval_resource_id} =
             PendingApprovalResourceId.resource_id("consensus", "")

    assert {:error, :invalid_pending_approval_resource_id} =
             PendingApprovalResourceId.resource_id("consensus", String.duplicate("x", 257))

    assert {:error, :invalid_pending_approval_resource_id} =
             PendingApprovalResourceId.resource_id("consensus", "bad\0id")

    assert {:error, :invalid_pending_approval_resource_id} =
             PendingApprovalResourceId.resource_id("consensus", <<0xFF, 0xFE>>)

    refute PendingApprovalResourceId.valid?("approval_not_hex")
    refute PendingApprovalResourceId.valid?("approval_" <> String.duplicate("A", 64))
    assert PendingApprovalResourceId.sources() == ~w(consensus interaction)
  end
end
