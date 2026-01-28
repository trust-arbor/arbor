defmodule Arbor.Trust.CalculatorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Calculator

  # Helper to build a profile with given component scores
  defp build_profile(attrs \\ %{}) do
    now = DateTime.utc_now()

    defaults = %{
      agent_id: "test_agent",
      trust_score: 0,
      tier: :untrusted,
      frozen: false,
      success_rate_score: 0.0,
      uptime_score: 0.0,
      security_score: 100.0,
      test_pass_score: 0.0,
      rollback_score: 100.0,
      total_actions: 0,
      successful_actions: 0,
      security_violations: 0,
      total_tests: 0,
      tests_passed: 0,
      rollback_count: 0,
      improvement_count: 0,
      trust_points: 0,
      proposals_submitted: 0,
      proposals_approved: 0,
      installations_successful: 0,
      installations_rolled_back: 0,
      created_at: now,
      updated_at: now,
      last_activity_at: nil
    }

    struct!(Profile, Map.merge(defaults, attrs))
  end

  # Standard weights used across tests
  @weights %{
    success_rate: 0.30,
    uptime: 0.15,
    security: 0.25,
    test_pass: 0.20,
    rollback: 0.10
  }

  describe "calculate/2 with explicit weights" do
    test "returns 0 when all component scores are zero" do
      profile = build_profile(%{
        success_rate_score: 0.0,
        uptime_score: 0.0,
        security_score: 0.0,
        test_pass_score: 0.0,
        rollback_score: 0.0
      })

      assert Calculator.calculate(profile, @weights) == 0
    end

    test "returns 100 when all component scores are 100" do
      profile = build_profile(%{
        success_rate_score: 100.0,
        uptime_score: 100.0,
        security_score: 100.0,
        test_pass_score: 100.0,
        rollback_score: 100.0
      })

      assert Calculator.calculate(profile, @weights) == 100
    end

    test "calculates a properly weighted sum" do
      profile = build_profile(%{
        success_rate_score: 85.0,
        uptime_score: 100.0,
        security_score: 80.0,
        test_pass_score: 90.0,
        rollback_score: 95.0
      })

      # Expected: 85*0.30 + 100*0.15 + 80*0.25 + 90*0.20 + 95*0.10
      #         = 25.5   + 15.0   + 20.0   + 18.0   + 9.5
      #         = 88.0
      assert Calculator.calculate(profile, @weights) == 88
    end

    test "rounds to nearest integer" do
      profile = build_profile(%{
        success_rate_score: 70.0,
        uptime_score: 50.0,
        security_score: 60.0,
        test_pass_score: 40.0,
        rollback_score: 80.0
      })

      # Expected: 70*0.30 + 50*0.15 + 60*0.25 + 40*0.20 + 80*0.10
      #         = 21.0   + 7.5    + 15.0   + 8.0    + 8.0
      #         = 59.5 => rounds to 60
      assert Calculator.calculate(profile, @weights) == 60
    end

    test "clamps score to minimum of 0" do
      # This shouldn't happen normally, but Calculator defensively clamps
      profile = build_profile(%{
        success_rate_score: 0.0,
        uptime_score: 0.0,
        security_score: 0.0,
        test_pass_score: 0.0,
        rollback_score: 0.0
      })

      assert Calculator.calculate(profile, @weights) >= 0
    end

    test "clamps score to maximum of 100" do
      profile = build_profile(%{
        success_rate_score: 100.0,
        uptime_score: 100.0,
        security_score: 100.0,
        test_pass_score: 100.0,
        rollback_score: 100.0
      })

      assert Calculator.calculate(profile, @weights) <= 100
    end

    test "handles mixed high and low scores" do
      profile = build_profile(%{
        success_rate_score: 100.0,
        uptime_score: 0.0,
        security_score: 100.0,
        test_pass_score: 0.0,
        rollback_score: 100.0
      })

      # Expected: 100*0.30 + 0*0.15 + 100*0.25 + 0*0.20 + 100*0.10
      #         = 30.0    + 0.0    + 25.0    + 0.0    + 10.0
      #         = 65.0
      assert Calculator.calculate(profile, @weights) == 65
    end

    test "security weight dominates with only security score" do
      profile = build_profile(%{
        success_rate_score: 0.0,
        uptime_score: 0.0,
        security_score: 100.0,
        test_pass_score: 0.0,
        rollback_score: 0.0
      })

      # Expected: 0 + 0 + 100*0.25 + 0 + 0 = 25
      assert Calculator.calculate(profile, @weights) == 25
    end

    test "success_rate weight is the largest single factor" do
      profile = build_profile(%{
        success_rate_score: 100.0,
        uptime_score: 0.0,
        security_score: 0.0,
        test_pass_score: 0.0,
        rollback_score: 0.0
      })

      # Expected: 100*0.30 = 30
      assert Calculator.calculate(profile, @weights) == 30
    end

    test "uptime weight is the smallest non-rollback factor" do
      profile = build_profile(%{
        success_rate_score: 0.0,
        uptime_score: 100.0,
        security_score: 0.0,
        test_pass_score: 0.0,
        rollback_score: 0.0
      })

      # Expected: 100*0.15 = 15
      assert Calculator.calculate(profile, @weights) == 15
    end

    test "rollback weight is the smallest factor" do
      profile = build_profile(%{
        success_rate_score: 0.0,
        uptime_score: 0.0,
        security_score: 0.0,
        test_pass_score: 0.0,
        rollback_score: 100.0
      })

      # Expected: 100*0.10 = 10
      assert Calculator.calculate(profile, @weights) == 10
    end

    test "custom weights override defaults" do
      profile = build_profile(%{
        success_rate_score: 100.0,
        uptime_score: 0.0,
        security_score: 0.0,
        test_pass_score: 0.0,
        rollback_score: 0.0
      })

      custom_weights = %{
        success_rate: 1.0,
        uptime: 0.0,
        security: 0.0,
        test_pass: 0.0,
        rollback: 0.0
      }

      assert Calculator.calculate(profile, custom_weights) == 100
    end

    test "partial custom weights fall back to module defaults for missing keys" do
      profile = build_profile(%{
        success_rate_score: 100.0,
        uptime_score: 100.0,
        security_score: 100.0,
        test_pass_score: 100.0,
        rollback_score: 100.0
      })

      # Only override success_rate; others use module @weights defaults
      partial_weights = %{success_rate: 0.50}

      # Expected: 100*0.50 + 100*0.15 + 100*0.25 + 100*0.20 + 100*0.10
      #         = 50 + 15 + 25 + 20 + 10 = 120 => clamped to 100
      assert Calculator.calculate(profile, partial_weights) == 100
    end
  end

  describe "success_rate_score/2" do
    test "returns 0.0 when total is 0" do
      assert Calculator.success_rate_score(0, 0) == 0.0
    end

    test "returns 100.0 for perfect success" do
      assert Calculator.success_rate_score(100, 100) == 100.0
    end

    test "returns 85.0 for 170/200" do
      assert Calculator.success_rate_score(170, 200) == 85.0
    end

    test "returns 50.0 for half success" do
      assert Calculator.success_rate_score(50, 100) == 50.0
    end

    test "returns 0.0 for zero successes with non-zero total" do
      assert Calculator.success_rate_score(0, 100) == 0.0
    end

    test "caps at 100.0 even if successful exceeds total (defensive)" do
      # The function uses min(100.0, rate)
      assert Calculator.success_rate_score(150, 100) == 100.0
    end

    test "rounds to 2 decimal places" do
      # 1/3 * 100 = 33.333... => 33.33
      assert Calculator.success_rate_score(1, 3) == 33.33
    end
  end

  describe "uptime_score/2" do
    test "returns 0.0 when last_activity is nil" do
      assert Calculator.uptime_score(nil, DateTime.utc_now()) == 0.0
    end

    test "returns 100.0 for same-day activity" do
      now = ~U[2024-01-15 14:00:00Z]
      last = ~U[2024-01-15 12:00:00Z]

      assert Calculator.uptime_score(last, now) == 100.0
    end

    test "decays from 100 to 70 over 7 days" do
      now = ~U[2024-01-15 12:00:00Z]
      seven_days_ago = ~U[2024-01-08 12:00:00Z]

      score = Calculator.uptime_score(seven_days_ago, now)
      assert score == 70.0
    end

    test "score at 5 days inactive is between 70 and 100" do
      now = ~U[2024-01-15 12:00:00Z]
      five_days_ago = ~U[2024-01-10 12:00:00Z]

      score = Calculator.uptime_score(five_days_ago, now)
      assert score > 70.0
      assert score < 100.0
    end

    test "decays from 70 to 30 over days 8-30" do
      now = ~U[2024-01-31 12:00:00Z]
      thirty_days_ago = ~U[2024-01-01 12:00:00Z]

      score = Calculator.uptime_score(thirty_days_ago, now)
      assert score == 30.0
    end

    test "returns 0.0 for 60+ days inactive" do
      now = ~U[2024-03-15 12:00:00Z]
      ninety_days_ago = ~U[2023-12-15 12:00:00Z]

      assert Calculator.uptime_score(ninety_days_ago, now) == 0.0
    end
  end

  describe "days_inactive_score/1" do
    test "returns 100.0 for 0 days" do
      assert Calculator.days_inactive_score(0) == 100.0
    end

    test "returns 100.0 for negative days" do
      assert Calculator.days_inactive_score(-1) == 100.0
    end

    test "returns 70.0 for exactly 7 days" do
      assert Calculator.days_inactive_score(7) == 70.0
    end

    test "returns 30.0 for exactly 30 days" do
      assert Calculator.days_inactive_score(30) == 30.0
    end

    test "returns 0.0 for exactly 60 days" do
      assert Calculator.days_inactive_score(60) == 0.0
    end

    test "returns 0.0 for more than 60 days" do
      assert Calculator.days_inactive_score(90) == 0.0
      assert Calculator.days_inactive_score(365) == 0.0
    end

    test "decays linearly between 0 and 7 days" do
      scores = Enum.map(0..7, &Calculator.days_inactive_score/1)
      # Each consecutive score should be less than or equal to the previous
      Enum.reduce(scores, fn current, previous ->
        assert current <= previous, "Expected #{current} <= #{previous}"
        current
      end)
    end

    test "decays linearly between 8 and 30 days" do
      scores = Enum.map(8..30, &Calculator.days_inactive_score/1)
      Enum.reduce(scores, fn current, previous ->
        assert current <= previous, "Expected #{current} <= #{previous}"
        current
      end)
    end

    test "decays linearly between 31 and 60 days" do
      scores = Enum.map(31..60, &Calculator.days_inactive_score/1)
      Enum.reduce(scores, fn current, previous ->
        assert current <= previous, "Expected #{current} <= #{previous}"
        current
      end)
    end
  end

  describe "security_score/1" do
    test "returns 100.0 for 0 violations" do
      assert Calculator.security_score(0) == 100.0
    end

    test "returns 80.0 for 1 violation" do
      assert Calculator.security_score(1) == 80.0
    end

    test "returns 60.0 for 2 violations" do
      assert Calculator.security_score(2) == 60.0
    end

    test "returns 40.0 for 3 violations" do
      assert Calculator.security_score(3) == 40.0
    end

    test "returns 20.0 for 4 violations" do
      assert Calculator.security_score(4) == 20.0
    end

    test "returns 0.0 for 5 violations" do
      assert Calculator.security_score(5) == 0.0
    end

    test "floors at 0.0 for more than 5 violations" do
      assert Calculator.security_score(6) == 0.0
      assert Calculator.security_score(10) == 0.0
      assert Calculator.security_score(100) == 0.0
    end
  end

  describe "test_pass_score/2" do
    test "returns 0.0 when total is 0" do
      assert Calculator.test_pass_score(0, 0) == 0.0
    end

    test "returns 100.0 for all tests passing" do
      assert Calculator.test_pass_score(20, 20) == 100.0
    end

    test "returns 90.0 for 18/20" do
      assert Calculator.test_pass_score(18, 20) == 90.0
    end

    test "returns 0.0 for zero passed with non-zero total" do
      assert Calculator.test_pass_score(0, 50) == 0.0
    end

    test "caps at 100.0" do
      assert Calculator.test_pass_score(25, 20) == 100.0
    end

    test "rounds to 2 decimal places" do
      # 1/3 * 100 = 33.333... => 33.33
      assert Calculator.test_pass_score(1, 3) == 33.33
    end
  end

  describe "rollback_score/2" do
    test "returns 100.0 when no improvements (denominator 0)" do
      assert Calculator.rollback_score(0, 0) == 100.0
      assert Calculator.rollback_score(5, 0) == 100.0
    end

    test "returns 100.0 for zero rollbacks" do
      assert Calculator.rollback_score(0, 10) == 100.0
    end

    test "returns 80.0 for 20% rollback rate" do
      assert Calculator.rollback_score(2, 10) == 80.0
    end

    test "returns 50.0 for 50% rollback rate" do
      assert Calculator.rollback_score(5, 10) == 50.0
    end

    test "returns 0.0 for 100% rollback rate" do
      assert Calculator.rollback_score(5, 5) == 0.0
    end

    test "floors at 0.0 for rollback ratio > 1" do
      assert Calculator.rollback_score(10, 5) == 0.0
    end
  end

  describe "recalculate_profile/3 with explicit weights" do
    test "recalculates all component scores from raw counters" do
      now = ~U[2024-01-15 14:00:00Z]

      profile = build_profile(%{
        total_actions: 200,
        successful_actions: 170,
        security_violations: 1,
        total_tests: 20,
        tests_passed: 18,
        rollback_count: 2,
        improvement_count: 10,
        last_activity_at: ~U[2024-01-15 12:00:00Z]
      })

      result = Calculator.recalculate_profile(profile, now, @weights)

      assert result.success_rate_score == 85.0
      assert result.uptime_score == 100.0
      assert result.security_score == 80.0
      assert result.test_pass_score == 90.0
      assert result.rollback_score == 80.0

      # Expected trust: 85*0.30 + 100*0.15 + 80*0.25 + 90*0.20 + 80*0.10
      #               = 25.5 + 15.0 + 20.0 + 18.0 + 8.0 = 86.5 => 87
      assert result.trust_score == 87
    end

    test "sets tier based on calculated score" do
      now = ~U[2024-01-15 14:00:00Z]

      profile = build_profile(%{
        total_actions: 200,
        successful_actions: 170,
        security_violations: 1,
        total_tests: 20,
        tests_passed: 18,
        rollback_count: 2,
        improvement_count: 10,
        last_activity_at: ~U[2024-01-15 12:00:00Z]
      })

      result = Calculator.recalculate_profile(profile, now, @weights)

      # Score of 87 => :veteran tier (75-89)
      assert result.tier == :veteran
    end

    test "handles brand new profile with no activity" do
      now = ~U[2024-01-15 14:00:00Z]
      profile = build_profile()

      result = Calculator.recalculate_profile(profile, now, @weights)

      # success_rate_score: 0 (0/0), uptime: 0 (nil last_activity),
      # security: 100 (0 violations), test_pass: 0 (0/0), rollback: 100 (0/0)
      assert result.success_rate_score == 0.0
      assert result.uptime_score == 0.0
      assert result.security_score == 100.0
      assert result.test_pass_score == 0.0
      assert result.rollback_score == 100.0

      # Expected: 0*0.30 + 0*0.15 + 100*0.25 + 0*0.20 + 100*0.10
      #         = 0 + 0 + 25 + 0 + 10 = 35
      assert result.trust_score == 35
      assert result.tier == :probationary
    end

    test "profile with all perfect metrics" do
      now = ~U[2024-01-15 14:00:00Z]

      profile = build_profile(%{
        total_actions: 100,
        successful_actions: 100,
        security_violations: 0,
        total_tests: 50,
        tests_passed: 50,
        rollback_count: 0,
        improvement_count: 10,
        last_activity_at: ~U[2024-01-15 12:00:00Z]
      })

      result = Calculator.recalculate_profile(profile, now, @weights)

      assert result.success_rate_score == 100.0
      assert result.uptime_score == 100.0
      assert result.security_score == 100.0
      assert result.test_pass_score == 100.0
      assert result.rollback_score == 100.0
      assert result.trust_score == 100
      assert result.tier == :autonomous
    end

    test "profile with all worst metrics" do
      now = ~U[2024-06-15 14:00:00Z]

      profile = build_profile(%{
        total_actions: 100,
        successful_actions: 0,
        security_violations: 10,
        total_tests: 50,
        tests_passed: 0,
        rollback_count: 10,
        improvement_count: 10,
        last_activity_at: ~U[2024-01-15 12:00:00Z]
      })

      result = Calculator.recalculate_profile(profile, now, @weights)

      assert result.success_rate_score == 0.0
      assert result.uptime_score == 0.0
      assert result.security_score == 0.0
      assert result.test_pass_score == 0.0
      assert result.rollback_score == 0.0
      assert result.trust_score == 0
      assert result.tier == :untrusted
    end
  end

  describe "weights/0" do
    test "returns the default weight map" do
      weights = Calculator.weights()

      assert weights.success_rate == 0.30
      assert weights.uptime == 0.15
      assert weights.security == 0.25
      assert weights.test_pass == 0.20
      assert weights.rollback == 0.10
    end

    test "weights sum to 1.0" do
      weights = Calculator.weights()
      total = weights.success_rate + weights.uptime + weights.security +
              weights.test_pass + weights.rollback

      assert_in_delta total, 1.0, 0.001
    end
  end
end
