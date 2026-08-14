defmodule Arbor.Security.SignalsPortConformanceTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.Crypto

  test "facade exports Signals authorization crypto and identity-key ports" do
    assert {:module, Security} = Code.ensure_loaded(Security)

    assert function_exported?(Security, :authorize, 4)
    assert function_exported?(Security, :generate_encryption_keypair, 0)
    assert function_exported?(Security, :encrypt, 2)
    assert function_exported?(Security, :decrypt, 4)
    assert function_exported?(Security, :seal, 3)
    assert function_exported?(Security, :unseal, 3)
    assert function_exported?(Security, :lookup, 1)
    assert function_exported?(Security, :lookup_encryption_key, 1)

    behaviours =
      Security.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Arbor.Signals.Contracts.Authorization in behaviours
    assert Arbor.Signals.Contracts.Crypto in behaviours
    assert Arbor.Signals.Contracts.IdentityKeys in behaviours
  end

  test "facade encrypt decrypt and seal unseal preserve Crypto result shapes" do
    key = :crypto.strong_rand_bytes(32)
    plaintext = "k1f-port-roundtrip"

    {ciphertext, iv, tag} = Security.encrypt(plaintext, key)
    assert is_binary(ciphertext)
    assert is_binary(iv)
    assert is_binary(tag)
    assert {:ok, ^plaintext} = Security.decrypt(ciphertext, key, iv, tag)

    {recipient_public, recipient_private} = Security.generate_encryption_keypair()
    {sender_public, sender_private} = Crypto.generate_keypair()

    sealed = Security.seal(plaintext, recipient_public, sender_private)
    assert is_map(sealed)
    assert {:ok, ^plaintext} = Security.unseal(sealed, recipient_private, sender_public)
  end
end
