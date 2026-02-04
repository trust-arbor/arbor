defmodule Arbor.SDLC.Processors.InProgress do
  @moduledoc """
  Detects session completion and handles result processing.

  The InProgress processor:
  - Subscribes to session completion signals from Claude Code hooks
  - Runs tests and quality checks on completed sessions
  - Moves items to completed or back to planned based on results
  - Handles blocked sessions (max_turns reached)
  - Routes interrupted sessions to comms for human input
  - Tracks session activity via PostToolUse hooks

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

  ## Interrupted Sessions

  When a session is interrupted (user_request reason):
  1. Route message to comms for human input
  2. Subscribe to comms response signal
  3. On response, resume session with `--resume <session_id>`

  ## Activity Tracking

  Subscribes to `PostToolUse` hook signals to track session activity:
  - Maintains last activity timestamp per session
  - Emits stale session warning if no activity for configurable duration
  """

  use GenServer

  @behaviour Arbor.Contracts.Flow.Processor

  require Logger

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Events, Pipeline, SessionRunner}
  alias Arbor.SDLC.Processors.Planned
  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @processor_id "sdlc_in_progress"

  # Default stale session threshold: 10 minutes without activity
  @default_stale_threshold_ms 600_000

  defstruct [
    :config,
    :subscription_id,
    :tool_use_subscription_id,
    :pending_completions,
    :session_activity,
    :stale_check_timer,
    :awaiting_comms_responses
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
      tool_use_subscription_id: nil,
      pending_completions: %{},
      session_activity: %{},
      stale_check_timer: nil,
      awaiting_comms_responses: %{}
    }

    # Subscribe to session signals
    send(self(), :subscribe_to_signals)

    # Start periodic stale session check
    timer_ref = schedule_stale_check()

    Logger.info("InProgress processor started")

    {:ok, %{state | stale_check_timer: timer_ref}}
  end

  @impl GenServer
  def handle_info(:subscribe_to_signals, state) do
    # Subscribe to Claude session_end signals
    state =
      case subscribe_to_session_signals() do
        {:ok, sub_id} ->
          Logger.info("Subscribed to session signals", subscription_id: sub_id)
          %{state | subscription_id: sub_id}

        {:error, reason} ->
          Logger.warning("Failed to subscribe to session signals, will retry",
            reason: inspect(reason)
          )

          # Retry subscription after delay
          Process.send_after(self(), :subscribe_to_signals, 5_000)
          state
      end

    # Subscribe to PostToolUse signals for activity tracking
    state =
      case subscribe_to_tool_use_signals() do
        {:ok, sub_id} ->
          Logger.info("Subscribed to tool_used signals", subscription_id: sub_id)
          %{state | tool_use_subscription_id: sub_id}

        {:error, reason} ->
          Logger.debug("Failed to subscribe to tool_used signals",
            reason: inspect(reason)
          )

          state
      end

    # Subscribe to comms response signals for resume handling
    subscribe_to_comms_responses()

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:check_stale_sessions, state) do
    state = check_stale_sessions(state)
    timer_ref = schedule_stale_check()
    {:noreply, %{state | stale_check_timer: timer_ref}}
  end

  @impl GenServer
  def handle_info({:tool_used, session_id, tool_name}, state) do
    # Update activity timestamp for this session
    now = System.monotonic_time(:millisecond)

    activity =
      Map.update(
        state.session_activity,
        session_id,
        %{last_activity: now, tool_count: 1, last_tool: tool_name},
        fn info ->
          %{info | last_activity: now, tool_count: info.tool_count + 1, last_tool: tool_name}
        end
      )

    {:noreply, %{state | session_activity: activity}}
  end

  @impl GenServer
  def handle_info({:comms_response, correlation_id, response}, state) do
    case Map.pop(state.awaiting_comms_responses, correlation_id) do
      {nil, _awaiting} ->
        # Not waiting for this response
        {:noreply, state}

      {{item_path, session_id}, awaiting} ->
        Logger.info("Received comms response for interrupted session",
          item_path: item_path,
          session_id: session_id
        )

        # Resume the session with the response
        resume_session(item_path, session_id, response, state.config)

        {:noreply, %{state | awaiting_comms_responses: awaiting}}
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

  def handle_cast({:await_comms_response, correlation_id, item_path, session_id}, state) do
    awaiting = Map.put(state.awaiting_comms_responses, correlation_id, {item_path, session_id})
    {:noreply, %{state | awaiting_comms_responses: awaiting}}
  end

  @impl GenServer
  def handle_call({:process_completion, item_path, session_id, output}, _from, state) do
    result = do_process_completion(item_path, session_id, output, state.config)
    {:reply, result, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Cancel stale check timer
    if state.stale_check_timer do
      Process.cancel_timer(state.stale_check_timer)
    end

    # Unsubscribe from signals
    if state.subscription_id do
      Arbor.Signals.unsubscribe(state.subscription_id)
    end

    if state.tool_use_subscription_id do
      Arbor.Signals.unsubscribe(state.tool_use_subscription_id)
    end

    :ok
  end

  # =============================================================================
  # Signal Subscription
  # =============================================================================

  defp subscribe_to_session_signals do
    if signals_available?() do
      do_subscribe_to_session_signals()
    else
      {:error, :signals_not_available}
    end
  end

  defp do_subscribe_to_session_signals do
    handler = fn signal ->
      session_id = get_in(signal.data, [:session_id]) || get_in(signal.data, ["session_id"])
      reason = get_in(signal.data, [:reason]) || get_in(signal.data, ["reason"]) || "completed"

      handle_session_end(__MODULE__, session_id, reason, signal.data)
      :ok
    end

    Arbor.Signals.subscribe("claude.session_end", handler)
  end

  defp subscribe_to_tool_use_signals do
    if signals_available?() do
      do_subscribe_to_tool_use()
    else
      {:error, :signals_not_available}
    end
  end

  defp do_subscribe_to_tool_use do
    processor = self()

    handler = fn signal ->
      session_id = get_in(signal.data, [:session_id]) || get_in(signal.data, ["session_id"])
      tool_name = get_in(signal.data, [:tool_name]) || get_in(signal.data, ["tool_name"])

      if session_id, do: send(processor, {:tool_used, session_id, tool_name})
      :ok
    end

    Arbor.Signals.subscribe("claude.tool_used", handler)
  end

  defp subscribe_to_comms_responses do
    if signals_available?() do
      do_subscribe_to_comms_responses()
    else
      :ok
    end
  end

  defp do_subscribe_to_comms_responses do
    processor = self()

    handler = fn signal ->
      correlation_id =
        get_in(signal.data, [:correlation_id]) ||
          get_in(signal.data, ["correlation_id"])

      response =
        get_in(signal.data, [:response]) ||
          get_in(signal.data, ["response"])

      if correlation_id, do: send(processor, {:comms_response, correlation_id, response})
      :ok
    end

    Arbor.Signals.subscribe("comms.response_received", handler)
  end

  defp signals_available? do
    Code.ensure_loaded?(Arbor.Signals) and
      function_exported?(Arbor.Signals, :subscribe, 3) and
      Process.whereis(Arbor.Signals.Bus) != nil
  end

  defp schedule_stale_check do
    # Check every minute for stale sessions
    Process.send_after(self(), :check_stale_sessions, 60_000)
  end

  defp check_stale_sessions(state) do
    now = System.monotonic_time(:millisecond)
    threshold = Application.get_env(:arbor_sdlc, :stale_session_threshold_ms, @default_stale_threshold_ms)

    stale_sessions =
      state.session_activity
      |> Enum.filter(fn {_session_id, info} ->
        now - info.last_activity > threshold
      end)

    # Emit warning for stale sessions
    for {session_id, info} <- stale_sessions do
      item_path = get_in(state.pending_completions, [session_id, :item_path])
      minutes_stale = div(now - info.last_activity, 60_000)

      Logger.warning("Stale session detected",
        session_id: session_id,
        item_path: item_path,
        minutes_without_activity: minutes_stale,
        last_tool: info.last_tool,
        tool_count: info.tool_count
      )

      Events.emit_session_stale(item_path, session_id, minutes_stale)
    end

    state
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

    timeout = Config.session_test_timeout()

    case Arbor.Shell.execute("mix test",
           cwd: config.roadmap_root,
           sandbox: :none,
           timeout: timeout
         ) do
      {:ok, %{exit_code: 0}} ->
        Logger.info("Tests passed")
        :ok

      {:ok, %{exit_code: code, stdout: output}} ->
        Logger.warning("Tests failed", exit_code: code)
        {:error, {:test_failed, code, String.slice(output, 0, 2000)}}

      {:error, reason} ->
        Logger.error("Test execution failed", error: inspect(reason))
        {:error, {:test_exception, inspect(reason)}}
    end
  end

  defp run_quality_checks(config) do
    Logger.info("Running quality checks")

    case Arbor.Shell.execute("mix quality",
           cwd: config.roadmap_root,
           sandbox: :none,
           timeout: 120_000
         ) do
      {:ok, %{exit_code: 0}} ->
        Logger.info("Quality checks passed")
        :ok

      {:ok, %{exit_code: code, stdout: output}} ->
        Logger.warning("Quality checks failed", exit_code: code)
        {:error, {:quality_failed, code, String.slice(output, 0, 2000)}}

      {:error, reason} ->
        Logger.error("Quality check execution failed", error: inspect(reason))
        {:error, {:quality_exception, inspect(reason)}}
    end
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

  defp handle_interrupted_session(item_path, session_id, metadata, config) do
    Logger.info("Session interrupted",
      item_path: item_path,
      session_id: session_id
    )

    # Emit the interrupted event
    Events.emit_session_interrupted(item_path, session_id, metadata)

    # Route to comms for human input
    route_to_comms(item_path, session_id, config)

    {:ok, :interrupted}
  end

  defp route_to_comms(item_path, session_id, _config) do
    # Generate a correlation ID for tracking the response
    correlation_id = "sdlc-resume-#{session_id}-#{System.system_time(:millisecond)}"

    item_name = Path.basename(item_path, ".md")
    message = build_interrupt_message(item_name, session_id, item_path)
    recipient = Application.get_env(:arbor_sdlc, :comms_recipient, nil)

    do_route_to_comms(recipient, message, session_id, correlation_id, item_path)
  end

  defp build_interrupt_message(item_name, session_id, item_path) do
    """
    SDLC session interrupted for work item: #{item_name}

    Session ID: #{session_id}
    Item path: #{item_path}

    The session was interrupted and may need your input to continue.
    Reply to this message to resume the session with your guidance.
    """
  end

  defp do_route_to_comms(nil, _message, _session_id, _correlation_id, _item_path) do
    Logger.debug("No comms recipient configured, skipping comms routing")
  end

  defp do_route_to_comms(recipient, message, session_id, correlation_id, item_path) do
    comms_available? =
      Code.ensure_loaded?(Arbor.Comms) and
        function_exported?(Arbor.Comms, :send_signal, 2)

    if comms_available? do
      send_via_comms(recipient, message, session_id, correlation_id, item_path)
    else
      Logger.debug("Comms not available, skipping comms routing")
    end
  end

  defp send_via_comms(recipient, message, session_id, correlation_id, item_path) do
    # Use Kernel.apply to explicitly indicate dynamic call
    case Kernel.apply(Arbor.Comms, :send_signal, [recipient, message]) do
      :ok ->
        Logger.info("Routed interrupted session to comms",
          session_id: session_id,
          correlation_id: correlation_id
        )

        GenServer.cast(self(), {:await_comms_response, correlation_id, item_path, session_id})

      {:error, reason} ->
        Logger.warning("Failed to route to comms",
          session_id: session_id,
          reason: inspect(reason)
        )
    end
  end

  defp resume_session(item_path, session_id, response, config) do
    Logger.info("Resuming session with human input",
      item_path: item_path,
      session_id: session_id
    )

    # Build resume prompt with the human's response
    prompt = """
    Previous session was interrupted. Human provided the following guidance:

    #{response}

    Please continue working on the task.
    """

    # Resume using SessionRunner
    runner_opts = [
      item_path: item_path,
      prompt: prompt,
      parent: self(),
      execution_mode: :auto,
      config: config,
      working_dir: config.roadmap_root,
      resume_session_id: session_id
    ]

    case SessionRunner.start_link(runner_opts) do
      {:ok, _runner_pid} ->
        Logger.info("Session resume initiated", session_id: session_id)

      {:error, reason} ->
        Logger.error("Failed to resume session",
          session_id: session_id,
          reason: inspect(reason)
        )
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
