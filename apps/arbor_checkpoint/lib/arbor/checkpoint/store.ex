defmodule Arbor.Checkpoint.Store do
  @moduledoc """
  Behaviour for checkpoint storage backends.

  This module delegates to `Arbor.Contracts.Persistence.Store`, the unified
  store behaviour in contracts. Use that module directly for new code.

  Any module implementing `Arbor.Contracts.Persistence.Store` is compatible
  and can be injected as a checkpoint backend.

  ## Built-in Backends

  - `Arbor.Checkpoint.Store.ETS` - In-memory ETS-based storage (good for testing)
  - `Arbor.Checkpoint.Store.Agent` - Agent-based storage (simpler, for testing)

  ## Consistency Considerations

  For distributed or eventually consistent storage backends, the
  `Arbor.Checkpoint.load/3` function includes retry logic. Backends
  should return `{:error, :not_found}` when a key doesn't exist
  (rather than raising) to allow retries to work correctly.
  """

  @type key :: String.t()
  @type value :: term()
  @type opts :: keyword()

  @callback put(key(), value(), opts()) :: :ok | {:error, term()}
  @callback get(key(), opts()) :: {:ok, value()} | {:error, :not_found | term()}
  @callback delete(key(), opts()) :: :ok | {:error, term()}
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}
  @callback exists?(key(), opts()) :: boolean()

  @optional_callbacks [exists?: 2]
end
