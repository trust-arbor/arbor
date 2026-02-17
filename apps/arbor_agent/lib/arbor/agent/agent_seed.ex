defmodule Arbor.Agent.AgentSeed do
  @moduledoc """
  Portable agent identity mixin — the "Seed" from the Seed/Host architecture.

  Provides all portable Seed functions that any agent Host can use:
  memory integration, identity consolidation, signal subscriptions,
  executor wiring, and action execution. Heartbeat is managed by the
  DOT Session (see `Arbor.Agent.SessionManager`).

  ## Usage

      defmodule MyAgent do
        use GenServer
        use Arbor.Agent.AgentSeed

        def init(opts) do
          state = init_seed(%{my_field: "host-specific"}, opts)
          {:ok, state}
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

  alias Arbor.Memory
  alias Arbor.Memory.WorkingMemory

  # Constants
  @default_id "agent"
  @default_recall_limit 5
  @consolidation_check_interval 10

  defmacro __using__(_opts) do
    quote do
      import Arbor.Agent.AgentSeed,
        only: [
          init_seed: 2,
          seed_handle_info: 2,
          seed_terminate: 2,
          prepare_query: 2,
          prepare_query: 3,
          finalize_query: 3,
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
  Prepare a query by recalling memories and optionally adding timing/self-knowledge context.

  Returns `{enhanced_prompt, recalled_memories, updated_state}`.

  ## Options

  - `:enhance_prompt` — Whether to add timing and self-knowledge context to the prompt.
    Defaults to `true`. Set to `false` when the caller handles context injection separately
    (e.g., APIAgent uses the split stable/volatile prompt builders).
  """
  @spec prepare_query(String.t(), map(), keyword()) :: {String.t(), [map()], map()}
  def prepare_query(prompt, state, opts \\ []) do
    state = TimingContext.on_user_message(state)

    recalled =
      if state.memory_initialized do
        recall_memories(state.id, prompt)
      else
        []
      end

    enhanced_prompt =
      if Keyword.get(opts, :enhance_prompt, true),
        do: maybe_add_timing_context(prompt, state),
        else: prompt

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
  # Private: Percept/Intent Status Tracking
  # ============================================================================

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

        # Dead-letter check: if all intents for this goal are terminal, flag it
        maybe_flag_dead_letter_goal(agent_id, goal_id)

      _ ->
        :ok
    end
  end

  defp maybe_flag_dead_letter_goal(_agent_id, nil), do: :ok

  defp maybe_flag_dead_letter_goal(agent_id, goal_id) do
    pending =
      safe_memory_call(fn ->
        Arbor.Memory.pending_intents_for_goal(agent_id, goal_id)
      end)

    # If no pending intents remain, all were completed or abandoned — goal is a dead letter
    if (is_list(pending) and pending == []) or pending == nil do
      safe_memory_call(fn ->
        Arbor.Memory.update_goal_metadata(agent_id, goal_id, %{decomposition_failed: true})
      end)

      seed_emit_signal(:goal_dead_letter, %{
        agent_id: agent_id,
        goal_id: goal_id,
        reason: "all_intents_abandoned"
      })

      Logger.warning("Goal #{goal_id} flagged as dead letter — all intents abandoned",
        agent_id: agent_id
      )
    end
  end

  defp get_intent_goal_id(agent_id, intent_id) do
    case safe_memory_call(fn -> Arbor.Memory.get_intent(agent_id, intent_id) end) do
      {:ok, intent, _status} -> intent.goal_id
      _ -> nil
    end
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
    Code.ensure_loaded?(Arbor.Memory.IdentityConsolidator) and
      function_exported?(Arbor.Memory.IdentityConsolidator, fun, arity)
  end

  defp fetch_self_knowledge(agent_id) do
    agent_id
    |> Memory.get_self_knowledge()
    |> format_self_knowledge()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_self_knowledge(nil), do: nil

  defp format_self_knowledge(sk) do
    case Memory.summarize_self_knowledge(sk) do
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
    if Code.ensure_loaded?(Arbor.Memory.ContextWindow) and
         function_exported?(Arbor.Memory.ContextWindow, :add_entry, 3) do
      window =
        window
        |> Memory.add_context_entry(:message, "Human: #{prompt}")
        |> Memory.add_context_entry(:message, "Assistant: #{response}")

      %{state | context_window: window}
    else
      state
    end
  rescue
    _ -> state
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
