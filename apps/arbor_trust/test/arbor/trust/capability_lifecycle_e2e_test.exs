defmodule Arbor.Trust.CapabilityLifecycleE2ETest do
  @moduledoc """
  End-to-end tests for the full capability lifecycle.

  Covers: grant -> use -> revoke -> verify revoked, plus delegation,
  expiry, max_uses, not_before, wildcard matching, and session scoping.

  Exercises the real authorization pipeline through Security.authorize/3,
  CapabilityStore, and the Capability struct validation.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore

  setup do
    ensure_security_started()

    # Save previous config values
    prev_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled)
    prev_signing = Application.get_env(:arbor_security, :capability_signing_required)
    prev_identity = Application.get_env(:arbor_security, :strict_identity_mode)
    prev_approval = Application.get_env(:arbor_security, :approval_guard_enabled)
    prev_receipts = Application.get_env(:arbor_security, :invocation_receipts_enabled)
    prev_delegation = Application.get_env(:arbor_security, :delegation_chain_verification_enabled)

    # Disable security features that interfere with capability-focused tests
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_security, :delegation_chain_verification_enabled, false)

    agent_id = "agent_cap_lifecycle_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      restore_config(:reflex_checking_enabled, prev_reflex)
      restore_config(:capability_signing_required, prev_signing)
      restore_config(:strict_identity_mode, prev_identity)
      restore_config(:approval_guard_enabled, prev_approval)
      restore_config(:invocation_receipts_enabled, prev_receipts)
      restore_config(:delegation_chain_verification_enabled, prev_delegation)
    end)

    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # 1. Grant and Use
  # ===========================================================================

  describe "grant and use" do
    test "agent with granted capability is authorized", %{agent_id: agent_id} do
      grant_capability(agent_id, "arbor://actions/execute/test_action")

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://actions/execute/test_action", :execute)
    end

    test "agent without capability is unauthorized", %{agent_id: agent_id} do
      # No capability granted
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://actions/execute/test_action", :execute)
    end

    test "capability for one resource does not authorize another", %{agent_id: agent_id} do
      grant_capability(agent_id, "arbor://actions/execute/allowed_action")

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://actions/execute/allowed_action", :execute)

      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://fs/read/secret", :read)
    end
  end

  # ===========================================================================
  # 2. Revoke
  # ===========================================================================

  describe "revoke" do
    test "revoking a capability blocks subsequent authorization", %{agent_id: agent_id} do
      cap = grant_capability(agent_id, "arbor://shell/exec/echo")

      # Should work before revocation
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://shell/exec/echo", :execute)

      # Revoke
      assert :ok = Security.revoke(cap.id)

      # Should fail after revocation
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://shell/exec/echo", :execute)
    end

    test "revoking a non-existent capability returns error" do
      assert {:error, :not_found} = Security.revoke("cap_nonexistent_id")
    end
  end

  # ===========================================================================
  # 3. Expiry
  # ===========================================================================

  describe "expiry" do
    test "expired capability is not authorized", %{agent_id: agent_id} do
      # Grant with expires_at in the past (granted_at must be before expires_at
      # for validation to pass, so set granted_at further in the past)
      past_granted = DateTime.add(DateTime.utc_now(), -7200, :second)
      past_expires = DateTime.add(DateTime.utc_now(), -3600, :second)

      cap = %Capability{
        id: "cap_expired_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/expired_action",
        principal_id: agent_id,
        granted_at: past_granted,
        expires_at: past_expires,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      # Should fail because capability has expired
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://actions/execute/expired_action", :execute)
    end

    test "capability with future expiry is authorized", %{agent_id: agent_id} do
      future_expires = DateTime.add(DateTime.utc_now(), 3600, :second)

      cap = %Capability{
        id: "cap_future_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/future_action",
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: future_expires,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://actions/execute/future_action", :execute)
    end
  end

  # ===========================================================================
  # 4. max_uses
  # ===========================================================================

  describe "max_uses" do
    test "capability with max_uses is auto-revoked after limit", %{agent_id: agent_id} do
      cap = %Capability{
        id: "cap_maxuses_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/limited_action",
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        max_uses: 2,
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      # First use — should succeed
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://actions/execute/limited_action", :execute)

      # Second use — should succeed (and trigger auto-revoke since count reaches max)
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://actions/execute/limited_action", :execute)

      # Third use — should fail because capability was auto-revoked
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://actions/execute/limited_action", :execute)
    end

    test "capability without max_uses allows unlimited authorizations", %{agent_id: agent_id} do
      grant_capability(agent_id, "arbor://actions/execute/unlimited_action")

      # Authorize many times — all should succeed
      for _ <- 1..10 do
        assert {:ok, :authorized} =
                 Security.authorize(
                   agent_id,
                   "arbor://actions/execute/unlimited_action",
                   :execute
                 )
      end
    end
  end

  # ===========================================================================
  # 5. not_before
  # ===========================================================================

  describe "not_before" do
    test "capability with future not_before is not yet valid", %{agent_id: agent_id} do
      future_not_before = DateTime.add(DateTime.utc_now(), 3600, :second)

      cap = %Capability{
        id: "cap_notbefore_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/future_start",
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        not_before: future_not_before,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      # Should fail because not_before is in the future
      # Capability.valid?/1 checks not_before_passed?, which causes
      # find_authorizing to skip this capability
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://actions/execute/future_start", :execute)
    end

    test "capability with past not_before is valid", %{agent_id: agent_id} do
      past_not_before = DateTime.add(DateTime.utc_now(), -3600, :second)

      cap = %Capability{
        id: "cap_notbefore_past_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/past_start",
        principal_id: agent_id,
        granted_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        expires_at: nil,
        not_before: past_not_before,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://actions/execute/past_start", :execute)
    end
  end

  # ===========================================================================
  # 6. Wildcard Matching
  # ===========================================================================

  describe "wildcard matching" do
    test "prefix capability matches sub-resources", %{agent_id: agent_id} do
      # Grant arbor://shell/exec (no trailing /*)
      grant_capability(agent_id, "arbor://shell/exec")

      # Should match sub-resources via boundary-aware prefix matching
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://shell/exec/echo", :execute)

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://shell/exec/ls", :execute)
    end

    test "glob wildcard /** matches deeply nested resources", %{agent_id: agent_id} do
      grant_capability(agent_id, "arbor://fs/read/**")

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/home/user/docs", :read)

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/etc/config", :read)
    end

    test "exact match does not match unrelated resources", %{agent_id: agent_id} do
      grant_capability(agent_id, "arbor://actions/execute/specific_tool")

      # Exact resource should work
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://actions/execute/specific_tool", :execute)

      # Different resource should not match
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://actions/execute/other_tool", :execute)
    end

    test "prefix match is boundary-aware", %{agent_id: agent_id} do
      grant_capability(agent_id, "arbor://fs/read/home")

      # Sub-path should match (boundary at /)
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/home/docs", :read)

      # Similar name without boundary should NOT match
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://fs/read/home_config", :read)
    end
  end

  # ===========================================================================
  # 7. Delegation
  # ===========================================================================

  describe "delegation" do
    test "delegated capability authorizes the delegatee", %{agent_id: agent_id} do
      delegatee_id = "agent_delegatee_#{:erlang.unique_integer([:positive])}"

      # Grant parent capability with delegation_depth: 1
      {:ok, parent_cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://actions/execute/delegated_action",
          delegation_depth: 1
        )

      # Generate keypair for the delegator to sign the delegation
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      # Delegate to another agent
      {:ok, delegated_cap} =
        Security.delegate(parent_cap.id, delegatee_id, delegator_private_key: priv)

      # Delegatee should be authorized
      assert {:ok, :authorized} =
               Security.authorize(
                 delegatee_id,
                 "arbor://actions/execute/delegated_action",
                 :execute
               )

      # Verify the delegated cap has reduced delegation depth
      assert delegated_cap.delegation_depth == 0
      assert delegated_cap.parent_capability_id == parent_cap.id
    end

    test "delegation_depth: 0 prevents further delegation", %{agent_id: agent_id} do
      delegatee_id = "agent_delegatee_#{:erlang.unique_integer([:positive])}"

      # Grant non-delegatable capability (depth: 0)
      {:ok, parent_cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://actions/execute/nondelegatable",
          delegation_depth: 0
        )

      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      # Should fail to delegate
      assert {:error, :delegation_depth_exhausted} =
               Security.delegate(parent_cap.id, delegatee_id, delegator_private_key: priv)
    end

    test "revoking parent does not automatically revoke delegated cap (use cascade_revoke for that)",
         %{agent_id: agent_id} do
      delegatee_id = "agent_delegatee_#{:erlang.unique_integer([:positive])}"

      {:ok, parent_cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://actions/execute/cascade_test",
          delegation_depth: 2
        )

      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _delegated_cap} =
        Security.delegate(parent_cap.id, delegatee_id, delegator_private_key: priv)

      # Revoke parent with simple revoke (not cascade)
      :ok = Security.revoke(parent_cap.id)

      # Delegatee should still be authorized (simple revoke doesn't cascade)
      assert {:ok, :authorized} =
               Security.authorize(
                 delegatee_id,
                 "arbor://actions/execute/cascade_test",
                 :execute
               )
    end

    test "cascade_revoke removes parent and delegated capabilities", %{agent_id: agent_id} do
      delegatee_id = "agent_delegatee_#{:erlang.unique_integer([:positive])}"

      {:ok, parent_cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://actions/execute/cascade_full",
          delegation_depth: 2
        )

      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, _delegated_cap} =
        Security.delegate(parent_cap.id, delegatee_id, delegator_private_key: priv)

      # Cascade revoke the parent
      assert {:ok, count} = CapabilityStore.cascade_revoke(parent_cap.id)
      assert count >= 2

      # Both parent and delegatee should be unauthorized
      assert {:error, :unauthorized} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/cascade_full",
                 :execute
               )

      assert {:error, :unauthorized} =
               Security.authorize(
                 delegatee_id,
                 "arbor://actions/execute/cascade_full",
                 :execute
               )
    end
  end

  # ===========================================================================
  # 8. Session-Scoped Capabilities
  # ===========================================================================

  describe "session-scoped capabilities" do
    test "session-scoped capability works in correct session", %{agent_id: agent_id} do
      session_id = "session_#{:erlang.unique_integer([:positive])}"

      cap = %Capability{
        id: "cap_session_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/session_action",
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        session_id: session_id,
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      # Authorized with matching session_id
      assert {:ok, :authorized} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/session_action",
                 :execute,
                 session_id: session_id
               )
    end

    test "session-scoped capability fails in wrong session", %{agent_id: agent_id} do
      session_id = "session_#{:erlang.unique_integer([:positive])}"
      wrong_session = "session_wrong_#{:erlang.unique_integer([:positive])}"

      cap = %Capability{
        id: "cap_session_wrong_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/session_locked",
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        session_id: session_id,
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      # Should fail with wrong session
      assert {:error, :scope_mismatch} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/session_locked",
                 :execute,
                 session_id: wrong_session
               )
    end

    test "session-scoped capability fails when no session provided", %{agent_id: agent_id} do
      session_id = "session_#{:erlang.unique_integer([:positive])}"

      cap = %Capability{
        id: "cap_session_none_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://actions/execute/session_required",
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        constraints: %{},
        delegation_depth: 0,
        delegation_chain: [],
        session_id: session_id,
        metadata: %{test: true}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      # No session_id in opts — should fail scope check
      assert {:error, :scope_mismatch} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/session_required",
                 :execute
               )
    end

    test "unscoped capability works regardless of session context", %{agent_id: agent_id} do
      grant_capability(agent_id, "arbor://actions/execute/unscoped_action")

      # Works without session
      assert {:ok, :authorized} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/unscoped_action",
                 :execute
               )

      # Works with any session
      assert {:ok, :authorized} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/unscoped_action",
                 :execute,
                 session_id: "session_any"
               )
    end
  end

  # ===========================================================================
  # 9. Full Lifecycle (integration)
  # ===========================================================================

  describe "full lifecycle" do
    test "grant -> authorize -> revoke -> verify revoked", %{agent_id: agent_id} do
      # Step 1: Grant
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://actions/execute/lifecycle_test"
        )

      assert cap.principal_id == agent_id
      assert cap.resource_uri == "arbor://actions/execute/lifecycle_test"

      # Step 2: Authorize (should succeed)
      assert {:ok, :authorized} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/lifecycle_test",
                 :execute
               )

      # Step 3: List capabilities (should include our cap)
      {:ok, caps} = Security.list_capabilities(agent_id)
      assert Enum.any?(caps, &(&1.id == cap.id))

      # Step 4: Revoke
      assert :ok = Security.revoke(cap.id)

      # Step 5: Verify revoked
      assert {:error, :unauthorized} =
               Security.authorize(
                 agent_id,
                 "arbor://actions/execute/lifecycle_test",
                 :execute
               )

      # Step 6: List should no longer include the cap
      {:ok, caps_after} = Security.list_capabilities(agent_id)
      refute Enum.any?(caps_after, &(&1.id == cap.id))
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp grant_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_lifecycle_#{:erlang.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{test: true}
    }

    {:ok, :stored} = CapabilityStore.put(cap)
    cap
  end

  defp ensure_security_started do
    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    if Process.whereis(Arbor.Security.Supervisor) do
      for child <- security_children do
        try do
          case Supervisor.start_child(Arbor.Security.Supervisor, child) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, :already_present} -> :ok
            _other -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)
end
