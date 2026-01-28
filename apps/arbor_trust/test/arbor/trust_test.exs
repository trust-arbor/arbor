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
      assert profile.trust_score == 0
      assert profile.tier == :untrusted
    end

    test "profile has correct initial state" do
      {:ok, profile} = Trust.create_trust_profile("facade_init")
      assert profile.frozen == false
      assert profile.security_score == 100.0
      assert profile.rollback_score == 100.0
      assert profile.success_rate_score == 0.0
      assert profile.trust_points == 0
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

  describe "get_trust_tier/1" do
    test "returns tier for existing agent" do
      {:ok, _} = Trust.create_trust_profile("facade_tier")
      assert {:ok, :untrusted} = Trust.get_trust_tier("facade_tier")
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Trust.get_trust_tier("facade_no_tier")
    end
  end

  # ===========================================================================
  # Trust Scoring
  # ===========================================================================

  describe "calculate_trust_score/1" do
    test "calculates score for existing agent" do
      {:ok, _} = Trust.create_trust_profile("facade_score")
      {:ok, score} = Trust.calculate_trust_score("facade_score")
      assert is_integer(score)
      assert score >= 0
      assert score <= 100
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Trust.calculate_trust_score("facade_no_score")
    end

    test "score changes after trust events" do
      {:ok, _} = Trust.create_trust_profile("facade_score_change")
      {:ok, initial_score} = Trust.calculate_trust_score("facade_score_change")

      # Record some successes and tests to build score
      for _ <- 1..10 do
        :ok = Trust.record_trust_event("facade_score_change", :action_success, %{})
        Process.sleep(10)
      end

      for _ <- 1..5 do
        :ok = Trust.record_trust_event("facade_score_change", :test_passed, %{})
        Process.sleep(10)
      end

      Process.sleep(50)

      {:ok, new_score} = Trust.calculate_trust_score("facade_score_change")
      # Score should have increased from actions and tests
      assert new_score >= initial_score
    end
  end

  # ===========================================================================
  # Trust Events
  # ===========================================================================

  describe "record_trust_event/3" do
    test "records action_success event" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_success")
      assert :ok = Trust.record_trust_event("facade_evt_success", :action_success, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_success")
      assert profile.total_actions == 1
      assert profile.successful_actions == 1
    end

    test "records action_failure event" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_fail")
      assert :ok = Trust.record_trust_event("facade_evt_fail", :action_failure, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_fail")
      assert profile.total_actions == 1
      assert profile.successful_actions == 0
    end

    test "records security_violation event" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_sec")
      assert :ok = Trust.record_trust_event("facade_evt_sec", :security_violation, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_sec")
      assert profile.security_violations == 1
      assert profile.security_score == 80.0
    end

    test "records test_passed event" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_test_pass")
      assert :ok = Trust.record_trust_event("facade_evt_test_pass", :test_passed, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_test_pass")
      assert profile.total_tests == 1
      assert profile.tests_passed == 1
      assert profile.test_pass_score == 100.0
    end

    test "records test_failed event" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_test_fail")
      assert :ok = Trust.record_trust_event("facade_evt_test_fail", :test_failed, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_test_fail")
      assert profile.total_tests == 1
      assert profile.tests_passed == 0
      assert profile.test_pass_score == 0.0
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
      assert profile.total_actions == 1
    end

    test "defaults metadata to empty map" do
      {:ok, _} = Trust.create_trust_profile("facade_evt_no_meta")
      assert :ok = Trust.record_trust_event("facade_evt_no_meta", :action_success)
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("facade_evt_no_meta")
      assert profile.total_actions == 1
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

  # ===========================================================================
  # Trust Authorization
  # ===========================================================================

  describe "check_trust_authorization/2" do
    test "authorizes agent for their tier" do
      {:ok, _} = Trust.create_trust_profile("facade_auth")

      assert {:ok, :authorized} =
               Trust.check_trust_authorization("facade_auth", :untrusted)
    end

    test "rejects agent for higher tier" do
      {:ok, _} = Trust.create_trust_profile("facade_auth_deny")

      assert {:error, :insufficient_trust} =
               Trust.check_trust_authorization("facade_auth_deny", :trusted)
    end

    test "returns :trust_frozen for frozen agent" do
      {:ok, _} = Trust.create_trust_profile("facade_auth_frozen")
      :ok = Trust.freeze_trust("facade_auth_frozen", :test)

      assert {:error, :trust_frozen} =
               Trust.check_trust_authorization("facade_auth_frozen", :untrusted)
    end

    test "returns :not_found for non-existent agent" do
      assert {:error, :not_found} =
               Trust.check_trust_authorization("facade_auth_none", :untrusted)
    end
  end

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

    test "supports tier filter" do
      {:ok, _} = Trust.create_trust_profile("facade_list_filter")

      {:ok, profiles} = Trust.list_profiles(tier: :untrusted)
      agent_ids = Enum.map(profiles, & &1.agent_id)
      assert "facade_list_filter" in agent_ids
    end

    test "returns empty list when no profiles match filter" do
      {:ok, _} = Trust.create_trust_profile("facade_list_no_match")

      {:ok, profiles} = Trust.list_profiles(tier: :autonomous)
      agent_ids = Enum.map(profiles, & &1.agent_id)
      refute "facade_list_no_match" in agent_ids
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
    test "create, record events, check authorization, freeze, unfreeze" do
      # Step 1: Create profile
      {:ok, profile} = Trust.create_trust_profile("lifecycle_agent")
      assert profile.tier == :untrusted

      # Step 2: Record events
      :ok = Trust.record_trust_event("lifecycle_agent", :action_success, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("lifecycle_agent")
      assert profile.total_actions == 1
      assert profile.successful_actions == 1

      # Step 3: Check authorization (should be authorized for untrusted)
      assert {:ok, :authorized} =
               Trust.check_trust_authorization("lifecycle_agent", :untrusted)

      # Step 4: Freeze
      :ok = Trust.freeze_trust("lifecycle_agent", :manual_review)

      assert {:error, :trust_frozen} =
               Trust.check_trust_authorization("lifecycle_agent", :untrusted)

      # Step 5: Unfreeze
      :ok = Trust.unfreeze_trust("lifecycle_agent")

      assert {:ok, :authorized} =
               Trust.check_trust_authorization("lifecycle_agent", :untrusted)

      # Step 6: Verify tier is a valid trust tier
      {:ok, tier} = Trust.get_trust_tier("lifecycle_agent")
      assert tier in [:untrusted, :probationary, :trusted, :veteran, :autonomous]
    end

    test "security violations reduce security component score" do
      {:ok, _} = Trust.create_trust_profile("sec_lifecycle")

      # Record a security violation
      :ok = Trust.record_trust_event("sec_lifecycle", :security_violation, %{})
      Process.sleep(50)

      {:ok, profile} = Trust.get_trust_profile("sec_lifecycle")
      # Security violation reduces security_score from 100 to 80
      assert profile.security_score == 80.0
      assert profile.security_violations == 1
    end
  end
end
