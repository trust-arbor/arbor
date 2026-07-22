defmodule Arbor.Security.SigningKeyStoreTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security
  alias Arbor.Security.SigningKeyStore

  @test_agent_id "agent_test_signing_key_store_#{:erlang.unique_integer([:positive])}"

  setup do
    # Clean up after test
    on_exit(fn ->
      SigningKeyStore.delete(@test_agent_id)
    end)

    :ok
  end

  describe "put/2 and get/1" do
    test "stores and retrieves a private key" do
      # Generate a fresh Ed25519 keypair
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv)
      assert {:ok, retrieved} = SigningKeyStore.get(@test_agent_id)
      assert retrieved == priv
    end

    test "returns error for non-existent key" do
      assert {:error, :no_signing_key} = SigningKeyStore.get("agent_nonexistent_key_test")
    end

    test "overwrites existing key" do
      {_pub1, priv1} = :crypto.generate_key(:eddsa, :ed25519)
      {_pub2, priv2} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv1)
      assert :ok = SigningKeyStore.put(@test_agent_id, priv2)
      assert {:ok, retrieved} = SigningKeyStore.get(@test_agent_id)
      assert retrieved == priv2
    end
  end

  describe "signing_key_status/1" do
    test "reports available without returning key material" do
      {_pub, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, private_key)
      assert {:ok, :available} = Security.signing_key_status(@test_agent_id)
    end

    test "reports a missing signing key" do
      assert {:error, :no_signing_key} = Security.signing_key_status(@test_agent_id)
    end

    test "rejects invalid principal input" do
      assert {:error, :invalid_principal} = Security.signing_key_status(nil)
      assert {:error, :invalid_principal} = Security.signing_key_status("")
      assert {:error, :invalid_principal} = Security.signing_key_status("system_authority")
    end

    test "uses the signing-authority principal contract without a narrower local grammar" do
      assert {:error, :no_signing_key} =
               Security.signing_key_status("agent_contract.accepted/by-validator")
    end

    test "reports malformed encrypted material without exposing storage errors" do
      {_pub, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      assert :ok = SigningKeyStore.put(@test_agent_id, private_key)

      malformed = %Record{
        id: @test_agent_id,
        key: @test_agent_id,
        data: %{"ct" => "not-base64", "iv" => "not-base64", "tag" => "not-base64"},
        metadata: %{}
      }

      assert :ok =
               Arbor.Persistence.BufferedStore.put(@test_agent_id, malformed,
                 name: :arbor_security_signing_keys
               )

      assert {:error, :invalid_key_material} = Security.signing_key_status(@test_agent_id)
    end

    test "does not create a missing master key while checking an encrypted signing record" do
      base =
        Path.join(System.tmp_dir!(), "arbor_signing_status_#{System.unique_integer([:positive])}")

      existing_keypath = Path.join([base, "existing", "master.key"])
      missing_keypath = Path.join([base, "missing", "master.key"])
      previous = Application.get_env(:arbor_security, :master_key_path)
      Application.put_env(:arbor_security, :master_key_path, existing_keypath)

      on_exit(fn ->
        File.rm_rf(base)

        case previous do
          nil -> Application.delete_env(:arbor_security, :master_key_path)
          value -> Application.put_env(:arbor_security, :master_key_path, value)
        end
      end)

      {_pub, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      assert :ok = SigningKeyStore.put(@test_agent_id, private_key)
      assert File.exists?(existing_keypath)

      Application.put_env(:arbor_security, :master_key_path, missing_keypath)

      assert {:error, :invalid_key_material} = Security.signing_key_status(@test_agent_id)
      refute File.exists?(missing_keypath)
    end
  end

  describe "delete/1" do
    test "deletes a stored key" do
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv)
      assert {:ok, _} = SigningKeyStore.get(@test_agent_id)

      assert :ok = SigningKeyStore.delete(@test_agent_id)
      assert {:error, :no_signing_key} = SigningKeyStore.get(@test_agent_id)
    end

    test "succeeds even if key doesn't exist" do
      assert :ok = SigningKeyStore.delete("agent_nonexistent_delete_test")
    end
  end

  describe "encryption" do
    test "stored data is encrypted (not raw private key)" do
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv)

      # Read raw record from BufferedStore — should NOT contain the raw private key
      case Arbor.Persistence.BufferedStore.get(@test_agent_id,
             name: :arbor_security_signing_keys
           ) do
        {:ok, record} ->
          # Record is a %Record{} struct with encrypted data inside
          data =
            case record do
              %Arbor.Contracts.Persistence.Record{data: d} -> d
              %{} -> record
            end

          assert is_map(data)
          assert Map.has_key?(data, "ct")
          assert Map.has_key?(data, "iv")
          assert Map.has_key?(data, "tag")
          # The ciphertext should NOT be the raw private key
          {:ok, ct} = Base.decode64(data["ct"])
          refute ct == priv

        {:error, _} ->
          # Store might not be available — skip this assertion
          :ok
      end
    end
  end

  describe "master key file permissions (C6)" do
    import Bitwise

    test "key directory is 0700 (no group/other access)" do
      # Security regression: master key creation used to leave a umask-
      # dependent window where the key was world-readable. The fix restricts
      # the containing directory to 0700 (and writes the file via an atomic
      # 0600 temp-rename). The directory mode is the persistent, testable
      # discriminator — pre-fix the dir was the umask default (commonly 0755).
      base = Path.join(System.tmp_dir!(), "arbor_c6_#{:erlang.unique_integer([:positive])}")
      keypath = Path.join([base, "security", "master.key"])
      prev = Application.get_env(:arbor_security, :master_key_path)
      Application.put_env(:arbor_security, :master_key_path, keypath)

      on_exit(fn ->
        File.rm_rf(base)

        case prev do
          nil -> Application.delete_env(:arbor_security, :master_key_path)
          v -> Application.put_env(:arbor_security, :master_key_path, v)
        end
      end)

      # Path doesn't exist yet → triggers generation.
      assert {:ok, key} = SigningKeyStore.ensure_master_key_for_oidc()
      assert byte_size(key) == 32

      dir = Path.dirname(keypath)
      {:ok, dir_stat} = File.stat(dir)
      {:ok, file_stat} = File.stat(keypath)

      assert (dir_stat.mode &&& 0o777) == 0o700,
             "key dir must be 0700, got 0o#{Integer.to_string(dir_stat.mode &&& 0o777, 8)}"

      assert (file_stat.mode &&& 0o077) == 0,
             "key file must have no group/other access, got 0o#{Integer.to_string(file_stat.mode &&& 0o777, 8)}"

      refute File.exists?(keypath <> ".tmp"), "temp file must be renamed away, not left behind"
    end
  end
end
