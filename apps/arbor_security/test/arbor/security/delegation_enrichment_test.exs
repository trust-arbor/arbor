defmodule Arbor.Security.DelegationEnrichmentTest do
  @moduledoc """
  Tests for delegation enrichment:
  - delegated_at timestamp in delegation records
  - by_parent index tracking
  - cascade_revoke functionality
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry

  setup do
    # Generate identities for delegation testing
    {:ok, delegator} = Identity.generate(name: "delegator")
    {:ok, recipient} = Identity.generate(name: "recipient")
    {:ok, second_recipient} = Identity.generate(name: "second-recipient")

    :ok = Registry.register(delegator)
    :ok = Registry.register(recipient)
    :ok = Registry.register(second_recipient)

    # Grant a capability to the delegator
    {:ok, cap} =
      Security.grant(
        principal: delegator.agent_id,
        resource: "arbor://test/delegate/resource",
        delegation_depth: 3
      )

    {:ok,
     delegator: delegator,
     recipient: recipient,
     second_recipient: second_recipient,
     parent_cap: cap}
  end

  # ===========================================================================
  # delegated_at timestamp in sign_delegation
  # ===========================================================================

  describe "Signer.sign_delegation/3 delegated_at" do
    test "includes delegated_at timestamp", %{parent_cap: parent_cap, delegator: delegator} do
      # Create a new capability for the delegation record
      {:ok, new_cap} =
        Capability.delegate(parent_cap, "agent_new_recipient",
          constraints: %{}
        )

      before_time = DateTime.utc_now()

      delegation_record =
        Signer.sign_delegation(parent_cap, new_cap, delegator.private_key)

      after_time = DateTime.utc_now()

      assert Map.has_key?(delegation_record, :delegated_at)
      assert %DateTime{} = delegation_record.delegated_at
      assert DateTime.compare(delegation_record.delegated_at, before_time) in [:eq, :gt]
      assert DateTime.compare(delegation_record.delegated_at, after_time) in [:eq, :lt]
    end

    test "delegation record contains all expected fields", %{
      parent_cap: parent_cap,
      delegator: delegator
    } do
      {:ok, new_cap} =
        Capability.delegate(parent_cap, "agent_recipient",
          constraints: %{custom: "value"}
        )

      delegation_record =
        Signer.sign_delegation(parent_cap, new_cap, delegator.private_key)

      assert Map.has_key?(delegation_record, :delegator_id)
      assert Map.has_key?(delegation_record, :delegator_signature)
      assert Map.has_key?(delegation_record, :constraints)
      assert Map.has_key?(delegation_record, :delegated_at)

      assert delegation_record.delegator_id == parent_cap.principal_id
      assert is_binary(delegation_record.delegator_signature)
      assert delegation_record.constraints == new_cap.constraints
    end
  end

  # ===========================================================================
  # by_parent index tracking
  # ===========================================================================

  describe "by_parent index" do
    test "child capabilities are indexed by parent", %{
      parent_cap: parent_cap,
      delegator: delegator,
      recipient: recipient
    } do
      {:ok, child_cap} =
        Security.delegate(parent_cap.id, recipient.agent_id,
          delegator_private_key: delegator.private_key
        )

      # Verify the child has the parent reference
      assert child_cap.parent_capability_id == parent_cap.id

      # Verify via cascade_revoke that the relationship is tracked
      # (if we revoke parent, child should be revoked too)
      {:ok, count} = CapabilityStore.cascade_revoke(parent_cap.id)

      # Should have revoked both parent and child
      assert count == 2

      # Both should now be gone
      assert {:error, :not_found} = CapabilityStore.get(parent_cap.id)
      assert {:error, :not_found} = CapabilityStore.get(child_cap.id)
    end

    test "multiple children indexed under same parent", %{
      parent_cap: parent_cap,
      delegator: delegator,
      recipient: recipient,
      second_recipient: second_recipient
    } do
      {:ok, child1} =
        Security.delegate(parent_cap.id, recipient.agent_id,
          delegator_private_key: delegator.private_key
        )

      {:ok, child2} =
        Security.delegate(parent_cap.id, second_recipient.agent_id,
          delegator_private_key: delegator.private_key
        )

      # Cascade revoke should get all three
      {:ok, count} = CapabilityStore.cascade_revoke(parent_cap.id)

      assert count == 3
      assert {:error, :not_found} = CapabilityStore.get(parent_cap.id)
      assert {:error, :not_found} = CapabilityStore.get(child1.id)
      assert {:error, :not_found} = CapabilityStore.get(child2.id)
    end
  end

  # ===========================================================================
  # cascade_revoke functionality
  # ===========================================================================

  describe "CapabilityStore.cascade_revoke/1" do
    test "revokes leaf capability (no children)", %{parent_cap: parent_cap} do
      {:ok, count} = CapabilityStore.cascade_revoke(parent_cap.id)

      assert count == 1
      assert {:error, :not_found} = CapabilityStore.get(parent_cap.id)
    end

    test "returns error for unknown capability" do
      assert {:error, :not_found} = CapabilityStore.cascade_revoke("cap_unknown")
    end

    test "handles multi-level delegation tree", %{
      parent_cap: parent_cap,
      delegator: delegator,
      recipient: recipient
    } do
      # Level 1: delegator -> recipient
      {:ok, level1_cap} =
        Security.delegate(parent_cap.id, recipient.agent_id,
          delegator_private_key: delegator.private_key
        )

      # Generate another recipient for level 2
      {:ok, level2_recipient} = Identity.generate(name: "level2-recipient")
      :ok = Registry.register(level2_recipient)

      # Level 2: recipient -> level2_recipient
      {:ok, level2_cap} =
        Security.delegate(level1_cap.id, level2_recipient.agent_id,
          delegator_private_key: recipient.private_key
        )

      # Cascade revoke from root should get all three
      {:ok, count} = CapabilityStore.cascade_revoke(parent_cap.id)

      assert count == 3
      assert {:error, :not_found} = CapabilityStore.get(parent_cap.id)
      assert {:error, :not_found} = CapabilityStore.get(level1_cap.id)
      assert {:error, :not_found} = CapabilityStore.get(level2_cap.id)
    end

    test "cascade from middle revokes subtree only", %{
      parent_cap: parent_cap,
      delegator: delegator,
      recipient: recipient
    } do
      # Create child
      {:ok, child_cap} =
        Security.delegate(parent_cap.id, recipient.agent_id,
          delegator_private_key: delegator.private_key
        )

      # Generate grandchild recipient
      {:ok, grandchild_recipient} = Identity.generate(name: "grandchild")
      :ok = Registry.register(grandchild_recipient)

      {:ok, grandchild_cap} =
        Security.delegate(child_cap.id, grandchild_recipient.agent_id,
          delegator_private_key: recipient.private_key
        )

      # Cascade from child should revoke child and grandchild, but NOT parent
      {:ok, count} = CapabilityStore.cascade_revoke(child_cap.id)

      assert count == 2

      # Parent should still exist
      assert {:ok, _} = CapabilityStore.get(parent_cap.id)

      # Child and grandchild should be gone
      assert {:error, :not_found} = CapabilityStore.get(child_cap.id)
      assert {:error, :not_found} = CapabilityStore.get(grandchild_cap.id)
    end
  end

  # ===========================================================================
  # Stats tracking
  # ===========================================================================

  describe "cascade_revoke stats" do
    test "updates total_cascade_revoked stat", %{
      parent_cap: parent_cap,
      delegator: delegator,
      recipient: recipient
    } do
      {:ok, _child} =
        Security.delegate(parent_cap.id, recipient.agent_id,
          delegator_private_key: delegator.private_key
        )

      stats_before = CapabilityStore.stats()

      {:ok, 2} = CapabilityStore.cascade_revoke(parent_cap.id)

      stats_after = CapabilityStore.stats()

      assert stats_after.total_cascade_revoked == stats_before.total_cascade_revoked + 2
      assert stats_after.total_revoked == stats_before.total_revoked + 2
    end
  end
end
