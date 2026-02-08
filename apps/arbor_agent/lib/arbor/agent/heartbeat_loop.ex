defmodule Arbor.Agent.HeartbeatLoop do
  @moduledoc """
  Heartbeat loop that drives agent autonomy.

  Provides:
  - Periodic heartbeat scheduling
  - Busy state management (skip/queue during processing)
  - Message queueing during busy heartbeats
  - Context window management
  - Non-blocking execution via Task

  ## Usage

  Include in a GenServer-based agent:

      defmodule MyAgent do
        use GenServer
        use Arbor.Agent.HeartbeatLoop

        def init(opts) do
          state = %{agent_id: "my-agent"}
          {:ok, init_heartbeat(state, opts)}
        end

        @impl Arbor.Agent.HeartbeatLoop
        def run_heartbeat_cycle(state, _body) do
          # Do work...
          {:ok, [], %{}, nil}
        end
      end

  The agent must implement the `run_heartbeat_cycle/2` callback.
  """

  require Logger

  @type heartbeat_result ::
          {:ok, actions :: list(), updated_body :: map()}
          | {:ok, actions :: list(), updated_body :: map(), context_window :: map() | nil}
          | {:ok, actions :: list(), updated_body :: map(), context_window :: map() | nil,
             system_prompt :: String.t()}
          | {:ok, actions :: list(), updated_body :: map(), context_window :: map() | nil,
             system_prompt :: String.t(), response_metadata :: map()}
          | {:error, reason :: term()}

  @doc """
  Called when the heartbeat fires.

  Receives the current agent state and body map. Should return
  a result tuple with actions taken, updated body, and optionally
  context window, system prompt, and response metadata.
  """
  @callback run_heartbeat_cycle(state :: map(), body :: map()) :: heartbeat_result()

  defmacro __using__(_opts) do
    quote do
      @behaviour Arbor.Agent.HeartbeatLoop

      import Arbor.Agent.HeartbeatLoop,
        only: [
          init_heartbeat: 2,
          handle_heartbeat_info: 2,
          schedule_heartbeat: 1,
          cancel_heartbeat: 1,
          queue_message: 3,
          queue_message: 2,
          process_pending_messages: 1
        ]
    end
  end

  @doc """
  Initialize heartbeat state from opts.
  Call this in your agent's init/1.

  Merges heartbeat-specific fields into the existing state map.
  Returns the updated state (does NOT schedule the first heartbeat;
  the caller should call `schedule_heartbeat/1` after init is complete).
  """
  @spec init_heartbeat(map(), keyword()) :: map()
  def init_heartbeat(state, opts) do
    heartbeat_enabled =
      Keyword.get(opts, :heartbeat_enabled, config(:heartbeat_enabled, true))

    heartbeat_interval =
      Keyword.get(opts, :heartbeat_interval_ms, config(:heartbeat_interval_ms, 10_000))

    state =
      Map.merge(state, %{
        heartbeat_enabled: heartbeat_enabled,
        heartbeat_interval: heartbeat_interval,
        busy: false,
        last_heartbeat_at: nil,
        pending_messages: [],
        context_window: Keyword.get(opts, :context_window),
        heartbeat_timer_ref: nil
      })

    if heartbeat_enabled do
      ref = schedule_heartbeat(state)
      %{state | heartbeat_timer_ref: ref}
    else
      state
    end
  end

  @doc """
  Handle heartbeat-related messages.
  Call this from your agent's handle_info/2.

  Returns:
  - `{:noreply, state}` — message was handled (busy/disabled)
  - `{:heartbeat_triggered, state}` — heartbeat should run
  - `:not_handled` — message is not heartbeat-related
  """
  @spec handle_heartbeat_info(atom() | tuple(), map()) ::
          {:noreply, map()} | {:heartbeat_triggered, map()} | :not_handled
  def handle_heartbeat_info(:heartbeat, %{busy: true} = state) do
    Logger.debug("Heartbeat skipped: agent is busy")
    ref = schedule_heartbeat(state)
    {:noreply, %{state | heartbeat_timer_ref: ref}}
  end

  def handle_heartbeat_info(:heartbeat, %{heartbeat_enabled: false} = state) do
    {:noreply, state}
  end

  def handle_heartbeat_info(:heartbeat, state) do
    state = %{state | busy: true, last_heartbeat_at: DateTime.utc_now()}
    {:heartbeat_triggered, state}
  end

  def handle_heartbeat_info({:heartbeat_complete, result}, state) do
    state = process_heartbeat_result(result, state)
    state = process_pending_messages(state)
    ref = schedule_heartbeat(state)
    {:noreply, %{state | busy: false, heartbeat_timer_ref: ref}}
  end

  def handle_heartbeat_info(_msg, _state), do: :not_handled

  @doc """
  Schedule the next heartbeat. Returns the timer reference.
  """
  @spec schedule_heartbeat(map()) :: reference()
  def schedule_heartbeat(%{heartbeat_interval: interval}) do
    Process.send_after(self(), :heartbeat, interval)
  end

  @doc """
  Cancel pending heartbeat timer.
  """
  @spec cancel_heartbeat(map()) :: :ok
  def cancel_heartbeat(%{heartbeat_timer_ref: nil}), do: :ok

  def cancel_heartbeat(%{heartbeat_timer_ref: ref}) do
    Process.cancel_timer(ref)
    :ok
  end

  @doc """
  Queue a message to be processed after the current heartbeat.
  Returns updated state.
  """
  @spec queue_message(map(), String.t(), keyword()) :: map()
  def queue_message(state, message, opts \\ []) do
    max_size = config(:message_queue_max_size, 100)

    if length(state.pending_messages) >= max_size do
      Logger.warning("Message queue full, dropping oldest",
        agent_id: state[:agent_id] || state[:id],
        queue_size: length(state.pending_messages)
      )

      pending = Enum.drop(state.pending_messages, 1) ++ [{message, opts}]
      %{state | pending_messages: pending}
    else
      %{state | pending_messages: state.pending_messages ++ [{message, opts}]}
    end
  end

  @doc """
  Process pending messages after heartbeat completes.
  Adds queued messages to the context window if available.
  """
  @spec process_pending_messages(map()) :: map()
  def process_pending_messages(%{pending_messages: []} = state), do: state

  def process_pending_messages(%{pending_messages: _pending, context_window: nil} = state) do
    Logger.debug("Clearing pending messages (no context window)")
    %{state | pending_messages: []}
  end

  def process_pending_messages(%{pending_messages: pending, context_window: window} = state) do
    Logger.debug("Processing pending messages", count: length(pending))

    updated_window =
      Enum.reduce(pending, window, fn
        {msg, opts}, win ->
          speaker = Keyword.get(opts, :speaker, "Human")
          add_message_to_window(win, msg, speaker)

        msg, win when is_binary(msg) ->
          add_message_to_window(win, msg, "Human")
      end)

    %{state | context_window: updated_window, pending_messages: []}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp process_heartbeat_result({:ok, actions, body, window, prompt, metadata}, state) do
    emit_heartbeat_signal(state, actions, metadata)
    sync_context_window(state, window)
    update_temporal_state(state, body, window, prompt, metadata)
  end

  defp process_heartbeat_result({:ok, actions, body, window, _prompt}, state) do
    emit_heartbeat_signal(state, actions, nil)
    sync_context_window(state, window)
    %{state | context_window: window} |> maybe_put_body(body)
  end

  defp process_heartbeat_result({:ok, actions, body, window}, state) do
    emit_heartbeat_signal(state, actions, nil)
    sync_context_window(state, window)
    %{state | context_window: window} |> maybe_put_body(body)
  end

  defp process_heartbeat_result({:ok, actions, body}, state) do
    emit_heartbeat_signal(state, actions, nil)
    maybe_put_body(state, body)
  end

  defp process_heartbeat_result({:error, reason}, state) do
    Logger.warning("Heartbeat cycle failed", reason: inspect(reason))
    state
  end

  defp update_temporal_state(state, body, window, _prompt, metadata) do
    timing_updates =
      if has_meaningful_output?(metadata) do
        %{
          last_assistant_output_at: DateTime.utc_now(),
          responded_to_last_user_message: true
        }
      else
        %{}
      end

    state
    |> maybe_put_body(body)
    |> Map.put(:context_window, window)
    |> Map.merge(timing_updates)
  end

  defp has_meaningful_output?(nil), do: false

  defp has_meaningful_output?(metadata) do
    output = Map.get(metadata, :output, "")
    is_binary(output) and String.trim(output) != ""
  end

  defp maybe_put_body(state, body) when is_map(body) and map_size(body) > 0 do
    Map.put(state, :body, body)
  end

  defp maybe_put_body(state, _body), do: state

  defp emit_heartbeat_signal(state, actions, metadata) do
    signal_data = %{
      agent_id: state[:agent_id] || state[:id],
      actions_taken: length(actions || []),
      timestamp: DateTime.utc_now()
    }

    signal_data =
      if metadata do
        Map.merge(signal_data, %{
          agent_output: metadata[:output],
          agent_thinking: metadata[:thinking],
          cognitive_mode: metadata[:cognitive_mode],
          llm_actions: metadata[:llm_actions],
          memory_notes_count: metadata[:memory_notes_count],
          goal_updates_count: metadata[:goal_updates_count],
          usage: metadata[:usage]
        })
      else
        signal_data
      end

    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 4) and
         Process.whereis(Arbor.Signals.Bus) != nil do
      agent_id = signal_data[:agent_id]
      meta = if agent_id, do: %{agent_id: agent_id}, else: %{}
      Arbor.Signals.emit(:agent, :heartbeat_complete, signal_data, metadata: meta)
    end
  rescue
    _ -> :ok
  end

  defp sync_context_window(_state, nil), do: :ok

  defp sync_context_window(state, window) do
    if config(:context_persistence_enabled, true) do
      agent_id = state[:agent_id] || state[:id]

      if agent_id && Code.ensure_loaded?(Arbor.Memory.ContextWindow) do
        serialized = Arbor.Memory.ContextWindow.serialize(window)
        path = context_window_path(agent_id)
        dir = Path.dirname(path)
        File.mkdir_p!(dir)
        File.write!(path, Jason.encode!(serialized))
      end
    end
  rescue
    e ->
      Logger.debug("Failed to sync context window: #{Exception.message(e)}")
      :ok
  end

  defp add_message_to_window(window, message, speaker) do
    if Code.ensure_loaded?(Arbor.Memory.ContextWindow) and
         function_exported?(Arbor.Memory.ContextWindow, :add_entry, 3) do
      Arbor.Memory.ContextWindow.add_entry(window, :message, "#{speaker}: #{message}")
    else
      window
    end
  end

  defp context_window_path(agent_id) do
    base = Application.get_env(:arbor_agent, :context_window_dir, "~/.arbor/context_windows")
    safe_id = String.replace(agent_id, ~r/[^a-zA-Z0-9_-]/, "_")
    Path.expand(base) |> Path.join("#{safe_id}.json")
  end

  defp config(key, default) do
    Application.get_env(:arbor_agent, key, default)
  end
end
