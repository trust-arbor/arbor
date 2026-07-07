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

    test "declares low-friction read profiles with default constraints" do
      profile =
        CapabilityRiskProfiles.profiles()
        |> Enum.find(&(&1.uri_prefix == "arbor://fs/read"))

      assert %CapabilityProfile{} = profile
      assert profile.blast_radius == :low
      assert profile.reversibility == :read_only
      assert profile.effect_class == :read
      assert profile.default_approval == :auto
      assert profile.default_constraints == %{rate_limit: 300}

      refute profile in CapabilityRiskProfiles.high_risk_profiles()
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

  describe "profile-derived policy projections" do
    test "every profile has non-ceiling policy projections" do
      profile_uris = CapabilityRiskProfiles.profiles() |> Enum.map(& &1.uri_prefix) |> Enum.sort()

      projections = [
        CapabilityRiskProfiles.graduation_thresholds(),
        CapabilityRiskProfiles.default_constraints(),
        CapabilityRiskProfiles.delegation_defaults(),
        CapabilityRiskProfiles.approval_defaults()
      ]

      for projection <- projections do
        assert profile_uris -- (projection |> Map.keys() |> Enum.sort()) == []
      end
    end

    test "every high-risk profile has a security ceiling projection" do
      profile_uris =
        CapabilityRiskProfiles.high_risk_profiles() |> Enum.map(& &1.uri_prefix) |> Enum.sort()

      ceiling_uris = CapabilityRiskProfiles.security_ceilings() |> Map.keys() |> Enum.sort()
      assert profile_uris -- ceiling_uris == []
    end

    test "derives graduation thresholds from profile metadata" do
      thresholds = CapabilityRiskProfiles.graduation_thresholds()

      assert thresholds["arbor://shell"] == :never
      assert thresholds["arbor://governance"] == :never
      assert thresholds["arbor://code/hot_load"] == :never
      assert thresholds["arbor://code/write"] == 3
      assert thresholds["arbor://fs/write"] == 3
      assert thresholds["arbor://code/compile"] == 5
      assert thresholds["arbor://action/github/pr"] == 5
      assert thresholds["arbor://fs/read"] == 0
    end

    test "projects constraints, delegation, and approval defaults" do
      assert CapabilityRiskProfiles.default_constraints()["arbor://fs/write"] == %{}
      assert CapabilityRiskProfiles.default_constraints()["arbor://fs/read"] == %{rate_limit: 300}
      assert CapabilityRiskProfiles.delegation_defaults()["arbor://fs/write"] == false
      assert CapabilityRiskProfiles.approval_defaults()["arbor://fs/write"] == :require_human
      assert CapabilityRiskProfiles.approval_defaults()["arbor://fs/read"] == :auto
    end

    test "operator profile overrides flow through all projections" do
      Application.put_env(:arbor_trust, :capability_profile_overrides, %{
        "arbor://fs/write" => %{
          default_approval: :forbid,
          default_constraints: %{ttl_seconds: 60},
          delegable: true,
          graduation_eligible: false
        }
      })

      assert CapabilityRiskProfiles.security_ceilings()["arbor://fs/write"] == :block
      assert CapabilityRiskProfiles.graduation_thresholds()["arbor://fs/write"] == :never

      assert CapabilityRiskProfiles.default_constraints()["arbor://fs/write"] == %{
               ttl_seconds: 60
             }

      assert CapabilityRiskProfiles.delegation_defaults()["arbor://fs/write"]
      assert CapabilityRiskProfiles.approval_defaults()["arbor://fs/write"] == :forbid
    end
  end
end
