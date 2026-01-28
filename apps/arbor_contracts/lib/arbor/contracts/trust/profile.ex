defmodule Arbor.Contracts.Trust.Profile do
  @moduledoc """
  Trust profile data structure for self-improving agents.

  A trust profile tracks all metrics that contribute to an agent's
  trust score, which determines what self-modification capabilities
  the agent has earned.

  ## Component Scores

  Each component score ranges from 0.0 to 100.0:

  - `success_rate_score` - Based on successful/total actions (30% weight)
  - `uptime_score` - Based on activity recency (15% weight)
  - `security_score` - Based on security compliance (25% weight)
  - `test_pass_score` - Based on tests passed/run (20% weight)
  - `rollback_score` - Based on rollback frequency (10% weight)

  ## Trust Tiers

  | Tier | Score Range | Capabilities |
  |------|-------------|--------------|
  | :untrusted | 0-19 | Read own code |
  | :probationary | 20-49 | Sandbox modifications |
  | :trusted | 50-74 | Self-modify with approval |
  | :veteran | 75-89 | Self-modify auto-approved |
  | :autonomous | 90-100 | Modify own capabilities |

  ## Frozen State

  When `frozen` is true, the agent cannot earn additional trust.
  This is used by circuit breakers when anomalous behavior is detected.

  ## Example

      profile = %Profile{
        agent_id: "agent_123",
        trust_score: 67,
        tier: :trusted,
        success_rate_score: 85.0,
        security_score: 100.0,
        total_actions: 200,
        successful_actions: 170,
        ...
      }

  @version "1.0.0"
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "Trust profile for a self-improving agent"

    # Identity
    field(:agent_id, String.t())

    # Computed trust values
    field(:trust_score, non_neg_integer(), default: 0)
    field(:tier, atom(), default: :untrusted)

    # Frozen state (circuit breaker)
    field(:frozen, boolean(), default: false)
    field(:frozen_reason, atom(), enforce: false)
    field(:frozen_at, DateTime.t(), enforce: false)

    # Component scores (0.0 to 100.0 each)
    field(:success_rate_score, float(), default: 0.0)
    field(:uptime_score, float(), default: 0.0)
    field(:security_score, float(), default: 100.0)
    field(:test_pass_score, float(), default: 0.0)
    field(:rollback_score, float(), default: 100.0)

    # Raw counters for success rate
    field(:total_actions, non_neg_integer(), default: 0)
    field(:successful_actions, non_neg_integer(), default: 0)

    # Security counters
    field(:security_violations, non_neg_integer(), default: 0)

    # Test counters
    field(:total_tests, non_neg_integer(), default: 0)
    field(:tests_passed, non_neg_integer(), default: 0)

    # Rollback/improvement counters
    field(:rollback_count, non_neg_integer(), default: 0)
    field(:improvement_count, non_neg_integer(), default: 0)

    # Trust points (council-based earning system)
    # Points earned from council-approved proposals and successful installations
    field(:trust_points, non_neg_integer(), default: 0)
    field(:proposals_submitted, non_neg_integer(), default: 0)
    field(:proposals_approved, non_neg_integer(), default: 0)
    field(:installations_successful, non_neg_integer(), default: 0)
    field(:installations_rolled_back, non_neg_integer(), default: 0)

    # Timestamps
    field(:created_at, DateTime.t())
    field(:updated_at, DateTime.t())
    field(:last_activity_at, DateTime.t(), enforce: false)
  end

  @doc """
  Create a new trust profile for an agent.

  Initializes with zero trust score and default component scores.
  Security and rollback scores start at 100.0 (no violations/rollbacks).

  ## Example

      {:ok, profile} = Profile.new("agent_123")
      profile.tier
      #=> :untrusted
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(agent_id) when is_binary(agent_id) and byte_size(agent_id) > 0 do
    now = DateTime.utc_now()

    profile = %__MODULE__{
      agent_id: agent_id,
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

    {:ok, profile}
  end

  def new(_), do: {:error, :invalid_agent_id}

  @doc """
  Update the trust score and tier based on current component scores.

  Uses default weights for calculation. For custom weights, use `recalculate/2`.

  ## Example

      profile = %Profile{...}
      updated = Profile.recalculate(profile)
      updated.trust_score
      #=> 67
  """
  @spec recalculate(t()) :: t()
  def recalculate(%__MODULE__{} = profile) do
    score = calculate_score(profile)
    tier = score_to_tier(score)

    %{profile | trust_score: score, tier: tier, updated_at: DateTime.utc_now()}
  end

  @doc """
  Update the trust score and tier with custom weights.

  The weights map should have keys: `:success_rate`, `:uptime`, `:security`,
  `:test_pass`, `:rollback` with float values summing to 1.0.

  ## Example

      weights = %{success_rate: 0.30, uptime: 0.15, security: 0.25, test_pass: 0.20, rollback: 0.10}
      updated = Profile.recalculate(profile, weights)
  """
  @spec recalculate(t(), map()) :: t()
  def recalculate(%__MODULE__{} = profile, weights) when is_map(weights) do
    score = calculate_score(profile, weights)
    tier = score_to_tier(score)

    %{profile | trust_score: score, tier: tier, updated_at: DateTime.utc_now()}
  end

  @doc """
  Record a successful action and update component scores.
  """
  @spec record_action_success(t()) :: t()
  def record_action_success(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:total_actions, &(&1 + 1))
    |> Map.update!(:successful_actions, &(&1 + 1))
    |> update_success_rate_score()
    |> touch_activity()
  end

  @doc """
  Record a failed action and update component scores.
  """
  @spec record_action_failure(t()) :: t()
  def record_action_failure(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:total_actions, &(&1 + 1))
    |> update_success_rate_score()
    |> touch_activity()
  end

  @doc """
  Record a security violation.

  Each violation reduces security_score by 20 points (floor 0).
  """
  @spec record_security_violation(t()) :: t()
  def record_security_violation(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:security_violations, &(&1 + 1))
    |> update_security_score()
    |> touch_activity()
  end

  @doc """
  Record a test result.
  """
  @spec record_test_result(t(), :passed | :failed) :: t()
  def record_test_result(%__MODULE__{} = profile, :passed) do
    profile
    |> Map.update!(:total_tests, &(&1 + 1))
    |> Map.update!(:tests_passed, &(&1 + 1))
    |> update_test_pass_score()
    |> touch_activity()
  end

  def record_test_result(%__MODULE__{} = profile, :failed) do
    profile
    |> Map.update!(:total_tests, &(&1 + 1))
    |> update_test_pass_score()
    |> touch_activity()
  end

  @doc """
  Record a rollback event.

  Rollbacks negatively impact the rollback stability score.
  """
  @spec record_rollback(t()) :: t()
  def record_rollback(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:rollback_count, &(&1 + 1))
    |> update_rollback_score()
    |> touch_activity()
  end

  @doc """
  Record an improvement being applied.
  """
  @spec record_improvement(t()) :: t()
  def record_improvement(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:improvement_count, &(&1 + 1))
    |> touch_activity()
  end

  # Trust Points Functions (Council-based earning system)

  @doc """
  Record a proposal submission.
  """
  @spec record_proposal_submitted(t()) :: t()
  def record_proposal_submitted(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:proposals_submitted, &(&1 + 1))
    |> touch_activity()
  end

  @doc """
  Record a proposal being approved by council and award points.

  Points awarded based on proposal impact:
  - :low - 3 points (bug fix, documentation)
  - :medium - 5 points (standard feature)
  - :high - 10 points (significant feature)
  - :critical - 20 points (high-impact contribution)
  """
  @spec record_proposal_approved(t(), atom()) :: t()
  def record_proposal_approved(%__MODULE__{} = profile, impact \\ :medium) do
    points = points_for_impact(impact)

    profile
    |> Map.update!(:proposals_approved, &(&1 + 1))
    |> Map.update!(:trust_points, &(&1 + points))
    |> touch_activity()
  end

  @doc """
  Record a successful installation and award bonus points.
  """
  @spec record_installation_success(t(), atom()) :: t()
  def record_installation_success(%__MODULE__{} = profile, impact \\ :medium) do
    # Installation success awards additional points (proves value)
    points = div(points_for_impact(impact), 2)

    profile
    |> Map.update!(:installations_successful, &(&1 + 1))
    |> Map.update!(:trust_points, &(&1 + points))
    |> touch_activity()
  end

  @doc """
  Record an installation rollback and deduct points.
  """
  @spec record_installation_rollback(t()) :: t()
  def record_installation_rollback(%__MODULE__{} = profile) do
    # Rollbacks deduct points
    new_points = max(0, profile.trust_points - 10)

    profile
    |> Map.update!(:installations_rolled_back, &(&1 + 1))
    |> Map.put(:trust_points, new_points)
    |> touch_activity()
  end

  @doc """
  Deduct trust points for abuse or policy violations.
  """
  @spec deduct_trust_points(t(), non_neg_integer(), atom()) :: t()
  def deduct_trust_points(%__MODULE__{} = profile, points, _reason) do
    new_points = max(0, profile.trust_points - points)

    profile
    |> Map.put(:trust_points, new_points)
    |> touch_activity()
  end

  @doc """
  Get the trust tier based on trust points, using default thresholds.

  | Tier | Points Required |
  |------|-----------------|
  | :untrusted | 0 |
  | :probationary | 25 |
  | :trusted | 100 |
  | :veteran | 500 |
  | :autonomous | 2000 |
  """
  @spec points_to_tier(non_neg_integer()) :: atom()
  def points_to_tier(points) when points < 25, do: :untrusted
  def points_to_tier(points) when points < 100, do: :probationary
  def points_to_tier(points) when points < 500, do: :trusted
  def points_to_tier(points) when points < 2000, do: :veteran
  def points_to_tier(_points), do: :autonomous

  @doc """
  Get the trust tier based on trust points with custom thresholds.

  The thresholds map should have tier keys with minimum point values.
  """
  @spec points_to_tier(non_neg_integer(), map()) :: atom()
  def points_to_tier(points, thresholds) when is_map(thresholds) do
    # Sort tiers by threshold descending and find the first one the points qualify for
    thresholds
    |> Enum.sort_by(fn {_tier, threshold} -> threshold end, :desc)
    |> Enum.find(fn {_tier, threshold} -> points >= threshold end)
    |> case do
      {tier, _} -> tier
      nil -> :untrusted
    end
  end

  defp points_for_impact(:low), do: 3
  defp points_for_impact(:medium), do: 5
  defp points_for_impact(:high), do: 10
  defp points_for_impact(:critical), do: 20
  defp points_for_impact(_), do: 5

  @doc """
  Freeze the trust profile.
  """
  @spec freeze(t(), atom()) :: t()
  def freeze(%__MODULE__{} = profile, reason) do
    %{profile | frozen: true, frozen_reason: reason, frozen_at: DateTime.utc_now()}
  end

  @doc """
  Unfreeze the trust profile.
  """
  @spec unfreeze(t()) :: t()
  def unfreeze(%__MODULE__{} = profile) do
    %{profile | frozen: false, frozen_reason: nil, frozen_at: nil}
  end

  @doc """
  Apply trust decay (called daily for inactive agents).

  Decays 1 point per day after 7-day grace period, with floor of 10.
  """
  @spec apply_decay(t(), days_inactive :: non_neg_integer()) :: t()
  def apply_decay(%__MODULE__{} = profile, days_inactive) when days_inactive > 7 do
    decay_days = days_inactive - 7
    new_score = max(10, profile.trust_score - decay_days)

    %{profile | trust_score: new_score, tier: score_to_tier(new_score)}
  end

  def apply_decay(%__MODULE__{} = profile, _), do: profile

  @doc """
  Convert profile to a map suitable for persistence.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    Map.from_struct(profile)
  end

  # Private functions

  defp calculate_score(%__MODULE__{} = profile) do
    weights = %{
      success_rate: 0.30,
      uptime: 0.15,
      security: 0.25,
      test_pass: 0.20,
      rollback: 0.10
    }

    calculate_score(profile, weights)
  end

  defp calculate_score(%__MODULE__{} = profile, weights) do
    score =
      profile.success_rate_score * Map.get(weights, :success_rate, 0.30) +
        profile.uptime_score * Map.get(weights, :uptime, 0.15) +
        profile.security_score * Map.get(weights, :security, 0.25) +
        profile.test_pass_score * Map.get(weights, :test_pass, 0.20) +
        profile.rollback_score * Map.get(weights, :rollback, 0.10)

    round(score)
  end

  defp score_to_tier(score) when score < 20, do: :untrusted
  defp score_to_tier(score) when score < 50, do: :probationary
  defp score_to_tier(score) when score < 75, do: :trusted
  defp score_to_tier(score) when score < 90, do: :veteran
  defp score_to_tier(_score), do: :autonomous

  defp update_success_rate_score(%__MODULE__{total_actions: 0} = profile) do
    %{profile | success_rate_score: 0.0}
  end

  defp update_success_rate_score(%__MODULE__{} = profile) do
    rate = profile.successful_actions / profile.total_actions * 100.0
    %{profile | success_rate_score: Float.round(rate, 2)}
  end

  defp update_security_score(%__MODULE__{} = profile) do
    # Each violation costs 20 points, floor at 0
    score = max(0.0, 100.0 - profile.security_violations * 20.0)
    %{profile | security_score: score}
  end

  defp update_test_pass_score(%__MODULE__{total_tests: 0} = profile) do
    %{profile | test_pass_score: 0.0}
  end

  defp update_test_pass_score(%__MODULE__{} = profile) do
    rate = profile.tests_passed / profile.total_tests * 100.0
    %{profile | test_pass_score: Float.round(rate, 2)}
  end

  defp update_rollback_score(%__MODULE__{improvement_count: 0} = profile) do
    # No improvements yet, so rollback ratio undefined, keep at 100
    %{profile | rollback_score: 100.0}
  end

  defp update_rollback_score(%__MODULE__{} = profile) do
    # Score decreases based on ratio of rollbacks to improvements
    rollback_ratio = profile.rollback_count / profile.improvement_count
    score = max(0.0, 100.0 - rollback_ratio * 100.0)
    %{profile | rollback_score: Float.round(score, 2)}
  end

  defp touch_activity(%__MODULE__{} = profile) do
    %{profile | last_activity_at: DateTime.utc_now()}
  end
end
