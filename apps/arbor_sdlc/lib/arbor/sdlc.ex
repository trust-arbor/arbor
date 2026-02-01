defmodule Arbor.SDLC do
  @moduledoc """
  SDLC automation facade for Arbor.

  Provides the public API for the SDLC pipeline system, which automates
  the flow of work items from idea to completion. Items in `.arbor/roadmap/`
  are automatically processed through the pipeline:

  ```
  inbox -> brainstorming -> planned -> in_progress -> completed
                                  \\-> discarded
  ```

  ## Architecture

      Filesystem Events → Watcher → Processors → Signals
                              │           │
                     FileTracker     Consensus Council
                     (persistence)        │
                                    Decision Docs

  ## Quick Start

      # System starts automatically via Application supervisor

      # Manually trigger a rescan
      Arbor.SDLC.rescan()

      # Process a specific file
      {:ok, result} = Arbor.SDLC.process_file("/path/to/item.md")

      # Get system status
      %{healthy: true, ...} = Arbor.SDLC.status()

  ## Processors

  Three processors handle different pipeline stages:

  - **Expander** - Expands raw inbox items via LLM (inbox -> brainstorming)
  - **Deliberator** - Analyzes items and uses consensus council for decisions
  - **ConsistencyChecker** - Periodic health checks and INDEX.md maintenance

  ## Configuration

      config :arbor_sdlc,
        roadmap_root: ".arbor/roadmap",
        poll_interval: 30_000,
        watcher_enabled: true

  See `Arbor.SDLC.Config` for full configuration options.
  """

  require Logger

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Events, PersistentFileTracker, Pipeline}

  # =============================================================================
  # System Status
  # =============================================================================

  @doc """
  Check if the SDLC system is healthy.

  Returns true if the supervisor and critical children are running.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case Process.whereis(Arbor.SDLC.Supervisor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  Get the current status of the SDLC system.

  Returns a map with health, configuration, and statistics.
  """
  @spec status() :: map()
  def status do
    config = Config.new()

    %{
      healthy: healthy?(),
      roadmap_root: config.roadmap_root,
      watcher_enabled: config.watcher_enabled,
      watcher_status: watcher_status(),
      tracker_stats: tracker_stats()
    }
  end

  defp watcher_status do
    case Process.whereis(Arbor.SDLC.Watcher) do
      nil ->
        :not_running

      pid ->
        case Arbor.Flow.Watcher.status(pid) do
          {:ok, status} -> status
          _ -> :unknown
        end
    end
  end

  defp tracker_stats do
    case Process.whereis(Arbor.SDLC.FileTracker) do
      nil ->
        %{}

      tracker ->
        PersistentFileTracker.stats(tracker, "sdlc_watcher")
    end
  end

  # =============================================================================
  # Manual Operations
  # =============================================================================

  @doc """
  Force an immediate rescan of all watched directories.

  Triggers the watcher to scan for new or changed files.
  """
  @spec rescan() :: :ok | {:error, :watcher_not_running}
  def rescan do
    case Process.whereis(Arbor.SDLC.Watcher) do
      nil -> {:error, :watcher_not_running}
      watcher -> Arbor.Flow.Watcher.rescan(watcher)
    end
  end

  @doc """
  Process a specific file manually.

  Parses the file and routes it to the appropriate processor based on
  its current stage.

  ## Options

  - `:dry_run` - If true, don't perform actual changes (default: false)
  - `:force` - Process even if file was already processed (default: false)
  """
  @spec process_file(String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def process_file(path, opts \\ []) do
    with {:ok, content} <- File.read(path) do
      item_map = ItemParser.parse(content)

      case build_item(item_map, path, content) do
        {:ok, item} -> process_item(item, opts)
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Parse a file and return the Item struct without processing.

  Useful for inspection and debugging.
  """
  @spec parse_file(String.t()) :: {:ok, Item.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, content} <- File.read(path) do
      item_map = ItemParser.parse(content)
      build_item(item_map, path, content)
    end
  end

  @doc """
  Move an item to a new stage.

  Moves the file to the appropriate directory and updates tracking.
  """
  @spec move_item(Item.t() | map(), atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def move_item(item, to_stage, opts \\ []) do
    config = Keyword.get(opts, :config, Config.new())
    from_stage = determine_stage(item)

    with :ok <- validate_transition(from_stage, to_stage),
         {:ok, new_path} <- do_move_file(item, to_stage, config) do
      # Update tracking if tracker is available
      update_tracking_after_move(item, new_path, config)

      # Emit event
      Events.emit_item_moved(item, from_stage, to_stage,
        old_path: Map.get(item, :path),
        new_path: new_path
      )

      {:ok, new_path}
    end
  end

  # =============================================================================
  # Watcher Callbacks
  # =============================================================================

  @doc """
  Handle a new file detected by the watcher.

  This is called automatically when files are added to watched directories.
  """
  @spec handle_new_file(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def handle_new_file(path, content, hash) do
    Events.emit_item_detected(path, hash)

    # ItemParser.parse returns a map directly (always succeeds)
    item_map = ItemParser.parse(content)

    case build_item(item_map, path, content) do
      {:ok, item} ->
        Events.emit_item_parsed(item)
        route_to_processor(item, path)

      {:error, reason} ->
        Logger.warning("Failed to build item", path: path, reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Handle a changed file detected by the watcher.
  """
  @spec handle_changed_file(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def handle_changed_file(path, content, hash) do
    # For now, treat changed files the same as new files
    handle_new_file(path, content, hash)
  end

  @doc """
  Handle a deleted file detected by the watcher.
  """
  @spec handle_deleted_file(String.t()) :: :ok
  def handle_deleted_file(path) do
    Logger.debug("File deleted", path: path)
    :ok
  end

  # =============================================================================
  # Pipeline Helpers (delegations)
  # =============================================================================

  @doc """
  Get all pipeline stages.
  """
  defdelegate stages, to: Pipeline

  @doc """
  Get the directory name for a stage.
  """
  defdelegate stage_directory(stage), to: Pipeline

  @doc """
  Check if a transition is allowed.
  """
  defdelegate transition_allowed?(from, to), to: Pipeline

  @doc """
  Get the full path for a stage within the roadmap root.
  """
  defdelegate stage_path(stage, roadmap_root), to: Pipeline

  @doc """
  Ensure all stage directories exist.
  """
  defdelegate ensure_directories!(roadmap_root), to: Pipeline

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp build_item(item_map, path, content) do
    hash = Arbor.Flow.compute_hash(content)

    attrs =
      item_map
      |> Map.to_list()
      |> Keyword.put(:path, path)
      |> Keyword.put(:content_hash, hash)
      |> Keyword.put(:raw_content, content)

    Item.new(attrs)
  end

  defp process_item(item, opts) do
    stage = determine_stage(item)

    case stage do
      :inbox ->
        # Would route to Expander processor (Phase 3)
        Logger.info("Item in inbox would be processed by Expander", title: item.title)
        {:ok, {:pending_processor, :expander}}

      :brainstorming ->
        # Would route to Deliberator processor (Phase 3)
        Logger.info("Item in brainstorming would be processed by Deliberator", title: item.title)
        {:ok, {:pending_processor, :deliberator}}

      stage when stage in [:completed, :discarded] ->
        Logger.debug("Item in terminal stage", stage: stage, title: item.title)
        {:ok, :no_action}

      _ ->
        dry_run = Keyword.get(opts, :dry_run, false)

        if dry_run do
          {:ok, :dry_run}
        else
          {:ok, :no_action}
        end
    end
  end

  defp route_to_processor(item, _path) do
    # For Phase 2, just log - processors will be added in Phase 3
    stage = determine_stage(item)

    Logger.debug("Routing item to processor",
      title: item.title,
      stage: stage,
      path: item.path
    )

    :ok
  end

  defp determine_stage(item) do
    case Map.get(item, :path) do
      nil -> :inbox
      path -> Pipeline.stage_from_path(path) |> elem(1)
    end
  rescue
    _ -> :inbox
  end

  defp validate_transition(from_stage, to_stage) do
    if Pipeline.transition_allowed?(from_stage, to_stage) do
      :ok
    else
      {:error, {:invalid_transition, from_stage, to_stage}}
    end
  end

  defp do_move_file(item, to_stage, config) do
    case Map.get(item, :path) do
      nil ->
        {:error, :no_source_path}

      source_path ->
        filename = Path.basename(source_path)
        dest_dir = Pipeline.stage_path(to_stage, config.roadmap_root)
        dest_path = Path.join(dest_dir, filename)

        # Ensure destination directory exists
        File.mkdir_p!(dest_dir)

        case File.rename(source_path, dest_path) do
          :ok -> {:ok, dest_path}
          {:error, reason} -> {:error, {:move_failed, reason}}
        end
    end
  end

  defp update_tracking_after_move(item, new_path, _config) do
    old_path = Map.get(item, :path)
    content_hash = Map.get(item, :content_hash, "")

    case Process.whereis(Arbor.SDLC.FileTracker) do
      nil ->
        :ok

      tracker ->
        PersistentFileTracker.mark_moved(
          tracker,
          old_path,
          new_path,
          "sdlc_watcher",
          content_hash
        )
    end
  rescue
    _ -> :ok
  end
end
