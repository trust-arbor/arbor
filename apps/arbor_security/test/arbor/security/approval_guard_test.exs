defmodule Arbor.Security.ApprovalGuardTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.ApprovalGuard

  @moduletag :fast

  # ===========================================================================
  # enabled? / disabled behavior
  # ===========================================================================

  describe "enabled?/0" do
    test "disabled by default" do
      refute ApprovalGuard.enabled?()
    end

    test "enabled via config" do
      original = Application.get_env(:arbor_security, :approval_guard_enabled)

      try do
        Application.put_env(:arbor_security, :approval_guard_enabled, true)
        assert ApprovalGuard.enabled?()
      after
        if original do
          Application.put_env(:arbor_security, :approval_guard_enabled, original)
        else
          Application.delete_env(:arbor_security, :approval_guard_enabled)
        end
      end
    end
  end

  describe "check/3 when disabled" do
    test "falls through to escalation (returns :ok for non-approval caps)" do
      cap = make_capability("arbor://code/read/agent_test/file.ex")

      # When disabled, delegates to Escalation which returns :ok
      # if requires_approval is not set
      assert :ok = ApprovalGuard.check(cap, "agent_test", "arbor://code/read/agent_test/file.ex")
    end
  end

  # ===========================================================================
  # check/3 when enabled (with Trust infrastructure)
  # ===========================================================================

  describe "check/3 when enabled with trust" do
    setup do
      original_guard = Application.get_env(:arbor_security, :approval_guard_enabled)
      original_escalation = Application.get_env(:arbor_security, :consensus_escalation_enabled)

      Application.put_env(:arbor_security, :approval_guard_enabled, true)
      # Disable consensus escalation — no Consensus.Coordinator running in tests
      Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

      # Start Trust + Security infrastructure
      ensure_started(Arbor.Security.Identity.Registry)
      ensure_started(Arbor.Security.SystemAuthority)
      ensure_started(Arbor.Security.CapabilityStore)
      ensure_started(Arbor.Security.Reflex.Registry)
      ensure_started(Arbor.Security.Constraint.RateLimiter)
      ensure_started(Arbor.Trust.EventStore)
      ensure_started(Arbor.Trust.Store)

      ensure_started(Arbor.Trust.Manager,
        circuit_breaker: false,
        decay: false,
        event_store: true
      )

      agent_id = "agent_guard_test_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        if original_guard do
          Application.put_env(:arbor_security, :approval_guard_enabled, original_guard)
        else
          Application.delete_env(:arbor_security, :approval_guard_enabled)
        end

        if original_escalation do
          Application.put_env(:arbor_security, :consensus_escalation_enabled, original_escalation)
        else
          Application.delete_env(:arbor_security, :consensus_escalation_enabled)
        end
      end)

      {:ok, agent_id: agent_id}
    end

    test "auto-approves code read for untrusted agent", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      cap = make_capability("arbor://code/read/#{agent_id}/file.ex")

      assert :ok = ApprovalGuard.check(cap, agent_id, "arbor://code/read/#{agent_id}/file.ex")
    end

    test "denies codebase write for restricted agent", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      cap = make_capability("arbor://code/write/#{agent_id}/impl/file.ex")

      assert {:error, :policy_denied} =
               ApprovalGuard.check(cap, agent_id, "arbor://code/write/#{agent_id}/impl/file.ex")
    end

    test "gates codebase write for trusted agent", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      cap = make_capability("arbor://code/write/#{agent_id}/impl/file.ex")

      # Gated → delegates to Escalation → escalation disabled in test config
      assert {:error, :escalation_disabled} =
               ApprovalGuard.check(cap, agent_id, "arbor://code/write/#{agent_id}/impl/file.ex")
    end

    test "auto-approves codebase write for veteran agent", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :veteran)
      cap = make_capability("arbor://code/write/#{agent_id}/impl/file.ex")

      assert :ok = ApprovalGuard.check(cap, agent_id, "arbor://code/write/#{agent_id}/impl/file.ex")
    end

    test "denies shell exec for restricted agent", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :untrusted)
      cap = make_capability("arbor://shell/exec/ls")

      assert {:error, :policy_denied} =
               ApprovalGuard.check(cap, agent_id, "arbor://shell/exec/ls")
    end

    test "gates shell exec for autonomous agent (never auto)", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :autonomous)
      cap = make_capability("arbor://shell/exec/ls")

      # Gated → delegates to Escalation → escalation disabled in test config
      assert {:error, :escalation_disabled} =
               ApprovalGuard.check(cap, agent_id, "arbor://shell/exec/ls")
    end
  end

  # ===========================================================================
  # check/3 with confirm-then-automate (graduation)
  # ===========================================================================

  describe "check/3 with graduated capabilities" do
    setup do
      original_guard = Application.get_env(:arbor_security, :approval_guard_enabled)
      original_escalation = Application.get_env(:arbor_security, :consensus_escalation_enabled)

      Application.put_env(:arbor_security, :approval_guard_enabled, true)
      Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

      # Start Trust + Security infrastructure
      ensure_started(Arbor.Security.Identity.Registry)
      ensure_started(Arbor.Security.SystemAuthority)
      ensure_started(Arbor.Security.CapabilityStore)
      ensure_started(Arbor.Security.Reflex.Registry)
      ensure_started(Arbor.Security.Constraint.RateLimiter)
      ensure_started(Arbor.Trust.EventStore)
      ensure_started(Arbor.Trust.Store)
      ensure_started(Arbor.Trust.ConfirmationTracker)

      ensure_started(Arbor.Trust.Manager,
        circuit_breaker: false,
        decay: false,
        event_store: true
      )

      agent_id = "agent_grad_test_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        if original_guard do
          Application.put_env(:arbor_security, :approval_guard_enabled, original_guard)
        else
          Application.delete_env(:arbor_security, :approval_guard_enabled)
        end

        if original_escalation do
          Application.put_env(:arbor_security, :consensus_escalation_enabled, original_escalation)
        else
          Application.delete_env(:arbor_security, :consensus_escalation_enabled)
        end
      end)

      {:ok, agent_id: agent_id}
    end

    test "graduated gated capability auto-approves", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"
      cap = make_capability(uri)

      # Without graduation: gated → escalation disabled
      assert {:error, :escalation_disabled} = ApprovalGuard.check(cap, agent_id, uri)

      # Record enough approvals to graduate (codebase_write threshold: 3)
      Arbor.Trust.ConfirmationTracker.record_approval(agent_id, uri)
      Arbor.Trust.ConfirmationTracker.record_approval(agent_id, uri)
      Arbor.Trust.ConfirmationTracker.record_approval(agent_id, uri)

      # Now graduated → auto-approved
      assert :ok = ApprovalGuard.check(cap, agent_id, uri)
    end

    test "shell never auto-approves even after graduation attempts", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :autonomous)
      uri = "arbor://shell/exec/ls"
      cap = make_capability(uri)

      # Try to graduate shell (20 approvals)
      for _ <- 1..20 do
        Arbor.Trust.ConfirmationTracker.record_approval(agent_id, uri)
      end

      # Still gated → escalation
      assert {:error, :escalation_disabled} = ApprovalGuard.check(cap, agent_id, uri)
    end

    test "rejection reverts graduation back to gated", %{agent_id: agent_id} do
      create_profile_at_tier(agent_id, :trusted)
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"
      cap = make_capability(uri)

      # Graduate
      Arbor.Trust.ConfirmationTracker.record_approval(agent_id, uri)
      Arbor.Trust.ConfirmationTracker.record_approval(agent_id, uri)
      Arbor.Trust.ConfirmationTracker.record_approval(agent_id, uri)
      assert :ok = ApprovalGuard.check(cap, agent_id, uri)

      # Rejection reverts
      Arbor.Trust.ConfirmationTracker.record_rejection(agent_id, uri)
      assert {:error, :escalation_disabled} = ApprovalGuard.check(cap, agent_id, uri)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp make_capability(resource_uri) do
    %{
      id: "cap_test_#{System.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: "agent_test",
      constraints: %{},
      metadata: %{}
    }
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  defp create_profile_at_tier(agent_id, tier) do
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
    end

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
