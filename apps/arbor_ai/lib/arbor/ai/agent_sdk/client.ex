defmodule Arbor.AI.AgentSDK.Client do
  @moduledoc """
  Claude Agent SDK Client for Elixir.

  Provides a high-level interface for building agentic applications with Claude,
  including support for extended thinking (reasoning traces with signatures).

  ## Usage

      # Start a client (opens persistent CLI connection)
      {:ok, client} = Client.start_link(model: :opus)

      # Send a query and collect responses
      {:ok, response} = Client.query(client, "What is 2 + 2?")
      response.text      #=> "2 + 2 equals 4."
      response.thinking  #=> [%{text: "Simple arithmetic...", signature: "..."}]

      # Multi-turn conversation
      {:ok, r2} = Client.query(client, "What about 3 + 3?")

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

  Opens a persistent Transport connection to the Claude CLI eagerly.
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
  Close the client and its Transport connection.
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

    # Allow injecting an existing transport (for testing)
    case Keyword.get(opts, :transport) do
      nil ->
        # Start the persistent Transport eagerly
        transport_opts = Keyword.put(opts, :receiver, self())

        case Transport.start_link(transport_opts) do
          {:ok, transport} ->
            {:ok, build_state(opts, transport, hooks)}

          {:error, reason} ->
            {:stop, reason}
        end

      transport when is_pid(transport) ->
        {:ok, build_state(opts, transport, hooks)}
    end
  end

  defp build_state(opts, transport, hooks) do
    %{
      opts: opts,
      transport: transport,
      transport_ready: false,
      pending_queries: %{},
      hooks: hooks,
      hook_context: Hooks.build_context(opts),
      tool_server: Keyword.get(opts, :tool_server)
    }
  end

  @impl true
  def handle_call({:query, prompt, _query_opts}, from, state) do
    case Transport.send_query(state.transport, prompt) do
      {:ok, query_ref} ->
        pending =
          Map.put(state.pending_queries, query_ref, %{
            from: from,
            response: new_response_acc(),
            callback: nil
          })

        {:noreply, %{state | pending_queries: pending}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stream, prompt, callback, _query_opts}, from, state) do
    case Transport.send_query(state.transport, prompt) do
      {:ok, query_ref} ->
        pending =
          Map.put(state.pending_queries, query_ref, %{
            from: from,
            response: new_response_acc(),
            callback: callback
          })

        {:noreply, %{state | pending_queries: pending}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:transport_ready}, state) do
    Logger.debug("Transport ready")
    {:noreply, %{state | transport_ready: true}}
  end

  def handle_info({:claude_message, query_ref, message}, state) do
    case Map.get(state.pending_queries, query_ref) do
      nil ->
        Logger.debug("Received message for unknown query_ref, ignoring")
        {:noreply, state}

      pending ->
        # Run on_message hooks
        if state.hooks != %{} do
          Hooks.run_message_hooks(state.hooks, message, state.hook_context)
        end

        {new_pending, new_state} = process_message(state, query_ref, pending, message)
        {:noreply, new_state |> Map.put(:pending_queries, new_pending)}
    end
  end

  def handle_info({:transport_closed, reason}, state) do
    Logger.debug("Transport closed: #{inspect(reason)}")

    # Reply error to all pending queries
    Enum.each(state.pending_queries, fn {_ref, pending} ->
      response = build_response(pending.response)

      if response.text != "" or response.thinking != nil do
        GenServer.reply(pending.from, {:ok, response})
      else
        GenServer.reply(pending.from, {:error, Error.process_error(0, "Transport closed")})
      end
    end)

    {:noreply, %{state | pending_queries: %{}, transport_ready: false}}
  end

  def handle_info({:transport_error, query_ref, %Error{} = error}, state) do
    Logger.warning("Transport error for query: #{error.message}")

    case Map.pop(state.pending_queries, query_ref) do
      {nil, _} ->
        {:noreply, state}

      {pending, remaining} ->
        GenServer.reply(pending.from, {:error, error})
        {:noreply, %{state | pending_queries: remaining}}
    end
  end

  def handle_info({:transport_error, _ref, error}, state) do
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

  defp process_message(state, query_ref, pending, %{"type" => "assistant", "message" => message}) do
    content = message["content"] || []

    # Build processing context with hooks + tool_server from state
    ctx = %{
      callback: pending.callback,
      hooks: state.hooks,
      hook_context: state.hook_context,
      tool_server: state.tool_server,
      opts: state.opts
    }

    acc =
      Enum.reduce(content, pending.response, fn block, acc ->
        process_content_block(ctx, block, acc)
      end)

    acc =
      if message["model"] do
        %{acc | model: message["model"]}
      else
        acc
      end

    updated = %{pending | response: acc}
    {Map.put(state.pending_queries, query_ref, updated), state}
  end

  defp process_message(state, query_ref, pending, %{"type" => "result"} = result) do
    acc = %{
      pending.response
      | usage: result["usage"],
        session_id: result["session_id"]
    }

    response = build_response(acc)

    if pending.callback do
      pending.callback.({:complete, response})
    end

    GenServer.reply(pending.from, {:ok, response})

    {Map.delete(state.pending_queries, query_ref), state}
  end

  defp process_message(state, query_ref, pending, %{"type" => "user", "message" => message}) do
    content = message["content"] || []
    tool_use_result = message["tool_use_result"]

    acc =
      Enum.reduce(content, pending.response, fn
        %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => result_content},
        acc ->
          is_error = message["is_error"] == true

          result_text =
            cond do
              is_binary(result_content) -> result_content
              tool_use_result && tool_use_result["stdout"] -> tool_use_result["stdout"]
              true -> inspect(result_content)
            end

          result = if is_error, do: {:error, result_text}, else: {:ok, result_text}

          updated_tool_uses =
            Enum.map(acc.tool_uses, &match_tool_result(&1, tool_use_id, result))

          notify_stream(pending, {:tool_result, %{tool_use_id: tool_use_id, result: result}})
          %{acc | tool_uses: updated_tool_uses}

        _, acc ->
          acc
      end)

    updated = %{pending | response: acc}
    {Map.put(state.pending_queries, query_ref, updated), state}
  end

  defp process_message(state, query_ref, pending, %{type: :thinking_complete, thinking: thinking}) do
    if pending.callback do
      Enum.each(thinking, fn block ->
        pending.callback.({:thinking, block})
      end)
    end

    acc = %{
      pending.response
      | thinking_blocks: thinking ++ pending.response.thinking_blocks
    }

    updated = %{pending | response: acc}
    {Map.put(state.pending_queries, query_ref, updated), state}
  end

  defp process_message(state, _query_ref, _pending, _message) do
    {state.pending_queries, state}
  end

  defp match_tool_result(%{id: id} = tool, id, result), do: %{tool | result: result}
  defp match_tool_result(tool, _id, _result), do: tool

  defp process_content_block(ctx, %{"type" => "text"} = block, acc) do
    text = block["text"] || ""

    if ctx.callback do
      ctx.callback.({:text, text})
    end

    %{acc | text_chunks: [text | acc.text_chunks]}
  end

  defp process_content_block(ctx, %{"type" => "thinking"} = block, acc) do
    thinking = %{
      text: block["thinking"] || "",
      signature: block["signature"]
    }

    if ctx.callback do
      ctx.callback.({:thinking, thinking})
    end

    %{acc | thinking_blocks: [thinking | acc.thinking_blocks]}
  end

  defp process_content_block(ctx, %{"type" => "tool_use"} = block, acc) do
    tool_name = block["name"]
    tool_input = block["input"] || %{}

    # Step 1: Run pre-hooks
    case run_pre_hooks(ctx, tool_name, tool_input) do
      {:deny, reason} ->
        tool_use = %{
          id: block["id"],
          name: tool_name,
          input: tool_input,
          hook_result: :deny,
          result: {:error, Error.hook_denied(tool_name, to_string(reason))}
        }

        notify_stream(ctx, {:tool_use, tool_use})
        %{acc | tool_uses: [tool_use | acc.tool_uses]}

      {:allow, final_input} ->
        # Step 2: Try in-process execution or record CLI-handled
        case maybe_execute_tool(ctx, tool_name, final_input) do
          {:executed, result} ->
            run_post_hooks(ctx, tool_name, final_input, result)

            tool_use = %{
              id: block["id"],
              name: tool_name,
              input: final_input,
              hook_result: :allow,
              result: result
            }

            notify_stream(ctx, {:tool_use, tool_use})
            %{acc | tool_uses: [tool_use | acc.tool_uses]}

          {:permission_denied, reason} ->
            tool_use = %{
              id: block["id"],
              name: tool_name,
              input: final_input,
              hook_result: :allow,
              result: {:error, Error.permission_denied(tool_name, reason)}
            }

            notify_stream(ctx, {:tool_use, tool_use})
            %{acc | tool_uses: [tool_use | acc.tool_uses]}

          :not_registered ->
            tool_use = %{
              id: block["id"],
              name: tool_name,
              input: final_input,
              hook_result: :allow,
              result: nil
            }

            notify_stream(ctx, {:tool_use, tool_use})
            %{acc | tool_uses: [tool_use | acc.tool_uses]}
        end
    end
  end

  defp process_content_block(_ctx, _block, acc), do: acc

  defp run_pre_hooks(%{hooks: hooks, hook_context: hook_ctx}, tool_name, tool_input)
       when hooks != %{} do
    Hooks.run_pre_hooks(hooks, tool_name, tool_input, hook_ctx)
  end

  defp run_pre_hooks(_ctx, _tool_name, tool_input), do: {:allow, tool_input}

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

  defp run_post_hooks(%{hooks: hooks, hook_context: hook_ctx}, name, input, result)
       when hooks != %{} do
    Hooks.run_post_hooks(hooks, name, input, result, hook_ctx)
  end

  defp run_post_hooks(_ctx, _name, _input, _result), do: :ok

  defp notify_stream(%{callback: nil}, _event), do: :ok
  defp notify_stream(%{callback: cb}, event), do: cb.(event)

  defp build_response(acc) do
    thinking = normalize_thinking(acc.thinking_blocks)

    Logger.debug(
      "[Client] build_response: #{length(acc.thinking_blocks)} raw thinking blocks -> " <>
        "#{inspect(thinking |> then(fn
          nil -> nil
          blocks -> length(blocks)
        end))} normalized, " <>
        "session: #{inspect(acc.session_id)}"
    )

    %{
      text: acc.text_chunks |> Enum.reverse() |> Enum.join(""),
      thinking: thinking,
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
