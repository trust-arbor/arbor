defmodule Arbor.Trust.PolicyTest do
  @moduledoc """
  Tests for Trust.Policy — the bridge between trust tiers and capabilities.

  Unit tests (describe blocks without infrastructure) test pure query functions
  via direct CapabilityTemplates lookup. Integration tests start the full
  Trust + Security stack to verify grant/sync/revoke flows.
  """
  use ExUnit.Case, async: false

  alias Arbor.Trust.Policy
  alias Arbor.Trust.CapabilityTemplates

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

  # ===========================================================================
  # Integration tests — require Trust + Security infrastructure
  # ===========================================================================

  describe "allowed?/2" do
    setup :start_infrastructure

    test "untrusted agent can read code", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      assert Policy.allowed?(agent_id, "arbor://code/read/self/*")
    end

    test "untrusted agent cannot write impl", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      refute Policy.allowed?(agent_id, "arbor://code/write/self/impl/*")
    end

    test "trusted agent can write impl", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      assert Policy.allowed?(agent_id, "arbor://code/write/self/impl/*")
    end

    test "veteran agent can install", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :veteran)
      assert Policy.allowed?(agent_id, "arbor://install/execute/self")
    end

    test "returns false for unknown agent" do
      refute Policy.allowed?(
               "agent_nonexistent_#{System.unique_integer([:positive])}",
               "arbor://code/read/self/*"
             )
    end
  end

  describe "requires_approval?/2" do
    setup :start_infrastructure

    test "impl write requires approval at trusted tier", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      assert Policy.requires_approval?(agent_id, "arbor://code/write/self/impl/*") == true
    end

    test "impl write does NOT require approval at veteran tier", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :veteran)
      assert Policy.requires_approval?(agent_id, "arbor://code/write/self/impl/*") == false
    end

    test "returns error for denied capability", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)

      assert {:error, :denied} =
               Policy.requires_approval?(agent_id, "arbor://code/write/self/impl/*")
    end

    test "code read never requires approval", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      assert Policy.requires_approval?(agent_id, "arbor://code/read/self/*") == false
    end
  end

  describe "confirmation_mode/2" do
    setup :start_infrastructure

    test "auto for unconstrained capability", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      assert Policy.confirmation_mode(agent_id, "arbor://code/read/self/*") == :auto
    end

    test "gated for approval-required capability", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      assert Policy.confirmation_mode(agent_id, "arbor://code/write/self/impl/*") == :gated
    end

    test "shell_exec is always gated via ConfirmationMatrix", %{agent_id: agent_id} do
      # Shell bundle is NEVER :auto at any tier (security invariant)
      create_profile_at_tier(agent_id, :autonomous)
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/anything") == :gated
    end

    test "deny for unavailable capability", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      assert Policy.confirmation_mode(agent_id, "arbor://governance/change/self/*") == :deny
    end

    test "deny for unknown agent" do
      assert Policy.confirmation_mode(
               "agent_ghost_#{System.unique_integer([:positive])}",
               "arbor://code/read/self/*"
             ) == :deny
    end
  end

  describe "effective_tier/1" do
    setup :start_infrastructure

    test "returns agent's behavioral tier", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      assert {:ok, :trusted} = Policy.effective_tier(agent_id)
    end

    test "untrusted agent", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      assert {:ok, :untrusted} = Policy.effective_tier(agent_id)
    end

    test "returns error for nonexistent agent" do
      assert {:error, _} =
               Policy.effective_tier("agent_no_such_#{System.unique_integer([:positive])}")
    end
  end

  describe "grant_tier_capabilities/2" do
    setup :start_infrastructure

    test "grants all untrusted capabilities", %{agent_id: agent_id} do
      expected_count = length(CapabilityTemplates.capabilities_for_tier(:untrusted))
      {:ok, granted} = Policy.grant_tier_capabilities(agent_id, :untrusted)
      assert granted == expected_count
    end

    test "grants all trusted capabilities", %{agent_id: agent_id} do
      expected_count = length(CapabilityTemplates.capabilities_for_tier(:trusted))
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
      expected_count = length(CapabilityTemplates.capabilities_for_tier(:trusted))
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

    test "shell_exec never auto-approved even at autonomous tier", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :autonomous)
      # Shell bundle is gated at all tiers where it's available (security invariant)
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/anything") == :gated
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/ls") == :gated
    end

    test "shell_exec denied at restricted tier", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/ls") == :deny
    end

    test "allowed? is monotonic with tier progression", %{agent_id: agent_id} do
      # If something is allowed at tier N, it should be allowed at tier N+1
      uri = "arbor://code/write/self/impl/*"
      tiers = [:untrusted, :probationary, :trusted, :veteran, :autonomous]

      results =
        Enum.map(tiers, fn tier ->
          create_profile_at_tier(agent_id, tier)
          {tier, Policy.allowed?(agent_id, uri)}
        end)

      # Find where it becomes true
      first_true_idx = Enum.find_index(results, fn {_, v} -> v end)

      if first_true_idx do
        # Everything after should also be true
        results
        |> Enum.drop(first_true_idx)
        |> Enum.each(fn {tier, allowed} ->
          assert allowed, "Expected #{uri} to be allowed at #{tier}"
        end)
      end
    end

    test "governance requires approval even at autonomous", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :autonomous)
      assert Policy.confirmation_mode(agent_id, "arbor://governance/change/self/*") == :gated
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

  defp create_profile_at_tier(agent_id, tier) do
    # Create profile (starts at untrusted)
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
    end

    # Set the tier directly via Store for testing
    score =
      case tier do
        :untrusted -> 0
        :probationary -> 25
        :trusted -> 60
        :veteran -> 80
        :autonomous -> 95
      end

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | tier: tier, trust_score: score}
    end)
  end
end
