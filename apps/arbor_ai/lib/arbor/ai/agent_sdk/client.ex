defmodule Arbor.AI.AgentSDK.Client do
  @moduledoc """
  Claude Agent SDK Client for Elixir.

  Provides a high-level interface for building agentic applications with Claude,
  including support for extended thinking (reasoning traces with signatures).

  ## Usage

      # Start a client
      {:ok, client} = Client.start_link(model: :opus)

      # Send a query and collect responses
      {:ok, response} = Client.query(client, "What is 2 + 2?")
      response.text      #=> "2 + 2 equals 4."
      response.thinking  #=> [%{text: "Simple arithmetic...", signature: "..."}]

      # Stream responses
      Client.stream(client, "Explain recursion", fn event ->
        case event do
          {:text, chunk} -> IO.write(chunk)
          {:thinking, block} -> IO.puts("[Thinking]")
          {:complete, response} -> IO.puts("Done!")
        end
      end)

      # Close the client
      :ok = Client.close(client)
  """

  use GenServer

  require Logger

  alias Arbor.AI.AgentSDK.Error
  alias Arbor.AI.AgentSDK.Hooks
  alias Arbor.AI.AgentSDK.Permissions
  alias Arbor.AI.AgentSDK.ToolServer
  alias Arbor.AI.AgentSDK.Transport

  @type option ::
          {:cwd, String.t()}
          | {:model, atom() | String.t()}
          | {:system_prompt, String.t()}
          | {:max_turns, pos_integer()}
          | {:timeout, pos_integer()}
          | {:hooks, Hooks.hooks()}
          | {:permission_mode, atom()}
          | {:allowed_tools, [String.t() | atom()]}
          | {:disallowed_tools, [String.t() | atom()]}

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
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, query_result()} | {:error, term()}
  def query(client, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(client, {:query, prompt, opts}, timeout)
  end

  @doc """
  Stream responses from Claude, calling the callback for each event.
  """
  @spec stream(t(), String.t(), (term() -> any()), keyword()) ::
          {:ok, query_result()} | {:error, term()}
  def stream(client, prompt, callback, opts \\ []) when is_function(callback, 1) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(client, {:stream, prompt, callback, opts}, timeout)
  end

  @doc """
  Close the client.
  """
  @spec close(t()) :: :ok
  def close(client) do
    GenServer.stop(client)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    hooks = Keyword.get(opts, :hooks, %{})

    state = %{
      opts: opts,
      transport: nil,
      pending_query: nil,
      current_response: new_response_acc(),
      stream_callback: nil,
      hooks: hooks,
      hook_context: Hooks.build_context(opts),
      tool_server: Keyword.get(opts, :tool_server)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:query, prompt, query_opts}, from, state) do
    opts = Keyword.merge(state.opts, query_opts)
    transport_opts = Keyword.put(opts, :prompt, prompt) |> Keyword.put(:receiver, self())

    case Transport.start_link(transport_opts) do
      {:ok, transport} ->
        new_state = %{
          state
          | transport: transport,
            pending_query: from,
            current_response: new_response_acc(),
            stream_callback: nil
        }

        {:noreply, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stream, prompt, callback, query_opts}, from, state) do
    opts = Keyword.merge(state.opts, query_opts)
    transport_opts = Keyword.put(opts, :prompt, prompt) |> Keyword.put(:receiver, self())

    case Transport.start_link(transport_opts) do
      {:ok, transport} ->
        new_state = %{
          state
          | transport: transport,
            pending_query: from,
            current_response: new_response_acc(),
            stream_callback: callback
        }

        {:noreply, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:claude_message, message}, state) do
    # Run on_message hooks
    if state.hooks != %{} do
      Hooks.run_message_hooks(state.hooks, message, state.hook_context)
    end

    new_state = process_message(state, message)
    {:noreply, new_state}
  end

  def handle_info({:transport_closed, status}, state) do
    Logger.debug("Transport closed with status #{status}")

    if state.pending_query do
      response = build_response(state.current_response)

      if response.text != "" or response.thinking != nil do
        GenServer.reply(state.pending_query, {:ok, response})
      else
        GenServer.reply(
          state.pending_query,
          {:error, Error.process_error(status, "")}
        )
      end
    end

    {:noreply, %{state | transport: nil, pending_query: nil}}
  end

  def handle_info({:transport_error, %Error{} = error}, state) do
    Logger.warning("Transport error: #{error.message}")

    if state.pending_query do
      GenServer.reply(state.pending_query, {:error, error})
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
    content = message["content"] || []

    acc =
      Enum.reduce(content, state.current_response, fn block, acc ->
        process_content_block(state, block, acc)
      end)

    acc =
      if message["model"] do
        %{acc | model: message["model"]}
      else
        acc
      end

    %{state | current_response: acc}
  end

  defp process_message(state, %{"type" => "result"} = result) do
    acc = %{
      state.current_response
      | usage: result["usage"],
        session_id: result["session_id"]
    }

    response = build_response(acc)

    if state.stream_callback do
      state.stream_callback.({:complete, response})
    end

    if state.pending_query do
      GenServer.reply(state.pending_query, {:ok, response})
    end

    %{state | pending_query: nil, current_response: new_response_acc()}
  end

  defp process_message(state, %{"type" => "user", "message" => message}) do
    content = message["content"] || []
    tool_use_result = message["tool_use_result"]

    # Match tool results back to their tool_uses by tool_use_id
    acc =
      Enum.reduce(content, state.current_response, fn
        %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => result_content}, acc ->
          is_error = message["is_error"] == true

          result_text =
            cond do
              is_binary(result_content) -> result_content
              tool_use_result && tool_use_result["stdout"] -> tool_use_result["stdout"]
              true -> inspect(result_content)
            end

          result = if is_error, do: {:error, result_text}, else: {:ok, result_text}

          updated_tool_uses =
            Enum.map(acc.tool_uses, fn tool ->
              if tool.id == tool_use_id, do: %{tool | result: result}, else: tool
            end)

          notify_stream(state, {:tool_result, %{tool_use_id: tool_use_id, result: result}})
          %{acc | tool_uses: updated_tool_uses}

        _, acc ->
          acc
      end)

    %{state | current_response: acc}
  end

  defp process_message(state, %{type: :thinking_complete, thinking: thinking}) do
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
    state
  end

  defp process_content_block(state, %{"type" => "text"} = block, acc) do
    text = block["text"] || ""

    if state.stream_callback do
      state.stream_callback.({:text, text})
    end

    %{acc | text_chunks: [text | acc.text_chunks]}
  end

  defp process_content_block(state, %{"type" => "thinking"} = block, acc) do
    thinking = %{
      text: block["thinking"] || "",
      signature: block["signature"]
    }

    if state.stream_callback do
      state.stream_callback.({:thinking, thinking})
    end

    %{acc | thinking_blocks: [thinking | acc.thinking_blocks]}
  end

  defp process_content_block(state, %{"type" => "tool_use"} = block, acc) do
    tool_name = block["name"]
    tool_input = block["input"] || %{}

    # Step 1: Run pre-hooks
    case run_pre_hooks(state, tool_name, tool_input) do
      {:deny, reason} ->
        tool_use = %{
          id: block["id"],
          name: tool_name,
          input: tool_input,
          hook_result: :deny,
          result: {:error, Error.hook_denied(tool_name, to_string(reason))}
        }

        notify_stream(state, {:tool_use, tool_use})
        %{acc | tool_uses: [tool_use | acc.tool_uses]}

      {:allow, final_input} ->
        # Step 2: Try in-process execution or record CLI-handled
        case maybe_execute_tool(state, tool_name, final_input) do
          {:executed, result} ->
            run_post_hooks_for_tool(state, tool_name, final_input, result)

            tool_use = %{
              id: block["id"],
              name: tool_name,
              input: final_input,
              hook_result: :allow,
              result: result
            }

            notify_stream(state, {:tool_use, tool_use})
            %{acc | tool_uses: [tool_use | acc.tool_uses]}

          {:permission_denied, reason} ->
            tool_use = %{
              id: block["id"],
              name: tool_name,
              input: final_input,
              hook_result: :allow,
              result: {:error, Error.permission_denied(tool_name, reason)}
            }

            notify_stream(state, {:tool_use, tool_use})
            %{acc | tool_uses: [tool_use | acc.tool_uses]}

          :not_registered ->
            tool_use = %{
              id: block["id"],
              name: tool_name,
              input: final_input,
              hook_result: :allow,
              result: nil
            }

            notify_stream(state, {:tool_use, tool_use})
            %{acc | tool_uses: [tool_use | acc.tool_uses]}
        end
    end
  end

  defp process_content_block(_state, _block, acc), do: acc

  defp run_pre_hooks(%{hooks: hooks, hook_context: ctx}, tool_name, tool_input)
       when hooks != %{} do
    Hooks.run_pre_hooks(hooks, tool_name, tool_input, ctx)
  end

  defp run_pre_hooks(_state, _tool_name, tool_input), do: {:allow, tool_input}

  defp maybe_execute_tool(%{tool_server: nil}, _name, _input), do: :not_registered

  defp maybe_execute_tool(%{tool_server: server, opts: opts}, tool_name, tool_input) do
    if ToolServer.has_tool?(tool_name, server) do
      case Permissions.check_tool_allowed?(tool_name, opts) do
        :ok ->
          result = ToolServer.call_tool(tool_name, tool_input, server)
          {:executed, result}

        {:error, reason} ->
          {:permission_denied, reason}
      end
    else
      :not_registered
    end
  end

  defp run_post_hooks_for_tool(%{hooks: hooks, hook_context: ctx}, name, input, result)
       when hooks != %{} do
    Hooks.run_post_hooks(hooks, name, input, result, ctx)
  end

  defp run_post_hooks_for_tool(_state, _name, _input, _result), do: :ok

  defp notify_stream(%{stream_callback: nil}, _event), do: :ok
  defp notify_stream(%{stream_callback: cb}, event), do: cb.(event)

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
