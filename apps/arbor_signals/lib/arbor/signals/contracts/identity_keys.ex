defmodule Arbor.Signals.Contracts.IdentityKeys do
  @moduledoc """
  Consumer-owned port for signing and encryption public-key lookup.

  Library-specific to `arbor_signals`. Implementations live above this
  library and are injected via `Arbor.Signals.Config.identity_registry_module/0`.

  `lookup/1` returns the agent's signing public key. `lookup_encryption_key/1`
  returns the agent's encryption public key.
  """

  @type agent_id :: String.t()
  @type public_key :: binary()

  @callback lookup(agent_id()) :: {:ok, public_key()} | {:error, :not_found}

  @callback lookup_encryption_key(agent_id()) ::
              {:ok, public_key()} | {:error, :not_found | :no_encryption_key}
end
