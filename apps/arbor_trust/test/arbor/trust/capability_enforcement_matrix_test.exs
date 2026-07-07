defmodule Arbor.Trust.CapabilityEnforcementMatrixTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.{CapabilityEnforcementMatrix, CapabilityRiskProfiles}

  @moduletag :fast

  describe "rows/0" do
    test "covers every declared high-risk profile with soft and hard gates" do
      profile_uris =
        CapabilityRiskProfiles.high_risk_profiles()
        |> Enum.map(& &1.uri_prefix)
        |> Enum.sort()

      row_uris =
        CapabilityEnforcementMatrix.rows()
        |> Enum.map(& &1.uri_prefix)
        |> Enum.sort()

      assert row_uris == profile_uris

      for row <- CapabilityEnforcementMatrix.rows() do
        assert row.soft_gate.layer == :soft
        assert row.hard_gate.layer == :hard
        assert is_atom(row.soft_gate.id)
        assert is_atom(row.hard_gate.id)
      end
    end

    test "declares hard-gate targets separate from the authorize/4 decision path" do
      for row <- CapabilityEnforcementMatrix.rows() do
        refute row.hard_gate.authorize4_dependent?
        refute row.soft_gate.decision_path == row.hard_gate.decision_path
        refute row.soft_gate.id == row.hard_gate.id
      end
    end

    test "declares the expected K5 class pairings" do
      rows = Map.new(CapabilityEnforcementMatrix.rows(), &{&1.uri_prefix, &1})

      assert rows["arbor://shell"].capability_class == :shell_exec
      assert rows["arbor://shell"].soft_gate.id == :trust_ask_ceiling
      assert rows["arbor://shell"].hard_gate.id == :sandbox_no_nic

      assert rows["arbor://action/github/pr"].capability_class == :network_egress
      assert rows["arbor://action/github/pr"].soft_gate.id == :egress_gate
      assert rows["arbor://action/github/pr"].hard_gate.id == :host_route_or_netns_filter

      assert rows["arbor://fs/write"].capability_class == :filesystem_write
      assert rows["arbor://fs/write"].soft_gate.id == :file_guard
      assert rows["arbor://fs/write"].hard_gate.id == :worktree_mount_confinement

      assert rows["arbor://governance"].capability_class == :administrative_mutation
      assert rows["arbor://governance"].soft_gate.id == :capability_gate
      assert rows["arbor://governance"].hard_gate.id == :non_agent_admin_boundary
    end
  end

  describe "row_for/1" do
    test "returns the most-specific high-risk profile covering a URI" do
      {:ok, row} = CapabilityEnforcementMatrix.row_for("arbor://shell/exec/git")

      assert row.uri_prefix == "arbor://shell"
      assert row.capability_class == :shell_exec
    end

    test "fails closed for URIs without a high-risk profile" do
      assert {:error, :unknown_high_risk_profile} =
               CapabilityEnforcementMatrix.row_for("arbor://memory/read")
    end
  end

  describe "Arbor.Trust facade" do
    test "exposes the enforcement matrix without requiring internal module access" do
      assert Arbor.Trust.capability_enforcement_rows() == CapabilityEnforcementMatrix.rows()

      assert {:ok, row} = Arbor.Trust.capability_enforcement_for("arbor://fs/write/project")
      assert row.uri_prefix == "arbor://fs/write"
    end
  end
end
