defmodule Arbor.Trust.TierResolver do
  @moduledoc """
  Pure functions for resolving trust tiers.

  This module handles the mapping between trust scores and capability tiers,
  as well as tier comparison logic. Tier definitions and thresholds are
  driven by `Arbor.Trust.Config` for runtime configurability.

  ## Trust Tiers (Default Configuration)

  | Tier | Score Range | Self-Modification Rights |
  |------|-------------|--------------------------|
  | :untrusted | 0-19 | Read own code only |
  | :probationary | 20-49 | Sandbox modifications |
  | :trusted | 50-74 | Self-modify with approval |
  | :veteran | 75-89 | Self-modify auto-approved |
  | :autonomous | 90-100 | Can modify own capabilities |

  ## Examples

      TierResolver.resolve(67)
      #=> :trusted

      TierResolver.sufficient?(:trusted, :probationary)
      #=> true

      TierResolver.sufficient?(:probationary, :trusted)
      #=> false
  """

  @type trust_score :: 0..100
  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous

  @doc """
  Resolve a trust score to a tier.

  Uses tier thresholds from `Arbor.Trust.Config.tier_thresholds/0`.

  ## Examples

      TierResolver.resolve(0)
      #=> :untrusted

      TierResolver.resolve(25)
      #=> :probationary

      TierResolver.resolve(50)
      #=> :trusted

      TierResolver.resolve(80)
      #=> :veteran

      TierResolver.resolve(95)
      #=> :autonomous
  """
  @spec resolve(trust_score()) :: trust_tier()
  def resolve(score) when is_integer(score) do
    thresholds = Arbor.Trust.Config.tier_thresholds()
    tiers = Arbor.Trust.Config.tiers()

    # Sort tiers by threshold descending and find the first one the score qualifies for
    tiers
    |> Enum.map(fn tier -> {tier, Map.fetch!(thresholds, tier)} end)
    |> Enum.sort_by(fn {_tier, threshold} -> threshold end, :desc)
    |> Enum.find(fn {_tier, threshold} -> score >= threshold end)
    |> case do
      {tier, _} -> tier
      nil -> List.first(tiers)
    end
  end

  @doc """
  Check if a tier is sufficient for a required tier.

  Returns true if `have_tier` is at or above `need_tier`.

  ## Examples

      TierResolver.sufficient?(:trusted, :probationary)
      #=> true

      TierResolver.sufficient?(:probationary, :trusted)
      #=> false

      TierResolver.sufficient?(:veteran, :veteran)
      #=> true
  """
  @spec sufficient?(have_tier :: trust_tier(), need_tier :: trust_tier()) :: boolean()
  def sufficient?(have_tier, need_tier) do
    tier_index(have_tier) >= tier_index(need_tier)
  end

  @doc """
  Get the minimum score required for a tier.

  ## Examples

      TierResolver.min_score(:trusted)
      #=> 50

      TierResolver.min_score(:autonomous)
      #=> 90
  """
  @spec min_score(trust_tier()) :: non_neg_integer()
  def min_score(tier) do
    thresholds = Arbor.Trust.Config.tier_thresholds()
    Map.fetch!(thresholds, tier)
  end

  @doc """
  Get the maximum score for a tier (exclusive upper bound).

  ## Examples

      TierResolver.max_score(:trusted)
      #=> 74

      TierResolver.max_score(:autonomous)
      #=> 100
  """
  @spec max_score(trust_tier()) :: non_neg_integer()
  def max_score(tier) do
    tiers = Arbor.Trust.Config.tiers()
    thresholds = Arbor.Trust.Config.tier_thresholds()
    idx = Enum.find_index(tiers, &(&1 == tier))

    if idx == length(tiers) - 1 do
      # Last tier caps at 100
      100
    else
      next = Enum.at(tiers, idx + 1)
      Map.fetch!(thresholds, next) - 1
    end
  end

  @doc """
  Get all tiers in order from lowest to highest.
  """
  @spec all_tiers() :: [trust_tier()]
  def all_tiers, do: Arbor.Trust.Config.tiers()

  @doc """
  Get the next tier above the given tier.

  Returns nil for the highest tier.

  ## Examples

      TierResolver.next_tier(:trusted)
      #=> :veteran

      TierResolver.next_tier(:autonomous)
      #=> nil
  """
  @spec next_tier(trust_tier()) :: trust_tier() | nil
  def next_tier(tier) do
    tiers = Arbor.Trust.Config.tiers()
    idx = Enum.find_index(tiers, &(&1 == tier))

    if idx && idx < length(tiers) - 1 do
      Enum.at(tiers, idx + 1)
    else
      nil
    end
  end

  @doc """
  Get the previous tier below the given tier.

  Returns nil for the lowest tier.

  ## Examples

      TierResolver.previous_tier(:trusted)
      #=> :probationary

      TierResolver.previous_tier(:untrusted)
      #=> nil
  """
  @spec previous_tier(trust_tier()) :: trust_tier() | nil
  def previous_tier(tier) do
    tiers = Arbor.Trust.Config.tiers()
    idx = Enum.find_index(tiers, &(&1 == tier))

    if idx && idx > 0 do
      Enum.at(tiers, idx - 1)
    else
      nil
    end
  end

  @doc """
  Compare two tiers, returning :lt, :eq, or :gt.

  ## Examples

      TierResolver.compare(:trusted, :probationary)
      #=> :gt

      TierResolver.compare(:trusted, :trusted)
      #=> :eq

      TierResolver.compare(:trusted, :veteran)
      #=> :lt
  """
  @spec compare(trust_tier(), trust_tier()) :: :lt | :eq | :gt
  def compare(tier_a, tier_b) do
    order_a = tier_index(tier_a)
    order_b = tier_index(tier_b)

    cond do
      order_a < order_b -> :lt
      order_a > order_b -> :gt
      true -> :eq
    end
  end

  @doc """
  Get the numeric order of a tier (0 = lowest).

  ## Examples

      TierResolver.tier_index(:untrusted)
      #=> 0

      TierResolver.tier_index(:autonomous)
      #=> 4
  """
  @spec tier_index(trust_tier()) :: non_neg_integer()
  def tier_index(tier) do
    tiers = Arbor.Trust.Config.tiers()
    idx = Enum.find_index(tiers, &(&1 == tier))
    idx || raise ArgumentError, "unknown tier: #{inspect(tier)}"
  end

  @doc """
  Get the tier thresholds map.
  """
  @spec thresholds() :: map()
  def thresholds, do: Arbor.Trust.Config.tier_thresholds()

  @doc """
  Get the score needed to promote from current tier.

  Returns the minimum score for the next tier, or nil if already at max.

  ## Examples

      TierResolver.score_to_promote(:probationary)
      #=> 50

      TierResolver.score_to_promote(:autonomous)
      #=> nil
  """
  @spec score_to_promote(trust_tier()) :: non_neg_integer() | nil
  def score_to_promote(tier) do
    case next_tier(tier) do
      nil -> nil
      next -> min_score(next)
    end
  end

  @doc """
  Get the score threshold that would cause demotion.

  Returns the minimum score for the current tier (below this = demotion).

  ## Examples

      TierResolver.score_to_demote(:trusted)
      #=> 50

      TierResolver.score_to_demote(:untrusted)
      #=> 0
  """
  @spec score_to_demote(trust_tier()) :: non_neg_integer()
  def score_to_demote(tier), do: min_score(tier)

  @doc """
  Human-readable description of a tier.
  """
  @spec describe(trust_tier()) :: String.t()
  def describe(:untrusted), do: "Untrusted - Read own code only"
  def describe(:probationary), do: "Probationary - Sandbox modifications"
  def describe(:trusted), do: "Trusted - Self-modify with approval"
  def describe(:veteran), do: "Veteran - Self-modify auto-approved"
  def describe(:autonomous), do: "Autonomous - Can modify own capabilities"
end
