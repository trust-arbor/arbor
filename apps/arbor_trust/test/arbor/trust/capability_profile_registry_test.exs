defmodule Arbor.Trust.CapabilityProfileRegistryTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Trust.CapabilityProfileRegistry

  @moduletag :fast

  describe "coverage_rows/0" do
    test "every canonical registered prefix has a profile or explicit owner/reason row" do
      assert CapabilityProfileRegistry.coverage_complete?()
      assert CapabilityProfileRegistry.coverage_gaps() == []
    end

    test "high-risk registered prefixes resolve to contract profiles" do
      assert %CapabilityProfile{owner: :arbor_shell, uri_prefix: "arbor://shell"} =
               CapabilityProfileRegistry.profile_for("arbor://shell/exec")

      assert %CapabilityProfile{owner: :arbor_security, uri_prefix: "arbor://fs/write"} =
               CapabilityProfileRegistry.profile_for("arbor://fs/write")
    end

    test "non-profiled registered prefixes carry owning library annotations" do
      rows = Map.new(CapabilityProfileRegistry.coverage_rows(), &{&1.uri_prefix, &1})

      assert rows["arbor://persistence/read"].owner == :arbor_persistence
      assert rows["arbor://persistence/read"].profile == nil

      assert rows["arbor://persistence/read"].not_profileable_reason =~
               "owned by arbor_persistence"
    end
  end
end
