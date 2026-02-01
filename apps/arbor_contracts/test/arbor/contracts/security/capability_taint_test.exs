defmodule Arbor.Contracts.Security.CapabilityTaintTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Capability

  @moduletag :fast

  describe "taint_policy/1" do
    test "returns policy from constraints" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://actions/execute/shell_execute",
          principal_id: "agent_001",
          constraints: %{taint_policy: :strict}
        )

      assert Capability.taint_policy(cap) == :strict
    end

    test "returns :permissive policy from constraints" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://actions/execute/shell_execute",
          principal_id: "agent_001",
          constraints: %{taint_policy: :permissive}
        )

      assert Capability.taint_policy(cap) == :permissive
    end

    test "returns :audit_only policy from constraints" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://actions/execute/shell_execute",
          principal_id: "agent_001",
          constraints: %{taint_policy: :audit_only}
        )

      assert Capability.taint_policy(cap) == :audit_only
    end

    test "defaults to :permissive when not set" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://actions/execute/shell_execute",
          principal_id: "agent_001"
        )

      assert Capability.taint_policy(cap) == :permissive
    end

    test "defaults to :permissive when constraints has other keys" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://actions/execute/shell_execute",
          principal_id: "agent_001",
          constraints: %{max_requests: 100}
        )

      assert Capability.taint_policy(cap) == :permissive
    end
  end

  describe "valid_taint_policy?/1" do
    test "accepts :strict" do
      assert Capability.valid_taint_policy?(:strict)
    end

    test "accepts :permissive" do
      assert Capability.valid_taint_policy?(:permissive)
    end

    test "accepts :audit_only" do
      assert Capability.valid_taint_policy?(:audit_only)
    end

    test "rejects invalid values" do
      refute Capability.valid_taint_policy?(:invalid)
      refute Capability.valid_taint_policy?(:lenient)
      refute Capability.valid_taint_policy?("strict")
      refute Capability.valid_taint_policy?(nil)
      refute Capability.valid_taint_policy?(42)
    end
  end

  describe "valid_taint_policies/0" do
    test "returns list of valid policies" do
      policies = Capability.valid_taint_policies()

      assert :strict in policies
      assert :permissive in policies
      assert :audit_only in policies
      assert length(policies) == 3
    end
  end
end
