defmodule Arbor.Agent.Claude do
  @moduledoc """
  Claude Code agent integration for Arbor.

  This module provides the runtime integration between Claude Code and Arbor,
  including:

  - Query execution via AgentSDK
  - Thinking extraction from session files
  - Full memory system integration (recall, index, working memory)
  - Signal emission for agent activities
  - Heartbeat loop for autonomous background processing
  - Context window management with persistence

  ## Architecture

  Claude Code runs as an external process (the CLI), but this module makes it
  a first-class Arbor citizen by:

  1. Wrapping queries through `Arbor.AI.AgentSDK`
  2. Extracting thinking blocks from session files after each query
  3. Recalling relevant memories before each query
  4. Indexing important facts from responses
  5. Maintaining working memory across the conversation
  6. Emitting signals for significant events
  7. Running periodic heartbeats for background checks and reflection

  ## Usage

      # Start the agent
      {:ok, agent} = Arbor.Agent.Claude.start_link(id: "claude-main")

      # Send a query (automatically recalls relevant memories)
      {:ok, response} = Arbor.Agent.Claude.query(agent, "What is 2+2?")

      # Get memories recalled for the last query
      {:ok, memories} = Arbor.Agent.Claude.get_recalled_memories(agent)

      # Get captured thinking
      {:ok, blocks} = Arbor.Agent.Claude.get_thinking(agent)
  """

  use GenServer
  use Arbor.Agent.HeartbeatLoop

  require Logger

  alias Arbor.Agent.{CognitivePrompts, ContextManager, TimingContext}
  alias Arbor.AI.AgentSDK
  alias Arbor.AI.SessionReader

  @type option ::
          {:id, String.t()}
          | {:model, atom()}
          | {:capture_thinking, boolean()}
          | {:memory_enabled, boolean()}

  @type t :: GenServer.server()

  # Agent ID used for memory operations
  @default_id "claude-code"

  # How many memories to recall per query
  @default_recall_limit 5

  # Consolidation check interval (every N queries)
  @consolidation_check_interval 10

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
  - `:heartbeat_interval_ms` - Heartbeat interval in ms (default: 30_000)
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

  ## Returns

  The response map includes:
  - `:text` - The text response
  - `:thinking` - Captured thinking blocks (if any)
  - `:session_id` - Session ID for reference
  - `:recalled_memories` - Memories that were recalled for context
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(agent, prompt, opts \\ []) do
    GenServer.call(agent, {:query, prompt, opts}, Keyword.get(opts, :timeout, 180_000))
  end

  @doc """
  Stream a query response with real-time callbacks.

  Callbacks receive events:
  - `{:text, chunk}` - Text chunk
  - `{:thinking, block}` - Thinking block (if captured)
  - `{:memories, list}` - Recalled memories
  - `{:complete, response}` - Final response
  """
  @spec stream(t(), String.t(), (term() -> any()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(agent, prompt, callback, opts \\ []) when is_function(callback, 1) do
    GenServer.call(agent, {:stream, prompt, callback, opts}, Keyword.get(opts, :timeout, 180_000))
  end

  @doc """
  Get thinking blocks from the most recent session.
  """
  @spec get_thinking(t()) :: {:ok, [map()]} | {:error, term()}
  def get_thinking(agent) do
    GenServer.call(agent, :get_thinking)
  end

  @doc """
  Get memories recalled for the last query.
  """
  @spec get_recalled_memories(t()) :: {:ok, [map()]} | {:error, term()}
  def get_recalled_memories(agent) do
    GenServer.call(agent, :get_recalled_memories)
  end

  @doc """
  Get the current working memory.
  """
  @spec get_working_memory(t()) :: {:ok, map() | nil} | {:error, term()}
  def get_working_memory(agent) do
    GenServer.call(agent, :get_working_memory)
  end

  @doc """
  Get the agent's ID.
  """
  @spec agent_id(t()) :: String.t()
  def agent_id(agent) do
    GenServer.call(agent, :agent_id)
  end

  @doc """
  Get the agent's current session ID.
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(agent) do
    GenServer.call(agent, :session_id)
  end

  @doc """
  Get memory statistics for this agent.
  """
  @spec memory_stats(t()) :: {:ok, map()} | {:error, term()}
  def memory_stats(agent) do
    GenServer.call(agent, :memory_stats)
  end

  @doc """
  Execute an Arbor action through the capability-based authorization system.

  Routes action execution through `Arbor.Actions.authorize_and_execute/4`,
  which checks capabilities before running. The agent must have the appropriate
  `arbor://actions/execute/{action_name}` capability granted.

  ## Parameters

  - `agent` - The agent process
  - `action_module` - The action module (e.g., `Arbor.Actions.File.Read`)
  - `params` - Parameters to pass to the action
  - `opts` - Options (default: [])
    - `:bypass_auth` - Skip authorization (for trusted system calls)

  ## Returns

  - `{:ok, result}` - Action executed successfully
  - `{:error, :unauthorized}` - Agent lacks required capability
  - `{:ok, :pending_approval, proposal_id}` - Requires escalation
  - `{:error, reason}` - Action failed

  ## Examples

      {:ok, result} = Claude.execute_action(agent, Arbor.Actions.File.Read, %{path: "/tmp/test.txt"})
      {:ok, result} = Claude.execute_action(agent, Arbor.Actions.Shell.Execute, %{command: "ls -la"})
  """
  @spec execute_action(t(), module(), map(), keyword()) ::
          {:ok, any()} | {:ok, :pending_approval, String.t()} | {:error, term()}
  def execute_action(agent, action_module, params, opts \\ []) do
    GenServer.call(agent, {:execute_action, action_module, params, opts}, 60_000)
  end

  @doc """
  List available actions the agent can execute.

  Returns a map of action categories to action modules.
  """
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

  @doc """
  Get all actions as LLM tool schemas.

  Useful for providing available tools to the Claude CLI.
  """
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
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id, @default_id)
    default_model = Keyword.get(opts, :model, :sonnet)
    capture_thinking = Keyword.get(opts, :capture_thinking, true)
    memory_enabled = Keyword.get(opts, :memory_enabled, true)

    # Initialize memory system for this agent
    memory_initialized =
      if memory_enabled do
        init_memory_system(id)
      else
        false
      end

    # Load working memory if available
    working_memory =
      if memory_initialized do
        load_working_memory(id)
      else
        nil
      end

    # Grant capabilities from template (non-fatal if security unavailable)
    grant_template_capabilities(id)

    # Initialize context window via ContextManager
    {:ok, context_window} = ContextManager.init_context(id, opts)

    state = %{
      id: id,
      default_model: default_model,
      capture_thinking: capture_thinking,
      memory_enabled: memory_enabled,
      memory_initialized: memory_initialized,
      working_memory: working_memory,
      last_session_id: nil,
      thinking_cache: [],
      recalled_memories: [],
      query_count: 0,
      # Temporal awareness
      last_user_message_at: nil,
      last_assistant_output_at: nil,
      responded_to_last_user_message: true
    }

    # Initialize heartbeat loop (adds heartbeat fields, schedules first tick)
    heartbeat_opts =
      Keyword.merge(opts,
        heartbeat_enabled: Keyword.get(opts, :heartbeat_enabled, true) and memory_initialized,
        context_window: context_window
      )

    state = init_heartbeat(state, heartbeat_opts)

    Logger.info("Claude agent started",
      id: id,
      model: default_model,
      memory_enabled: memory_enabled,
      memory_initialized: memory_initialized,
      heartbeat_enabled: state.heartbeat_enabled
    )

    emit_signal(:agent_started, %{
      id: id,
      memory_enabled: memory_enabled,
      memory_initialized: memory_initialized,
      heartbeat_enabled: state.heartbeat_enabled
    })

    {:ok, state}
  end

  @impl true
  def handle_call({:query, prompt, opts}, _from, state) do
    # If busy with heartbeat, queue the message and respond when done
    if state.busy do
      state = queue_message(state, prompt, opts)
      {:reply, {:error, :busy}, state}
    else
      handle_query(prompt, opts, state)
    end
  end

  def handle_call({:stream, prompt, callback, opts}, _from, state) do
    if state.busy do
      state = queue_message(state, prompt, opts)
      {:reply, {:error, :busy}, state}
    else
      handle_stream(prompt, callback, opts, state)
    end
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
        get_memory_stats(state.id)
      else
        %{enabled: false}
      end

    {:reply, {:ok, stats}, state}
  end

  def handle_call({:execute_action, action_module, params, opts}, _from, state) do
    bypass_auth = Keyword.get(opts, :bypass_auth, false)

    result =
      if bypass_auth do
        execute_action_direct(action_module, params)
      else
        execute_action_authorized(state.id, action_module, params)
      end

    emit_action_signal(state.id, action_module, result)

    {:reply, result, state}
  end

  @impl true
  def handle_info(msg, state) do
    case handle_heartbeat_info(msg, state) do
      {:noreply, new_state} ->
        {:noreply, new_state}

      {:heartbeat_triggered, new_state} ->
        run_heartbeat_async(new_state)
        {:noreply, new_state}

      :not_handled ->
        handle_other_info(msg, state)
    end
  end

  @impl true
  def terminate(reason, state) do
    # Cancel heartbeat timer
    cancel_heartbeat(state)

    # Save context window before shutdown
    if state[:context_window] do
      ContextManager.save_context(state.id, state.context_window)
    end

    # Save working memory before shutdown
    if state.memory_initialized and state.working_memory do
      save_working_memory(state.id, state.working_memory)
    end

    Logger.info("Claude agent stopping", id: state.id, reason: inspect(reason))
    emit_signal(:agent_stopped, %{id: state.id, query_count: state.query_count})
    :ok
  end

  # ============================================================================
  # HeartbeatLoop Callback
  # ============================================================================

  @impl Arbor.Agent.HeartbeatLoop
  def run_heartbeat_cycle(state, _body) do
    # Determine cognitive mode for this heartbeat
    mode = determine_cognitive_mode(state)

    # Run background checks (memory health, consolidation)
    background_result = run_background_checks(state)

    actions =
      if is_map(background_result) do
        Map.get(background_result, :actions, [])
      else
        []
      end

    # Build metadata with cognitive mode info
    metadata = %{
      cognitive_mode: mode,
      background_actions: length(actions)
    }

    {:ok, actions, %{}, state[:context_window], nil, metadata}
  end

  # ============================================================================
  # Private: Heartbeat Helpers
  # ============================================================================

  defp run_heartbeat_async(state) do
    host_pid = self()
    body = Map.get(state, :body, %{})

    Task.start(fn ->
      result =
        try do
          run_heartbeat_cycle(state, body)
        rescue
          e ->
            Logger.warning("Heartbeat cycle error: #{Exception.message(e)}")
            {:error, {:heartbeat_exception, Exception.message(e)}}
        catch
          :exit, reason ->
            Logger.warning("Heartbeat cycle exit: #{inspect(reason)}")
            {:error, {:heartbeat_exit, reason}}
        end

      send(host_pid, {:heartbeat_complete, result})
    end)
  end

  defp determine_cognitive_mode(state) do
    cond do
      # If user is waiting, stay in conversation mode
      user_waiting?(state) ->
        :conversation

      # Roll for idle reflection
      idle_reflection_enabled?() and :rand.uniform() < idle_reflection_chance() ->
        Enum.random([:introspection, :reflection, :pattern_analysis, :insight_detection])

      # Default: consolidation during background time
      true ->
        :consolidation
    end
  end

  defp user_waiting?(state) do
    timing = TimingContext.compute(state)
    timing.user_waiting
  end

  defp idle_reflection_enabled? do
    Application.get_env(:arbor_agent, :idle_reflection_enabled, true)
  end

  defp idle_reflection_chance do
    Application.get_env(:arbor_agent, :idle_reflection_chance, 0.3)
  end

  defp handle_other_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private: Query Handling (extracted from handle_call)
  # ============================================================================

  defp handle_query(prompt, opts, state) do
    # Track user message timing
    state = TimingContext.on_user_message(state)

    model = Keyword.get(opts, :model, state.default_model)
    capture = Keyword.get(opts, :capture_thinking, should_capture_thinking?(model, state))
    recall = Keyword.get(opts, :recall_memories, true) and state.memory_initialized
    index = Keyword.get(opts, :index_response, true) and state.memory_initialized

    recalled =
      if recall do
        recall_memories(state.id, prompt)
      else
        []
      end

    case execute_query(prompt, model, capture, state, opts) do
      {:ok, response, new_state} ->
        new_state = TimingContext.on_agent_output(new_state)

        if index do
          index_response(state.id, prompt, response.text)
        end

        new_state = update_working_memory(new_state, prompt, response.text)
        new_state = maybe_consolidate(new_state)

        # Add to context window
        new_state = add_to_context_window(new_state, prompt, response.text)

        enhanced_response = Map.put(response, :recalled_memories, recalled)
        new_state = %{new_state | recalled_memories: recalled}

        {:reply, {:ok, enhanced_response}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp handle_stream(prompt, callback, opts, state) do
    state = TimingContext.on_user_message(state)

    model = Keyword.get(opts, :model, state.default_model)
    capture = Keyword.get(opts, :capture_thinking, should_capture_thinking?(model, state))
    recall = Keyword.get(opts, :recall_memories, true) and state.memory_initialized
    index = Keyword.get(opts, :index_response, true) and state.memory_initialized

    recalled =
      if recall do
        memories = recall_memories(state.id, prompt)
        if memories != [], do: callback.({:memories, memories})
        memories
      else
        []
      end

    case execute_stream(prompt, callback, model, capture, state, opts) do
      {:ok, response, new_state} ->
        new_state = TimingContext.on_agent_output(new_state)

        if index do
          index_response(state.id, prompt, response.text)
        end

        new_state = update_working_memory(new_state, prompt, response.text)
        new_state = maybe_consolidate(new_state)
        new_state = add_to_context_window(new_state, prompt, response.text)

        enhanced_response = Map.put(response, :recalled_memories, recalled)
        new_state = %{new_state | recalled_memories: recalled}

        {:reply, {:ok, enhanced_response}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp add_to_context_window(%{context_window: nil} = state, _prompt, _response), do: state

  defp add_to_context_window(%{context_window: window} = state, prompt, response) do
    if Code.ensure_loaded?(Arbor.Memory.ContextWindow) and
         function_exported?(Arbor.Memory.ContextWindow, :add_entry, 3) do
      window =
        window
        |> Arbor.Memory.ContextWindow.add_entry(:message, "Human: #{prompt}")
        |> Arbor.Memory.ContextWindow.add_entry(:message, "Assistant: #{response}")

      %{state | context_window: window}
    else
      state
    end
  rescue
    _ -> state
  end

  # ============================================================================
  # Memory System Integration
  # ============================================================================

  defp init_memory_system(agent_id) do
    if memory_available?() and memory_registry_running?() do
      case Arbor.Memory.init_for_agent(agent_id) do
        {:ok, _pid} ->
          Logger.info("Memory system initialized", agent_id: agent_id)
          true

        {:error, {:already_started, _pid}} ->
          Logger.debug("Memory system already running", agent_id: agent_id)
          true

        {:error, reason} ->
          Logger.warning("Failed to initialize memory: #{inspect(reason)}")
          false
      end
    else
      Logger.debug("Memory system not available or not running")
      false
    end
  rescue
    e ->
      Logger.debug("Memory system initialization failed: #{Exception.message(e)}")
      false
  end

  defp grant_template_capabilities(agent_id) do
    if security_available?() do
      alias Arbor.Agent.Templates.ClaudeCode

      capabilities = ClaudeCode.required_capabilities()

      Enum.each(capabilities, fn cap ->
        grant_single_capability(agent_id, cap.resource)
      end)

      Logger.info("Granted #{length(capabilities)} capabilities", agent_id: agent_id)
    else
      Logger.debug("Security system not available, skipping capability grants")
    end
  rescue
    e ->
      Logger.debug("Capability grant failed: #{Exception.message(e)}")
  end

  defp grant_single_capability(agent_id, resource) do
    case Arbor.Security.grant(principal: agent_id, resource: resource) do
      {:ok, _cap} ->
        Logger.debug("Granted capability", agent_id: agent_id, resource: resource)
        :ok

      {:error, reason} ->
        Logger.debug("Failed to grant capability: #{inspect(reason)}")
        :error
    end
  rescue
    _ -> :error
  end

  defp security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :grant, 1) and
      Process.whereis(Arbor.Security.SystemAuthority) != nil
  end

  defp memory_registry_running? do
    Process.whereis(Arbor.Memory.Registry) != nil or
      Process.whereis(Arbor.Memory.IndexSupervisor) != nil
  rescue
    _ -> false
  end

  defp load_working_memory(agent_id) do
    wm = Arbor.Memory.load_working_memory(agent_id)
    Logger.debug("Loaded working memory", agent_id: agent_id)
    wm
  rescue
    e ->
      Logger.warning("Error loading working memory: #{Exception.message(e)}")
      nil
  end

  defp save_working_memory(agent_id, working_memory) do
    Arbor.Memory.save_working_memory(agent_id, working_memory)
    Logger.debug("Saved working memory", agent_id: agent_id)
    :ok
  rescue
    e ->
      Logger.warning("Error saving working memory: #{Exception.message(e)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("Working memory save timeout or exit: #{inspect(reason)}")
      :error
  end

  defp recall_memories(agent_id, query) do
    case Arbor.Memory.recall(agent_id, query, limit: @default_recall_limit) do
      {:ok, memories} ->
        Logger.debug("Recalled #{length(memories)} memories",
          agent_id: agent_id,
          query_preview: String.slice(query, 0..50)
        )

        memories

      {:error, reason} ->
        Logger.debug("Memory recall failed: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.warning("Error recalling memories: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.warning("Memory recall timeout or exit: #{inspect(reason)}")
      []
  end

  defp index_response(agent_id, prompt, response_text) do
    content = "Q: #{String.slice(prompt, 0..200)}\nA: #{String.slice(response_text, 0..500)}"

    metadata = %{
      type: :conversation,
      timestamp: DateTime.utc_now(),
      prompt_length: String.length(prompt),
      response_length: String.length(response_text)
    }

    case Arbor.Memory.index(agent_id, content, metadata) do
      {:ok, entry_id} ->
        Logger.debug("Indexed conversation", agent_id: agent_id, entry_id: entry_id)
        :ok

      {:error, reason} ->
        Logger.debug("Failed to index response: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.warning("Error indexing response: #{Exception.message(e)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("Memory index timeout or exit: #{inspect(reason)}")
      :error
  end

  defp update_working_memory(state, prompt, response) do
    if state.memory_initialized and state.working_memory do
      thought =
        "User asked: #{String.slice(prompt, 0..100)}... " <>
          "I responded: #{String.slice(response, 0..200)}..."

      working_memory =
        Arbor.Memory.WorkingMemory.add_thought(
          state.working_memory,
          thought,
          priority: :medium
        )

      %{state | working_memory: working_memory}
    else
      state
    end
  rescue
    _ -> state
  end

  defp maybe_consolidate(state) do
    if state.memory_initialized and
         rem(state.query_count + 1, @consolidation_check_interval) == 0 do
      case Arbor.Memory.should_consolidate?(state.id) do
        true ->
          Logger.info("Running memory consolidation", agent_id: state.id)

          spawn(fn ->
            Arbor.Memory.run_consolidation(state.id)
          end)

        false ->
          :ok
      end
    end

    state
  rescue
    _ -> state
  end

  defp run_background_checks(state) do
    if background_checks_available?() do
      result = Arbor.Memory.BackgroundChecks.run(state.id, skip_patterns: true)

      Enum.each(result.warnings, fn warning ->
        Logger.info("Background check warning: #{warning.message}",
          agent_id: state.id,
          type: warning.type,
          severity: warning.severity
        )
      end)

      Enum.each(result.actions, fn action ->
        case action.type do
          :run_consolidation ->
            spawn(fn -> Arbor.Memory.run_consolidation(state.id) end)

          other ->
            Logger.debug("Background check action: #{other}", agent_id: state.id)
        end
      end)

      emit_signal(:heartbeat_complete, %{
        id: state.id,
        action_count: length(result.actions),
        warning_count: length(result.warnings),
        suggestion_count: length(result.suggestions)
      })

      result
    else
      %{actions: [], warnings: [], suggestions: []}
    end
  rescue
    e ->
      Logger.warning("Background checks failed: #{Exception.message(e)}")
      %{actions: [], warnings: [], suggestions: []}
  catch
    :exit, reason ->
      Logger.warning("Background checks timeout: #{inspect(reason)}")
      %{actions: [], warnings: [], suggestions: []}
  end

  defp background_checks_available? do
    Code.ensure_loaded?(Arbor.Memory.BackgroundChecks) and
      function_exported?(Arbor.Memory.BackgroundChecks, :run, 2)
  end

  defp get_memory_stats(agent_id) do
    index_stats =
      case Arbor.Memory.index_stats(agent_id) do
        {:ok, stats} -> stats
        _ -> %{}
      end

    knowledge_stats =
      case Arbor.Memory.knowledge_stats(agent_id) do
        {:ok, stats} -> stats
        _ -> %{}
      end

    %{
      enabled: true,
      index: index_stats,
      knowledge: knowledge_stats
    }
  rescue
    _ -> %{enabled: true, error: "Failed to get stats"}
  end

  defp memory_available? do
    Code.ensure_loaded?(Arbor.Memory) and
      function_exported?(Arbor.Memory, :init_for_agent, 1)
  end

  # ============================================================================
  # Query Execution
  # ============================================================================

  defp should_capture_thinking?(model, state) do
    model == :opus or state.capture_thinking
  end

  defp execute_query(prompt, model, capture, state, opts) do
    enhanced_prompt = maybe_add_timing_context(prompt, state)

    case AgentSDK.query(enhanced_prompt, Keyword.merge(opts, model: model)) do
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
    enhanced_prompt = maybe_add_timing_context(prompt, state)

    case AgentSDK.stream(enhanced_prompt, callback, Keyword.merge(opts, model: model)) do
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

  defp maybe_add_timing_context(prompt, state) do
    if Application.get_env(:arbor_agent, :timing_context_enabled, true) do
      timing_markdown =
        state
        |> TimingContext.compute()
        |> TimingContext.to_markdown()

      # Add cognitive mode prompt if in non-conversation mode
      mode = determine_cognitive_mode(state)

      mode_prompt =
        if function_exported?(CognitivePrompts, :prompt_for, 1) do
          CognitivePrompts.prompt_for(mode)
        else
          ""
        end

      parts = [prompt, timing_markdown]
      parts = if mode_prompt != "", do: parts ++ [mode_prompt], else: parts

      Enum.join(parts, "\n\n")
    else
      prompt
    end
  end

  defp resolve_thinking(response, true, state) do
    capture_thinking_from_session(response.session_id, state)
  end

  defp resolve_thinking(response, false, _state) do
    {response.thinking, response.session_id}
  end

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
    emit_signal(:query_completed, %{
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
    Code.ensure_loaded?(Arbor.Memory.Thinking) and
      Process.whereis(Arbor.Memory.Thinking) != nil
  end

  defp record_single_thinking(agent_id, block) do
    text = block.text || block[:text] || ""
    opts = if block.signature, do: [metadata: %{signature: block.signature}], else: []

    result = Arbor.Memory.Thinking.record_thinking(agent_id, text, opts)

    case result do
      {:ok, _entry} -> :ok
      {:error, reason} -> Logger.warning("Failed to record thinking: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # Action Execution
  # ============================================================================

  defp actions_available? do
    Code.ensure_loaded?(Arbor.Actions) and
      function_exported?(Arbor.Actions, :authorize_and_execute, 4)
  end

  defp execute_action_authorized(agent_id, action_module, params) do
    if actions_available?() do
      Arbor.Actions.authorize_and_execute(agent_id, action_module, params)
    else
      {:error, :actions_unavailable}
    end
  rescue
    e -> {:error, {:action_exception, Exception.message(e)}}
  end

  defp execute_action_direct(action_module, params) do
    if actions_available?() do
      Arbor.Actions.execute_action(action_module, params)
    else
      {:error, :actions_unavailable}
    end
  rescue
    e -> {:error, {:action_exception, Exception.message(e)}}
  end

  defp emit_action_signal(agent_id, action_module, result) do
    outcome =
      case result do
        {:ok, _} -> :success
        {:ok, :pending_approval, _} -> :pending
        {:error, :unauthorized} -> :unauthorized
        {:error, _} -> :failure
      end

    emit_signal(:action_executed, %{
      agent_id: agent_id,
      action: action_module_name(action_module),
      outcome: outcome
    })
  end

  defp action_module_name(module) when is_atom(module) do
    module |> Module.split() |> Enum.take(-2) |> Enum.join(".")
  end

  defp action_module_name(module), do: inspect(module)

  # ============================================================================
  # Signal Emission
  # ============================================================================

  defp emit_signal(event, data) do
    if signals_available?() do
      Arbor.Signals.emit(:agent, event, data)
    end
  rescue
    _ -> :ok
  end

  defp signals_available? do
    Code.ensure_loaded?(Arbor.Signals) and
      Process.whereis(Arbor.Signals.Bus) != nil
  end
end
