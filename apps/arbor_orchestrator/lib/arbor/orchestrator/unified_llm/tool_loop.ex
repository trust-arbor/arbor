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

  alias Arbor.Contracts.Pipeline.Response, as: PipelineResponse

  alias Arbor.Orchestrator.UnifiedLLM.{
    ArborActionsExecutor,
    Client,
    ContentPart,
    Message,
    Request
  }

  alias Arbor.Orchestrator.Session.Builders

  @prompt_sanitizer Arbor.Common.PromptSanitizer

  @default_max_turns 50

  @spec run(Client.t(), Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(client, %Request{} = request, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    workdir = Keyword.get(opts, :workdir, ".")
    on_tool_call = Keyword.get(opts, :on_tool_call)
    tool_executor = Keyword.get(opts, :tool_executor, ArborActionsExecutor)
    agent_id = Keyword.get(opts, :agent_id, "system")

    signer = Keyword.get(opts, :signer)
    tools = Keyword.get(opts, :tools, ArborActionsExecutor.definitions())
    request = %{request | tools: tools}

    loop(client, request, opts, %{
      max_turns: max_turns,
      workdir: workdir,
      on_tool_call: on_tool_call,
      tool_executor: tool_executor,
      agent_id: agent_id,
      signer: signer,
      turn: 0,
      total_usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0},
      discovered_tools: [],
      accumulated_text: ""
    })
  end

  defp loop(client, request, _opts, %{turn: turn, max_turns: max} = state)
       when turn >= max do
    # Tool loop exhausted — make one final text-only call so the LLM
    # MUST respond with text instead of more tool calls
    require Logger

    Logger.info(
      "[ToolLoop] Hit #{max} turn limit. Making final text-only call for agent #{state.agent_id}"
    )

    # Strip tools and add instruction to respond with text only
    wrap_up_msg =
      Message.new(
        :system,
        "You have used all available tool call rounds. You MUST now respond with a text " <>
          "summary of what you accomplished and any remaining issues. Do NOT output any " <>
          "tool calls or JSON — respond in plain text only."
      )

    text_only_request = %{
      request
      | tools: [],
        messages: request.messages ++ [wrap_up_msg]
    }

    case call_llm(client, text_only_request, []) do
      {:ok, response} ->
        final_text = response.text || ""
        accumulated = Map.get(state, :accumulated_text, "")

        content =
          case {accumulated, final_text} do
            {"", ""} -> ""
            {"", text} -> text
            {acc, ""} -> acc
            {acc, text} -> acc <> "\n\n" <> text
          end

        {:ok,
         %PipelineResponse{
           content: content,
           content_parts: response.content_parts || [],
           usage: merge_usage_maps(state.total_usage, response.usage),
           tool_rounds: turn,
           finish_reason: :max_turns,
           discovered_tools: state.discovered_tools
         }}

      {:error, _} ->
        # Final call failed — fall back to accumulated text
        accumulated = Map.get(state, :accumulated_text, "")

        if accumulated != "" do
          {:ok,
           %PipelineResponse{
             content: accumulated,
             usage: state.total_usage,
             tool_rounds: turn,
             finish_reason: :max_turns,
             discovered_tools: state.discovered_tools
           }}
        else
          {:error, {:max_turns_reached, turn, state.total_usage}}
        end
    end
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
          raw_finish_reason:
            (response.raw["choices"] || [])
            |> List.first()
            |> then(fn
              nil -> nil
              c -> c["finish_reason"]
            end)
        })

        if tool_calls == [] and response.finish_reason == :tool_calls do
          require Logger

          Logger.warning(
            "[ToolLoop] finish_reason=tool_calls but no tool_call parts! content_parts=#{inspect(response.content_parts)} raw=#{inspect(response.raw, limit: 500)}"
          )
        end

        if response.finish_reason == :tool_calls and tool_calls != [] do
          # Execute each tool call
          {tool_results, state} =
            execute_tools(tool_calls, state)

          # Check if find_tools was called — inject discovered tools
          {state, new_tool_defs} = extract_discovered_tools(tool_results, state)

          # Preserve non-empty text from intermediate rounds
          state =
            if response.text && response.text != "" do
              Map.update(state, :accumulated_text, response.text, fn prev ->
                if prev == "" or is_nil(prev),
                  do: response.text,
                  else: prev <> "\n" <> response.text
              end)
            else
              state
            end

          # Build the assistant message with its tool calls
          assistant_msg = build_assistant_message(response)

          # Build tool result messages
          tool_msgs = build_tool_messages(tool_results)

          # Append to conversation and continue
          updated_messages = request.messages ++ [assistant_msg | tool_msgs]

          # Merge discovered tool definitions into request tools for next iteration
          next_tools = merge_tool_definitions(request.tools, new_tool_defs)
          next_request = %{request | messages: updated_messages, tools: next_tools}

          loop(client, next_request, opts, %{state | turn: state.turn + 1})
        else
          # Final response — return as normalized PipelineResponse
          if (response.text || "") == "" do
            require Logger

            Logger.warning(
              "[ToolLoop] Final response has empty text after #{state.turn + 1} tool rounds. " <>
                "finish_reason=#{inspect(response.finish_reason)} " <>
                "content_parts=#{inspect(Enum.map(response.content_parts || [], & &1.kind))} " <>
                "text=#{inspect(response.text, limit: 100)}"
            )
          end

          # Combine accumulated text from intermediate rounds with final response
          accumulated = Map.get(state, :accumulated_text) || ""
          final_response = if is_binary(response.text), do: String.trim(response.text), else: ""

          final_text =
            case {accumulated, final_response} do
              {"", ""} -> ""
              {"", text} -> text
              {acc, ""} -> acc
              {acc, text} -> acc <> "\n\n" <> text
            end

          {:ok,
           %PipelineResponse{
             content: final_text,
             content_parts: response.content_parts || [],
             finish_reason: response.finish_reason,
             usage: state.total_usage,
             tool_rounds: state.turn + 1,
             raw: response.raw,
             discovered_tools: state.discovered_tools
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

        Logger.info(
          "[ToolLoop] tool=#{tc.name} signed=#{signed_request != nil} result=#{match?({:ok, _}, result)} duration=#{duration_ms}ms"
        )

        case result do
          {:error, reason} ->
            Logger.warning("[ToolLoop] tool=#{tc.name} ERROR: #{inspect(reason)}")

          {:ok, text} when is_binary(text) ->
            Logger.info("[ToolLoop] tool=#{tc.name} result_preview=#{String.slice(text, 0..200)}")

          _ ->
            :ok
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

          {:ok, :pending_approval, proposal_id} ->
            {"Action #{name} requires approval. Proposal ID: #{proposal_id}. " <>
               "Waiting for consensus decision.", false}

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

  defp merge_usage_maps(a, nil), do: a
  defp merge_usage_maps(nil, b), do: b

  defp merge_usage_maps(a, b) when is_map(a) and is_map(b) do
    # Merge standard token counts (accumulated across tool rounds)
    base = %{
      prompt_tokens: add_usage_val(a, b, :prompt_tokens),
      completion_tokens: add_usage_val(a, b, :completion_tokens),
      total_tokens: add_usage_val(a, b, :total_tokens)
    }

    # Preserve provider-specific fields (cost, input_tokens, cache, etc.)
    # Cost may be a direct key or nested inside raw (OpenRouter)
    cost_b = Map.get(b, :cost) || get_in(b, [:raw, "cost"])
    cost_a = Map.get(a, :cost) || 0

    base
    |> then(fn m -> if cost_b, do: Map.put(m, :cost, (cost_a || 0) + cost_b), else: m end)
    |> add_optional(a, b, :input_tokens)
    |> add_optional(a, b, :output_tokens)
    |> add_optional(a, b, :cache_read_tokens)
    |> add_optional(a, b, :cache_write_tokens)
    |> add_optional(a, b, :reasoning_tokens)
    |> maybe_keep(b, :raw)
  end

  defp merge_usage(state, nil), do: state

  defp merge_usage(state, usage) when is_map(usage) do
    %{state | total_usage: merge_usage_maps(state.total_usage, usage)}
  end

  defp add_usage_val(a, b, key) do
    str_key = to_string(key)
    (Map.get(a, key, 0) || 0) + (Map.get(b, key) || Map.get(b, str_key) || 0)
  end

  # Accumulate numeric usage fields that may be present in provider responses
  defp add_optional(map, a, b, key) do
    str_key = to_string(key)
    val_a = Map.get(a, key, 0) || 0
    val_b = Map.get(b, key) || Map.get(b, str_key)

    cond do
      val_b != nil -> Map.put(map, key, val_a + val_b)
      val_a > 0 -> Map.put(map, key, val_a)
      true -> map
    end
  end

  defp maybe_keep(map, source, key) do
    case Map.get(source, key) do
      nil -> map
      val -> Map.put(map, key, val)
    end
  end

  defp truncate(text, max_len) when is_binary(text) do
    if byte_size(text) > max_len do
      String.slice(text, 0, max_len) <> "\n... (truncated)"
    else
      text
    end
  end

  defp truncate(other, _), do: inspect(other)

  # ── Progressive Tool Discovery ───────────────────────────────────

  # Extract discovered tool schemas from find_tools results and accumulate names
  defp extract_discovered_tools(tool_results, state) do
    {new_tool_defs, new_names} =
      Enum.reduce(tool_results, {[], []}, fn {_id, name, result}, {defs, names} ->
        if name == "find_tools" do
          case result do
            {:ok, json} when is_binary(json) ->
              case Jason.decode(json) do
                {:ok, %{"tools" => tools, "discovered_tool_names" => tool_names}}
                when is_list(tools) ->
                  {defs ++ tools, names ++ (tool_names || [])}

                _ ->
                  {defs, names}
              end

            _ ->
              {defs, names}
          end
        else
          {defs, names}
        end
      end)

    state = %{state | discovered_tools: (state.discovered_tools || []) ++ new_names}
    {state, new_tool_defs}
  end

  # Merge new tool definitions into existing tools, deduplicating by function name
  defp merge_tool_definitions(existing, []), do: existing

  defp merge_tool_definitions(existing, new_defs) do
    existing_names =
      MapSet.new(existing, fn
        %{"function" => %{"name" => n}} -> n
        _ -> nil
      end)

    unique_new =
      Enum.reject(new_defs, fn
        %{"function" => %{"name" => n}} -> MapSet.member?(existing_names, n)
        _ -> true
      end)

    existing ++ unique_new
  end

  # ── Signal Emission ──────────────────────────────────────────────

  defp emit_tool_loop_signal(event, data) do
    Builders.emit_signal(:agent, event, data)
  rescue
    _ -> :ok
  end
end
