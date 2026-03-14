defmodule Arbor.Orchestrator.Handlers.LlmHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  require Logger

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  alias Arbor.Orchestrator.UnifiedLLM.{
    ArborActionsExecutor,
    Client,
    Message,
    Request,
    ToolLoop
  }

  import Arbor.Orchestrator.Handlers.Helpers

  alias Arbor.Orchestrator.Session.Builders

  @prompt_sanitizer Arbor.Common.PromptSanitizer

  @impl true
  def execute(node, context, graph, opts) do
    goal = Map.get(graph.attrs, "goal", "")

    prompt =
      case Map.get(node.attrs, "prompt_context_key") do
        nil ->
          node.attrs
          |> Map.get("prompt", Map.get(node.attrs, "label", node.id))
          |> String.replace("$goal", to_string(goal))

        key ->
          Context.get(context, key, Map.get(node.attrs, "prompt", node.id))
      end

    # In decision mode, perspective nodes should evaluate the council question,
    # not their own node ID
    prompt = maybe_use_council_question(prompt, node.attrs, graph.attrs, context)

    base_updates = %{
      "last_stage" => node.id,
      "last_prompt" => prompt,
      "context.previous_outcome" => Context.get(context, "outcome"),
      "llm.model" => Map.get(node.attrs, "llm_model") || Map.get(node.attrs, "model"),
      "llm.provider" => Map.get(node.attrs, "llm_provider") || Map.get(node.attrs, "handler"),
      "llm.reasoning_effort" => Map.get(node.attrs, "reasoning_effort"),
      "score" => parse_score(Map.get(node.attrs, "score"))
    }

    simulate_attr = Map.get(node.attrs, "simulate")

    case simulate_attr do
      "fail" ->
        %Outcome{
          status: :fail,
          failure_reason: "simulated failure",
          context_updates: Map.put(base_updates, "last_response", "[Simulated] failure")
        }

      "retry" ->
        %Outcome{
          status: :retry,
          failure_reason: "simulated retry",
          context_updates: Map.put(base_updates, "last_response", "[Simulated] retry")
        }

      "fail_once" ->
        key = "internal.simulate.fail_once.#{node.id}"
        attempts = Context.get(context, key, 0)

        if attempts == 0 do
          %Outcome{
            status: :fail,
            failure_reason: "simulated fail once",
            context_updates:
              base_updates
              |> Map.put("last_response", "[Simulated] fail once")
              |> Map.put(key, 1)
          }
        else
          response = "[Simulated] Response for stage: #{node.id}"
          _ = write_stage_artifacts(opts, node.id, prompt, response)

          %Outcome{
            status: :success,
            notes: "Stage completed: #{node.id}",
            context_updates: Map.put(base_updates, "last_response", response)
          }
        end

      "raise_retryable" ->
        raise "network timeout"

      "raise_terminal" ->
        raise "401 unauthorized"

      simulate when simulate in [nil, "true", true] ->
        Logger.warning("[LlmHandler] #{node.id}: SIMULATED (simulate=#{inspect(simulate_attr)})")

        # Simulation mode — no real LLM call
        response = "[Simulated] Response for stage: #{node.id}"
        _ = write_stage_artifacts(opts, node.id, prompt, response)

        %Outcome{
          status: :success,
          notes: "Stage completed: #{node.id}",
          context_updates: Map.put(base_updates, "last_response", response)
        }

      "false" ->
        # Real LLM call
        call_llm_and_respond(prompt, node, context, graph, base_updates, opts)
    end
  end

  @impl true
  def idempotency, do: :idempotent_with_key

  defp call_llm_and_respond(prompt, node, context, graph, base_updates, opts) do
    agent_id = Context.get(context, "session.agent_id", "?")
    prompt_len = if is_binary(prompt), do: String.length(prompt), else: 0
    msgs_count = context |> Context.get("session.messages", []) |> length()
    provider = Context.get(context, "session.llm_provider")
    model = Context.get(context, "session.llm_model")
    use_tools = Map.get(node.attrs, "use_tools") in ["true", true]

    Logger.info(
      "[LlmHandler] #{node.id} for #{agent_id}: " <>
        "prompt=#{prompt_len} chars, messages=#{msgs_count}, " <>
        "provider=#{provider}, model=#{model}"
    )

    emit_llm_signal(:llm_call_started, %{
      agent_id: agent_id,
      node_id: node.id,
      provider: provider,
      model: model,
      prompt_length: prompt_len,
      message_count: msgs_count,
      use_tools: use_tools
    })

    # Clear any stale routing decision from process dict
    Process.delete(:__routing_decision__)
    start_time = System.monotonic_time(:millisecond)

    case call_llm(prompt, node, context, graph, opts) do
      {:ok, response_text} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        resp_len = if is_binary(response_text), do: String.length(response_text), else: 0

        Logger.info(
          "[LlmHandler] #{node.id} for #{agent_id}: " <>
            "OK in #{elapsed}ms, response=#{resp_len} chars"
        )

        emit_llm_signal(:llm_call_completed, %{
          agent_id: agent_id,
          node_id: node.id,
          provider: provider,
          model: model,
          duration_ms: elapsed,
          response_length: resp_len,
          response_preview:
            if(is_binary(response_text), do: String.slice(response_text, 0..200), else: nil),
          use_tools: use_tools
        })

        _ = write_stage_artifacts(opts, node.id, prompt, response_text)

        updates =
          base_updates
          |> Map.put("last_response", response_text)
          |> maybe_put_perspective_key(node.attrs, response_text)
          |> maybe_put_routing_decision()
          |> maybe_put_discovered_tools()

        %Outcome{
          status: :success,
          notes: response_text,
          context_updates: updates
        }

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        Logger.warning(
          "[LlmHandler] #{node.id} for #{agent_id}: " <>
            "FAILED in #{elapsed}ms, reason=#{inspect(reason)}"
        )

        emit_llm_signal(:llm_call_failed, %{
          agent_id: agent_id,
          node_id: node.id,
          provider: provider,
          model: model,
          duration_ms: elapsed,
          error: inspect(reason),
          use_tools: use_tools
        })

        %Outcome{
          status: :fail,
          failure_reason: "LLM call failed: #{inspect(reason)}",
          context_updates: Map.put(base_updates, "last_response", nil)
        }
    end
  end

  defp call_llm(prompt, node, context, graph, opts) do
    client = Keyword.get(opts, :llm_client) || Client.default_client()
    nonce = @prompt_sanitizer.generate_nonce()

    {system_content, user_content} = build_llm_messages(prompt, node, context, graph, nonce)

    case build_llm_request(node, context, system_content, user_content) do
      {:ok, request} ->
        call_opts = build_call_opts(node, opts)
        on_stream = Keyword.get(opts, :on_stream)

        call_opts =
          if on_stream do
            Keyword.put(call_opts, :stream_callback, on_stream)
          else
            call_opts
          end

        use_tools = Map.get(node.attrs, "use_tools") in ["true", true]

        if use_tools do
          call_llm_with_tools(client, request, node, context, on_stream, opts)
        else
          call_llm_direct(client, request, call_opts, on_stream)
        end

      {:error, _} = error ->
        error
    end
  end

  defp build_llm_messages(prompt, node, context, graph, nonce) do
    previous_outcome =
      case Map.get(node.attrs, "context.previous_outcome") do
        nil -> ""
        outcome -> "\n\nPrevious stage outcome: #{@prompt_sanitizer.wrap(outcome, nonce)}"
      end

    goal = Map.get(graph.attrs, "goal", "")

    system_content =
      case Map.get(node.attrs, "system_prompt_context_key") do
        nil ->
          case Map.get(node.attrs, "system_prompt") do
            nil ->
              "You are a coding agent working on the following goal: #{@prompt_sanitizer.wrap(goal, nonce)}"

            sys ->
              sys
          end

        key ->
          Context.get(context, key, "You are a coding agent.")
      end

    system_content = @prompt_sanitizer.preamble(nonce) <> "\n\n" <> system_content
    system_content = maybe_prepend_vote_format(system_content, node.attrs, graph.attrs)
    user_content = prompt <> previous_outcome

    {system_content, user_content}
  end

  defp build_llm_request(node, context, system_content, user_content) do
    messages =
      case Map.get(node.attrs, "messages_context_key") do
        nil ->
          [
            Message.new(:system, system_content),
            Message.new(:user, user_content)
          ]

        key ->
          case Context.get(context, key) do
            msgs when is_list(msgs) and msgs != [] ->
              # Prepend system message, use context messages as conversation history
              [Message.new(:system, system_content) | to_messages(msgs)]

            _ ->
              [
                Message.new(:system, system_content),
                Message.new(:user, user_content)
              ]
          end
      end

    # Provider/model: node attrs take priority, fall back to context
    provider =
      Map.get(node.attrs, "llm_provider") ||
        Map.get(node.attrs, "handler") ||
        Context.get(context, "session.llm_provider")

    model =
      Map.get(node.attrs, "llm_model") ||
        Map.get(node.attrs, "model") ||
        Context.get(context, "session.llm_model")

    # Sensitivity routing: reroute if the current provider can't handle the data
    case maybe_route_by_sensitivity(provider, model, context) do
      {:error, _} = error ->
        error

      {routed_provider, routed_model} ->
        {:ok,
         %Request{
           provider: routed_provider,
           model: routed_model,
           messages: messages,
           max_tokens: parse_int(Map.get(node.attrs, "max_tokens"), 4096),
           temperature: parse_float(Map.get(node.attrs, "temperature"), 0.7),
           provider_options: Map.get(node.attrs, "provider_options", %{})
         }}
    end
  end

  defp to_messages(msgs) do
    msgs
    |> Enum.reject(&empty_assistant?/1)
    |> Enum.map(fn
      %Message{} = m ->
        m

      %{"role" => role, "content" => content} ->
        Message.new(String.to_existing_atom(role), content)

      %{role: role, content: content} ->
        Message.new(role, content)
    end)
  end

  defp empty_assistant?(%{"role" => "assistant", "content" => c}) when c in [nil, ""], do: true
  defp empty_assistant?(%{role: :assistant, content: c}) when c in [nil, ""], do: true
  defp empty_assistant?(_), do: false

  defp build_call_opts(node, opts) do
    case parse_int(Map.get(node.attrs, "timeout"), nil) do
      nil -> opts
      timeout_ms -> Keyword.put(opts, :timeout, timeout_ms)
    end
  end

  defp call_llm_with_tools(client, request, node, context, on_stream, opts) do
    workdir = Map.get(node.attrs, "workdir") || Keyword.get(opts, :workdir, ".")
    max_turns = parse_int(Map.get(node.attrs, "max_turns"), 15)

    {tool_defs, executor} = resolve_tools(node, context, opts)

    agent_id =
      Map.get(node.attrs, "agent_id") ||
        Context.get(context, "session.agent_id", "system")

    # Annotate ask-mode tools with "(requires approval)" in description
    tool_defs = annotate_ask_mode_tools(tool_defs, agent_id)

    # Extract signer from context — allows cryptographic identity verification
    # for every tool call executed within the pipeline
    signer =
      Keyword.get(opts, :signer) ||
        Context.get(context, "session.signer")

    tool_loop_opts =
      [
        workdir: workdir,
        max_turns: max_turns,
        tools: tool_defs,
        tool_executor: executor,
        agent_id: agent_id,
        signer: signer,
        on_tool_call: build_tool_callback(opts, node.id)
      ]
      |> maybe_add_stream_callback(on_stream)

    case ToolLoop.run(client, request, tool_loop_opts) do
      {:ok, result} ->
        # Propagate discovered tool names via process dict so call_llm_and_respond
        # can include them in context_updates for session persistence
        if result[:discovered_tools] != nil and result[:discovered_tools] != [] do
          Process.put(:__discovered_tool_names__, result[:discovered_tools])
        end

        {:ok, result.text}

      {:error, {:max_turns_reached, turns, _}} ->
        {:error, "Tool loop hit #{turns} turn limit without completing"}

      {:error, _} = error ->
        error
    end
  end

  defp call_llm_direct(client, request, call_opts, nil) do
    case Client.complete(client, request, call_opts) do
      {:ok, response} -> {:ok, response.text}
      {:error, _} = error -> error
    end
  end

  defp call_llm_direct(client, request, call_opts, on_stream) do
    case Client.stream(client, request, call_opts) do
      {:ok, events} ->
        events =
          Stream.each(events, fn event -> on_stream.(event) end)

        case Client.collect_stream(events) do
          {:ok, response} -> {:ok, response.text}
          {:error, _} = error -> error
        end

      {:error, {:stream_not_supported, _}} ->
        # Fall back to non-streaming for providers that don't support it
        call_llm_direct(client, request, call_opts, nil)

      {:error, _} = error ->
        error
    end
  end

  # Resolve which tools and executor to use based on node attributes.
  # Priority: node attrs "tools" > session.tools from context > all actions default.
  # The `tool_executor` opt allows test injection.
  defp resolve_tools(node, context, opts) do
    executor = Keyword.get(opts, :tool_executor, ArborActionsExecutor)

    case Map.get(node.attrs, "tools") do
      nil ->
        case Context.get(context, "session.tools") do
          session_tools when is_list(session_tools) and session_tools != [] ->
            {resolve_tool_list(session_tools), executor}

          _ ->
            {ArborActionsExecutor.definitions(), executor}
        end

      tools_str when is_binary(tools_str) ->
        action_names = String.split(tools_str, ",", trim: true)
        {ArborActionsExecutor.definitions(action_names), executor}
    end
  end

  # Convert a list of tool items to OpenAI-format definitions.
  # Accepts action name strings, module atoms, or already-formatted maps.
  defp resolve_tool_list(tools) do
    {names, maps} =
      Enum.split_with(tools, fn
        item when is_binary(item) -> true
        item when is_atom(item) -> true
        _ -> false
      end)

    name_defs =
      if names != [] do
        string_names =
          Enum.map(names, fn
            mod when is_atom(mod) ->
              if function_exported?(mod, :name, 0), do: mod.name(), else: inspect(mod)

            name ->
              name
          end)

        ArborActionsExecutor.definitions(string_names)
      else
        []
      end

    name_defs ++ maps
  end

  # Annotate tool definitions for tools that require approval (`:ask` mode in trust profile).
  # Appends "(requires approval)" to the description so the LLM knows to explain
  # why it needs the tool before calling it.
  defp annotate_ask_mode_tools(tool_defs, agent_id) do
    alias Arbor.Orchestrator.Session.ToolDisclosure

    ask_tools = ToolDisclosure.ask_mode_tools(agent_id)

    if MapSet.size(ask_tools) == 0 do
      tool_defs
    else
      Enum.map(tool_defs, fn tool_def ->
        name = get_in(tool_def, ["function", "name"])

        if name && MapSet.member?(ask_tools, name) do
          update_in(tool_def, ["function", "description"], fn desc ->
            desc = desc || ""

            if String.contains?(desc, "(requires approval)") do
              desc
            else
              desc <> " (requires approval)"
            end
          end)
        else
          tool_def
        end
      end)
    end
  rescue
    _ -> tool_defs
  end

  defp maybe_add_stream_callback(opts, nil), do: opts

  defp maybe_add_stream_callback(opts, callback) do
    Keyword.put(opts, :stream_callback, callback)
  end

  defp build_tool_callback(opts, node_id) do
    case Keyword.get(opts, :logs_root) do
      nil ->
        nil

      logs_root ->
        fn name, args, result ->
          tool_log_dir = Path.join([logs_root, node_id, "tool_calls"])
          File.mkdir_p!(tool_log_dir)
          timestamp = System.system_time(:millisecond)
          status = if match?({:ok, _}, result), do: "ok", else: "error"

          entry = %{
            "tool" => name,
            "args" => args,
            "status" => status,
            "timestamp" => timestamp
          }

          File.write!(
            Path.join(tool_log_dir, "#{timestamp}_#{name}.json"),
            Jason.encode!(entry, pretty: true)
          )
        end
    end
  end

  # Consult the sensitivity router if data sensitivity is known.
  # Uses runtime bridge (Code.ensure_loaded? + apply) because
  # arbor_orchestrator and arbor_ai are both Standalone — no compile dep.
  defp maybe_route_by_sensitivity(provider, model, context) do
    sensitivity = Context.get(context, "__data_sensitivity__")

    if sensitivity && sensitivity != :public && sensitivity_router_available?() do
      agent_id = Context.get(context, "session.agent_id")

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      decision =
        apply(Arbor.AI.SensitivityRouter, :decide, [
          safe_to_atom(provider),
          model || "",
          sensitivity,
          [agent_id: agent_id]
        ])

      case decision do
        %{action: :proceed} ->
          {provider, model}

        %{action: :rerouted, alternative: {p, m}} = d ->
          # Store routing decision in process dict for context_updates propagation.
          # call_llm_and_respond merges this into the Outcome's context_updates.
          Process.put(:__routing_decision__, %{
            action: :rerouted,
            original: d.original,
            alternative: d.alternative,
            sensitivity: d.sensitivity,
            mode: d.mode,
            reason: d.reason
          })

          {to_string(p), m}

        %{action: :blocked, reason: reason} ->
          {:error, {:sensitivity_blocked, reason}}
      end
    else
      {provider, model}
    end
  rescue
    _ -> {provider, model}
  catch
    :exit, _ -> {provider, model}
  end

  defp sensitivity_router_available? do
    Code.ensure_loaded?(Arbor.AI.SensitivityRouter) and
      function_exported?(Arbor.AI.SensitivityRouter, :decide, 4)
  end

  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown
  end

  defp safe_to_atom(_), do: :unknown

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value / 1

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  @vote_format_prefix """
  You MUST respond with a JSON object in this exact format:
  {"vote": "approve" or "reject" or "abstain", "reasoning": "your detailed reasoning", "confidence": 0.0-1.0, "concerns": ["list", "of", "concerns"], "risk_score": 0.0-1.0}

  Respond ONLY with the JSON object, no other text.

  """

  defp maybe_prepend_vote_format(system_content, node_attrs, graph_attrs) do
    perspective = Map.get(node_attrs, "perspective")
    mode = Map.get(graph_attrs, "mode")

    if perspective && mode == "decision" do
      @vote_format_prefix <> system_content
    else
      system_content
    end
  end

  defp maybe_use_council_question(prompt, node_attrs, graph_attrs, context) do
    perspective = Map.get(node_attrs, "perspective")
    mode = Map.get(graph_attrs, "mode")
    has_explicit_prompt = Map.has_key?(node_attrs, "prompt")

    if perspective && mode == "decision" && !has_explicit_prompt do
      # Use the council question as the prompt for decision-mode perspective nodes
      question = Context.get(context, "council.question", "")

      if question != "" do
        "Evaluate the following proposal and cast your vote:\n\n#{question}"
      else
        prompt
      end
    else
      prompt
    end
  end

  defp maybe_put_perspective_key(updates, node_attrs, response_text) do
    case Map.get(node_attrs, "perspective") do
      nil -> updates
      perspective -> Map.put(updates, "vote.#{perspective}", response_text)
    end
  end

  # Merge routing decision from process dict into context_updates.
  # Set by maybe_route_by_sensitivity when a reroute occurs.
  defp maybe_put_routing_decision(updates) do
    case Process.delete(:__routing_decision__) do
      nil -> updates
      decision -> Map.put(updates, "__routing_decision__", decision)
    end
  end

  # Propagate discovered tool names from find_tools calls into context
  # so the Session can persist them across turns.
  defp maybe_put_discovered_tools(updates) do
    case Process.delete(:__discovered_tool_names__) do
      nil ->
        updates

      names when is_list(names) and names != [] ->
        existing = Map.get(updates, "session.discovered_tool_names", [])
        Map.put(updates, "session.discovered_tool_names", existing ++ names)

      _ ->
        updates
    end
  end

  defp parse_score(nil), do: nil
  defp parse_score(value) when is_integer(value), do: value / 1
  defp parse_score(value) when is_float(value), do: value

  defp parse_score(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_score(_), do: nil

  # ── Signal Emission ──────────────────────────────────────────────

  defp emit_llm_signal(event, data) do
    Builders.emit_signal(:agent, event, data)
  rescue
    _ -> :ok
  end

  defp write_stage_artifacts(opts, node_id, prompt, response) do
    case Keyword.get(opts, :logs_root) do
      nil ->
        :ok

      logs_root ->
        node_dir = Path.join(logs_root, node_id)

        with :ok <- File.mkdir_p(node_dir),
             :ok <- File.write(Path.join(node_dir, "prompt.md"), prompt),
             :ok <- File.write(Path.join(node_dir, "response.md"), response) do
          :ok
        else
          _ -> :ok
        end
    end
  end
end
