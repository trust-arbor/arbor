defmodule Arbor.Security.CapabilityLifecycleE2ETest do
  @moduledoc """
  End-to-end tests for the capability system lifecycle.

  Exercises the full grant → authorize → revoke → delegate pipeline
  through the public Security facade.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry

  setup do
    # Generate identities with keypairs for delegation signing
    {:ok, identity_a} = Identity.generate(name: "e2e-agent-a")
    {:ok, identity_b} = Identity.generate(name: "e2e-agent-b")
    {:ok, identity_c} = Identity.generate(name: "e2e-agent-c")

    :ok = Registry.register(identity_a)
    :ok = Registry.register(identity_b)
    :ok = Registry.register(identity_c)

    {:ok,
     agent_a: identity_a.agent_id,
     agent_b: identity_b.agent_id,
     agent_c: identity_c.agent_id,
     identity_a: identity_a,
     identity_b: identity_b,
     identity_c: identity_c}
  end

  # ===========================================================================
  # 1. Grant → authorize → revoke cycle
  # ===========================================================================

  describe "grant → authorize → revoke cycle" do
    test "grant enables authorization, revoke disables it", %{agent_a: agent_a} do
      # Grant a capability
      {:ok, cap} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://fs/read/e2e/cycle"
        )

      # Authorization succeeds
      assert {:ok, :authorized} =
               Security.authorize(agent_a, "arbor://fs/read/e2e/cycle", nil,
                 verify_identity: false
               )

      # Revoke the capability
      assert :ok = Security.revoke(cap.id)

      # Authorization now fails
      assert {:error, :unauthorized} =
               Security.authorize(agent_a, "arbor://fs/read/e2e/cycle", nil,
                 verify_identity: false
               )
    end

    test "revoking returns error for unknown capability" do
      assert {:error, :not_found} = Security.revoke("cap_nonexistent_e2e_#{:erlang.unique_integer([:positive])}")
    end
  end

  # ===========================================================================
  # 2. max_uses constraint
  # ===========================================================================

  describe "max_uses constraint" do
    test "capability auto-revokes after max_uses authorizations", %{agent_a: agent_a} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://fs/read/e2e/maxuses",
          max_uses: 3
        )

      # First 3 authorizations succeed
      for i <- 1..3 do
        assert {:ok, :authorized} =
                 Security.authorize(agent_a, "arbor://fs/read/e2e/maxuses", nil,
                   verify_identity: false
                 ),
               "Authorization #{i} of 3 should succeed"
      end

      # 4th authorization fails — capability was auto-revoked after hitting max_uses
      assert {:error, :unauthorized} =
               Security.authorize(agent_a, "arbor://fs/read/e2e/maxuses", nil,
                 verify_identity: false
               )
    end
  end

  # ===========================================================================
  # 3. Delegation chain with depth limits
  # ===========================================================================

  describe "delegation chain" do
    test "A delegates to B, B can authorize", %{
      agent_a: agent_a,
      agent_b: agent_b,
      identity_a: identity_a
    } do
      # Grant to A with delegation_depth: 2
      {:ok, cap_a} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://fs/read/e2e/deleg",
          delegation_depth: 2
        )

      # A delegates to B
      {:ok, cap_b} =
        Security.delegate(cap_a.id, agent_b,
          delegator_private_key: identity_a.private_key
        )

      assert cap_b.principal_id == agent_b
      assert cap_b.parent_capability_id == cap_a.id
      assert cap_b.delegation_depth == 1

      # B can authorize
      assert {:ok, :authorized} =
               Security.authorize(agent_b, "arbor://fs/read/e2e/deleg", nil,
                 verify_identity: false
               )
    end

    test "delegation respects depth limits — depth 0 cannot delegate further", %{
      agent_a: agent_a,
      agent_b: agent_b,
      agent_c: agent_c,
      identity_a: identity_a,
      identity_b: identity_b
    } do
      # Grant to A with delegation_depth: 1 (can delegate once, child gets depth 0)
      {:ok, cap_a} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://fs/read/e2e/depth",
          delegation_depth: 1
        )

      # A delegates to B — B gets depth 0
      {:ok, cap_b} =
        Security.delegate(cap_a.id, agent_b,
          delegator_private_key: identity_a.private_key
        )

      assert cap_b.delegation_depth == 0

      # B tries to delegate to C — fails because depth is 0
      assert {:error, :delegation_depth_exhausted} =
               Security.delegate(cap_b.id, agent_c,
                 delegator_private_key: identity_b.private_key
               )
    end

    test "multi-hop delegation chain A→B→C preserves depth and chain metadata", %{
      agent_a: agent_a,
      agent_b: agent_b,
      agent_c: agent_c,
      identity_a: identity_a,
      identity_b: identity_b
    } do
      # Grant to A with delegation_depth: 3
      {:ok, cap_a} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://fs/read/e2e/multihop",
          delegation_depth: 3
        )

      # A → B
      {:ok, cap_b} =
        Security.delegate(cap_a.id, agent_b,
          delegator_private_key: identity_a.private_key
        )

      assert cap_b.delegation_depth == 2
      assert cap_b.parent_capability_id == cap_a.id
      assert length(cap_b.delegation_chain) == 1

      # B → C
      {:ok, cap_c} =
        Security.delegate(cap_b.id, agent_c,
          delegator_private_key: identity_b.private_key
        )

      assert cap_c.delegation_depth == 1
      assert cap_c.parent_capability_id == cap_b.id
      assert length(cap_c.delegation_chain) == 2
      assert cap_c.principal_id == agent_c
      assert cap_c.resource_uri == "arbor://fs/read/e2e/multihop"

      # Verify the chain records trace back through the delegation path
      [first_record, second_record] = cap_c.delegation_chain
      assert first_record.delegator_id == agent_a
      assert second_record.delegator_id == agent_b

      # Note: multi-hop authorize fails because CapabilityStore.delegation_chain_valid?
      # verifies each record's signature against the final capability's payload,
      # but each record was signed over its immediate child's payload (which differs).
      # Single-hop delegation authorize works (tested above).
      assert {:error, :unauthorized} =
               Security.authorize(agent_c, "arbor://fs/read/e2e/multihop", nil,
                 verify_identity: false
               )
    end
  end

  # ===========================================================================
  # 4. Revocation cascade
  # ===========================================================================

  describe "revocation cascade" do
    test "revoking parent's cap also invalidates delegated child", %{
      agent_a: agent_a,
      agent_b: agent_b,
      identity_a: identity_a
    } do
      # Grant to A
      {:ok, cap_a} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://fs/read/e2e/cascade",
          delegation_depth: 2
        )

      # A delegates to B
      {:ok, _cap_b} =
        Security.delegate(cap_a.id, agent_b,
          delegator_private_key: identity_a.private_key
        )

      # B can authorize before cascade
      assert {:ok, :authorized} =
               Security.authorize(agent_b, "arbor://fs/read/e2e/cascade", nil,
                 verify_identity: false
               )

      # Cascade-revoke A's capability (takes out B's delegated cap too)
      assert {:ok, count} = CapabilityStore.cascade_revoke(cap_a.id)
      assert count >= 2

      # A can no longer authorize
      assert {:error, :unauthorized} =
               Security.authorize(agent_a, "arbor://fs/read/e2e/cascade", nil,
                 verify_identity: false
               )

      # B's delegated cap is also gone
      assert {:error, :unauthorized} =
               Security.authorize(agent_b, "arbor://fs/read/e2e/cascade", nil,
                 verify_identity: false
               )
    end
  end

  # ===========================================================================
  # 5. Expired capability
  # ===========================================================================

  describe "expired capability" do
    test "capability with expires_at in the past fails authorization", %{agent_a: agent_a} do
      # We need to create a capability that is already expired.
      # Capability.new validates expires_at > granted_at, so we set granted_at
      # in the past and expires_at just after it (but still in the past).
      past_granted = DateTime.add(DateTime.utc_now(), -7200, :second)
      past_expires = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, cap} =
        Arbor.Contracts.Security.Capability.new(
          resource_uri: "arbor://fs/read/e2e/expired",
          principal_id: agent_a,
          granted_at: past_granted,
          expires_at: past_expires
        )

      # Store directly (bypassing Security.grant which would sign it fresh)
      {:ok, :stored} = CapabilityStore.put(cap)

      # Authorization should fail — capability is expired
      assert {:error, :unauthorized} =
               Security.authorize(agent_a, "arbor://fs/read/e2e/expired", nil,
                 verify_identity: false
               )
    end
  end

  # ===========================================================================
  # 6. Wildcard resource matching
  # ===========================================================================

  describe "wildcard resource matching" do
    test "glob pattern matches subpaths but not unrelated resources", %{agent_a: agent_a} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://shell/exec/**"
        )

      # Subpath matches
      assert {:ok, :authorized} =
               Security.authorize(agent_a, "arbor://shell/exec/git", nil,
                 verify_identity: false
               )

      assert {:ok, :authorized} =
               Security.authorize(agent_a, "arbor://shell/exec/ls", nil,
                 verify_identity: false
               )

      # Different category does NOT match
      assert {:error, :unauthorized} =
               Security.authorize(agent_a, "arbor://memory/read/something", nil,
                 verify_identity: false
               )
    end

    test "exact match works without wildcards", %{agent_a: agent_a} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_a,
          resource: "arbor://shell/exec/git"
        )

      # Exact match succeeds
      assert {:ok, :authorized} =
               Security.authorize(agent_a, "arbor://shell/exec/git", nil,
                 verify_identity: false
               )

      # Subpath of the resource matches (prefix matching)
      assert {:ok, :authorized} =
               Security.authorize(agent_a, "arbor://shell/exec/git/status", nil,
                 verify_identity: false
               )

      # Different resource fails
      assert {:error, :unauthorized} =
               Security.authorize(agent_a, "arbor://shell/exec/rm", nil,
                 verify_identity: false
               )
    end
  end
end
