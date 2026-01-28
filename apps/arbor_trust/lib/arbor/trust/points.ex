defmodule Arbor.Trust.Points do
  @moduledoc """
  Trust points calculation and management.

  This module implements the council-based trust earning system where agents
  earn discrete points for specific actions like having proposals approved
  and implementations installed.

  ## Earning Trust Points

  | Event                              | Points | Notes                       |
  |------------------------------------|--------|-----------------------------|
  | Idea approved by Council           | +5     | Base points for accepted idea |
  | Implementation installed           | +10    | Proven value                |
  | High-impact feature (council rated)| +20    | Bonus for significant work  |
  | Bug fix that passes tests          | +3     | Lower risk, lower reward    |
  | Documentation improvement          | +1     | Low risk, low reward        |

  ## Losing Trust Points

  | Event                        | Points | Notes                     |
  |------------------------------|--------|---------------------------|
  | Implementation causes failures| -5     | Quality issue             |
  | Implementation rolled back   | -10    | Significant quality issue |
  | Security violation detected  | -20    | Serious concern           |
  | Rapid failures (circuit break)| -15   | Pattern of problems       |

  ## Trust Tier Thresholds (Points-Based)

  | Tier         | Points Required | Capabilities                   |
  |--------------|-----------------|--------------------------------|
  | :untrusted   | 0               | Read roadmap, propose ideas    |
  | :probationary| 25              | + Work on roadmap items        |
  | :trusted     | 100             | + Propose code changes         |
  | :veteran     | 500             | + Auto-approve low-risk changes|
  | :autonomous  | 2000            | + Self-modify capabilities     |

  ## Usage

      # Award points for an approved proposal
      {:ok, profile} = Points.award(profile, :proposal_approved)

      # Deduct points for a rollback
      {:ok, profile} = Points.deduct(profile, :installation_rolled_back)

      # Get tier from points
      tier = Points.tier_for_points(150)
      #=> :trusted
  """

  alias Arbor.Contracts.Trust.Profile

  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous
  @type award_event ::
          :proposal_approved
          | :installation_successful
          | :high_impact_feature
          | :bug_fix_passed
          | :documentation_improvement
  @type deduction_event ::
          :implementation_failure
          | :installation_rolled_back
          | :security_violation
          | :circuit_breaker_triggered

  @doc """
  Award trust points for a positive event.

  ## Example

      {:ok, profile} = Points.award(profile, :proposal_approved)
      profile.trust_points
      #=> 5
  """
  @spec award(Profile.t(), award_event(), map()) :: {:ok, Profile.t()}
  def award(%Profile{} = profile, event, metadata \\ %{}) do
    points = Map.get(Arbor.Trust.Config.points_earned(), event, 0)
    new_points = profile.trust_points + points

    updated_profile =
      profile
      |> Map.put(:trust_points, new_points)
      |> update_event_counters(event, metadata)
      |> Map.put(:updated_at, DateTime.utc_now())
      |> Map.put(:last_activity_at, DateTime.utc_now())

    {:ok, updated_profile}
  end

  @doc """
  Deduct trust points for a negative event.

  Points cannot go below 0.

  ## Example

      {:ok, profile} = Points.deduct(profile, :installation_rolled_back)
  """
  @spec deduct(Profile.t(), deduction_event(), map()) :: {:ok, Profile.t()}
  def deduct(%Profile{} = profile, event, metadata \\ %{}) do
    points = Map.get(Arbor.Trust.Config.points_lost(), event, 0)
    new_points = max(0, profile.trust_points - points)

    updated_profile =
      profile
      |> Map.put(:trust_points, new_points)
      |> update_event_counters(event, metadata)
      |> Map.put(:updated_at, DateTime.utc_now())
      |> Map.put(:last_activity_at, DateTime.utc_now())

    {:ok, updated_profile}
  end

  @doc """
  Get the trust tier for a given number of points.

  Uses configurable thresholds from `Arbor.Trust.Config.points_thresholds/0`.

  ## Examples

      Points.tier_for_points(0)
      #=> :untrusted

      Points.tier_for_points(50)
      #=> :probationary

      Points.tier_for_points(150)
      #=> :trusted

      Points.tier_for_points(2500)
      #=> :autonomous
  """
  @spec tier_for_points(non_neg_integer()) :: trust_tier()
  def tier_for_points(points) do
    thresholds = Arbor.Trust.Config.points_thresholds()

    cond do
      points >= Map.get(thresholds, :autonomous, 2000) -> :autonomous
      points >= Map.get(thresholds, :veteran, 500) -> :veteran
      points >= Map.get(thresholds, :trusted, 100) -> :trusted
      points >= Map.get(thresholds, :probationary, 25) -> :probationary
      true -> :untrusted
    end
  end

  @doc """
  Get the minimum points required for a tier.

  ## Example

      Points.min_points_for_tier(:trusted)
      #=> 100
  """
  @spec min_points_for_tier(trust_tier()) :: non_neg_integer()
  def min_points_for_tier(tier) do
    Map.fetch!(Arbor.Trust.Config.points_thresholds(), tier)
  end

  @doc """
  Get points needed to reach the next tier.

  Returns nil if already at autonomous.

  ## Example

      Points.points_to_next_tier(:probationary, 50)
      #=> 50  # Need 100 points for :trusted, have 50

      Points.points_to_next_tier(:autonomous, 2500)
      #=> nil
  """
  @spec points_to_next_tier(trust_tier(), non_neg_integer()) :: non_neg_integer() | nil
  def points_to_next_tier(:autonomous, _current_points), do: nil

  def points_to_next_tier(current_tier, current_points) do
    next_tier = next_tier(current_tier)
    required = min_points_for_tier(next_tier)
    max(0, required - current_points)
  end

  @doc """
  Get the next tier above the given tier.

  ## Example

      Points.next_tier(:trusted)
      #=> :veteran
  """
  @spec next_tier(trust_tier()) :: trust_tier() | nil
  def next_tier(:untrusted), do: :probationary
  def next_tier(:probationary), do: :trusted
  def next_tier(:trusted), do: :veteran
  def next_tier(:veteran), do: :autonomous
  def next_tier(:autonomous), do: nil

  @doc """
  Get points awarded for an event type.

  ## Example

      Points.points_for_event(:proposal_approved)
      #=> 5
  """
  @spec points_for_event(award_event() | deduction_event()) ::
          {:earn, non_neg_integer()} | {:lose, non_neg_integer()} | :unknown
  def points_for_event(event) do
    earned = Arbor.Trust.Config.points_earned()
    lost = Arbor.Trust.Config.points_lost()

    cond do
      Map.has_key?(earned, event) ->
        {:earn, Map.get(earned, event)}

      Map.has_key?(lost, event) ->
        {:lose, Map.get(lost, event)}

      true ->
        :unknown
    end
  end

  @doc """
  Check if a tier is sufficient for a required tier.

  ## Example

      Points.tier_sufficient?(:trusted, :probationary)
      #=> true
  """
  @spec tier_sufficient?(trust_tier(), trust_tier()) :: boolean()
  def tier_sufficient?(have_tier, need_tier) do
    tier_order(have_tier) >= tier_order(need_tier)
  end

  @doc """
  Get tier thresholds map.
  """
  @spec thresholds() :: %{trust_tier() => non_neg_integer()}
  def thresholds, do: Arbor.Trust.Config.points_thresholds()

  @doc """
  Get points earned configuration.
  """
  @spec points_earned_config() :: %{award_event() => non_neg_integer()}
  def points_earned_config, do: Arbor.Trust.Config.points_earned()

  @doc """
  Get points lost configuration.
  """
  @spec points_lost_config() :: %{deduction_event() => non_neg_integer()}
  def points_lost_config, do: Arbor.Trust.Config.points_lost()

  # Private functions

  defp tier_order(:untrusted), do: 0
  defp tier_order(:probationary), do: 1
  defp tier_order(:trusted), do: 2
  defp tier_order(:veteran), do: 3
  defp tier_order(:autonomous), do: 4

  defp update_event_counters(profile, :proposal_approved, _metadata) do
    Map.update!(profile, :proposals_approved, &(&1 + 1))
  end

  defp update_event_counters(profile, :installation_successful, _metadata) do
    Map.update!(profile, :installations_successful, &(&1 + 1))
  end

  defp update_event_counters(profile, :installation_rolled_back, _metadata) do
    Map.update!(profile, :installations_rolled_back, &(&1 + 1))
  end

  defp update_event_counters(profile, :security_violation, _metadata) do
    Map.update!(profile, :security_violations, &(&1 + 1))
  end

  defp update_event_counters(profile, _event, _metadata), do: profile
end
