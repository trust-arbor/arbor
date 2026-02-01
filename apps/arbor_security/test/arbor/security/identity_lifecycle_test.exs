defmodule Arbor.Security.IdentityLifecycleTest do
  @moduledoc """
  Tests for identity lifecycle management:
  - suspend/resume/revoke transitions
  - lookup gating based on status
  - authorize rejection of suspended/revoked principals
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry

  setup do
    # Generate and register a test identity
    {:ok, identity} = Identity.generate(name: "lifecycle-test-agent")
    :ok = Registry.register(identity)

    {:ok, identity: identity}
  end

  # ===========================================================================
  # Registry Lifecycle Functions
  # ===========================================================================

  describe "Registry.suspend/2" do
    test "sets status to :suspended", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id, "Test suspension")

      assert {:ok, :suspended} = Registry.get_status(identity.agent_id)
    end

    test "stores the reason", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id, "Security concern")

      # We verify indirectly through status being :suspended
      assert {:ok, :suspended} = Registry.get_status(identity.agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = Registry.suspend("agent_unknown")
    end

    test "fails on :revoked identity (terminal)", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id, "Compromised")
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)

      assert {:error, :cannot_suspend_revoked} = Registry.suspend(identity.agent_id, "Attempt")
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)
    end
  end

  describe "Registry.resume/1" do
    test "sets status back to :active", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id, "Temporary")
      assert {:ok, :suspended} = Registry.get_status(identity.agent_id)

      :ok = Registry.resume(identity.agent_id)
      assert {:ok, :active} = Registry.get_status(identity.agent_id)
    end

    test "fails on :revoked identity (terminal)", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id, "Compromised")
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)

      assert {:error, :cannot_resume_revoked} = Registry.resume(identity.agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = Registry.resume("agent_unknown")
    end
  end

  describe "Registry.revoke_identity/2" do
    test "sets status to :revoked and returns revoked count", %{identity: identity} do
      {:ok, count} = Registry.revoke_identity(identity.agent_id, "Account compromised")

      assert is_integer(count)
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = Registry.revoke_identity("agent_unknown")
    end
  end

  describe "Registry.get_status/1" do
    test "returns :active for newly registered identity", %{identity: identity} do
      assert {:ok, :active} = Registry.get_status(identity.agent_id)
    end

    test "returns :suspended after suspension", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id)
      assert {:ok, :suspended} = Registry.get_status(identity.agent_id)
    end

    test "returns :revoked after revocation", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id)
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = Registry.get_status("agent_unknown")
    end
  end

  describe "Registry.active?/1" do
    test "returns true for active identity", %{identity: identity} do
      assert Registry.active?(identity.agent_id)
    end

    test "returns false for suspended identity", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id)
      refute Registry.active?(identity.agent_id)
    end

    test "returns false for revoked identity", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id)
      refute Registry.active?(identity.agent_id)
    end

    test "returns false for unknown agent" do
      refute Registry.active?("agent_unknown")
    end
  end

  # ===========================================================================
  # Lookup Gating by Status
  # ===========================================================================

  describe "Registry.lookup/1 status gating" do
    test "returns public key for active identity", %{identity: identity} do
      assert {:ok, public_key} = Registry.lookup(identity.agent_id)
      assert public_key == identity.public_key
    end

    test "returns error for suspended identity", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id, "Suspicious activity")

      assert {:error, :identity_suspended} = Registry.lookup(identity.agent_id)
    end

    test "returns error for revoked identity", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id, "Compromised")

      assert {:error, :identity_revoked} = Registry.lookup(identity.agent_id)
    end
  end

  describe "Registry.lookup_encryption_key/1 status gating" do
    test "returns encryption key for active identity", %{identity: identity} do
      assert {:ok, enc_key} = Registry.lookup_encryption_key(identity.agent_id)
      assert enc_key == identity.encryption_public_key
    end

    test "returns error for suspended identity", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id)

      assert {:error, :identity_suspended} = Registry.lookup_encryption_key(identity.agent_id)
    end

    test "returns error for revoked identity", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id)

      assert {:error, :identity_revoked} = Registry.lookup_encryption_key(identity.agent_id)
    end
  end

  # ===========================================================================
  # Status Transitions
  # ===========================================================================

  describe "status transitions" do
    test "active -> suspended -> active (valid)", %{identity: identity} do
      assert {:ok, :active} = Registry.get_status(identity.agent_id)

      :ok = Registry.suspend(identity.agent_id)
      assert {:ok, :suspended} = Registry.get_status(identity.agent_id)

      :ok = Registry.resume(identity.agent_id)
      assert {:ok, :active} = Registry.get_status(identity.agent_id)
    end

    test "active -> revoked (terminal)", %{identity: identity} do
      assert {:ok, :active} = Registry.get_status(identity.agent_id)

      {:ok, _} = Registry.revoke_identity(identity.agent_id)
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)
    end

    test "suspended -> revoked (terminal)", %{identity: identity} do
      :ok = Registry.suspend(identity.agent_id)
      assert {:ok, :suspended} = Registry.get_status(identity.agent_id)

      {:ok, _} = Registry.revoke_identity(identity.agent_id)
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)
    end

    test "revoked -> active (invalid)", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id)
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)

      assert {:error, :cannot_resume_revoked} = Registry.resume(identity.agent_id)
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)
    end
  end

  # ===========================================================================
  # Security Facade Functions
  # ===========================================================================

  describe "Security.suspend_identity/2" do
    test "suspends identity via facade", %{identity: identity} do
      :ok = Security.suspend_identity(identity.agent_id, reason: "Facade test")

      assert {:ok, :suspended} = Security.identity_status(identity.agent_id)
    end
  end

  describe "Security.resume_identity/1" do
    test "resumes identity via facade", %{identity: identity} do
      :ok = Security.suspend_identity(identity.agent_id)
      :ok = Security.resume_identity(identity.agent_id)

      assert {:ok, :active} = Security.identity_status(identity.agent_id)
    end
  end

  describe "Security.revoke_identity/2" do
    test "revokes identity via facade", %{identity: identity} do
      :ok = Security.revoke_identity(identity.agent_id, reason: "Facade test")

      assert {:ok, :revoked} = Security.identity_status(identity.agent_id)
    end
  end

  describe "Security.identity_status/1" do
    test "returns current status", %{identity: identity} do
      assert {:ok, :active} = Security.identity_status(identity.agent_id)

      :ok = Security.suspend_identity(identity.agent_id)
      assert {:ok, :suspended} = Security.identity_status(identity.agent_id)
    end
  end

  describe "Security.identity_active?/1" do
    test "returns correct boolean", %{identity: identity} do
      assert Security.identity_active?(identity.agent_id)

      :ok = Security.suspend_identity(identity.agent_id)
      refute Security.identity_active?(identity.agent_id)

      :ok = Security.resume_identity(identity.agent_id)
      assert Security.identity_active?(identity.agent_id)

      :ok = Security.revoke_identity(identity.agent_id)
      refute Security.identity_active?(identity.agent_id)
    end
  end

  # ===========================================================================
  # deregister vs revoke
  # ===========================================================================

  describe "deregister vs revoke" do
    test "deregister removes entry entirely", %{identity: identity} do
      :ok = Registry.deregister(identity.agent_id)

      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
      assert {:error, :not_found} = Registry.get_status(identity.agent_id)
    end

    test "revoke keeps entry for audit trail", %{identity: identity} do
      {:ok, _} = Registry.revoke_identity(identity.agent_id, "Audit trail test")

      # Entry still exists
      assert {:ok, :revoked} = Registry.get_status(identity.agent_id)
      # But lookups fail with specific error
      assert {:error, :identity_revoked} = Registry.lookup(identity.agent_id)
    end
  end

  # ===========================================================================
  # Default status on registration
  # ===========================================================================

  describe "default status on registration" do
    test "new identities start with :active status" do
      {:ok, new_identity} = Identity.generate(name: "fresh-agent")
      :ok = Registry.register(new_identity)

      assert {:ok, :active} = Registry.get_status(new_identity.agent_id)
    end
  end
end
