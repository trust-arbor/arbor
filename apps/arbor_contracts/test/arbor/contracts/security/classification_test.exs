defmodule Arbor.Contracts.Security.ClassificationTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Classification

  @moduletag :fast

  describe "vocabulary" do
    test "effect_classes/0 includes network_egress and the core effects" do
      classes = Classification.effect_classes()
      assert :network_egress in classes
      assert :read in classes
      assert :local_write in classes
      assert :process_spawn in classes
      assert :financial in classes
      assert :identity_mutating in classes
    end

    test "egress_tiers/0 includes all four locality tiers plus :none" do
      tiers = Classification.egress_tiers()
      assert :on_host in tiers
      assert :on_premises in tiers
      assert :external_provider in tiers
      assert :external_peer in tiers
      assert :none in tiers
    end
  end

  describe "external_egress?/1" do
    test "external_provider and external_peer cross the boundary" do
      assert Classification.external_egress?(:external_provider)
      assert Classification.external_egress?(:external_peer)
    end

    test "on_host and on_premises do NOT (operator-owned hardware)" do
      refute Classification.external_egress?(:on_host)
      refute Classification.external_egress?(:on_premises)
    end

    test ":none is not egress" do
      refute Classification.external_egress?(:none)
    end
  end
end
