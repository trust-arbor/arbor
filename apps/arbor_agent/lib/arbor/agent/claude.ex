defmodule Arbor.Agent.Claude do
  @moduledoc """
  Claude Code Host — the execution environment for a Claude agent in Arbor.

  This is a Host in the Seed/Host architecture. Portable identity (memory,
  signals, executor, heartbeat logic) lives in `Arbor.Agent.AgentSeed`.
  This module provides only Claude-specific functionality:

  - Query execution via `Arbor.AI.AgentSDK`
  - Thinking extraction from session files
  - Checkpoint persistence
  - LLM think cycle delegation to `HeartbeatLLM`

  ## Usage

      {:ok, agent} = Arbor.Agent.Claude.start_link(id: "claude-main")
      {:ok, response} = Arbor.Agent.Claude.query(agent, "What is 2+2?")
  """

  use GenServer
  use Arbor.Agent.HeartbeatLoop
  use Arbor.Agent.AgentSeed

  require Logger

  alias Arbor.Agent.{
    CheckpointManager,
    HeartbeatLLM,
    HeartbeatResponse,
    TimingContext
  }

  alias Arbor.AI.AgentSDK
  alias Arbor.AI.SessionReader
  alias Arbor.Memory.Thinking

  @type option ::
          {:id, String.t()}
          | {:model, atom()}
          | {:capture_thinking, boolean()}
          | {:memory_enabled, boolean()}

  @type t :: GenServer.server()

  @default_id "claude-code"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the Claude agent.

  ## Options

  - `:id` - Agent identifier (default: "claude-code")
  - `:model` - Default model to use (default: :sonnet)
  - `:capture_thinking` - Enable thinking capture (default: true)
  - `:memory_enabled` - Enable memory system (default: true)
  - `:heartbeat_enabled` - Enable heartbeat loop (default: true)
  - `:heartbeat_interval_ms` - Heartbeat interval in ms (default: 10_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Send a query to Claude and get a response.

  Before sending the query, relevant memories are recalled and can be
  included in the context. After receiving the response, important facts
  are indexed to memory.

  ## Options

  - `:model` - Model to use (`:opus`, `:sonnet`, `:haiku`)
  - `:capture_thinking` - Extract thinking from session file (default: true for opus)
  - `:timeout` - Response timeout in ms
  - `:recall_memories` - Whether to recall memories (default: true)
  - `:index_response` - Whether to index response facts (default: true)
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(agent, prompt, opts \\ []) do
    GenServer.call(agent, {:query, prompt, opts}, Keyword.get(opts, :timeout, :infinity))
  end

  @doc """
  Stream a query response with real-time callbacks.
  """
  @spec stream(t(), String.t(), (term() -> any()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(agent, prompt, callback, opts \\ []) when is_function(callback, 1) do
    GenServer.call(agent, {:stream, prompt, callback, opts}, Keyword.get(opts, :timeout, :infinity))
  end

  @doc "Get thinking blocks from the most recent session."
  @spec get_thinking(t()) :: {:ok, [map()]} | {:error, term()}
  def get_thinking(agent), do: GenServer.call(agent, :get_thinking)

  @doc "Get memories recalled for the last query."
  @spec get_recalled_memories(t()) :: {:ok, [map()]} | {:error, term()}
  def get_recalled_memories(agent), do: GenServer.call(agent, :get_recalled_memories)

  @doc "Get the current working memory."
  @spec get_working_memory(t()) :: {:ok, map() | nil} | {:error, term()}
  def get_working_memory(agent), do: GenServer.call(agent, :get_working_memory)

  @doc "Get the agent's ID."
  @spec agent_id(t()) :: String.t()
  def agent_id(agent), do: GenServer.call(agent, :agent_id)

  @doc "Get the agent's current session ID."
  @spec session_id(t()) :: String.t() | nil
  def session_id(agent), do: GenServer.call(agent, :session_id)

  @doc "Get memory statistics for this agent."
  @spec memory_stats(t()) :: {:ok, map()} | {:error, term()}
  def memory_stats(agent), do: GenServer.call(agent, :memory_stats)

  @doc """
  Execute an Arbor action through the capability-based authorization system.
  """
  @spec execute_action(t(), module(), map(), keyword()) ::
          {:ok, any()} | {:ok, :pending_approval, String.t()} | {:error, term()}
  def execute_action(agent, action_module, params, opts \\ []) do
    GenServer.call(agent, {:execute_action, action_module, params, opts}, 60_000)
  end

  @doc "List available actions the agent can execute."
  @spec list_actions() :: %{atom() => [module()]}
  def list_actions do
    if actions_available?() do
      Arbor.Actions.list_actions()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  @doc "Get all actions as LLM tool schemas."
  @spec get_tools() :: [map()]
  def get_tools do
    if actions_available?() do
      Arbor.Actions.all_tools()
    else
      []
    end
  rescue
    _ -> []
  end

  # ============================================================================
  # AgentSeed Callback
  # ============================================================================

  @impl Arbor.Agent.AgentSeed
  def seed_think(state, mode) do
    run_llm_think_cycle(state, mode)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id, @default_id)

    # Host-specific state
    host_state = %{
      default_model: Keyword.get(opts, :model, :sonnet),
      capture_thinking: Keyword.get(opts, :capture_thinking, true),
      last_session_id: nil,
      thinking_cache: [],
      # Checkpoint tracking
      last_checkpoint_query_count: 0,
      checkpoint_timer_ref: nil
    }

    # Initialize seed (memory, executor, signals, working memory, capabilities)
    seed_opts =
      opts
      |> Keyword.put(:seed_module, __MODULE__)
      |> Keyword.put_new(:id, id)

    state = init_seed(host_state, seed_opts)

    # Attempt checkpoint restore
    state =
      if checkpoint_enabled?() do
        case CheckpointManager.load_checkpoint(id) do
          {:ok, checkpoint_data} ->
            CheckpointManager.apply_checkpoint(state, checkpoint_data)

          {:error, _} ->
            state
        end
      else
        state
      end

    # Initialize heartbeat loop
    heartbeat_opts =
      Keyword.merge(opts,
        heartbeat_enabled:
          Keyword.get(opts, :heartbeat_enabled, true) and state.memory_initialized,
        context_window: state.context_window
      )

    state = init_heartbeat(state, heartbeat_opts)

    # Schedule auto-checkpoint
    state =
      if checkpoint_enabled?() do
        ref = CheckpointManager.schedule_checkpoint()
        %{state | checkpoint_timer_ref: ref}
      else
        state
      end

    Logger.info("Claude agent started",
      id: id,
      model: state.default_model,
      memory_enabled: state.memory_enabled,
      memory_initialized: state.memory_initialized,
      heartbeat_enabled: state.heartbeat_enabled,
      executor: state.executor_pid != nil,
      checkpoint_restored: state.query_count > 0
    )

    seed_emit_signal(:agent_started, %{
      id: id,
      memory_enabled: state.memory_enabled,
      memory_initialized: state.memory_initialized,
      heartbeat_enabled: state.heartbeat_enabled,
      executor_started: state.executor_pid != nil
    })

    {:ok, state}
  end

  @impl true
  def handle_call({:query, prompt, opts}, _from, state) do
    handle_query(prompt, opts, state)
  end

  def handle_call({:stream, prompt, callback, opts}, _from, state) do
    handle_stream(prompt, callback, opts, state)
  end

  def handle_call(:get_thinking, _from, state) do
    {:reply, {:ok, state.thinking_cache}, state}
  end

  def handle_call(:get_recalled_memories, _from, state) do
    {:reply, {:ok, state.recalled_memories}, state}
  end

  def handle_call(:get_working_memory, _from, state) do
    {:reply, {:ok, state.working_memory}, state}
  end

  def handle_call(:agent_id, _from, state) do
    {:reply, state.id, state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.last_session_id, state}
  end

  def handle_call(:memory_stats, _from, state) do
    stats =
      if state.memory_initialized do
        seed_memory_stats(state.id)
      else
        %{enabled: false}
      end

    {:reply, {:ok, stats}, state}
  end

  def handle_call({:execute_action, action_module, params, opts}, _from, state) do
    result = execute_seed_action(state.id, action_module, params, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_info(msg, state) do
    # Chain: heartbeat → seed → host
    case handle_heartbeat_info(msg, state) do
      {:noreply, new_state} ->
        {:noreply, new_state}

      {:heartbeat_triggered, new_state} ->
        seed_heartbeat_async(new_state)
        {:noreply, new_state}

      :not_handled ->
        case seed_handle_info(msg, state) do
          {:noreply, new_state} ->
            {:noreply, new_state}

          :not_handled ->
            handle_host_info(msg, state)
        end
    end
  end

  @impl true
  def terminate(reason, state) do
    # Cancel heartbeat timer
    cancel_heartbeat(state)

    # Cancel checkpoint timer
    if state[:checkpoint_timer_ref] do
      Process.cancel_timer(state.checkpoint_timer_ref)
    end

    # Final checkpoint save
    if checkpoint_enabled?() do
      CheckpointManager.save_checkpoint(state)
    end

    # Seed cleanup (save WM, context, stop executor)
    seed_terminate(reason, state)
  end

  # ============================================================================
  # HeartbeatLoop Callback
  # ============================================================================

  @impl Arbor.Agent.HeartbeatLoop
  def run_heartbeat_cycle(state, body) do
    seed_heartbeat_cycle(state, body)
  end

  # ============================================================================
  # Private: Host-Specific Info Handling
  # ============================================================================

  defp handle_host_info(:checkpoint, state) do
    if checkpoint_enabled?() do
      CheckpointManager.save_checkpoint(state, async: true)
    end

    ref = CheckpointManager.schedule_checkpoint()

    {:noreply,
     %{state | checkpoint_timer_ref: ref, last_checkpoint_query_count: state.query_count}}
  end

  defp handle_host_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private: LLM Think Cycle (Host-specific)
  # ============================================================================

  defp run_llm_think_cycle(state, mode) do
    think_fn =
      if user_waiting?(state) do
        fn -> {:ok, HeartbeatResponse.empty_response()} end
      else
        case mode do
          :conversation ->
            fn -> {:ok, HeartbeatResponse.empty_response()} end

          m when m in [:introspection, :reflection, :pattern_analysis, :insight_detection] ->
            fn -> HeartbeatLLM.idle_think(state) end

          _ ->
            fn -> HeartbeatLLM.think(state) end
        end
      end

    case think_fn.() do
      {:ok, parsed} ->
        {parsed, Map.get(parsed, :thinking, ""), Map.get(parsed, :memory_notes, []),
         Map.get(parsed, :goal_updates, [])}

      {:error, _reason} ->
        {HeartbeatResponse.empty_response(), "", [], []}
    end
  end

  defp user_waiting?(state) do
    timing = TimingContext.compute(state)
    timing.user_waiting
  end

  # ============================================================================
  # Private: Query Handling (Host-specific — uses AgentSDK)
  # ============================================================================

  defp handle_query(prompt, opts, state) do
    model = Keyword.get(opts, :model, state.default_model)
    capture = Keyword.get(opts, :capture_thinking, should_capture_thinking?(model, state))
    recall = Keyword.get(opts, :recall_memories, true) and state.memory_initialized
    index = Keyword.get(opts, :index_response, true) and state.memory_initialized

    # Seed: prepare query (recall memories, add timing/self-knowledge)
    {enhanced_prompt, recalled, state} = prepare_query(prompt, state)

    recalled = if recall, do: recalled, else: []

    case execute_query(enhanced_prompt, model, capture, state, opts) do
      {:ok, response, new_state} ->
        # Seed: finalize query (index, update WM, consolidate, context window)
        new_state =
          if index do
            finalize_query(prompt, response.text, new_state)
          else
            new_state
          end

        enhanced_response = Map.put(response, :recalled_memories, recalled)
        new_state = %{new_state | recalled_memories: recalled}

        {:reply, {:ok, enhanced_response}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp handle_stream(prompt, callback, opts, state) do
    model = Keyword.get(opts, :model, state.default_model)
    capture = Keyword.get(opts, :capture_thinking, should_capture_thinking?(model, state))
    recall = Keyword.get(opts, :recall_memories, true) and state.memory_initialized
    index = Keyword.get(opts, :index_response, true) and state.memory_initialized

    {enhanced_prompt, recalled, state} = prepare_query(prompt, state)
    recalled = if recall, do: recalled, else: []

    if recalled != [], do: callback.({:memories, recalled})

    case execute_stream(enhanced_prompt, callback, model, capture, state, opts) do
      {:ok, response, new_state} ->
        new_state =
          if index do
            finalize_query(prompt, response.text, new_state)
          else
            new_state
          end

        enhanced_response = Map.put(response, :recalled_memories, recalled)
        new_state = %{new_state | recalled_memories: recalled}

        {:reply, {:ok, enhanced_response}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  # ============================================================================
  # Private: Query Execution (Host-specific — AgentSDK + Session Thinking)
  # ============================================================================

  defp should_capture_thinking?(model, state) do
    model == :opus or state.capture_thinking
  end

  defp execute_query(prompt, model, capture, state, opts) do
    case AgentSDK.query(prompt, Keyword.merge(opts, model: model)) do
      {:ok, response} ->
        {thinking, session_id} = resolve_thinking(response, capture, state)
        maybe_record_thinking(state.id, thinking)
        emit_query_completed(state.id, model, thinking)

        enhanced_response = %{response | thinking: thinking}
        new_state = update_state_after_query(state, session_id, thinking)
        {:ok, enhanced_response, new_state}

      {:error, _} = error ->
        error
    end
  end

  defp execute_stream(prompt, callback, model, capture, state, opts) do
    case AgentSDK.stream(prompt, callback, Keyword.merge(opts, model: model)) do
      {:ok, response} ->
        {thinking, session_id} = resolve_thinking(response, capture, state)
        maybe_record_thinking(state.id, thinking)
        notify_thinking_callback(thinking, callback)

        enhanced_response = %{response | thinking: thinking}
        new_state = update_state_after_query(state, session_id, thinking)
        {:ok, enhanced_response, new_state}

      {:error, _} = error ->
        error
    end
  end

  # Use thinking from the stream response when available.
  # Only fall back to SessionReader if the stream didn't capture thinking.
  defp resolve_thinking(response, true, state) do
    case response.thinking do
      blocks when is_list(blocks) and blocks != [] ->
        {blocks, response.session_id}

      _ ->
        capture_thinking_from_session(response.session_id, state)
    end
  end

  defp resolve_thinking(response, false, _state) do
    {response.thinking, response.session_id}
  end

  # Fallback: read thinking from session JSONL files.
  # Used when the stream didn't include thinking blocks (older CLI versions).
  defp capture_thinking_from_session(nil, _state) do
    case SessionReader.latest_thinking() do
      {:ok, blocks} -> {blocks, nil}
      {:error, _} -> {nil, nil}
    end
  end

  defp capture_thinking_from_session(session_id, _state) do
    case SessionReader.read_thinking(session_id) do
      {:ok, blocks} ->
        {blocks, session_id}

      {:error, _} ->
        case SessionReader.latest_thinking() do
          {:ok, blocks} -> {blocks, session_id}
          {:error, _} -> {nil, session_id}
        end
    end
  end

  defp update_state_after_query(state, session_id, thinking) do
    %{
      state
      | last_session_id: session_id,
        thinking_cache: thinking || [],
        query_count: state.query_count + 1
    }
  end

  defp emit_query_completed(agent_id, model, thinking) do
    seed_emit_signal(:query_completed, %{
      id: agent_id,
      model: model,
      thinking_count: length(thinking || [])
    })
  end

  defp notify_thinking_callback(nil, _callback), do: :ok
  defp notify_thinking_callback([], _callback), do: :ok

  defp notify_thinking_callback(thinking, callback) do
    Enum.each(thinking, fn block ->
      callback.({:thinking, block})
    end)
  end

  defp maybe_record_thinking(_agent_id, nil), do: :ok
  defp maybe_record_thinking(_agent_id, []), do: :ok

  defp maybe_record_thinking(agent_id, thinking_blocks) do
    if memory_thinking_available?() do
      Enum.each(thinking_blocks, &record_single_thinking(agent_id, &1))
    else
      Logger.debug("Memory.Thinking not available, skipping thinking record")
    end
  end

  defp memory_thinking_available? do
    Code.ensure_loaded?(Thinking) and
      Process.whereis(Thinking) != nil
  end

  defp record_single_thinking(agent_id, block) do
    text = block.text || block[:text] || ""
    opts = if block.signature, do: [metadata: %{signature: block.signature}], else: []

    result = Thinking.record_thinking(agent_id, text, opts)

    case result do
      {:ok, _entry} -> :ok
      {:error, reason} -> Logger.warning("Failed to record thinking: #{inspect(reason)}")
    end
  end

  defp checkpoint_enabled? do
    Application.get_env(:arbor_agent, :checkpoint_enabled, true)
  end
end
