defmodule Arbor.Trust.Config do
  @moduledoc """
  Central configuration reader for the trust system.

  All trust modules call this instead of using hardcoded module attributes.
  Configuration is read from application env with sensible defaults.

  ## Configuration

      # config/config.exs
      config :arbor_trust,
        pubsub: Arbor.Core.PubSub,
        tiers: [:untrusted, :probationary, :trusted, :veteran, :autonomous],
        tier_thresholds: %{
          untrusted: 0,
          probationary: 20,
          trusted: 50,
          veteran: 75,
          autonomous: 90
        },
        score_weights: %{
          success_rate: 0.30,
          uptime: 0.15,
          security: 0.25,
          test_pass: 0.20,
          rollback: 0.10
        },
        points_earned: %{
          proposal_approved: 5,
          installation_successful: 10,
          high_impact_feature: 20,
          bug_fix_passed: 3,
          documentation_improvement: 1
        },
        points_lost: %{
          implementation_failure: 5,
          installation_rolled_back: 10,
          security_violation: 20,
          circuit_breaker_triggered: 15
        },
        points_thresholds: %{
          untrusted: 0,
          probationary: 25,
          trusted: 100,
          veteran: 500,
          autonomous: 2000
        },
        decay: %{
          grace_period_days: 7,
          decay_rate: 1,
          floor_score: 10,
          run_time: ~T[03:00:00]
        },
        circuit_breaker: %{
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
  """

  # Default values
  @default_tiers [:untrusted, :probationary, :trusted, :veteran, :autonomous]

  @default_tier_thresholds %{
    untrusted: 0,
    probationary: 20,
    trusted: 50,
    veteran: 75,
    autonomous: 90
  }

  @default_score_weights %{
    success_rate: 0.30,
    uptime: 0.15,
    security: 0.25,
    test_pass: 0.20,
    rollback: 0.10
  }

  @default_points_earned %{
    proposal_approved: 5,
    installation_successful: 10,
    high_impact_feature: 20,
    bug_fix_passed: 3,
    documentation_improvement: 1
  }

  @default_points_lost %{
    implementation_failure: 5,
    installation_rolled_back: 10,
    security_violation: 20,
    circuit_breaker_triggered: 15
  }

  @default_points_thresholds %{
    untrusted: 0,
    probationary: 25,
    trusted: 100,
    veteran: 500,
    autonomous: 2000
  }

  @default_capability_templates %{}

  @default_decay %{
    grace_period_days: 7,
    decay_rate: 1,
    floor_score: 10,
    run_time: ~T[03:00:00]
  }

  @default_circuit_breaker %{
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

  @doc "Get the PubSub module to use."
  @spec pubsub() :: module()
  def pubsub, do: get(:pubsub, Arbor.Core.PubSub)

  @doc "Get the ordered list of trust tiers."
  @spec tiers() :: [atom()]
  def tiers, do: get(:tiers, @default_tiers)

  @doc "Get the score-based tier thresholds."
  @spec tier_thresholds() :: map()
  def tier_thresholds, do: get(:tier_thresholds, @default_tier_thresholds)

  @doc "Get the score component weights."
  @spec score_weights() :: map()
  def score_weights, do: get(:score_weights, @default_score_weights)

  @doc "Get points earned per event type."
  @spec points_earned() :: map()
  def points_earned, do: get(:points_earned, @default_points_earned)

  @doc "Get points lost per event type."
  @spec points_lost() :: map()
  def points_lost, do: get(:points_lost, @default_points_lost)

  @doc "Get points-based tier thresholds."
  @spec points_thresholds() :: map()
  def points_thresholds, do: get(:points_thresholds, @default_points_thresholds)

  @doc "Get capability templates per tier."
  @spec capability_templates() :: map()
  def capability_templates, do: get(:capability_templates, @default_capability_templates)

  @doc "Get decay configuration."
  @spec decay_config() :: map()
  def decay_config, do: get(:decay, @default_decay)

  @doc "Get circuit breaker configuration."
  @spec circuit_breaker_config() :: map()
  def circuit_breaker_config, do: get(:circuit_breaker, @default_circuit_breaker)

  defp get(key, default), do: Application.get_env(:arbor_trust, key, default)
end
