defmodule Arbor.Trust.Calculator do
  @moduledoc """
  Pure functions for calculating trust scores.

  This module implements the weighted trust score calculation algorithm.
  All functions are pure and side-effect free, making them easy to test.

  ## Algorithm

  The trust score is a weighted average of component scores:

      trust_score = (success_rate * 0.30) +
                    (uptime * 0.15) +
                    (security * 0.25) +
                    (test_pass * 0.20) +
                    (rollback * 0.10)

  Weights are configurable via `Arbor.Trust.Config.score_weights/0`.

  ## Component Score Calculation

  - **Success Rate**: `successful_actions / total_actions * 100`
  - **Uptime**: Based on days since last activity (see `uptime_score/1`)
  - **Security**: `100 - (violations * 20)`, floor 0
  - **Test Pass**: `tests_passed / total_tests * 100`
  - **Rollback**: `100 - (rollback_ratio * 100)`

  ## Example

      profile = %Profile{
        success_rate_score: 85.0,
        uptime_score: 100.0,
        security_score: 80.0,
        test_pass_score: 90.0,
        rollback_score: 95.0
      }

      Calculator.calculate(profile)
      #=> 88 (rounded)
  """

  alias Arbor.Contracts.Trust.Profile

  @weights %{
    success_rate: 0.30,
    uptime: 0.15,
    security: 0.25,
    test_pass: 0.20,
    rollback: 0.10
  }

  @doc """
  Calculate the trust score from a profile's component scores.

  Uses weights from `Arbor.Trust.Config.score_weights/0`.
  Returns an integer from 0 to 100.

  ## Example

      profile = %Profile{...}
      Calculator.calculate(profile)
      #=> 67
  """
  @spec calculate(Profile.t()) :: 0..100
  def calculate(%Profile{} = profile) do
    calculate(profile, Arbor.Trust.Config.score_weights())
  end

  @doc """
  Calculate the trust score from a profile's component scores with custom weights.

  Returns an integer from 0 to 100.

  ## Example

      weights = %{success_rate: 0.30, uptime: 0.15, security: 0.25, test_pass: 0.20, rollback: 0.10}
      Calculator.calculate(profile, weights)
      #=> 67
  """
  @spec calculate(Profile.t(), map()) :: 0..100
  def calculate(%Profile{} = profile, weights) when is_map(weights) do
    score =
      profile.success_rate_score * Map.get(weights, :success_rate, @weights.success_rate) +
        profile.uptime_score * Map.get(weights, :uptime, @weights.uptime) +
        profile.security_score * Map.get(weights, :security, @weights.security) +
        profile.test_pass_score * Map.get(weights, :test_pass, @weights.test_pass) +
        profile.rollback_score * Map.get(weights, :rollback, @weights.rollback)

    # Clamp to 0-100 range
    score
    |> round()
    |> max(0)
    |> min(100)
  end

  @doc """
  Calculate success rate score from action counts.

  Returns 0.0 if no actions have been recorded.

  ## Example

      Calculator.success_rate_score(170, 200)
      #=> 85.0
  """
  @spec success_rate_score(non_neg_integer(), non_neg_integer()) :: float()
  def success_rate_score(_successful, 0), do: 0.0

  def success_rate_score(successful, total) when successful >= 0 and total > 0 do
    rate = successful / total * 100.0
    Float.round(min(100.0, rate), 2)
  end

  @doc """
  Calculate uptime score based on days since last activity.

  The uptime score encourages regular activity:
  - 0 days: 100.0
  - 1-7 days: Linear decay from 100 to 70
  - 8-30 days: Linear decay from 70 to 30
  - >30 days: Linear decay from 30 to 0

  ## Example

      Calculator.uptime_score(~U[2024-01-15 12:00:00Z], ~U[2024-01-15 14:00:00Z])
      #=> 100.0  # Same day

      Calculator.uptime_score(~U[2024-01-10 12:00:00Z], ~U[2024-01-15 12:00:00Z])
      #=> ~78.57  # 5 days ago
  """
  @spec uptime_score(DateTime.t() | nil, DateTime.t()) :: float()
  def uptime_score(nil, _now), do: 0.0

  def uptime_score(%DateTime{} = last_activity, %DateTime{} = now) do
    days_inactive = DateTime.diff(now, last_activity, :day)
    days_inactive_score(days_inactive)
  end

  @doc """
  Calculate uptime score from days inactive count.

  ## Example

      Calculator.days_inactive_score(0)
      #=> 100.0

      Calculator.days_inactive_score(14)
      #=> ~52.17
  """
  @spec days_inactive_score(non_neg_integer()) :: float()
  def days_inactive_score(days) when days <= 0, do: 100.0

  def days_inactive_score(days) when days <= 7 do
    # 100 -> 70 over 7 days
    100.0 - days / 7 * 30.0
  end

  def days_inactive_score(days) when days <= 30 do
    # 70 -> 30 over days 8-30
    70.0 - (days - 7) / 23 * 40.0
  end

  def days_inactive_score(days) when days <= 60 do
    # 30 -> 0 over days 31-60
    30.0 - (days - 30) / 30 * 30.0
  end

  def days_inactive_score(_), do: 0.0

  @doc """
  Calculate security score from violation count.

  Each violation costs 20 points, floor at 0.

  ## Example

      Calculator.security_score(0)
      #=> 100.0

      Calculator.security_score(3)
      #=> 40.0

      Calculator.security_score(5)
      #=> 0.0
  """
  @spec security_score(non_neg_integer()) :: float()
  def security_score(violations) when violations >= 0 do
    max(0.0, 100.0 - violations * 20.0)
  end

  @doc """
  Calculate test pass score from test counts.

  Returns 0.0 if no tests have been run.

  ## Example

      Calculator.test_pass_score(18, 20)
      #=> 90.0
  """
  @spec test_pass_score(non_neg_integer(), non_neg_integer()) :: float()
  def test_pass_score(_passed, 0), do: 0.0

  def test_pass_score(passed, total) when passed >= 0 and total > 0 do
    rate = passed / total * 100.0
    Float.round(min(100.0, rate), 2)
  end

  @doc """
  Calculate rollback score from rollback and improvement counts.

  Returns 100.0 if no improvements have been made (no rollback ratio).
  Score decreases based on rollback_count / improvement_count ratio.

  ## Example

      Calculator.rollback_score(0, 10)
      #=> 100.0  # No rollbacks

      Calculator.rollback_score(2, 10)
      #=> 80.0  # 20% rollback rate

      Calculator.rollback_score(5, 5)
      #=> 0.0  # 100% rollback rate
  """
  @spec rollback_score(non_neg_integer(), non_neg_integer()) :: float()
  def rollback_score(_rollbacks, 0), do: 100.0

  def rollback_score(rollbacks, improvements) when rollbacks >= 0 and improvements > 0 do
    ratio = rollbacks / improvements
    score = 100.0 - ratio * 100.0
    Float.round(max(0.0, score), 2)
  end

  @doc """
  Recalculate all component scores for a profile.

  Updates all component scores based on current counters and
  recalculates the overall trust score using weights from
  `Arbor.Trust.Config.score_weights/0`.

  ## Example

      profile = %Profile{
        total_actions: 200,
        successful_actions: 170,
        security_violations: 1,
        total_tests: 20,
        tests_passed: 18,
        rollback_count: 2,
        improvement_count: 10,
        last_activity_at: ~U[2024-01-15 12:00:00Z]
      }

      Calculator.recalculate_profile(profile, ~U[2024-01-15 14:00:00Z])
      #=> %Profile{trust_score: 73, tier: :trusted, ...}
  """
  @spec recalculate_profile(Profile.t(), DateTime.t()) :: Profile.t()
  def recalculate_profile(%Profile{} = profile, %DateTime{} = now) do
    recalculate_profile(profile, now, Arbor.Trust.Config.score_weights())
  end

  @doc """
  Recalculate all component scores for a profile with custom weights.

  ## Example

      weights = %{success_rate: 0.40, uptime: 0.10, security: 0.20, test_pass: 0.20, rollback: 0.10}
      Calculator.recalculate_profile(profile, now, weights)
  """
  @spec recalculate_profile(Profile.t(), DateTime.t(), map()) :: Profile.t()
  def recalculate_profile(%Profile{} = profile, %DateTime{} = now, weights) when is_map(weights) do
    profile
    |> update_component_scores(now)
    |> update_trust_score(weights)
    |> update_tier()
  end

  @doc """
  Get the default weights used in score calculation.
  """
  @spec weights() :: %{
          success_rate: float(),
          uptime: float(),
          security: float(),
          test_pass: float(),
          rollback: float()
        }
  def weights, do: @weights

  # Private functions

  defp update_component_scores(%Profile{} = profile, now) do
    %{
      profile
      | success_rate_score: success_rate_score(profile.successful_actions, profile.total_actions),
        uptime_score: uptime_score(profile.last_activity_at, now),
        security_score: security_score(profile.security_violations),
        test_pass_score: test_pass_score(profile.tests_passed, profile.total_tests),
        rollback_score: rollback_score(profile.rollback_count, profile.improvement_count)
    }
  end

  defp update_trust_score(%Profile{} = profile, weights) do
    %{profile | trust_score: calculate(profile, weights)}
  end

  defp update_tier(%Profile{trust_score: score} = profile) do
    %{profile | tier: Arbor.Trust.TierResolver.resolve(score)}
  end
end
