defmodule Arbor.Signals.Test.MockCrypto do
  @moduledoc """
  Test-local crypto fake for Signals.

  arbor_signals is L1 and must not depend on arbor_security (L2).
  Compatible encrypt/decrypt/seal/unseal using :crypto directly.
  """

  def generate_encryption_keypair do
    :crypto.generate_key(:ecdh, :x25519)
  end

  def seal(plaintext, _recipient_pub, _sender_priv) do
    %{ciphertext: plaintext, iv: <<0::96>>, tag: <<0::128>>, sender_public: <<0::256>>}
  end

  def unseal(%{ciphertext: ciphertext}, _recipient_priv) do
    {:ok, ciphertext}
  end

  def encrypt(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    {ciphertext, iv, tag}
  end

  def decrypt(ciphertext, key, iv, tag) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  end
end
