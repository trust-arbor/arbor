defmodule Arbor.Orchestrator.Handlers.CodergenHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  alias Arbor.Orchestrator.UnifiedLLM.{
    ArborActionsExecutor,
    Client,
    CodingTools,
    Message,
    Request,
    ToolLoop
  }

  @impl true
  def execute(node, context, graph, opts) do
    goal = Map.get(graph.attrs, "goal", "")

    prompt =
      node.attrs
      |> Map.get("prompt", Map.get(node.attrs, "label", node.id))
      |> String.replace("$goal", to_string(goal))

    # In decision mode, perspective nodes should evaluate the council question,
    # not their own node ID
    prompt = maybe_use_council_question(prompt, node.attrs, graph.attrs, context)

    base_updates = %{
      "last_stage" => node.id,
      "last_prompt" => prompt,
      "context.previous_outcome" => Arbor.Orchestrator.Engine.Context.get(context, "outcome"),
      "llm.model" => Map.get(node.attrs, "llm_model") || Map.get(node.attrs, "model"),
      "llm.provider" => Map.get(node.attrs, "llm_provider") || Map.get(node.attrs, "handler"),
      "llm.reasoning_effort" => Map.get(node.attrs, "reasoning_effort"),
      "score" => parse_score(Map.get(node.attrs, "score"))
    }

    case Map.get(node.attrs, "simulate") do
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
        attempts = Arbor.Orchestrator.Engine.Context.get(context, key, 0)

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

  defp call_llm_and_respond(prompt, node, _context, graph, base_updates, opts) do
    case call_llm(prompt, node, graph, opts) do
      {:ok, response_text} ->
        _ = write_stage_artifacts(opts, node.id, prompt, response_text)

        updates =
          base_updates
          |> Map.put("last_response", response_text)
          |> maybe_put_perspective_key(node.attrs, response_text)

        %Outcome{
          status: :success,
          notes: response_text,
          context_updates: updates
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "LLM call failed: #{inspect(reason)}",
          context_updates: Map.put(base_updates, "last_response", nil)
        }
    end
  end

  defp call_llm(prompt, node, graph, opts) do
    client = Keyword.get(opts, :llm_client) || Client.default_client()

    previous_outcome =
      case Map.get(node.attrs, "context.previous_outcome") do
        nil -> ""
        outcome -> "\n\nPrevious stage outcome: #{outcome}"
      end

    goal = Map.get(graph.attrs, "goal", "")

    system_content =
      case Map.get(node.attrs, "system_prompt") do
        nil -> "You are a coding agent working on the following goal: #{goal}"
        sys -> sys
      end

    # In decision mode with a perspective, prepend vote format instructions
    system_content = maybe_prepend_vote_format(system_content, node.attrs, graph.attrs)

    user_content = prompt <> previous_outcome

    request = %Request{
      provider: Map.get(node.attrs, "llm_provider") || Map.get(node.attrs, "handler"),
      model: Map.get(node.attrs, "llm_model") || Map.get(node.attrs, "model"),
      messages: [
        Message.new(:system, system_content),
        Message.new(:user, user_content)
      ],
      max_tokens: parse_int(Map.get(node.attrs, "max_tokens"), 4096),
      temperature: parse_float(Map.get(node.attrs, "temperature"), 0.7),
      provider_options: Map.get(node.attrs, "provider_options", %{})
    }

    call_opts =
      case parse_int(Map.get(node.attrs, "timeout"), nil) do
        nil -> opts
        timeout_ms -> Keyword.put(opts, :timeout, timeout_ms)
      end

    # Thread streaming callback through to the transport layer
    on_stream = Keyword.get(opts, :on_stream)

    call_opts =
      if on_stream do
        Keyword.put(call_opts, :stream_callback, on_stream)
      else
        call_opts
      end

    use_tools = Map.get(node.attrs, "use_tools") in ["true", true]

    if use_tools do
      workdir = Map.get(node.attrs, "workdir") || Keyword.get(opts, :workdir, ".")
      max_turns = parse_int(Map.get(node.attrs, "max_turns"), 15)

      {tool_defs, executor} = resolve_tools(node, opts)

      tool_loop_opts =
        [
          workdir: workdir,
          max_turns: max_turns,
          tools: tool_defs,
          tool_executor: executor,
          on_tool_call: build_tool_callback(opts, node.id)
        ]
        |> maybe_add_stream_callback(on_stream)

      case ToolLoop.run(client, request, tool_loop_opts) do
        {:ok, result} ->
          {:ok, result.text}

        {:error, {:max_turns_reached, turns, _}} ->
          {:error, "Tool loop hit #{turns} turn limit without completing"}

        {:error, _} = error ->
          error
      end
    else
      case Client.complete(client, request, call_opts) do
        {:ok, response} -> {:ok, response.text}
        {:error, _} = error -> error
      end
    end
  end

  # Resolve which tools and executor to use based on node attributes.
  # If `tools` attr is set, use ArborActionsExecutor with those specific actions.
  # Otherwise, fall back to CodingTools (5 built-in tools).
  # The `tool_executor` opt allows test injection.
  defp resolve_tools(node, opts) do
    case Map.get(node.attrs, "tools") do
      nil ->
        executor = Keyword.get(opts, :tool_executor, CodingTools)
        {CodingTools.definitions(), executor}

      tools_str when is_binary(tools_str) ->
        action_names = String.split(tools_str, ",", trim: true)
        executor = Keyword.get(opts, :tool_executor, ArborActionsExecutor)
        {ArborActionsExecutor.definitions(action_names), executor}
    end
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

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

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
      question = Arbor.Orchestrator.Engine.Context.get(context, "council.question", "")

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
