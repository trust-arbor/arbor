defmodule Arbor.Contracts.Trust.ProfileTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile

  describe "new/1" do
    test "creates a new profile with valid agent_id" do
      assert {:ok, profile} = Profile.new("agent_123")
      assert profile.agent_id == "agent_123"
      assert profile.trust_score == 0
      assert profile.tier == :untrusted
      assert profile.frozen == false
      assert profile.frozen_reason == nil
      assert profile.frozen_at == nil
    end

    test "initializes component scores correctly" do
      {:ok, profile} = Profile.new("agent_1")
      assert profile.success_rate_score == 0.0
      assert profile.uptime_score == 0.0
      assert profile.security_score == 100.0
      assert profile.test_pass_score == 0.0
      assert profile.rollback_score == 100.0
    end

    test "initializes all counters to zero" do
      {:ok, profile} = Profile.new("agent_1")
      assert profile.total_actions == 0
      assert profile.successful_actions == 0
      assert profile.security_violations == 0
      assert profile.total_tests == 0
      assert profile.tests_passed == 0
      assert profile.rollback_count == 0
      assert profile.improvement_count == 0
    end

    test "initializes trust point fields to zero" do
      {:ok, profile} = Profile.new("agent_1")
      assert profile.trust_points == 0
      assert profile.proposals_submitted == 0
      assert profile.proposals_approved == 0
      assert profile.installations_successful == 0
      assert profile.installations_rolled_back == 0
    end

    test "sets created_at and updated_at timestamps" do
      {:ok, profile} = Profile.new("agent_1")
      assert %DateTime{} = profile.created_at
      assert %DateTime{} = profile.updated_at
      assert profile.last_activity_at == nil
    end

    test "returns error for empty string agent_id" do
      assert {:error, :invalid_agent_id} = Profile.new("")
    end

    test "returns error for non-string agent_id" do
      assert {:error, :invalid_agent_id} = Profile.new(123)
      assert {:error, :invalid_agent_id} = Profile.new(nil)
      assert {:error, :invalid_agent_id} = Profile.new(:atom_id)
    end
  end

  describe "record_action_success/1" do
    test "increments total_actions and successful_actions" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_action_success(profile)

      assert updated.total_actions == 1
      assert updated.successful_actions == 1
    end

    test "updates success_rate_score" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_action_success(profile)

      assert updated.success_rate_score == 100.0
    end

    test "calculates correct success rate after mixed results" do
      {:ok, profile} = Profile.new("agent_1")

      updated =
        profile
        |> Profile.record_action_success()
        |> Profile.record_action_success()
        |> Profile.record_action_failure()

      # 2 successes out of 3 total
      assert updated.total_actions == 3
      assert updated.successful_actions == 2
      assert_in_delta updated.success_rate_score, 66.67, 0.01
    end

    test "sets last_activity_at" do
      {:ok, profile} = Profile.new("agent_1")
      assert profile.last_activity_at == nil

      updated = Profile.record_action_success(profile)
      assert %DateTime{} = updated.last_activity_at
    end
  end

  describe "record_action_failure/1" do
    test "increments total_actions but not successful_actions" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_action_failure(profile)

      assert updated.total_actions == 1
      assert updated.successful_actions == 0
    end

    test "updates success_rate_score to 0 for all failures" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_action_failure(profile)

      assert updated.success_rate_score == 0.0
    end

    test "sets last_activity_at" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_action_failure(profile)
      assert %DateTime{} = updated.last_activity_at
    end
  end

  describe "record_security_violation/1" do
    test "increments security_violations counter" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_security_violation(profile)

      assert updated.security_violations == 1
    end

    test "reduces security_score by 20 per violation" do
      {:ok, profile} = Profile.new("agent_1")
      assert profile.security_score == 100.0

      updated = Profile.record_security_violation(profile)
      assert updated.security_score == 80.0

      updated2 = Profile.record_security_violation(updated)
      assert updated2.security_score == 60.0
    end

    test "security_score floors at 0.0" do
      {:ok, profile} = Profile.new("agent_1")

      # Record 6 violations (6 * 20 = 120, but floor at 0)
      updated =
        Enum.reduce(1..6, profile, fn _i, acc ->
          Profile.record_security_violation(acc)
        end)

      assert updated.security_score == 0.0
      assert updated.security_violations == 6
    end

    test "sets last_activity_at" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_security_violation(profile)
      assert %DateTime{} = updated.last_activity_at
    end
  end

  describe "record_test_result/2" do
    test "records passed test correctly" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_test_result(profile, :passed)

      assert updated.total_tests == 1
      assert updated.tests_passed == 1
      assert updated.test_pass_score == 100.0
    end

    test "records failed test correctly" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_test_result(profile, :failed)

      assert updated.total_tests == 1
      assert updated.tests_passed == 0
      assert updated.test_pass_score == 0.0
    end

    test "calculates correct test pass rate with mixed results" do
      {:ok, profile} = Profile.new("agent_1")

      updated =
        profile
        |> Profile.record_test_result(:passed)
        |> Profile.record_test_result(:passed)
        |> Profile.record_test_result(:passed)
        |> Profile.record_test_result(:failed)

      # 3 passed out of 4
      assert updated.total_tests == 4
      assert updated.tests_passed == 3
      assert updated.test_pass_score == 75.0
    end

    test "sets last_activity_at" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_test_result(profile, :passed)
      assert %DateTime{} = updated.last_activity_at
    end
  end

  describe "record_rollback/1" do
    test "increments rollback_count" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_rollback(profile)

      assert updated.rollback_count == 1
    end

    test "keeps rollback_score at 100 when no improvements recorded" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_rollback(profile)

      # improvement_count is 0, so score stays at 100.0
      assert updated.rollback_score == 100.0
    end

    test "reduces rollback_score based on rollback-to-improvement ratio" do
      {:ok, profile} = Profile.new("agent_1")

      # Record some improvements first
      profile = %{profile | improvement_count: 10}

      # 1 rollback out of 10 improvements = 10% ratio = 100 - 10 = 90
      updated = Profile.record_rollback(profile)
      assert_in_delta updated.rollback_score, 90.0, 0.01
    end

    test "sets last_activity_at" do
      {:ok, profile} = Profile.new("agent_1")
      updated = Profile.record_rollback(profile)
      assert %DateTime{} = updated.last_activity_at
    end
  end

  describe "freeze/2" do
    test "sets frozen to true with reason" do
      {:ok, profile} = Profile.new("agent_1")
      frozen = Profile.freeze(profile, :rapid_failures)

      assert frozen.frozen == true
      assert frozen.frozen_reason == :rapid_failures
      assert %DateTime{} = frozen.frozen_at
    end

    test "preserves other profile fields" do
      {:ok, profile} = Profile.new("agent_1")
      profile = Profile.record_action_success(profile)
      frozen = Profile.freeze(profile, :security_violation)

      assert frozen.agent_id == "agent_1"
      assert frozen.total_actions == 1
      assert frozen.successful_actions == 1
    end
  end

  describe "unfreeze/1" do
    test "sets frozen to false and clears reason and timestamp" do
      {:ok, profile} = Profile.new("agent_1")
      frozen = Profile.freeze(profile, :rapid_failures)
      unfrozen = Profile.unfreeze(frozen)

      assert unfrozen.frozen == false
      assert unfrozen.frozen_reason == nil
      assert unfrozen.frozen_at == nil
    end

    test "preserves other profile fields" do
      {:ok, profile} = Profile.new("agent_1")
      profile = Profile.record_action_success(profile)

      unfrozen =
        profile
        |> Profile.freeze(:test_reason)
        |> Profile.unfreeze()

      assert unfrozen.agent_id == "agent_1"
      assert unfrozen.total_actions == 1
      assert unfrozen.successful_actions == 1
    end
  end

  describe "apply_decay/2" do
    test "does not decay within 7-day grace period" do
      {:ok, profile} = Profile.new("agent_1")
      profile = %{profile | trust_score: 50, tier: :trusted}

      assert Profile.apply_decay(profile, 0).trust_score == 50
      assert Profile.apply_decay(profile, 5).trust_score == 50
      assert Profile.apply_decay(profile, 7).trust_score == 50
    end

    test "decays 1 point per day after grace period" do
      {:ok, profile} = Profile.new("agent_1")
      profile = %{profile | trust_score: 50, tier: :trusted}

      # 8 days inactive = 1 day past grace = decay 1 point
      decayed = Profile.apply_decay(profile, 8)
      assert decayed.trust_score == 49

      # 10 days inactive = 3 days past grace = decay 3 points
      decayed = Profile.apply_decay(profile, 10)
      assert decayed.trust_score == 47
    end

    test "does not decay below floor of 10" do
      {:ok, profile} = Profile.new("agent_1")
      profile = %{profile | trust_score: 15}

      # 100 days inactive = 93 days past grace, but floor at 10
      decayed = Profile.apply_decay(profile, 100)
      assert decayed.trust_score == 10
    end

    test "updates tier after decay" do
      {:ok, profile} = Profile.new("agent_1")
      profile = %{profile | trust_score: 51, tier: :trusted}

      # Decay from trusted (51) to below 50 -> probationary
      decayed = Profile.apply_decay(profile, 10)
      assert decayed.trust_score == 48
      assert decayed.tier == :probationary
    end
  end

  describe "recalculate/1" do
    test "calculates trust score from component scores with default weights" do
      {:ok, profile} = Profile.new("agent_1")

      # Set known component scores
      profile = %{
        profile
        | success_rate_score: 80.0,
          uptime_score: 90.0,
          security_score: 100.0,
          test_pass_score: 70.0,
          rollback_score: 100.0
      }

      recalculated = Profile.recalculate(profile)

      # Expected: 80*0.30 + 90*0.15 + 100*0.25 + 70*0.20 + 100*0.10
      # = 24 + 13.5 + 25 + 14 + 10 = 86.5 -> rounds to 87 (or 86 depending on rounding)
      expected = round(80 * 0.30 + 90 * 0.15 + 100 * 0.25 + 70 * 0.20 + 100 * 0.10)
      assert recalculated.trust_score == expected
    end

    test "sets appropriate tier based on calculated score" do
      {:ok, profile} = Profile.new("agent_1")

      # All scores at 100 -> trust_score = 100 -> autonomous
      profile = %{
        profile
        | success_rate_score: 100.0,
          uptime_score: 100.0,
          security_score: 100.0,
          test_pass_score: 100.0,
          rollback_score: 100.0
      }

      recalculated = Profile.recalculate(profile)
      assert recalculated.trust_score == 100
      assert recalculated.tier == :autonomous
    end

    test "untrusted tier for all-zero component scores" do
      {:ok, profile} = Profile.new("agent_1")

      # Zero out the default non-zero scores (security and rollback start at 100)
      profile = %{
        profile
        | success_rate_score: 0.0,
          uptime_score: 0.0,
          security_score: 0.0,
          test_pass_score: 0.0,
          rollback_score: 0.0
      }

      recalculated = Profile.recalculate(profile)
      assert recalculated.trust_score == 0
      assert recalculated.tier == :untrusted
    end

    test "updates updated_at timestamp" do
      {:ok, profile} = Profile.new("agent_1")
      before = profile.updated_at

      # Small sleep to ensure different timestamp
      Process.sleep(1)
      recalculated = Profile.recalculate(profile)
      assert DateTime.compare(recalculated.updated_at, before) in [:gt, :eq]
    end
  end

  describe "recalculate/2 with custom weights" do
    test "uses custom weights for score calculation" do
      {:ok, profile} = Profile.new("agent_1")

      profile = %{
        profile
        | success_rate_score: 100.0,
          uptime_score: 0.0,
          security_score: 0.0,
          test_pass_score: 0.0,
          rollback_score: 0.0
      }

      # Only weight success_rate
      weights = %{success_rate: 1.0, uptime: 0.0, security: 0.0, test_pass: 0.0, rollback: 0.0}
      recalculated = Profile.recalculate(profile, weights)

      assert recalculated.trust_score == 100
      assert recalculated.tier == :autonomous
    end

    test "different weights produce different scores" do
      {:ok, profile} = Profile.new("agent_1")

      profile = %{
        profile
        | success_rate_score: 100.0,
          uptime_score: 50.0,
          security_score: 0.0,
          test_pass_score: 0.0,
          rollback_score: 0.0
      }

      heavy_success = %{
        success_rate: 0.80,
        uptime: 0.20,
        security: 0.0,
        test_pass: 0.0,
        rollback: 0.0
      }

      heavy_uptime = %{
        success_rate: 0.20,
        uptime: 0.80,
        security: 0.0,
        test_pass: 0.0,
        rollback: 0.0
      }

      result_success = Profile.recalculate(profile, heavy_success)
      result_uptime = Profile.recalculate(profile, heavy_uptime)

      # Heavy success weight should yield higher score since success_rate is 100 vs uptime 50
      assert result_success.trust_score > result_uptime.trust_score
    end
  end

  describe "to_map/1" do
    test "converts profile struct to a plain map" do
      {:ok, profile} = Profile.new("agent_1")
      map = Profile.to_map(profile)

      assert is_map(map)
      refute is_struct(map)
      assert map.agent_id == "agent_1"
      assert map.trust_score == 0
      assert map.tier == :untrusted
    end

    test "includes all fields" do
      {:ok, profile} = Profile.new("agent_1")
      map = Profile.to_map(profile)

      expected_keys = [
        :agent_id,
        :trust_score,
        :tier,
        :frozen,
        :frozen_reason,
        :frozen_at,
        :success_rate_score,
        :uptime_score,
        :security_score,
        :test_pass_score,
        :rollback_score,
        :total_actions,
        :successful_actions,
        :security_violations,
        :total_tests,
        :tests_passed,
        :rollback_count,
        :improvement_count,
        :trust_points,
        :proposals_submitted,
        :proposals_approved,
        :installations_successful,
        :installations_rolled_back,
        :created_at,
        :updated_at,
        :last_activity_at
      ]

      for key <- expected_keys do
        assert Map.has_key?(map, key), "Expected map to have key #{inspect(key)}"
      end
    end
  end

  describe "tier boundaries" do
    test "score 0 maps to :untrusted" do
      {:ok, profile} = Profile.new("agent_1")

      profile = %{
        profile
        | success_rate_score: 0.0,
          uptime_score: 0.0,
          security_score: 0.0,
          test_pass_score: 0.0,
          rollback_score: 0.0
      }

      recalculated = Profile.recalculate(profile)
      assert recalculated.trust_score == 0
      assert recalculated.tier == :untrusted
    end

    test "score 19 maps to :untrusted" do
      {:ok, profile} = Profile.new("agent_1")

      # Set scores to produce ~19
      profile = %{
        profile
        | success_rate_score: 19.0,
          uptime_score: 19.0,
          security_score: 19.0,
          test_pass_score: 19.0,
          rollback_score: 19.0
      }

      recalculated = Profile.recalculate(profile)
      assert recalculated.trust_score == 19
      assert recalculated.tier == :untrusted
    end

    test "score 50 maps to :trusted" do
      {:ok, profile} = Profile.new("agent_1")

      profile = %{
        profile
        | success_rate_score: 50.0,
          uptime_score: 50.0,
          security_score: 50.0,
          test_pass_score: 50.0,
          rollback_score: 50.0
      }

      recalculated = Profile.recalculate(profile)
      assert recalculated.trust_score == 50
      assert recalculated.tier == :trusted
    end

    test "score 90 maps to :autonomous" do
      {:ok, profile} = Profile.new("agent_1")

      profile = %{
        profile
        | success_rate_score: 90.0,
          uptime_score: 90.0,
          security_score: 90.0,
          test_pass_score: 90.0,
          rollback_score: 90.0
      }

      recalculated = Profile.recalculate(profile)
      assert recalculated.trust_score == 90
      assert recalculated.tier == :autonomous
    end
  end

  describe "integration: full lifecycle" do
    test "agent progresses through actions and recalculation" do
      {:ok, profile} = Profile.new("lifecycle_agent")

      # Record several successes
      profile =
        Enum.reduce(1..10, profile, fn _i, acc ->
          Profile.record_action_success(acc)
        end)

      assert profile.total_actions == 10
      assert profile.successful_actions == 10
      assert profile.success_rate_score == 100.0

      # Record tests
      profile =
        Enum.reduce(1..5, profile, fn _i, acc ->
          Profile.record_test_result(acc, :passed)
        end)

      assert profile.tests_passed == 5
      assert profile.test_pass_score == 100.0

      # Set uptime manually for recalculation
      profile = %{profile | uptime_score: 80.0}

      # Recalculate: success=100*0.30 + uptime=80*0.15 + security=100*0.25 + test=100*0.20 + rollback=100*0.10
      # = 30 + 12 + 25 + 20 + 10 = 97
      recalculated = Profile.recalculate(profile)
      assert recalculated.trust_score == 97
      assert recalculated.tier == :autonomous
    end

    test "freeze and unfreeze round-trip preserves data" do
      {:ok, profile} = Profile.new("freeze_agent")
      profile = Profile.record_action_success(profile)

      frozen = Profile.freeze(profile, :test_reason)
      assert frozen.frozen == true

      unfrozen = Profile.unfreeze(frozen)
      assert unfrozen.frozen == false
      assert unfrozen.agent_id == "freeze_agent"
      assert unfrozen.total_actions == 1
      assert unfrozen.successful_actions == 1
    end
  end
end
