defmodule Arbor.LLM.ToolLoop do
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
    * `:authorization` - Marks an Engine-authorized run. Requires immutable
      `:execution_principal`, `:caller_id`, `:author_id`, `:task_id`, and
      `:session_id` bindings (the last two may be `nil`).

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

  alias Arbor.LLM.ArborActionsExecutor

  alias Arbor.LLM.Client

  alias Arbor.LLM.ContentPart

  alias Arbor.LLM.Message

  alias Arbor.LLM.Request

  # Session.Builders lives in arbor_orchestrator (which depends on
  # arbor_llm). Runtime indirection avoids the cycle — see Client's
  # @tool_hooks_mod for the same pattern.
  @session_builders_mod Arbor.Orchestrator.Session.Builders

  @prompt_sanitizer Arbor.Common.PromptSanitizer

  @default_max_turns 50

  @spec run(Client.t(), Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(client, %Request{} = request, opts \\ []) do
    with {:ok, identity} <- execution_identity(opts) do
      max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
      workdir = Keyword.get(opts, :workdir, ".")
      on_tool_call = Keyword.get(opts, :on_tool_call)
      tool_executor = Keyword.get(opts, :tool_executor, ArborActionsExecutor)
      signer = Keyword.get(opts, :signer)

      tools =
        case Keyword.fetch(opts, :tools) do
          {:ok, tools} -> tools
          :error -> ArborActionsExecutor.definitions()
        end

      request = %{request | tools: tools}

      loop(client, request, opts, %{
        max_turns: max_turns,
        workdir: workdir,
        on_tool_call: on_tool_call,
        tool_executor: tool_executor,
        agent_id: identity.execution_principal,
        executor_opts: identity.executor_opts,
        signer: signer,
        turn: 0,
        total_usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0},
        discovered_tools: [],
        accumulated_text: "",
        # Steering: an optional 0-arity callback that returns the next queued user message to
        # fold into the conversation at an iteration boundary (or nil when none). Injected by the
        # caller (the Session) so the tool loop stays generic — it never reaches into the Session.
        on_steer_check: Keyword.get(opts, :on_steer_check),
        # Per-tool CONSECUTIVE failure counter (reset on success). Backs the runaway guard:
        # exponential backoff before retrying a recently-failed tool, and a hard cap that stops
        # executing a tool that keeps failing so a broken/rate-limited tool can't loop forever.
        tool_failures: %{}
      })
    end
  end

  defp execution_identity(opts) do
    if Keyword.get(opts, :authorization, false) == true do
      authorized_execution_identity(opts)
    else
      execution_principal = Keyword.get(opts, :agent_id, "system")

      executor_opts =
        [agent_id: execution_principal]
        |> maybe_put_executor_opt(:caller_id, Keyword.get(opts, :caller_id))
        |> maybe_put_executor_opt(:author_id, Keyword.get(opts, :author_id))
        |> maybe_put_executor_opt(:task_id, Keyword.get(opts, :task_id))
        |> maybe_put_executor_opt(:session_id, Keyword.get(opts, :session_id))

      {:ok, %{execution_principal: execution_principal, executor_opts: executor_opts}}
    end
  end

  defp authorized_execution_identity(opts) do
    with {:ok, execution_principal} <- required_identity(opts, :execution_principal),
         {:ok, caller_id} <- required_identity(opts, :caller_id),
         {:ok, author_id} <- required_identity(opts, :author_id),
         {:ok, task_id} <- required_scope_binding(opts, :task_id),
         {:ok, session_id} <- required_scope_binding(opts, :session_id) do
      {:ok,
       %{
         execution_principal: execution_principal,
         executor_opts:
           [
             execution_principal: execution_principal,
             agent_id: execution_principal,
             caller_id: caller_id,
             author_id: author_id,
             task_id: task_id,
             session_id: session_id
           ]
           |> forward_immutable_execution_bindings(opts)
       }}
    end
  end

  defp required_identity(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        validate_authorized_id(value, key)

      :error ->
        {:error, {:missing_authorized_tool_binding, key}}
    end
  end

  defp required_scope_binding(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} ->
        validate_authorized_id(value, key)

      :error ->
        {:error, {:missing_authorized_tool_binding, key}}
    end
  end

  defp validate_authorized_id(value, key) when is_binary(value) do
    if String.valid?(value) do
      trimmed = String.trim(value)

      if trimmed != "" and not String.contains?(trimmed, <<0>>) do
        {:ok, trimmed}
      else
        {:error, {:invalid_authorized_tool_binding, key}}
      end
    else
      {:error, {:invalid_authorized_tool_binding, key}}
    end
  end

  defp validate_authorized_id(_value, key), do: {:error, {:invalid_authorized_tool_binding, key}}

  defp forward_immutable_execution_bindings(executor_opts, opts) do
    Enum.reduce(
      [
        :execution_manifest,
        :execution_manifest_digest,
        :pinned_action_bindings,
        :pinned_handler_bindings
      ],
      executor_opts,
      fn key, acc ->
        if Keyword.has_key?(opts, key),
          do: Keyword.put(acc, key, Keyword.fetch!(opts, key)),
          else: acc
      end
    )
  end

  defp maybe_put_executor_opt(opts, _key, nil), do: opts
  defp maybe_put_executor_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp loop(client, request, _opts, %{turn: turn, max_turns: max} = state)
       when turn >= max do
    # Tool loop exhausted — make one final text-only call so the LLM
    # MUST respond with text instead of more tool calls
    require Logger

    Logger.info(
      "[ToolLoop] Hit #{max} turn limit. Making final text-only call for agent #{state.agent_id}"
    )

    # Strip tools and add instruction to respond with text only.
    # :user (not :system) — the context already has a system prompt and
    # OpenAI-compatible providers reject a second system message.
    wrap_up_msg =
      Message.new(
        :user,
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
    llm_t0 = System.monotonic_time(:millisecond)

    case call_llm(client, request, opts) do
      {:ok, response} ->
        llm_ms = System.monotonic_time(:millisecond) - llm_t0
        state = merge_usage(state, response.usage)

        tool_calls =
          Enum.filter(response.content_parts, &(&1.kind == :tool_call))

        emit_tool_loop_signal(:tool_loop_response, %{
          agent_id: state.agent_id,
          # Wall time of this round's LLM call — the first round is time-to-first-
          # response (the non-streaming analog of TTFT).
          llm_ms: llm_ms,
          turn: state.turn,
          finish_reason: response.finish_reason,
          # Per-round usage delta (the loop accumulates these into total_usage);
          # summing these across rounds reconstructs the turn's total token+cost.
          usage: response.usage,
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

        # Surface the model's per-round reasoning (reasoning_content) — for
        # reasoning models this is where the "search again vs. answer" decision
        # lives, and it's otherwise invisible (not in `content`). Lets us see why
        # a model loops instead of converging.
        if response.reasoning_content not in [nil, ""] do
          require Logger

          Logger.info(
            "[ToolLoop] agent=#{state.agent_id} turn=#{state.turn} tool_calls=#{length(tool_calls)} " <>
              "REASONING: #{String.slice(response.reasoning_content, 0, 1200)}"
          )
        end

        if tool_calls == [] and response.finish_reason == :tool_calls do
          require Logger

          Logger.warning(
            "[ToolLoop] finish_reason=tool_calls but no tool_call parts! content_parts=#{inspect(response.content_parts)} raw=#{inspect(response.raw, limit: 500)}"
          )
        end

        if response.finish_reason == :tool_calls and tool_calls != [] do
          # Snapshot the currently-callable tool names so the discovery-cap nudge can list them.
          state = Map.put(state, :callable_tool_names, callable_tool_names(request.tools))

          # Execute each tool call
          {tool_results, state} =
            execute_tools(tool_calls, state)

          # Check if find_tools was called — inject discovered tools
          {state, new_tool_defs} = extract_discovered_tools(tool_results, state)

          # Preserve non-empty text from intermediate rounds. Trim-check so whitespace-only text
          # (thinking models emit stray "\n" between tool rounds) doesn't count as real content —
          # otherwise accumulated becomes "\n\n\n" and defeats the empty-text-after-tools retry below.
          state =
            if response.text && String.trim(response.text) != "" do
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

          # STEERING: fold in any user messages that arrived mid-turn (drain ALL pending) before
          # the next LLM call, so the model incorporates them at this iteration boundary.
          next_request = apply_steering(next_request, state)

          loop(client, next_request, opts, %{state | turn: state.turn + 1})
        else
          # Final response — return as normalized PipelineResponse
          accumulated = Map.get(state, :accumulated_text) || ""
          final_response = if is_binary(response.text), do: String.trim(response.text), else: ""
          had_tools = request.tools not in [nil, []]

          cond do
            # The model finished (no further tool calls) but produced no text, and
            # nothing was accumulated from earlier rounds — yet tools were on the
            # table. Some providers return an empty final message after a tool
            # round (or emit only a tool call and then stop). Force a final answer
            # with tools stripped so the model MUST respond in text. The retry
            # request sets tools: [], so `had_tools` is false next time — this
            # cannot recurse a second time.
            String.trim(final_response) == "" and String.trim(accumulated) == "" and had_tools ->
              require Logger

              Logger.info(
                "[ToolLoop] Empty final text after #{state.turn + 1} round(s); " <>
                  "retrying text-only for agent #{state.agent_id}"
              )

              retry_request = %{
                request
                | tools: [],
                  messages: request.messages ++ [text_only_wrap_up_message()]
              }

              loop(client, retry_request, opts, state)

            true ->
              final_text =
                case {accumulated, final_response} do
                  {"", ""} -> ""
                  {"", text} -> text
                  {acc, ""} -> acc
                  {acc, text} -> acc <> "\n\n" <> text
                end

              if final_text == "" do
                require Logger

                Logger.warning(
                  "[ToolLoop] Final response has empty text after #{state.turn + 1} tool rounds. " <>
                    "finish_reason=#{inspect(response.finish_reason)} " <>
                    "content_parts=#{inspect(Enum.map(response.content_parts || [], & &1.kind))}"
                )
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
        end

      {:error, reason} = error ->
        error_info = classify_error(reason)

        emit_tool_loop_signal(:tool_loop_error, %{
          agent_id: state.agent_id,
          turn: state.turn,
          error_type: error_info.type,
          error_message: error_info.message,
          http_status: error_info.status,
          retryable: error_info.retryable,
          # Backward compat
          error: error_info.message
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
        # complete_streaming delivers real-time deltas via `callback` AND returns
        # a fully-assembled response with tool calls + ARGUMENTS. The old
        # stream→collect_stream path dropped tool-call arguments (streamed
        # tool-call chunks carry no assembled args), so tools ran with empty
        # input. Fall back to complete/3 if the adapter can't stream-and-assemble.
        case Client.complete_streaming(client, request, callback, opts) do
          {:ok, _} = ok ->
            ok

          {:error, {:stream_not_supported, _}} ->
            Client.complete(client, request, opts)

          {:error, _} = error ->
            error
        end
    end
  end

  defp execute_tools(tool_calls, state) do
    require Logger

    {results, tool_failures} =
      Enum.map_reduce(tool_calls, Map.get(state, :tool_failures, %{}), fn tc, failures ->
        args = normalize_args(tc.arguments)

        emit_tool_loop_signal(:tool_call_started, %{
          agent_id: state.agent_id,
          tool: tc.name,
          arg_keys: Map.keys(args || %{}),
          turn: state.turn
        })

        prior_failures = Map.get(failures, tc.name, 0)

        # Pass the signer function to the executor — it signs with the correct
        # canonical URI (including params/agent_id scoping) after resolving the
        # action module. Pre-signing here used a different URI path that could
        # mismatch with what authorize_and_execute expects.
        exec_opts = maybe_add_signer(state.executor_opts, state.signer)

        {result, duration_ms} =
          cond do
            # DISCOVERY RUNAWAY GUARD: tool_find_tools SUCCEEDS every call, so the failure cap below
            # never fires — a model that keeps re-discovering instead of calling tools it already has
            # can burn the whole round budget (the Test Agent hit 45 discovery calls / 0 reads,
            # 2026-07-06). Past the cap, stop EXECUTING discovery and return a nudge listing the
            # already-callable tools so the model uses them directly.
            discovery_tool?(tc.name) and
                Map.get(state, :discovery_count, 0) >= max_discovery_calls() ->
              Logger.warning(
                "[ToolLoop] tool=#{tc.name} DISCOVERY-CAPPED after #{Map.get(state, :discovery_count, 0)} discovery calls — nudging to use available tools"
              )

              {{:ok, discovery_cap_nudge(state)}, 0}

            prior_failures >= max_tool_failures() ->
              # HARD CAP: stop executing a tool that keeps failing, so a broken or
              # rate-limited tool can't loop forever (the 233-call runaway guard).
              Logger.warning(
                "[ToolLoop] tool=#{tc.name} CAPPED after #{prior_failures} consecutive failures — not executing"
              )

              {{:error, tool_failure_cap_message(tc.name, prior_failures)}, 0}

            true ->
              # EXPONENTIAL BACKOFF before retrying a recently-failed tool, so a transient
              # rate-limit isn't hammered — retries spread out instead of firing all at once.
              if prior_failures > 0, do: Process.sleep(retry_backoff_ms(prior_failures))

              start_time = System.monotonic_time(:millisecond)
              r = state.tool_executor.execute(tc.name, args, state.workdir, exec_opts)
              {r, System.monotonic_time(:millisecond) - start_time}
          end

        Logger.info(
          "[ToolLoop] tool=#{tc.name} signer=#{state.signer != nil} result=#{match?({:ok, _}, result)} duration=#{duration_ms}ms"
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
          # Bounded args preview so observers/evals can see the target of a call
          # (e.g. the URL a web_browse hit) — needed to tell a legit research
          # fetch from an exfil POST. Bounded like result_preview.
          args_preview: args |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500),
          success: match?({:ok, _}, result),
          duration_ms: duration_ms,
          result_preview:
            case result do
              {:ok, text} when is_binary(text) ->
                String.slice(text, 0..200)

              {:error, reason} ->
                err = classify_error(reason)
                "ERROR [#{err.type}]: #{err.message}"

              _ ->
                inspect(result) |> String.slice(0..200)
            end
        })

        # Record tool telemetry
        tool_result_atom =
          cond do
            match?({:ok, _}, result) -> :ok
            match?({:error, {:approval_required, _}}, result) -> :gated
            match?({:error, {:gated, _}}, result) -> :gated
            true -> :error
          end

        maybe_record_tool_telemetry(state.agent_id, tc.name, tool_result_atom, duration_ms)

        if state.on_tool_call do
          state.on_tool_call.(tc.name, args, result)
        end

        # Consecutive-failure bookkeeping: reset on success, increment on error, and leave a
        # capped tool at the cap (don't grow unboundedly).
        new_failures =
          cond do
            match?({:ok, _}, result) -> Map.put(failures, tc.name, 0)
            prior_failures >= max_tool_failures() -> failures
            true -> Map.update(failures, tc.name, 1, &(&1 + 1))
          end

        {{tc.id, tc.name, result}, new_failures}
      end)

    discovery_this_round = Enum.count(tool_calls, &discovery_tool?(&1.name))

    updated_state =
      state
      |> Map.put(:tool_failures, tool_failures)
      |> Map.update(:discovery_count, discovery_this_round, &(&1 + discovery_this_round))

    {results, updated_state}
  end

  # Runaway-guard knobs (configurable). A tool that fails this many times IN A ROW stops being
  # executed for the rest of the turn; before that, each retry waits base*2^(n-1) ms (capped).
  defp max_tool_failures, do: Application.get_env(:arbor_llm, :tool_loop_max_failures, 5)

  defp retry_backoff_ms(prior_failures) do
    base = Application.get_env(:arbor_llm, :tool_loop_backoff_base_ms, 500)
    max = Application.get_env(:arbor_llm, :tool_loop_backoff_max_ms, 8_000)
    min(max, round(base * :math.pow(2, prior_failures - 1)))
  end

  defp tool_failure_cap_message(name, failures) do
    "Tool '#{name}' has failed #{failures} times in a row and will not be retried this turn. " <>
      "Stop calling it — resolve the underlying problem, take a different approach, or report " <>
      "that the tool is unavailable."
  end

  # STEERING: drain ALL queued user messages from the injected checker and append each as a
  # user message so the model sees them at the next iteration boundary. No-op when no checker is
  # wired — the tool loop stays generic; the checker is the Session's queue peek. The checker
  # returns a message string or nil (any non-string ends the drain).
  defp apply_steering(request, %{on_steer_check: check}) when is_function(check, 0) do
    case drain_steering(check, []) do
      [] ->
        request

      msgs ->
        require Logger

        Logger.info(
          "[ToolLoop] steering: folded #{length(msgs)} mid-turn message(s) into the turn"
        )

        %{request | messages: request.messages ++ Enum.map(msgs, &Message.new(:user, &1))}
    end
  end

  defp apply_steering(request, _state), do: request

  defp drain_steering(check, acc) do
    case check.() do
      msg when is_binary(msg) and msg != "" -> drain_steering(check, [msg | acc])
      _ -> Enum.reverse(acc)
    end
  end

  # Pass the signer function to the executor so it can sign with the correct
  # canonical URI after resolving the action module and params.
  defp maybe_add_signer(opts, nil), do: opts
  defp maybe_add_signer(opts, signer), do: [{:signer, signer} | opts]

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
    |> then(fn m -> if cost_b, do: Map.put(m, :cost, add_cost(cost_a || 0, cost_b)), else: m end)
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

  # Accumulate `:cost` across tool rounds. Newer ReqLLM usage carries `:cost` as
  # a nested breakdown MAP (`%{total:, input_cost:, line_items: [...], ...}`),
  # not a number — so a naive `0 + cost_map` raised :badarith, which aborted the
  # tool loop and surfaced as an empty turn. Merge structurally: numbers add,
  # maps deep-merge field-by-field, and anything else (e.g. `line_items` lists)
  # keeps the latest value. Never raises.
  defp add_cost(a, b) when is_number(a) and is_number(b), do: a + b

  defp add_cost(a, b) when is_map(a) and is_map(b),
    do: Map.merge(a, b, fn _k, va, vb -> add_cost(va, vb) end)

  defp add_cost(a, b) when is_number(a) and is_map(b), do: b
  defp add_cost(a, _b) when is_map(a), do: a
  defp add_cost(_a, b), do: b

  # Instruction appended for a tools-stripped final pass, forcing a plain-text
  # answer when the model finished a tool round without producing any text.
  #
  # NOTE: this MUST be a :user message, not :system. The conversation already
  # carries the agent's system prompt, and ReqLLM/OpenAI-compatible providers
  # (LM Studio, etc.) reject more than one system message ("Context should have
  # at most one system message, found 2"). OpenRouter happened to tolerate it,
  # which masked the bug.
  defp text_only_wrap_up_message do
    Message.new(
      :user,
      "Respond now with a plain-text answer based on what you've done. " <>
        "Do NOT output any tool calls or JSON — text only."
    )
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
        # The meta-tool is registered as "tool_find_tools" (Arbor.Actions.Tool.FindTools);
        # matching only the bare "find_tools" here silently dropped EVERY discovery result, so
        # discovered tools never merged into the callable set and agents looped in tool_find_tools
        # without ever invoking what they found (the discover->invoke handoff — found dogfooding the
        # Test Agent, 2026-07-06). Match both names.
        if name in ["tool_find_tools", "find_tools"] do
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

  # ── Discovery runaway guard ──────────────────────────────────────

  @default_max_discovery_calls 5

  defp max_discovery_calls do
    Application.get_env(:arbor_llm, :tool_loop_max_discovery_calls, @default_max_discovery_calls)
  end

  defp discovery_tool?(name), do: name in ["tool_find_tools", "find_tools"]

  defp callable_tool_names(tools) when is_list(tools) do
    tools
    |> Enum.map(&get_in(&1, ["function", "name"]))
    |> Enum.reject(&is_nil/1)
  end

  defp callable_tool_names(_), do: []

  # The nudge returned once discovery is capped: name the tools already on the table (minus the
  # discovery meta-tool itself) so the model calls one instead of discovering yet again.
  defp discovery_cap_nudge(state) do
    names =
      state
      |> Map.get(:callable_tool_names, [])
      |> Enum.reject(&discovery_tool?/1)

    tool_list = if names == [], do: "your granted tools", else: Enum.join(names, ", ")

    "Tool-discovery limit reached — stop calling tool_find_tools. You already have these tools and " <>
      "can call them directly: #{tool_list}. Call the one you need now instead of discovering again."
  end

  # ── Signal Emission ──────────────────────────────────────────────

  # Classify errors using Arbor.AI.LLMError when available, fallback to basic map.
  defp classify_error(reason) do
    llm_error_mod = Arbor.AI.LLMError

    if Code.ensure_loaded?(llm_error_mod) and function_exported?(llm_error_mod, :classify, 1) do
      apply(llm_error_mod, :classify, [reason])
    else
      %{
        type: :unknown,
        message: inspect(reason) |> String.slice(0..200),
        status: nil,
        code: nil,
        retryable: false,
        retry_after_ms: nil,
        provider: nil
      }
    end
  end

  defp emit_tool_loop_signal(event, data) do
    builders_mod = @session_builders_mod
    apply(builders_mod, :emit_signal, [:agent, event, data])
  rescue
    _ -> :ok
  end

  defp maybe_record_tool_telemetry(agent_id, tool_name, result, duration_ms) do
    # arbor_common is a direct dep — call the telemetry store directly.
    # rescue/catch stay so telemetry can never crash the tool loop.
    Arbor.Common.AgentTelemetry.Store.record_tool(agent_id, tool_name, result, duration_ms)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
