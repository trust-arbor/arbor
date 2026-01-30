defmodule Arbor.Trust.ConfigTest do
  # async: false because these tests modify shared Application config keys
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.Config

  describe "pubsub/0" do
    test "returns default PubSub module when no app env set" do
      original = Application.get_env(:arbor_trust, :pubsub)
      Application.delete_env(:arbor_trust, :pubsub)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :pubsub, original),
          else: Application.delete_env(:arbor_trust, :pubsub)
      end)

      assert Config.pubsub() == Arbor.Core.PubSub
    end

    test "returns overridden PubSub module from app env" do
      original = Application.get_env(:arbor_trust, :pubsub)
      Application.put_env(:arbor_trust, :pubsub, MyApp.CustomPubSub)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :pubsub, original),
          else: Application.delete_env(:arbor_trust, :pubsub)
      end)

      assert Config.pubsub() == MyApp.CustomPubSub
    end
  end

  describe "tiers/0" do
    test "returns default tier list when no app env set" do
      original = Application.get_env(:arbor_trust, :tiers)
      Application.delete_env(:arbor_trust, :tiers)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tiers, original),
          else: Application.delete_env(:arbor_trust, :tiers)
      end)

      assert Config.tiers() == [:untrusted, :probationary, :trusted, :veteran, :autonomous]
    end

    test "returns overridden tier list from app env" do
      original = Application.get_env(:arbor_trust, :tiers)
      custom_tiers = [:low, :medium, :high]
      Application.put_env(:arbor_trust, :tiers, custom_tiers)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tiers, original),
          else: Application.delete_env(:arbor_trust, :tiers)
      end)

      assert Config.tiers() == custom_tiers
    end
  end

  describe "tier_thresholds/0" do
    test "returns default tier thresholds when no app env set" do
      original = Application.get_env(:arbor_trust, :tier_thresholds)
      Application.delete_env(:arbor_trust, :tier_thresholds)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_thresholds, original),
          else: Application.delete_env(:arbor_trust, :tier_thresholds)
      end)

      expected = %{
        untrusted: 0,
        probationary: 20,
        trusted: 50,
        veteran: 75,
        autonomous: 90
      }

      assert Config.tier_thresholds() == expected
    end

    test "returns overridden tier thresholds from app env" do
      original = Application.get_env(:arbor_trust, :tier_thresholds)
      custom = %{low: 0, medium: 30, high: 70}
      Application.put_env(:arbor_trust, :tier_thresholds, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_thresholds, original),
          else: Application.delete_env(:arbor_trust, :tier_thresholds)
      end)

      assert Config.tier_thresholds() == custom
    end
  end

  describe "score_weights/0" do
    test "returns default score weights when no app env set" do
      original = Application.get_env(:arbor_trust, :score_weights)
      Application.delete_env(:arbor_trust, :score_weights)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :score_weights, original),
          else: Application.delete_env(:arbor_trust, :score_weights)
      end)

      expected = %{
        success_rate: 0.30,
        uptime: 0.15,
        security: 0.25,
        test_pass: 0.20,
        rollback: 0.10
      }

      assert Config.score_weights() == expected
    end

    test "weights sum to 1.0 by default" do
      original = Application.get_env(:arbor_trust, :score_weights)
      Application.delete_env(:arbor_trust, :score_weights)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :score_weights, original),
          else: Application.delete_env(:arbor_trust, :score_weights)
      end)

      weights = Config.score_weights()
      total = weights |> Map.values() |> Enum.sum()
      assert_in_delta total, 1.0, 0.001
    end

    test "returns overridden score weights from app env" do
      original = Application.get_env(:arbor_trust, :score_weights)
      custom = %{success_rate: 0.50, security: 0.50}
      Application.put_env(:arbor_trust, :score_weights, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :score_weights, original),
          else: Application.delete_env(:arbor_trust, :score_weights)
      end)

      assert Config.score_weights() == custom
    end
  end

  describe "points_earned/0" do
    test "returns default points earned when no app env set" do
      original = Application.get_env(:arbor_trust, :points_earned)
      Application.delete_env(:arbor_trust, :points_earned)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :points_earned, original),
          else: Application.delete_env(:arbor_trust, :points_earned)
      end)

      expected = %{
        proposal_approved: 5,
        installation_successful: 10,
        high_impact_feature: 20,
        bug_fix_passed: 3,
        documentation_improvement: 1
      }

      assert Config.points_earned() == expected
    end

    test "returns overridden points earned from app env" do
      original = Application.get_env(:arbor_trust, :points_earned)
      custom = %{proposal_approved: 10, installation_successful: 25}
      Application.put_env(:arbor_trust, :points_earned, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :points_earned, original),
          else: Application.delete_env(:arbor_trust, :points_earned)
      end)

      assert Config.points_earned() == custom
    end
  end

  describe "points_lost/0" do
    test "returns default points lost when no app env set" do
      original = Application.get_env(:arbor_trust, :points_lost)
      Application.delete_env(:arbor_trust, :points_lost)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :points_lost, original),
          else: Application.delete_env(:arbor_trust, :points_lost)
      end)

      expected = %{
        implementation_failure: 5,
        installation_rolled_back: 10,
        security_violation: 20,
        circuit_breaker_triggered: 15
      }

      assert Config.points_lost() == expected
    end

    test "returns overridden points lost from app env" do
      original = Application.get_env(:arbor_trust, :points_lost)
      custom = %{security_violation: 50}
      Application.put_env(:arbor_trust, :points_lost, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :points_lost, original),
          else: Application.delete_env(:arbor_trust, :points_lost)
      end)

      assert Config.points_lost() == custom
    end
  end

  describe "points_thresholds/0" do
    test "returns default points thresholds when no app env set" do
      original = Application.get_env(:arbor_trust, :points_thresholds)
      Application.delete_env(:arbor_trust, :points_thresholds)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :points_thresholds, original),
          else: Application.delete_env(:arbor_trust, :points_thresholds)
      end)

      expected = %{
        untrusted: 0,
        probationary: 25,
        trusted: 100,
        veteran: 500,
        autonomous: 2000
      }

      assert Config.points_thresholds() == expected
    end

    test "returns overridden points thresholds from app env" do
      original = Application.get_env(:arbor_trust, :points_thresholds)
      custom = %{untrusted: 0, trusted: 50, autonomous: 1000}
      Application.put_env(:arbor_trust, :points_thresholds, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :points_thresholds, original),
          else: Application.delete_env(:arbor_trust, :points_thresholds)
      end)

      assert Config.points_thresholds() == custom
    end
  end

  describe "capability_templates/0" do
    test "returns empty map as default when no app env set" do
      original = Application.get_env(:arbor_trust, :capability_templates)
      Application.delete_env(:arbor_trust, :capability_templates)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :capability_templates, original),
          else: Application.delete_env(:arbor_trust, :capability_templates)
      end)

      assert Config.capability_templates() == %{}
    end

    test "returns overridden capability templates from app env" do
      original = Application.get_env(:arbor_trust, :capability_templates)
      custom = %{trusted: [:read, :write], autonomous: [:read, :write, :admin]}
      Application.put_env(:arbor_trust, :capability_templates, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :capability_templates, original),
          else: Application.delete_env(:arbor_trust, :capability_templates)
      end)

      assert Config.capability_templates() == custom
    end
  end

  describe "decay_config/0" do
    test "returns default decay config when no app env set" do
      original = Application.get_env(:arbor_trust, :decay)
      Application.delete_env(:arbor_trust, :decay)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :decay, original),
          else: Application.delete_env(:arbor_trust, :decay)
      end)

      expected = %{
        grace_period_days: 7,
        decay_rate: 1,
        floor_score: 10,
        run_time: ~T[03:00:00]
      }

      assert Config.decay_config() == expected
    end

    test "returns overridden decay config from app env" do
      original = Application.get_env(:arbor_trust, :decay)
      custom = %{grace_period_days: 14, decay_rate: 2, floor_score: 5, run_time: ~T[04:00:00]}
      Application.put_env(:arbor_trust, :decay, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :decay, original),
          else: Application.delete_env(:arbor_trust, :decay)
      end)

      assert Config.decay_config() == custom
    end
  end

  describe "circuit_breaker_config/0" do
    test "returns default circuit breaker config when no app env set" do
      original = Application.get_env(:arbor_trust, :circuit_breaker)
      Application.delete_env(:arbor_trust, :circuit_breaker)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :circuit_breaker, original),
          else: Application.delete_env(:arbor_trust, :circuit_breaker)
      end)

      expected = %{
        rapid_failure_threshold: 5,
        rapid_failure_window_seconds: 60,
        security_violation_threshold: 3,
        security_violation_window_seconds: 3600,
        rollback_threshold: 3,
        rollback_window_seconds: 3600,
        test_failure_threshold: 5,
        test_failure_window_seconds: 300,
        freeze_duration_seconds: 86_400,
        half_open_duration_seconds: 3600
      }

      assert Config.circuit_breaker_config() == expected
    end

    test "returns overridden circuit breaker config from app env" do
      original = Application.get_env(:arbor_trust, :circuit_breaker)

      custom = %{
        rapid_failure_threshold: 10,
        rapid_failure_window_seconds: 120,
        security_violation_threshold: 5,
        security_violation_window_seconds: 7200,
        rollback_threshold: 5,
        rollback_window_seconds: 7200,
        test_failure_threshold: 10,
        test_failure_window_seconds: 600,
        freeze_duration_seconds: 172_800,
        half_open_duration_seconds: 7200
      }

      Application.put_env(:arbor_trust, :circuit_breaker, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :circuit_breaker, original),
          else: Application.delete_env(:arbor_trust, :circuit_breaker)
      end)

      assert Config.circuit_breaker_config() == custom
    end
  end
end
