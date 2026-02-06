defmodule Arbor.AI.AgentSDK.Client do
  @moduledoc """
  Claude Agent SDK Client for Elixir.

  Provides a high-level interface for building agentic applications with Claude,
  including support for:

  - Extended thinking (reasoning traces with cryptographic signatures)
  - Tool use and custom tools
  - Multi-turn conversations with state
  - Streaming responses

  ## Architecture

  This is an Elixir implementation inspired by the official Claude Agent SDKs
  for Python and TypeScript. It communicates with the Claude Code CLI via
  a subprocess transport layer.

  ## Usage

      # Start a client
      {:ok, client} = Client.start_link(
        cwd: "/path/to/project",
        model: :opus,
        system_prompt: "You are a helpful coding assistant."
      )

      # Send a query and collect responses
      {:ok, response} = Client.query(client, "What is 2 + 2?")
      response.text      #=> "2 + 2 equals 4."
      response.thinking  #=> [%{text: "Simple arithmetic...", signature: "..."}]

      # Stream responses
      Client.stream(client, "Explain recursion", fn event ->
        case event do
          {:text, chunk} -> IO.write(chunk)
          {:thinking, block} -> IO.puts("[Thinking: \#{block.text}]")
          {:complete, response} -> IO.puts("\\nDone!")
        end
      end)

      # Close the client
      :ok = Client.close(client)

  ## Configuration Options

  - `:cwd` - Working directory for the Claude CLI
  - `:model` - Model to use (`:opus`, `:sonnet`, `:haiku`)
  - `:system_prompt` - System prompt for the conversation
  - `:max_turns` - Maximum conversation turns
  - `:allowed_tools` - List of allowed tool names
  - `:timeout` - Response timeout in milliseconds (default: 120_000)
  """

  use GenServer

  require Logger

  alias Arbor.AI.AgentSDK.Transport

  @type option ::
          {:cwd, String.t()}
          | {:model, atom() | String.t()}
          | {:system_prompt, String.t()}
          | {:max_turns, pos_integer()}
          | {:allowed_tools, [String.t()]}
          | {:timeout, pos_integer()}

  @type t :: GenServer.server()

  @type query_result :: %{
          text: String.t(),
          thinking: [map()] | nil,
          tool_uses: [map()],
          usage: map() | nil,
          session_id: String.t() | nil
        }

  @default_timeout 120_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a client process linked to the caller.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start a client process without linking.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Send a query and wait for the complete response.

  This is a blocking call that waits until Claude has finished
  responding, including any tool use and thinking.
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, query_result()} | {:error, term()}
  def query(client, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(client, {:query, prompt, opts}, timeout)
  end

  @doc """
  Stream responses from Claude, calling the callback for each event.

  Events include:
  - `{:text, chunk}` - Text chunk received
  - `{:thinking, block}` - Thinking block completed
  - `{:tool_use, tool_call}` - Tool use requested
  - `{:complete, response}` - Response complete

  Returns the final response after streaming completes.
  """
  @spec stream(t(), String.t(), (term() -> any()), keyword()) ::
          {:ok, query_result()} | {:error, term()}
  def stream(client, prompt, callback, opts \\ []) when is_function(callback, 1) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(client, {:stream, prompt, callback, opts}, timeout)
  end

  @doc """
  Continue the conversation with a follow-up message.

  This maintains the conversation context from previous exchanges.
  """
  @spec continue(t(), String.t(), keyword()) :: {:ok, query_result()} | {:error, term()}
  def continue(client, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(client, {:continue, message, opts}, timeout)
  end

  @doc """
  Get the current conversation history.
  """
  @spec history(t()) :: [map()]
  def history(client) do
    GenServer.call(client, :history)
  end

  @doc """
  Clear the conversation history and start fresh.
  """
  @spec clear_history(t()) :: :ok
  def clear_history(client) do
    GenServer.call(client, :clear_history)
  end

  @doc """
  Close the client and terminate the transport.
  """
  @spec close(t()) :: :ok
  def close(client) do
    GenServer.call(client, :close)
  end

  @doc """
  Check if the client is connected.
  """
  @spec connected?(t()) :: boolean()
  def connected?(client) do
    GenServer.call(client, :connected?)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    # Start transport with this process as receiver
    transport_opts = Keyword.put(opts, :receiver, self())

    case Transport.start_link(transport_opts) do
      {:ok, transport} ->
        state = %{
          transport: transport,
          opts: opts,
          history: [],
          pending_query: nil,
          current_response: new_response_acc(),
          stream_callback: nil
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:query, prompt, query_opts}, from, state) do
    # Merge options
    _opts = Keyword.merge(state.opts, query_opts)

    case Transport.send_prompt(state.transport, prompt) do
      :ok ->
        new_state = %{
          state
          | pending_query: from,
            current_response: new_response_acc(),
            stream_callback: nil
        }

        {:noreply, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stream, prompt, callback, query_opts}, from, state) do
    _opts = Keyword.merge(state.opts, query_opts)

    case Transport.send_prompt(state.transport, prompt) do
      :ok ->
        new_state = %{
          state
          | pending_query: from,
            current_response: new_response_acc(),
            stream_callback: callback
        }

        {:noreply, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:continue, message, _opts}, from, state) do
    case Transport.send_prompt(state.transport, message) do
      :ok ->
        new_state = %{
          state
          | pending_query: from,
            current_response: new_response_acc()
        }

        {:noreply, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:clear_history, _from, state) do
    {:reply, :ok, %{state | history: []}}
  end

  def handle_call(:close, _from, state) do
    Transport.close(state.transport)
    {:reply, :ok, state}
  end

  def handle_call(:connected?, _from, state) do
    connected = Transport.connected?(state.transport)
    {:reply, connected, state}
  end

  @impl true
  def handle_info({:claude_message, message}, state) do
    new_state = process_message(state, message)
    {:noreply, new_state}
  end

  def handle_info({:transport_closed, reason}, state) do
    Logger.info("Transport closed: #{inspect(reason)}")

    # If we have a pending query, reply with error
    if state.pending_query do
      GenServer.reply(state.pending_query, {:error, {:transport_closed, reason}})
    end

    {:noreply, %{state | pending_query: nil}}
  end

  def handle_info({:transport_error, error}, state) do
    Logger.warning("Transport error: #{inspect(error)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Client received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.transport do
      Transport.close(state.transport)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp new_response_acc do
    %{
      text_chunks: [],
      thinking_blocks: [],
      tool_uses: [],
      usage: nil,
      session_id: nil,
      model: nil
    }
  end

  defp process_message(state, %{"type" => "assistant", "message" => message}) do
    # Extract content from assistant message
    content = message["content"] || []

    acc =
      Enum.reduce(content, state.current_response, fn block, acc ->
        case block["type"] do
          "text" ->
            text = block["text"] || ""

            # Stream callback for text
            if state.stream_callback do
              state.stream_callback.({:text, text})
            end

            %{acc | text_chunks: [text | acc.text_chunks]}

          "thinking" ->
            thinking = %{
              text: block["thinking"] || "",
              signature: block["signature"]
            }

            # Stream callback for thinking
            if state.stream_callback do
              state.stream_callback.({:thinking, thinking})
            end

            %{acc | thinking_blocks: [thinking | acc.thinking_blocks]}

          "tool_use" ->
            tool_use = %{
              id: block["id"],
              name: block["name"],
              input: block["input"]
            }

            # Stream callback for tool use
            if state.stream_callback do
              state.stream_callback.({:tool_use, tool_use})
            end

            %{acc | tool_uses: [tool_use | acc.tool_uses]}

          _ ->
            acc
        end
      end)

    # Update model if present
    acc =
      if message["model"] do
        %{acc | model: message["model"]}
      else
        acc
      end

    %{state | current_response: acc}
  end

  defp process_message(state, %{"type" => "result"} = result) do
    # Result message signals completion
    acc = state.current_response

    # Extract usage and session info
    acc = %{
      acc
      | usage: result["usage"],
        session_id: result["session_id"]
    }

    # Build final response
    response = build_response(acc)

    # Add to history
    new_history = [
      %{role: :assistant, content: response.text, thinking: response.thinking}
      | state.history
    ]

    # Stream callback for completion
    if state.stream_callback do
      state.stream_callback.({:complete, response})
    end

    # Reply to pending query
    if state.pending_query do
      GenServer.reply(state.pending_query, {:ok, response})
    end

    %{state | pending_query: nil, current_response: new_response_acc(), history: new_history}
  end

  defp process_message(state, %{type: :thinking_complete, thinking: thinking}) do
    # Thinking block completed from streaming
    if state.stream_callback do
      Enum.each(thinking, fn block ->
        state.stream_callback.({:thinking, block})
      end)
    end

    acc = %{
      state.current_response
      | thinking_blocks: thinking ++ state.current_response.thinking_blocks
    }

    %{state | current_response: acc}
  end

  defp process_message(state, _message) do
    # Ignore other message types
    state
  end

  defp build_response(acc) do
    %{
      text: acc.text_chunks |> Enum.reverse() |> Enum.join(""),
      thinking: normalize_thinking(acc.thinking_blocks),
      tool_uses: Enum.reverse(acc.tool_uses),
      usage: acc.usage,
      session_id: acc.session_id,
      model: acc.model
    }
  end

  defp normalize_thinking([]), do: nil

  defp normalize_thinking(blocks) do
    blocks
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.text)
  end
end
