defmodule Arbor.Checkpoint.Store do
  @moduledoc """
  Behaviour for checkpoint storage backends.

  This interface is intentionally aligned with `Arbor.Persistence.Store` so that
  any persistence backend can be used as a checkpoint store via dependency injection.

  ## Built-in Backends

  - `Arbor.Checkpoint.Store.ETS` - In-memory ETS-based storage (good for testing)
  - `Arbor.Checkpoint.Store.Agent` - Agent-based storage (simpler, for testing)

  ## Using Persistence Backends

  Any module implementing `Arbor.Persistence.Store` is interface-compatible and
  can be injected as a checkpoint backend without checkpoint depending on persistence:

      # In arbor_agent config
      config :my_app, checkpoint_storage: Arbor.Persistence.Store.DETS

  ## Implementing a Custom Backend

      defmodule MyRedisStore do
        @behaviour Arbor.Checkpoint.Store

        @impl true
        def put(id, checkpoint, _opts) do
          key = "checkpoint:\#{id}"
          value = :erlang.term_to_binary(checkpoint)

          case Redix.command(:redix, ["SET", key, value]) do
            {:ok, "OK"} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def get(id, _opts) do
          key = "checkpoint:\#{id}"

          case Redix.command(:redix, ["GET", key]) do
            {:ok, nil} -> {:error, :not_found}
            # Use :safe to prevent atom table exhaustion from untrusted data
            {:ok, value} -> {:ok, :erlang.binary_to_term(value, [:safe])}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def delete(id, _opts) do
          Redix.command(:redix, ["DEL", "checkpoint:\#{id}"])
          :ok
        end

        @impl true
        def list(opts) do
          {:ok, keys} = Redix.command(:redix, ["KEYS", "checkpoint:*"])
          {:ok, Enum.map(keys, fn "checkpoint:" <> id -> id end)}
        end
      end

  ## Consistency Considerations

  For distributed or eventually consistent storage backends, the
  `Arbor.Checkpoint.load/3` function includes retry logic. Backends
  should return `{:error, :not_found}` when a key doesn't exist
  (rather than raising) to allow retries to work correctly.
  """

  @type key :: String.t()
  @type value :: term()
  @type opts :: keyword()

  @doc "Store a value under the given key. Overwrites existing values."
  @callback put(key(), value(), opts()) :: :ok | {:error, term()}

  @doc "Retrieve a value by key. Returns {:ok, value} or {:error, :not_found}."
  @callback get(key(), opts()) :: {:ok, value()} | {:error, :not_found | term()}

  @doc "Delete a value by key. Returns :ok even if key doesn't exist."
  @callback delete(key(), opts()) :: :ok | {:error, term()}

  @doc "List all keys. Returns {:ok, [key]} or {:error, reason}."
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}

  @doc "Check if a key exists."
  @callback exists?(key(), opts()) :: boolean()

  @optional_callbacks [exists?: 2]
end
