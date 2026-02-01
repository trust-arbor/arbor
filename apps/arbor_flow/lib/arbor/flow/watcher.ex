defmodule Arbor.Flow.Watcher do
  @moduledoc """
  GenServer for watching directories and detecting file changes.

  The Watcher periodically scans directories for new or changed files,
  using content hashes to detect modifications. When changes are detected,
  it invokes registered callbacks.

  ## Architecture

  The Watcher is a GenServer that:

  1. Periodically scans watched directories (configurable interval)
  2. Computes content hashes for each file
  3. Compares against stored hashes in a FileTracker
  4. Invokes callbacks for new/changed files
  5. Debounces rapid changes

  ## Usage

  ```elixir
  # Define callbacks
  callbacks = %{
    on_new: fn path, content, hash -> IO.puts("New: " <> path) end,
    on_changed: fn path, content, hash -> IO.puts("Changed: " <> path) end,
    on_deleted: fn path -> IO.puts("Deleted: " <> path) end
  }

  # Start the watcher
  {:ok, pid} = Watcher.start_link(
    name: :my_watcher,
    directories: ["/path/to/roadmap/0-inbox"],
    patterns: ["*.md"],
    callbacks: callbacks,
    tracker: :my_tracker,
    processor_id: "expander"
  )

  # Force a rescan
  :ok = Watcher.rescan(:my_watcher)

  # Get status
  {:ok, status} = Watcher.status(:my_watcher)
  ```

  ## Options

  - `:name` - Required. Name to register the watcher under
  - `:directories` - Required. List of directories to watch
  - `:patterns` - File patterns to match (default: ["*.md"])
  - `:callbacks` - Map with `:on_new`, `:on_changed`, `:on_deleted` functions
  - `:tracker` - FileTracker reference (atom or pid)
  - `:processor_id` - ID for this processor in the FileTracker
  - `:poll_interval` - Milliseconds between scans (default: 30_000)
  - `:debounce_ms` - Debounce window for rapid changes (default: 1_000)
  """

  use GenServer

  alias Arbor.Flow.FileTracker

  require Logger

  @default_poll_interval 30_000
  @default_debounce_ms 1_000
  @default_patterns ["*.md"]

  @type callback :: (String.t(), String.t(), String.t() -> :ok | {:error, term()})
  @type delete_callback :: (String.t() -> :ok)

  @type watcher_opts :: [
          name: atom(),
          directories: [String.t()],
          patterns: [String.t()],
          callbacks: %{
            optional(:on_new) => callback(),
            optional(:on_changed) => callback(),
            optional(:on_deleted) => delete_callback()
          },
          tracker: atom() | pid() | nil,
          processor_id: String.t(),
          poll_interval: non_neg_integer(),
          debounce_ms: non_neg_integer()
        ]

  defstruct [
    :name,
    :directories,
    :patterns,
    :callbacks,
    :tracker,
    :processor_id,
    :poll_interval,
    :debounce_ms,
    :timer_ref,
    :known_files,
    # Track pending debounced files: %{path => {content, hash, timestamp}}
    :pending_changes
  ]

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Start the watcher GenServer.
  """
  @spec start_link(watcher_opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Force an immediate rescan of all watched directories.
  """
  @spec rescan(GenServer.server()) :: :ok
  def rescan(server) do
    GenServer.cast(server, :rescan)
  end

  @doc """
  Get the current status of the watcher.
  """
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Stop the watcher.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      directories: Keyword.fetch!(opts, :directories),
      patterns: Keyword.get(opts, :patterns, @default_patterns),
      callbacks: Keyword.get(opts, :callbacks, %{}),
      tracker: Keyword.get(opts, :tracker),
      processor_id: Keyword.get(opts, :processor_id, "watcher"),
      poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval),
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      timer_ref: nil,
      known_files: MapSet.new(),
      pending_changes: %{}
    }

    # Load known files from tracker if available
    state = load_known_files(state)

    # Ensure directories exist
    Enum.each(state.directories, &File.mkdir_p!/1)

    # Schedule initial scan
    send(self(), :initial_scan)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:initial_scan, state) do
    Logger.info("Watcher starting initial scan",
      name: state.name,
      directories: state.directories
    )

    state = scan_all_directories(state)
    timer_ref = schedule_scan(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_info(:scheduled_scan, state) do
    state = scan_all_directories(state)
    timer_ref = schedule_scan(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_info({:debounce_expired, path}, state) do
    case Map.get(state.pending_changes, path) do
      nil ->
        {:noreply, state}

      {content, hash, _timestamp, change_type} ->
        # Process the debounced change
        state = process_file_change(state, path, content, hash, change_type)
        pending = Map.delete(state.pending_changes, path)
        {:noreply, %{state | pending_changes: pending}}
    end
  end

  @impl GenServer
  def handle_cast(:rescan, state) do
    # Cancel any pending scheduled scan
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    state = scan_all_directories(state)
    timer_ref = schedule_scan(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = %{
      name: state.name,
      directories: state.directories,
      patterns: state.patterns,
      processor_id: state.processor_id,
      known_files_count: MapSet.size(state.known_files),
      pending_changes_count: map_size(state.pending_changes),
      poll_interval: state.poll_interval
    }

    {:reply, {:ok, status}, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp schedule_scan(interval) do
    Process.send_after(self(), :scheduled_scan, interval)
  end

  defp load_known_files(%{tracker: nil} = state), do: state

  defp load_known_files(%{tracker: tracker, processor_id: processor_id} = state) do
    known = FileTracker.ETS.load_known_files(tracker, processor_id)
    %{state | known_files: known}
  end

  defp scan_all_directories(state) do
    # Get all current files across all directories
    current_files =
      state.directories
      |> Enum.flat_map(&scan_directory(&1, state.patterns))
      |> Map.new(fn path -> {path, compute_file_hash(path)} end)

    current_paths = Map.keys(current_files) |> MapSet.new()

    # Find new files
    new_paths = MapSet.difference(current_paths, state.known_files)

    # Find deleted files
    deleted_paths = MapSet.difference(state.known_files, current_paths)

    # Process new and changed files
    state =
      current_files
      |> Enum.reduce(state, fn {path, hash}, acc ->
        cond do
          # New file
          MapSet.member?(new_paths, path) ->
            schedule_debounced_change(acc, path, hash, :new)

          # Existing file - check if changed
          needs_processing?(acc, path, hash) ->
            schedule_debounced_change(acc, path, hash, :changed)

          # No change
          true ->
            acc
        end
      end)

    # Process deleted files
    state =
      Enum.reduce(deleted_paths, state, fn path, acc ->
        handle_file_deleted(acc, path)
      end)

    %{state | known_files: current_paths}
  end

  defp scan_directory(dir_path, patterns) do
    case File.ls(dir_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&matches_patterns?(&1, patterns))
        |> Enum.map(&Path.join(dir_path, &1))

      {:error, reason} ->
        Logger.warning("Failed to scan directory",
          path: dir_path,
          reason: inspect(reason)
        )

        []
    end
  end

  defp matches_patterns?(filename, patterns) do
    Enum.any?(patterns, fn pattern ->
      case pattern do
        "*.md" -> String.ends_with?(filename, ".md")
        "*.json" -> String.ends_with?(filename, ".json")
        "*" -> true
        _ -> filename == pattern
      end
    end)
  end

  defp compute_file_hash(path) do
    case File.read(path) do
      {:ok, content} ->
        Arbor.Flow.compute_hash(content)

      {:error, _} ->
        nil
    end
  end

  defp needs_processing?(%{tracker: nil}, _path, _hash), do: false

  defp needs_processing?(%{tracker: tracker, processor_id: processor_id}, path, hash) do
    FileTracker.ETS.needs_processing?(tracker, path, processor_id, hash)
  end

  defp schedule_debounced_change(state, path, hash, change_type) do
    # Read file content
    case File.read(path) do
      {:ok, content} ->
        # Store pending change - include change_type so we know if it was new or changed
        pending =
          Map.put(state.pending_changes, path, {content, hash, System.monotonic_time(), change_type})

        # Schedule debounce expiry
        Process.send_after(self(), {:debounce_expired, path}, state.debounce_ms)

        %{state | pending_changes: pending}

      {:error, reason} ->
        Logger.warning("Failed to read file for change detection",
          path: path,
          reason: inspect(reason)
        )

        state
    end
  end

  defp process_file_change(state, path, content, hash, change_type) do
    # Use the change_type from when the change was detected
    case change_type do
      :new ->
        invoke_callback(state.callbacks[:on_new], path, content, hash)

      :changed ->
        invoke_callback(state.callbacks[:on_changed], path, content, hash)
    end

    # Mark as processed in tracker
    mark_processed(state, path, hash)

    state
  end

  defp handle_file_deleted(state, path) do
    invoke_delete_callback(state.callbacks[:on_deleted], path)
    remove_from_tracker(state, path)
    state
  end

  defp invoke_callback(nil, _path, _content, _hash), do: :ok

  defp invoke_callback(callback, path, content, hash) when is_function(callback, 3) do
    callback.(path, content, hash)
  rescue
    e ->
      Logger.error("Callback error",
        path: path,
        error: Exception.message(e)
      )

      {:error, e}
  end

  defp invoke_delete_callback(nil, _path), do: :ok

  defp invoke_delete_callback(callback, path) when is_function(callback, 1) do
    callback.(path)
  rescue
    e ->
      Logger.error("Delete callback error",
        path: path,
        error: Exception.message(e)
      )

      {:error, e}
  end

  defp mark_processed(%{tracker: nil}, _path, _hash), do: :ok

  defp mark_processed(%{tracker: tracker, processor_id: processor_id}, path, hash) do
    FileTracker.ETS.mark_processed(tracker, path, processor_id, hash)
  end

  defp remove_from_tracker(%{tracker: nil}, _path), do: :ok

  defp remove_from_tracker(%{tracker: tracker, processor_id: processor_id}, path) do
    FileTracker.ETS.remove(tracker, path, processor_id)
  end
end
