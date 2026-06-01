defmodule Arbor.Security.SystemAuthorityTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SystemAuthority

  describe "lifecycle" do
    test "system authority starts and has an agent_id" do
      agent_id = SystemAuthority.agent_id()
      assert is_binary(agent_id)
      assert String.starts_with?(agent_id, "agent_")
    end

    test "public_key returns a 32-byte binary" do
      pk = SystemAuthority.public_key()
      assert is_binary(pk)
      assert byte_size(pk) == 32
    end

    test "system authority is registered in Identity.Registry" do
      agent_id = SystemAuthority.agent_id()
      assert {:ok, pk} = Registry.lookup(agent_id)
      assert pk == SystemAuthority.public_key()
    end
  end

  describe "sign_capability/1" do
    test "adds issuer_id and issuer_signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)

      assert signed.issuer_id == SystemAuthority.agent_id()
      assert is_binary(signed.issuer_signature)
      assert byte_size(signed.issuer_signature) > 0
    end

    test "preserves all original capability fields" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          constraints: %{max_size: 100},
          delegation_depth: 5
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)

      assert signed.id == cap.id
      assert signed.resource_uri == cap.resource_uri
      assert signed.principal_id == cap.principal_id
      assert signed.constraints == cap.constraints
      assert signed.delegation_depth == cap.delegation_depth
    end
  end

  describe "verify_capability_signature/1" do
    test "accepts valid signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)
      assert :ok = SystemAuthority.verify_capability_signature(signed)
    end

    test "rejects tampered capability" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)

      # Tamper with the resource URI
      tampered = %{signed | resource_uri: "arbor://fs/write/evil"}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(tampered)
    end

    test "rejects capability with random signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          issuer_id: SystemAuthority.agent_id()
        )

      cap = %{cap | issuer_signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(cap)
    end

    test "verifies capability signed by a different registered entity" do
      # Generate a separate identity and register it
      alias Arbor.Contracts.Security.Identity
      alias Arbor.Security.Capability.Signer

      {:ok, other_identity} = Identity.generate()
      :ok = Registry.register(Identity.public_only(other_identity))

      # Create and sign a capability with the other identity's key
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/other_signed",
          principal_id: "agent_test001"
        )

      signed =
        cap
        |> Map.put(:issuer_id, other_identity.agent_id)
        |> Signer.sign(other_identity.private_key)

      # SystemAuthority should verify via Registry lookup
      assert :ok = SystemAuthority.verify_capability_signature(signed)
    end

    test "rejects capability with unknown issuer_id" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/unknown_issuer",
          principal_id: "agent_test001"
        )

      # Set issuer to an unregistered agent
      cap = %{
        cap
        | issuer_id: "agent_not_registered",
          issuer_signature: :crypto.strong_rand_bytes(64)
      }

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(cap)
    end
  end

  # The test environment runs SystemAuthority in :ephemeral mode, so the live
  # GenServer never persists anything. These tests drive persist_keypair/1
  # and load_persisted_keypair/0 directly (both exposed as @doc false) on a
  # generated identity so the persisted-record layout is what's under test,
  # independent of which mode the live authority is in. async: false to avoid
  # tests stepping on each other's BufferedStore records.
  describe "persistence (P0-5 regression)" do
    @key_store_name :arbor_security_signing_keys
    @authority_metadata_key "system_authority_metadata_v2"
    @authority_signing_id "system_authority"
    @legacy_plaintext_key "system_authority_keypair"

    setup do
      # Snapshot anything currently at the keys we touch so we don't pollute
      # the SigningKeyStore master record across tests.
      meta_before =
        case Arbor.Persistence.BufferedStore.get(@authority_metadata_key,
               name: @key_store_name
             ) do
          {:ok, record} -> record
          _ -> nil
        end

      on_exit(fn ->
        if meta_before do
          Arbor.Persistence.BufferedStore.put(@authority_metadata_key, meta_before,
            name: @key_store_name
          )
        else
          Arbor.Persistence.BufferedStore.delete(@authority_metadata_key,
            name: @key_store_name
          )
        end

        # Also clean the SigningKeyStore entry we wrote.
        Arbor.Security.SigningKeyStore.delete(@authority_signing_id)
      end)

      {:ok, identity} = Arbor.Contracts.Security.Identity.generate(name: "p0_5_test_authority")
      {:ok, identity: identity}
    end

    test "security regression (P0-5): persist_keypair writes no plaintext private key",
         %{identity: identity} do
      # P0-5: the pre-v2 layout wrote the Ed25519 private key as base64 plaintext
      # in a BufferedStore record. The fix must keep secrets out of the plain
      # BufferedStore — only public material lives there. After persist_keypair,
      # the BufferedStore record at the metadata key must not contain any field
      # whose name suggests a private key.
      :ok = SystemAuthority.persist_keypair(identity)

      {:ok, %Arbor.Contracts.Persistence.Record{data: data}} =
        Arbor.Persistence.BufferedStore.get(@authority_metadata_key, name: @key_store_name)

      refute Map.has_key?(data, "private_key"),
             "Metadata record holds a plaintext \"private_key\" field — P0-5 regression. " <>
               "Got keys: #{inspect(Map.keys(data))}"

      refute Map.has_key?(data, "encryption_private_key"),
             "Metadata record holds a plaintext \"encryption_private_key\" field — P0-5 regression. " <>
               "Got keys: #{inspect(Map.keys(data))}"

      # Belt-and-braces: no value in the plaintext metadata decodes to the live
      # private key. Catches future fields with innocuous names.
      live_private = identity.private_key

      for {field, value} <- data, is_binary(value) do
        case Base.decode64(value) do
          {:ok, decoded} ->
            refute decoded == live_private,
                   "Metadata field #{inspect(field)} decodes to the private key — P0-5 regression"

          _ ->
            :ok
        end
      end
    end

    test "SigningKeyStore holds the encrypted private keypair after persist",
         %{identity: identity} do
      :ok = SystemAuthority.persist_keypair(identity)

      assert {:ok, %{signing: signing_key}} =
               Arbor.Security.SigningKeyStore.get_keypair(@authority_signing_id)

      assert signing_key == identity.private_key,
             "SigningKeyStore must round-trip the signing key"
    end

    test "security regression (P0-5): cleanup_legacy_plaintext_record removes pre-v2 records" do
      # Simulate a pre-v2 plaintext record being on disk (e.g. after upgrade).
      legacy_data = %{
        "agent_id" => "agent_legacy",
        "public_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
        "private_key" => Base.encode64(:crypto.strong_rand_bytes(64)),
        "name" => "legacy",
        "created_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      legacy_record =
        Arbor.Contracts.Persistence.Record.new(@legacy_plaintext_key, legacy_data)

      Arbor.Persistence.BufferedStore.put(@legacy_plaintext_key, legacy_record,
        name: @key_store_name
      )

      # Sanity: the legacy record is there before cleanup.
      assert {:ok, _} =
               Arbor.Persistence.BufferedStore.get(@legacy_plaintext_key,
                 name: @key_store_name
               )

      :ok = SystemAuthority.cleanup_legacy_plaintext_record()

      assert {:error, :not_found} =
               Arbor.Persistence.BufferedStore.get(@legacy_plaintext_key,
                 name: @key_store_name
               ),
             "Legacy plaintext authority record was not deleted — P0-5 regression"
    end

    test "security regression (P0-5): load failure is fatal, never silently regenerates",
         %{identity: identity} do
      # P0-5: previously, init_persistent caught {:error, _} from
      # load_persisted_keypair, logged a warning, and generated a fresh
      # keypair. That silently rotated the trust root, invalidating every
      # capability and endorsement ever signed under the old key. The fix
      # propagates the error so init returns {:stop, _}.
      #
      # Establish a baseline persisted authority, then corrupt the metadata
      # and assert load returns {:error, _} — never :not_found, never {:ok, _}.
      :ok = SystemAuthority.persist_keypair(identity)

      corrupted_data = %{
        "v" => 2,
        "agent_id" => "agent_corrupt",
        "public_key" => "not_valid_base64_!@#$",
        "encryption_public_key" => "",
        "name" => "corrupt",
        "created_at" => "garbage"
      }

      corrupted_record =
        Arbor.Contracts.Persistence.Record.new(@authority_metadata_key, corrupted_data)

      :ok =
        Arbor.Persistence.BufferedStore.put(@authority_metadata_key, corrupted_record,
          name: @key_store_name
        )

      result = SystemAuthority.load_persisted_keypair()

      case result do
        {:error, _reason} ->
          :ok

        other ->
          flunk(
            "Expected {:error, _} from corrupted persistence, got #{inspect(other)} — " <>
              "P0-5 regression: load failure must be fatal, not silently regenerate"
          )
      end
    end

    test "load_persisted_keypair returns :not_found on a clean slate" do
      # First-boot semantics: with no metadata and no private key, the loader
      # returns :not_found, NOT {:error, _} — that's how init_persistent
      # distinguishes "first boot, generate fresh" from "corrupted, refuse to
      # rotate silently".
      Arbor.Persistence.BufferedStore.delete(@authority_metadata_key, name: @key_store_name)
      Arbor.Security.SigningKeyStore.delete(@authority_signing_id)

      assert :not_found = SystemAuthority.load_persisted_keypair()
    end
  end
end
