defmodule Arbor.Trust.CapabilityRiskProfilesTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Trust.CapabilityRiskProfiles
  alias Arbor.Trust.Presets

  @moduletag :fast

  setup do
    previous = Application.get_env(:arbor_trust, :capability_profile_overrides)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_trust, :capability_profile_overrides)
      else
        Application.put_env(:arbor_trust, :capability_profile_overrides, previous)
      end
    end)

    Application.delete_env(:arbor_trust, :capability_profile_overrides)
    :ok
  end

  describe "profiles/0" do
    test "returns Level-0 CapabilityProfile structs with the resolved field set" do
      profile =
        CapabilityRiskProfiles.profiles()
        |> Enum.find(&(&1.uri_prefix == "arbor://fs/write"))

      assert %CapabilityProfile{} = profile
      assert profile.owner == :arbor_security
      assert profile.data_class == :confidential
      assert profile.graduation_eligible
      refute Map.has_key?(Map.from_struct(profile), :trust_floor)
    end

    test "layers operator profile overrides over inline defaults" do
      Application.put_env(:arbor_trust, :capability_profile_overrides, %{
        "arbor://fs/write/" => %{
          default_approval: :forbid,
          default_constraints: %{ttl_seconds: 60}
        }
      })

      profile =
        CapabilityRiskProfiles.profiles()
        |> Enum.find(&(&1.uri_prefix == "arbor://fs/write"))

      assert profile.default_approval == :forbid
      assert profile.default_constraints == %{ttl_seconds: 60}
      assert CapabilityRiskProfiles.security_ceilings()["arbor://fs/write"] == :block
    end
  end

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

    test "covers the highest-blast-radius URI classes" do
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
