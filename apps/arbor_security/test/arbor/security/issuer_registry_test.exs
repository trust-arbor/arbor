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
    test "returns public_key + envelopes for active issuer", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      assert {:ok, %{public_key: pk, max_envelope_caps: [env]}} =
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
    test "returns enrolled entries with issuer_id, envelopes, status", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "primary author")

      entries = IssuerRegistry.list()
      entry = Enum.find(entries, &(&1.issuer_id == identity.agent_id))

      refute is_nil(entry)
      assert entry.status == :active
      assert [env] = entry.max_envelope_caps
      assert env.resource_uri == envelope.resource_uri
      assert entry.status_reason == "primary author"
    end
  end

  describe "multi-envelope enrollment" do
    # The multi-envelope refactor: an issuer can be authorized for several
    # non-overlapping resource patterns (e.g. fs/read of one subtree AND
    # fs/write of another) without using a coarser pattern that would
    # dilute the bound. verify_envelope/2 passes a cap if it fits ANY of
    # the issuer's envelopes.

    test "accepts a list of envelope caps", %{identity: identity} do
      {:ok, read_env} =
        Capability.new(
          resource_uri: "arbor://fs/read/reports/**",
          principal_id: identity.agent_id
        )

      {:ok, write_env} =
        Capability.new(
          resource_uri: "arbor://fs/write/summaries/**",
          principal_id: identity.agent_id
        )

      assert :ok = IssuerRegistry.register(identity.agent_id, [read_env, write_env])

      assert {:ok, %{max_envelope_caps: [_, _]}} = IssuerRegistry.lookup(identity.agent_id)
    end

    test "rejects empty envelope list with :empty_envelopes", %{identity: identity} do
      assert {:error, :empty_envelopes} = IssuerRegistry.register(identity.agent_id, [])
    end

    test "verify_envelope/2 passes when cap matches at least one envelope", %{
      identity: identity
    } do
      {:ok, read_env} =
        Capability.new(
          resource_uri: "arbor://fs/read/reports/**",
          principal_id: identity.agent_id
        )

      {:ok, write_env} =
        Capability.new(
          resource_uri: "arbor://fs/write/summaries/**",
          principal_id: identity.agent_id
        )

      :ok = IssuerRegistry.register(identity.agent_id, [read_env, write_env])

      {:ok, fits_read} =
        Capability.new(
          resource_uri: "arbor://fs/read/reports/today.md",
          principal_id: "agent_runner"
        )

      {:ok, fits_write} =
        Capability.new(
          resource_uri: "arbor://fs/write/summaries/today.md",
          principal_id: "agent_runner"
        )

      assert :ok = IssuerRegistry.verify_envelope(identity.agent_id, fits_read)
      assert :ok = IssuerRegistry.verify_envelope(identity.agent_id, fits_write)
    end

    test "verify_envelope/2 rejects with :exceeds_envelope when cap matches NONE", %{
      identity: identity
    } do
      {:ok, read_env} =
        Capability.new(
          resource_uri: "arbor://fs/read/reports/**",
          principal_id: identity.agent_id
        )

      {:ok, write_env} =
        Capability.new(
          resource_uri: "arbor://fs/write/summaries/**",
          principal_id: identity.agent_id
        )

      :ok = IssuerRegistry.register(identity.agent_id, [read_env, write_env])

      {:ok, escape_cap} =
        Capability.new(
          resource_uri: "arbor://shell/exec/rm",
          principal_id: "agent_runner"
        )

      assert {:error, :exceeds_envelope} =
               IssuerRegistry.verify_envelope(identity.agent_id, escape_cap)
    end
  end

  describe "update_envelopes/3" do
    # The update_envelopes path exists so operators can expand or narrow
    # an issuer's authority WITHOUT revoke + re-register. Revoke +
    # re-register would force re-signing every existing .caps.json even
    # if those files would still fit within the new envelopes — that's
    # avoidable churn.

    test "replaces the full envelope list for an active issuer", %{identity: identity} do
      {:ok, original} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/**",
          principal_id: identity.agent_id
        )

      :ok = IssuerRegistry.register(identity.agent_id, [original])

      # New, broader set covering both read and write across a different subtree
      {:ok, new_read} =
        Capability.new(
          resource_uri: "arbor://fs/read/code/**",
          principal_id: identity.agent_id
        )

      {:ok, new_write} =
        Capability.new(
          resource_uri: "arbor://fs/write/artifacts/**",
          principal_id: identity.agent_id
        )

      assert :ok = IssuerRegistry.update_envelopes(identity.agent_id, [new_read, new_write])

      # Lookup returns the new list, not the original
      assert {:ok, %{max_envelope_caps: envelopes}} = IssuerRegistry.lookup(identity.agent_id)
      assert length(envelopes) == 2
      uris = Enum.map(envelopes, & &1.resource_uri)
      assert "arbor://fs/read/code/**" in uris
      assert "arbor://fs/write/artifacts/**" in uris
      refute "arbor://fs/write/reports/**" in uris
    end

    test "regression: a cap that fit the OLD envelope but not the NEW one is rejected", %{
      identity: identity
    } do
      # Original: write access to reports/
      {:ok, original} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/**",
          principal_id: identity.agent_id
        )

      :ok = IssuerRegistry.register(identity.agent_id, [original])

      {:ok, originally_fit_cap} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/today.md",
          principal_id: "agent_runner"
        )

      # Confirm baseline: under the original envelope, this passes
      assert :ok = IssuerRegistry.verify_envelope(identity.agent_id, originally_fit_cap)

      # Narrow to a non-overlapping envelope
      {:ok, narrowed} =
        Capability.new(
          resource_uri: "arbor://fs/read/elsewhere/**",
          principal_id: identity.agent_id
        )

      :ok = IssuerRegistry.update_envelopes(identity.agent_id, [narrowed])

      # The cap that fit the original is now outside the envelope.
      # If verify_envelope short-circuited on a stale cache or used the
      # OLD envelope list, this assertion would fail — that's exactly
      # the property the regression test locks in.
      assert {:error, :exceeds_envelope} =
               IssuerRegistry.verify_envelope(identity.agent_id, originally_fit_cap)
    end

    test "regression: a cap that fits the NEW envelope passes after update", %{
      identity: identity
    } do
      # Original: only writes to reports/
      {:ok, original} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/**",
          principal_id: identity.agent_id
        )

      :ok = IssuerRegistry.register(identity.agent_id, [original])

      {:ok, code_cap} =
        Capability.new(
          resource_uri: "arbor://fs/write/code/file.ex",
          principal_id: "agent_runner"
        )

      # Baseline: not in original envelope
      assert {:error, :exceeds_envelope} =
               IssuerRegistry.verify_envelope(identity.agent_id, code_cap)

      # Expand to add code/ writes
      {:ok, expanded} =
        Capability.new(
          resource_uri: "arbor://fs/write/code/**",
          principal_id: identity.agent_id
        )

      :ok = IssuerRegistry.update_envelopes(identity.agent_id, [original, expanded])

      # Now the cap passes
      assert :ok = IssuerRegistry.verify_envelope(identity.agent_id, code_cap)
    end

    test "rejects unknown issuer with :not_found" do
      {:ok, envelope} =
        Capability.new(
          resource_uri: "arbor://fs/write/x",
          principal_id: "agent_someone"
        )

      assert {:error, :not_found} =
               IssuerRegistry.update_envelopes(
                 "agent_5555555555555555555555555555555555555555555555555555555555555555",
                 [envelope]
               )
    end

    test "rejects revoked issuer with :revoked", %{identity: identity, envelope: envelope} do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)
      :ok = IssuerRegistry.revoke(identity.agent_id, "test revocation")

      {:ok, new_env} =
        Capability.new(
          resource_uri: "arbor://fs/write/anything",
          principal_id: identity.agent_id
        )

      assert {:error, :revoked} =
               IssuerRegistry.update_envelopes(identity.agent_id, [new_env])
    end

    test "rejects empty list with :empty_envelopes", %{identity: identity, envelope: envelope} do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      assert {:error, :empty_envelopes} =
               IssuerRegistry.update_envelopes(identity.agent_id, [])
    end

    test "rejects non-Capability entries with :invalid_envelope", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope)

      assert {:error, :invalid_envelope} =
               IssuerRegistry.update_envelopes(identity.agent_id, [:not_a_cap])
    end

    test "captures reason in status_reason and bumps status_changed_at", %{
      identity: identity,
      envelope: envelope
    } do
      :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "original enrollment")

      original_entry = Enum.find(IssuerRegistry.list(), &(&1.issuer_id == identity.agent_id))
      assert original_entry.status_reason == "original enrollment"
      assert original_entry.status_changed_at == nil

      {:ok, new_env} =
        Capability.new(
          resource_uri: "arbor://fs/read/different",
          principal_id: identity.agent_id
        )

      :ok =
        IssuerRegistry.update_envelopes(
          identity.agent_id,
          [new_env],
          reason: "expanding to cover code reviews"
        )

      updated_entry = Enum.find(IssuerRegistry.list(), &(&1.issuer_id == identity.agent_id))
      assert updated_entry.status_reason == "expanding to cover code reviews"
      assert %DateTime{} = updated_entry.status_changed_at
      # Status itself stays :active — this isn't a revoke.
      assert updated_entry.status == :active
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
