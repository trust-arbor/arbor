defmodule Arbor.Persistence.QueryableStore do
  @moduledoc """
  Behaviour for queryable persistence with filtering, pagination, and aggregation.

  Extends the Store concept with structured Records that support rich querying
  via the Filter DSL.

  ## Implementing a QueryableStore

      defmodule MyQueryableStore do
        @behaviour Arbor.Persistence.QueryableStore

        @impl true
        def put(key, record, opts), do: ...

        @impl true
        def query(filter, opts), do: ...

        # ...
      end
  """

  alias Arbor.Persistence.{Record, Filter}

  @type key :: String.t()
  @type opts :: keyword()

  # --- Store operations ---

  @doc "Store a record under the given key. Overwrites existing records."
  @callback put(key(), Record.t(), opts()) :: :ok | {:error, term()}

  @doc "Retrieve a record by key."
  @callback get(key(), opts()) :: {:ok, Record.t()} | {:error, :not_found} | {:error, term()}

  @doc "Delete a record by key."
  @callback delete(key(), opts()) :: :ok | {:error, term()}

  @doc "List all keys."
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}

  @doc "Check if a key exists."
  @callback exists?(key(), opts()) :: boolean()

  # --- Query operations ---

  @doc "Query records using a Filter. Returns matching records."
  @callback query(Filter.t(), opts()) :: {:ok, [Record.t()]} | {:error, term()}

  @doc "Count records matching a Filter."
  @callback count(Filter.t(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Aggregate a numeric field across matching records.

  Supported operations: :sum, :avg, :min, :max
  """
  @callback aggregate(Filter.t(), atom(), atom(), opts()) ::
              {:ok, number() | nil} | {:error, term()}

  @optional_callbacks [exists?: 2]
end
