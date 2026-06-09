defmodule Arbor.Security.Crypto do
  @moduledoc """
  Cryptographic primitives for the Arbor security system.

  Provides two keypair families:

  - **Ed25519** — signing and verification (existing)
  - **X25519** — Diffie-Hellman key exchange and encryption (new)

  Plus symmetric encryption (AES-256-GCM) and key derivation (HKDF-SHA256).
  All functions are pure (no state, no side effects).

  ## Encryption Flow

  To send a sealed message to a peer:

      1. ECDH:  shared_secret = derive_shared_secret(my_x25519_private, their_x25519_public)
      2. HKDF:  key = derive_key(shared_secret, "arbor-seal-v1")
      3. AES:   {ciphertext, iv, tag} = encrypt(plaintext, key)

  The `seal/3` and `unseal/2` functions wrap this flow for convenience.
  """

  # -------------------------------------------------------------------
  # Ed25519 — Signing
  # -------------------------------------------------------------------

  @doc """
  Generate a new Ed25519 keypair.

  Returns `{public_key, private_key}` where:
  - `public_key` is 32 bytes
  - `private_key` is 64 bytes (Ed25519 expanded key from Erlang `:crypto`)
  """
  @spec generate_keypair() :: {binary(), binary()}
  def generate_keypair do
    :crypto.generate_key(:eddsa, :ed25519)
  end

  @doc """
  Sign a message with an Ed25519 private key.

  Returns the signature bytes.
  """
  @spec sign(binary(), binary()) :: binary()
  def sign(message, private_key) when is_binary(message) and is_binary(private_key) do
    # `:none` is the correct digest argument for pure Ed25519 (RFC 8032,
    # which hashes internally). The previous `:sha512` was version-dependent:
    # OTP's eddsa has historically ignored the digest parameter, but relying
    # on that risks prehash semantics on some OTP release and breaks interop
    # with standard Ed25519 verifiers. On our OTP it is signature-identical
    # to `:sha512`, so this is a no-migration swap. (Crypto review C9.)
    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  @doc """
  Verify an Ed25519 signature against a message and public key.

  Returns `true` if the signature is valid, `false` otherwise.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(message, signature, public_key)
      when is_binary(message) and is_binary(signature) and is_binary(public_key) do
    # `:none` — pure Ed25519. See sign/2. Verify must use the same digest
    # argument as sign. (Crypto review C9.)
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  # -------------------------------------------------------------------
  # X25519 — Key Exchange
  # -------------------------------------------------------------------

  @doc """
  Generate a new X25519 keypair for Diffie-Hellman key exchange.

  Returns `{public_key, private_key}` where both are 32 bytes.
  """
  @spec generate_encryption_keypair() :: {binary(), binary()}
  def generate_encryption_keypair do
    :crypto.generate_key(:ecdh, :x25519)
  end

  @doc """
  Derive a shared secret from an X25519 key exchange (ECDH).

  Both parties compute the same shared secret:

      secret = derive_shared_secret(alice_private, bob_public)
      secret = derive_shared_secret(bob_private, alice_public)   # same value

  Returns a 32-byte shared secret.
  """
  @spec derive_shared_secret(binary(), binary()) :: binary()
  def derive_shared_secret(my_private, their_public)
      when is_binary(my_private) and is_binary(their_public) do
    :crypto.compute_key(:ecdh, their_public, my_private, :x25519)
  end

  # -------------------------------------------------------------------
  # HKDF — Key Derivation
  # -------------------------------------------------------------------

  @doc """
  Derive a cryptographic key from input keying material using HKDF-SHA256.

  This is a standard HKDF (RFC 5869) with SHA-256:
  1. Extract: `PRK = HMAC-SHA256(salt, ikm)` where salt defaults to 32 zero bytes
  2. Expand: `OKM = HMAC-SHA256(PRK, info || 0x01)` (single block for ≤32 bytes)

  **Audit note (2026-02-16):** This implementation was audited against RFC 5869.
  Neither JOSE nor Plug.Crypto provide an HKDF primitive — verified by checking
  `:application.get_key(:jose, :modules)` and `Plug.Crypto` exports. Hand-rolled
  implementation is the only option for Elixir/Erlang at this time.

  ## Parameters

  - `ikm` — input keying material (e.g., ECDH shared secret)
  - `info` — context string for domain separation (e.g., `"arbor-seal-v1"`)
  - `length` — desired output length in bytes (default: 32, max: 255 * 32)
  """
  @spec derive_key(binary(), binary(), pos_integer()) :: binary()
  def derive_key(ikm, info, length \\ 32)
      when is_binary(ikm) and is_binary(info) and is_integer(length) and length > 0 do
    # Extract phase: PRK = HMAC-SHA256(salt, IKM)
    salt = :binary.copy(<<0>>, 32)
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    # Expand phase
    hkdf_expand(prk, info, length)
  end

  defp hkdf_expand(prk, info, length) do
    n = ceil(length / 32)

    {output, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev} ->
        block = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i::8>>)
        {acc <> block, block}
      end)

    binary_part(output, 0, length)
  end

  # -------------------------------------------------------------------
  # AES-256-GCM — Symmetric Encryption
  # -------------------------------------------------------------------

  @aes_gcm_iv_size 12
  @aes_gcm_tag_size 16

  @doc """
  Encrypt plaintext with AES-256-GCM.

  Returns `{ciphertext, iv, tag}` where:
  - `iv` is a 12-byte random nonce
  - `tag` is a 16-byte authentication tag
  - `aad` is optional additional authenticated data (authenticated but not encrypted)
  """
  @spec encrypt(binary(), binary(), binary()) :: {binary(), binary(), binary()}
  def encrypt(plaintext, key, aad \\ "")
      when is_binary(plaintext) and is_binary(key) and byte_size(key) == 32 and is_binary(aad) do
    iv = :crypto.strong_rand_bytes(@aes_gcm_iv_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, @aes_gcm_tag_size, true)

    {ciphertext, iv, tag}
  end

  @doc """
  Decrypt ciphertext with AES-256-GCM.

  Returns `{:ok, plaintext}` on success, `{:error, :decryption_failed}` if the
  ciphertext or tag has been tampered with.
  """
  @spec decrypt(binary(), binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt(ciphertext, key, iv, tag, aad \\ "")
      when is_binary(ciphertext) and is_binary(key) and byte_size(key) == 32 and
             is_binary(iv) and is_binary(tag) and is_binary(aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> {:error, :decryption_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  # -------------------------------------------------------------------
  # Sealed Messages — ECDH + HKDF + AES-GCM
  # -------------------------------------------------------------------

  # Bumped v1 -> v2 for the ECIES redesign (C2). The label is HKDF info, so
  # it domain-separates v2 sealed messages from any v1 material.
  @seal_info "arbor-seal-v2"

  @doc """
  Seal a message for a recipient using **ECIES** (C2 review redesign).

  Improvements over the old static-static ECDH:

    * **Forward secrecy** — a fresh ephemeral X25519 keypair is generated per
      message and discarded. Compromise of either party's *static* key does
      NOT decrypt previously recorded traffic.
    * **Sender authentication** — an Ed25519 signature over the envelope binds
      the message to the sender's identity. The old scheme let any party seal
      a message and claim any sender; here the recipient verifies the
      signature against the sender's known signing key.

  Arguments:
    * `plaintext`            — message bytes
    * `recipient_public`     — recipient's **X25519** public key (32 bytes)
    * `sender_sign_private`  — sender's **Ed25519** signing private key. NOT an
      X25519 key — the ephemeral key supplies the ECDH secret, so the sender's
      static encryption key is no longer involved.

  Returns a sealed map. Decrypt with `unseal/3` and the sender's Ed25519
  PUBLIC key.

  Note: this is single-message AEAD with FS + sender auth — good for key/
  channel setup. For ongoing conversations use `DoubleRatchet`, which adds
  per-message ratcheting and replay handling.
  """
  @spec seal(binary(), binary(), binary()) :: map()
  def seal(plaintext, recipient_public, sender_sign_private)
      when is_binary(plaintext) and byte_size(recipient_public) == 32 and
             is_binary(sender_sign_private) do
    {ephemeral_public, ephemeral_private} = generate_encryption_keypair()
    shared_secret = derive_shared_secret(ephemeral_private, recipient_public)
    key = derive_key(shared_secret, @seal_info)
    {ciphertext, iv, tag} = encrypt(plaintext, key)

    # Sign the (non-secret) envelope so the recipient can authenticate the
    # sender. Covers the ephemeral pubkey too, so an attacker can't swap in
    # their own ephemeral key to redirect the ECDH.
    signature = sign(ephemeral_public <> iv <> tag <> ciphertext, sender_sign_private)

    %{
      v: 2,
      ephemeral_public: ephemeral_public,
      iv: iv,
      tag: tag,
      ciphertext: ciphertext,
      signature: signature
    }
  end

  @doc """
  Unseal a message sealed with `seal/3`.

  Verifies the sender's Ed25519 signature over the envelope BEFORE deriving
  the decryption key — an unauthenticated message is rejected without any
  decryption attempt.

  Arguments:
    * `sealed`              — the map from `seal/3`
    * `recipient_private`   — recipient's **X25519** private key (32 bytes)
    * `sender_sign_public`  — sender's **Ed25519** public key. Look this up
      from the identity registry / peer record; verifying against it is what
      binds the message to a known sender.

  Returns `{:ok, plaintext}`, `{:error, :bad_signature}`, or
  `{:error, :decryption_failed}` (or `{:error, :malformed_sealed}`).
  """
  @spec unseal(map(), binary(), binary()) ::
          {:ok, binary()}
          | {:error, :bad_signature | :decryption_failed | :malformed_sealed}
  def unseal(
        %{
          v: 2,
          ephemeral_public: ephemeral_public,
          iv: iv,
          tag: tag,
          ciphertext: ciphertext,
          signature: signature
        },
        recipient_private,
        sender_sign_public
      )
      when byte_size(recipient_private) == 32 and byte_size(ephemeral_public) == 32 and
             is_binary(sender_sign_public) do
    if verify(ephemeral_public <> iv <> tag <> ciphertext, signature, sender_sign_public) do
      shared_secret = derive_shared_secret(recipient_private, ephemeral_public)
      key = derive_key(shared_secret, @seal_info)
      decrypt(ciphertext, key, iv, tag)
    else
      {:error, :bad_signature}
    end
  end

  def unseal(_sealed, _recipient_private, _sender_sign_public), do: {:error, :malformed_sealed}

  # -------------------------------------------------------------------
  # Hashing & ID Derivation
  # -------------------------------------------------------------------

  @doc """
  Derive an agent ID from an Ed25519 public key.

  Returns `"agent_" <> hex(SHA-256(public_key))` in lowercase.
  """
  @spec derive_agent_id(binary()) :: String.t()
  def derive_agent_id(public_key) when is_binary(public_key) do
    "agent_" <> Base.encode16(hash(public_key), case: :lower)
  end

  @doc """
  Compute a SHA-256 hash of the given data.
  """
  @spec hash(binary()) :: binary()
  def hash(data) when is_binary(data) do
    :crypto.hash(:sha256, data)
  end
end
