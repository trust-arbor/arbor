defmodule Arbor.Trust.PointsTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Points

  describe "award/2 - proposal approved" do
    test "awards 5 points for proposal_approved" do
      {:ok, profile} = build_profile("agent_proposal", trust_points: 0)

      {:ok, updated} = Points.award(profile, :proposal_approved)

      assert updated.trust_points == 5
      assert updated.proposals_approved == 1
    end

    test "accumulates points across multiple awards" do
      {:ok, profile} = build_profile("agent_multi", trust_points: 0)

      {:ok, profile} = Points.award(profile, :proposal_approved)
      {:ok, profile} = Points.award(profile, :proposal_approved)
      {:ok, profile} = Points.award(profile, :proposal_approved)

      assert profile.trust_points == 15
      assert profile.proposals_approved == 3
    end
  end

  describe "award/2 - installation successful" do
    test "awards 10 points for installation_successful" do
      {:ok, profile} = build_profile("agent_install", trust_points: 0)

      {:ok, updated} = Points.award(profile, :installation_successful)

      assert updated.trust_points == 10
      assert updated.installations_successful == 1
    end
  end

  describe "award/2 - high impact feature" do
    test "awards 20 points for high_impact_feature" do
      {:ok, profile} = build_profile("agent_high", trust_points: 0)

      {:ok, updated} = Points.award(profile, :high_impact_feature)

      assert updated.trust_points == 20
    end
  end

  describe "award/2 - bug fix" do
    test "awards 3 points for bug_fix_passed" do
      {:ok, profile} = build_profile("agent_bugfix", trust_points: 0)

      {:ok, updated} = Points.award(profile, :bug_fix_passed)

      assert updated.trust_points == 3
    end
  end

  describe "award/2 - documentation improvement" do
    test "awards 1 point for documentation_improvement" do
      {:ok, profile} = build_profile("agent_docs", trust_points: 0)

      {:ok, updated} = Points.award(profile, :documentation_improvement)

      assert updated.trust_points == 1
    end
  end

  describe "award/2 - updates timestamps" do
    test "updates last_activity_at and updated_at" do
      {:ok, profile} = build_profile("agent_timestamps", trust_points: 0)
      old_updated_at = profile.updated_at

      Process.sleep(10)
      {:ok, updated} = Points.award(profile, :proposal_approved)

      assert DateTime.compare(updated.updated_at, old_updated_at) == :gt
      assert updated.last_activity_at != nil
    end
  end

  describe "award/2 - unknown event" do
    test "awards 0 points for unknown event type" do
      {:ok, profile} = build_profile("agent_unknown", trust_points: 10)

      {:ok, updated} = Points.award(profile, :unknown_event)

      assert updated.trust_points == 10
    end
  end

  describe "deduct/2 - implementation failure" do
    test "deducts 5 points for implementation_failure" do
      {:ok, profile} = build_profile("agent_fail", trust_points: 20)

      {:ok, updated} = Points.deduct(profile, :implementation_failure)

      assert updated.trust_points == 15
    end
  end

  describe "deduct/2 - installation rolled back" do
    test "deducts 10 points for installation_rolled_back" do
      {:ok, profile} = build_profile("agent_rollback", trust_points: 20)

      {:ok, updated} = Points.deduct(profile, :installation_rolled_back)

      assert updated.trust_points == 10
      assert updated.installations_rolled_back == 1
    end
  end

  describe "deduct/2 - security violation" do
    test "deducts 20 points for security_violation" do
      {:ok, profile} = build_profile("agent_security", trust_points: 30)

      {:ok, updated} = Points.deduct(profile, :security_violation)

      assert updated.trust_points == 10
      assert updated.security_violations == 1
    end
  end

  describe "deduct/2 - circuit breaker triggered" do
    test "deducts 15 points for circuit_breaker_triggered" do
      {:ok, profile} = build_profile("agent_cb", trust_points: 25)

      {:ok, updated} = Points.deduct(profile, :circuit_breaker_triggered)

      assert updated.trust_points == 10
    end
  end

  describe "deduct/2 - floor at zero" do
    test "points cannot go below zero" do
      {:ok, profile} = build_profile("agent_zero", trust_points: 3)

      {:ok, updated} = Points.deduct(profile, :security_violation)

      assert updated.trust_points == 0
    end

    test "deducting from zero stays at zero" do
      {:ok, profile} = build_profile("agent_at_zero", trust_points: 0)

      {:ok, updated} = Points.deduct(profile, :implementation_failure)

      assert updated.trust_points == 0
    end
  end

  describe "deduct/2 - unknown event" do
    test "deducts 0 points for unknown event type" do
      {:ok, profile} = build_profile("agent_unknown_deduct", trust_points: 10)

      {:ok, updated} = Points.deduct(profile, :unknown_event)

      assert updated.trust_points == 10
    end
  end

  describe "tier_for_points/1" do
    test "returns :untrusted for 0 points" do
      assert Points.tier_for_points(0) == :untrusted
    end

    test "returns :untrusted for points below probationary threshold" do
      assert Points.tier_for_points(24) == :untrusted
    end

    test "returns :probationary at 25 points" do
      assert Points.tier_for_points(25) == :probationary
    end

    test "returns :probationary for points below trusted threshold" do
      assert Points.tier_for_points(99) == :probationary
    end

    test "returns :trusted at 100 points" do
      assert Points.tier_for_points(100) == :trusted
    end

    test "returns :trusted for points below veteran threshold" do
      assert Points.tier_for_points(499) == :trusted
    end

    test "returns :veteran at 500 points" do
      assert Points.tier_for_points(500) == :veteran
    end

    test "returns :veteran for points below autonomous threshold" do
      assert Points.tier_for_points(1999) == :veteran
    end

    test "returns :autonomous at 2000 points" do
      assert Points.tier_for_points(2000) == :autonomous
    end

    test "returns :autonomous for points above threshold" do
      assert Points.tier_for_points(5000) == :autonomous
    end
  end

  describe "min_points_for_tier/1" do
    test "returns 0 for :untrusted" do
      assert Points.min_points_for_tier(:untrusted) == 0
    end

    test "returns 25 for :probationary" do
      assert Points.min_points_for_tier(:probationary) == 25
    end

    test "returns 100 for :trusted" do
      assert Points.min_points_for_tier(:trusted) == 100
    end

    test "returns 500 for :veteran" do
      assert Points.min_points_for_tier(:veteran) == 500
    end

    test "returns 2000 for :autonomous" do
      assert Points.min_points_for_tier(:autonomous) == 2000
    end
  end

  describe "points_to_next_tier/2" do
    test "returns points needed from untrusted to probationary" do
      assert Points.points_to_next_tier(:untrusted, 0) == 25
    end

    test "returns remaining points needed when partially there" do
      assert Points.points_to_next_tier(:untrusted, 10) == 15
    end

    test "returns 0 when already at or above next tier threshold" do
      assert Points.points_to_next_tier(:untrusted, 30) == 0
    end

    test "returns points needed from probationary to trusted" do
      assert Points.points_to_next_tier(:probationary, 50) == 50
    end

    test "returns nil for autonomous (highest tier)" do
      assert Points.points_to_next_tier(:autonomous, 2500) == nil
    end
  end

  describe "next_tier/1" do
    test "returns :probationary for :untrusted" do
      assert Points.next_tier(:untrusted) == :probationary
    end

    test "returns :trusted for :probationary" do
      assert Points.next_tier(:probationary) == :trusted
    end

    test "returns :veteran for :trusted" do
      assert Points.next_tier(:trusted) == :veteran
    end

    test "returns :autonomous for :veteran" do
      assert Points.next_tier(:veteran) == :autonomous
    end

    test "returns nil for :autonomous" do
      assert Points.next_tier(:autonomous) == nil
    end
  end

  describe "points_for_event/1" do
    test "returns {:earn, amount} for award events" do
      assert Points.points_for_event(:proposal_approved) == {:earn, 5}
      assert Points.points_for_event(:installation_successful) == {:earn, 10}
      assert Points.points_for_event(:high_impact_feature) == {:earn, 20}
      assert Points.points_for_event(:bug_fix_passed) == {:earn, 3}
      assert Points.points_for_event(:documentation_improvement) == {:earn, 1}
    end

    test "returns {:lose, amount} for deduction events" do
      assert Points.points_for_event(:implementation_failure) == {:lose, 5}
      assert Points.points_for_event(:installation_rolled_back) == {:lose, 10}
      assert Points.points_for_event(:security_violation) == {:lose, 20}
      assert Points.points_for_event(:circuit_breaker_triggered) == {:lose, 15}
    end

    test "returns :unknown for unrecognized events" do
      assert Points.points_for_event(:completely_unknown) == :unknown
    end
  end

  describe "tier_sufficient?/2" do
    test "same tier is sufficient" do
      assert Points.tier_sufficient?(:trusted, :trusted) == true
    end

    test "higher tier is sufficient for lower requirement" do
      assert Points.tier_sufficient?(:veteran, :trusted) == true
      assert Points.tier_sufficient?(:autonomous, :untrusted) == true
    end

    test "lower tier is not sufficient for higher requirement" do
      assert Points.tier_sufficient?(:untrusted, :trusted) == false
      assert Points.tier_sufficient?(:probationary, :veteran) == false
    end

    test "untrusted is sufficient for untrusted" do
      assert Points.tier_sufficient?(:untrusted, :untrusted) == true
    end

    test "autonomous is sufficient for all tiers" do
      assert Points.tier_sufficient?(:autonomous, :untrusted) == true
      assert Points.tier_sufficient?(:autonomous, :probationary) == true
      assert Points.tier_sufficient?(:autonomous, :trusted) == true
      assert Points.tier_sufficient?(:autonomous, :veteran) == true
      assert Points.tier_sufficient?(:autonomous, :autonomous) == true
    end
  end

  describe "thresholds/0" do
    test "returns the points threshold map" do
      thresholds = Points.thresholds()

      assert is_map(thresholds)
      assert Map.has_key?(thresholds, :untrusted)
      assert Map.has_key?(thresholds, :probationary)
      assert Map.has_key?(thresholds, :trusted)
      assert Map.has_key?(thresholds, :veteran)
      assert Map.has_key?(thresholds, :autonomous)
    end
  end

  describe "points_earned_config/0" do
    test "returns the earning configuration" do
      config = Points.points_earned_config()

      assert is_map(config)
      assert config[:proposal_approved] == 5
      assert config[:installation_successful] == 10
      assert config[:high_impact_feature] == 20
      assert config[:bug_fix_passed] == 3
      assert config[:documentation_improvement] == 1
    end
  end

  describe "points_lost_config/0" do
    test "returns the loss configuration" do
      config = Points.points_lost_config()

      assert is_map(config)
      assert config[:implementation_failure] == 5
      assert config[:installation_rolled_back] == 10
      assert config[:security_violation] == 20
      assert config[:circuit_breaker_triggered] == 15
    end
  end

  describe "points-based tier promotion scenario" do
    test "agent progresses from untrusted to probationary through proposals" do
      {:ok, profile} = build_profile("agent_promote", trust_points: 0)

      # 5 proposals approved = 25 points = probationary
      profile =
        Enum.reduce(1..5, profile, fn _i, acc ->
          {:ok, updated} = Points.award(acc, :proposal_approved)
          updated
        end)

      assert profile.trust_points == 25
      assert Points.tier_for_points(profile.trust_points) == :probationary
    end

    test "agent progresses through multiple tiers" do
      {:ok, profile} = build_profile("agent_progress", trust_points: 0)

      # Start untrusted
      assert Points.tier_for_points(profile.trust_points) == :untrusted

      # Earn 100 points via installations (10 installations)
      profile =
        Enum.reduce(1..10, profile, fn _i, acc ->
          {:ok, updated} = Points.award(acc, :installation_successful)
          updated
        end)

      assert profile.trust_points == 100
      assert Points.tier_for_points(profile.trust_points) == :trusted
    end

    test "agent can lose tier due to deductions" do
      {:ok, profile} = build_profile("agent_demote", trust_points: 30)

      # At 30 points, agent is probationary
      assert Points.tier_for_points(profile.trust_points) == :probationary

      # Security violation deducts 20 points -> 10 points -> untrusted
      {:ok, updated} = Points.deduct(profile, :security_violation)

      assert updated.trust_points == 10
      assert Points.tier_for_points(updated.trust_points) == :untrusted
    end
  end

  describe "award/3 with metadata" do
    test "accepts metadata parameter" do
      {:ok, profile} = build_profile("agent_meta", trust_points: 0)

      {:ok, updated} = Points.award(profile, :proposal_approved, %{proposal_id: "prop_123"})

      assert updated.trust_points == 5
    end
  end

  describe "deduct/3 with metadata" do
    test "accepts metadata parameter" do
      {:ok, profile} = build_profile("agent_meta_deduct", trust_points: 20)

      {:ok, updated} = Points.deduct(profile, :security_violation, %{details: "unauthorized access"})

      assert updated.trust_points == 0
    end
  end

  # Helpers

  defp build_profile(agent_id, opts) do
    {:ok, profile} = Profile.new(agent_id)

    profile =
      Enum.reduce(opts, profile, fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    {:ok, profile}
  end
end
