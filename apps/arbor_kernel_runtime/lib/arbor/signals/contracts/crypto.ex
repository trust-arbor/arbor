defmodule Arbor.Signals.Contracts.Crypto do
  @moduledoc """
  Consumer-owned port for channel and topic-key cryptography.

  Library-specific to `arbor_signals`. Implementations live above this
  library and are injected via `Arbor.Signals.Config.crypto_module/0`.

  Callback names and arities match the existing configured-provider
  surface used by Channels and TopicKeys. Standalone and test default
  is `nil`; non-test runtime injects the production implementation.
  """

  @type plaintext :: binary()
  @type ciphertext :: binary()
  @type key :: binary()
  @type iv :: binary()
  @type tag :: binary()
  @type public_key :: binary()
  @type private_key :: binary()
  @type sealed :: map()

  @callback generate_encryption_keypair() :: {public_key(), private_key()}

  @callback encrypt(plaintext(), key()) :: {ciphertext(), iv(), tag()}

  @callback decrypt(ciphertext(), key(), iv(), tag()) ::
              {:ok, plaintext()} | {:error, :decryption_failed}

  @callback seal(plaintext(), public_key(), private_key()) :: sealed()

  @callback unseal(sealed(), private_key(), public_key()) ::
              {:ok, plaintext()}
              | {:error, :bad_signature | :decryption_failed | :malformed_sealed}
end
