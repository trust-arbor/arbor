defmodule Arbor.Orchestrator.UnifiedLLM do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.{
    AbortError,
    Client,
    Message,
    NoObjectGeneratedError,
    Request,
    RequestTimeoutError,
    Retry,
    Tool
  }

  @type generate_opts :: keyword()

  @spec generate(generate_opts()) ::
          {:ok, Arbor.Orchestrator.UnifiedLLM.Response.t()} | {:error, term()}
  def generate(opts) when is_list(opts) do
    with :ok <- ensure_not_aborted(opts),
         {:ok, request} <- build_request(opts) do
      client = Keyword.get(opts, :client) || Client.default_client()
      tools = Keyword.get(opts, :tools, [])
      client_opts = Keyword.get(opts, :client_opts, [])

      with_timeout(opts, fn ->
        if tools == [] do
          Client.complete(client, request, client_opts)
        else
          tool_opts =
            opts
            |> Keyword.take([
              :max_tool_rounds,
              :max_steps,
              :max_step_timeout_ms,
              :parallel_tool_execution,
              :on_step,
              :stop_when,
              :retry,
              :sleep_fn,
              :tool_hooks,
              :validate_tool_call,
              :repair_tool_call,
              :abort?
            ])
            |> Keyword.merge(client_opts)

          Client.generate_with_tools(client, request, tools, tool_opts)
        end
      end)
    end
  end

  @spec stream(generate_opts()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(opts) when is_list(opts) do
    with :ok <- ensure_not_aborted(opts),
         {:ok, request} <- build_request(opts) do
      client = Keyword.get(opts, :client) || Client.default_client()
      client_opts = Keyword.get(opts, :client_opts, [])
      tools = Keyword.get(opts, :tools, [])

      with_timeout(opts, fn ->
        stream_opts = stream_tool_opts(opts, client_opts)

        case stream_events(client, request, tools, stream_opts) do
          {:ok, events} ->
            {:ok, wrap_stream_runtime_controls(events, opts)}

          other ->
            other
        end
      end)
    end
  end

  @spec generate_object(generate_opts()) :: {:ok, map()} | {:error, term()}
  def generate_object(opts) when is_list(opts) do
    case generate(opts) do
      {:ok, response} ->
        with {:ok, object} <- decode_object(response.text),
             :ok <- validate_object(object, opts) do
          {:ok, object}
        else
          {:error, reason} -> {:error, NoObjectGeneratedError.exception(reason: reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec stream_object(generate_opts()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream_object(opts) when is_list(opts) do
    case stream(opts) do
      {:ok, events} ->
        {:ok, build_object_stream(events, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_request(opts) do
    with :ok <- validate_prompt_messages(opts),
         {:ok, messages} <- normalize_messages(opts) do
      request = %Request{
        provider: Keyword.get(opts, :provider),
        model: Keyword.get(opts, :model, ""),
        messages: maybe_prepend_system(messages, Keyword.get(opts, :system)),
        tools: normalize_tools(Keyword.get(opts, :tools, [])),
        tool_choice: Keyword.get(opts, :tool_choice),
        max_tokens: Keyword.get(opts, :max_tokens),
        temperature: Keyword.get(opts, :temperature),
        reasoning_effort: Keyword.get(opts, :reasoning_effort),
        provider_options: Keyword.get(opts, :provider_options, %{})
      }

      if request.model in [nil, ""] do
        {:error, :model_required}
      else
        {:ok, request}
      end
    end
  end

  defp build_object_stream(events, opts) do
    Stream.transform(
      events,
      %{text: "", last_object: nil},
      fn event, state ->
        case event do
          %Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :delta, data: %{"text" => chunk}} ->
            emit_partial_object(state, chunk, opts)

          %Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :delta, data: %{text: chunk}} ->
            emit_partial_object(state, chunk, opts)

          %Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :finish} ->
            ensure_final_object!(state, opts)
            {[], state}

          _ ->
            {[], state}
        end
      end
    )
  end

  defp emit_partial_object(state, chunk, opts) do
    text = state.text <> to_string(chunk)
    next_state = %{state | text: text}

    case Jason.decode(text) do
      {:ok, object} when is_map(object) ->
        case maybe_emit_partial_object(object, state.last_object, opts) do
          {:emit, object} ->
            {[object], %{next_state | last_object: object}}

          :skip ->
            {[], %{next_state | last_object: object}}
        end

      _ ->
        {[], next_state}
    end
  end

  defp maybe_emit_partial_object(object, last_object, opts) do
    if object == last_object do
      :skip
    else
      case validate_partial_object(object, opts) do
        :ok -> {:emit, object}
        {:error, _} -> :skip
      end
    end
  end

  defp validate_partial_object(object, opts) do
    schema = Keyword.get(opts, :schema, Keyword.get(opts, :object_schema))

    case schema do
      nil -> :ok
      _ -> validate_object_schema(object, opts)
    end
  end

  defp ensure_final_object!(state, opts) do
    with {:ok, object} <- decode_object(state.text),
         :ok <- validate_object(object, opts) do
      :ok
    else
      {:error, reason} -> raise NoObjectGeneratedError, reason: reason
    end
  end

  defp validate_prompt_messages(opts) do
    has_prompt = is_binary(Keyword.get(opts, :prompt))
    has_messages = is_list(Keyword.get(opts, :messages))

    cond do
      has_prompt and has_messages -> {:error, :prompt_and_messages_mutually_exclusive}
      has_prompt or has_messages -> :ok
      true -> {:error, :prompt_or_messages_required}
    end
  end

  defp normalize_messages(opts) do
    case Keyword.get(opts, :prompt) do
      prompt when is_binary(prompt) ->
        {:ok, [Message.new(:user, prompt)]}

      _ ->
        case Keyword.get(opts, :messages) do
          messages when is_list(messages) -> {:ok, messages}
          _ -> {:error, :invalid_messages}
        end
    end
  end

  defp maybe_prepend_system(messages, system) when is_binary(system) and system != "" do
    [Message.new(:system, system) | messages]
  end

  defp maybe_prepend_system(messages, _), do: messages

  defp normalize_tools(tools) do
    Enum.map(tools, fn
      %Tool{} = tool -> Tool.as_definition(tool)
      other when is_map(other) -> other
      other -> %{name: to_string(other), description: nil, input_schema: %{}}
    end)
  end

  defp decode_object(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :object_must_be_map}
      {:error, _} -> {:error, :no_object_generated}
    end
  end

  defp decode_object(_), do: {:error, :no_object_generated}

  defp validate_object(object, opts) do
    with :ok <- validate_object_schema(object, opts) do
      validate_object_callback(object, opts)
    end
  end

  defp validate_object_schema(object, opts) do
    schema = Keyword.get(opts, :schema, Keyword.get(opts, :object_schema))

    case schema do
      nil ->
        :ok

      schema when is_map(schema) ->
        validate_schema_value(object, schema)

      _ ->
        {:error, :invalid_object_schema}
    end
  end

  defp validate_object_callback(object, opts) do
    case Keyword.get(opts, :validate_object) do
      nil ->
        :ok

      fun when is_function(fun, 1) ->
        case fun.(object) do
          :ok -> :ok
          {:error, reason} -> {:error, {:object_validation_failed, reason}}
          other -> {:error, {:object_validation_failed, other}}
        end

      _ ->
        {:error, :invalid_object_validator}
    end
  end

  defp validate_schema_value(value, schema) when is_map(schema) do
    expected_type = Map.get(schema, "type") || Map.get(schema, :type)

    with :ok <- validate_schema_type(value, expected_type),
         :ok <- validate_schema_required(value, schema),
         :ok <- validate_schema_properties(value, schema) do
      validate_schema_items(value, schema)
    end
  end

  defp validate_schema_value(_value, _schema), do: {:error, :invalid_object_schema}

  defp validate_schema_type(_value, nil), do: :ok

  defp validate_schema_type(value, type) when type in ["object", :object] do
    if is_map(value), do: :ok, else: {:error, {:schema_type_mismatch, %{expected: :object}}}
  end

  defp validate_schema_type(value, type) when type in ["array", :array] do
    if is_list(value), do: :ok, else: {:error, {:schema_type_mismatch, %{expected: :array}}}
  end

  defp validate_schema_type(value, type) when type in ["string", :string] do
    if is_binary(value), do: :ok, else: {:error, {:schema_type_mismatch, %{expected: :string}}}
  end

  defp validate_schema_type(value, type) when type in ["integer", :integer] do
    if is_integer(value), do: :ok, else: {:error, {:schema_type_mismatch, %{expected: :integer}}}
  end

  defp validate_schema_type(value, type) when type in ["number", :number] do
    if is_number(value), do: :ok, else: {:error, {:schema_type_mismatch, %{expected: :number}}}
  end

  defp validate_schema_type(value, type) when type in ["boolean", :boolean] do
    if is_boolean(value), do: :ok, else: {:error, {:schema_type_mismatch, %{expected: :boolean}}}
  end

  defp validate_schema_type(value, type) when type in ["null", :null] do
    if is_nil(value), do: :ok, else: {:error, {:schema_type_mismatch, %{expected: :null}}}
  end

  defp validate_schema_type(_value, _type), do: {:error, :invalid_object_schema}

  defp validate_schema_required(value, schema) when is_map(value) do
    case Map.get(schema, "required") || Map.get(schema, :required) do
      nil ->
        :ok

      required when is_list(required) ->
        missing =
          Enum.find(required, fn key ->
            key_str = to_string(key)
            not (Map.has_key?(value, key_str) or Map.has_key?(value, key))
          end)

        if missing do
          {:error, {:schema_required_missing, to_string(missing)}}
        else
          :ok
        end

      _ ->
        {:error, :invalid_object_schema}
    end
  end

  defp validate_schema_required(_value, _schema), do: :ok

  defp validate_schema_properties(value, schema) when is_map(value) do
    case Map.get(schema, "properties") || Map.get(schema, :properties) do
      nil ->
        :ok

      properties when is_map(properties) ->
        Enum.reduce_while(properties, :ok, fn {key, prop_schema}, _acc ->
          key_str = to_string(key)

          case fetch_object_key(value, key, key_str) do
            :missing ->
              {:cont, :ok}

            {:ok, prop_value} ->
              case validate_schema_value(prop_value, prop_schema) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, {:schema_property_invalid, key_str, reason}}}
              end
          end
        end)

      _ ->
        {:error, :invalid_object_schema}
    end
  end

  defp validate_schema_properties(_value, _schema), do: :ok

  defp validate_schema_items(value, schema) when is_list(value) do
    case Map.get(schema, "items") || Map.get(schema, :items) do
      nil ->
        :ok

      item_schema when is_map(item_schema) ->
        Enum.reduce_while(value, :ok, fn item, _acc ->
          case validate_schema_value(item, item_schema) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:schema_item_invalid, reason}}}
          end
        end)

      _ ->
        {:error, :invalid_object_schema}
    end
  end

  defp validate_schema_items(_value, _schema), do: :ok

  defp fetch_object_key(map, key, key_str) do
    cond do
      Map.has_key?(map, key_str) -> {:ok, Map.get(map, key_str)}
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      true -> :missing
    end
  end

  defp with_timeout(opts, fun) when is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms)

    if is_integer(timeout_ms) and timeout_ms > 0 do
      task = Task.async(fun)

      try do
        Task.await(task, timeout_ms)
      catch
        :exit, {:timeout, _} ->
          Task.shutdown(task, :brutal_kill)
          {:error, RequestTimeoutError.exception(timeout_ms: timeout_ms)}
      end
    else
      fun.()
    end
  end

  defp stream_events(client, request, [], stream_opts),
    do: stream_call_with_retry(client, request, stream_opts)

  defp stream_events(client, request, tools, stream_opts) do
    max_steps =
      Keyword.get(stream_opts, :max_tool_rounds, Keyword.get(stream_opts, :max_steps, 8))

    parallel = Keyword.get(stream_opts, :parallel_tool_execution, true)

    {:ok, build_tool_loop_stream(client, request, tools, stream_opts, max_steps, parallel)}
  end

  defp stream_tool_opts(opts, client_opts) do
    opts
    |> Keyword.take([
      :max_tool_rounds,
      :max_steps,
      :parallel_tool_execution,
      :abort?,
      :retry,
      :sleep_fn
    ])
    |> Keyword.merge(client_opts)
  end

  defp build_tool_loop_stream(client, request, tools, stream_opts, max_steps, parallel) do
    Stream.resource(
      fn ->
        %{
          client: client,
          request: request,
          tools: tools,
          stream_opts: stream_opts,
          max_steps: max_steps,
          step_index: 0,
          parallel: parallel,
          pending_events: [],
          done?: false
        }
      end,
      &next_tool_loop_stream_item/1,
      fn _ -> :ok end
    )
  end

  defp next_tool_loop_stream_item(%{pending_events: [event | rest]} = state) do
    {[event], %{state | pending_events: rest}}
  end

  defp next_tool_loop_stream_item(%{done?: true} = state), do: {:halt, state}

  defp next_tool_loop_stream_item(state) do
    case next_tool_loop_step(state) do
      {:ok, %{pending_events: []} = next_state} when next_state.done? ->
        {:halt, next_state}

      {:ok, next_state} ->
        next_tool_loop_stream_item(next_state)

      {:error, reason} ->
        raise reason
    end
  end

  defp next_tool_loop_step(state) do
    with :ok <- ensure_not_aborted_runtime(state.stream_opts),
         {:ok, step_stream} <-
           stream_call_with_retry(state.client, state.request, state.stream_opts) do
      step_events = Enum.to_list(step_stream)
      tool_calls = extract_tool_calls_from_events(step_events)

      cond do
        state.max_steps <= 0 ->
          {:ok, %{state | pending_events: step_events, done?: true}}

        tool_calls == [] ->
          {:ok, %{state | pending_events: step_events, done?: true}}

        not should_auto_execute_tool_calls?(tool_calls, state.tools) ->
          {:ok, %{state | pending_events: step_events, done?: true}}

        true ->
          {tool_messages, tool_result_events} =
            execute_tool_calls_for_stream(tool_calls, state.tools, state.parallel)

          step_finish_event = %Arbor.Orchestrator.UnifiedLLM.StreamEvent{
            type: :step_finish,
            data: %{
              "step" => state.step_index,
              "tool_call_count" => length(tool_calls),
              "next_step" => state.step_index + 1
            }
          }

          next_request = %{
            state.request
            | messages:
                state.request.messages ++
                  [
                    Message.new(:assistant, extract_text_from_events(step_events), %{
                      "tool_calls" => tool_calls
                    })
                  ] ++ tool_messages
          }

          {:ok,
           %{
             state
             | request: next_request,
               pending_events: step_events ++ tool_result_events ++ [step_finish_event],
               max_steps: state.max_steps - 1,
               step_index: state.step_index + 1,
               done?: false
           }}
      end
    end
  end

  defp stream_call_with_retry(client, request, stream_opts) do
    retry_opts = Keyword.get(stream_opts, :retry, [])

    Retry.execute(
      fn -> Client.stream(client, request, stream_opts) end,
      Keyword.merge(
        [
          sleep_fn: Keyword.get(stream_opts, :sleep_fn, fn ms -> Process.sleep(ms) end)
        ],
        retry_opts
      )
    )
  end

  defp extract_text_from_events(events) do
    events
    |> Enum.reduce([], fn
      %Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :delta, data: %{"text" => text}}, acc ->
        [to_string(text) | acc]

      %Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :delta, data: %{text: text}}, acc ->
        [to_string(text) | acc]

      _, acc ->
        acc
    end)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp extract_tool_calls_from_events(events) do
    events
    |> Enum.flat_map(fn
      %Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :tool_call, data: data} ->
        [normalize_tool_call_data(data)]

      _ ->
        []
    end)
  end

  defp normalize_tool_call_data(data) when is_map(data) do
    %{
      "id" => to_string(Map.get(data, "id") || Map.get(data, :id) || "call"),
      "name" => Map.get(data, "name") || Map.get(data, :name),
      "arguments" =>
        normalize_tool_call_arguments(
          Map.get(data, "arguments") || Map.get(data, :arguments) || Map.get(data, "args") ||
            Map.get(data, :args) || %{}
        )
    }
  end

  defp normalize_tool_call_data(_), do: %{"id" => "call", "name" => nil, "arguments" => %{}}

  defp normalize_tool_call_arguments(arguments) when is_map(arguments), do: arguments

  defp normalize_tool_call_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  defp normalize_tool_call_arguments(_), do: %{}

  defp should_auto_execute_tool_calls?(tool_calls, tools) do
    Enum.any?(tool_calls, fn call ->
      name = Map.get(call, "name") || Map.get(call, :name)

      case Enum.find(tools, &(&1.name == name)) do
        %Tool{execute: execute} when is_function(execute, 1) -> true
        %Tool{execute: nil} -> false
        nil -> true
      end
    end)
  end

  defp execute_tool_calls_for_stream(tool_calls, tools, parallel) do
    runner = fn call -> execute_tool_call_for_stream(call, tools) end

    results =
      if parallel and length(tool_calls) > 1 do
        tool_calls
        |> Task.async_stream(runner, timeout: 30_000, ordered: true)
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> fallback_tool_stream_result(reason)
        end)
      else
        Enum.map(tool_calls, runner)
      end

    {Enum.map(results, &elem(&1, 0)), Enum.map(results, &elem(&1, 1))}
  end

  defp execute_tool_call_for_stream(call, tools) do
    id = Map.get(call, "id") || Map.get(call, :id) || "call"
    name = Map.get(call, "name") || Map.get(call, :name)
    arguments = Map.get(call, "arguments") || Map.get(call, :arguments) || %{}

    output =
      case Enum.find(tools, &(&1.name == name)) do
        %Tool{execute: execute} when is_function(execute, 1) ->
          safe_execute_stream_tool(execute, arguments)

        %Tool{} ->
          %{
            "status" => "error",
            "error" => "Tool has no execute handler",
            "type" => :invalid_tool_call
          }

        nil ->
          %{"status" => "error", "error" => "Unknown tool", "type" => :unknown_tool}
      end

    tool_message =
      Message.new(:tool, Jason.encode!(output), %{"tool_call_id" => id, "name" => name})

    tool_event = %Arbor.Orchestrator.UnifiedLLM.StreamEvent{
      type: :tool_result,
      data: %{
        "id" => id,
        "name" => name,
        "status" => output["status"],
        "result" => Map.get(output, "result"),
        "error" => Map.get(output, "error")
      }
    }

    {tool_message, tool_event}
  end

  defp safe_execute_stream_tool(execute, arguments) do
    case execute.(arguments) do
      {:ok, map} when is_map(map) ->
        %{"status" => "ok", "result" => map}

      {:error, reason} ->
        %{"status" => "error", "error" => inspect(reason), "type" => :execution_failed}

      map when is_map(map) ->
        %{"status" => "ok", "result" => map}

      other ->
        %{"status" => "ok", "result" => %{"value" => inspect(other)}}
    end
  rescue
    exception ->
      %{
        "status" => "error",
        "error" => Exception.message(exception),
        "type" => :execution_failed
      }
  end

  defp fallback_tool_stream_result(reason) do
    output = %{
      "status" => "error",
      "error" => "tool failed: #{inspect(reason)}",
      "type" => :execution_failed
    }

    message =
      Message.new(:tool, Jason.encode!(output), %{"tool_call_id" => "call", "name" => "unknown"})

    event = %Arbor.Orchestrator.UnifiedLLM.StreamEvent{
      type: :tool_result,
      data: %{
        "id" => "call",
        "name" => "unknown",
        "status" => "error",
        "error" => output["error"]
      }
    }

    {message, event}
  end

  defp ensure_not_aborted_runtime(opts) do
    if aborted?(opts) do
      {:error, AbortError.exception([])}
    else
      :ok
    end
  end

  defp wrap_stream_runtime_controls(events, opts) do
    timeout_ms = Keyword.get(opts, :stream_read_timeout_ms, Keyword.get(opts, :timeout_ms))
    abort_fun = abort_fun(opts)

    if stream_runtime_controls_enabled?(timeout_ms, abort_fun) do
      build_controlled_stream(events, timeout_ms, abort_fun)
    else
      events
    end
  end

  defp stream_runtime_controls_enabled?(timeout_ms, abort_fun) do
    (is_integer(timeout_ms) and timeout_ms > 0) or is_function(abort_fun, 0)
  end

  defp build_controlled_stream(events, timeout_ms, abort_fun) do
    owner = self()
    ref = make_ref()
    {pid, monitor_ref} = spawn_monitor(fn -> produce_stream_events(owner, ref, events) end)

    Stream.resource(
      fn ->
        %{
          ref: ref,
          producer_pid: pid,
          monitor_ref: monitor_ref,
          timeout_ms: normalize_timeout_ms(timeout_ms),
          abort_fun: abort_fun,
          deadline_ms: maybe_deadline_ms(timeout_ms),
          done?: false
        }
      end,
      &next_controlled_stream_item/1,
      &close_controlled_stream/1
    )
  end

  defp produce_stream_events(owner, ref, events) do
    Enum.each(events, fn event -> send(owner, {ref, :event, event}) end)
    send(owner, {ref, :done})
  rescue
    exception ->
      send(owner, {ref, :producer_error, {:error, exception, __STACKTRACE__}})
  catch
    kind, reason ->
      send(owner, {ref, :producer_error, {kind, reason, __STACKTRACE__}})
  end

  defp next_controlled_stream_item(%{done?: true} = state), do: {:halt, state}

  defp next_controlled_stream_item(state) do
    maybe_raise_if_aborted(state.abort_fun)
    maybe_raise_if_stream_timed_out(state)

    receive_timeout = next_receive_timeout_ms(state)

    receive do
      {ref, :event, event} when ref == state.ref ->
        {[event], reset_deadline(state)}

      {ref, :done} when ref == state.ref ->
        {:halt, %{state | done?: true}}

      {ref, :producer_error, {:error, exception, stacktrace}} when ref == state.ref ->
        reraise(exception, stacktrace)

      {ref, :producer_error, {kind, reason, stacktrace}} when ref == state.ref ->
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, mon_ref, :process, pid, _reason}
      when mon_ref == state.monitor_ref and pid == state.producer_pid ->
        {:halt, %{state | done?: true}}
    after
      receive_timeout ->
        maybe_raise_if_stream_timed_out(state)
        next_controlled_stream_item(state)
    end
  end

  defp close_controlled_stream(state) do
    if Process.alive?(state.producer_pid) do
      Process.exit(state.producer_pid, :kill)
    end

    Process.demonitor(state.monitor_ref, [:flush])
    :ok
  end

  defp maybe_raise_if_aborted(nil), do: :ok

  defp maybe_raise_if_aborted(abort_fun) do
    if abort_fun.() do
      raise AbortError
    else
      :ok
    end
  end

  defp maybe_raise_if_stream_timed_out(%{timeout_ms: nil}), do: :ok

  defp maybe_raise_if_stream_timed_out(%{timeout_ms: timeout_ms, deadline_ms: deadline_ms}) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      raise RequestTimeoutError, timeout_ms: timeout_ms
    else
      :ok
    end
  end

  defp normalize_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp normalize_timeout_ms(_), do: nil

  defp maybe_deadline_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp maybe_deadline_ms(_), do: nil

  defp reset_deadline(%{timeout_ms: nil} = state), do: state

  defp reset_deadline(%{timeout_ms: timeout_ms} = state),
    do: %{state | deadline_ms: maybe_deadline_ms(timeout_ms)}

  defp next_receive_timeout_ms(%{timeout_ms: nil, abort_fun: abort_fun})
       when is_function(abort_fun, 0),
       do: 100

  defp next_receive_timeout_ms(%{timeout_ms: nil}), do: :infinity

  defp next_receive_timeout_ms(%{
         timeout_ms: timeout_ms,
         deadline_ms: deadline_ms,
         abort_fun: abort_fun
       }) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    if is_function(abort_fun, 0) do
      min(remaining_ms, 100)
    else
      min(remaining_ms, timeout_ms)
    end
  end

  defp abort_fun(opts) do
    case Keyword.get(opts, :abort?) do
      fun when is_function(fun, 0) -> fun
      true -> fn -> true end
      _ -> nil
    end
  end

  defp ensure_not_aborted(opts) do
    if aborted?(opts) do
      {:error, AbortError.exception([])}
    else
      :ok
    end
  end

  defp aborted?(opts) do
    case Keyword.get(opts, :abort?) do
      fun when is_function(fun, 0) -> fun.()
      value -> value
    end
  end
end
