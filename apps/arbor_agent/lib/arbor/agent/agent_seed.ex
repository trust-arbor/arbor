defmodule Arbor.Agent.AgentSeed do
  @moduledoc """
  Portable agent identity mixin — the "Seed" from the Seed/Host architecture.

  Provides all portable Seed functions that any agent Host can use:
  memory integration, identity consolidation, signal subscriptions,
  executor wiring, action execution, and heartbeat seed logic.

  The Host provides only one callback: `seed_think/2`, which delegates
  to the Host-specific LLM provider.

  ## Usage

      defmodule MyAgent do
        use GenServer
        use Arbor.Agent.HeartbeatLoop
        use Arbor.Agent.AgentSeed

        @impl Arbor.Agent.AgentSeed
        def seed_think(state, mode) do
          # Host-specific LLM call
          MyLLM.think(state, mode)
        end

        def init(opts) do
          state = init_seed(%{my_field: "host-specific"}, opts)
          state = init_heartbeat(state, opts)
          {:ok, state}
        end

        @impl Arbor.Agent.HeartbeatLoop
        def run_heartbeat_cycle(state, body) do
          seed_heartbeat_cycle(state, body)
        end
      end

  ## Seed State Fields

  The following fields are merged into the agent state map by `init_seed/2`:

  - `id` — Agent identifier
  - `memory_enabled` — Whether memory system is active
  - `memory_initialized` — Whether memory init succeeded
  - `working_memory` — Current working memory struct
  - `recalled_memories` — Memories recalled for last query
  - `query_count` — Total queries processed
  - `heartbeat_count` — Total heartbeat cycles run
  - `last_user_message_at` — Timestamp of last user message
  - `last_assistant_output_at` — Timestamp of last assistant output
  - `responded_to_last_user_message` — Whether agent has responded
  - `executor_pid` — PID of the Executor process (or nil)
  """

  require Logger

  alias Arbor.Agent.{
    CheckpointManager,
    ContextManager,
    ExecutorIntegration,
    TimingContext
  }

  # Constants
  @default_id "agent"
  @default_recall_limit 5
  @consolidation_check_interval 10
  @identity_consolidation_interval 30
  @reflection_interval 60

  @doc """
  Called by the Host to perform an LLM think cycle during heartbeat.

  The Host should delegate to its LLM provider. Returns the same
  tuple format as `HeartbeatLLM.think/1`.

  ## Parameters

  - `state` — Current agent state map
  - `mode` — Cognitive mode atom (`:consolidation`, `:introspection`, etc.)

  ## Returns

  `{parsed_response, thinking_string, memory_notes_list, goal_updates_list}`
  """
  @callback seed_think(state :: map(), mode :: atom()) ::
              {parsed :: map(), thinking :: String.t(), notes :: [String.t()], goals :: [map()]}

  defmacro __using__(_opts) do
    quote do
      @behaviour Arbor.Agent.AgentSeed

      # Store the host module so seed_heartbeat_cycle can call back to seed_think/2
      @seed_host_module __MODULE__

      import Arbor.Agent.AgentSeed,
        only: [
          init_seed: 2,
          seed_handle_info: 2,
          seed_terminate: 2,
          prepare_query: 2,
          finalize_query: 3,
          seed_heartbeat_cycle: 2,
          seed_heartbeat_async: 1,
          seed_emit_signal: 2,
          execute_seed_action: 4,
          seed_memory_stats: 1,
          # Guards
          memory_available?: 0,
          memory_registry_running?: 0,
          security_available?: 0,
          background_checks_available?: 0,
          signals_available?: 0,
          actions_available?: 0,
          safe_memory_call: 1
        ]

      @doc false
      def __seed_host_module__, do: @seed_host_module
    end
  end

  # ============================================================================
  # Composite Functions
  # ============================================================================

  @doc """
  Initialize seed state. Call from your agent's `init/1`.

  Merges seed fields into the given state map. Initializes memory,
  executor, signal subscriptions, working memory, and capabilities.

  ## Options

  - `:id` — Agent identifier (default: "agent")
  - `:memory_enabled` — Enable memory system (default: true)
  """
  @spec init_seed(map(), keyword()) :: map()
  def init_seed(state, opts) do
    id = Keyword.get(opts, :id, @default_id)
    memory_enabled = Keyword.get(opts, :memory_enabled, true)
    # The host module is passed via opts so seed_heartbeat_cycle can call seed_think/2
    seed_module = Keyword.get(opts, :seed_module)

    # Initialize memory system
    memory_initialized =
      if memory_enabled do
        init_memory_system(id)
      else
        false
      end

    # Load working memory
    working_memory =
      if memory_initialized do
        load_working_memory(id)
      else
        nil
      end

    # Grant capabilities from template (non-fatal)
    grant_template_capabilities(id)

    # Initialize context window
    {:ok, context_window} = ContextManager.init_context(id, opts)

    # Start Executor
    executor_pid = start_agent_executor(id)

    seed_state = %{
      id: id,
      seed_module: seed_module,
      memory_enabled: memory_enabled,
      memory_initialized: memory_initialized,
      working_memory: working_memory,
      recalled_memories: [],
      query_count: 0,
      heartbeat_count: 0,
      last_user_message_at: nil,
      last_assistant_output_at: nil,
      responded_to_last_user_message: true,
      executor_pid: executor_pid,
      context_window: context_window
    }

    state = Map.merge(state, seed_state)

    # Subscribe to percepts from Executor
    if executor_pid do
      ExecutorIntegration.subscribe_to_percepts(id, self())
    end

    # Subscribe to memory signals
    subscribe_to_memory_signals(id)

    state
  end

  @doc """
  Handle seed-related messages (percepts, memory signals).

  Returns `{:noreply, state}` if handled, or `:not_handled` if not a seed message.
  Call from your agent's `handle_info/2` chain.
  """
  @spec seed_handle_info(term(), map()) :: {:noreply, map()} | :not_handled
  def seed_handle_info({:percept_result, percept}, state) do
    Logger.debug("Percept received: #{percept.id}, outcome=#{percept.outcome}",
      agent_id: state.id
    )

    seed_emit_signal(:percept_received, %{
      id: state.id,
      percept_id: percept.id,
      outcome: percept.outcome,
      intent_id: percept.intent_id
    })

    {:noreply, state}
  end

  def seed_handle_info({:memory_signal, signal_type, payload}, state) do
    handle_memory_signal(signal_type, payload, state)
  end

  def seed_handle_info(_msg, _state), do: :not_handled

  @doc """
  Clean up seed resources on terminate.

  Saves working memory, stops executor. Call from your agent's `terminate/2`.
  """
  @spec seed_terminate(term(), map()) :: :ok
  def seed_terminate(reason, state) do
    # Capture a full Seed snapshot before shutdown
    capture_seed_on_terminate(state, reason)

    # Save context window
    if state[:context_window] do
      ContextManager.save_context(state.id, state.context_window)
    end

    # Save working memory
    if state.memory_initialized and state.working_memory do
      save_working_memory(state.id, state.working_memory)
    end

    # Stop Executor
    if state[:executor_pid] do
      Arbor.Agent.Executor.stop(state.id)
    end

    Logger.info("Agent seed terminating", id: state.id, reason: inspect(reason))
    seed_emit_signal(:agent_stopped, %{id: state.id, query_count: state.query_count})
    :ok
  end

  @doc """
  Prepare a query by recalling memories and adding timing/self-knowledge context.

  Returns `{enhanced_prompt, recalled_memories, updated_state}`.
  """
  @spec prepare_query(String.t(), map()) :: {String.t(), [map()], map()}
  def prepare_query(prompt, state) do
    state = TimingContext.on_user_message(state)

    recalled =
      if state.memory_initialized do
        recall_memories(state.id, prompt)
      else
        []
      end

    enhanced_prompt = maybe_add_timing_context(prompt, state)

    {enhanced_prompt, recalled, state}
  end

  @doc """
  Finalize a query by indexing the response, updating working memory,
  consolidating, and updating the context window.

  Returns updated state.
  """
  @spec finalize_query(String.t(), String.t(), map()) :: map()
  def finalize_query(prompt, response_text, state) do
    state = TimingContext.on_agent_output(state)

    if state.memory_initialized do
      index_response(state.id, prompt, response_text)
    end

    state = update_working_memory(state, prompt, response_text)
    state = maybe_consolidate(state)
    add_to_context_window(state, prompt, response_text)
  end

  @doc """
  Run a full heartbeat cycle with seed logic.

  Orchestrates: background checks → LLM think (via `seed_think/2` callback) →
  action routing → goal updates → memory notes → context compression →
  identity consolidation → periodic reflection.

  Returns the standard `HeartbeatLoop` result tuple.
  """
  @spec seed_heartbeat_cycle(map(), map()) ::
          {:ok, list(), map(), map() | nil, nil, map()} | {:error, term()}
  def seed_heartbeat_cycle(state, _body) do
    # Increment heartbeat counter
    heartbeat_count = (state[:heartbeat_count] || 0) + 1
    state = Map.put(state, :heartbeat_count, heartbeat_count)

    # Determine cognitive mode
    mode = determine_cognitive_mode(state)
    state = Map.put(state, :cognitive_mode, mode)

    # 1. Background checks
    background_result = run_background_checks(state)

    bg_actions =
      if is_map(background_result) do
        Map.get(background_result, :actions, [])
      else
        []
      end

    # 2. LLM think cycle via Host callback
    {llm_result, thinking, memory_notes, goal_updates} =
      state.seed_module.seed_think(state, mode)

    # 3. Route LLM-generated actions through Executor
    llm_actions = Map.get(llm_result, :actions, [])

    if llm_actions != [] and state[:executor_pid] do
      ExecutorIntegration.route_actions(state.id, llm_actions)
    end

    # 4. Process goal updates
    process_goal_updates(state.id, goal_updates)

    # 5. Index memory notes
    index_memory_notes(state.id, memory_notes)

    # 6. Context compression
    maybe_compress_context(state)

    # 7. Periodic identity consolidation
    maybe_consolidate_identity(state.id, heartbeat_count)

    # 8. Periodic reflection
    maybe_periodic_reflection(state.id, heartbeat_count)

    # Combine actions
    all_actions = bg_actions ++ llm_actions

    llm_usage = Map.get(llm_result, :usage, %{})

    llm_output = Map.get(llm_result, :output, "")

    metadata = %{
      cognitive_mode: mode,
      background_actions: length(bg_actions),
      llm_actions: length(llm_actions),
      thinking: thinking,
      memory_notes_count: length(memory_notes),
      goal_updates_count: length(goal_updates),
      heartbeat_count: heartbeat_count,
      usage: llm_usage,
      output: llm_output
    }

    # Only pass context window back if there's meaningful user-facing output
    context_window_to_sync =
      if is_binary(llm_output) and String.trim(llm_output) != "" do
        state[:context_window]
      else
        nil
      end

    {:ok, all_actions, %{}, context_window_to_sync, nil, metadata}
  end

  @doc """
  Run heartbeat cycle asynchronously in a Task.

  Sends `{:heartbeat_complete, result}` back to the calling process.
  """
  @spec seed_heartbeat_async(map()) :: {:ok, pid()}
  def seed_heartbeat_async(state) do
    host_pid = self()
    body = Map.get(state, :body, %{})

    Task.start(fn ->
      result =
        try do
          seed_heartbeat_cycle(state, body)
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

  # ============================================================================
  # Signal Emission
  # ============================================================================

  @doc """
  Emit a signal via Arbor.Signals (if available).
  """
  @spec seed_emit_signal(atom(), map()) :: :ok
  def seed_emit_signal(event, data) do
    if signals_available?() do
      agent_id = data[:id] || data["id"]
      metadata = if agent_id, do: %{agent_id: agent_id}, else: %{}
      Arbor.Signals.emit(:agent, event, data, metadata: metadata)
    end

    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Action Execution
  # ============================================================================

  @doc """
  Execute an action through capability-based authorization.
  """
  @spec execute_seed_action(String.t(), module(), map(), keyword()) ::
          {:ok, any()} | {:ok, :pending_approval, String.t()} | {:error, term()}
  def execute_seed_action(agent_id, action_module, params, opts \\ []) do
    bypass_auth = Keyword.get(opts, :bypass_auth, false)

    result =
      if bypass_auth do
        execute_action_direct(action_module, params)
      else
        execute_action_authorized(agent_id, action_module, params)
      end

    emit_action_signal(agent_id, action_module, result)

    result
  end

  # ============================================================================
  # Memory Stats
  # ============================================================================

  @doc """
  Get memory statistics for an agent.
  """
  @spec seed_memory_stats(String.t()) :: map()
  def seed_memory_stats(agent_id) do
    get_memory_stats(agent_id)
  end

  # ============================================================================
  # Guards — Availability Checks
  # ============================================================================

  @doc false
  @spec memory_available?() :: boolean()
  def memory_available? do
    Code.ensure_loaded?(Arbor.Memory) and
      function_exported?(Arbor.Memory, :init_for_agent, 1)
  end

  @doc false
  @spec memory_registry_running?() :: boolean()
  def memory_registry_running? do
    Process.whereis(Arbor.Memory.Registry) != nil or
      Process.whereis(Arbor.Memory.IndexSupervisor) != nil
  rescue
    _ -> false
  end

  @doc false
  @spec security_available?() :: boolean()
  def security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :grant, 1) and
      Process.whereis(Arbor.Security.SystemAuthority) != nil
  end

  @doc false
  @spec background_checks_available?() :: boolean()
  def background_checks_available? do
    Code.ensure_loaded?(Arbor.Memory.BackgroundChecks) and
      function_exported?(Arbor.Memory.BackgroundChecks, :run, 2)
  end

  @doc false
  @spec signals_available?() :: boolean()
  def signals_available? do
    Code.ensure_loaded?(Arbor.Signals) and
      Process.whereis(Arbor.Signals.Bus) != nil
  end

  @doc false
  @spec actions_available?() :: boolean()
  def actions_available? do
    Code.ensure_loaded?(Arbor.Actions) and
      function_exported?(Arbor.Actions, :authorize_and_execute, 4)
  end

  @doc false
  @spec safe_memory_call((-> any())) :: any()
  def safe_memory_call(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("Memory call rescued: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("Memory call caught exit: #{inspect(reason)}")
      nil
  end

  # ============================================================================
  # Private: Memory System
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

      save_working_memory(state.id, working_memory)
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

  # ============================================================================
  # Private: Prompt Enhancement
  # ============================================================================

  defp maybe_add_timing_context(prompt, state) do
    if Application.get_env(:arbor_agent, :timing_context_enabled, true) do
      timing_markdown =
        state
        |> TimingContext.compute()
        |> TimingContext.to_markdown()

      self_knowledge_context = build_self_knowledge_context(state.id)

      parts = [prompt, timing_markdown]
      parts = if self_knowledge_context, do: parts ++ [self_knowledge_context], else: parts

      Enum.join(parts, "\n\n")
    else
      prompt
    end
  end

  defp build_self_knowledge_context(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory.IdentityConsolidator) and
         function_exported?(Arbor.Memory.IdentityConsolidator, :get_self_knowledge, 1) do
      case Arbor.Memory.IdentityConsolidator.get_self_knowledge(agent_id) do
        nil ->
          nil

        sk ->
          summary = Arbor.Memory.SelfKnowledge.summarize(sk)
          if summary != "" and summary != nil, do: "## Self-Awareness\n#{summary}", else: nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # ============================================================================
  # Private: Context Window
  # ============================================================================

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

  defp maybe_compress_context(state) do
    if state[:context_window] && ContextManager.should_compress?(state.context_window) do
      case ContextManager.maybe_compress(state.context_window) do
        {:ok, compressed} ->
          Logger.debug("Context compressed", agent_id: state.id)
          seed_emit_signal(:context_compressed, %{id: state.id})
          compressed

        {:error, _} ->
          state.context_window
      end
    else
      state[:context_window]
    end
  end

  # ============================================================================
  # Private: Security
  # ============================================================================

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

  # ============================================================================
  # Private: Executor & Actions
  # ============================================================================

  defp start_agent_executor(agent_id) do
    case ExecutorIntegration.start_executor(agent_id, trust_tier: :established) do
      {:ok, pid} -> pid
      {:error, _} -> nil
    end
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

    seed_emit_signal(:action_executed, %{
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
  # Private: Signal Subscriptions
  # ============================================================================

  defp subscribe_to_memory_signals(agent_id) do
    pid = self()

    memory_topics = [
      "memory.consolidation_completed",
      "memory.insights_detected",
      "memory.preconscious_surfaced",
      "memory.fact_extracted"
    ]

    Enum.each(memory_topics, fn topic ->
      safe_memory_call(fn ->
        if Code.ensure_loaded?(Arbor.Signals) and
             function_exported?(Arbor.Signals, :subscribe, 2) do
          Arbor.Signals.subscribe(topic, fn signal ->
            signal_type =
              case signal.type do
                t when is_atom(t) -> t
                t when is_binary(t) -> String.to_existing_atom(t)
                _ -> :unknown
              end

            send(pid, {:memory_signal, signal_type, signal.payload || %{}})
            :ok
          end)
        end
      end)
    end)

    Logger.debug("Subscribed to memory signals", agent_id: agent_id)
  rescue
    _ -> Logger.debug("Could not subscribe to memory signals")
  catch
    :exit, _ -> Logger.debug("Memory signal subscription timeout")
  end

  # ============================================================================
  # Private: Seed Capture on Terminate
  # ============================================================================

  defp capture_seed_on_terminate(state, reason) do
    capture_reason =
      case reason do
        :normal -> :shutdown
        :shutdown -> :shutdown
        {:shutdown, _} -> :shutdown
        _ -> :crash
      end

    CheckpointManager.save_checkpoint(state, reason: capture_reason)
  rescue
    e ->
      Logger.warning("Seed capture on terminate rescued: #{Exception.message(e)}")
  end

  # ============================================================================
  # Private: Memory Signal Handlers
  # ============================================================================

  defp handle_memory_signal(:consolidation_completed, payload, state) do
    Logger.debug("Memory consolidation completed",
      agent_id: state.id,
      metrics: inspect(payload[:metrics])
    )

    {:noreply, state}
  end

  defp handle_memory_signal(:insights_detected, payload, state) do
    insights = payload[:insights] || []

    if state[:working_memory] && insights != [] do
      new_wm =
        Enum.reduce(Enum.take(insights, 2), state.working_memory, fn insight, wm ->
          content = insight[:content] || inspect(insight)

          Arbor.Memory.WorkingMemory.add_curiosity(
            wm,
            "[hb] [insight] #{String.slice(content, 0..80)}"
          )
        end)

      save_working_memory(state.id, new_wm)
      {:noreply, %{state | working_memory: new_wm}}
    else
      {:noreply, state}
    end
  end

  defp handle_memory_signal(:preconscious_surfaced, payload, state) do
    memories = payload[:memories] || []

    if state[:working_memory] && memories != [] do
      new_wm =
        Enum.reduce(Enum.take(memories, 2), state.working_memory, fn mem, wm ->
          content = mem[:content] || mem[:text] || inspect(mem)

          Arbor.Memory.WorkingMemory.add_thought(
            wm,
            "[hb] [recalled] #{String.slice(content, 0..120)}"
          )
        end)

      save_working_memory(state.id, new_wm)
      {:noreply, %{state | working_memory: new_wm}}
    else
      {:noreply, state}
    end
  end

  defp handle_memory_signal(_type, _payload, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private: Heartbeat Helpers
  # ============================================================================

  defp determine_cognitive_mode(state) do
    cond do
      user_waiting?(state) ->
        :conversation

      idle_reflection_enabled?() and :rand.uniform() < idle_reflection_chance() ->
        Enum.random([:introspection, :reflection, :pattern_analysis, :insight_detection])

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

  defp process_goal_updates(_agent_id, []), do: :ok

  defp process_goal_updates(agent_id, updates) do
    Enum.each(updates, fn update ->
      goal_id = update[:goal_id]
      progress = update[:progress]

      if goal_id && progress do
        safe_memory_call(fn ->
          Arbor.Memory.update_goal_progress(agent_id, goal_id, progress)
        end)
      end
    end)
  end

  defp index_memory_notes(_agent_id, []), do: :ok

  defp index_memory_notes(agent_id, notes) do
    Enum.each(notes, fn note ->
      safe_memory_call(fn ->
        Arbor.Memory.index(agent_id, note, %{
          type: :heartbeat_observation,
          timestamp: DateTime.utc_now()
        })
      end)

      seed_emit_signal(:agent_memory_note, %{
        id: agent_id,
        note: String.slice(note, 0..100)
      })
    end)

    # Also add heartbeat notes to working memory so they're visible in the dashboard.
    # This runs in a Task (not the GenServer), so we read/update/save ETS directly.
    safe_memory_call(fn ->
      wm = Arbor.Memory.load_working_memory(agent_id)

      updated_wm =
        Enum.reduce(notes, wm, fn note, acc ->
          Arbor.Memory.WorkingMemory.add_thought(
            acc,
            "[hb] #{String.slice(note, 0..120)}",
            priority: :low
          )
        end)

      Arbor.Memory.save_working_memory(agent_id, updated_wm)
    end)
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

      # Surface suggestions
      surface_background_suggestions(state.id, result.suggestions, state)

      seed_emit_signal(:heartbeat_complete, %{
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

  defp surface_background_suggestions(_agent_id, [], _state), do: :ok

  defp surface_background_suggestions(agent_id, suggestions, state) do
    Enum.each(suggestions, fn suggestion ->
      if (suggestion[:confidence] || 0) >= 0.5 do
        safe_memory_call(fn ->
          Arbor.Memory.create_proposal(
            agent_id,
            suggestion[:type] || :background_insight,
            suggestion[:content] || inspect(suggestion)
          )
        end)
      end

      if state[:working_memory] && (suggestion[:confidence] || 0) >= 0.6 do
        content = suggestion[:content] || inspect(suggestion)
        summary = String.slice(content, 0..120)

        safe_memory_call(fn ->
          wm =
            state.working_memory
            |> Arbor.Memory.WorkingMemory.add_curiosity(
              "[hb] [#{suggestion[:type]}] #{summary}",
              max_curiosity: 5
            )

          Arbor.Memory.save_working_memory(agent_id, wm)
        end)
      end
    end)
  end

  defp maybe_consolidate_identity(agent_id, heartbeat_count) do
    if rem(heartbeat_count, @identity_consolidation_interval) == 0 do
      spawn(fn ->
        safe_memory_call(fn ->
          if Code.ensure_loaded?(Arbor.Memory.IdentityConsolidator) and
               function_exported?(Arbor.Memory.IdentityConsolidator, :consolidate, 2) do
            case Arbor.Memory.IdentityConsolidator.consolidate(agent_id) do
              {:ok, :no_changes} ->
                :ok

              {:ok, _sk} ->
                Logger.info("Identity consolidated", agent_id: agent_id)

                seed_emit_signal(:identity_consolidated, %{
                  id: agent_id,
                  heartbeat: heartbeat_count
                })

              {:error, reason} ->
                Logger.debug("Identity consolidation skipped: #{inspect(reason)}")
            end
          end
        end)
      end)
    end
  end

  defp maybe_periodic_reflection(agent_id, heartbeat_count) do
    if rem(heartbeat_count, @reflection_interval) == 0 do
      spawn(fn ->
        safe_memory_call(fn ->
          if Code.ensure_loaded?(Arbor.Memory.ReflectionProcessor) and
               function_exported?(Arbor.Memory.ReflectionProcessor, :periodic_reflection, 1) do
            case Arbor.Memory.ReflectionProcessor.periodic_reflection(agent_id) do
              {:ok, reflection} ->
                Logger.info("Periodic reflection completed",
                  agent_id: agent_id,
                  insights: length(reflection[:insights] || [])
                )

                seed_emit_signal(:reflection_completed, %{
                  id: agent_id,
                  insights_count: length(reflection[:insights] || []),
                  heartbeat: heartbeat_count
                })

              {:error, reason} ->
                Logger.debug("Periodic reflection failed: #{inspect(reason)}")
            end
          end
        end)
      end)
    end
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
end
