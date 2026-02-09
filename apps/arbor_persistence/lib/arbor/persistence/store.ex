defmodule Arbor.Persistence.Store do
  @moduledoc """
  Behaviour for basic key-value persistence.

  This module delegates to `Arbor.Contracts.Persistence.Store`, the unified
  store behaviour in contracts. Use that module directly for new code.

  Existing implementations using `@behaviour Arbor.Persistence.Store` will
  continue to work — the callbacks are identical.
  """

  @type key :: String.t()
  @type value :: term()
  @type opts :: keyword()

  @callback put(key(), value(), opts()) :: :ok | {:error, term()}
  @callback get(key(), opts()) :: {:ok, value()} | {:error, :not_found} | {:error, term()}
  @callback delete(key(), opts()) :: :ok | {:error, term()}
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}
  @callback exists?(key(), opts()) :: boolean()

  @optional_callbacks [exists?: 2]
end
