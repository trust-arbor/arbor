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

  alias Arbor.SDLC.{Config, Events}
  alias Arbor.SDLC.Processors.InProgress.CompletionProcessing
  alias Arbor.SDLC.Processors.Planned

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
      CompletionProcessing.check_and_process_completion(item, config, opts)
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
        CompletionProcessing.resume_session(item_path, session_id, response, state.config)

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
      CompletionProcessing.do_process_completion(item_path, session_id, output, state.config)
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
      CompletionProcessing.handle_session_error(item_path, reason, state.config)
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
          CompletionProcessing.handle_blocked_session(item_path, session_id, state.config)

        "user_request" ->
          # User interrupted - may need follow-up
          CompletionProcessing.handle_interrupted_session(item_path, session_id, metadata, state.config)

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
    result = CompletionProcessing.do_process_completion(item_path, session_id, output, state.config)
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
  # Delegated to CompletionProcessing
  # =============================================================================

  @doc """
  Serialize an item back to markdown.
  """
  defdelegate serialize_item(item), to: CompletionProcessing
end
