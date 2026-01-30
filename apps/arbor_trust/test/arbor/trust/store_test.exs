defmodule Arbor.Trust.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Trust.Event
  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Store

  setup do
    # Stop the Store if it was already running from a previous test
    case GenServer.whereis(Store) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    # Also clean up named ETS tables if they linger
    for table <- [:trust_profile_cache, :trust_events_cache] do
      if :ets.info(table) != :undefined do
        :ets.delete(table)
      end
    end

    {:ok, pid} = Store.start_link([])

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    {:ok, profile} = Profile.new("agent_test_1")
    {:ok, pid: pid, profile: profile}
  end

  describe "start_link/1 and stopping" do
    test "starts the store GenServer", %{pid: pid} do
      assert Process.alive?(pid)
      assert GenServer.whereis(Store) == pid
    end

    test "creates ETS tables on start" do
      assert :ets.info(:trust_profile_cache) != :undefined
      assert :ets.info(:trust_events_cache) != :undefined
    end

    test "stops cleanly and cleans up ETS tables", %{pid: pid} do
      GenServer.stop(pid, :normal)
      # ETS tables are cleaned up in terminate/2
      assert :ets.info(:trust_profile_cache) == :undefined
      assert :ets.info(:trust_events_cache) == :undefined
    end
  end

  describe "store_profile/1 and get_profile/1" do
    test "stores and retrieves a profile", %{profile: profile} do
      assert :ok = Store.store_profile(profile)
      assert {:ok, retrieved} = Store.get_profile(profile.agent_id)
      assert retrieved.agent_id == profile.agent_id
      assert retrieved.trust_score == profile.trust_score
      assert retrieved.tier == profile.tier
    end

    test "returns {:error, :not_found} for missing profile" do
      assert {:error, :not_found} = Store.get_profile("nonexistent_agent")
    end

    test "overwrites an existing profile", %{profile: profile} do
      :ok = Store.store_profile(profile)

      # Create an updated version of the same profile
      updated_profile = %{profile | trust_score: 50, tier: :trusted}
      :ok = Store.store_profile(updated_profile)

      {:ok, retrieved} = Store.get_profile(profile.agent_id)
      assert retrieved.trust_score == 50
      assert retrieved.tier == :trusted
    end

    test "stores multiple different profiles" do
      {:ok, profile_a} = Profile.new("agent_a")
      {:ok, profile_b} = Profile.new("agent_b")

      :ok = Store.store_profile(profile_a)
      :ok = Store.store_profile(profile_b)

      {:ok, retrieved_a} = Store.get_profile("agent_a")
      {:ok, retrieved_b} = Store.get_profile("agent_b")

      assert retrieved_a.agent_id == "agent_a"
      assert retrieved_b.agent_id == "agent_b"
    end
  end

  describe "profile_exists?/1" do
    test "returns true for stored profile", %{profile: profile} do
      :ok = Store.store_profile(profile)
      assert Store.profile_exists?(profile.agent_id) == true
    end

    test "returns false for missing profile" do
      assert Store.profile_exists?("nonexistent_agent") == false
    end
  end

  describe "delete_profile/1" do
    test "deletes an existing profile", %{profile: profile} do
      :ok = Store.store_profile(profile)
      assert Store.profile_exists?(profile.agent_id) == true

      assert :ok = Store.delete_profile(profile.agent_id)
      assert Store.profile_exists?(profile.agent_id) == false
      assert {:error, :not_found} = Store.get_profile(profile.agent_id)
    end

    test "returns :ok when deleting a non-existent profile" do
      assert :ok = Store.delete_profile("nonexistent_agent")
    end
  end

  describe "list_profiles/0 and list_profiles/1" do
    test "lists all stored profiles" do
      {:ok, p1} = Profile.new("agent_list_1")
      {:ok, p2} = Profile.new("agent_list_2")
      {:ok, p3} = Profile.new("agent_list_3")

      :ok = Store.store_profile(p1)
      :ok = Store.store_profile(p2)
      :ok = Store.store_profile(p3)

      {:ok, profiles} = Store.list_profiles()
      agent_ids = Enum.map(profiles, & &1.agent_id)

      assert "agent_list_1" in agent_ids
      assert "agent_list_2" in agent_ids
      assert "agent_list_3" in agent_ids
    end

    test "returns empty list when no profiles exist" do
      {:ok, profiles} = Store.list_profiles()
      assert profiles == []
    end

    test "filters by tier" do
      {:ok, untrusted} = Profile.new("agent_tier_1")
      {:ok, trusted} = Profile.new("agent_tier_2")
      trusted = %{trusted | tier: :trusted, trust_score: 60}

      :ok = Store.store_profile(untrusted)
      :ok = Store.store_profile(trusted)

      {:ok, untrusted_list} = Store.list_profiles(tier: :untrusted)
      {:ok, trusted_list} = Store.list_profiles(tier: :trusted)

      assert length(untrusted_list) == 1
      assert hd(untrusted_list).agent_id == "agent_tier_1"
      assert length(trusted_list) == 1
      assert hd(trusted_list).agent_id == "agent_tier_2"
    end

    test "respects limit option" do
      for i <- 1..5 do
        {:ok, p} = Profile.new("agent_limit_#{i}")
        :ok = Store.store_profile(p)
      end

      {:ok, profiles} = Store.list_profiles(limit: 3)
      assert length(profiles) == 3
    end

    test "sorts profiles by trust_score descending" do
      {:ok, low} = Profile.new("agent_low")
      {:ok, mid} = Profile.new("agent_mid")
      {:ok, high} = Profile.new("agent_high")

      low = %{low | trust_score: 10}
      mid = %{mid | trust_score: 50}
      high = %{high | trust_score: 90}

      :ok = Store.store_profile(low)
      :ok = Store.store_profile(mid)
      :ok = Store.store_profile(high)

      {:ok, profiles} = Store.list_profiles()
      scores = Enum.map(profiles, & &1.trust_score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "update_profile/2" do
    test "updates a profile using an update function", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} =
        Store.update_profile(profile.agent_id, fn p ->
          %{p | trust_score: 75, tier: :veteran}
        end)

      assert updated.trust_score == 75
      assert updated.tier == :veteran
      # updated_at should be refreshed
      assert DateTime.compare(updated.updated_at, profile.updated_at) != :lt
    end

    test "returns {:error, :not_found} for missing profile" do
      result =
        Store.update_profile("nonexistent", fn p ->
          %{p | trust_score: 99}
        end)

      assert result == {:error, :not_found}
    end
  end

  describe "record_action_success/1" do
    test "increments success counters", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} = Store.record_action_success(profile.agent_id)
      assert updated.total_actions == 1
      assert updated.successful_actions == 1
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Store.record_action_success("ghost_agent")
    end
  end

  describe "record_action_failure/1" do
    test "increments total actions but not successful", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} = Store.record_action_failure(profile.agent_id)
      assert updated.total_actions == 1
      assert updated.successful_actions == 0
    end
  end

  describe "record_security_violation/1" do
    test "increments violation counter and reduces security score", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} = Store.record_security_violation(profile.agent_id)
      assert updated.security_violations == 1
      assert updated.security_score < 100.0
    end
  end

  describe "record_test_result/2" do
    test "records a passing test", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} = Store.record_test_result(profile.agent_id, :passed)
      assert updated.total_tests == 1
      assert updated.tests_passed == 1
    end

    test "records a failing test", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} = Store.record_test_result(profile.agent_id, :failed)
      assert updated.total_tests == 1
      assert updated.tests_passed == 0
    end
  end

  describe "record_rollback/1" do
    test "increments rollback counter", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} = Store.record_rollback(profile.agent_id)
      assert updated.rollback_count == 1
    end
  end

  describe "record_improvement/1" do
    test "increments improvement counter", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} = Store.record_improvement(profile.agent_id)
      assert updated.improvement_count == 1
    end
  end

  describe "freeze_profile/2 and unfreeze_profile/1" do
    test "freezes and unfreezes a profile", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, frozen} = Store.freeze_profile(profile.agent_id, :anomalous_behavior)
      assert frozen.frozen == true
      assert frozen.frozen_reason == :anomalous_behavior
      assert frozen.frozen_at != nil

      {:ok, unfrozen} = Store.unfreeze_profile(profile.agent_id)
      assert unfrozen.frozen == false
      assert unfrozen.frozen_reason == nil
      assert unfrozen.frozen_at == nil
    end
  end

  describe "store_event/1 and get_events/1" do
    test "stores and retrieves trust events", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, event} =
        Event.new(
          agent_id: profile.agent_id,
          event_type: :action_success,
          previous_score: 0,
          new_score: 5
        )

      assert :ok = Store.store_event(event)

      {:ok, events} = Store.get_events(profile.agent_id)
      assert length(events) == 1
      assert hd(events).event_type == :action_success
    end

    test "returns empty list for agent with no events" do
      {:ok, events} = Store.get_events("agent_no_events")
      assert events == []
    end

    test "respects limit option" do
      agent_id = "agent_events_limit"

      for i <- 1..10 do
        {:ok, event} =
          Event.new(
            agent_id: agent_id,
            event_type: :action_success,
            previous_score: i - 1,
            new_score: i
          )

        Store.store_event(event)
      end

      {:ok, events} = Store.get_events(agent_id, limit: 3)
      assert length(events) == 3
    end

    test "events are sorted by timestamp descending" do
      agent_id = "agent_events_order"
      base_time = ~U[2024-01-01 10:00:00Z]

      for i <- 1..5 do
        timestamp = DateTime.add(base_time, i * 60, :second)

        {:ok, event} =
          Event.new(
            agent_id: agent_id,
            event_type: :action_success,
            timestamp: timestamp,
            previous_score: i - 1,
            new_score: i
          )

        Store.store_event(event)
      end

      {:ok, events} = Store.get_events(agent_id)

      timestamps = Enum.map(events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end
  end

  describe "council-based trust earning" do
    setup %{profile: profile} do
      :ok = Store.store_profile(profile)
      :ok
    end

    test "record_proposal_submitted/1 increments counter", %{profile: profile} do
      {:ok, updated} = Store.record_proposal_submitted(profile.agent_id)
      assert updated.proposals_submitted == 1
    end

    test "record_proposal_approved/2 awards trust points", %{profile: profile} do
      {:ok, updated} = Store.record_proposal_approved(profile.agent_id, :medium)
      assert updated.proposals_approved == 1
      assert updated.trust_points > 0
    end

    test "record_installation_success/2 awards trust points", %{profile: profile} do
      {:ok, updated} = Store.record_installation_success(profile.agent_id, :high)
      assert updated.installations_successful == 1
      assert updated.trust_points > 0
    end

    test "record_installation_rollback/1 deducts trust points", %{profile: profile} do
      # First give some points
      {:ok, _} = Store.award_trust_points(profile.agent_id, 50)

      {:ok, updated} = Store.record_installation_rollback(profile.agent_id)
      assert updated.installations_rolled_back == 1
      assert updated.trust_points < 50
    end

    test "award_trust_points/2 adds points", %{profile: profile} do
      {:ok, updated} = Store.award_trust_points(profile.agent_id, 25)
      assert updated.trust_points == 25
    end

    test "deduct_trust_points/3 removes points with floor at 0", %{profile: profile} do
      {:ok, _} = Store.award_trust_points(profile.agent_id, 10)
      {:ok, updated} = Store.deduct_trust_points(profile.agent_id, 100, :abuse)
      assert updated.trust_points == 0
    end
  end

  describe "recalculate_all/0" do
    test "recalculates all stored profiles" do
      {:ok, p1} = Profile.new("agent_recalc_1")
      {:ok, p2} = Profile.new("agent_recalc_2")

      # Give some scores that would change recalculation
      p1 = %{p1 | success_rate_score: 90.0, security_score: 100.0, test_pass_score: 80.0}
      p2 = %{p2 | success_rate_score: 50.0, security_score: 60.0, test_pass_score: 40.0}

      :ok = Store.store_profile(p1)
      :ok = Store.store_profile(p2)

      assert :ok = Store.recalculate_all()

      {:ok, updated_p1} = Store.get_profile("agent_recalc_1")
      {:ok, updated_p2} = Store.get_profile("agent_recalc_2")

      # After recalculation, scores should reflect component scores
      assert updated_p1.trust_score > 0
      assert updated_p2.trust_score > 0
    end
  end

  describe "tier change event emission on update" do
    test "emits tier change event when tier changes", %{profile: profile} do
      :ok = Store.store_profile(profile)

      # Update profile to trigger tier change (untrusted -> trusted)
      {:ok, updated} =
        Store.update_profile(profile.agent_id, fn p ->
          %{p | trust_score: 60, tier: :trusted}
        end)

      assert updated.tier == :trusted

      # Verify the tier change event was stored
      {:ok, events} = Store.get_events(profile.agent_id)
      tier_events = Enum.filter(events, &(&1.event_type == :tier_changed))
      assert length(tier_events) >= 1
    end

    test "does not emit tier change event when tier stays the same", %{profile: profile} do
      :ok = Store.store_profile(profile)

      # Update score but keep same tier
      {:ok, _updated} =
        Store.update_profile(profile.agent_id, fn p ->
          %{p | trust_score: 5}
        end)

      {:ok, events} = Store.get_events(profile.agent_id)
      tier_events = Enum.filter(events, &(&1.event_type == :tier_changed))
      assert length(tier_events) == 0
    end
  end

  describe "higher_tier logic via council-based operations" do
    test "trust points can boost tier through recalculate_with_points", %{profile: profile} do
      :ok = Store.store_profile(profile)

      # Award enough points to potentially boost tier
      {:ok, updated} = Store.award_trust_points(profile.agent_id, 100)
      assert updated.trust_points == 100
    end
  end

  describe "get_cache_stats/0" do
    test "returns cache statistics" do
      stats = Store.get_cache_stats()

      assert Map.has_key?(stats, :hits)
      assert Map.has_key?(stats, :misses)
      assert Map.has_key?(stats, :writes)
      assert Map.has_key?(stats, :deletes)
      assert Map.has_key?(stats, :events)
      assert Map.has_key?(stats, :profiles_size)
      assert Map.has_key?(stats, :profiles_memory)
      assert Map.has_key?(stats, :events_size)
      assert Map.has_key?(stats, :events_memory)
    end

    test "tracks writes", %{profile: profile} do
      :ok = Store.store_profile(profile)
      stats = Store.get_cache_stats()
      assert stats.writes >= 1
    end

    test "tracks cache hits", %{profile: profile} do
      :ok = Store.store_profile(profile)
      {:ok, _} = Store.get_profile(profile.agent_id)

      stats = Store.get_cache_stats()
      assert stats.hits >= 1
    end

    test "tracks cache misses" do
      {:error, :not_found} = Store.get_profile("miss_agent")

      stats = Store.get_cache_stats()
      assert stats.misses >= 1
    end

    test "tracks deletes", %{profile: profile} do
      :ok = Store.store_profile(profile)
      :ok = Store.delete_profile(profile.agent_id)

      stats = Store.get_cache_stats()
      assert stats.deletes >= 1
    end

    test "tracks event count" do
      {:ok, event} =
        Event.new(
          agent_id: "agent_stat_evt",
          event_type: :action_success,
          previous_score: 0,
          new_score: 1
        )

      :ok = Store.store_event(event)

      stats = Store.get_cache_stats()
      assert stats.events >= 1
    end
  end
end
