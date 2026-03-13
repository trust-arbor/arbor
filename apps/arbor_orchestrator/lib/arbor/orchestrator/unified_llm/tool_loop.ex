defmodule Arbor.Orchestrator.UnifiedLLM.ToolLoop do
  @moduledoc """
  Multi-turn tool-use loop for the unified LLM client.

  Sends a request with tools, executes any tool calls the LLM makes,
  feeds results back, and repeats until the LLM produces a final text
  response or a turn limit is reached.

  ## Options

    * `:max_turns` - Maximum tool-use round trips (default: 15)
    * `:workdir` - Working directory for file operations (default: ".")
    * `:on_tool_call` - Optional callback `fn name, args, result -> :ok end`
    * `:tools` - Tool definitions (default: `CodingTools.definitions()`)
    * `:tool_executor` - Module implementing `execute/3` (default: `CodingTools`)

  ## Example

      tools = CodingTools.definitions()
      request = %Request{
        provider: "openrouter",
        model: "openrouter/aurora-alpha",
        messages: [Message.new(:system, "..."), Message.new(:user, "...")],
        tools: tools
      }
      {:ok, response} = ToolLoop.run(client, request, workdir: "/path/to/project")
  """

  alias Arbor.Orchestrator.UnifiedLLM.{Client, CodingTools, ContentPart, Message, Request}
  alias Arbor.Orchestrator.Session.Builders

  @prompt_sanitizer Arbor.Common.PromptSanitizer

  @default_max_turns 15

  @spec run(Client.t(), Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(client, %Request{} = request, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    workdir = Keyword.get(opts, :workdir, ".")
    on_tool_call = Keyword.get(opts, :on_tool_call)
    tool_executor = Keyword.get(opts, :tool_executor, CodingTools)
    agent_id = Keyword.get(opts, :agent_id, "system")

    signer = Keyword.get(opts, :signer)
    tools = Keyword.get(opts, :tools, CodingTools.definitions())
    request = %{request | tools: tools}

    loop(client, request, opts, %{
      max_turns: max_turns,
      workdir: workdir,
      on_tool_call: on_tool_call,
      tool_executor: tool_executor,
      agent_id: agent_id,
      signer: signer,
      turn: 0,
      total_usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    })
  end

  defp loop(_client, _request, _opts, %{turn: turn, max_turns: max} = state)
       when turn >= max do
    {:error, {:max_turns_reached, turn, state.total_usage}}
  end

  defp loop(client, request, opts, state) do
    case call_llm(client, request, opts) do
      {:ok, response} ->
        state = merge_usage(state, response.usage)

        tool_calls =
          Enum.filter(response.content_parts, &(&1.kind == :tool_call))

        emit_tool_loop_signal(:tool_loop_response, %{
          agent_id: state.agent_id,
          turn: state.turn,
          finish_reason: response.finish_reason,
          tool_call_count: length(tool_calls),
          text_length: if(response.text, do: String.length(response.text), else: 0),
          text_preview: if(response.text, do: String.slice(response.text, 0..200), else: nil),
          content_parts_count: length(response.content_parts || []),
          content_parts_kinds: Enum.map(response.content_parts || [], & &1.kind),
          raw_finish_reason: (response.raw["choices"] || []) |> List.first() |> then(fn nil -> nil; c -> c["finish_reason"] end)
        })

        if tool_calls == [] and response.finish_reason == :tool_calls do
          require Logger
          Logger.warning("[ToolLoop] finish_reason=tool_calls but no tool_call parts! content_parts=#{inspect(response.content_parts)} raw=#{inspect(response.raw, limit: 500)}")
        end

        if response.finish_reason == :tool_calls and tool_calls != [] do
          # Execute each tool call
          {tool_results, state} =
            execute_tools(tool_calls, state)

          # Build the assistant message with its tool calls
          assistant_msg = build_assistant_message(response)

          # Build tool result messages
          tool_msgs = build_tool_messages(tool_results)

          # Append to conversation and continue
          updated_messages = request.messages ++ [assistant_msg | tool_msgs]
          next_request = %{request | messages: updated_messages}

          loop(client, next_request, opts, %{state | turn: state.turn + 1})
        else

          # Final response — return with accumulated usage
          {:ok,
           %{
             text: response.text,
             content_parts: response.content_parts,
             finish_reason: response.finish_reason,
             usage: state.total_usage,
             turns: state.turn + 1,
             raw: response.raw
           }}
        end

      {:error, _} = error ->
        emit_tool_loop_signal(:tool_loop_error, %{
          agent_id: state.agent_id,
          turn: state.turn,
          error: inspect(error)
        })

        error
    end
  end

  # Use streaming when a stream_callback is provided, otherwise Client.complete
  defp call_llm(client, request, opts) do
    case Keyword.get(opts, :stream_callback) do
      nil ->
        Client.complete(client, request, opts)

      callback ->
        case Client.stream(client, request, opts) do
          {:ok, events} ->
            events = Stream.each(events, fn event -> callback.(event) end)
            Client.collect_stream(events)

          {:error, {:stream_not_supported, _}} ->
            Client.complete(client, request, opts)

          {:error, _} = error ->
            error
        end
    end
  end

  defp execute_tools(tool_calls, state) do
    require Logger

    results =
      Enum.map(tool_calls, fn tc ->
        args = normalize_args(tc.arguments)

        emit_tool_loop_signal(:tool_call_started, %{
          agent_id: state.agent_id,
          tool: tc.name,
          args: args,
          turn: state.turn
        })

        start_time = System.monotonic_time(:millisecond)

        # Sign the tool call if a signer function is available.
        # Each tool call gets a fresh SignedRequest (unique nonce + timestamp).
        signed_request = sign_tool_call(state.signer, tc.name)

        exec_opts =
          [agent_id: state.agent_id]
          |> maybe_add_signed_request(signed_request)

        result = state.tool_executor.execute(tc.name, args, state.workdir, exec_opts)
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Logger.info("[ToolLoop] tool=#{tc.name} signed=#{signed_request != nil} result=#{match?({:ok, _}, result)} duration=#{duration_ms}ms")
        case result do
          {:error, reason} -> Logger.warning("[ToolLoop] tool=#{tc.name} ERROR: #{inspect(reason)}")
          {:ok, text} when is_binary(text) -> Logger.info("[ToolLoop] tool=#{tc.name} result_preview=#{String.slice(text, 0..200)}")
          _ -> :ok
        end

        emit_tool_loop_signal(:tool_call_completed, %{
          agent_id: state.agent_id,
          tool: tc.name,
          success: match?({:ok, _}, result),
          duration_ms: duration_ms,
          result_preview:
            case result do
              {:ok, text} when is_binary(text) -> String.slice(text, 0..200)
              {:error, reason} -> "ERROR: #{inspect(reason)}"
              _ -> inspect(result) |> String.slice(0..200)
            end
        })

        if state.on_tool_call do
          state.on_tool_call.(tc.name, args, result)
        end

        {tc.id, tc.name, result}
      end)

    {results, state}
  end

  # Sign a tool call with the resource URI as the payload.
  # Returns {:ok, signed_request} or nil if no signer is available.
  defp sign_tool_call(nil, _tool_name), do: nil

  defp sign_tool_call(signer, tool_name) when is_function(signer, 1) do
    resource = resolve_canonical_uri(tool_name)

    case signer.(resource) do
      {:ok, signed_request} -> signed_request
      {:error, _} -> nil
    end
  end

  # Resolve a tool name to its canonical facade URI via Arbor.Actions.
  # Falls back to legacy URI format when the actions module isn't available.
  defp resolve_canonical_uri(tool_name) do
    actions_mod = Module.concat([:Arbor, :Actions])

    if Code.ensure_loaded?(actions_mod) and
         function_exported?(actions_mod, :tool_name_to_canonical_uri, 1) do
      case apply(actions_mod, :tool_name_to_canonical_uri, [tool_name]) do
        {:ok, uri} -> uri
        :error -> "arbor://actions/execute/#{tool_name}"
      end
    else
      "arbor://actions/execute/#{tool_name}"
    end
  end

  defp maybe_add_signed_request(opts, nil), do: opts

  defp maybe_add_signed_request(opts, signed_request),
    do: [{:signed_request, signed_request} | opts]

  defp build_assistant_message(response) do
    # Reconstruct the assistant message including tool calls
    tool_call_parts =
      response.content_parts
      |> Enum.filter(&(&1.kind == :tool_call))
      |> Enum.map(fn tc ->
        ContentPart.tool_call(tc.id, tc.name, tc.arguments)
      end)

    text_parts =
      response.content_parts
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.map(fn tp -> ContentPart.text(tp.text) end)

    content = text_parts ++ tool_call_parts
    Message.new(:assistant, content)
  end

  defp build_tool_messages(tool_results) do
    nonce = @prompt_sanitizer.generate_nonce()

    Enum.map(tool_results, fn {call_id, name, result} ->
      {content, is_error} =
        case result do
          {:ok, text} ->
            {@prompt_sanitizer.wrap(truncate(text, 30_000), nonce), false}

          {:error, reason} ->
            {"Error: #{reason}", true}
        end

      Message.new(:tool, content, %{
        tool_call_id: call_id,
        name: name,
        is_error: is_error
      })
    end)
  end

  defp normalize_args(args) when is_map(args), do: args

  defp normalize_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"raw" => args}
    end
  end

  defp normalize_args(_), do: %{}

  defp merge_usage(state, nil), do: state

  defp merge_usage(state, usage) when is_map(usage) do
    merged = %{
      prompt_tokens:
        state.total_usage.prompt_tokens + (usage["prompt_tokens"] || usage[:prompt_tokens] || 0),
      completion_tokens:
        state.total_usage.completion_tokens +
          (usage["completion_tokens"] || usage[:completion_tokens] || 0),
      total_tokens:
        state.total_usage.total_tokens + (usage["total_tokens"] || usage[:total_tokens] || 0)
    }

    %{state | total_usage: merged}
  end

  defp truncate(text, max_len) when is_binary(text) do
    if byte_size(text) > max_len do
      String.slice(text, 0, max_len) <> "\n... (truncated)"
    else
      text
    end
  end

  defp truncate(other, _), do: inspect(other)

  # ── Signal Emission ──────────────────────────────────────────────

  defp emit_tool_loop_signal(event, data) do
    Builders.emit_signal(:agent, event, data)
  rescue
    _ -> :ok
  end
end
