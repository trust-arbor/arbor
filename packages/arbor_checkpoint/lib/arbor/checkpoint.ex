defmodule Arbor.Checkpoint do
  @moduledoc """
  Generic checkpoint/restore library for Elixir processes.

  This module provides state persistence patterns that can be used with any
  GenServer or stateful process. It supports pluggable storage backends,
  retry logic for eventually consistent stores, automatic periodic checkpointing,
  and recovery mechanisms.

  ## Checkpoint Behaviour

  Modules that want custom checkpoint extraction/restoration should implement
  the `Arbor.Checkpoint` behaviour:

      defmodule MyStatefulProcess do
        use GenServer
        @behaviour Arbor.Checkpoint

        @impl Arbor.Checkpoint
        def extract_checkpoint_data(state) do
          # Return only essential data for persistence
          %{
            important_field: state.important_field,
            counter: state.counter
          }
        end

        @impl Arbor.Checkpoint
        def restore_from_checkpoint(checkpoint_data, initial_state) do
          # Merge checkpoint data into initial state
          %{initial_state |
            important_field: checkpoint_data.important_field,
            counter: checkpoint_data.counter,
            restored_at: System.system_time(:millisecond)
          }
        end
      end

  ## Storage Backends

  Checkpoints are stored using pluggable storage backends that implement
  `Arbor.Checkpoint.Storage`. An in-memory ETS backend is included for
  testing and simple use cases.

  ## Usage

      # Save a checkpoint
      :ok = Arbor.Checkpoint.save("process_1", state, MyStorage)

      # Load a checkpoint (with retry)
      {:ok, state} = Arbor.Checkpoint.load("process_1", MyStorage)

      # Enable auto-save (sends :checkpoint message periodically)
      Arbor.Checkpoint.enable_auto_save(self(), 30_000)

      # Attempt recovery for a module implementing the behaviour
      {:ok, recovered_state} = Arbor.Checkpoint.attempt_recovery(
        MyStatefulProcess, "process_1", initial_args, MyStorage
      )

  ## Checkpoint Metadata

  Each checkpoint includes metadata:
  - `timestamp` - When the checkpoint was created (milliseconds)
  - `node` - The node that created the checkpoint
  - `version` - Schema version for migration support
  """

  require Logger

  @type checkpoint_id :: String.t() | atom()
  @type checkpoint_data :: any()
  @type state :: any()
  @type storage_backend :: module()

  @type checkpoint :: %{
          data: checkpoint_data(),
          timestamp: integer(),
          node: node(),
          version: String.t()
        }

  @type load_opts :: [
          retries: non_neg_integer(),
          retry_delay: non_neg_integer(),
          retry_backoff: :exponential | :linear
        ]

  # ============================================================================
  # Behaviour Callbacks
  # ============================================================================

  @doc """
  Extracts essential data from state for checkpointing.

  Implementations should return only the critical data needed for recovery,
  avoiding transient or runtime-specific values.
  """
  @callback extract_checkpoint_data(state()) :: checkpoint_data()

  @doc """
  Restores state from checkpoint data.

  Implementations should merge checkpoint data with the initial state,
  reconstructing any derived fields as needed.
  """
  @callback restore_from_checkpoint(checkpoint_data(), state()) :: state()

  @optional_callbacks extract_checkpoint_data: 1, restore_from_checkpoint: 2

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Save a checkpoint for the given ID.

  Wraps the state data with metadata (timestamp, node, version) and
  persists it using the provided storage backend.

  ## Parameters
  - `id` - Unique identifier for the checkpoint
  - `state` - The state data to checkpoint (or a module implementing the behaviour)
  - `storage_backend` - Module implementing `Arbor.Checkpoint.Storage`
  - `opts` - Options passed to the storage backend

  ## Options
  - `:module` - If provided, calls `module.extract_checkpoint_data(state)` first
  - `:version` - Schema version string (default: "1.0.0")
  - `:metadata` - Additional metadata to include in the checkpoint

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save(checkpoint_id(), state(), storage_backend(), keyword()) :: :ok | {:error, term()}
  def save(id, state, storage_backend, opts \\ []) do
    module = Keyword.get(opts, :module)
    version = Keyword.get(opts, :version, "1.0.0")
    extra_metadata = Keyword.get(opts, :metadata, %{})

    data =
      if module do
        Code.ensure_loaded(module)

        if function_exported?(module, :extract_checkpoint_data, 1) do
          module.extract_checkpoint_data(state)
        else
          state
        end
      else
        state
      end

    checkpoint = %{
      data: data,
      timestamp: System.system_time(:millisecond),
      node: node(),
      version: version,
      metadata: extra_metadata
    }

    case storage_backend.put(id, checkpoint) do
      :ok ->
        Logger.debug("Checkpoint saved for #{inspect(id)}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to save checkpoint for #{inspect(id)}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Load a checkpoint for the given ID.

  Includes retry logic for eventually consistent storage backends.
  Returns the checkpoint data (without metadata wrapper) on success.

  ## Parameters
  - `id` - The checkpoint identifier to load
  - `storage_backend` - Module implementing `Arbor.Checkpoint.Storage`
  - `opts` - Retry and loading options

  ## Options
  - `:retries` - Number of retry attempts (default: 5)
  - `:retry_delay` - Initial delay between retries in ms (default: 100)
  - `:retry_backoff` - `:exponential` or `:linear` (default: `:exponential`)
  - `:include_metadata` - If true, returns full checkpoint with metadata (default: false)

  ## Returns
  - `{:ok, data}` on success (or `{:ok, checkpoint}` if include_metadata is true)
  - `{:error, :not_found}` if no checkpoint exists
  - `{:error, reason}` on failure
  """
  @spec load(checkpoint_id(), storage_backend(), load_opts()) ::
          {:ok, checkpoint_data()} | {:error, :not_found | term()}
  def load(id, storage_backend, opts \\ []) do
    retries = Keyword.get(opts, :retries, 5)
    retry_delay = Keyword.get(opts, :retry_delay, 100)
    backoff = Keyword.get(opts, :retry_backoff, :exponential)
    include_metadata = Keyword.get(opts, :include_metadata, false)

    load_with_retry(id, storage_backend, retries, retry_delay, backoff, include_metadata)
  end

  @doc """
  Get checkpoint info without loading the full data.

  Returns metadata about the checkpoint for inspection.

  ## Returns
  - `{:ok, info}` with timestamp, node, version, and age_ms
  - `{:error, :not_found}` if no checkpoint exists
  """
  @spec get_info(checkpoint_id(), storage_backend()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_info(id, storage_backend) do
    case storage_backend.get(id) do
      {:ok, checkpoint} ->
        info = %{
          timestamp: checkpoint.timestamp,
          node: checkpoint.node,
          version: checkpoint.version,
          age_ms: System.system_time(:millisecond) - checkpoint.timestamp,
          metadata: Map.get(checkpoint, :metadata, %{})
        }

        {:ok, info}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Remove a checkpoint.

  ## Returns
  - `:ok` on success (or if checkpoint didn't exist)
  - `{:error, reason}` on failure
  """
  @spec remove(checkpoint_id(), storage_backend()) :: :ok | {:error, term()}
  def remove(id, storage_backend) do
    case storage_backend.delete(id) do
      :ok ->
        Logger.debug("Checkpoint removed for #{inspect(id)}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to remove checkpoint for #{inspect(id)}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  List all checkpoint IDs in storage.

  ## Returns
  - `{:ok, [id]}` list of checkpoint IDs
  - `{:error, reason}` on failure
  """
  @spec list(storage_backend()) :: {:ok, [checkpoint_id()]} | {:error, term()}
  def list(storage_backend) do
    storage_backend.list()
  end

  @doc """
  Enable automatic periodic checkpointing for a process.

  Sends `:checkpoint` messages to the specified process at the given interval.
  The process should handle this message by calling `save/4`.

  Returns immediately after scheduling the first checkpoint message.

  ## Parameters
  - `pid` - The process to send checkpoint messages to
  - `interval_ms` - Interval between checkpoint messages in milliseconds

  ## Returns
  - `:ok` after scheduling the first message

  ## Example

      def init(args) do
        Arbor.Checkpoint.enable_auto_save(self(), 30_000)
        {:ok, initial_state}
      end

      def handle_info(:checkpoint, state) do
        Arbor.Checkpoint.save(state.id, state, MyStorage)
        # Re-schedule for next checkpoint
        Arbor.Checkpoint.enable_auto_save(self(), 30_000)
        {:noreply, state}
      end
  """
  @spec enable_auto_save(pid(), pos_integer()) :: :ok
  def enable_auto_save(pid, interval_ms) when is_pid(pid) and interval_ms > 0 do
    Process.send_after(pid, :checkpoint, interval_ms)
    :ok
  end

  @doc """
  Attempt to recover state for a module implementing the checkpoint behaviour.

  This function:
  1. Checks if the module implements the checkpoint behaviour callbacks
  2. Loads the checkpoint from storage
  3. Calls the module's `restore_from_checkpoint/2` to reconstruct state

  ## Parameters
  - `module` - Module implementing `Arbor.Checkpoint` behaviour
  - `id` - The checkpoint identifier
  - `initial_args` - Arguments to construct initial state for recovery
  - `storage_backend` - Module implementing `Arbor.Checkpoint.Storage`
  - `opts` - Options for loading (same as `load/3`)

  ## Returns
  - `{:ok, recovered_state}` on successful recovery
  - `{:error, :not_implemented}` if module doesn't implement behaviour
  - `{:error, :no_checkpoint}` if no checkpoint exists
  - `{:error, reason}` on other failures
  """
  @spec attempt_recovery(module(), checkpoint_id(), any(), storage_backend(), keyword()) ::
          {:ok, state()} | {:error, :not_implemented | :no_checkpoint | term()}
  def attempt_recovery(module, id, initial_args, storage_backend, opts \\ []) do
    Code.ensure_loaded(module)
    extract_exported = function_exported?(module, :extract_checkpoint_data, 1)
    restore_exported = function_exported?(module, :restore_from_checkpoint, 2)

    if extract_exported and restore_exported do
      case load(id, storage_backend, opts) do
        {:ok, checkpoint_data} ->
          Logger.debug("Loaded checkpoint for recovery: #{inspect(id)}")

          try do
            initial_state = build_initial_state(id, initial_args)
            restored_state = module.restore_from_checkpoint(checkpoint_data, initial_state)

            Logger.info("Successfully restored state from checkpoint for #{inspect(id)}")
            {:ok, restored_state}
          rescue
            error ->
              Logger.error("Failed to restore from checkpoint: #{inspect(error)}")
              {:error, error}
          end

        {:error, :not_found} ->
          Logger.debug("No checkpoint found for recovery: #{inspect(id)}")
          {:error, :no_checkpoint}

        {:error, reason} ->
          Logger.error("Failed to load checkpoint for recovery: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_implemented}
    end
  end

  @doc """
  Check if a module implements the checkpoint behaviour.

  ## Returns
  - `true` if both callbacks are exported
  - `false` otherwise
  """
  @spec implements_behaviour?(module()) :: boolean()
  def implements_behaviour?(module) do
    Code.ensure_loaded(module)

    function_exported?(module, :extract_checkpoint_data, 1) and
      function_exported?(module, :restore_from_checkpoint, 2)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_with_retry(id, storage_backend, retries, delay, backoff, include_metadata) do
    case storage_backend.get(id) do
      {:ok, checkpoint} ->
        result = if include_metadata, do: checkpoint, else: checkpoint.data
        {:ok, result}

      {:error, :not_found} when retries > 0 ->
        # Retry with backoff for eventual consistency
        Process.sleep(delay)
        next_delay = calculate_next_delay(delay, backoff)
        load_with_retry(id, storage_backend, retries - 1, next_delay, backoff, include_metadata)

      {:error, _reason} = error ->
        error
    end
  end

  defp calculate_next_delay(delay, :exponential), do: delay * 2
  defp calculate_next_delay(delay, :linear), do: delay

  defp build_initial_state(id, initial_args) when is_list(initial_args) do
    %{
      id: id,
      args: initial_args,
      recovered: false
    }
  end

  defp build_initial_state(id, initial_args) when is_map(initial_args) do
    Map.merge(%{id: id, recovered: false}, initial_args)
  end

  defp build_initial_state(id, initial_args) do
    %{
      id: id,
      args: initial_args,
      recovered: false
    }
  end
end
