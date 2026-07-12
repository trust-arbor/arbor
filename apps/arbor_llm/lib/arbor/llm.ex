defmodule Arbor.LLM do
  @moduledoc false

  alias Arbor.LLM.AbortError

  alias Arbor.LLM.Boundary

  alias Arbor.LLM.Client

  alias Arbor.LLM.Deadline

  alias Arbor.LLM.Message

  alias Arbor.LLM.NoObjectGeneratedError

  alias Arbor.LLM.Request

  alias Arbor.LLM.RequestTimeoutError

  alias Arbor.LLM.ResponseBudget

  alias Arbor.LLM.Retry

  alias Arbor.LLM.Tool

  @eval_subjects %{
    "llm" => Arbor.LLM.Eval.Subject
  }

  @controlled_wrapper_cleanup_grace_ms 600
  @max_object_stream_bytes 1_048_576
  @default_public_timeout_ms 30_000
  @max_object_stream_events 4_000
  @max_object_stream_depth 32
  @max_object_decode_attempts 1
  @object_json_limits [
    max_bytes: 1_048_576,
    max_nodes: 100_000,
    max_depth: 32,
    max_map_keys: 10_000,
    max_list_items: 100_000
  ]
  @tool_argument_limits [
    max_bytes: 1_048_576,
    max_nodes: 10_000,
    max_depth: 32,
    max_map_keys: 2_000,
    max_list_items: 10_000
  ]
  @tool_argument_aggregate_limits %{
    bytes: 16_777_216,
    nodes: 100_000,
    map_keys: 10_000,
    list_items: 100_000
  }

  @type generate_opts :: keyword()

  @doc "Returns an LLM-owned eval subject from the closed symbolic catalog."
  @spec eval_subject(String.t()) :: module() | nil
  def eval_subject(name) when is_binary(name), do: Map.get(@eval_subjects, name)
  def eval_subject(_name), do: nil

  @spec generate(generate_opts()) ::
          {:ok, Arbor.LLM.Response.t()} | {:error, term()}
  def generate(opts) when is_list(opts) do
    with {:ok, opts, _timeout} <- Deadline.normalize_options(opts, @default_public_timeout_ms) do
      with_timeout(opts, fn _receipt -> do_generate(opts) end)
    end
  end

  def generate(_opts), do: {:error, :keyword_options_required}

  @doc "Generate an authoritative indexed embedding batch through the bounded LLM transport."
  @spec embed_batch(atom() | String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def embed_batch(provider, model, texts, opts \\ [])

  def embed_batch(provider, model, texts, opts)
      when (is_atom(provider) or is_binary(provider)) and is_binary(model) and is_list(opts) do
    with {:ok, opts, _timeout} <- Deadline.normalize_options(opts, @default_public_timeout_ms) do
      with_timeout(opts, fn _receipt ->
        canonical = Arbor.LLM.ProviderRegistry.normalize(provider)

        adapter_opts =
          opts
          |> Keyword.delete(:provider)
          |> Keyword.put(:provider, canonical)

        case Arbor.LLM.Adapter.ReqLLM.embed(texts, model, adapter_opts) do
          {:ok, result} when is_map(result) ->
            {:ok, Map.put(result, :provider, canonical)}

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:invalid_embedding_result, Arbor.LLM.ExternalTerm.sanitize(other)}}
        end
      end)
    end
  end

  def embed_batch(_provider, _model, _texts, _opts),
    do: {:error, :invalid_embedding_request}

  defp do_generate(opts) do
    with :ok <- validate_public_options(opts),
         :ok <- ensure_not_aborted(opts),
         {:ok, request} <- build_request(opts),
         {:ok, client_opts} <-
           Boundary.narrow_options(opts, Keyword.get(opts, :client_opts, [])) do
      client = Keyword.get(opts, :client) || Client.default_client()
      tools = Keyword.get(opts, :tools, [])

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
    end
  end

  @spec stream(generate_opts()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(opts) when is_list(opts) do
    with {:ok, opts, _timeout} <- Deadline.normalize_options(opts, @default_public_timeout_ms) do
      with_timeout(opts, fn receipt -> do_stream(opts, receipt) end)
    end
  end

  def stream(_opts), do: {:error, :keyword_options_required}

  defp do_stream(opts, receipt) do
    with :ok <- validate_public_options(opts),
         :ok <- ensure_not_aborted(opts),
         {:ok, request} <- build_request(opts),
         {:ok, client_opts} <-
           Boundary.narrow_options(opts, Keyword.get(opts, :client_opts, [])) do
      client = Keyword.get(opts, :client) || Client.default_client()
      tools = Keyword.get(opts, :tools, [])
      stream_opts = stream_tool_opts(opts, client_opts)

      case stream_events(client, request, tools, stream_opts) do
        {:ok, events} ->
          {:ok, wrap_stream_runtime_controls(events, stream_opts, receipt)}

        other ->
          other
      end
    end
  end

  @spec generate_object(generate_opts()) :: {:ok, map()} | {:error, term()}
  def generate_object(opts) when is_list(opts) do
    with {:ok, opts, _timeout} <- Deadline.normalize_options(opts, @default_public_timeout_ms) do
      with_timeout(opts, fn _receipt ->
        case do_generate(opts) do
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
      end)
    end
  end

  def generate_object(_opts), do: {:error, :keyword_options_required}

  @spec stream_object(generate_opts()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream_object(opts) when is_list(opts) do
    with {:ok, opts, _timeout} <- Deadline.normalize_options(opts, @default_public_timeout_ms) do
      with_timeout(opts, fn receipt ->
        case do_stream(opts, receipt) do
          {:ok, events} ->
            {:ok, build_object_stream(events, opts)}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  def stream_object(_opts), do: {:error, :keyword_options_required}

  defp validate_public_options(opts), do: validate_public_options(opts, 0)
  defp validate_public_options([], _count), do: :ok

  defp validate_public_options(_opts, count) when count >= 128,
    do: {:error, :too_many_options}

  defp validate_public_options([{key, _value} | rest], count) when is_atom(key),
    do: validate_public_options(rest, count + 1)

  defp validate_public_options(_improper_or_invalid, _count),
    do: {:error, :keyword_options_required}

  defp build_request(opts) do
    with :ok <- validate_prompt_messages(opts),
         {:ok, messages} <- normalize_messages(opts),
         {:ok, tools} <- normalize_tools(Keyword.get(opts, :tools, [])) do
      request = %Request{
        provider: Keyword.get(opts, :provider),
        model: Keyword.get(opts, :model, ""),
        messages: maybe_prepend_system(messages, Keyword.get(opts, :system)),
        tools: tools,
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
      new_object_stream_state(opts),
      fn event, state ->
        state = count_object_stream_event!(state)

        case event do
          %Arbor.LLM.StreamEvent{type: :delta, data: %{"text" => chunk}} ->
            emit_partial_object(state, chunk, opts)

          %Arbor.LLM.StreamEvent{type: :delta, data: %{text: chunk}} ->
            emit_partial_object(state, chunk, opts)

          %Arbor.LLM.StreamEvent{type: :finish} ->
            ensure_final_object!(state, opts)
            {[], state}

          _ ->
            {[], state}
        end
      end
    )
  end

  defp emit_partial_object(state, chunk, opts) do
    unless is_binary(chunk) do
      raise NoObjectGeneratedError, reason: :object_stream_binary_chunks_required
    end

    bytes = state.bytes + byte_size(chunk)

    if bytes > state.max_bytes do
      raise NoObjectGeneratedError,
        reason: {:object_stream_limit_exceeded, :bytes, state.max_bytes}
    end

    case scan_object_json(chunk, state.scan) do
      {:ok, scan} ->
        next_state = %{state | chunks: [chunk | state.chunks], bytes: bytes, scan: scan}

        if scan.complete? and is_nil(state.final_object),
          do: decode_object_stream_candidate(next_state, opts),
          else: {[], next_state}

      {:error, reason} ->
        raise NoObjectGeneratedError, reason: reason
    end
  end

  defp new_object_stream_state(opts) do
    configured =
      Keyword.get(opts, :max_object_stream_bytes, @max_object_stream_bytes)

    max_bytes =
      if is_integer(configured) and configured > 0,
        do: min(configured, @max_object_stream_bytes),
        else: @max_object_stream_bytes

    %{
      chunks: [],
      bytes: 0,
      events: 0,
      decode_attempts: 0,
      max_bytes: max_bytes,
      last_object: nil,
      final_object: nil,
      decode_error: nil,
      scan: %{
        started?: false,
        complete?: false,
        in_string?: false,
        escape?: false,
        stack: []
      }
    }
  end

  defp count_object_stream_event!(state) do
    events = state.events + 1

    if events > @max_object_stream_events do
      raise NoObjectGeneratedError,
        reason: {:object_stream_limit_exceeded, :events, @max_object_stream_events}
    end

    %{state | events: events}
  end

  defp decode_object_stream_candidate(state, opts) do
    attempts = state.decode_attempts + 1

    if attempts > @max_object_decode_attempts do
      raise NoObjectGeneratedError,
        reason: {:object_stream_limit_exceeded, :decode_attempts, @max_object_decode_attempts}
    end

    body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case Arbor.LLM.ResponseBudget.decode_json(body, object_stream_limits(state.max_bytes)) do
      {:ok, object} when is_map(object) ->
        next_state = %{state | decode_attempts: attempts, final_object: object}

        case maybe_emit_partial_object(object, state.last_object, opts) do
          {:emit, object} -> {[object], %{next_state | last_object: object}}
          :skip -> {[], %{next_state | last_object: object}}
        end

      {:ok, _other} ->
        {[], %{state | decode_attempts: attempts, decode_error: :object_must_be_map}}

      {:error, reason} ->
        {[], %{state | decode_attempts: attempts, decode_error: reason}}
    end
  end

  defp scan_object_json("", scan), do: {:ok, scan}

  defp scan_object_json(<<char, rest::binary>>, %{in_string?: true} = scan) do
    cond do
      scan.escape? ->
        scan_object_json(rest, %{scan | escape?: false})

      char == ?\\ ->
        scan_object_json(rest, %{scan | escape?: true})

      char == ?\" ->
        scan_object_json(rest, %{scan | in_string?: false})

      char < 0x20 ->
        {:error, :malformed_object_stream_json}

      true ->
        scan_object_json(rest, scan)
    end
  end

  defp scan_object_json(<<char, rest::binary>>, scan) do
    cond do
      scan.complete? and char in [32, 9, 10, 13] ->
        scan_object_json(rest, scan)

      scan.complete? ->
        {:error, :multiple_object_stream_values}

      not scan.started? and char in [32, 9, 10, 13] ->
        scan_object_json(rest, scan)

      not scan.started? and char == ?{ ->
        scan_object_json(rest, %{scan | started?: true, stack: [?} | scan.stack]})

      not scan.started? ->
        {:error, :object_stream_must_start_with_map}

      char == ?\" ->
        scan_object_json(rest, %{scan | in_string?: true})

      char in [?{, ?[] ->
        closer = if char == ?{, do: ?}, else: ?]
        stack = [closer | scan.stack]

        if length(stack) > @max_object_stream_depth,
          do: {:error, {:object_stream_limit_exceeded, :depth, @max_object_stream_depth}},
          else: scan_object_json(rest, %{scan | stack: stack})

      char in [?}, ?]] ->
        case scan.stack do
          [^char] -> scan_object_json(rest, %{scan | stack: [], complete?: true})
          [^char | stack] -> scan_object_json(rest, %{scan | stack: stack})
          _ -> {:error, :malformed_object_stream_json}
        end

      true ->
        scan_object_json(rest, scan)
    end
  end

  defp object_stream_limits(max_bytes) do
    [
      max_bytes: max_bytes,
      max_nodes: 20_000,
      max_depth: @max_object_stream_depth,
      max_map_keys: 5_000,
      max_list_items: 20_000
    ]
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
    with true <- is_nil(state.decode_error) or {:error, state.decode_error},
         object when is_map(object) <- state.final_object,
         :ok <- validate_object(object, opts) do
      :ok
    else
      nil -> raise NoObjectGeneratedError, reason: :no_object_generated
      false -> raise NoObjectGeneratedError, reason: :no_object_generated
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

  defp normalize_tools(tools), do: normalize_tools(tools, [])
  defp normalize_tools([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_tools([%Tool{} = tool | rest], acc),
    do: normalize_tools(rest, [Tool.as_definition(tool) | acc])

  defp normalize_tools([tool | rest], acc) when is_map(tool),
    do: normalize_tools(rest, [tool | acc])

  defp normalize_tools([name | rest], acc) when is_binary(name) or is_atom(name),
    do:
      normalize_tools(rest, [%{name: to_string(name), description: nil, input_schema: %{}} | acc])

  defp normalize_tools(_improper_or_invalid, _acc), do: {:error, :proper_tool_list_required}

  defp decode_object(text) when is_binary(text) do
    case ResponseBudget.decode_json(text, @object_json_limits) do
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
              validate_property_value(prop_value, prop_schema, key_str)
          end
        end)

      _ ->
        {:error, :invalid_object_schema}
    end
  end

  defp validate_schema_properties(_value, _schema), do: :ok

  defp validate_property_value(prop_value, prop_schema, key_str) do
    case validate_schema_value(prop_value, prop_schema) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:schema_property_invalid, key_str, reason}}}
    end
  end

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

  defp with_timeout(opts, fun) when is_function(fun, 1) do
    with {:ok, receipt} <- Deadline.receipt(opts) do
      Deadline.run(
        fn -> fun.(receipt) end,
        receipt,
        RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
      )
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
      :timeout_ms,
      :stream_read_timeout_ms,
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
          tool_result_budget: Arbor.LLM.ToolResultBudget.new(),
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
        raise RuntimeError,
              "tool result rejected: #{Arbor.LLM.ExternalTerm.inspect(reason)}"
    end
  end

  defp next_tool_loop_step(state) do
    with :ok <- ensure_not_aborted_runtime(state.stream_opts),
         {:ok, step_stream} <-
           stream_call_with_retry(state.client, state.request, state.stream_opts),
         step_events = Enum.to_list(step_stream),
         {:ok, tool_calls} <- extract_tool_calls_from_events(step_events) do
      cond do
        state.max_steps <= 0 ->
          {:ok, %{state | pending_events: step_events, done?: true}}

        tool_calls == [] ->
          {:ok, %{state | pending_events: step_events, done?: true}}

        not should_auto_execute_tool_calls?(tool_calls, state.tools) ->
          {:ok, %{state | pending_events: step_events, done?: true}}

        true ->
          with {:ok, tool_messages, tool_result_events, next_budget} <-
                 execute_tool_calls_for_stream(
                   tool_calls,
                   state.tools,
                   state.parallel,
                   state.tool_result_budget
                 ) do
            step_finish_event = %Arbor.LLM.StreamEvent{
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
                 tool_result_budget: next_budget,
                 pending_events: step_events ++ tool_result_events ++ [step_finish_event],
                 max_steps: state.max_steps - 1,
                 step_index: state.step_index + 1,
                 done?: false
             }}
          end
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
      %Arbor.LLM.StreamEvent{type: :delta, data: %{"text" => text}}, acc ->
        [to_string(text) | acc]

      %Arbor.LLM.StreamEvent{type: :delta, data: %{text: text}}, acc ->
        [to_string(text) | acc]

      _, acc ->
        acc
    end)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp extract_tool_calls_from_events(events) do
    entries =
      Enum.flat_map(events, fn
        %Arbor.LLM.StreamEvent{type: :tool_call, data: data} -> [data]
        _event -> []
      end)

    with :ok <- preflight_tool_call_entries(entries) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case normalize_tool_call_data(entry) do
          {:ok, call} -> {:cont, {:ok, [call | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, calls} -> {:ok, Enum.reverse(calls)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize_tool_call_data(data) when is_map(data) do
    with {:ok, arguments} <-
           normalize_tool_call_arguments(
             Map.get(data, "arguments") || Map.get(data, :arguments) || Map.get(data, "args") ||
               Map.get(data, :args) || %{}
           ) do
      {:ok,
       %{
         "id" => to_string(Map.get(data, "id") || Map.get(data, :id) || "call"),
         "name" => Map.get(data, "name") || Map.get(data, :name),
         "arguments" => arguments
       }}
    end
  end

  defp normalize_tool_call_data(_), do: {:error, :tool_call_map_required}

  defp normalize_tool_call_arguments(arguments) when is_map(arguments) do
    case ResponseBudget.validate(arguments, @tool_argument_limits) do
      :ok -> {:ok, arguments}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp normalize_tool_call_arguments(arguments) when is_binary(arguments) do
    case ResponseBudget.decode_json(arguments, @tool_argument_limits) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> {:error, :tool_arguments_must_be_map}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp normalize_tool_call_arguments(_), do: {:error, :tool_arguments_must_be_map_or_json}

  defp preflight_tool_call_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{bytes: 0, nodes: 0, map_keys: 0, list_items: 0}}, fn
      data, {:ok, aggregate} when is_map(data) ->
        arguments =
          Map.get(data, "arguments") || Map.get(data, :arguments) || Map.get(data, "args") ||
            Map.get(data, :args) || %{}

        case preflight_tool_call_arguments(arguments) do
          {:ok, measurements} ->
            case add_tool_argument_measurements(aggregate, measurements) do
              {:ok, next} -> {:cont, {:ok, next}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      _data, _aggregate ->
        {:halt, {:error, :tool_call_map_required}}
    end)
    |> case do
      {:ok, _aggregate} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp preflight_tool_call_arguments(arguments) when is_binary(arguments) do
    case ResponseBudget.preflight_json(arguments, @tool_argument_limits) do
      {:ok, measurements} -> {:ok, measurements}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp preflight_tool_call_arguments(arguments) when is_map(arguments),
    do: ResponseBudget.measure(arguments, @tool_argument_limits)

  defp preflight_tool_call_arguments(_arguments),
    do: {:error, :tool_arguments_must_be_map_or_json}

  defp add_tool_argument_measurements(aggregate, measurements) do
    next = %{
      bytes: aggregate.bytes + Map.get(measurements, :bytes, 0),
      nodes: aggregate.nodes + Map.get(measurements, :nodes, 0),
      map_keys: aggregate.map_keys + Map.get(measurements, :map_keys, 0),
      list_items: aggregate.list_items + Map.get(measurements, :list_items, 0)
    }

    case Enum.find(@tool_argument_aggregate_limits, fn {key, maximum} -> next[key] > maximum end) do
      nil -> {:ok, next}
      {key, maximum} -> {:error, {:tool_argument_aggregate_exceeded, key, maximum}}
    end
  end

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

  defp execute_tool_calls_for_stream(tool_calls, tools, parallel, aggregate) do
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

    encode_stream_tool_results(results, aggregate, [], [])
  end

  defp encode_stream_tool_results([], aggregate, messages, events),
    do: {:ok, Enum.reverse(messages), Enum.reverse(events), aggregate}

  defp encode_stream_tool_results([{output, id, name} | rest], aggregate, messages, events) do
    with {:ok, encoded, next} <- Arbor.LLM.ToolResultBudget.encode(output, aggregate) do
      message = Message.new(:tool, encoded, %{"tool_call_id" => id, "name" => name})

      event = %Arbor.LLM.StreamEvent{
        type: :tool_result,
        data: %{
          "id" => id,
          "name" => name,
          "status" => output["status"],
          "result" => Map.get(output, "result"),
          "error" => Map.get(output, "error")
        }
      }

      encode_stream_tool_results(rest, next, [message | messages], [event | events])
    end
  end

  defp encode_stream_tool_results(_invalid, _aggregate, _messages, _events),
    do: {:error, :invalid_tool_execution_result}

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

    {output, id, name}
  end

  defp safe_execute_stream_tool(execute, arguments) do
    case execute.(arguments) do
      {:ok, map} when is_map(map) ->
        %{"status" => "ok", "result" => map}

      {:error, reason} ->
        %{
          "status" => "error",
          "error" => Arbor.LLM.ExternalTerm.inspect(reason),
          "type" => :execution_failed
        }

      map when is_map(map) ->
        %{"status" => "ok", "result" => map}

      other ->
        %{"status" => "ok", "result" => other}
    end
  rescue
    exception ->
      %{
        "status" => "error",
        "error" => Arbor.LLM.ExternalTerm.exception_message(exception),
        "type" => :execution_failed
      }
  catch
    kind, reason ->
      %{
        "status" => "error",
        "error" => Atom.to_string(kind) <> ": " <> Arbor.LLM.ExternalTerm.inspect(reason),
        "type" => :execution_failed
      }
  end

  defp fallback_tool_stream_result(reason) do
    output = %{
      "status" => "error",
      "error" => "tool failed: " <> Arbor.LLM.ExternalTerm.inspect(reason),
      "type" => :execution_failed
    }

    {output, "call", "unknown"}
  end

  defp ensure_not_aborted_runtime(opts) do
    if aborted?(opts) do
      {:error, AbortError.exception([])}
    else
      :ok
    end
  end

  defp wrap_stream_runtime_controls(events, opts, receipt) do
    timeout_ms = receipt.timeout_ms
    deadline_ms = receipt.deadline_ms
    abort_fun = abort_fun(opts)
    {:ok, tracker} = Boundary.stream_tracker(opts)
    {:ok, max_events} = Boundary.stream_event_limit(opts)
    build_controlled_stream(events, timeout_ms, deadline_ms, abort_fun, tracker, max_events, opts)
  end

  defp build_controlled_stream(
         events,
         timeout_ms,
         deadline_ms,
         abort_fun,
         tracker,
         max_events,
         opts
       ) do
    track_events? = not match?(%Arbor.LLM.OwnedStream{}, events)

    Stream.resource(
      fn ->
        owner = self()
        ref = make_ref()
        reply_alias = :erlang.alias()

        {producer_pid, monitor_ref} =
          spawn_monitor(fn -> produce_stream_events(owner, reply_alias, ref, events) end)

        %{
          ref: ref,
          reply_alias: reply_alias,
          producer_pid: producer_pid,
          monitor_ref: monitor_ref,
          timeout_ms: timeout_ms,
          abort_fun: abort_fun,
          absolute_deadline_ms: deadline_ms,
          done?: false,
          producer_down?: false,
          demand_outstanding?: false,
          tracker: tracker,
          max_events: max_events,
          event_count: 0,
          boundary_opts: opts,
          track_events?: track_events?
        }
      end,
      &next_controlled_stream_item/1,
      &close_controlled_stream/1
    )
  end

  defp produce_stream_events(owner, reply_alias, ref, events) do
    owner_monitor = Process.monitor(owner)

    try do
      Enum.reduce_while(events, :ok, fn event, :ok ->
        receive do
          {^ref, :demand} ->
            send(reply_alias, {ref, :event, event, System.monotonic_time(:millisecond)})
            {:cont, :ok}

          {^ref, :cancel} ->
            {:halt, :cancelled}

          {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
            {:halt, :owner_down}
        end
      end)

      send(reply_alias, {ref, :done, System.monotonic_time(:millisecond)})
    after
      Process.demonitor(owner_monitor, [:flush])
    end
  rescue
    exception ->
      send(
        reply_alias,
        {ref, :producer_error, {:error, Arbor.LLM.ExternalTerm.exception(exception)},
         System.monotonic_time(:millisecond)}
      )
  catch
    kind, reason ->
      send(
        reply_alias,
        {ref, :producer_error, {kind, Arbor.LLM.ExternalTerm.sanitize(reason)},
         System.monotonic_time(:millisecond)}
      )
  end

  defp next_controlled_stream_item(%{done?: true} = state), do: {:halt, state}

  defp next_controlled_stream_item(state) do
    maybe_raise_if_aborted(state.abort_fun)
    maybe_raise_if_stream_timed_out(state)

    receive_timeout = next_receive_timeout_ms(state)
    state = request_controlled_demand(state)

    receive do
      {ref, :event, event, completed_mono} when ref == state.ref ->
        if completed_within_stream_deadline?(state, completed_mono) do
          case validate_controlled_event(event, state) do
            {:ok, normalized, next_state} ->
              {[normalized], %{next_state | demand_outstanding?: false}}

            {:error, reason} ->
              raise Arbor.LLM.StreamError, reason: reason
          end
        else
          raise RequestTimeoutError, timeout_ms: state.timeout_ms
        end

      {ref, :done, completed_mono} when ref == state.ref ->
        if completed_within_stream_deadline?(state, completed_mono) do
          {:halt, %{state | done?: true}}
        else
          raise RequestTimeoutError, timeout_ms: state.timeout_ms
        end

      {ref, :producer_error, {:error, reason}, completed_mono}
      when ref == state.ref ->
        if completed_within_stream_deadline?(state, completed_mono),
          do: raise_bounded_producer_exception(reason),
          else: raise(RequestTimeoutError, timeout_ms: state.timeout_ms)

      {ref, :producer_error, {kind, reason}, completed_mono} when ref == state.ref ->
        if completed_within_stream_deadline?(state, completed_mono),
          do: raise(Arbor.LLM.StreamError, reason: {:stream_producer_failed, kind, reason}),
          else: raise(RequestTimeoutError, timeout_ms: state.timeout_ms)

      {:DOWN, mon_ref, :process, pid, _reason}
      when mon_ref == state.monitor_ref and pid == state.producer_pid ->
        {:halt, %{state | done?: true, producer_down?: true}}
    after
      receive_timeout ->
        maybe_raise_if_stream_timed_out(state)
        next_controlled_stream_item(state)
    end
  end

  defp validate_controlled_event(event, %{track_events?: false} = state),
    do: {:ok, event, state}

  defp validate_controlled_event(event, state) do
    event_count = state.event_count + 1

    if event_count > state.max_events do
      {:error, {:stream_limit_exceeded, :events, state.max_events}}
    else
      case Boundary.track_stream_event(state.tracker, event, state.boundary_opts) do
        {:ok, normalized} -> {:ok, normalized, %{state | event_count: event_count}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp raise_bounded_producer_exception({RuntimeError, message}) when is_binary(message),
    do: raise(RuntimeError, message)

  defp raise_bounded_producer_exception(reason),
    do: raise(Arbor.LLM.StreamError, reason: {:stream_producer_failed, :error, reason})

  defp request_controlled_demand(%{demand_outstanding?: true} = state), do: state

  defp request_controlled_demand(state) do
    send(state.producer_pid, {state.ref, :demand})
    %{state | demand_outstanding?: true}
  end

  defp close_controlled_stream(state) do
    deadline = System.monotonic_time(:millisecond) + @controlled_wrapper_cleanup_grace_ms
    :erlang.unalias(state.reply_alias)
    send(state.producer_pid, {state.ref, :cancel})

    producer_down? =
      state.producer_down? or
        await_controlled_down_until(state, deadline)

    unless producer_down? do
      if Process.alive?(state.producer_pid), do: Process.exit(state.producer_pid, :kill)
      await_controlled_down_until(state, deadline)
    end

    Process.demonitor(state.monitor_ref, [:flush])
    flush_controlled_messages(state.ref, state.monitor_ref, state.producer_pid)
    :ok
  end

  defp await_controlled_down_until(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, monitor_ref, :process, producer_pid, _reason}
      when monitor_ref == state.monitor_ref and producer_pid == state.producer_pid ->
        true
    after
      remaining -> false
    end
  end

  defp flush_controlled_messages(ref, monitor_ref, producer_pid) do
    receive do
      {^ref, _kind} ->
        flush_controlled_messages(ref, monitor_ref, producer_pid)

      {^ref, _kind, _value} ->
        flush_controlled_messages(ref, monitor_ref, producer_pid)

      {^ref, _kind, _value, _completed_mono} ->
        flush_controlled_messages(ref, monitor_ref, producer_pid)

      {:DOWN, ^monitor_ref, :process, ^producer_pid, _reason} ->
        flush_controlled_messages(ref, monitor_ref, producer_pid)
    after
      0 -> :ok
    end
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

  defp maybe_raise_if_stream_timed_out(%{
         timeout_ms: timeout_ms,
         absolute_deadline_ms: absolute_deadline_ms
       }) do
    if System.monotonic_time(:millisecond) >= absolute_deadline_ms do
      raise RequestTimeoutError, timeout_ms: timeout_ms
    else
      :ok
    end
  end

  defp completed_within_stream_deadline?(%{timeout_ms: nil}, _completed_mono), do: true

  defp completed_within_stream_deadline?(state, completed_mono),
    do: is_integer(completed_mono) and completed_mono <= state.absolute_deadline_ms

  defp next_receive_timeout_ms(%{timeout_ms: nil, abort_fun: abort_fun})
       when is_function(abort_fun, 0),
       do: 100

  defp next_receive_timeout_ms(%{timeout_ms: nil}), do: :infinity

  defp next_receive_timeout_ms(%{
         timeout_ms: timeout_ms,
         absolute_deadline_ms: absolute_deadline_ms,
         abort_fun: abort_fun
       }) do
    remaining_ms = max(absolute_deadline_ms - System.monotonic_time(:millisecond), 0)

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

  @doc false
  def validate_decoded_term(term, opts), do: Arbor.LLM.ResponseBudget.validate(term, opts)

  @doc false
  def decode_bounded_json(body, opts), do: Arbor.LLM.ResponseBudget.decode_json(body, opts)

  @doc false
  def decode_bounded_json_numbers(body, opts, keys),
    do: Arbor.LLM.ResponseBudget.decode_json_numbers(body, opts, keys)

  @doc false
  def exact_unit_number?(lexeme), do: Arbor.LLM.ResponseBudget.exact_unit_number?(lexeme)

  @doc false
  def validate_endpoint(value, policy), do: Arbor.LLM.Endpoint.validate(value, policy)

  @doc false
  def finite_number?(value), do: Arbor.LLM.ResponseBudget.finite_number?(value)

  @doc false
  def normalize_timeout_options(opts, default_timeout_ms \\ @default_public_timeout_ms),
    do: Deadline.normalize_options(opts, default_timeout_ms)

  @doc false
  def timeout_option_keys, do: Deadline.timeout_keys()

  @doc false
  def select_timeout_option(opts, keys, default_timeout_ms, maximum_timeout_ms),
    do: Deadline.select(opts, keys, default_timeout_ms, maximum_timeout_ms)

  @doc false
  def sanitize_external_reason(reason), do: Arbor.LLM.ExternalTerm.sanitize(reason)

  @doc false
  def sanitize_external_exception(exception), do: Arbor.LLM.ExternalTerm.exception(exception)

  @doc false
  def external_exception_message(exception),
    do: Arbor.LLM.ExternalTerm.exception_message(exception)

  @doc false
  def inspect_external_reason(reason), do: Arbor.LLM.ExternalTerm.inspect(reason)

  @doc false
  def run_with_deadline(fun, timeout_ms, timeout_error) when is_function(fun, 0) do
    with {:ok, receipt} <- Deadline.receipt(timeout_ms: timeout_ms) do
      Deadline.run(fun, receipt, timeout_error)
    end
  end

  def run_with_deadline(_fun, _timeout_ms, _timeout_error),
    do: {:error, :invalid_deadline_operation}

  @doc false
  def run_until_deadline(fun, deadline_ms, timeout_ms, timeout_error) when is_function(fun, 0) do
    with {:ok, receipt} <- Deadline.receipt_until(deadline_ms, timeout_ms) do
      Deadline.run(fun, receipt, timeout_error)
    end
  end

  def run_until_deadline(_fun, _deadline_ms, _timeout_ms, _timeout_error),
    do: {:error, :invalid_deadline_operation}

  @doc false
  def read_bounded_regular_file(path, maximum),
    do: Arbor.LLM.FileReceipt.read(path, maximum)

  @doc """
  Validate and normalize an OpenAI-compatible batch embedding response.

  Every response entry must carry the exact next input `index` in submitted
  batch order. Reordered, duplicate, missing, or fabricated associations are
  rejected before vectors are returned.
  """
  @spec decode_embedding_response(term(), pos_integer()) ::
          {:ok, [[number()]], term()} | {:error, term()}
  def decode_embedding_response(body, expected_count),
    do: Boundary.embedding_response(body, expected_count)
end
