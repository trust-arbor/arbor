defmodule Arbor.Security.IssuerRegistryTest do
  @moduledoc """
  Tests for `Arbor.Security.IssuerRegistry` — Phase 2 of the scheduler-privesc
  redesign.

  Covers:
    - register/3: success, identity-not-found, already-enrolled
    - lookup/1: success returns public key + envelope; revoked / not_found /
      identity_unavailable errors
    - verify_envelope/2: in-envelope passes, out-of-envelope rejected with
      :exceeds_envelope, revoked issuer rejected
    - revoke/2: status flip, reason captured, subsequent lookup fails closed
    - list/0: returns enrolled entries

  Tests use `async: false` because IssuerRegistry + Identity.Registry are
  process-globals and tests share state. Each test runs in setup-isolated
  identities to avoid cross-test pollution.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  setup do
    {:ok, identity} = Identity.generate()
    :ok = IdentityRegistry.register(identity)

    envelope = build_envelope()

    on_exit(fn ->
      # Best-effort cleanup: revoke and forget.
      IssuerRegistry.revoke(identity.agent_id, "test cleanup")
    end)

    {:ok, identity: identity, envelope: envelope}
  end

  describe "register/3" do
    test "enrolls an existing identity as an issuer", %{
      identity: identity,
      envelope: envelope
    } do
      assert :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "test")
    end

    test "rejects an unknown identity", %{envelope: envelope} do
      assert {:error, :identity_not_found} =
               IssuerRegistry.register(
                 "agent_0000000000000000000000000000000000000000000000000000000000000000",
                 envelope
               )
    end

    test "rejects duplicate enrollment", %{identity: identity, envelope: envelope} do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      assert {:error, :already_enrolled} =
               IssuerRegistry.register(identity.agent_id, envelope)
    end
  end

  describe "lookup/1" do
    test "returns public_key + envelope for active issuer", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      assert {:ok, %{public_key: pk, max_envelope_cap: env}} =
               IssuerRegistry.lookup(identity.agent_id)

      assert pk == identity.public_key
      assert env.resource_uri == envelope.resource_uri
    end

    test "returns :not_found for never-enrolled issuer" do
      assert {:error, :not_found} =
               IssuerRegistry.lookup(
                 "agent_1111111111111111111111111111111111111111111111111111111111111111"
               )
    end

    test "returns :revoked after revoke/2", %{identity: identity, envelope: envelope} do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)
      :ok = IssuerRegistry.revoke(identity.agent_id, "test revocation")

      assert {:error, :revoked} = IssuerRegistry.lookup(identity.agent_id)
    end
  end

  describe "verify_envelope/2" do
    test "passes for a capability inside the issuer's envelope", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      {:ok, child_cap} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/upstream-deps-summary/2026-06-05.md",
          principal_id: "agent_pipeline_runner"
        )

      assert :ok = IssuerRegistry.verify_envelope(identity.agent_id, child_cap)
    end

    test "rejects with :exceeds_envelope for a capability outside the envelope", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      {:ok, escape_cap} =
        Capability.new(
          # Outside envelope which is arbor://fs/{read,write}/reports/**
          resource_uri: "arbor://shell/exec/rm",
          principal_id: "agent_pipeline_runner"
        )

      assert {:error, :exceeds_envelope} =
               IssuerRegistry.verify_envelope(identity.agent_id, escape_cap)
    end

    test "rejects unknown issuer with :not_found" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/anywhere",
          principal_id: "agent_x"
        )

      assert {:error, :not_found} =
               IssuerRegistry.verify_envelope(
                 "agent_2222222222222222222222222222222222222222222222222222222222222222",
                 cap
               )
    end

    test "rejects revoked issuer with :revoked", %{identity: identity, envelope: envelope} do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)
      :ok = IssuerRegistry.revoke(identity.agent_id, "test")

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/x.md",
          principal_id: "agent_pipeline_runner"
        )

      assert {:error, :revoked} =
               IssuerRegistry.verify_envelope(identity.agent_id, cap)
    end

    test "regression: even an envelope-valid cap fails closed after revoke", %{
      identity: identity,
      envelope: envelope
    } do
      # Regression: the bug shape this gate exists to prevent is "issuer was
      # revoked but their previously-signed .caps.json files still load." If
      # the verification path short-circuits on envelope check without first
      # checking status, a compromised-and-revoked issuer's outputs can keep
      # authorizing. Make sure revoke fails closed independent of whether
      # the cap would otherwise be in-envelope.
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      {:ok, in_envelope_cap} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/upstream-deps-summary/2026-06-05.md",
          principal_id: "agent_pipeline_runner"
        )

      assert :ok = IssuerRegistry.verify_envelope(identity.agent_id, in_envelope_cap)

      :ok = IssuerRegistry.revoke(identity.agent_id, "compromise")

      assert {:error, :revoked} =
               IssuerRegistry.verify_envelope(identity.agent_id, in_envelope_cap)
    end
  end

  describe "revoke/2" do
    test "captures reason in status_changed_at and status_reason", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)
      :ok = IssuerRegistry.revoke(identity.agent_id, "stolen key")

      entries = IssuerRegistry.list()
      entry = Enum.find(entries, &(&1.issuer_id == identity.agent_id))

      assert entry.status == :revoked
      assert entry.status_reason == "stolen key"
      assert %DateTime{} = entry.status_changed_at
    end

    test "returns :not_found for unknown issuer" do
      assert {:error, :not_found} =
               IssuerRegistry.revoke(
                 "agent_3333333333333333333333333333333333333333333333333333333333333333"
               )
    end
  end

  describe "list/0" do
    test "returns enrolled entries with issuer_id, envelope, status", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "primary author")

      entries = IssuerRegistry.list()
      entry = Enum.find(entries, &(&1.issuer_id == identity.agent_id))

      refute is_nil(entry)
      assert entry.status == :active
      assert entry.max_envelope_cap.resource_uri == envelope.resource_uri
      assert entry.status_reason == "primary author"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_envelope do
    # Mirrors the envelope shape Hysun will enroll for his own identity to
    # sign the scheduler-internal pipeline caps files.
    {:ok, envelope} =
      Capability.new(
        resource_uri: "arbor://fs/write/reports/**",
        principal_id: "agent_envelope_holder"
      )

    envelope
  end
end
