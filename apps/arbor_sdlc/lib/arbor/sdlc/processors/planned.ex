defmodule Arbor.SDLC.Processors.Planned do
  @moduledoc """
  Processes planned items by spawning autonomous sessions.

  The Planned processor handles the transition from planned to in_progress.
  It watches for items with `auto: true` in their frontmatter and spawns
  CLI sessions (or full Hands) to work on them.

  ## Pipeline Stage

  Handles: `planned` -> `in_progress`

  ## Execution Modes

  Items can specify their execution mode via frontmatter:

  - `execution_mode: auto` - Lightweight CLI session (SessionRunner)
  - `execution_mode: hand` - Full Hand with git worktree
  - `execution_mode: manual` - Skip auto-processing

  ## Frontmatter Fields

  ```yaml
  auto: true              # Whether to auto-spawn (default: false)
  max_attempts: 2         # Max spawn attempts (default: 2)
  session_id: null        # Set by processor when session started
  session_started_at: null # Timestamp of spawn
  attempt: 0              # Current attempt number
  execution_mode: auto    # auto | hand | manual
  ```

  ## Usage

      {:ok, result} = Planned.process_item(item, [])

      case result do
        {:spawned, session_id} -> ...
        :skipped_manual -> ...
        :skipped_max_attempts -> ...
      end
  """

  @behaviour Arbor.Contracts.Flow.Processor

  use GenServer

  require Logger

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Events, Pipeline, SessionRunner}

  @processor_id "sdlc_planned"

  # State for the processor GenServer
  defstruct [
    :config,
    :active_sessions,
    :session_monitors
  ]

  # =============================================================================
  # Processor Behaviour Implementation
  # =============================================================================

  @impl Arbor.Contracts.Flow.Processor
  def processor_id, do: @processor_id

  @impl Arbor.Contracts.Flow.Processor
  def can_handle?(%{path: path}) when is_binary(path) do
    path
    |> Path.dirname()
    |> Path.basename()
    |> String.starts_with?("2-planned")
  end

  def can_handle?(_), do: false

  @impl Arbor.Contracts.Flow.Processor
  def process_item(item, opts \\ []) do
    config = Keyword.get(opts, :config, Config.new())
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("Planned processor checking item",
      title: item.title,
      path: item.path
    )

    cond do
      dry_run ->
        {:ok, :dry_run}

      not auto_enabled?(item) ->
        Logger.debug("Item not marked for auto-processing", title: item.title)
        {:ok, :skipped_not_auto}

      execution_mode(item) == :manual ->
        Logger.debug("Item has manual execution mode", title: item.title)
        {:ok, :skipped_manual}

      max_attempts_reached?(item, config) ->
        Logger.warning("Item has reached max attempts", title: item.title)
        {:ok, :skipped_max_attempts}

      already_has_session?(item) ->
        Logger.debug("Item already has active session", title: item.title)
        {:ok, :skipped_active_session}

      true ->
        spawn_session_for_item(item, config, opts)
    end
  end

  # =============================================================================
  # GenServer Implementation (for managing active sessions)
  # =============================================================================

  @doc """
  Start the planned processor as a supervised GenServer.

  This allows it to track active sessions and enforce concurrency limits.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the current count of active sessions.
  """
  def active_session_count(server \\ __MODULE__) do
    GenServer.call(server, :active_session_count)
  end

  @doc """
  Check if we can spawn a new session (under concurrency limit).
  """
  def can_spawn_session?(server \\ __MODULE__) do
    GenServer.call(server, :can_spawn_session?)
  end

  @doc """
  Register a new session with the processor.
  """
  def register_session(server \\ __MODULE__, item_path, session_id, runner_pid) do
    GenServer.call(server, {:register_session, item_path, session_id, runner_pid})
  end

  @doc """
  Unregister a session (called on completion).
  """
  def unregister_session(server \\ __MODULE__, session_id) do
    GenServer.cast(server, {:unregister_session, session_id})
  end

  @impl GenServer
  def init(opts) do
    config = Keyword.get(opts, :config, Config.new())

    state = %__MODULE__{
      config: config,
      active_sessions: %{},
      session_monitors: %{}
    }

    Logger.info("Planned processor started",
      max_concurrent: Config.max_concurrent_sessions()
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:active_session_count, _from, state) do
    {:reply, map_size(state.active_sessions), state}
  end

  @impl GenServer
  def handle_call(:can_spawn_session?, _from, state) do
    max = Config.max_concurrent_sessions()
    current = map_size(state.active_sessions)
    {:reply, current < max, state}
  end

  @impl GenServer
  def handle_call({:register_session, item_path, session_id, runner_pid}, _from, state) do
    max = Config.max_concurrent_sessions()
    current = map_size(state.active_sessions)

    if current >= max do
      {:reply, {:error, :at_capacity}, state}
    else
      # Monitor the runner process
      ref = Process.monitor(runner_pid)

      new_sessions = Map.put(state.active_sessions, session_id, %{
        item_path: item_path,
        runner_pid: runner_pid,
        started_at: DateTime.utc_now()
      })

      new_monitors = Map.put(state.session_monitors, ref, session_id)

      Logger.info("Session registered",
        session_id: session_id,
        item_path: item_path,
        active_count: map_size(new_sessions)
      )

      {:reply, :ok, %{state | active_sessions: new_sessions, session_monitors: new_monitors}}
    end
  end

  @impl GenServer
  def handle_cast({:unregister_session, session_id}, state) do
    case Map.get(state.active_sessions, session_id) do
      nil ->
        {:noreply, state}

      _session_info ->
        new_sessions = Map.delete(state.active_sessions, session_id)
        new_monitors = remove_session_monitor(state.session_monitors, session_id)

        Logger.info("Session unregistered",
          session_id: session_id,
          active_count: map_size(new_sessions)
        )

        {:noreply, %{state | active_sessions: new_sessions, session_monitors: new_monitors}}
    end
  end

  defp remove_session_monitor(monitors, session_id) do
    case Enum.find(monitors, fn {_ref, sid} -> sid == session_id end) do
      {ref, _sid} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitors, ref)

      nil ->
        monitors
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.session_monitors, ref) do
      nil ->
        {:noreply, state}

      session_id ->
        Logger.info("Session runner process down", session_id: session_id)

        new_sessions = Map.delete(state.active_sessions, session_id)
        new_monitors = Map.delete(state.session_monitors, ref)

        {:noreply, %{state | active_sessions: new_sessions, session_monitors: new_monitors}}
    end
  end

  # =============================================================================
  # Internal Functions
  # =============================================================================

  defp auto_enabled?(item) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    # Check both atom and string keys
    Map.get(metadata, :auto, Map.get(metadata, "auto", false)) == true
  end

  defp execution_mode(item) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    mode = Map.get(metadata, :execution_mode, Map.get(metadata, "execution_mode", "auto"))

    case mode do
      "auto" -> :auto
      "hand" -> :hand
      "manual" -> :manual
      :auto -> :auto
      :hand -> :hand
      :manual -> :manual
      _ -> :auto
    end
  end

  defp max_attempts_reached?(item, config) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    attempt = Map.get(metadata, :attempt, Map.get(metadata, "attempt", 0)) || 0
    max_attempts = Map.get(metadata, :max_attempts, Map.get(metadata, "max_attempts", 2)) || 2
    max_global = config.max_deliberation_attempts

    attempt >= min(max_attempts, max_global)
  end

  defp already_has_session?(item) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    session_id = Map.get(metadata, :session_id, Map.get(metadata, "session_id"))
    session_id != nil
  end

  defp spawn_session_for_item(item, config, opts) do
    # Check concurrency limit
    processor_server = Keyword.get(opts, :processor_server, __MODULE__)

    if can_spawn_session?(processor_server) do
      do_spawn_session(item, config, opts, processor_server)
    else
      Logger.info("At session capacity, delaying spawn", title: item.title)
      {:ok, :delayed_at_capacity}
    end
  end

  defp do_spawn_session(item, config, opts, processor_server) do
    mode = execution_mode(item)

    Logger.info("Spawning session for item",
      title: item.title,
      execution_mode: mode
    )

    Events.emit_processing_started(item, :planned, execution_mode: mode)

    # Build prompt from item
    prompt = build_prompt(item, config)

    # Start the session runner
    runner_opts = [
      item_path: item.path,
      prompt: prompt,
      parent: self(),
      execution_mode: mode,
      config: config,
      working_dir: Keyword.get(opts, :working_dir, File.cwd!())
    ]

    expected_path = item.path

    case SessionRunner.start_link(runner_opts) do
      {:ok, runner_pid} ->
        # Wait for session_started message
        receive do
          {:session_started, ^expected_path, session_id} ->
            # Register with processor
            :ok = register_session(processor_server, item.path, session_id, runner_pid)

            # Update item frontmatter and move to in_progress
            updated_item = update_item_for_session(item, session_id)
            move_result = move_to_in_progress(updated_item, config)

            Events.emit_session_spawned(item, session_id, mode)

            case move_result do
              {:ok, new_path} ->
                {:ok, {:spawned, session_id, new_path}}

              {:error, reason} ->
                {:error, {:move_failed, reason}}
            end

          {:session_error, ^expected_path, reason} ->
            Logger.error("Session failed to start",
              title: item.title,
              reason: inspect(reason)
            )

            Events.emit_processing_failed(item, :planned, reason, retryable: true)
            {:error, {:spawn_failed, reason}}
        after
          30_000 ->
            Logger.error("Timeout waiting for session to start", title: item.title)
            SessionRunner.stop(runner_pid)
            {:error, :spawn_timeout}
        end

      {:error, reason} ->
        Logger.error("Failed to start session runner",
          title: item.title,
          reason: inspect(reason)
        )

        {:error, {:runner_failed, reason}}
    end
  end

  defp build_prompt(item, _config) do
    """
    # Work Item: #{item.title}

    ## Summary

    #{item.summary || "No summary provided."}

    ## Acceptance Criteria

    #{format_criteria(item.acceptance_criteria)}

    ## Definition of Done

    #{format_criteria(item.definition_of_done)}

    #{if item.notes, do: "## Notes\n\n#{item.notes}", else: ""}

    ## Task

    Implement this work item according to the acceptance criteria and definition of done.
    When finished, ensure all tests pass and code quality checks pass.
    """
  end

  defp format_criteria([]), do: "None specified."

  defp format_criteria(criteria) when is_list(criteria) do
    criteria
    |> Enum.map(fn
      %{text: text} -> "- [ ] #{text}"
      text when is_binary(text) -> "- [ ] #{text}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_criteria(_), do: "None specified."

  defp update_item_for_session(item, session_id) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    attempt = Map.get(metadata, :attempt, Map.get(metadata, "attempt", 0)) || 0

    updated_metadata =
      metadata
      |> Map.put("session_id", session_id)
      |> Map.put("session_started_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("attempt", attempt + 1)

    struct(item, metadata: updated_metadata)
  end

  defp move_to_in_progress(item, config) do
    # Serialize the updated item
    content = ItemParser.serialize(Map.from_struct(item))

    # Calculate paths
    filename = Path.basename(item.path)
    dest_dir = Pipeline.stage_path(:in_progress, config.roadmap_root)
    dest_path = Path.join(dest_dir, filename)

    # Ensure destination exists
    File.mkdir_p!(dest_dir)

    # Write to new location
    case File.write(dest_path, content) do
      :ok ->
        # Delete old file
        if item.path != dest_path and File.exists?(item.path) do
          File.rm(item.path)
        end

        Events.emit_item_moved(item, :planned, :in_progress,
          old_path: item.path,
          new_path: dest_path
        )

        {:ok, dest_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Serialize an item back to markdown.
  """
  @spec serialize_item(Item.t()) :: String.t()
  def serialize_item(%Item{} = item) do
    item
    |> Map.from_struct()
    |> ItemParser.serialize()
  end
end
