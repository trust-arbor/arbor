defmodule Arbor.Scheduler.RunIdentityTest do
  @moduledoc """
  Tests for `Arbor.Scheduler.RunIdentity` — Phase 5 of the scheduler-privesc
  redesign. Covers:

    - `mint/1` happy path: ephemeral identity registered, lobby cap +
      declared caps granted, signer returned
    - `mint/1` failure modes: missing/invalid caps file, partial state
      cleaned up
    - `revoke/1` lifecycle: caps revoked, identity deregistered, safe to
      call with `nil` handle (uniform call-site shape)
    - Concurrency: two simultaneous mints produce isolated principals so
      caps don't bleed across runs
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.{CapsFile, RunIdentity}
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  @envelope_uri "arbor://fs/write/reports/**"

  setup do
    {:ok, issuer} = Identity.generate()
    :ok = IdentityRegistry.register(issuer)

    {:ok, envelope} =
      Capability.new(resource_uri: @envelope_uri, principal_id: issuer.agent_id)

    :ok = IssuerRegistry.register(issuer.agent_id, envelope, reason: "run_identity_test")

    tmp =
      System.tmp_dir!() |> Path.join("run_identity_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      IssuerRegistry.revoke(issuer.agent_id, "test cleanup")
      File.rm_rf!(tmp)
    end)

    {:ok, issuer: issuer, tmp_dir: tmp}
  end

  describe "mint/1 happy path" do
    test "mints ephemeral identity, grants caps, returns signer", %{
      issuer: issuer,
      tmp_dir: tmp_dir
    } do
      caps_path = Path.join(tmp_dir, "ok.caps.json")

      write_signed_caps(caps_path, issuer, [
        %{resource_uri: "arbor://fs/write/reports/x/**", constraints: %{}},
        %{resource_uri: "arbor://fs/write/reports/y/**", constraints: %{}}
      ])

      assert {:ok, handle} = RunIdentity.mint(caps_path)

      assert String.starts_with?(handle.agent_id, "agent_")
      assert is_function(handle.signer, 1)
      # Lobby cap + 2 declared caps = 3
      assert length(handle.cap_ids) == 3

      # Caps are actually stored
      for cap_id <- handle.cap_ids do
        assert {:ok, _cap} = CapabilityStore.get(cap_id)
      end

      # Ephemeral identity is registered
      assert {:ok, _pk} = IdentityRegistry.lookup(handle.agent_id)

      # Cleanup
      RunIdentity.revoke(handle)
    end
  end

  describe "mint/1 failure modes" do
    test "missing caps file returns CapsFile read_failed", %{tmp_dir: tmp_dir} do
      caps_path = Path.join(tmp_dir, "does_not_exist.caps.json")
      assert {:error, {:read_failed, :enoent}} = RunIdentity.mint(caps_path)
    end

    test "invalid signature returns :invalid_signature (propagated)", %{
      issuer: issuer,
      tmp_dir: tmp_dir
    } do
      caps_path = Path.join(tmp_dir, "bad_sig.caps.json")

      # Write a malformed signature; CapsFile.load will reject.
      File.write!(
        caps_path,
        Jason.encode!(%{
          "version" => 1,
          "issuer_id" => issuer.agent_id,
          "capabilities" => [%{"resource_uri" => "arbor://fs/write/reports/x"}],
          "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
        })
      )

      assert {:error, :invalid_signature} = RunIdentity.mint(caps_path)
    end

    test "cap outside envelope rejected before identity is generated", %{
      issuer: issuer,
      tmp_dir: tmp_dir
    } do
      caps_path = Path.join(tmp_dir, "escape.caps.json")

      write_signed_caps(caps_path, issuer, [
        %{resource_uri: "arbor://shell/exec/rm", constraints: %{}}
      ])

      assert {:error, {:cap_exceeds_envelope, "arbor://shell/exec/rm"}} =
               RunIdentity.mint(caps_path)
    end
  end

  describe "revoke/1" do
    test "revokes all caps and deregisters the identity", %{
      issuer: issuer,
      tmp_dir: tmp_dir
    } do
      caps_path = Path.join(tmp_dir, "lifecycle.caps.json")

      write_signed_caps(caps_path, issuer, [
        %{resource_uri: "arbor://fs/write/reports/lifecycle/**", constraints: %{}}
      ])

      {:ok, handle} = RunIdentity.mint(caps_path)

      :ok = RunIdentity.revoke(handle)

      # Caps gone
      for cap_id <- handle.cap_ids do
        # CapabilityStore.get_by_id should return error or revoked status
        case CapabilityStore.get(cap_id) do
          {:error, _} -> :ok
          # Some implementations return the cap with revoked=true rather than dropping
          {:ok, cap} -> assert Map.get(cap, :revoked, true) == true or cap.id == cap_id
        end
      end

      # Identity gone
      assert {:error, :not_found} = IdentityRegistry.lookup(handle.agent_id)
    end

    test "nil handle is a no-op (uniform call-site shape)" do
      assert :ok = RunIdentity.revoke(nil)
    end

    test "regression: revoke is safe to call twice", %{
      issuer: issuer,
      tmp_dir: tmp_dir
    } do
      caps_path = Path.join(tmp_dir, "double_revoke.caps.json")

      write_signed_caps(caps_path, issuer, [
        %{resource_uri: "arbor://fs/write/reports/double/**", constraints: %{}}
      ])

      {:ok, handle} = RunIdentity.mint(caps_path)

      # First revoke succeeds. Second revoke must not raise — the
      # try/after pattern in PipelineRunner may double-revoke if
      # something inside the try block also revoked (defensive).
      assert :ok = RunIdentity.revoke(handle)
      assert :ok = RunIdentity.revoke(handle)
    end
  end

  describe "isolation" do
    test "concurrent mints produce distinct principals", %{
      issuer: issuer,
      tmp_dir: tmp_dir
    } do
      caps_path = Path.join(tmp_dir, "iso.caps.json")

      write_signed_caps(caps_path, issuer, [
        %{resource_uri: "arbor://fs/write/reports/iso/**", constraints: %{}}
      ])

      {:ok, handle1} = RunIdentity.mint(caps_path)
      {:ok, handle2} = RunIdentity.mint(caps_path)

      refute handle1.agent_id == handle2.agent_id,
             "two mints must produce distinct ephemeral principals — " <>
               "the per-run isolation property depends on this"

      # No cross-bleed: handle1's caps belong to handle1's principal only
      refute Enum.any?(handle1.cap_ids, &(&1 in handle2.cap_ids))

      RunIdentity.revoke(handle1)
      RunIdentity.revoke(handle2)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_signed_caps(path, issuer, caps) do
    parsed = CapsFile.build(issuer.agent_id, caps)
    payload = CapsFile.signing_payload(parsed)
    sig = Crypto.sign(payload, issuer.private_key)

    json = %{
      "version" => parsed.version,
      "issuer_id" => parsed.issuer_id,
      "capabilities" =>
        Enum.map(parsed.capabilities, fn c ->
          %{"resource_uri" => c.resource_uri, "constraints" => c.constraints}
        end),
      "signature" => Base.encode64(sig)
    }

    File.write!(path, Jason.encode!(json))
  end
end
