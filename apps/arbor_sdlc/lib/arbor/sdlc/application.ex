defmodule Arbor.SDLC.Application do
  @moduledoc """
  Supervisor for the SDLC automation system.

  Starts the file tracker and watcher under supervision. Processors
  register with the watcher to receive callbacks when files change.

  ## Architecture

      Application Supervisor
          │
          ├── PersistentFileTracker (tracks processed files across restarts)
          │
          └── Watcher (monitors roadmap directories for changes)
                  │
                  ├── on_new callback → Processors
                  └── on_changed callback → Processors

  ## Configuration

  The application can be configured via `config/config.exs`:

      config :arbor_sdlc,
        roadmap_root: "/path/to/roadmap",
        poll_interval: 30_000,
        processors: [
          Arbor.SDLC.Processors.Expander,
          Arbor.SDLC.Processors.Deliberator,
          Arbor.SDLC.Processors.ConsistencyChecker
        ]
  """

  use Application

  require Logger

  alias Arbor.SDLC.{Config, PersistentFileTracker, Pipeline}

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_sdlc, :start_children, true) do
        build_children()
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.SDLC.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Arbor.SDLC started", children: length(children))
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start Arbor.SDLC", reason: inspect(reason))
        error
    end
  end

  @impl true
  def stop(_state) do
    :ok
  end

  # Build children based on configuration
  defp build_children do
    config = Config.new()

    # Always start the file tracker and task supervisor
    tracker_spec = {
      PersistentFileTracker,
      [name: Arbor.SDLC.FileTracker, config: config]
    }

    task_supervisor_spec = {Task.Supervisor, name: Arbor.SDLC.TaskSupervisor}

    # Only start the watcher if enabled
    if config.watcher_enabled do
      watcher_spec = build_watcher_spec(config)
      [tracker_spec, task_supervisor_spec, watcher_spec]
    else
      [tracker_spec, task_supervisor_spec]
    end
  end

  defp build_watcher_spec(config) do
    directories = Pipeline.watched_directories(config.roadmap_root)

    {
      Arbor.Flow.Watcher,
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
          on_new: &Arbor.SDLC.handle_new_file/3,
          on_changed: &Arbor.SDLC.handle_changed_file/3,
          on_deleted: &Arbor.SDLC.handle_deleted_file/1
        }
      ]
    }
  end
end
