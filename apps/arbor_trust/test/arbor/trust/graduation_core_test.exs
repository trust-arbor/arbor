defmodule Arbor.Trust.GraduationCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.{CapabilityRiskProfiles, GraduationCore}

  setup do
    {:ok, profile} = Profile.new("agent_core")
    profile = %{profile | rules: %{"arbor://memory/read" => :ask}}

    capability =
      Enum.find(
        CapabilityRiskProfiles.inline_profiles(),
        &(&1.uri_prefix == "arbor://memory/read")
      )

    entry = %{
      revision: 0,
      suggestion_id: nil,
      suggestion_profile_updated_at: nil,
      graduated: false,
      graduated_at: nil,
      locked: false,
      human_streak: 1
    }

    %{
      profile: profile,
      capability: capability,
      entry: entry,
      policy: %{security_ceilings: %{}, allow_permissive_baseline: false}
    }
  end

  test "accept returns a persist effect; decline returns only a locked successor", ctx do
    eligibility = eligible(ctx)
    assert eligibility.eligible

    entry =
      GraduationCore.suggest(ctx.entry, eligibility, ctx.profile, "exact", ctx.profile.created_at)

    assert {:ok, accepted, [:persist_auto_rule]} =
             GraduationCore.decide(entry, "exact", eligibility, ctx.profile, :accept)

    assert accepted.suggestion_id == nil
    assert accepted.revision == 1

    assert {:ok, declined, []} =
             GraduationCore.decide(entry, "exact", eligibility, ctx.profile, :decline)

    assert declined.locked

    assert {:error, :stale_graduation_suggestion} =
             GraduationCore.decide(entry, "forged", eligibility, ctx.profile, :accept)
  end

  test "zero threshold still requires verified human evidence and immutable profile revision",
       ctx do
    refute eligible(%{ctx | entry: %{ctx.entry | human_streak: 0}}).eligible

    entry =
      GraduationCore.suggest(
        ctx.entry,
        eligible(ctx),
        ctx.profile,
        "exact",
        ctx.profile.created_at
      )

    changed = %{ctx.profile | updated_at: DateTime.add(ctx.profile.updated_at, 1, :second)}

    assert {:error, :stale_graduation_suggestion} =
             GraduationCore.decide(entry, "exact", eligible(ctx), changed, :accept)
  end

  test "sensitive effects never graduate even when threshold configuration says zero", ctx do
    for effect <- [:governance, :trust_mutating, :identity_mutating, :financial] do
      capability = %{
        ctx.capability
        | effect_class: effect,
          graduation_eligible: true,
          default_approval: :auto
      }

      assert eligible(%{ctx | capability: capability}).reason == :never_graduate
    end

    policy = %{ctx.policy | security_ceilings: %{"arbor://memory/read" => :ask}}
    assert eligible(%{ctx | policy: policy}).reason == :ceiling_restricted
  end

  defp eligible(ctx),
    do:
      GraduationCore.eligibility(
        ctx.entry,
        "arbor://memory/read",
        ctx.profile,
        ctx.policy,
        0,
        0,
        ctx.capability
      )
end
