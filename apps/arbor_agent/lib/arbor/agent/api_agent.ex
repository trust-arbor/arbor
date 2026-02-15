defmodule Arbor.Agent.APIAgent do
  @moduledoc """
  API Agent Host — the execution environment for API-backend agents in Arbor.

  This is a Host in the Seed/Host architecture, mirroring `Arbor.Agent.Claude`
  but using `Arbor.AI.generate_text_with_tools/2` for queries instead of
  the Claude CLI. Portable identity (memory, signals, executor) lives in
  `Arbor.Agent.AgentSeed`. Heartbeat is managed by the DOT Session.

  This module provides API-specific functionality:
  - Query execution via Session (DOT) or direct `Arbor.AI.generate_text_with_tools/2`
  - Rich system prompt building from memory subsystems
  - Configurable model/provider via tiered config

  ## Usage

      {:ok, agent} = Arbor.Agent.APIAgent.start_link(
        id: "api-agent-1",
        model: "arcee-ai/trinity-large-preview:free",
        provider: :openrouter
      )
      {:ok, response} = Arbor.Agent.APIAgent.query(agent, "What is 2+2?")
  """

  use GenServer
  use Arbor.Agent.AgentSeed

  require Logger

  alias Arbor.Agent.APIConfig

  @type option ::
          {:id, String.t()}
          | {:model, String.t()}
          | {:provider, atom()}
          | {:model_id, String.t()}
          | {:memory_enabled, boolean()}

  @type t :: GenServer.server()

  @default_id "api-agent"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the API agent.

  ## Options

  - `:id` - Agent identifier (default: "api-agent")
  - `:model` - Model string (e.g., "arcee-ai/trinity-large-preview:free")
  - `:provider` - Provider atom (e.g., :openrouter, :zai_coding_plan)
  - `:model_id` - Model ID for tiered config lookup (usually same as :model)
  - `:memory_enabled` - Enable memory system (default: true)
  - `:max_tokens` - Max tokens for generation (default: 16_384)
  - `:temperature` - Sampling temperature (default: 0.7)
  - `:max_turns` - Max tool-call turns per query (default: 10)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Send a query to the API agent and get a response.

  Before sending the query, relevant memories are recalled and included
  in the context. A rich system prompt is built from the agent's memory
  subsystems. After receiving the response, important facts are indexed.

  ## Options

  - `:timeout` - Response timeout in ms (default: 300_000)
  - `:recall_memories` - Whether to recall memories (default: true)
  - `:index_response` - Whether to index response facts (default: true)
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(agent, prompt, opts \\ []) do
    GenServer.call(agent, {:query, prompt, opts}, Keyword.get(opts, :timeout, 300_000))
  end

  @doc "Get the agent's ID."
  @spec agent_id(t()) :: String.t()
  def agent_id(agent), do: GenServer.call(agent, :agent_id)

  @doc "Get memory statistics for this agent."
  @spec memory_stats(t()) :: {:ok, map()} | {:error, term()}
  def memory_stats(agent), do: GenServer.call(agent, :memory_stats)

  @doc "Get the current working memory."
  @spec get_working_memory(t()) :: {:ok, map() | nil}
  def get_working_memory(agent), do: GenServer.call(agent, :get_working_memory)

  @doc "Get the agent's current recalled memories."
  @spec get_recalled_memories(t()) :: {:ok, [map()]}
  def get_recalled_memories(agent), do: GenServer.call(agent, :get_recalled_memories)

  @doc """
  Execute an Arbor action through the capability-based authorization system.
  """
  @spec execute_action(t(), module(), map(), keyword()) ::
          {:ok, any()} | {:ok, :pending_approval, String.t()} | {:error, term()}
  def execute_action(agent, action_module, params, opts \\ []) do
    GenServer.call(agent, {:execute_action, action_module, params, opts}, 60_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id, @default_id)

    # Resolve tiered config: global → per-model → agent-level
    config = APIConfig.resolve(opts)

    # Host-specific state
    host_state = %{
      # Query model config
      model: Keyword.get(opts, :model, "arcee-ai/trinity-large-preview:free"),
      provider: Keyword.get(opts, :provider, :openrouter),
      max_tokens: config.max_tokens,
      temperature: config.temperature,
      max_turns: config.max_turns
    }

    # Initialize seed (memory, executor, signals, working memory, capabilities)
    seed_opts =
      opts
      |> Keyword.put_new(:id, id)

    state = init_seed(host_state, seed_opts)

    Logger.info("API agent started",
      id: id,
      model: state.model,
      provider: state.provider,
      max_tokens: state.max_tokens,
      memory_enabled: state.memory_enabled,
      memory_initialized: state.memory_initialized,
      executor: state.executor_pid != nil
    )

    seed_emit_signal(:agent_started, %{
      id: id,
      type: :api_agent,
      model: state.model,
      provider: state.provider,
      memory_enabled: state.memory_enabled,
      memory_initialized: state.memory_initialized,
      executor_started: state.executor_pid != nil
    })

    {:ok, state}
  end

  @impl true
  def handle_call({:query, prompt, opts}, _from, state) do
    # Route through persistent Session
    case Arbor.Agent.SessionManager.get_session(state.id) do
      {:ok, session_pid} ->
        handle_session_query(prompt, opts, state, session_pid)

      {:error, _} ->
        # No session available — use direct API query
        handle_direct_query(prompt, opts, state)
    end
  end

  def handle_call(:agent_id, _from, state) do
    {:reply, state.id, state}
  end

  def handle_call(:get_working_memory, _from, state) do
    {:reply, {:ok, state.working_memory}, state}
  end

  def handle_call(:get_recalled_memories, _from, state) do
    {:reply, {:ok, state.recalled_memories}, state}
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
    case seed_handle_info(msg, state) do
      {:noreply, new_state} ->
        {:noreply, new_state}

      :not_handled ->
        handle_host_info(msg, state)
    end
  end

  @impl true
  def terminate(reason, state) do
    seed_terminate(reason, state)
  end

  # ============================================================================
  # Private: Host-Specific Info Handling
  # ============================================================================

  defp handle_host_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private: Query Handling
  # ============================================================================

  defp handle_session_query(prompt, opts, state, session_pid) do
    recall = Keyword.get(opts, :recall_memories, true) and state.memory_initialized
    index = Keyword.get(opts, :index_response, true) and state.memory_initialized

    {_enhanced_prompt, recalled, state} = prepare_query(prompt, state, enhance_prompt: false)
    recalled = if recall, do: recalled, else: []

    case GenServer.call(session_pid, {:send_message, prompt}, 300_000) do
      {:ok, text} ->
        new_state =
          if index do
            finalize_query(prompt, text, state)
          else
            state
          end

        response = %{
          text: text,
          thinking: nil,
          usage: %{},
          model: to_string(state.model),
          provider: to_string(state.provider),
          tool_calls: [],
          recalled_memories: recalled,
          session_id: state.id,
          type: :session
        }

        new_state = %{new_state | recalled_memories: recalled, query_count: state.query_count + 1}
        {:reply, {:ok, response}, new_state}

      {:error, reason} ->
        Logger.warning("Session query failed, falling back to direct: #{inspect(reason)}",
          agent_id: state.id
        )

        handle_direct_query(prompt, opts, state)
    end
  rescue
    e ->
      Logger.warning("Session query crashed, falling back to direct: #{Exception.message(e)}",
        agent_id: state.id
      )

      handle_direct_query(prompt, opts, state)
  end

  defp handle_direct_query(prompt, opts, state) do
    recall = Keyword.get(opts, :recall_memories, true) and state.memory_initialized
    index = Keyword.get(opts, :index_response, true) and state.memory_initialized

    {enhanced_prompt, recalled, state} = prepare_query(prompt, state, enhance_prompt: false)
    recalled = if recall, do: recalled, else: []

    case execute_query(enhanced_prompt, state, opts) do
      {:ok, response, new_state} ->
        text = response[:text] || ""
        tool_calls = response[:tool_calls] || []

        if text == "" and tool_calls == [] do
          Logger.warning("Empty response from API (no text, no tool calls)",
            agent_id: state.id,
            model: state.model,
            provider: state.provider
          )

          {:reply, {:error, :empty_response}, state}
        else
          new_state =
            if index do
              finalize_query(prompt, text, new_state)
            else
              new_state
            end

          enhanced_response =
            response
            |> Map.put(:recalled_memories, recalled)
            |> Map.put(:session_id, nil)

          new_state = %{new_state | recalled_memories: recalled}

          {:reply, {:ok, enhanced_response}, new_state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp execute_query(prompt, state, _opts) do
    prompt_opts = [state: state, model: state.model, provider: state.provider]

    # Stable system prompt (identity, self-knowledge, tools — cacheable)
    system_prompt = Arbor.AI.build_stable_system_prompt(state.id, prompt_opts)

    # Volatile context (goals, WM, KG, timing — changes each query)
    volatile_context = Arbor.AI.build_volatile_context(state.id, prompt_opts)

    # Prepend volatile context to user message
    full_prompt =
      if volatile_context not in ["", nil],
        do: volatile_context <> "\n\n---\n\n## User Message\n" <> prompt,
        else: prompt

    api_opts = [
      provider: state.provider,
      model: state.model,
      agent_id: state.id,
      system_prompt: system_prompt,
      max_tokens: state.max_tokens,
      temperature: state.temperature,
      auto_execute: true,
      max_turns: state.max_turns
    ]

    case Arbor.AI.generate_text_with_tools(full_prompt, api_opts) do
      {:ok, response} ->
        new_state = %{state | query_count: state.query_count + 1}

        emit_query_completed(state.id, state.model, response)

        {:ok, response, new_state}

      {:error, _} = error ->
        error
    end
  end

  defp emit_query_completed(agent_id, model, response) do
    seed_emit_signal(:query_completed, %{
      id: agent_id,
      type: :api_agent,
      model: model,
      tool_calls_count: length(response[:tool_calls] || [])
    })
  end

end
