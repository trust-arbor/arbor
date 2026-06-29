defmodule Arbor.TrustTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust
  alias Arbor.Trust.EventStore
  alias Arbor.Trust.Manager
  alias Arbor.Trust.Store

  setup do
    # Start EventStore
    start_supervised!({EventStore, []})

    # Start Store (ETS-based, no dependencies)
    start_supervised!({Store, []})

    # Start Manager (depends on Store, EventStore)
    start_supervised!(
      {Manager,
       [
         circuit_breaker: false,
         decay: false,
         event_store: true
       ]}
    )

    :ok
  end

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  describe "healthy?/0" do
    test "returns true when Manager is running" do
      assert Trust.healthy?() == true
    end
  end

  # ===========================================================================
  # Trust Profile Management
  # ===========================================================================

  describe "create_trust_profile/1" do
    test "creates a profile via the facade" do
      assert {:ok, profile} = Trust.create_trust_profile("facade_create")
      assert profile.agent_id == "facade_create"
      assert profile.baseline == :ask
    end

    test "profile has correct initial state" do
      {:ok, profile} = Trust.create_trust_profile("facade_init")
      assert profile.frozen == false
      assert profile.security_score == 100.0
      assert profile.rollback_score == 100.0
      assert profile.success_rate_score == 0.0
    end
  end

  describe "get_trust_profile/1" do
    test "returns created profile" do
      {:ok, _} = Trust.create_trust_profile("facade_get")
      assert {:ok, profile} = Trust.get_trust_profile("facade_get")
      assert profile.agent_id == "facade_get"
    end

    test "returns error for non-existent profile" do
      assert {:error, :not_found} = Trust.get_trust_profile("facade_nonexistent")
    end
  end

  # ===========================================================================
  # Trust Events
  # ===========================================================================

  describe "record_trust_event/3" do
    # The scoring/counter feedback loop was removed (tiers-retirement phase 3b):
    # recording an event returns :ok and records the event for audit, but no
    # longer mutates the profile counters/scores.
    test "accepts action_success event without mutating counters" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_success")
      assert :ok = Trust.record_trust_event("facade_evt_success", :action_success, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_success")
      assert profile.total_actions == 0
      assert profile.successful_actions == 0
    end

    test "accepts security_violation event without reducing security score" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_sec")
      assert :ok = Trust.record_trust_event("facade_evt_sec", :security_violation, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_sec")
      assert profile.security_violations == 0
      assert profile.security_score == 100.0
    end

    test "accepts test_passed / test_failed events without mutating counters" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_test")
      assert :ok = Trust.record_trust_event("facade_evt_test", :test_passed, %{})
      assert :ok = Trust.record_trust_event("facade_evt_test", :test_failed, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_test")
      assert profile.total_tests == 0
      assert profile.tests_passed == 0
    end

    test "accepts metadata with events" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_meta")

      assert :ok =
               Trust.record_trust_event("facade_evt_meta", :action_success, %{
                 action: "file_read",
                 duration_ms: 42
               })

      Process.sleep(50)
      {:ok, profile} = Trust.get_trust_profile("facade_evt_meta")
      assert profile.agent_id == "facade_evt_meta"
    end

    test "defaults metadata to empty map" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_no_meta")
      assert :ok = Trust.record_trust_event("facade_evt_no_meta", :action_success)
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_no_meta")
      assert profile.agent_id == "facade_evt_no_meta"
    end
  end

  # ===========================================================================
  # Trust Freezing
  # ===========================================================================

  describe "freeze_trust/2" do
    test "freezes an agent's trust" do
      {:ok, _} = Trust.create_trust_profile("facade_freeze")
      assert :ok = Trust.freeze_trust("facade_freeze", :rapid_failures)

      {:ok, profile} = Trust.get_trust_profile("facade_freeze")
      assert profile.frozen == true
      assert profile.frozen_reason == :rapid_failures
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Trust.freeze_trust("facade_no_freeze", :reason)
    end
  end

  describe "unfreeze_trust/1" do
    test "unfreezes an agent's trust" do
      {:ok, _} = Trust.create_trust_profile("facade_unfreeze")
      :ok = Trust.freeze_trust("facade_unfreeze", :test)
      assert :ok = Trust.unfreeze_trust("facade_unfreeze")

      {:ok, profile} = Trust.get_trust_profile("facade_unfreeze")
      assert profile.frozen == false
      assert profile.frozen_reason == nil
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Trust.unfreeze_trust("facade_no_unfreeze")
    end
  end

  # Trust authorization (check_trust_authorization/2) was removed in the
  # tiers-retirement phase 3c — there is no trust-tier band. Authorization runs
  # on the granular baseline/rules + capability checks (see Policy tests).

  # ===========================================================================
  # Administration
  # ===========================================================================

  describe "list_profiles/0 and list_profiles/1" do
    test "lists all profiles" do
      {:ok, _} = Trust.create_trust_profile("facade_list_a")
      {:ok, _} = Trust.create_trust_profile("facade_list_b")

      {:ok, profiles} = Trust.list_profiles()
      agent_ids = Enum.map(profiles, & &1.agent_id)
      assert "facade_list_a" in agent_ids
      assert "facade_list_b" in agent_ids
    end
  end

  describe "get_events/2" do
    test "returns events for an agent" do
      {:ok, _} = Trust.create_trust_profile("facade_get_events")

      :ok = Trust.record_trust_event("facade_get_events", :action_success, %{})
      Process.sleep(50)

      {:ok, events} = Trust.get_events("facade_get_events")
      assert is_list(events)
      assert events != []
    end

    test "supports limit option" do
      {:ok, _} = Trust.create_trust_profile("facade_events_limit")

      for _ <- 1..5 do
        :ok = Trust.record_trust_event("facade_events_limit", :action_success, %{})
        Process.sleep(10)
      end

      Process.sleep(50)

      {:ok, events} = Trust.get_events("facade_events_limit", limit: 2)
      assert length(events) <= 2
    end
  end

  describe "run_decay_check/0" do
    test "runs without error" do
      assert :ok = Trust.run_decay_check()
    end
  end

  # ===========================================================================
  # Integration: Full trust lifecycle
  # ===========================================================================

  describe "full trust lifecycle" do
    test "create, record events, freeze, unfreeze" do
      # Step 1: Create profile
      {:ok, profile} = Trust.create_trust_profile("lifecycle_agent")
      assert profile.baseline == :ask
      refute profile.frozen

      # Step 2: Record events (no longer mutates counters)
      :ok = Trust.record_trust_event("lifecycle_agent", :action_success, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("lifecycle_agent")
      assert profile.total_actions == 0
      assert profile.successful_actions == 0

      # Step 3: Freeze
      :ok = Trust.freeze_trust("lifecycle_agent", :manual_review)
      {:ok, profile} = Trust.get_trust_profile("lifecycle_agent")
      assert profile.frozen

      # Step 4: Unfreeze
      :ok = Trust.unfreeze_trust("lifecycle_agent")
      {:ok, profile} = Trust.get_trust_profile("lifecycle_agent")
      refute profile.frozen
    end

    test "security violations no longer reduce security component score" do
      {:ok, _} = Trust.create_trust_profile("sec_lifecycle")

      # Recording a security violation no longer mutates the profile
      # (scoring feedback loop removed, tiers-retirement phase 3b).
      :ok = Trust.record_trust_event("sec_lifecycle", :security_violation, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("sec_lifecycle")
      assert profile.security_score == 100.0
      assert profile.security_violations == 0
    end
  end
end
