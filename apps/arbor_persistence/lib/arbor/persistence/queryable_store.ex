defmodule Arbor.Persistence.QueryableStore do
  @moduledoc """
  Behaviour for queryable persistence with filtering, pagination, and aggregation.

  This module delegates to `Arbor.Contracts.Persistence.Store`, the unified
  store behaviour in contracts which now includes optional query callbacks.
  Use that module directly for new code.

  Existing implementations using `@behaviour Arbor.Persistence.QueryableStore`
  will continue to work — the callbacks are identical.
  """

  alias Arbor.Contracts.Persistence.{Filter, Record}

  @type key :: String.t()
  @type opts :: keyword()

  # --- Store operations ---

  @callback put(key(), Record.t(), opts()) :: :ok | {:error, term()}
  @callback get(key(), opts()) :: {:ok, Record.t()} | {:error, :not_found} | {:error, term()}
  @callback delete(key(), opts()) :: :ok | {:error, term()}
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}
  @callback exists?(key(), opts()) :: boolean()

  # --- Query operations ---

  @callback query(Filter.t(), opts()) :: {:ok, [Record.t()]} | {:error, term()}
  @callback count(Filter.t(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback aggregate(Filter.t(), atom(), atom(), opts()) ::
              {:ok, number() | nil} | {:error, term()}

  @optional_callbacks [exists?: 2]
end
