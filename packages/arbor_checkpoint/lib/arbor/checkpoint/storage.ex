defmodule Arbor.Checkpoint.Storage do
  @moduledoc """
  Behaviour for checkpoint storage backends.

  Implement this behaviour to create custom storage backends for checkpoints.
  Storage backends handle the persistence of checkpoint data and must support
  basic CRUD operations.

  ## Built-in Backends

  - `Arbor.Checkpoint.Storage.ETS` - In-memory ETS-based storage (good for testing)
  - `Arbor.Checkpoint.Storage.Agent` - Agent-based storage (simpler, for testing)

  ## Implementing a Custom Backend

      defmodule MyRedisStorage do
        @behaviour Arbor.Checkpoint.Storage

        @impl true
        def put(id, checkpoint) do
          key = checkpoint_key(id)
          value = :erlang.term_to_binary(checkpoint)

          case Redix.command(:redix, ["SET", key, value]) do
            {:ok, "OK"} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def get(id) do
          key = checkpoint_key(id)

          case Redix.command(:redix, ["GET", key]) do
            {:ok, nil} -> {:error, :not_found}
            {:ok, value} -> {:ok, :erlang.binary_to_term(value)}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def delete(id) do
          key = checkpoint_key(id)
          Redix.command(:redix, ["DEL", key])
          :ok
        end

        @impl true
        def list do
          case Redix.command(:redix, ["KEYS", "checkpoint:*"]) do
            {:ok, keys} -> {:ok, Enum.map(keys, &extract_id/1)}
            {:error, reason} -> {:error, reason}
          end
        end

        defp checkpoint_key(id), do: "checkpoint:\#{id}"
        defp extract_id("checkpoint:" <> id), do: id
      end

  ## Consistency Considerations

  For distributed or eventually consistent storage backends, the
  `Arbor.Checkpoint.load/3` function includes retry logic. Backends
  should return `{:error, :not_found}` when a key doesn't exist
  (rather than raising) to allow retries to work correctly.
  """

  @type checkpoint_id :: Arbor.Checkpoint.checkpoint_id()
  @type checkpoint :: Arbor.Checkpoint.checkpoint()

  @doc """
  Store a checkpoint with the given ID.

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @callback put(checkpoint_id(), checkpoint()) :: :ok | {:error, term()}

  @doc """
  Retrieve a checkpoint by ID.

  ## Returns
  - `{:ok, checkpoint}` if found
  - `{:error, :not_found}` if no checkpoint exists for the ID
  - `{:error, reason}` on other failures
  """
  @callback get(checkpoint_id()) :: {:ok, checkpoint()} | {:error, :not_found | term()}

  @doc """
  Delete a checkpoint by ID.

  Should succeed even if the checkpoint doesn't exist.

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @callback delete(checkpoint_id()) :: :ok | {:error, term()}

  @doc """
  List all checkpoint IDs in storage.

  ## Returns
  - `{:ok, [checkpoint_id]}` list of IDs
  - `{:error, reason}` on failure
  """
  @callback list() :: {:ok, [checkpoint_id()]} | {:error, term()}

  @doc """
  Check if a checkpoint exists.

  Default implementation uses `get/1`, but backends can override
  for more efficient existence checks.

  ## Returns
  - `true` if checkpoint exists
  - `false` otherwise
  """
  @callback exists?(checkpoint_id()) :: boolean()

  @optional_callbacks exists?: 1
end
