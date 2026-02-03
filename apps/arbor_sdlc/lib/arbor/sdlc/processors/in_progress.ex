defmodule Arbor.SDLC.Processors.InProgress do
  @moduledoc """
  Detects session completion and handles result processing.

  The InProgress processor:
  - Subscribes to session completion signals from Claude Code hooks
  - Runs tests and quality checks on completed sessions
  - Moves items to completed or back to planned based on results
  - Handles blocked sessions (max_turns reached)

  ## Pipeline Stage

  Handles: `in_progress` -> `completed` | `planned`

  ## Completion Detection

  Sessions are detected as complete via:
  1. `SessionEnd` hook signals from Claude Code
  2. `SubagentStop` signals for Hand sessions
  3. Summary file detection for Hand sessions

  The processor subscribes to `claude.session_end` signals and correlates
  them to work items via the `ARBOR_SDLC_ITEM_PATH` environment variable
  that was set when the session was spawned.

  ## Result Processing

  On session completion:
  1. Read session output or Hand summary
  2. Run configured tests (default: `mix test`)
  3. Run quality checks (default: `mix quality`)
  4. If tests pass: move to completed with summary
  5. If tests fail: move back to planned with failure notes

  ## Blocked Sessions

  When a session hits max_turns:
  1. Mark item as blocked in frontmatter
  2. Emit signal for human attention
  3. Item stays in in_progress for review
  """

  use GenServer

  @behaviour Arbor.Contracts.Flow.Processor

  require Logger

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Events, Pipeline}
  alias Arbor.SDLC.Processors.Planned
  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @processor_id "sdlc_in_progress"

  defstruct [
    :config,
    :subscription_id,
    :pending_completions
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
    |> String.starts_with?("3-in-progress")
  end

  def can_handle?(_), do: false

  @impl Arbor.Contracts.Flow.Processor
  def process_item(item, opts \\ []) do
    # Manual processing: check for completion and process
    config = Keyword.get(opts, :config, Config.new())
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("InProgress processor checking item",
      title: item.title,
      path: item.path
    )

    if dry_run do
      {:ok, :dry_run}
    else
      check_and_process_completion(item, config, opts)
    end
  end

  # =============================================================================
  # GenServer Implementation
  # =============================================================================

  @doc """
  Start the in-progress processor as a supervised GenServer.

  The processor subscribes to session completion signals and processes
  them asynchronously.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually trigger completion handling for a session.

  Used when hook signals arrive.
  """
  def handle_session_end(server \\ __MODULE__, session_id, reason, metadata) do
    GenServer.cast(server, {:session_end, session_id, reason, metadata})
  end

  @doc """
  Process a completed session for an item.
  """
  def process_completion(server \\ __MODULE__, item_path, session_id, output) do
    GenServer.call(server, {:process_completion, item_path, session_id, output}, 600_000)
  end

  @impl GenServer
  def init(opts) do
    config = Keyword.get(opts, :config, Config.new())

    state = %__MODULE__{
      config: config,
      subscription_id: nil,
      pending_completions: %{}
    }

    # Subscribe to session signals
    send(self(), :subscribe_to_signals)

    Logger.info("InProgress processor started")

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:subscribe_to_signals, state) do
    # Subscribe to Claude session_end signals
    case subscribe_to_session_signals() do
      {:ok, sub_id} ->
        Logger.info("Subscribed to session signals", subscription_id: sub_id)
        {:noreply, %{state | subscription_id: sub_id}}

      {:error, reason} ->
        Logger.warning("Failed to subscribe to signals, will retry",
          reason: inspect(reason)
        )

        # Retry subscription after delay
        Process.send_after(self(), :subscribe_to_signals, 5_000)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:session_started, item_path, session_id}, state) do
    # Track that we're expecting a completion for this session
    pending = Map.put(state.pending_completions, session_id, %{
      item_path: item_path,
      started_at: DateTime.utc_now()
    })

    {:noreply, %{state | pending_completions: pending}}
  end

  @impl GenServer
  def handle_info({:session_complete, item_path, session_id, output}, state) do
    Logger.info("Session completed",
      session_id: session_id,
      item_path: item_path
    )

    # Process the completion asynchronously
    Task.Supervisor.start_child(Arbor.SDLC.TaskSupervisor, fn ->
      do_process_completion(item_path, session_id, output, state.config)
    end)

    # Remove from pending
    pending = Map.delete(state.pending_completions, session_id)

    # Unregister from Planned processor
    Planned.unregister_session(session_id)

    {:noreply, %{state | pending_completions: pending}}
  end

  @impl GenServer
  def handle_info({:session_error, item_path, reason}, state) do
    Logger.warning("Session error",
      item_path: item_path,
      reason: inspect(reason)
    )

    # Handle error - increment attempt counter
    Task.Supervisor.start_child(Arbor.SDLC.TaskSupervisor, fn ->
      handle_session_error(item_path, reason, state.config)
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:session_end, session_id, reason, metadata}, state) do
    Logger.info("Received session_end signal",
      session_id: session_id,
      reason: reason
    )

    # Find the item path from metadata or pending completions
    item_path =
      Map.get(metadata, "item_path") ||
        Map.get(metadata, :item_path) ||
        get_in(state.pending_completions, [session_id, :item_path])

    if item_path do
      case reason do
        "completed" ->
          # Session finished normally
          output = Map.get(metadata, "output", "")
          send(self(), {:session_complete, item_path, session_id, output})

        "max_turns" ->
          # Session hit turn limit - blocked
          handle_blocked_session(item_path, session_id, state.config)

        "user_request" ->
          # User interrupted - may need follow-up
          handle_interrupted_session(item_path, session_id, metadata, state.config)

        _ ->
          # Unknown reason, treat as completion
          output = Map.get(metadata, "output", "")
          send(self(), {:session_complete, item_path, session_id, output})
      end
    else
      Logger.warning("Received session_end but no item_path found",
        session_id: session_id
      )
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:process_completion, item_path, session_id, output}, _from, state) do
    result = do_process_completion(item_path, session_id, output, state.config)
    {:reply, result, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Unsubscribe from signals
    if state.subscription_id do
      Arbor.Signals.unsubscribe(state.subscription_id)
    end

    :ok
  end

  # =============================================================================
  # Signal Subscription
  # =============================================================================

  defp subscribe_to_session_signals do
    # Check if signals module is loaded and the Bus process is running
    signals_available? =
      Code.ensure_loaded?(Arbor.Signals) and
        function_exported?(Arbor.Signals, :subscribe, 3) and
        Process.whereis(Arbor.Signals.Bus) != nil

    if signals_available? do
      handler = fn signal ->
        # Extract session_id and reason from signal data
        session_id = get_in(signal.data, [:session_id]) || get_in(signal.data, ["session_id"])
        reason = get_in(signal.data, [:reason]) || get_in(signal.data, ["reason"]) || "completed"

        # Notify the processor
        handle_session_end(__MODULE__, session_id, reason, signal.data)
        :ok
      end

      Arbor.Signals.subscribe("claude.session_end", handler)
    else
      {:error, :signals_not_available}
    end
  end

  # =============================================================================
  # Completion Processing
  # =============================================================================

  defp check_and_process_completion(item, config, _opts) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    session_id = Map.get(metadata, :session_id, Map.get(metadata, "session_id"))

    cond do
      session_id == nil ->
        # No session, nothing to check
        {:ok, :no_session}

      hand_session?(session_id) ->
        # Check for Hand completion via summary.md
        check_hand_completion(item, session_id, config)

      true ->
        # Auto session - rely on signals
        {:ok, :awaiting_signal}
    end
  end

  defp hand_session?(session_id) do
    String.starts_with?(session_id, "hand-")
  end

  defp check_hand_completion(item, session_id, config) do
    # Extract hand name from session_id
    hand_name = String.replace_prefix(session_id, "hand-", "")

    if Hands.summary_exists?(hand_name) do
      Logger.info("Hand summary found, processing completion",
        hand_name: hand_name,
        item_path: item.path
      )

      case Hands.read_summary(hand_name) do
        {:ok, summary} ->
          do_process_completion(item.path, session_id, summary, config)

        {:error, reason} ->
          {:error, {:summary_read_failed, reason}}
      end
    else
      # Check if hand is still running
      case Hands.find_hand(hand_name) do
        :not_found ->
          # Hand stopped without summary
          Logger.warning("Hand stopped without summary", hand_name: hand_name)
          handle_session_error(item.path, :no_summary, config)

        _ ->
          # Hand still running
          {:ok, :still_running}
      end
    end
  end

  defp do_process_completion(item_path, session_id, output, config) do
    Logger.info("Processing session completion",
      item_path: item_path,
      session_id: session_id
    )

    # Load the current item
    case File.read(item_path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        process_completed_item(item_map, item_path, session_id, output, config)

      {:error, :enoent} ->
        # Item may have been moved already
        Logger.warning("Item file not found", item_path: item_path)
        {:error, :item_not_found}

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  defp process_completed_item(item_map, item_path, session_id, output, config) do
    Events.emit_session_completed(item_path, session_id)

    # Run tests and quality checks
    test_result = run_tests(config)
    quality_result = run_quality_checks(config)

    case {test_result, quality_result} do
      {:ok, :ok} ->
        # Success! Move to completed
        move_to_completed(item_map, item_path, session_id, output, config)

      {test_result, quality_result} ->
        # Failure - move back to planned
        handle_test_failure(item_map, item_path, session_id, test_result, quality_result, config)
    end
  end

  defp run_tests(config) do
    Logger.info("Running tests")

    _timeout = Config.session_test_timeout()
    test_command = "mix test"

    case System.cmd("sh", ["-c", test_command], stderr_to_stdout: true, cd: config.roadmap_root) do
      {_output, 0} ->
        Logger.info("Tests passed")
        :ok

      {output, exit_code} ->
        Logger.warning("Tests failed", exit_code: exit_code)
        {:error, {:test_failed, exit_code, String.slice(output, 0, 2000)}}
    end
  rescue
    e ->
      Logger.error("Test execution failed", error: Exception.message(e))
      {:error, {:test_exception, Exception.message(e)}}
  end

  defp run_quality_checks(config) do
    Logger.info("Running quality checks")

    case System.cmd("sh", ["-c", "mix quality"], stderr_to_stdout: true, cd: config.roadmap_root) do
      {_output, 0} ->
        Logger.info("Quality checks passed")
        :ok

      {output, exit_code} ->
        Logger.warning("Quality checks failed", exit_code: exit_code)
        {:error, {:quality_failed, exit_code, String.slice(output, 0, 2000)}}
    end
  rescue
    e ->
      Logger.error("Quality check execution failed", error: Exception.message(e))
      {:error, {:quality_exception, Exception.message(e)}}
  end

  defp move_to_completed(item_map, item_path, _session_id, output, config) do
    Logger.info("Moving item to completed", item_path: item_path)

    # Update metadata
    metadata = Map.get(item_map, :metadata, %{}) || %{}

    updated_metadata =
      metadata
      |> Map.put("completed_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("session_output_summary", String.slice(output, 0, 500))
      |> Map.delete("session_id")
      |> Map.delete("session_started_at")

    updated_item = Map.put(item_map, :metadata, updated_metadata)

    # Serialize and move
    content = ItemParser.serialize(updated_item)
    filename = Path.basename(item_path)
    dest_dir = Pipeline.stage_path(:completed, config.roadmap_root)
    dest_path = Path.join(dest_dir, filename)

    File.mkdir_p!(dest_dir)

    case File.write(dest_path, content) do
      :ok ->
        if item_path != dest_path and File.exists?(item_path) do
          File.rm(item_path)
        end

        Events.emit_item_moved(updated_item, :in_progress, :completed,
          old_path: item_path,
          new_path: dest_path
        )

        Events.emit_item_completed(updated_item, :completed)

        Logger.info("Item completed successfully",
          title: Map.get(item_map, :title),
          new_path: dest_path
        )

        {:ok, {:completed, dest_path}}

      {:error, reason} ->
        {:error, {:move_failed, reason}}
    end
  end

  defp handle_test_failure(item_map, item_path, session_id, test_result, quality_result, config) do
    Logger.warning("Session completed but checks failed",
      item_path: item_path,
      test_result: inspect(test_result),
      quality_result: inspect(quality_result)
    )

    # Update metadata with failure info
    metadata = Map.get(item_map, :metadata, %{}) || %{}
    attempt = Map.get(metadata, :attempt, Map.get(metadata, "attempt", 1)) || 1

    failure_notes = build_failure_notes(test_result, quality_result)

    updated_metadata =
      metadata
      |> Map.put("last_failure", failure_notes)
      |> Map.put("last_failure_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.delete("session_id")
      |> Map.delete("session_started_at")

    updated_item = Map.put(item_map, :metadata, updated_metadata)

    # Move back to planned
    content = ItemParser.serialize(updated_item)
    filename = Path.basename(item_path)
    dest_dir = Pipeline.stage_path(:planned, config.roadmap_root)
    dest_path = Path.join(dest_dir, filename)

    File.mkdir_p!(dest_dir)

    case File.write(dest_path, content) do
      :ok ->
        if item_path != dest_path and File.exists?(item_path) do
          File.rm(item_path)
        end

        Events.emit_item_moved(updated_item, :in_progress, :planned,
          old_path: item_path,
          new_path: dest_path
        )

        Events.emit_session_failed(item_path, session_id, :checks_failed)

        Logger.info("Item moved back to planned for retry",
          title: Map.get(item_map, :title),
          attempt: attempt
        )

        {:ok, {:retry, dest_path}}

      {:error, reason} ->
        {:error, {:move_failed, reason}}
    end
  end

  defp build_failure_notes(test_result, quality_result) do
    parts = []

    parts =
      case test_result do
        {:error, {:test_failed, code, output}} ->
          ["Tests failed (exit #{code}): #{String.slice(output, 0, 500)}" | parts]

        {:error, reason} ->
          ["Tests error: #{inspect(reason)}" | parts]

        _ ->
          parts
      end

    parts =
      case quality_result do
        {:error, {:quality_failed, code, output}} ->
          ["Quality failed (exit #{code}): #{String.slice(output, 0, 500)}" | parts]

        {:error, reason} ->
          ["Quality error: #{inspect(reason)}" | parts]

        _ ->
          parts
      end

    Enum.join(parts, "\n")
  end

  # =============================================================================
  # Error and Special Case Handling
  # =============================================================================

  defp handle_session_error(item_path, reason, _config) do
    Logger.warning("Handling session error",
      item_path: item_path,
      reason: inspect(reason)
    )

    case File.read(item_path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        metadata = Map.get(item_map, :metadata, %{}) || %{}

        updated_metadata =
          metadata
          |> Map.put("last_error", inspect(reason))
          |> Map.put("last_error_at", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.delete("session_id")
          |> Map.delete("session_started_at")

        updated_item = Map.put(item_map, :metadata, updated_metadata)

        # Stay in place but update file
        content = ItemParser.serialize(updated_item)
        File.write!(item_path, content)

        {:ok, :error_recorded}

      {:error, _} ->
        {:error, :item_not_found}
    end
  end

  defp handle_blocked_session(item_path, session_id, _config) do
    Logger.warning("Session blocked (max_turns reached)",
      item_path: item_path,
      session_id: session_id
    )

    case File.read(item_path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        metadata = Map.get(item_map, :metadata, %{}) || %{}

        updated_metadata =
          metadata
          |> Map.put("blocked", true)
          |> Map.put("blocked_at", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put("blocked_reason", "max_turns_reached")

        updated_item = Map.put(item_map, :metadata, updated_metadata)

        # Write updated item (stays in in_progress)
        content = ItemParser.serialize(updated_item)
        File.write!(item_path, content)

        Events.emit_session_blocked(item_path, session_id, "max_turns")

        {:ok, :blocked}

      {:error, _} ->
        {:error, :item_not_found}
    end
  end

  defp handle_interrupted_session(item_path, session_id, metadata, _config) do
    Logger.info("Session interrupted",
      item_path: item_path,
      session_id: session_id
    )

    # For interrupted sessions, we keep the session_id for potential resume
    Events.emit_session_interrupted(item_path, session_id, metadata)

    {:ok, :interrupted}
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
