defmodule Arbor.Trust.CapabilityRiskProfilesTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.CapabilityRiskProfiles
  alias Arbor.Trust.Presets

  @moduletag :fast

  describe "security_ceilings/0" do
    test "generates ceilings from declared high-risk profiles" do
      generated =
        CapabilityRiskProfiles.high_risk_profiles()
        |> Enum.flat_map(fn profile ->
          case CapabilityRiskProfiles.ceiling_mode(profile) do
            nil -> []
            mode -> [{profile.uri_prefix, mode}]
          end
        end)
        |> Map.new()

      assert CapabilityRiskProfiles.security_ceilings() == generated
      assert Presets.default_security_ceilings() == generated
    end

    test "covers the Ring A highest-blast-radius URI classes" do
      ceilings = CapabilityRiskProfiles.security_ceilings()

      assert ceilings["arbor://shell"] == :ask
      assert ceilings["arbor://governance"] == :ask
      assert ceilings["arbor://trust/write"] == :ask
      assert ceilings["arbor://trust/auto_promote"] == :ask
      assert ceilings["arbor://agent/create"] == :ask
      assert ceilings["arbor://agent/destroy"] == :ask
      assert ceilings["arbor://agent/spawn"] == :ask
      assert ceilings["arbor://agent/spawn_worker"] == :ask
      assert ceilings["arbor://consensus/admin"] == :ask
      assert ceilings["arbor://monitor/remediate"] == :ask
      assert ceilings["arbor://code/write"] == :ask
      assert ceilings["arbor://code/compile"] == :ask
      assert ceilings["arbor://code/reload"] == :ask
      assert ceilings["arbor://code/hot_load"] == :ask
      assert ceilings["arbor://fs/write"] == :ask
      assert ceilings["arbor://action/git/commit"] == :ask
      assert ceilings["arbor://action/git/branch"] == :ask
      assert ceilings["arbor://action/github/pr"] == :ask
      assert ceilings["arbor://action/mix/format"] == :ask
      assert ceilings["arbor://action/code_review/apply_changes"] == :ask
    end

    test "maps profile default approval to ceiling mode" do
      assert CapabilityRiskProfiles.ceiling_mode(%{default_approval: :forbid}) == :block
      assert CapabilityRiskProfiles.ceiling_mode(%{default_approval: :require_human}) == :ask
      assert CapabilityRiskProfiles.ceiling_mode(%{default_approval: :notify}) == :allow
      assert CapabilityRiskProfiles.ceiling_mode(%{default_approval: :auto}) == nil
    end
  end
end
