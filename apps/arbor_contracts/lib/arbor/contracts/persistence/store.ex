defmodule Arbor.Contracts.Persistence.Store do
  @moduledoc """
  Unified behaviour for pluggable storage backends.

  Provides basic CRUD operations that every backend must implement, plus
  optional query operations for backends that support filtering, counting,
  and aggregation.

  ## Implementing a Store

  Minimal (CRUD only):

      defmodule MyFileStore do
        @behaviour Arbor.Contracts.Persistence.Store

        @impl true
        def put(key, value, _opts), do: ...

        @impl true
        def get(key, _opts), do: ...

        @impl true
        def delete(key, _opts), do: ...

        @impl true
        def list(_opts), do: ...
      end

  With query support:

      defmodule MyEctoStore do
        @behaviour Arbor.Contracts.Persistence.Store

        # ... CRUD callbacks ...

        @impl true
        def query(filter, _opts), do: ...

        @impl true
        def count(filter, _opts), do: ...

        @impl true
        def aggregate(filter, field, op, _opts), do: ...
      end

  ## Usage

  Any library can accept a store backend via configuration:

      config :arbor_security, storage_backend: MyFileStore

  The same backend module can plug into security, checkpoints, memory,
  or any other system that persists data.
  """

  alias Arbor.Contracts.Persistence.Filter

  @type key :: String.t()
  @type value :: term()
  @type opts :: keyword()

  # --- Required: CRUD operations ---

  @doc "Store a value under the given key. Overwrites existing values."
  @callback put(key(), value(), opts()) :: :ok | {:error, term()}

  @doc "Retrieve a value by key. Returns {:ok, value} or {:error, :not_found}."
  @callback get(key(), opts()) :: {:ok, value()} | {:error, :not_found | term()}

  @doc "Delete a value by key. Returns :ok even if key doesn't exist."
  @callback delete(key(), opts()) :: :ok | {:error, term()}

  @doc "List all keys. Returns {:ok, [key]} or {:error, reason}."
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}

  # --- Optional: existence check ---

  @doc "Check if a key exists."
  @callback exists?(key(), opts()) :: boolean()

  # --- Optional: query operations ---

  @doc "Query values using a Filter. Returns matching values."
  @callback query(Filter.t(), opts()) :: {:ok, [value()]} | {:error, term()}

  @doc "Count values matching a Filter."
  @callback count(Filter.t(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Aggregate a numeric field across matching values.

  Supported operations: :sum, :avg, :min, :max
  """
  @callback aggregate(Filter.t(), atom(), atom(), opts()) ::
              {:ok, number() | nil} | {:error, term()}

  @optional_callbacks [exists?: 2, query: 2, count: 2, aggregate: 4]
end
