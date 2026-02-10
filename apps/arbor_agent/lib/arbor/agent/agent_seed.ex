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
    Executor,
    ExecutorIntegration,
    TimingContext
  }

  alias Arbor.Memory.BackgroundChecks
  alias Arbor.Memory.ContextWindow
  alias Arbor.Memory.IdentityConsolidator
  alias Arbor.Memory.Proposal
  alias Arbor.Memory.ReflectionProcessor
  alias Arbor.Memory.SelfKnowledge
  alias Arbor.Memory.WorkingMemory

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

    # Note: capabilities are granted by Lifecycle.create — no need to re-grant here

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
  @max_intent_retries 3

  def seed_handle_info({:percept_result, percept}, state) do
    Logger.debug("Percept received: #{percept.id}, outcome=#{percept.outcome}",
      agent_id: state.id
    )

    # Update intent status based on percept outcome
    handle_percept_intent_status(state.id, percept)

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
      Executor.stop(state.id)
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

    # 3.5. Route pending intentions from IntentStore to Executor (BDI pull-based)
    if state[:executor_pid] do
      ExecutorIntegration.route_pending_intentions(state.id)
    end

    # 4. Process goal updates
    process_goal_updates(state.id, goal_updates)

    # 4.5. Create new goals suggested by the LLM
    new_goals = Map.get(llm_result, :new_goals, [])
    create_suggested_goals(state.id, new_goals)

    # 4.75. Process decompositions (goal -> intentions)
    decompositions = Map.get(llm_result, :decompositions, [])
    process_decompositions(state.id, decompositions)

    # 5. Index memory notes
    index_memory_notes(state.id, memory_notes)

    # 6. Process proposal decisions from LLM
    proposal_decisions = Map.get(llm_result, :proposal_decisions, [])
    process_proposal_decisions(state.id, proposal_decisions)

    # 7. Context compression
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
    Code.ensure_loaded?(BackgroundChecks) and
      function_exported?(BackgroundChecks, :run, 2)
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
        WorkingMemory.add_thought(
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
    if identity_consolidator_available?(:get_self_knowledge, 1),
      do: fetch_self_knowledge(agent_id)
  end

  defp identity_consolidator_available?(fun, arity) do
    Code.ensure_loaded?(IdentityConsolidator) and
      function_exported?(IdentityConsolidator, fun, arity)
  end

  defp fetch_self_knowledge(agent_id) do
    agent_id
    |> IdentityConsolidator.get_self_knowledge()
    |> format_self_knowledge()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_self_knowledge(nil), do: nil

  defp format_self_knowledge(sk) do
    case SelfKnowledge.summarize(sk) do
      summary when summary != "" and not is_nil(summary) ->
        "## Self-Awareness\n#{summary}"

      _ ->
        nil
    end
  end

  # ============================================================================
  # Private: Context Window
  # ============================================================================

  defp add_to_context_window(%{context_window: nil} = state, _prompt, _response), do: state

  defp add_to_context_window(%{context_window: window} = state, prompt, response) do
    if Code.ensure_loaded?(ContextWindow) and
         function_exported?(ContextWindow, :add_entry, 3) do
      window =
        window
        |> ContextWindow.add_entry(:message, "Human: #{prompt}")
        |> ContextWindow.add_entry(:message, "Assistant: #{response}")

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
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :subscribe, 2) do
      subscribe_to_each_memory_topic(self())
    end

    Logger.debug("Subscribed to memory signals", agent_id: agent_id)
  rescue
    _ -> Logger.debug("Could not subscribe to memory signals")
  catch
    :exit, _ -> Logger.debug("Memory signal subscription timeout")
  end

  defp subscribe_to_each_memory_topic(pid) do
    memory_topics = [
      "memory.consolidation_completed",
      "memory.insights_detected",
      "memory.preconscious_surfaced",
      "memory.fact_extracted"
    ]

    Enum.each(memory_topics, fn topic ->
      safe_memory_call(fn ->
        Arbor.Signals.subscribe(topic, &handle_memory_signal(&1, pid))
      end)
    end)
  end

  defp handle_memory_signal(signal, pid) do
    signal_type = normalize_signal_type(signal.type)
    send(pid, {:memory_signal, signal_type, signal.payload || %{}})
    :ok
  end

  defp normalize_signal_type(t) when is_atom(t), do: t
  defp normalize_signal_type(t) when is_binary(t), do: String.to_existing_atom(t)
  defp normalize_signal_type(_), do: :unknown

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
    # Insights flow through the Proposal pipeline, not directly into working memory.
    # The LLM sees pending proposals via HeartbeatPrompt.proposals_section/1
    # and decides whether to accept/reject/defer them.
    count = length(payload[:insights] || [])

    if count > 0 do
      Logger.debug("Insights detected (#{count}) — available as proposals for LLM review",
        agent_id: state.id
      )
    end

    {:noreply, state}
  end

  defp handle_memory_signal(:preconscious_surfaced, payload, state) do
    # Preconscious memories flow through the Proposal pipeline, not directly into working memory.
    # The LLM sees pending proposals via HeartbeatPrompt.proposals_section/1
    # and decides whether to accept/reject/defer them.
    count = length(payload[:memories] || [])

    if count > 0 do
      Logger.debug(
        "Preconscious memories surfaced (#{count}) — available as proposals for LLM review",
        agent_id: state.id
      )
    end

    {:noreply, state}
  end

  defp handle_memory_signal(_type, _payload, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private: Heartbeat Helpers
  # ============================================================================

  defp determine_cognitive_mode(state) do
    heartbeat_count = state[:heartbeat_count] || 0

    cond do
      # User waiting — always conversation mode
      user_waiting?(state) ->
        :conversation

      # Maintenance floor: every 5th cycle, consolidate regardless (council: stability)
      rem(heartbeat_count, 5) == 0 and heartbeat_count > 0 ->
        :consolidation

      # Plan execution: goals exist but have no pending intentions — need decomposition
      has_undecomposed_goals?(state) ->
        :plan_execution

      # Goal pursuit when active goals exist (council: adaptive goal-first)
      has_active_goals?(state) ->
        :goal_pursuit

      # No goals — idle mode
      true ->
        idle_mode()
    end
  end

  defp has_active_goals?(state) do
    agent_id = state[:id] || state[:agent_id]

    goals =
      try do
        Arbor.Memory.get_active_goals(agent_id)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    is_list(goals) and goals != []
  end

  defp has_undecomposed_goals?(state) do
    agent_id = state[:id] || state[:agent_id]

    goals =
      try do
        Arbor.Memory.get_active_goals(agent_id)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    if is_list(goals) and goals != [] do
      # Check if any goal has no pending intentions (needs decomposition)
      # Skip goals flagged as decomposition_failed
      Enum.any?(goals, fn goal ->
        not decomposition_failed?(goal) and not has_pending_intents?(agent_id, goal.id)
      end)
    else
      false
    end
  end

  defp decomposition_failed?(goal) do
    meta = goal.metadata || %{}
    meta[:decomposition_failed] == true or meta["decomposition_failed"] == true
  end

  defp has_pending_intents?(agent_id, goal_id) do
    pending =
      try do
        Arbor.Memory.pending_intents_for_goal(agent_id, goal_id)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    is_list(pending) and pending != []
  end

  defp user_waiting?(state) do
    timing = TimingContext.compute(state)
    timing.user_waiting
  end

  defp idle_mode do
    if idle_reflection_enabled?() and :rand.uniform() < idle_reflection_chance() do
      Enum.random([:introspection, :reflection, :pattern_analysis, :insight_detection])
    else
      :consolidation
    end
  end

  defp idle_reflection_enabled? do
    Application.get_env(:arbor_agent, :idle_reflection_enabled, true)
  end

  defp idle_reflection_chance do
    Application.get_env(:arbor_agent, :idle_reflection_chance, 0.3)
  end

  defp process_proposal_decisions(_agent_id, []), do: :ok

  defp process_proposal_decisions(agent_id, decisions) do
    Enum.each(decisions, &apply_proposal_decision(agent_id, &1))
  end

  defp apply_proposal_decision(_agent_id, decision) when not is_map(decision), do: :ok

  defp apply_proposal_decision(agent_id, decision) do
    proposal_id = decision[:proposal_id]
    action = decision[:decision]

    if proposal_id && action do
      safe_memory_call(fn ->
        execute_proposal_action(agent_id, proposal_id, action, decision[:reason])
      end)
    end
  end

  defp execute_proposal_action(agent_id, proposal_id, :accept, _reason) do
    # Get the proposal first to check its type and metadata
    case Proposal.get(agent_id, proposal_id) do
      {:ok, proposal} ->
        # Accept the proposal (marks it in ETS)
        Proposal.accept(agent_id, proposal_id)

        # Type-specific post-acceptance handling
        apply_accepted_proposal(agent_id, proposal)

      _ ->
        Proposal.accept(agent_id, proposal_id)
    end
  end

  defp execute_proposal_action(agent_id, proposal_id, :reject, reason) do
    opts = if reason, do: [reason: reason], else: []
    Proposal.reject(agent_id, proposal_id, opts)
  end

  defp execute_proposal_action(agent_id, proposal_id, :defer, _reason),
    do: Proposal.defer(agent_id, proposal_id)

  defp execute_proposal_action(_agent_id, _proposal_id, _action, _reason), do: :ok

  defp apply_accepted_proposal(agent_id, %{type: :identity, metadata: metadata})
       when is_map(metadata) do
    safe_memory_call(fn ->
      IdentityConsolidator.apply_accepted_change(agent_id, metadata)
    end)
  end

  defp apply_accepted_proposal(_agent_id, _proposal), do: :ok

  defp process_goal_updates(_agent_id, []), do: :ok

  defp process_goal_updates(agent_id, updates) do
    Enum.each(updates, &apply_goal_update(agent_id, &1))
  end

  defp apply_goal_update(agent_id, update) do
    goal_id = update[:goal_id]
    progress = update[:progress]

    if goal_id && progress do
      safe_memory_call(fn -> Arbor.Memory.update_goal_progress(agent_id, goal_id, progress) end)
    end
  end

  defp create_suggested_goals(_agent_id, []), do: :ok

  defp create_suggested_goals(agent_id, goals) do
    alias Arbor.Contracts.Memory.Goal

    # Cap at 3 new goals per heartbeat cycle
    goals
    |> Enum.take(3)
    |> Enum.each(fn goal ->
      desc = goal[:description]
      priority = goal[:priority] || :medium

      if desc do
        goal_struct =
          Goal.new(desc,
            priority: priority,
            success_criteria: goal[:success_criteria]
          )

        safe_memory_call(fn ->
          Arbor.Memory.add_goal(agent_id, goal_struct)
        end)

        seed_emit_signal(:goal_suggested, %{
          agent_id: agent_id,
          description: String.slice(desc, 0..100),
          priority: priority
        })
      end
    end)
  end

  defp handle_percept_intent_status(_agent_id, %{intent_id: nil}), do: :ok
  defp handle_percept_intent_status(_agent_id, %{intent_id: ""}), do: :ok

  defp handle_percept_intent_status(agent_id, percept) do
    intent_id = percept.intent_id

    case percept.outcome do
      :success ->
        safe_memory_call(fn -> Arbor.Memory.complete_intent(agent_id, intent_id) end)

      outcome when outcome in [:failure, :error] ->
        handle_intent_failure(agent_id, intent_id, percept)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp handle_intent_failure(agent_id, intent_id, percept) do
    reason = inspect(percept.error || percept.outcome)

    case safe_memory_call(fn -> Arbor.Memory.fail_intent(agent_id, intent_id, reason) end) do
      {:ok, retry_count} when retry_count >= @max_intent_retries ->
        # Abandon this intent — too many retries
        safe_memory_call(fn -> Arbor.Memory.complete_intent(agent_id, intent_id) end)

        # Look up the goal_id for signaling
        goal_id = get_intent_goal_id(agent_id, intent_id)

        seed_emit_signal(:agent_intent_abandoned, %{
          agent_id: agent_id,
          intent_id: intent_id,
          goal_id: goal_id,
          retry_count: retry_count,
          reason: reason
        })

        Logger.warning("Intent #{intent_id} abandoned after #{retry_count} retries",
          agent_id: agent_id,
          goal_id: goal_id
        )

      _ ->
        :ok
    end
  end

  defp get_intent_goal_id(agent_id, intent_id) do
    case safe_memory_call(fn -> Arbor.Memory.get_intent(agent_id, intent_id) end) do
      {:ok, intent, _status} -> intent.goal_id
      _ -> nil
    end
  end

  defp process_decompositions(_agent_id, []), do: :ok

  defp process_decompositions(agent_id, decompositions) do
    Enum.each(decompositions, fn decomp ->
      goal_id = decomp[:goal_id]
      intentions = decomp[:intentions] || []

      if goal_id do
        Enum.each(intentions, &record_decomposed_intent(agent_id, goal_id, &1))
      end
    end)
  end

  defp record_decomposed_intent(agent_id, goal_id, intention) do
    alias Arbor.Contracts.Memory.Intent
    action = intention[:action]

    if action do
      intent =
        Intent.action(action, intention[:params] || %{},
          goal_id: goal_id,
          reasoning: intention[:reasoning],
          metadata: %{
            preconditions: intention[:preconditions],
            success_criteria: intention[:success_criteria],
            status: :pending
          }
        )

      safe_memory_call(fn -> Arbor.Memory.record_intent(agent_id, intent) end)

      seed_emit_signal(:intent_decomposed, %{
        agent_id: agent_id,
        intent_id: intent.id,
        goal_id: goal_id,
        action: action
      })

      Logger.debug("Decomposed intention for goal #{goal_id}: #{action}",
        agent_id: agent_id
      )
    end
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
          WorkingMemory.add_thought(
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
      result = BackgroundChecks.run(state.id, skip_patterns: true)

      Enum.each(result.warnings, fn warning ->
        Logger.info("Background check warning: #{warning.message}",
          agent_id: state.id,
          type: warning.type,
          severity: warning.severity
        )
      end)

      Enum.each(result.actions, &dispatch_background_action(&1, state.id))

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

  defp dispatch_background_action(%{type: :run_consolidation}, agent_id) do
    spawn(fn -> Arbor.Memory.run_consolidation(agent_id) end)
  end

  defp dispatch_background_action(%{type: other}, agent_id) do
    Logger.debug("Background check action: #{other}", agent_id: agent_id)
  end

  defp surface_background_suggestions(_agent_id, [], _state), do: :ok

  defp surface_background_suggestions(agent_id, suggestions, state) do
    Enum.each(suggestions, fn suggestion ->
      maybe_create_suggestion_proposal(agent_id, suggestion)
      maybe_add_suggestion_curiosity(agent_id, suggestion, state)
    end)
  end

  defp maybe_create_suggestion_proposal(agent_id, suggestion) do
    if (suggestion[:confidence] || 0) >= 0.5 do
      safe_memory_call(fn ->
        Arbor.Memory.create_proposal(
          agent_id,
          suggestion[:type] || :background_insight,
          suggestion[:content] || inspect(suggestion)
        )
      end)
    end
  end

  defp maybe_add_suggestion_curiosity(agent_id, suggestion, state) do
    if state[:working_memory] && (suggestion[:confidence] || 0) >= 0.6 do
      content = suggestion[:content] || inspect(suggestion)
      summary = String.slice(content, 0..120)

      safe_memory_call(fn ->
        wm =
          state.working_memory
          |> WorkingMemory.add_curiosity(
            "[hb] [#{suggestion[:type]}] #{summary}",
            max_curiosity: 5
          )

        Arbor.Memory.save_working_memory(agent_id, wm)
      end)
    end
  end

  defp maybe_consolidate_identity(agent_id, heartbeat_count) do
    if rem(heartbeat_count, @identity_consolidation_interval) == 0 do
      spawn(fn -> run_identity_consolidation(agent_id, heartbeat_count) end)
    end
  end

  defp run_identity_consolidation(agent_id, heartbeat_count) do
    if identity_consolidator_available?(:consolidate, 2) do
      safe_memory_call(fn ->
        handle_consolidation_result(
          IdentityConsolidator.consolidate(agent_id),
          agent_id,
          heartbeat_count
        )
      end)
    end
  end

  defp handle_consolidation_result({:ok, :no_changes}, _agent_id, _heartbeat_count), do: :ok

  defp handle_consolidation_result({:ok, _sk}, agent_id, heartbeat_count) do
    Logger.info("Identity consolidated", agent_id: agent_id)

    seed_emit_signal(:identity_consolidated, %{
      id: agent_id,
      heartbeat: heartbeat_count
    })
  end

  defp handle_consolidation_result({:error, reason}, _agent_id, _heartbeat_count) do
    Logger.debug("Identity consolidation skipped: #{inspect(reason)}")
  end

  defp maybe_periodic_reflection(agent_id, heartbeat_count) do
    if rem(heartbeat_count, @reflection_interval) == 0 do
      spawn(fn -> run_periodic_reflection(agent_id, heartbeat_count) end)
    end
  end

  defp run_periodic_reflection(agent_id, heartbeat_count) do
    if reflection_processor_available?() do
      safe_memory_call(fn ->
        handle_reflection_result(
          ReflectionProcessor.periodic_reflection(agent_id),
          agent_id,
          heartbeat_count
        )
      end)
    end
  end

  defp reflection_processor_available? do
    Code.ensure_loaded?(ReflectionProcessor) and
      function_exported?(ReflectionProcessor, :periodic_reflection, 1)
  end

  defp handle_reflection_result({:ok, reflection}, agent_id, heartbeat_count) do
    Logger.info("Periodic reflection completed",
      agent_id: agent_id,
      insights: length(reflection[:insights] || [])
    )

    seed_emit_signal(:reflection_completed, %{
      id: agent_id,
      insights_count: length(reflection[:insights] || []),
      heartbeat: heartbeat_count
    })
  end

  defp handle_reflection_result({:error, reason}, _agent_id, _heartbeat_count) do
    Logger.debug("Periodic reflection failed: #{inspect(reason)}")
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
