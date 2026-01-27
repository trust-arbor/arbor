defmodule Arbor.Persistence.Store do
  @moduledoc """
  Behaviour for basic key-value persistence.

  A Store provides simple CRUD operations on key-value pairs. Values
  can be any term. Implementations must handle their own serialization
  if needed.

  ## Implementing a Store

      defmodule MyStore do
        @behaviour Arbor.Persistence.Store

        @impl true
        def put(key, value, opts), do: ...

        @impl true
        def get(key, opts), do: ...

        # ...
      end
  """

  @type key :: String.t()
  @type value :: term()
  @type opts :: keyword()

  @doc "Store a value under the given key. Overwrites existing values."
  @callback put(key(), value(), opts()) :: :ok | {:error, term()}

  @doc "Retrieve a value by key. Returns {:ok, value} or {:error, :not_found}."
  @callback get(key(), opts()) :: {:ok, value()} | {:error, :not_found} | {:error, term()}

  @doc "Delete a value by key. Returns :ok even if key doesn't exist."
  @callback delete(key(), opts()) :: :ok | {:error, term()}

  @doc "List all keys. Returns {:ok, [key]} or {:error, reason}."
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}

  @doc "Check if a key exists."
  @callback exists?(key(), opts()) :: boolean()

  @optional_callbacks [exists?: 2]
end
