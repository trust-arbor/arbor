defmodule Arbor.Trust.AuthorityTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.Authority

  describe "new_profile/2" do
    test "creates profile with default untrusted tier" do
      profile = Authority.new_profile("agent_123")
      assert profile.agent_id == "agent_123"
      assert profile.tier == :untrusted
      assert profile.baseline == :ask
      assert profile.trust_score == 0
    end

    test "creates profile with veteran tier and hands_off preset" do
      profile = Authority.new_profile("agent_123", :veteran)
      assert profile.tier == :veteran
      assert profile.baseline == :allow
      assert profile.rules["arbor://shell"] == :ask
      assert profile.rules["arbor://governance"] == :ask
      assert profile.rules["arbor://fs"] == :auto
    end

    test "creates profile with autonomous tier and full_trust preset" do
      profile = Authority.new_profile("agent_123", :autonomous)
      assert profile.tier == :autonomous
      assert profile.baseline == :auto
    end
  end

  describe "record_action_success/1" do
    test "increments success and total counts" do
      profile = Authority.new_profile("agent_123")
      updated = Authority.record_action_success(profile)
      assert updated.successful_actions == 1
      assert updated.total_actions == 1
    end

    test "recalculates scores" do
      profile = Authority.new_profile("agent_123")
      updated = Authority.record_action_success(profile)
      assert updated.success_rate_score == 100.0
    end
  end

  describe "record_security_violation/1" do
    test "increments violations" do
      profile = Authority.new_profile("agent_123")
      updated = Authority.record_security_violation(profile)
      assert updated.security_violations == 1
      assert updated.security_score == 80.0
    end

    test "security score floors at 0" do
      profile = Authority.new_profile("agent_123")

      updated =
        Enum.reduce(1..6, profile, fn _, p -> Authority.record_security_violation(p) end)

      assert updated.security_score == 0.0
    end
  end

  describe "record_proposal_approved/2" do
    test "awards trust points" do
      profile = Authority.new_profile("agent_123")
      updated = Authority.record_proposal_approved(profile, :high)
      assert updated.trust_points == 10
      assert updated.proposals_approved == 1
    end

    test "may graduate tier based on points" do
      profile = %{Authority.new_profile("agent_123") | trust_points: 95}
      updated = Authority.record_proposal_approved(profile, :medium)
      assert updated.trust_points == 100
      assert updated.tier == :trusted
    end
  end

  describe "apply_decay/2" do
    test "no decay within grace period" do
      profile = %{Authority.new_profile("agent_123") | trust_points: 100}
      updated = Authority.apply_decay(profile, 5)
      assert updated.trust_points == 100
    end

    test "decays after grace period" do
      profile = %{Authority.new_profile("agent_123") | trust_points: 100}
      updated = Authority.apply_decay(profile, 17)
      assert updated.trust_points == 90
    end

    test "decay floors at 10 points" do
      profile = %{Authority.new_profile("agent_123") | trust_points: 15}
      updated = Authority.apply_decay(profile, 100)
      assert updated.trust_points == 10
    end

    test "no decay when frozen" do
      profile = Authority.new_profile("agent_123") |> Authority.freeze(:test)
      updated = Authority.apply_decay(profile, 100)
      assert updated.trust_points == 0
    end
  end

  describe "effective_mode/3" do
    test "returns baseline for unmatched URI" do
      profile = Authority.new_profile("agent_123", :veteran)
      assert Authority.effective_mode(profile, "arbor://unknown/thing") == :allow
    end

    test "returns specific rule for matched URI" do
      profile = Authority.new_profile("agent_123", :veteran)
      assert Authority.effective_mode(profile, "arbor://shell/exec") == :ask
    end

    test "security ceiling overrides user preference" do
      profile = Authority.new_profile("agent_123", :autonomous)
      # full_trust baseline is :auto, but shell ceiling is :ask
      assert Authority.effective_mode(profile, "arbor://shell/exec") == :ask
    end

    test "longest prefix match wins" do
      # Start with a clean profile (no preset rules that might interfere)
      profile =
        %{Authority.new_profile("agent_123") | rules: %{}}
        |> Authority.set_rule("arbor://code", :ask)
        |> Authority.set_rule("arbor://code/read", :auto)

      assert Authority.effective_mode(profile, "arbor://code/read/file.ex") == :auto
      assert Authority.effective_mode(profile, "arbor://code/write/file.ex") == :ask
    end
  end

  describe "resolve_tier/1" do
    test "maps scores to tiers" do
      assert Authority.resolve_tier(0) == :untrusted
      assert Authority.resolve_tier(19) == :untrusted
      assert Authority.resolve_tier(20) == :probationary
      assert Authority.resolve_tier(50) == :trusted
      assert Authority.resolve_tier(75) == :veteran
      assert Authority.resolve_tier(90) == :autonomous
    end
  end

  describe "tier_to_preset/1" do
    test "maps tiers to presets" do
      assert Authority.tier_to_preset(:untrusted) == :cautious
      assert Authority.tier_to_preset(:trusted) == :balanced
      assert Authority.tier_to_preset(:veteran) == :hands_off
      assert Authority.tier_to_preset(:autonomous) == :full_trust
    end
  end

  describe "most_restrictive/1" do
    test "returns most restrictive mode" do
      assert Authority.most_restrictive([:auto, :allow, :ask]) == :ask
      assert Authority.most_restrictive([:auto, :block]) == :block
      assert Authority.most_restrictive([:auto, :auto]) == :auto
    end
  end

  describe "set_tier/2" do
    test "updates tier and applies preset rules" do
      profile = Authority.new_profile("agent_123", :untrusted)
      assert profile.baseline == :ask

      updated = Authority.set_tier(profile, :veteran)
      assert updated.tier == :veteran
      assert updated.baseline == :allow
      assert updated.rules["arbor://shell"] == :ask
    end
  end

  describe "freeze/unfreeze" do
    test "freeze sets frozen state" do
      profile = Authority.new_profile("agent_123")
      frozen = Authority.freeze(profile, :security_incident)
      assert frozen.frozen == true
      assert frozen.frozen_reason == :security_incident
    end

    test "unfreeze clears frozen state" do
      profile = Authority.new_profile("agent_123") |> Authority.freeze(:test)
      unfrozen = Authority.unfreeze(profile)
      assert unfrozen.frozen == false
      assert unfrozen.frozen_reason == nil
    end
  end

  describe "explain/3" do
    test "returns resolution chain" do
      profile = Authority.new_profile("agent_123", :veteran)
      explanation = Authority.explain(profile, "arbor://shell/exec")

      assert explanation.effective_mode == :ask
      assert explanation.user_mode == :ask
      assert explanation.ceiling_mode == :ask
      assert explanation.tier == :veteran
    end
  end

  describe "show_summary/1" do
    test "formats profile for display" do
      profile = Authority.new_profile("agent_123", :veteran)
      summary = Authority.show_summary(profile)

      assert summary.tier == :veteran
      assert summary.baseline == :allow
      assert is_map(summary.stats)
    end
  end
end
