defmodule Arbor.Security.Crypto do
  @moduledoc """
  Cryptographic primitives for the Arbor security system.

  Provides Ed25519 keypair generation, signing, verification, and hashing.
  All functions are pure (no state, no side effects). This module is the
  single source of truth for crypto operations across the security library,
  used by Identity, SignedRequest verification, and future capability signing.
  """

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
    :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])
  end

  @doc """
  Verify an Ed25519 signature against a message and public key.

  Returns `true` if the signature is valid, `false` otherwise.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(message, signature, public_key)
      when is_binary(message) and is_binary(signature) and is_binary(public_key) do
    :crypto.verify(:eddsa, :sha512, message, signature, [public_key, :ed25519])
  end

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
