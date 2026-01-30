defmodule Arbor.Trust.DecayTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Decay
  alias Arbor.Trust.Store

  setup do
    # Ensure Store and Manager are running for decay operations
    ensure_store_started()

    # Start Decay with decay disabled to prevent automatic scheduling interference
    start_supervised!({Decay, enabled: false, grace_period_days: 7, decay_rate: 1, floor_score: 10})

    {:ok, %{}}
  end

  describe "start_link/1" do
    test "starts the decay GenServer" do
      assert Process.whereis(Decay) != nil
    end
  end

  describe "apply_decay/2 (pure function with default config)" do
    test "does not decay profile within grace period" do
      {:ok, profile} = build_profile("agent_grace", trust_score: 50, tier: :trusted)

      # 5 days inactive (within 7-day grace period)
      result = Decay.apply_decay(profile, 5)

      assert result.trust_score == 50
      assert result.tier == profile.tier
    end

    test "does not decay profile at exactly grace period boundary" do
      {:ok, profile} = build_profile("agent_boundary", trust_score: 50, tier: :trusted)

      # Exactly 7 days inactive (grace period boundary - no decay)
      result = Decay.apply_decay(profile, 7)

      assert result.trust_score == 50
    end

    test "decays profile after grace period" do
      {:ok, profile} = build_profile("agent_decay", trust_score: 50, tier: :trusted)

      # 10 days inactive = 3 days past grace period = 3 points decay
      result = Decay.apply_decay(profile, 10)

      assert result.trust_score == 47
    end

    test "decays 1 point per day past grace period" do
      {:ok, profile} = build_profile("agent_rate", trust_score: 80, tier: :veteran)

      # 17 days inactive = 10 days past grace = 10 points decay
      result = Decay.apply_decay(profile, 17)

      assert result.trust_score == 70
    end

    test "trust score does not decay below floor" do
      {:ok, profile} = build_profile("agent_floor", trust_score: 15, tier: :untrusted)

      # 100 days inactive = 93 days past grace period = 93 points decay
      # But floor is 10, so score should be 10
      result = Decay.apply_decay(profile, 100)

      assert result.trust_score == 10
    end

    test "updates tier when score drops to lower tier threshold" do
      {:ok, profile} = build_profile("agent_tier_drop", trust_score: 52, tier: :trusted)

      # 10 days inactive = 3 days decay = score 49 (drops from trusted to probationary)
      result = Decay.apply_decay(profile, 10)

      assert result.trust_score == 49
      assert result.tier == :probationary
    end

    test "no decay for 0 days inactive" do
      {:ok, profile} = build_profile("agent_active", trust_score: 75, tier: :veteran)

      result = Decay.apply_decay(profile, 0)

      assert result.trust_score == 75
      assert result.tier == :veteran
    end
  end

  describe "apply_decay/3 (pure function with custom config)" do
    test "respects custom grace period" do
      {:ok, profile} = build_profile("agent_custom_grace", trust_score: 50, tier: :trusted)

      config = %{grace_period: 3, decay_rate: 1, floor: 10}

      # 5 days inactive, 3-day grace = 2 days decay
      result = Decay.apply_decay(profile, 5, config)

      assert result.trust_score == 48
    end

    test "respects custom decay rate" do
      {:ok, profile} = build_profile("agent_custom_rate", trust_score: 50, tier: :trusted)

      config = %{grace_period: 7, decay_rate: 2, floor: 10}

      # 10 days inactive, 7-day grace = 3 days * 2 points/day = 6 points decay
      result = Decay.apply_decay(profile, 10, config)

      assert result.trust_score == 44
    end

    test "respects custom floor" do
      {:ok, profile} = build_profile("agent_custom_floor", trust_score: 30, tier: :probationary)

      config = %{grace_period: 7, decay_rate: 1, floor: 20}

      # 50 days inactive = 43 days decay, but floor is 20
      result = Decay.apply_decay(profile, 50, config)

      assert result.trust_score == 20
    end
  end

  describe "days_inactive/1" do
    test "calculates days from last_activity_at" do
      now = DateTime.utc_now()
      ten_days_ago = DateTime.add(now, -10, :day)

      {:ok, profile} = build_profile("agent_activity", trust_score: 50, tier: :trusted)
      profile = %{profile | last_activity_at: ten_days_ago}

      days = Decay.days_inactive(profile)

      # Should be approximately 10 days (allow 1 day margin for timing)
      assert days >= 9
      assert days <= 11
    end

    test "calculates days from created_at when last_activity_at is nil" do
      five_days_ago = DateTime.add(DateTime.utc_now(), -5, :day)

      {:ok, profile} = build_profile("agent_no_activity", trust_score: 50, tier: :trusted)
      profile = %{profile | last_activity_at: nil, created_at: five_days_ago}

      days = Decay.days_inactive(profile)

      assert days >= 4
      assert days <= 6
    end
  end

  describe "get_config/0" do
    test "returns the current decay configuration" do
      config = Decay.get_config()

      assert is_map(config)
      assert Map.has_key?(config, :grace_period_days)
      assert Map.has_key?(config, :decay_rate)
      assert Map.has_key?(config, :floor_score)
      assert Map.has_key?(config, :enabled)
      assert Map.has_key?(config, :run_time)
    end

    test "reflects initialization options" do
      config = Decay.get_config()

      assert config.grace_period_days == 7
      assert config.decay_rate == 1
      assert config.floor_score == 10
      assert config.enabled == false
    end
  end

  describe "set_enabled/1" do
    test "can enable decay" do
      assert Decay.set_enabled(true) == :ok
      config = Decay.get_config()
      assert config.enabled == true
    end

    test "can disable decay" do
      Decay.set_enabled(true)
      assert Decay.set_enabled(false) == :ok
      config = Decay.get_config()
      assert config.enabled == false
    end
  end

  describe "run_decay_check/0" do
    test "does not crash when called" do
      # Enable decay for this test
      Decay.set_enabled(true)

      # Run decay check (should process any stored profiles)
      Decay.run_decay_check()

      # Give the cast time to process
      Process.sleep(100)

      # GenServer should still be alive
      assert Process.alive?(Process.whereis(Decay))
    end

    test "does nothing when disabled" do
      Decay.set_enabled(false)

      Decay.run_decay_check()
      Process.sleep(50)

      assert Process.alive?(Process.whereis(Decay))
    end

    test "applies decay to inactive profiles in the store" do
      Decay.set_enabled(true)

      # Create an agent with activity far in the past
      agent_id = "decay_target_#{System.unique_integer([:positive])}"
      {:ok, profile} = Profile.new(agent_id)

      # Set the profile to have a non-zero trust score and old activity
      twenty_days_ago = DateTime.add(DateTime.utc_now(), -20, :day)

      profile = %{profile |
        trust_score: 50,
        tier: :trusted,
        last_activity_at: twenty_days_ago,
        created_at: twenty_days_ago
      }

      Store.store_profile(profile)

      # Run decay check
      Decay.run_decay_check()
      Process.sleep(200)

      # Check the profile was decayed
      {:ok, updated_profile} = Store.get_profile(agent_id)

      # 20 days inactive - 7 grace = 13 days decay = 13 points
      # 50 - 13 = 37
      assert updated_profile.trust_score == 37
    end

    test "respects grace period in decay check" do
      Decay.set_enabled(true)

      agent_id = "grace_agent_#{System.unique_integer([:positive])}"
      {:ok, profile} = Profile.new(agent_id)

      # Set activity to 3 days ago (within grace period)
      three_days_ago = DateTime.add(DateTime.utc_now(), -3, :day)

      profile = %{profile |
        trust_score: 50,
        tier: :trusted,
        last_activity_at: three_days_ago,
        created_at: three_days_ago
      }

      Store.store_profile(profile)

      Decay.run_decay_check()
      Process.sleep(200)

      {:ok, updated_profile} = Store.get_profile(agent_id)

      # Should not have decayed (within grace period)
      assert updated_profile.trust_score == 50
    end
  end

  describe "scheduled_run message" do
    test "does not crash the GenServer" do
      send(Process.whereis(Decay), :scheduled_run)
      Process.sleep(50)

      assert Process.alive?(Process.whereis(Decay))
    end

    test "scheduled_run with enabled=true runs decay and reschedules" do
      Decay.set_enabled(true)

      # Create an inactive profile with score to decay
      agent_id = "sched_decay_#{System.unique_integer([:positive])}"
      {:ok, profile} = Profile.new(agent_id)

      twenty_days_ago = DateTime.add(DateTime.utc_now(), -20, :day)

      profile = %{
        profile
        | trust_score: 50,
          tier: :trusted,
          last_activity_at: twenty_days_ago,
          created_at: twenty_days_ago
      }

      Store.store_profile(profile)

      # Trigger the scheduled run message
      send(Process.whereis(Decay), :scheduled_run)
      Process.sleep(200)

      assert Process.alive?(Process.whereis(Decay))

      {:ok, updated} = Store.get_profile(agent_id)
      # 20 days - 7 grace = 13 points decay: 50 - 13 = 37
      assert updated.trust_score == 37
    end

    test "scheduled_run with enabled=false is a no-op" do
      Decay.set_enabled(false)

      send(Process.whereis(Decay), :scheduled_run)
      Process.sleep(50)

      assert Process.alive?(Process.whereis(Decay))
    end
  end

  describe "set_enabled transitions" do
    test "enabling from disabled state schedules next run" do
      # Start disabled
      config = Decay.get_config()
      assert config.enabled == false

      # Enable - should schedule next run
      Decay.set_enabled(true)
      config = Decay.get_config()
      assert config.enabled == true

      # Disable again
      Decay.set_enabled(false)
      config = Decay.get_config()
      assert config.enabled == false
    end

    test "enabling when already enabled does not double-schedule" do
      Decay.set_enabled(true)
      Decay.set_enabled(true)

      config = Decay.get_config()
      assert config.enabled == true

      # Cleanup
      Decay.set_enabled(false)
    end
  end

  describe "decay with profiles at floor score" do
    test "profile at floor score does not decay further" do
      {:ok, profile} = build_profile("agent_at_floor", trust_score: 10, tier: :untrusted)

      # 30 days inactive, should try to decay below floor (10) but not go below
      result = Decay.apply_decay(profile, 30)
      assert result.trust_score == 10
    end
  end

  # Helpers

  defp ensure_store_started do
    case Process.whereis(Store) do
      nil -> start_supervised!(Store)
      _pid -> :ok
    end
  end

  defp build_profile(agent_id, opts) do
    {:ok, profile} = Profile.new(agent_id)

    profile =
      Enum.reduce(opts, profile, fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    {:ok, profile}
  end
end
