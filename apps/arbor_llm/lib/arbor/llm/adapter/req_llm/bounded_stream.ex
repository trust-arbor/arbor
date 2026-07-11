defmodule Arbor.LLM.Adapter.ReqLLM.BoundedStream do
  @moduledoc false

  alias Arbor.LLM.JSONPreflight
  alias Arbor.LLM.ResponseBudget

  @default_max_response_bytes 16_777_216
  @default_max_events 100_000
  @default_max_event_bytes 1_048_576
  @cleanup_grace_ms 100
  @cleanup_kill_wait_ms 1_000

  defstruct [:stream, :cancel, :model, :context, :limits, :producer]

  @type t :: %__MODULE__{}

  @spec start(term(), term(), keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(model_spec, messages, opts, limits_opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider} <- ReqLLM.provider(model.provider),
         {:ok, context} <- ReqLLM.Context.normalize(messages, opts),
         finch_name = Keyword.get(opts, :finch_name, ReqLLM.Finch),
         {:ok, request} <- provider.attach_stream(model, context, opts, finch_name),
         {:ok, limits} <- build_limits(opts, limits_opts) do
      ref = make_ref()

      pid =
        spawn(fn ->
          await_consumer(ref, request, finch_name, provider, model, limits)
        end)

      stream = bounded_enumerable(pid, ref, limits)

      {:ok,
       %__MODULE__{
         stream: stream,
         cancel: fn -> cancel_and_wait(pid, ref) end,
         model: model,
         context: context,
         limits: limits,
         producer: pid
       }}
    end
  rescue
    exception -> {:error, {:stream_setup_failed, bounded_exception(exception)}}
  catch
    kind, reason -> {:error, {:stream_setup_failed, {kind, bounded_reason(reason)}}}
  end

  @spec process(t(), keyword()) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
  def process(%__MODULE__{} = response, callbacks \\ []) do
    initial = %{chunks: [], metadata: %{}, fragments: %{}, fragment_bytes: 0}

    result =
      Enum.reduce_while(response.stream, {:ok, initial}, fn
        {:arbor_stream_error, reason}, _acc ->
          {:halt, {:error, reason}}

        %ReqLLM.StreamChunk{} = chunk, {:ok, acc} ->
          with :ok <- invoke_callback(chunk, callbacks),
               {:ok, acc} <- collect_chunk(chunk, acc, response.limits) do
            {:cont, {:ok, acc}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        other, _acc ->
          {:halt, {:error, {:invalid_stream_chunk, bounded_reason(other)}}}
      end)

    with {:ok, acc} <- result,
         {:ok, fragment_chunks} <- finalize_fragments(acc.fragments, response.limits),
         chunks = Enum.reverse(acc.chunks) ++ fragment_chunks,
         builder = ReqLLM.Provider.ResponseBuilder.for_model(response.model) do
      builder.build_response(chunks, acc.metadata,
        context: response.context,
        model: response.model
      )
    end
  rescue
    exception -> {:error, {:stream_assembly_failed, bounded_exception(exception)}}
  catch
    kind, reason -> {:error, {:stream_assembly_failed, {kind, bounded_reason(reason)}}}
  end

  defp build_limits(opts, limits_opts) do
    maximum = Keyword.get(limits_opts, :max_response_bytes, @default_max_response_bytes)
    max_events = Keyword.get(limits_opts, :max_events, @default_max_events)
    max_event_bytes = Keyword.get(limits_opts, :max_event_bytes, @default_max_event_bytes)
    timeout = Keyword.get(opts, :receive_timeout, 30_000)

    if Enum.all?([maximum, max_events, max_event_bytes, timeout], &(is_integer(&1) and &1 > 0)) and
         maximum <= @default_max_response_bytes and max_events <= @default_max_events and
         max_event_bytes <= min(maximum, @default_max_event_bytes) do
      {:ok,
       %{
         max_response_bytes: maximum,
         max_events: max_events,
         max_event_bytes: max_event_bytes,
         max_work: max_events * 16,
         max_nodes: 100_000,
         max_depth: 32,
         max_map_keys: 10_000,
         max_list_items: 100_000,
         timeout: timeout,
         deadline_ms: System.monotonic_time(:millisecond) + timeout
       }}
    else
      {:error, :invalid_stream_limits}
    end
  end

  defp bounded_enumerable(pid, ref, limits) do
    Stream.resource(
      fn ->
        monitor = Process.monitor(pid)
        send(pid, {ref, :consumer, self()})
        %{pid: pid, ref: ref, monitor: monitor, limits: limits, done?: false}
      end,
      &next_item/1,
      &cleanup_resource/1
    )
  end

  defp next_item(%{done?: true} = state), do: {:halt, state}

  defp next_item(state) do
    remaining = remaining_ms(state.limits.deadline_ms)

    if remaining <= 0 do
      {[{:arbor_stream_error, {:stream_deadline_exceeded, state.limits.timeout}}],
       %{state | done?: true}}
    else
      receive do
        {ref, :chunk, chunk} when ref == state.ref ->
          send(state.pid, {state.ref, :continue})
          {[chunk], state}

        {ref, :error, reason} when ref == state.ref ->
          {[{:arbor_stream_error, reason}], %{state | done?: true}}

        {ref, :done} when ref == state.ref ->
          {:halt, %{state | done?: true}}

        {:DOWN, monitor, :process, pid, reason}
        when monitor == state.monitor and pid == state.pid ->
          if reason == :normal do
            {:halt, %{state | done?: true}}
          else
            error = producer_exit_reason(reason, state.limits)
            {[{:arbor_stream_error, error}], %{state | done?: true}}
          end
      after
        remaining ->
          {[{:arbor_stream_error, {:stream_deadline_exceeded, state.limits.timeout}}],
           %{state | done?: true}}
      end
    end
  end

  defp cleanup_resource(state) do
    cleanup_result = cancel_and_wait(state.pid, state.ref)
    Process.demonitor(state.monitor, [:flush])
    flush_messages(state.ref, state.pid, state.monitor)

    case cleanup_result do
      :ok -> :ok
      {:error, :producer_cleanup_timeout} -> raise "stream producer cleanup timed out"
    end
  end

  defp cancel_and_wait(pid, ref) when is_pid(pid) do
    monitor = Process.monitor(pid)
    send(pid, {ref, :cancel})

    down? =
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> true
      after
        @cleanup_grace_ms ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^pid, _reason} -> true
          after
            @cleanup_kill_wait_ms -> false
          end
      end

    Process.demonitor(monitor, [:flush])
    if down?, do: :ok, else: {:error, :producer_cleanup_timeout}
  end

  defp await_consumer(ref, request, finch_name, provider, model, limits) do
    remaining = remaining_ms(limits.deadline_ms)

    receive do
      {^ref, :consumer, consumer} when is_pid(consumer) ->
        producer = self()
        guardian = spawn(fn -> guard_producer(producer, consumer, limits.deadline_ms) end)
        run_request(ref, consumer, request, finch_name, provider, model, limits)
        send(guardian, :producer_done)

      {^ref, :cancel} ->
        :ok
    after
      max(remaining, 0) -> :ok
    end
  end

  defp guard_producer(producer, consumer, deadline_ms) do
    producer_ref = Process.monitor(producer)
    consumer_ref = Process.monitor(consumer)
    remaining = remaining_ms(deadline_ms)

    receive do
      :producer_done -> :ok
      {:DOWN, ^producer_ref, :process, ^producer, _reason} -> :ok
      {:DOWN, ^consumer_ref, :process, ^consumer, _reason} -> Process.exit(producer, :kill)
    after
      max(remaining, 0) -> Process.exit(producer, {:shutdown, :stream_deadline})
    end
  end

  defp run_request(ref, consumer, request, finch_name, provider, model, limits) do
    provider_state =
      if function_exported?(provider, :init_stream_state, 1),
        do: provider.init_stream_state(model),
        else: nil

    state = %{
      ref: ref,
      consumer: consumer,
      provider: provider,
      provider_state: provider_state,
      model: model,
      limits: limits,
      status: nil,
      headers_valid?: false,
      raw_bytes: 0,
      event_count: 0,
      chunk_count: 0,
      work: 0,
      decoded_nodes: 0,
      decoded_bytes: 0,
      decoded_map_keys: 0,
      decoded_list_items: 0,
      terminal?: false,
      cancelled?: false,
      failure: nil,
      sse: new_sse_state()
    }

    request_opts = [
      receive_timeout: min(limits.timeout, max(remaining_ms(limits.deadline_ms), 1)),
      request_timeout: max(remaining_ms(limits.deadline_ms), 1)
    ]

    callback = fn event, acc -> handle_http_event(event, acc) end

    final_state =
      case Finch.stream_while(request, finch_name, state, callback, request_opts) do
        {:ok, state} ->
          state

        {:error, reason, state} ->
          %{state | failure: state.failure || {:stream_transport_error, bounded_reason(reason)}}
      end

    finish_request(final_state)
  rescue
    exception ->
      send(consumer, {ref, :error, {:stream_transport_exception, bounded_exception(exception)}})
  catch
    kind, reason ->
      send(consumer, {ref, :error, {:stream_transport_exception, {kind, bounded_reason(reason)}}})
  end

  defp handle_http_event({:status, status}, state) when is_integer(status) do
    cond do
      deadline_passed?(state) ->
        halt_failure(state, deadline_error(state))

      not is_nil(state.status) ->
        halt_failure(state, :multiple_http_statuses)

      status not in 200..299 ->
        halt_failure(%{state | status: status}, {:stream_http_error, status})

      true ->
        {:cont, %{state | status: status}}
    end
  end

  defp handle_http_event({:headers, headers}, state) when is_list(headers) do
    if deadline_passed?(state) do
      halt_failure(state, deadline_error(state))
    else
      case validate_stream_headers(headers) do
        :ok -> {:cont, %{state | headers_valid?: true}}
        {:error, reason} -> halt_failure(state, reason)
      end
    end
  end

  defp handle_http_event({:data, data}, state) when is_binary(data) do
    case add_work(state, 1) do
      {:ok, state} -> handle_http_data(data, state)
      {:error, reason} -> halt_failure(state, reason)
    end
  end

  defp handle_http_event({:trailers, _trailers}, state), do: {:cont, state}
  defp handle_http_event(_event, state), do: halt_failure(state, :unexpected_http_stream_event)

  defp handle_http_data(data, state) do
    cond do
      deadline_passed?(state) ->
        halt_failure(state, deadline_error(state))

      state.status not in 200..299 ->
        halt_failure(state, {:stream_http_error, state.status})

      not state.headers_valid? ->
        halt_failure(state, {:invalid_stream_headers, :headers_required_before_body})

      byte_size(data) > state.limits.max_response_bytes - state.raw_bytes ->
        halt_failure(
          state,
          {:stream_limit_exceeded, :response_bytes, state.limits.max_response_bytes}
        )

      true ->
        state = %{state | raw_bytes: state.raw_bytes + byte_size(data)}

        case feed_sse(data, state) do
          {:ok, state} -> {:cont, state}
          {:halt, state} -> {:halt, state}
        end
    end
  end

  defp validate_stream_headers(headers) do
    content_types = header_values(headers, "content-type")
    encodings = header_values(headers, "content-encoding")

    case content_types do
      [content_type] when is_binary(content_type) ->
        validate_stream_header_values(content_type, encodings)

      _conflicting_or_malformed ->
        {:error, {:invalid_stream_headers, :text_event_stream_required}}
    end
  end

  defp validate_stream_header_values(content_type, encodings) do
    cond do
      not event_stream_content_type?(content_type) ->
        {:error, {:invalid_stream_headers, :text_event_stream_required}}

      Enum.any?(encodings, &(String.downcase(String.trim(&1)) not in ["", "identity"])) ->
        {:error, {:invalid_stream_headers, :content_encoding_forbidden}}

      true ->
        :ok
    end
  end

  defp header_values(headers, wanted) do
    for {name, value} <- headers,
        is_binary(name) and is_binary(value) and String.downcase(name) == wanted,
        do: value
  end

  defp event_stream_content_type?(value) do
    value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
      "text/event-stream"
  end

  defp new_sse_state do
    %{
      line_parts: [],
      line_bytes: 0,
      data_parts: [],
      event: nil,
      id: nil,
      event_bytes: 0,
      first_line?: true
    }
  end

  defp feed_sse("", state), do: {:ok, state}

  defp feed_sse(data, state) do
    case :binary.match(data, "\n") do
      :nomatch ->
        append_incomplete_line(data, state)

      {index, 1} ->
        piece = binary_part(data, 0, index)
        rest = binary_part(data, index + 1, byte_size(data) - index - 1)

        with {:ok, line, state} <- complete_line(piece, state),
             {:ok, state} <- process_sse_line(line, state) do
          if state.terminal? or state.cancelled? or state.failure,
            do: {:halt, state},
            else: feed_sse(rest, state)
        else
          {:halt, state} -> {:halt, state}
        end
    end
  end

  defp append_incomplete_line("", state), do: {:ok, state}

  defp append_incomplete_line(piece, state) do
    bytes = state.sse.line_bytes + byte_size(piece)

    if bytes > state.limits.max_event_bytes do
      {:halt,
       fail_state(
         state,
         {:stream_limit_exceeded, :incomplete_sse_bytes, state.limits.max_event_bytes}
       )}
    else
      sse = %{state.sse | line_parts: [piece | state.sse.line_parts], line_bytes: bytes}
      {:ok, %{state | sse: sse}}
    end
  end

  defp complete_line(piece, state) do
    bytes = state.sse.line_bytes + byte_size(piece)

    if bytes > state.limits.max_event_bytes do
      {:halt,
       fail_state(state, {:stream_limit_exceeded, :sse_line_bytes, state.limits.max_event_bytes})}
    else
      line =
        case state.sse.line_parts do
          [] -> piece
          parts -> [piece | parts] |> Enum.reverse() |> IO.iodata_to_binary()
        end
        |> strip_carriage_return()

      sse = %{state.sse | line_parts: [], line_bytes: 0}
      {:ok, line, %{state | sse: sse}}
    end
  end

  defp strip_carriage_return(line) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  defp process_sse_line(line, state) do
    with {:ok, state} <- add_work(state, 1) do
      line = if state.sse.first_line?, do: strip_bom(line), else: line
      state = put_in(state.sse.first_line?, false)

      cond do
        line == "" -> complete_sse_event(state)
        String.starts_with?(line, ":") -> {:ok, state}
        true -> put_sse_field(line, state)
      end
    else
      {:error, reason} -> {:halt, fail_state(state, reason)}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(line), do: line

  defp put_sse_field(line, state) do
    {field, value} = split_sse_field(line)

    value =
      if String.starts_with?(value, " "),
        do: binary_part(value, 1, byte_size(value) - 1),
        else: value

    bytes = state.sse.event_bytes + byte_size(value) + 1

    if bytes > state.limits.max_event_bytes do
      {:halt,
       fail_state(state, {:stream_limit_exceeded, :sse_event_bytes, state.limits.max_event_bytes})}
    else
      sse =
        case field do
          "data" -> %{state.sse | data_parts: [value | state.sse.data_parts], event_bytes: bytes}
          "event" -> %{state.sse | event: value, event_bytes: bytes}
          "id" -> %{state.sse | id: value, event_bytes: bytes}
          _ -> %{state.sse | event_bytes: bytes}
        end

      {:ok, %{state | sse: sse}}
    end
  end

  defp split_sse_field(line) do
    case :binary.match(line, ":") do
      :nomatch ->
        {line, ""}

      {index, 1} ->
        {binary_part(line, 0, index), binary_part(line, index + 1, byte_size(line) - index - 1)}
    end
  end

  defp complete_sse_event(%{sse: %{data_parts: [], event: nil, id: nil}} = state) do
    {:ok, %{state | sse: reset_event(state.sse)}}
  end

  defp complete_sse_event(state) do
    event_count = state.event_count + 1

    with true <- event_count <= state.limits.max_events,
         {:ok, state} <- add_work(state, 1) do
      data =
        state.sse.data_parts |> Enum.reverse() |> Enum.intersperse("\n") |> IO.iodata_to_binary()

      event =
        %{data: data}
        |> maybe_put(:event, state.sse.event)
        |> maybe_put(:id, state.sse.id)

      state = %{state | event_count: event_count, sse: reset_event(state.sse)}

      case process_provider_event(event, state) do
        {:ok, state} -> if(state.terminal?, do: {:halt, state}, else: {:ok, state})
        {:error, reason, state} -> {:halt, fail_state(state, reason)}
        {:cancel, state} -> {:halt, %{state | cancelled?: true}}
      end
    else
      false ->
        {:halt, fail_state(state, {:stream_limit_exceeded, :events, state.limits.max_events})}

      {:error, reason} ->
        {:halt, fail_state(state, reason)}
    end
  end

  defp reset_event(sse),
    do: %{sse | data_parts: [], event: nil, id: nil, event_bytes: 0}

  defp process_provider_event(%{data: "[DONE]"} = event, state) do
    decode_and_emit(event, %{state | terminal?: true})
  end

  defp process_provider_event(%{data: data} = event, state) do
    json_limits = json_limits(state.limits, state.limits.max_event_bytes)

    with true <- String.valid?(data) or {:error, {:invalid_stream_json, :valid_utf8_required}},
         {:ok, measurements} <- JSONPreflight.scan(data, json_limits),
         {:ok, decoded} <- Jason.decode(data),
         {:ok, state} <- add_measurements(state, measurements),
         {:ok, state} <- validate_complete_arguments(decoded, state) do
      event = %{event | data: decoded}
      state = if termination_data?(decoded), do: %{state | terminal?: true}, else: state
      decode_and_emit(event, state)
    else
      {:error, reason} -> {:error, {:invalid_stream_json, reason}, state}
    end
  end

  defp decode_and_emit(event, state) do
    try do
      {chunks, provider_state} = decode_provider_event(event, state)
      emit_chunks(chunks, %{state | provider_state: provider_state})
    rescue
      exception -> {:error, {:stream_decode_failed, bounded_exception(exception)}, state}
    catch
      kind, reason -> {:error, {:stream_decode_failed, {kind, bounded_reason(reason)}}, state}
    end
  end

  defp decode_provider_event(event, state) do
    cond do
      function_exported?(state.provider, :decode_stream_event, 3) ->
        state.provider.decode_stream_event(event, state.model, state.provider_state)

      function_exported?(state.provider, :decode_stream_event, 2) ->
        {state.provider.decode_stream_event(event, state.model), state.provider_state}

      true ->
        {ReqLLM.Provider.Defaults.default_decode_stream_event(event, state.model),
         state.provider_state}
    end
  end

  defp emit_chunks([], state), do: {:ok, state}

  defp emit_chunks([%ReqLLM.StreamChunk{} = chunk | rest], state) do
    chunk_count = state.chunk_count + 1

    cond do
      chunk_count > state.limits.max_events ->
        {:error, {:stream_limit_exceeded, :decoded_chunks, state.limits.max_events}, state}

      true ->
        with {:ok, state} <- add_work(state, 1) do
          case ResponseBudget.measure(
                 chunk,
                 json_limits(state.limits, state.limits.max_response_bytes)
               ) do
            {:ok, measurements} ->
              with {:ok, state} <-
                     add_measurements(%{state | chunk_count: chunk_count}, measurements),
                   :continue <- emit_chunk(chunk, state) do
                emit_chunks(rest, state)
              else
                {:error, reason} -> {:error, reason, state}
                :cancel -> {:cancel, state}
                :deadline -> {:error, deadline_error(state), state}
              end

            {:error, reason} ->
              {:error, {:invalid_stream_chunk, reason}, state}
          end
        else
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp emit_chunks(_improper_or_invalid, state),
    do: {:error, {:invalid_stream_chunk, :proper_chunk_list_required}, state}

  defp emit_chunk(chunk, state) do
    send(state.consumer, {state.ref, :chunk, chunk})
    remaining = remaining_ms(state.limits.deadline_ms)

    receive do
      {ref, :continue} when ref == state.ref -> :continue
      {ref, :cancel} when ref == state.ref -> :cancel
    after
      max(remaining, 0) -> :deadline
    end
  end

  defp add_measurements(state, measurements) do
    nodes = state.decoded_nodes + Map.get(measurements, :nodes, 0)

    bytes =
      state.decoded_bytes + Map.get(measurements, :string_bytes, Map.get(measurements, :bytes, 0))

    map_keys = state.decoded_map_keys + Map.get(measurements, :map_keys, 0)
    list_items = state.decoded_list_items + Map.get(measurements, :list_items, 0)

    cond do
      nodes > state.limits.max_nodes ->
        {:error, {:stream_limit_exceeded, :decoded_nodes, state.limits.max_nodes}}

      bytes > state.limits.max_response_bytes ->
        {:error, {:stream_limit_exceeded, :decoded_bytes, state.limits.max_response_bytes}}

      map_keys > state.limits.max_map_keys ->
        {:error, {:stream_limit_exceeded, :decoded_map_keys, state.limits.max_map_keys}}

      list_items > state.limits.max_list_items ->
        {:error, {:stream_limit_exceeded, :decoded_list_items, state.limits.max_list_items}}

      true ->
        {:ok,
         %{
           state
           | decoded_nodes: nodes,
             decoded_bytes: bytes,
             decoded_map_keys: map_keys,
             decoded_list_items: list_items
         }}
    end
  end

  defp validate_complete_arguments(term, state), do: validate_arguments([{:value, term}], state)

  defp validate_arguments([], state), do: {:ok, state}

  defp validate_arguments([{:value, map} | rest], state) when is_map(map) do
    result =
      case {Map.get(map, "name"), Map.get(map, "arguments")} do
        {name, arguments} when is_binary(name) and is_binary(arguments) ->
          case JSONPreflight.scan(
                 arguments,
                 json_limits(state.limits, state.limits.max_event_bytes)
               ) do
            {:ok, measurements} -> add_measurements(state, measurements)
            {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
          end

        _ ->
          {:ok, state}
      end

    with {:ok, state} <- result do
      validate_arguments([{:map, :maps.iterator(map)} | rest], state)
    end
  end

  defp validate_arguments([{:map, iterator} | rest], state) do
    case :maps.next(iterator) do
      :none ->
        validate_arguments(rest, state)

      {_key, value, next} ->
        validate_arguments([{:value, value}, {:map, next} | rest], state)
    end
  end

  defp validate_arguments([{:value, list} | rest], state) when is_list(list),
    do: validate_arguments([{:list, list} | rest], state)

  defp validate_arguments([{:list, []} | rest], state), do: validate_arguments(rest, state)

  defp validate_arguments([{:list, [head | tail]} | rest], state),
    do: validate_arguments([{:value, head}, {:list, tail} | rest], state)

  defp validate_arguments([{:list, _improper} | _rest], _state),
    do: {:error, :improper_decoded_list}

  defp validate_arguments([{:value, _scalar} | rest], state), do: validate_arguments(rest, state)

  defp termination_data?(%{"done" => true}), do: true

  defp termination_data?(%{"type" => type}) when type in ["message_stop", "response.completed"],
    do: true

  defp termination_data?(_data), do: false

  defp finish_request(state) do
    cond do
      state.cancelled? ->
        :ok

      state.failure ->
        send(state.consumer, {state.ref, :error, state.failure})

      state.status not in 200..299 ->
        send(state.consumer, {state.ref, :error, {:stream_http_error, state.status}})

      not state.headers_valid? ->
        send(state.consumer, {state.ref, :error, {:invalid_stream_headers, :missing_headers}})

      incomplete_sse?(state.sse) ->
        send(state.consumer, {state.ref, :error, {:invalid_stream, :partial_sse_event}})

      true ->
        send(state.consumer, {state.ref, :done})
    end
  end

  defp incomplete_sse?(sse),
    do:
      sse.line_bytes > 0 or sse.line_parts != [] or sse.data_parts != [] or not is_nil(sse.event) or
        not is_nil(sse.id)

  defp halt_failure(state, reason), do: {:halt, fail_state(state, reason)}
  defp fail_state(state, reason), do: %{state | failure: state.failure || reason}

  defp add_work(state, amount) do
    work = state.work + amount

    if work <= state.limits.max_work,
      do: {:ok, %{state | work: work}},
      else: {:error, {:stream_limit_exceeded, :work, state.limits.max_work}}
  end

  defp json_limits(limits, max_bytes) do
    [
      max_bytes: max_bytes,
      max_nodes: limits.max_nodes,
      max_depth: limits.max_depth,
      max_map_keys: limits.max_map_keys,
      max_list_items: limits.max_list_items,
      max_string_bytes: max_bytes,
      max_number_bytes: 128
    ]
  end

  defp collect_chunk(%ReqLLM.StreamChunk{type: :meta, metadata: metadata} = chunk, acc, limits) do
    {tool_args, metadata} = Map.pop(metadata || %{}, :tool_call_args)
    acc = %{acc | metadata: merge_metadata(acc.metadata, metadata)}

    with {:ok, acc} <- collect_fragment(tool_args, acc, limits) do
      if map_size(metadata) == 0,
        do: {:ok, acc},
        else: {:ok, %{acc | chunks: [%{chunk | metadata: metadata} | acc.chunks]}}
    end
  end

  defp collect_chunk(chunk, acc, _limits), do: {:ok, %{acc | chunks: [chunk | acc.chunks]}}

  defp collect_fragment(nil, acc, _limits), do: {:ok, acc}

  defp collect_fragment(%{index: index, fragment: fragment}, acc, limits)
       when is_integer(index) and index >= 0 and is_binary(fragment) do
    bytes = acc.fragment_bytes + byte_size(fragment)

    if bytes <= limits.max_response_bytes do
      fragments = Map.update(acc.fragments, index, [fragment], &[fragment | &1])
      {:ok, %{acc | fragments: fragments, fragment_bytes: bytes}}
    else
      {:error, {:stream_limit_exceeded, :tool_argument_bytes, limits.max_response_bytes}}
    end
  end

  defp collect_fragment(_invalid, _acc, _limits), do: {:error, :invalid_tool_argument_fragment}

  defp finalize_fragments(fragments, limits) do
    Enum.reduce_while(fragments, {:ok, []}, fn {index, parts}, {:ok, acc} ->
      body = parts |> Enum.reverse() |> IO.iodata_to_binary()

      case ResponseBudget.validate_json(body, json_limits(limits, limits.max_response_bytes)) do
        :ok ->
          chunk = ReqLLM.StreamChunk.meta(%{tool_call_args: %{index: index, fragment: body}})
          {:cont, {:ok, [chunk | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_tool_arguments, reason}}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, Enum.reverse(chunks)}
      {:error, _reason} = error -> error
    end
  end

  defp merge_metadata(current, metadata) when is_map(metadata) do
    Map.merge(current, metadata, fn
      :usage, left, right when is_map(left) and is_map(right) -> Map.merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp invoke_callback(%ReqLLM.StreamChunk{type: :content, text: text}, callbacks)
       when is_binary(text),
       do: invoke_optional(Keyword.get(callbacks, :on_result), text)

  defp invoke_callback(%ReqLLM.StreamChunk{type: :thinking, text: text}, callbacks)
       when is_binary(text),
       do: invoke_optional(Keyword.get(callbacks, :on_thinking), text)

  defp invoke_callback(%ReqLLM.StreamChunk{type: :tool_call} = chunk, callbacks),
    do: invoke_optional(Keyword.get(callbacks, :on_tool_call), chunk)

  defp invoke_callback(_chunk, _callbacks), do: :ok

  defp invoke_optional(nil, _value), do: :ok

  defp invoke_optional(callback, value) when is_function(callback, 1) do
    callback.(value)
    :ok
  rescue
    exception -> {:error, {:stream_callback_failed, bounded_exception(exception)}}
  catch
    kind, reason -> {:error, {:stream_callback_failed, {kind, bounded_reason(reason)}}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp deadline_passed?(state), do: remaining_ms(state.limits.deadline_ms) <= 0
  defp deadline_error(state), do: {:stream_deadline_exceeded, state.limits.timeout}
  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp producer_exit_reason({:shutdown, :stream_deadline}, limits),
    do: {:stream_deadline_exceeded, limits.timeout}

  defp producer_exit_reason(reason, _limits), do: {:stream_producer_exit, bounded_reason(reason)}

  defp flush_messages(ref, pid, monitor) do
    receive do
      {^ref, _kind} -> flush_messages(ref, pid, monitor)
      {^ref, _kind, _value} -> flush_messages(ref, pid, monitor)
      {:DOWN, ^monitor, :process, ^pid, _reason} -> flush_messages(ref, pid, monitor)
    after
      0 -> :ok
    end
  end

  defp bounded_exception(%{__struct__: module, message: message}) when is_binary(message),
    do: {module, String.slice(String.replace_invalid(message, ""), 0, 512)}

  defp bounded_exception(%{__struct__: module}), do: module
  defp bounded_exception(_exception), do: :exception

  defp bounded_reason(value) when is_binary(value),
    do: value |> String.slice(0, 512) |> String.replace_invalid("")

  defp bounded_reason(value) when is_atom(value) or is_number(value), do: value
  defp bounded_reason(_value), do: :external_error
end
