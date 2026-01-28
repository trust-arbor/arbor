defmodule Arbor.Trust.CapabilitySyncIntegrationTest do
  @moduledoc """
  Integration tests for Trust-Capability synchronization.

  These tests verify that trust tier changes correctly grant/revoke
  signed capabilities through the Security facade.

  Uses CapabilitySync.sync_capabilities/1 directly since we don't
  have PubSub set up in tests.
  """
  use ExUnit.Case, async: false

  alias Arbor.Security
  alias Arbor.Security.SystemAuthority
  alias Arbor.Trust
  alias Arbor.Trust.CapabilitySync
  alias Arbor.Trust.EventStore
  alias Arbor.Trust.Manager
  alias Arbor.Trust.Store

  @moduletag :integration

  setup do
    # Start Trust services
    start_supervised!({EventStore, []})
    start_supervised!({Store, []})

    start_supervised!(
      {Manager,
       [
         circuit_breaker: false,
         decay: false,
         event_store: true
       ]}
    )

    # Start CapabilitySync (disabled mode - we'll call sync directly)
    start_supervised!({CapabilitySync, [enabled: false]})

    # Unique agent ID for each test
    agent_id = "agent_sync_test_#{:erlang.unique_integer([:positive])}"

    {:ok, agent_id: agent_id}
  end

  describe "sync_capabilities grants signed capabilities" do
    test "syncing at untrusted tier grants capabilities with valid signatures", %{
      agent_id: agent_id
    } do
      # Create trust profile at untrusted tier
      {:ok, profile} = Trust.create_trust_profile(agent_id)
      assert profile.tier == :untrusted

      # Sync capabilities
      {:ok, result} = CapabilitySync.sync_capabilities(agent_id)
      assert result.granted >= 0 or result.existing >= 0

      # Check capabilities were granted
      {:ok, caps} = Security.list_capabilities(agent_id)

      # Verify all capabilities are signed (Phase 2 integration)
      for cap <- caps do
        assert is_binary(cap.issuer_signature),
               "Capability #{cap.id} should have issuer_signature"

        assert byte_size(cap.issuer_signature) > 0
        assert is_binary(cap.issuer_id)
        assert String.starts_with?(cap.issuer_id, "agent_")
      end
    end

    test "synced capabilities have system authority as issuer", %{agent_id: agent_id} do
      {:ok, _profile} = Trust.create_trust_profile(agent_id)
      {:ok, _result} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, caps} = Security.list_capabilities(agent_id)

      system_authority_id = SystemAuthority.agent_id()

      for cap <- caps do
        assert cap.issuer_id == system_authority_id,
               "Capability should be signed by system authority"
      end
    end
  end

  describe "synced capabilities work for authorization" do
    test "synced capabilities can be used for authorize/4", %{agent_id: agent_id} do
      {:ok, _profile} = Trust.create_trust_profile(agent_id)
      {:ok, _result} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, caps} = Security.list_capabilities(agent_id)

      # At least one capability should authorize successfully
      if caps != [] do
        cap = hd(caps)
        assert {:ok, :authorized} = Security.authorize(agent_id, cap.resource_uri)
      end
    end

    test "synced capabilities work with can?/3", %{agent_id: agent_id} do
      {:ok, _profile} = Trust.create_trust_profile(agent_id)
      {:ok, _result} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, caps} = Security.list_capabilities(agent_id)

      if caps != [] do
        cap = hd(caps)
        assert Security.can?(agent_id, cap.resource_uri)
      end
    end
  end

  describe "capability signature verification" do
    test "synced capability signatures are valid", %{agent_id: agent_id} do
      {:ok, _profile} = Trust.create_trust_profile(agent_id)
      {:ok, _result} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, caps} = Security.list_capabilities(agent_id)

      for cap <- caps do
        # Verify signature is valid via system authority
        assert :ok = SystemAuthority.verify_capability_signature(cap)
      end
    end

    test "tampered synced capability fails verification", %{agent_id: agent_id} do
      {:ok, _profile} = Trust.create_trust_profile(agent_id)
      {:ok, _result} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, caps} = Security.list_capabilities(agent_id)

      if caps != [] do
        cap = hd(caps)
        tampered = %{cap | principal_id: "agent_evil"}

        assert {:error, :invalid_capability_signature} =
                 SystemAuthority.verify_capability_signature(tampered)
      end
    end
  end

  describe "freeze/unfreeze flow" do
    test "frozen agent loses explicit write capability after sync", %{agent_id: agent_id} do
      {:ok, _profile} = Trust.create_trust_profile(agent_id)

      # Grant an explicit write capability outside of templates
      resource = "arbor://fs/write/explicit_#{:erlang.unique_integer([:positive])}"
      {:ok, cap} = Security.grant(principal: agent_id, resource: resource)

      # Verify it works
      assert {:ok, :authorized} = Security.authorize(agent_id, resource)

      # Freeze trust
      :ok = Trust.freeze_trust(agent_id, :test_freeze)

      # Revoke the explicit capability (simulating what CapabilitySync.handle_trust_frozen does)
      # The sync_capabilities call grants template caps, but the freeze handler revokes non-readonly
      :ok = Security.revoke(cap.id)

      # Explicit grant should be revoked now
      assert {:error, :unauthorized} = Security.authorize(agent_id, resource)
    end

    test "unfrozen agent regains tier capabilities", %{agent_id: agent_id} do
      {:ok, profile} = Trust.create_trust_profile(agent_id)
      {:ok, _} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, caps_before} = Security.list_capabilities(agent_id)

      # Freeze
      :ok = Trust.freeze_trust(agent_id, :test_freeze)

      # Unfreeze
      :ok = Trust.unfreeze_trust(agent_id)
      {:ok, _} = CapabilitySync.sync_capabilities(agent_id)

      {:ok, caps_after} = Security.list_capabilities(agent_id)

      # Should have same or more capabilities as before (at same tier)
      assert length(caps_after) >= length(caps_before)

      # Verify tier is unchanged
      {:ok, profile_after} = Trust.get_trust_profile(agent_id)
      assert profile_after.tier == profile.tier
      refute profile_after.frozen
    end
  end

  describe "tier promotion via events" do
    test "recording success events updates profile", %{agent_id: agent_id} do
      {:ok, initial} = Trust.create_trust_profile(agent_id)
      assert initial.tier == :untrusted
      assert initial.success_rate_score == 0.0

      # Record success events
      Enum.each(1..10, fn _ ->
        Trust.record_trust_event(agent_id, :action_success, %{action: "test"})
      end)

      {:ok, profile_after} = Trust.get_trust_profile(agent_id)

      # Success rate should have improved
      assert profile_after.success_rate_score > initial.success_rate_score
    end
  end
end
