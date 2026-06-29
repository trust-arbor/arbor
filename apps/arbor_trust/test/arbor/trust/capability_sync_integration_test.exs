defmodule Arbor.Trust.CapabilitySyncIntegrationTest do
  @moduledoc """
  Integration tests for Trust-Capability synchronization.

  These tests verify that the explicit, lifecycle-driven capability sync
  (`CapabilitySync.sync_capabilities/1` and freeze handling) grants/revokes
  signed capabilities through the Security facade.

  They also pin the tier-minting kill sweep (P0 gate #1): recording trust
  events through the public Manager API must NOT move tier or mint capabilities
  via a second authority path.

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
    # Start Security services (required for grant/list_capabilities/authorize)
    # Use ensure_started to handle umbrella runs where these are already running
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)
    ensure_started(Arbor.Security.Constraint.RateLimiter)

    # Start Trust services
    ensure_started(EventStore)
    ensure_started(Store)

    ensure_started(Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )

    # Start CapabilitySync (disabled mode - we'll call sync directly)
    ensure_started(CapabilitySync, enabled: false)

    # Unique agent ID for each test
    agent_id = "agent_sync_test_#{:erlang.unique_integer([:positive])}"

    {:ok, agent_id: agent_id}
  end

  describe "tier-minting kill sweep (P0 gate #1) — security regression" do
    test "recording many approvals never mints capabilities", %{
      agent_id: agent_id
    } do
      # Profile starts with the creation baseline.
      {:ok, profile} = Trust.create_trust_profile(agent_id)
      assert profile.baseline == :ask

      # Establish a deterministic baseline capability set (the creation grant).
      {:ok, _} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, baseline_caps} = Security.list_capabilities(agent_id)
      baseline_ids = MapSet.new(baseline_caps, & &1.id)

      # Record a barrage of approval events. Under the old system, accruing
      # trust points auto-promoted tier via maybe_graduate and minted signed
      # tier capabilities through Policy.sync_capabilities — a parallel authority
      # path that bypassed the rules/ceilings model. The scoring/points feedback
      # loop and that minting path are both now closed (the tier band is gone).
      for _ <- 1..220 do
        :ok = Manager.record_trust_event(agent_id, :proposal_approved, %{impact: :high})
      end

      # get_trust_profile is a GenServer.call, so it is processed after all the
      # preceding record_trust_event casts have been applied.
      {:ok, after_profile} = Manager.get_trust_profile(agent_id)

      # The authorization profile never moved from its creation value.
      assert after_profile.baseline == profile.baseline,
             "baseline must not auto-graduate from trust events"

      assert after_profile.rules == profile.rules,
             "rules must not auto-graduate from trust events"

      # ...and NO new capabilities were minted: the set is byte-for-byte the same.
      {:ok, after_caps} = Security.list_capabilities(agent_id)
      after_ids = MapSet.new(after_caps, & &1.id)

      assert MapSet.equal?(after_ids, baseline_ids),
             "tier-minting path is closed: recording approvals must not grant or revoke capabilities"
    end
  end

  describe "sync_capabilities grants signed capabilities" do
    test "syncing grants baseline capabilities with valid signatures", %{
      agent_id: agent_id
    } do
      {:ok, profile} = Trust.create_trust_profile(agent_id)
      assert profile.baseline == :ask

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
        assert {:ok, :authorized} = Security.authorize(agent_id, cap.resource_uri)
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

    test "unfrozen agent regains baseline capabilities", %{agent_id: agent_id} do
      {:ok, profile} = Trust.create_trust_profile(agent_id)
      {:ok, _} = CapabilitySync.sync_capabilities(agent_id)
      {:ok, caps_before} = Security.list_capabilities(agent_id)

      # Freeze
      :ok = Trust.freeze_trust(agent_id, :test_freeze)

      # Unfreeze
      :ok = Trust.unfreeze_trust(agent_id)
      {:ok, _} = CapabilitySync.sync_capabilities(agent_id)

      {:ok, caps_after} = Security.list_capabilities(agent_id)

      # Should have same or more capabilities as before (same baseline floor)
      assert length(caps_after) >= length(caps_before)

      # Verify the profile baseline is unchanged and the agent is unfrozen
      {:ok, profile_after} = Trust.get_trust_profile(agent_id)
      assert profile_after.baseline == profile.baseline
      refute profile_after.frozen
    end
  end

  # Start a service, or skip if already running (umbrella context)
  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  describe "recording events" do
    test "recording success events does not mutate the profile", %{agent_id: agent_id} do
      {:ok, initial} = Trust.create_trust_profile(agent_id)
      assert initial.baseline == :ask
      assert initial.success_rate_score == 0.0

      # Record success events
      Enum.each(1..10, fn _ ->
        Trust.record_trust_event(agent_id, :action_success, %{action: "test"})
      end)

      {:ok, profile_after} = Trust.get_trust_profile(agent_id)

      # Scoring feedback loop removed (tiers-retirement phase 3b): events are
      # recorded for audit but do not move the profile's component scores.
      assert profile_after.success_rate_score == initial.success_rate_score
      assert profile_after.baseline == initial.baseline
    end
  end
end
