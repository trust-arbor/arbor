defmodule Arbor.Trust.BehaviourTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.Behaviour

  @moduletag :fast

  describe "tier_thresholds/0" do
    test "returns default tier threshold map" do
      thresholds = Behaviour.tier_thresholds()
      assert thresholds == %{
        untrusted: 0,
        probationary: 20,
        trusted: 50,
        veteran: 75,
        autonomous: 90
      }
    end
  end

  describe "tier_thresholds/1" do
    test "merges custom thresholds with defaults" do
      custom = %{trusted: 60, autonomous: 95}
      result = Behaviour.tier_thresholds(custom)
      assert result.trusted == 60
      assert result.autonomous == 95
      assert result.untrusted == 0
      assert result.probationary == 20
    end
  end

  describe "tiers/0" do
    test "returns all tiers in order" do
      assert Behaviour.tiers() == [:untrusted, :probationary, :trusted, :veteran, :autonomous]
    end
  end

  describe "min_score_for_tier/1" do
    test "returns minimum score for each tier" do
      assert Behaviour.min_score_for_tier(:untrusted) == 0
      assert Behaviour.min_score_for_tier(:probationary) == 20
      assert Behaviour.min_score_for_tier(:trusted) == 50
      assert Behaviour.min_score_for_tier(:veteran) == 75
      assert Behaviour.min_score_for_tier(:autonomous) == 90
    end
  end

  describe "min_score_for_tier/2" do
    test "uses custom thresholds" do
      custom = %{untrusted: 0, probationary: 25, trusted: 55, veteran: 80, autonomous: 95}
      assert Behaviour.min_score_for_tier(:trusted, custom) == 55
      assert Behaviour.min_score_for_tier(:autonomous, custom) == 95
    end
  end

  describe "tier_sufficient?/2" do
    test "same tier is sufficient" do
      assert Behaviour.tier_sufficient?(:trusted, :trusted)
    end

    test "higher tier is sufficient for lower tier" do
      assert Behaviour.tier_sufficient?(:autonomous, :untrusted)
      assert Behaviour.tier_sufficient?(:veteran, :trusted)
      assert Behaviour.tier_sufficient?(:trusted, :probationary)
    end

    test "lower tier is insufficient for higher tier" do
      refute Behaviour.tier_sufficient?(:untrusted, :probationary)
      refute Behaviour.tier_sufficient?(:probationary, :trusted)
      refute Behaviour.tier_sufficient?(:trusted, :veteran)
    end
  end
end
