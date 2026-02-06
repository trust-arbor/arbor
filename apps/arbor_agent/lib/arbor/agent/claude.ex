defmodule Arbor.Agent.Claude do
  @moduledoc """
  Claude Code agent integration for Arbor.

  This module provides the runtime integration between Claude Code and Arbor,
  including:

  - Query execution via AgentSDK
  - Thinking extraction from session files
  - Memory integration for thinking persistence
  - Signal emission for agent activities

  ## Architecture

  Claude Code runs as an external process (the CLI), but this module makes it
  a first-class Arbor citizen by:

  1. Wrapping queries through `Arbor.AI.AgentSDK`
  2. Extracting thinking blocks from session files after each query
  3. Recording thinking to `Arbor.Memory.Thinking`
  4. Emitting signals for significant events

  ## Usage

      # Start the agent
      {:ok, agent} = Arbor.Agent.Claude.start_link(id: "claude-main")

      # Send a query
      {:ok, response} = Arbor.Agent.Claude.query(agent, "What is 2+2?")

      # Query with thinking capture
      {:ok, response} = Arbor.Agent.Claude.query(agent, "Analyze this code",
        capture_thinking: true,
        model: :opus
      )

      # Get captured thinking
      {:ok, blocks} = Arbor.Agent.Claude.get_thinking(agent)
  """

  use GenServer

  require Logger

  alias Arbor.AI.AgentSDK
  alias Arbor.AI.SessionReader

  @type option ::
          {:id, String.t()}
          | {:model, atom()}
          | {:capture_thinking, boolean()}

  @type t :: GenServer.server()

  # Agent ID used for memory operations
  @default_id "claude-code"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the Claude agent.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Send a query to Claude and get a response.

  ## Options

  - `:model` - Model to use (`:opus`, `:sonnet`, `:haiku`)
  - `:capture_thinking` - Extract thinking from session file (default: true for opus)
  - `:timeout` - Response timeout in ms

  ## Returns

  The response map includes:
  - `:text` - The text response
  - `:thinking` - Captured thinking blocks (if any)
  - `:session_id` - Session ID for reference
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

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id, @default_id)
    default_model = Keyword.get(opts, :model, :sonnet)
    capture_thinking = Keyword.get(opts, :capture_thinking, true)

    state = %{
      id: id,
      default_model: default_model,
      capture_thinking: capture_thinking,
      last_session_id: nil,
      thinking_cache: [],
      query_count: 0
    }

    Logger.info("Claude agent started", id: id, model: default_model)
    emit_signal(:agent_started, %{id: id})

    {:ok, state}
  end

  @impl true
  def handle_call({:query, prompt, opts}, _from, state) do
    model = Keyword.get(opts, :model, state.default_model)
    capture = Keyword.get(opts, :capture_thinking, should_capture_thinking?(model, state))

    case execute_query(prompt, model, capture, state, opts) do
      {:ok, response, new_state} ->
        {:reply, {:ok, response}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stream, prompt, callback, opts}, _from, state) do
    model = Keyword.get(opts, :model, state.default_model)
    capture = Keyword.get(opts, :capture_thinking, should_capture_thinking?(model, state))

    case execute_stream(prompt, callback, model, capture, state, opts) do
      {:ok, response, new_state} ->
        {:reply, {:ok, response}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:get_thinking, _from, state) do
    {:reply, {:ok, state.thinking_cache}, state}
  end

  def handle_call(:agent_id, _from, state) do
    {:reply, state.id, state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.last_session_id, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Claude agent stopping", id: state.id, reason: inspect(reason))
    emit_signal(:agent_stopped, %{id: state.id, query_count: state.query_count})
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp should_capture_thinking?(model, state) do
    # Always capture for Opus, respect setting for others
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
