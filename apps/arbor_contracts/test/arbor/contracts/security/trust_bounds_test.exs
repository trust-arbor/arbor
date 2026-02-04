defmodule Arbor.Contracts.Security.TrustBoundsTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.TrustBounds

  describe "sandbox_for_tier/1" do
    test "untrusted gets strict sandbox" do
      assert TrustBounds.sandbox_for_tier(:untrusted) == :strict
    end

    test "probationary gets strict sandbox" do
      assert TrustBounds.sandbox_for_tier(:probationary) == :strict
    end

    test "trusted gets standard sandbox" do
      assert TrustBounds.sandbox_for_tier(:trusted) == :standard
    end

    test "veteran gets permissive sandbox" do
      assert TrustBounds.sandbox_for_tier(:veteran) == :permissive
    end

    test "autonomous gets no sandbox" do
      assert TrustBounds.sandbox_for_tier(:autonomous) == :none
    end
  end

  describe "allowed_actions/1" do
    test "untrusted can only read, search, think" do
      assert TrustBounds.allowed_actions(:untrusted) == [:read, :search, :think]
    end

    test "probationary can also write to sandbox" do
      assert TrustBounds.allowed_actions(:probationary) == [:read, :search, :think, :write_sandbox]
    end

    test "trusted can write and execute safe commands" do
      assert TrustBounds.allowed_actions(:trusted) == [
               :read,
               :search,
               :think,
               :write,
               :execute_safe
             ]
    end

    test "veteran can execute and use network" do
      assert TrustBounds.allowed_actions(:veteran) == [
               :read,
               :search,
               :think,
               :write,
               :execute,
               :network
             ]
    end

    test "autonomous has all permissions" do
      assert TrustBounds.allowed_actions(:autonomous) == :all
    end
  end

  describe "action_allowed?/2" do
    test "read is allowed at all tiers" do
      for tier <- TrustBounds.tiers() do
        assert TrustBounds.action_allowed?(tier, :read)
      end
    end

    test "think is allowed at all tiers" do
      for tier <- TrustBounds.tiers() do
        assert TrustBounds.action_allowed?(tier, :think)
      end
    end

    test "write_sandbox is not allowed for untrusted" do
      refute TrustBounds.action_allowed?(:untrusted, :write_sandbox)
      assert TrustBounds.action_allowed?(:probationary, :write_sandbox)
    end

    test "write is not allowed below trusted" do
      refute TrustBounds.action_allowed?(:untrusted, :write)
      refute TrustBounds.action_allowed?(:probationary, :write)
      assert TrustBounds.action_allowed?(:trusted, :write)
    end

    test "execute is not allowed below veteran" do
      refute TrustBounds.action_allowed?(:untrusted, :execute)
      refute TrustBounds.action_allowed?(:probationary, :execute)
      refute TrustBounds.action_allowed?(:trusted, :execute)
      assert TrustBounds.action_allowed?(:veteran, :execute)
    end

    test "autonomous allows any action" do
      assert TrustBounds.action_allowed?(:autonomous, :execute)
      assert TrustBounds.action_allowed?(:autonomous, :network)
      assert TrustBounds.action_allowed?(:autonomous, :anything)
    end
  end

  describe "tiers/0" do
    test "returns all tiers in order" do
      assert TrustBounds.tiers() == [:untrusted, :probationary, :trusted, :veteran, :autonomous]
    end
  end

  describe "sandbox_levels/0" do
    test "returns all sandbox levels in order from most to least restrictive" do
      assert TrustBounds.sandbox_levels() == [:strict, :standard, :permissive, :none]
    end
  end

  describe "compare_tiers/2" do
    test "compares tiers correctly" do
      assert TrustBounds.compare_tiers(:untrusted, :trusted) == :lt
      assert TrustBounds.compare_tiers(:trusted, :untrusted) == :gt
      assert TrustBounds.compare_tiers(:trusted, :trusted) == :eq
      assert TrustBounds.compare_tiers(:autonomous, :veteran) == :gt
    end
  end

  describe "minimum_tier_for_action/1" do
    test "read requires untrusted" do
      assert TrustBounds.minimum_tier_for_action(:read) == :untrusted
    end

    test "write_sandbox requires probationary" do
      assert TrustBounds.minimum_tier_for_action(:write_sandbox) == :probationary
    end

    test "write requires trusted" do
      assert TrustBounds.minimum_tier_for_action(:write) == :trusted
    end

    test "execute requires veteran" do
      assert TrustBounds.minimum_tier_for_action(:execute) == :veteran
    end

    test "network requires veteran" do
      assert TrustBounds.minimum_tier_for_action(:network) == :veteran
    end
  end

  describe "sandbox_required_for_action/1" do
    test "read works in strict sandbox" do
      assert TrustBounds.sandbox_required_for_action(:read) == :strict
    end

    test "write requires standard sandbox" do
      assert TrustBounds.sandbox_required_for_action(:write) == :standard
    end

    test "execute requires permissive sandbox" do
      assert TrustBounds.sandbox_required_for_action(:execute) == :permissive
    end

    test "network requires permissive sandbox" do
      assert TrustBounds.sandbox_required_for_action(:network) == :permissive
    end
  end
end
