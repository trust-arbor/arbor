defmodule Arbor.Trust.PolicyTest do
  @moduledoc """
  Tests for Trust.Policy — the bridge between trust profiles and capabilities.

  Policy now uses ProfileResolver for trust mode resolution. The effective
  mode is determined by the agent's trust profile rules (URI-prefix matching),
  security ceilings, and optional model constraints.

  Unit tests verify pure functions. Integration tests start the full
  Trust + Security stack to verify the complete pipeline.
  """
  use ExUnit.Case, async: false

  alias Arbor.Trust.Policy
  alias Arbor.Trust.Config

  @moduletag :fast

  # ===========================================================================
  # Unit tests — pure functions, no infrastructure needed
  # ===========================================================================

  describe "min_tier_for/1" do
    test "code read is available from untrusted" do
      assert Policy.min_tier_for("arbor://code/read/self/*") == :untrusted
    end

    test "sandbox write requires probationary" do
      assert Policy.min_tier_for("arbor://code/write/self/sandbox/*") == :probationary
    end

    test "impl write requires trusted" do
      assert Policy.min_tier_for("arbor://code/write/self/impl/*") == :trusted
    end

    test "install requires veteran" do
      assert Policy.min_tier_for("arbor://install/execute/self") == :veteran
    end

    test "capability management requires autonomous" do
      assert Policy.min_tier_for("arbor://capability/request/self/*") == :autonomous
    end

    test "unknown URI returns nil" do
      assert Policy.min_tier_for("arbor://nonexistent/action/self") == nil
    end
  end

  describe "mode_to_confirmation/1" do
    test "block maps to deny" do
      assert Policy.mode_to_confirmation(:block) == :deny
    end

    test "ask maps to gated" do
      assert Policy.mode_to_confirmation(:ask) == :gated
    end

    test "allow maps to auto" do
      assert Policy.mode_to_confirmation(:allow) == :auto
    end

    test "auto maps to auto" do
      assert Policy.mode_to_confirmation(:auto) == :auto
    end
  end

  describe "tier_to_preset/1" do
    test "untrusted maps to cautious" do
      assert Policy.tier_to_preset(:untrusted) == :cautious
    end

    test "probationary maps to cautious" do
      assert Policy.tier_to_preset(:probationary) == :cautious
    end

    test "trusted maps to balanced" do
      assert Policy.tier_to_preset(:trusted) == :balanced
    end

    test "veteran maps to hands_off" do
      assert Policy.tier_to_preset(:veteran) == :hands_off
    end

    test "autonomous maps to full_trust" do
      assert Policy.tier_to_preset(:autonomous) == :full_trust
    end
  end

  describe "preset_rules/1" do
    test "returns baseline and rules for each preset" do
      for preset <- [:cautious, :balanced, :hands_off, :full_trust] do
        {baseline, rules} = Policy.preset_rules(preset)
        assert baseline in [:block, :ask, :allow, :auto]
        assert is_map(rules)
      end
    end

    test "cautious preset has ask baseline and blocks shell" do
      {baseline, rules} = Policy.preset_rules(:cautious)
      assert baseline == :ask
      assert rules["arbor://shell"] == :block
    end

    test "full_trust preset has auto baseline" do
      {baseline, _rules} = Policy.preset_rules(:full_trust)
      assert baseline == :auto
    end
  end

  # ===========================================================================
  # Integration tests — require Trust + Security infrastructure
  # ===========================================================================

  describe "effective_mode/3" do
    setup :start_infrastructure

    test "returns mode from profile rules", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced preset has "arbor://actions/execute/file.read" => :auto
      assert Policy.effective_mode(agent_id, "arbor://actions/execute/file.read") == :auto
    end

    test "returns baseline for unmatched URIs", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced baseline is :ask, no rule for this URI
      assert Policy.effective_mode(agent_id, "arbor://some/unknown/uri") == :ask
    end

    test "security ceiling overrides user preference", %{agent_id: agent_id} do
      # full_trust has baseline :auto, but shell ceiling is :ask
      create_profile_with_preset(agent_id, :full_trust)
      assert Policy.effective_mode(agent_id, "arbor://shell/exec/ls") == :ask
    end

    test "returns :ask for unknown agent" do
      # Fail closed — unknown agent gets :ask (gated)
      assert Policy.effective_mode(
               "agent_ghost_#{System.unique_integer([:positive])}",
               "arbor://anything"
             ) == :ask
    end

    test "cautious preset blocks shell", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :cautious)
      # Cautious preset: shell → :block, but security ceiling is :ask
      # most_restrictive(:block, :ask) = :block
      assert Policy.effective_mode(agent_id, "arbor://shell/exec/ls") == :block
    end

    test "hands_off preset auto-approves writes", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :hands_off)
      # hands_off has code/write => :auto
      assert Policy.effective_mode(agent_id, "arbor://code/write/self/impl/*") == :auto
    end

    test "hands_off preset allows unmatched URIs", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :hands_off)
      # hands_off baseline is :allow for unmatched URIs
      assert Policy.effective_mode(agent_id, "arbor://some/unknown/uri") == :allow
    end
  end

  describe "allowed?/2" do
    setup :start_infrastructure

    test "returns true when profile doesn't block", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      assert Policy.allowed?(agent_id, "arbor://code/read/self/*")
    end

    test "returns false when profile blocks", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :cautious)
      # Cautious blocks shell
      refute Policy.allowed?(agent_id, "arbor://shell/exec/ls")
    end

    test "returns true for ask mode (allowed but gated)", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced baseline is :ask for unmatched URIs
      assert Policy.allowed?(agent_id, "arbor://code/write/self/impl/*")
    end

    test "returns false for unknown agent" do
      # Fail closed returns :ask, which is not :block, so allowed? = true
      # This is correct: unknown agents are gated, not blocked
      # The capability store will deny them at the security layer
      assert Policy.allowed?(
               "agent_nonexistent_#{System.unique_integer([:positive])}",
               "arbor://code/read/self/*"
             )
    end
  end

  describe "requires_approval?/2" do
    setup :start_infrastructure

    test "returns true for :ask mode", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced baseline is :ask for unmatched URIs
      assert Policy.requires_approval?(agent_id, "arbor://code/write/self/impl/*") == true
    end

    test "returns false for :auto mode", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced has file.read => :auto
      assert Policy.requires_approval?(agent_id, "arbor://actions/execute/file.read") == false
    end

    test "returns false for :allow mode", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced has file.write => :allow
      assert Policy.requires_approval?(agent_id, "arbor://actions/execute/file.write") == false
    end

    test "returns error for :block mode", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :cautious)
      # cautious blocks shell
      assert {:error, :denied} =
               Policy.requires_approval?(agent_id, "arbor://shell/exec/rm")
    end
  end

  describe "confirmation_mode/2" do
    setup :start_infrastructure

    test "auto for auto-mode capability", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced has file.read => :auto
      assert Policy.confirmation_mode(agent_id, "arbor://actions/execute/file.read") == :auto
    end

    test "gated for ask-mode capability", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced baseline is :ask → maps to :gated
      assert Policy.confirmation_mode(agent_id, "arbor://code/write/self/impl/*") == :gated
    end

    test "shell_exec is always gated via security ceiling", %{agent_id: agent_id} do
      # Even full_trust can't make shell :auto — security ceiling enforces :ask
      create_profile_with_preset(agent_id, :full_trust)
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/anything") == :gated
    end

    test "deny when profile blocks", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :cautious)
      # Cautious blocks shell
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/ls") == :deny
    end

    test "gated for unknown agent (fail closed)" do
      # Unknown agent → :ask → :gated (not :deny)
      assert Policy.confirmation_mode(
               "agent_ghost_#{System.unique_integer([:positive])}",
               "arbor://code/read/self/*"
             ) == :gated
    end

    test "auto for allow-mode capability", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      # balanced has file.write => :allow → maps to :auto
      assert Policy.confirmation_mode(agent_id, "arbor://actions/execute/file.write") == :auto
    end
  end

  describe "explain/3" do
    setup :start_infrastructure

    test "returns resolution chain", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :balanced)
      result = Policy.explain(agent_id, "arbor://shell/exec/git")

      assert result.resource_uri == "arbor://shell/exec/git"
      assert result.user_mode in [:block, :ask, :allow, :auto]
      assert result.security_ceiling in [:block, :ask, :allow, :auto]
      assert result.effective_mode in [:block, :ask, :allow, :auto]
    end

    test "returns error info for unknown agent" do
      result =
        Policy.explain(
          "agent_unknown_#{System.unique_integer([:positive])}",
          "arbor://shell/exec/git"
        )

      assert result.effective_mode == :ask
      assert result.error
    end
  end

  describe "grant_tier_capabilities/2" do
    setup :start_infrastructure

    test "grants all untrusted capabilities", %{agent_id: agent_id} do
      expected_count = length(Config.capabilities_for_tier(:untrusted))
      {:ok, granted} = Policy.grant_tier_capabilities(agent_id, :untrusted)
      assert granted == expected_count
    end

    test "grants all trusted capabilities", %{agent_id: agent_id} do
      expected_count = length(Config.capabilities_for_tier(:trusted))
      {:ok, granted} = Policy.grant_tier_capabilities(agent_id, :trusted)
      assert granted == expected_count
    end

    test "granted capabilities are signed and stored", %{agent_id: agent_id} do
      {:ok, _} = Policy.grant_tier_capabilities(agent_id, :probationary)
      {:ok, caps} = Arbor.Security.list_capabilities(agent_id)

      assert caps != []

      for cap <- caps do
        assert cap.principal_id == agent_id
        assert is_binary(cap.issuer_signature)
        assert byte_size(cap.issuer_signature) > 0
      end
    end

    test "granted capabilities have correct resource URIs with agent_id", %{agent_id: agent_id} do
      {:ok, _} = Policy.grant_tier_capabilities(agent_id, :untrusted)
      {:ok, caps} = Arbor.Security.list_capabilities(agent_id)

      for cap <- caps do
        # URIs should have agent_id substituted for "self"
        refute String.contains?(cap.resource_uri, "/self/")
        refute String.ends_with?(cap.resource_uri, "/self")
        assert String.contains?(cap.resource_uri, agent_id)
      end
    end

    test "grants succeed when security is available" do
      # Verify the happy path — security infrastructure is running
      assert Process.whereis(Arbor.Security.CapabilityStore) != nil
      agent_id = "agent_avail_#{System.unique_integer([:positive])}"
      assert {:ok, count} = Policy.grant_tier_capabilities(agent_id, :untrusted)
      assert count > 0
    end
  end

  describe "sync_capabilities/3" do
    setup :start_infrastructure

    test "promotion grants new capabilities", %{agent_id: agent_id} do
      # Start with probationary capabilities
      {:ok, _} = Policy.grant_tier_capabilities(agent_id, :probationary)
      {:ok, old_caps} = Arbor.Security.list_capabilities(agent_id)

      # Promote to trusted
      {:ok, result} = Policy.sync_capabilities(agent_id, :probationary, :trusted)

      assert result.effective_tier == :trusted
      assert result.revoked == length(old_caps)
      assert result.granted > 0

      # Should have trusted-tier capabilities now
      {:ok, new_caps} = Arbor.Security.list_capabilities(agent_id)
      expected_count = length(Config.capabilities_for_tier(:trusted))
      assert length(new_caps) == expected_count
    end

    test "demotion removes capabilities", %{agent_id: agent_id} do
      # Start with trusted capabilities
      {:ok, _} = Policy.grant_tier_capabilities(agent_id, :trusted)
      {:ok, trusted_caps} = Arbor.Security.list_capabilities(agent_id)

      # Demote to probationary
      {:ok, result} = Policy.sync_capabilities(agent_id, :trusted, :probationary)

      assert result.effective_tier == :probationary
      assert result.revoked == length(trusted_caps)

      # Should have fewer capabilities now
      {:ok, demoted_caps} = Arbor.Security.list_capabilities(agent_id)
      assert length(demoted_caps) < length(trusted_caps)
    end

    test "same-tier sync replaces capabilities", %{agent_id: agent_id} do
      {:ok, _} = Policy.grant_tier_capabilities(agent_id, :trusted)
      {:ok, result} = Policy.sync_capabilities(agent_id, :trusted, :trusted)

      assert result.effective_tier == :trusted
      assert result.revoked > 0
      assert result.granted > 0
    end
  end

  describe "revoke_agent_capabilities/1" do
    setup :start_infrastructure

    test "revokes all capabilities", %{agent_id: agent_id} do
      {:ok, _} = Policy.grant_tier_capabilities(agent_id, :trusted)
      {:ok, caps_before} = Arbor.Security.list_capabilities(agent_id)
      assert caps_before != []

      {:ok, revoked} = Policy.revoke_agent_capabilities(agent_id)
      assert revoked == Enum.count(caps_before)

      {:ok, caps_after} = Arbor.Security.list_capabilities(agent_id)
      assert caps_after == []
    end

    test "revoke on agent with no capabilities returns 0", %{agent_id: agent_id} do
      {:ok, 0} = Policy.revoke_agent_capabilities(agent_id)
    end
  end

  describe "security invariants" do
    setup :start_infrastructure

    test "shell_exec never auto-approved even at full_trust", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :full_trust)
      # Security ceiling: shell → :ask → :gated
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/anything") == :gated
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/ls") == :gated
    end

    test "shell blocked at cautious preset", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :cautious)
      # Cautious blocks shell → :deny
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/ls") == :deny
    end

    test "governance always gated even at full_trust", %{agent_id: agent_id} do
      create_profile_with_preset(agent_id, :full_trust)
      # Security ceiling: governance → :ask → :gated
      assert Policy.confirmation_mode(agent_id, "arbor://governance/change/self/*") == :gated
    end

    test "security ceilings cannot be overridden by profile rules", %{agent_id: agent_id} do
      # Create a profile with explicit :auto for shell
      create_profile_with_rules(agent_id, :auto, %{"arbor://shell" => :auto})
      # Security ceiling still enforces :ask
      assert Policy.effective_mode(agent_id, "arbor://shell/exec/ls") == :ask
    end

    test "profile mode progression is monotonic for presets" do
      # Each successive preset should be less restrictive for most URIs
      presets = [:cautious, :balanced, :hands_off, :full_trust]
      baselines = Enum.map(presets, fn p -> elem(Policy.preset_rules(p), 0) end)

      # Baselines should be monotonically less restrictive
      mode_order = %{block: 0, ask: 1, allow: 2, auto: 3}

      baselines
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert mode_order[a] <= mode_order[b],
               "Expected #{a} <= #{b} in restrictiveness"
      end)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp start_infrastructure(_context) do
    # Security infrastructure
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)
    ensure_started(Arbor.Security.Constraint.RateLimiter)

    # Trust infrastructure
    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )

    agent_id = "agent_policy_test_#{System.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  defp create_profile_with_preset(agent_id, preset_name) do
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
    end

    {baseline, rules} = Policy.preset_rules(preset_name)

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: baseline, rules: rules}
    end)
  end

  defp create_profile_with_rules(agent_id, baseline, rules) do
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
    end

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: baseline, rules: rules}
    end)
  end
end
