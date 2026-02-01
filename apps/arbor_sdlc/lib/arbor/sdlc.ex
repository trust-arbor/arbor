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

  alias Arbor.SDLC.{
    Config,
    Events,
    PersistentFileTracker,
    Pipeline,
    Processors.ConsistencyChecker,
    Processors.Deliberator,
    Processors.Expander
  }

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
      enabled_stages: config.enabled_stages,
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
  Restart the watcher with current configuration.

  Use after changing the roadmap root or other watcher settings at runtime.
  Terminates the existing watcher and starts a new one under the supervisor.
  """
  @spec restart_watcher() :: :ok | {:error, term()}
  def restart_watcher do
    supervisor = Arbor.SDLC.Supervisor

    case Process.whereis(supervisor) do
      nil ->
        {:error, :supervisor_not_running}

      _pid ->
        # Terminate old watcher if running
        case Process.whereis(Arbor.SDLC.Watcher) do
          nil -> :ok
          _watcher -> Supervisor.terminate_child(supervisor, Arbor.SDLC.Watcher)
        end

        # Delete the old child spec
        Supervisor.delete_child(supervisor, Arbor.SDLC.Watcher)

        # Build new spec with current config
        config = Config.new()
        directories = Pipeline.watched_directories(config.roadmap_root)

        watcher_spec =
          {Arbor.Flow.Watcher,
           [
             name: Arbor.SDLC.Watcher,
             directories: directories,
             patterns: ["*.md"],
             tracker: Arbor.SDLC.FileTracker,
             tracker_module: PersistentFileTracker,
             processor_id: "sdlc_watcher",
             poll_interval: config.poll_interval,
             debounce_ms: config.debounce_ms,
             callbacks: %{
               on_new: &handle_new_file/3,
               on_changed: &handle_changed_file/3,
               on_deleted: &handle_deleted_file/1
             }
           ]}

        case Supervisor.start_child(supervisor, watcher_spec) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
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
        # Spawn processor work asynchronously so the watcher isn't blocked
        # by potentially slow LLM calls
        Task.Supervisor.start_child(Arbor.SDLC.TaskSupervisor, fn ->
          route_to_processor(item, path)
        end)

        :ok

      {:error, reason} ->
        Logger.warning("Failed to build item", path: path, reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Handle a changed file detected by the watcher.

  When a file's content hash changes, this re-processes the item through the
  appropriate processor. The file is re-parsed from the updated content so
  that any authoritative fields the user edited are picked up. The Expander's
  merge logic then preserves those fields during re-expansion.

  After successful re-processing the tracker is updated with the new content
  hash so that subsequent scans treat the file as up-to-date.
  """
  @spec handle_changed_file(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def handle_changed_file(path, content, hash) do
    Logger.info("File changed, re-processing", path: path, content_hash: hash)

    Events.emit_item_changed(path, hash)

    item_map = ItemParser.parse(content)

    case build_item(item_map, path, content) do
      {:ok, item} ->
        Events.emit_item_parsed(item)

        Task.Supervisor.start_child(Arbor.SDLC.TaskSupervisor, fn ->
          result = route_to_processor(item, path)
          update_tracker_after_change(path, hash, result)
        end)

        :ok

      {:error, reason} ->
        Logger.warning("Failed to build changed item", path: path, reason: inspect(reason))
        {:error, reason}
    end
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
  # Consistency Checks
  # =============================================================================

  @doc """
  Run consistency checks on the roadmap.

  Performs health checks, index refresh, stale item detection, and completion
  detection across all pipeline stages.

  ## Options

  - `:checks` - List of checks to run (default: all)
  - `:dry_run` - Don't write changes (default: false)
  - `:stale_threshold_days` - Days before item is considered stale (default: 14)

  ## Available Checks

  - `:completion_detection` - Find in_progress items that are done
  - `:index_refresh` - Rebuild INDEX.md files
  - `:stale_detection` - Find items stuck too long
  - `:health_check` - Verify required fields

  ## Examples

      # Run all checks
      {:ok, results} = Arbor.SDLC.run_consistency_checks()

      # Run specific checks
      {:ok, results} = Arbor.SDLC.run_consistency_checks(checks: [:health_check])
  """
  @spec run_consistency_checks(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run_consistency_checks(opts \\ []), to: ConsistencyChecker, as: :run

  @doc """
  List available consistency checks.
  """
  @spec available_consistency_checks() :: [atom()]
  defdelegate available_consistency_checks(), to: ConsistencyChecker, as: :available_checks

  # =============================================================================
  # Processors API
  # =============================================================================

  @doc """
  Expand an inbox item using the Expander processor.

  Takes a raw inbox item and expands it with LLM-generated content:
  priority, category, summary, acceptance criteria, etc.

  ## Options

  - `:dry_run` - If true, don't perform actual changes
  - `:ai_module` - Override the AI module to use

  ## Returns

      {:ok, {:moved_and_updated, :brainstorming, expanded_item}} | {:ok, :no_action} | {:error, reason}
  """
  @spec expand_item(Item.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate expand_item(item, opts \\ []), to: Expander, as: :process_item

  @doc """
  Deliberate on a brainstorming item using the Deliberator processor.

  Analyzes the item for decision points and uses the consensus council
  to make planning decisions.

  ## Options

  - `:dry_run` - If true, don't perform actual changes
  - `:ai_module` - Override the AI module to use

  ## Returns

      {:ok, {:moved, :planned | :discarded}} | {:ok, {:moved_and_updated, stage, item}} | {:error, reason}
  """
  @spec deliberate_item(Item.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate deliberate_item(item, opts \\ []), to: Deliberator, as: :process_item

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
        # Route to Expander processor
        Logger.info("Processing inbox item with Expander", title: item.title)
        Expander.process_item(item, opts)

      :brainstorming ->
        # Route to Deliberator processor
        Logger.info("Processing brainstorming item with Deliberator", title: item.title)
        Deliberator.process_item(item, opts)

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
    stage = determine_stage(item)

    if Config.stage_enabled?(stage) do
      Logger.debug("Routing item to processor",
        title: item.title,
        stage: stage,
        path: item.path
      )

      case stage do
        :inbox -> route_to_expander(item)
        :brainstorming -> route_to_deliberator(item)
        _ -> :ok
      end
    else
      Logger.debug("Stage disabled, skipping auto-processing",
        title: item.title,
        stage: stage
      )

      :ok
    end
  end

  defp route_to_expander(item) do
    case Expander.process_item(item, []) do
      {:ok, {:moved_and_updated, :brainstorming, expanded_item}} ->
        write_and_move_item(expanded_item, item.path, :brainstorming)

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Expander failed", title: item.title, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp route_to_deliberator(item) do
    case Deliberator.process_item(item, []) do
      {:ok, {:moved, stage}} ->
        move_item(item, stage, [])
        :ok

      {:ok, {:moved_and_updated, stage, updated_item}} ->
        write_and_move_item(updated_item, item.path, stage)

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Deliberator failed", title: item.title, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp write_and_move_item(item, old_path, to_stage) do
    config = Config.new()

    # Serialize the item back to markdown
    content = ItemParser.serialize(Map.from_struct(item))

    # Write to the new location
    filename = Path.basename(old_path)
    dest_dir = Pipeline.stage_path(to_stage, config.roadmap_root)
    dest_path = Path.join(dest_dir, filename)

    File.mkdir_p!(dest_dir)
    File.write!(dest_path, content)

    # Delete the old file if different from new
    if old_path != dest_path and File.exists?(old_path) do
      File.rm(old_path)
    end

    # Update tracking
    update_tracking_after_move(
      %{path: old_path, content_hash: item.content_hash},
      dest_path,
      config
    )

    # Emit event
    from_stage = Pipeline.stage_from_path(old_path) |> elem(1)

    Events.emit_item_moved(item, from_stage, to_stage,
      old_path: old_path,
      new_path: dest_path
    )

    :ok
  rescue
    e ->
      Logger.error("Failed to write and move item",
        item: item.title,
        error: Exception.message(e)
      )

      {:error, {:write_failed, e}}
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

  # When a changed file is re-processed and stays in place (e.g. the
  # processor returned :ok or :no_action without moving the file),
  # update the tracker with the new content hash so the next scan
  # treats the file as current.  If the processor moved the file,
  # write_and_move_item already updated the tracker.
  defp update_tracker_after_change(path, hash, result) do
    case result do
      :ok ->
        mark_processed_in_tracker(path, hash)

      {:error, _} ->
        # Processing failed — don't update tracker so it retries next scan
        :ok

      _ ->
        # Moved/updated variants are already tracked by write_and_move_item
        :ok
    end
  end

  defp mark_processed_in_tracker(path, hash) do
    case Process.whereis(Arbor.SDLC.FileTracker) do
      nil ->
        :ok

      tracker ->
        PersistentFileTracker.mark_processed(tracker, path, "sdlc_watcher", hash)
    end
  rescue
    _ -> :ok
  end
end
