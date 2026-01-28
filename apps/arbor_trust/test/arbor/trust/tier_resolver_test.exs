defmodule Arbor.Trust.TierResolverTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Trust.TierResolver

  describe "resolve/1" do
    test "resolves score 0 to :untrusted" do
      assert TierResolver.resolve(0) == :untrusted
    end

    test "resolves score 19 to :untrusted" do
      assert TierResolver.resolve(19) == :untrusted
    end

    test "resolves score 20 to :probationary" do
      assert TierResolver.resolve(20) == :probationary
    end

    test "resolves score 49 to :probationary" do
      assert TierResolver.resolve(49) == :probationary
    end

    test "resolves score 50 to :trusted" do
      assert TierResolver.resolve(50) == :trusted
    end

    test "resolves score 74 to :trusted" do
      assert TierResolver.resolve(74) == :trusted
    end

    test "resolves score 75 to :veteran" do
      assert TierResolver.resolve(75) == :veteran
    end

    test "resolves score 89 to :veteran" do
      assert TierResolver.resolve(89) == :veteran
    end

    test "resolves score 90 to :autonomous" do
      assert TierResolver.resolve(90) == :autonomous
    end

    test "resolves score 100 to :autonomous" do
      assert TierResolver.resolve(100) == :autonomous
    end

    test "resolves mid-range scores correctly" do
      assert TierResolver.resolve(10) == :untrusted
      assert TierResolver.resolve(35) == :probationary
      assert TierResolver.resolve(60) == :trusted
      assert TierResolver.resolve(80) == :veteran
      assert TierResolver.resolve(95) == :autonomous
    end
  end

  describe "sufficient?/2" do
    test "same tier is sufficient" do
      assert TierResolver.sufficient?(:untrusted, :untrusted) == true
      assert TierResolver.sufficient?(:probationary, :probationary) == true
      assert TierResolver.sufficient?(:trusted, :trusted) == true
      assert TierResolver.sufficient?(:veteran, :veteran) == true
      assert TierResolver.sufficient?(:autonomous, :autonomous) == true
    end

    test "higher tier is sufficient for lower requirement" do
      assert TierResolver.sufficient?(:autonomous, :untrusted) == true
      assert TierResolver.sufficient?(:veteran, :probationary) == true
      assert TierResolver.sufficient?(:trusted, :probationary) == true
      assert TierResolver.sufficient?(:autonomous, :veteran) == true
    end

    test "lower tier is not sufficient for higher requirement" do
      assert TierResolver.sufficient?(:untrusted, :probationary) == false
      assert TierResolver.sufficient?(:probationary, :trusted) == false
      assert TierResolver.sufficient?(:trusted, :veteran) == false
      assert TierResolver.sufficient?(:veteran, :autonomous) == false
    end

    test "untrusted is not sufficient for any higher tier" do
      assert TierResolver.sufficient?(:untrusted, :probationary) == false
      assert TierResolver.sufficient?(:untrusted, :trusted) == false
      assert TierResolver.sufficient?(:untrusted, :veteran) == false
      assert TierResolver.sufficient?(:untrusted, :autonomous) == false
    end

    test "autonomous is sufficient for everything" do
      assert TierResolver.sufficient?(:autonomous, :untrusted) == true
      assert TierResolver.sufficient?(:autonomous, :probationary) == true
      assert TierResolver.sufficient?(:autonomous, :trusted) == true
      assert TierResolver.sufficient?(:autonomous, :veteran) == true
      assert TierResolver.sufficient?(:autonomous, :autonomous) == true
    end
  end

  describe "all_tiers/0" do
    test "returns ordered list of all tiers" do
      tiers = TierResolver.all_tiers()

      assert tiers == [:untrusted, :probationary, :trusted, :veteran, :autonomous]
    end

    test "returns 5 tiers" do
      assert length(TierResolver.all_tiers()) == 5
    end

    test "first tier is :untrusted" do
      assert List.first(TierResolver.all_tiers()) == :untrusted
    end

    test "last tier is :autonomous" do
      assert List.last(TierResolver.all_tiers()) == :autonomous
    end
  end

  describe "min_score/1" do
    test "returns 0 for :untrusted" do
      assert TierResolver.min_score(:untrusted) == 0
    end

    test "returns 20 for :probationary" do
      assert TierResolver.min_score(:probationary) == 20
    end

    test "returns 50 for :trusted" do
      assert TierResolver.min_score(:trusted) == 50
    end

    test "returns 75 for :veteran" do
      assert TierResolver.min_score(:veteran) == 75
    end

    test "returns 90 for :autonomous" do
      assert TierResolver.min_score(:autonomous) == 90
    end
  end

  describe "max_score/1" do
    test "returns 19 for :untrusted" do
      assert TierResolver.max_score(:untrusted) == 19
    end

    test "returns 49 for :probationary" do
      assert TierResolver.max_score(:probationary) == 49
    end

    test "returns 74 for :trusted" do
      assert TierResolver.max_score(:trusted) == 74
    end

    test "returns 89 for :veteran" do
      assert TierResolver.max_score(:veteran) == 89
    end

    test "returns 100 for :autonomous" do
      assert TierResolver.max_score(:autonomous) == 100
    end
  end

  describe "next_tier/1" do
    test "returns :probationary for :untrusted" do
      assert TierResolver.next_tier(:untrusted) == :probationary
    end

    test "returns :trusted for :probationary" do
      assert TierResolver.next_tier(:probationary) == :trusted
    end

    test "returns :veteran for :trusted" do
      assert TierResolver.next_tier(:trusted) == :veteran
    end

    test "returns :autonomous for :veteran" do
      assert TierResolver.next_tier(:veteran) == :autonomous
    end

    test "returns nil for :autonomous (highest tier)" do
      assert TierResolver.next_tier(:autonomous) == nil
    end
  end

  describe "previous_tier/1" do
    test "returns nil for :untrusted (lowest tier)" do
      assert TierResolver.previous_tier(:untrusted) == nil
    end

    test "returns :untrusted for :probationary" do
      assert TierResolver.previous_tier(:probationary) == :untrusted
    end

    test "returns :probationary for :trusted" do
      assert TierResolver.previous_tier(:trusted) == :probationary
    end

    test "returns :trusted for :veteran" do
      assert TierResolver.previous_tier(:veteran) == :trusted
    end

    test "returns :veteran for :autonomous" do
      assert TierResolver.previous_tier(:autonomous) == :veteran
    end
  end

  describe "compare/2" do
    test "returns :eq for same tiers" do
      assert TierResolver.compare(:untrusted, :untrusted) == :eq
      assert TierResolver.compare(:trusted, :trusted) == :eq
      assert TierResolver.compare(:autonomous, :autonomous) == :eq
    end

    test "returns :gt when first tier is higher" do
      assert TierResolver.compare(:trusted, :probationary) == :gt
      assert TierResolver.compare(:autonomous, :untrusted) == :gt
      assert TierResolver.compare(:veteran, :trusted) == :gt
    end

    test "returns :lt when first tier is lower" do
      assert TierResolver.compare(:probationary, :trusted) == :lt
      assert TierResolver.compare(:untrusted, :autonomous) == :lt
      assert TierResolver.compare(:trusted, :veteran) == :lt
    end

    test "comparison is consistent with tier ordering" do
      tiers = TierResolver.all_tiers()

      for {lower, i} <- Enum.with_index(tiers),
          {higher, j} <- Enum.with_index(tiers),
          i < j do
        assert TierResolver.compare(lower, higher) == :lt,
               "Expected #{lower} < #{higher}"

        assert TierResolver.compare(higher, lower) == :gt,
               "Expected #{higher} > #{lower}"
      end
    end
  end

  describe "tier_index/1" do
    test "returns 0 for :untrusted" do
      assert TierResolver.tier_index(:untrusted) == 0
    end

    test "returns 1 for :probationary" do
      assert TierResolver.tier_index(:probationary) == 1
    end

    test "returns 2 for :trusted" do
      assert TierResolver.tier_index(:trusted) == 2
    end

    test "returns 3 for :veteran" do
      assert TierResolver.tier_index(:veteran) == 3
    end

    test "returns 4 for :autonomous" do
      assert TierResolver.tier_index(:autonomous) == 4
    end

    test "raises ArgumentError for unknown tier" do
      assert_raise ArgumentError, ~r/unknown tier/, fn ->
        TierResolver.tier_index(:nonexistent)
      end
    end

    test "indices are consecutive starting from 0" do
      tiers = TierResolver.all_tiers()
      indices = Enum.map(tiers, &TierResolver.tier_index/1)

      assert indices == Enum.to_list(0..(length(tiers) - 1))
    end
  end

  describe "thresholds/0" do
    test "returns a map of tier thresholds" do
      thresholds = TierResolver.thresholds()

      assert is_map(thresholds)
      assert Map.has_key?(thresholds, :untrusted)
      assert Map.has_key?(thresholds, :probationary)
      assert Map.has_key?(thresholds, :trusted)
      assert Map.has_key?(thresholds, :veteran)
      assert Map.has_key?(thresholds, :autonomous)
    end

    test "thresholds are in ascending order" do
      thresholds = TierResolver.thresholds()
      tiers = TierResolver.all_tiers()

      scores = Enum.map(tiers, &Map.fetch!(thresholds, &1))

      Enum.reduce(scores, fn current, previous ->
        assert current > previous,
               "Expected threshold #{current} > #{previous}"
        current
      end)
    end

    test "returns default threshold values" do
      thresholds = TierResolver.thresholds()

      assert thresholds[:untrusted] == 0
      assert thresholds[:probationary] == 20
      assert thresholds[:trusted] == 50
      assert thresholds[:veteran] == 75
      assert thresholds[:autonomous] == 90
    end
  end

  describe "score_to_promote/1" do
    test "returns 20 for :untrusted" do
      assert TierResolver.score_to_promote(:untrusted) == 20
    end

    test "returns 50 for :probationary" do
      assert TierResolver.score_to_promote(:probationary) == 50
    end

    test "returns 75 for :trusted" do
      assert TierResolver.score_to_promote(:trusted) == 75
    end

    test "returns 90 for :veteran" do
      assert TierResolver.score_to_promote(:veteran) == 90
    end

    test "returns nil for :autonomous (no promotion possible)" do
      assert TierResolver.score_to_promote(:autonomous) == nil
    end
  end

  describe "score_to_demote/1" do
    test "returns 0 for :untrusted (already lowest)" do
      assert TierResolver.score_to_demote(:untrusted) == 0
    end

    test "returns 20 for :probationary" do
      assert TierResolver.score_to_demote(:probationary) == 20
    end

    test "returns 50 for :trusted" do
      assert TierResolver.score_to_demote(:trusted) == 50
    end

    test "returns 75 for :veteran" do
      assert TierResolver.score_to_demote(:veteran) == 75
    end

    test "returns 90 for :autonomous" do
      assert TierResolver.score_to_demote(:autonomous) == 90
    end
  end

  describe "describe/1" do
    test "returns description for :untrusted" do
      assert TierResolver.describe(:untrusted) == "Untrusted - Read own code only"
    end

    test "returns description for :probationary" do
      assert TierResolver.describe(:probationary) == "Probationary - Sandbox modifications"
    end

    test "returns description for :trusted" do
      assert TierResolver.describe(:trusted) == "Trusted - Self-modify with approval"
    end

    test "returns description for :veteran" do
      assert TierResolver.describe(:veteran) == "Veteran - Self-modify auto-approved"
    end

    test "returns description for :autonomous" do
      assert TierResolver.describe(:autonomous) == "Autonomous - Can modify own capabilities"
    end

    test "all tiers have descriptions" do
      for tier <- TierResolver.all_tiers() do
        desc = TierResolver.describe(tier)
        assert is_binary(desc), "Expected string description for #{tier}"
        assert String.length(desc) > 0, "Expected non-empty description for #{tier}"
      end
    end
  end

  describe "tier boundary integration" do
    test "every score from 0 to 100 resolves to a valid tier" do
      valid_tiers = MapSet.new(TierResolver.all_tiers())

      for score <- 0..100 do
        tier = TierResolver.resolve(score)
        assert MapSet.member?(valid_tiers, tier),
               "Score #{score} resolved to invalid tier #{inspect(tier)}"
      end
    end

    test "tier transitions happen at exact boundary scores" do
      # Just below and at each boundary
      assert TierResolver.resolve(19) == :untrusted
      assert TierResolver.resolve(20) == :probationary

      assert TierResolver.resolve(49) == :probationary
      assert TierResolver.resolve(50) == :trusted

      assert TierResolver.resolve(74) == :trusted
      assert TierResolver.resolve(75) == :veteran

      assert TierResolver.resolve(89) == :veteran
      assert TierResolver.resolve(90) == :autonomous
    end

    test "resolve is consistent with min_score and max_score" do
      for tier <- TierResolver.all_tiers() do
        min = TierResolver.min_score(tier)
        max = TierResolver.max_score(tier)

        assert TierResolver.resolve(min) == tier,
               "min_score #{min} should resolve to #{tier}"

        assert TierResolver.resolve(max) == tier,
               "max_score #{max} should resolve to #{tier}"
      end
    end

    test "promotion score matches next tier min_score" do
      for tier <- [:untrusted, :probationary, :trusted, :veteran] do
        promote_score = TierResolver.score_to_promote(tier)
        next = TierResolver.next_tier(tier)

        assert promote_score == TierResolver.min_score(next),
               "Promotion score for #{tier} should equal min_score of #{next}"
      end
    end
  end
end
