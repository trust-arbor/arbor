defmodule Arbor.LLM.Eval.Subject do
  @moduledoc """
  Evaluation subject that sends prompts through an Arbor LLM provider.

  Input can be a prompt string or a map with `"prompt"` and optional
  `"system"` keys. Atom-keyed maps are accepted for compatibility.

  A concrete `Arbor.LLM.Client` may be supplied with `:client` to select an
  explicitly configured transport for a single eval run. Without one, the
  provider adapter is selected from `Arbor.LLM.ProviderCatalog`.

  `:max_tokens` is forwarded only when the caller supplies a positive signed
  64-bit protocol integer; it remains unset by default.
  All runs have a 16 MiB output ceiling. Streaming runs additionally have an
  absolute `:timeout` and a 100,000-event ceiling. Callers can lower the output
  and event ceilings with `:max_output_bytes` and `:max_stream_events`.
  """

  @behaviour Arbor.Eval.Subject

  require Logger

  alias Arbor.LLM.{Client, Message, ProviderCatalog, Request, ResponseBudget, StreamEvent}

  @default_provider "lm_studio"
  @default_timeout 60_000
  @max_timeout 900_000
  @max_stream_events 100_000
  @max_output_bytes 16_777_216
  @max_provider_bytes 256
  @max_model_bytes 512
  @max_prompt_bytes 1_048_576
  @max_system_bytes 1_048_576
  @max_protocol_integer 9_223_372_036_854_775_807
  @max_temperature 1.0e6
  @max_diagnostic_bytes 512
  @max_diagnostic_items 16
  @max_diagnostic_depth 4
  @max_logged_content_parts 32
  @max_response_nodes 100_000
  @max_response_depth 32
  @max_response_map_keys 10_000
  @max_response_list_items 100_000
  @max_stream_event_bytes 1_048_576
  @producer_cleanup_grace_ms 10
  @producer_cleanup_kill_wait_ms 250

  @impl true
  def run(input, opts \\ []) do
    with :ok <- validate_opts(opts),
         {:ok, {prompt, system}} <- parse_input(input),
         {:ok, config} <- parse_options(opts),
         {:ok, transport} <- resolve_transport(config.provider, opts) do
      request = %Request{
        provider: config.provider,
        model: config.model,
        messages: build_messages(prompt, system),
        max_tokens: config.max_tokens,
        temperature: config.temperature,
        provider_options: build_provider_options(config.provider)
      }

      if config.stream? do
        run_streaming(transport, request, config)
      else
        run_complete(transport, request, config)
      end
    end
  end

  defp validate_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_options, :keyword_required}}
  end

  defp validate_opts(_opts), do: {:error, {:invalid_options, :keyword_required}}

  defp parse_options(opts) do
    with {:ok, provider} <-
           string_option(opts, :provider, @default_provider, false, @max_provider_bytes),
         {:ok, model} <-
           string_option(opts, :model, default_model(provider), true, @max_model_bytes),
         {:ok, temperature} <- temperature_option(opts),
         {:ok, max_tokens} <- optional_positive_integer(opts, :max_tokens),
         {:ok, timeout} <-
           bounded_positive_integer(opts, :timeout, @default_timeout, @max_timeout),
         {:ok, stream?} <- boolean_option(opts, :stream, false),
         {:ok, max_stream_events} <-
           bounded_positive_integer(
             opts,
             :max_stream_events,
             @max_stream_events,
             @max_stream_events
           ),
         {:ok, max_output_bytes} <-
           bounded_positive_integer(
             opts,
             :max_output_bytes,
             @max_output_bytes,
             @max_output_bytes
           ) do
      {:ok,
       %{
         provider: provider,
         model: model,
         temperature: temperature,
         max_tokens: max_tokens,
         timeout: timeout,
         stream?: stream?,
         max_stream_events: max_stream_events,
         max_output_bytes: max_output_bytes
       }}
    end
  end

  defp string_option(opts, key, default, allow_empty?, maximum) do
    value = Keyword.get(opts, key, default)

    cond do
      not is_binary(value) ->
        {:error, {:invalid_option, key, :string_required}}

      byte_size(value) > maximum ->
        {:error, {:invalid_option, key, {:byte_size_exceeded, maximum}}}

      not String.valid?(value) ->
        {:error, {:invalid_option, key, :valid_utf8_required}}

      value == "" and not allow_empty? ->
        {:error, {:invalid_option, key, :non_empty_string_required}}

      true ->
        {:ok, value}
    end
  end

  defp temperature_option(opts) do
    case Keyword.get(opts, :temperature) do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value >= 0 and value <= @max_temperature ->
        {:ok, value}

      value when is_float(value) and value >= 0.0 and value <= @max_temperature ->
        {:ok, value}

      _value ->
        {:error,
         {:invalid_option, :temperature, {:finite_number_range_required, 0, @max_temperature}}}
    end
  end

  defp optional_positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, nil}

      {:ok, value}
      when is_integer(value) and value > 0 and value <= @max_protocol_integer ->
        {:ok, value}

      {:ok, value} when is_integer(value) and value > @max_protocol_integer ->
        {:error, {:invalid_option, key, {:integer_range_required, 1, @max_protocol_integer}}}

      {:ok, _value} ->
        {:error, {:invalid_option, key, :positive_integer_required}}
    end
  end

  defp bounded_positive_integer(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= maximum ->
        {:ok, value}

      _value ->
        {:error, {:invalid_option, key, {:integer_range_required, 1, maximum}}}
    end
  end

  defp boolean_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, {:invalid_option, key, :boolean_required}}
    end
  end

  defp resolve_transport(provider, opts) do
    case Keyword.get(opts, :client) do
      nil -> resolve_catalog_transport(provider)
      %Client{} = client -> {:ok, {:client, client}}
      _other -> {:error, "invalid client: expected an Arbor.LLM.Client struct"}
    end
  end

  defp resolve_catalog_transport(provider) do
    case Enum.find(ProviderCatalog.all(), &(&1.provider == provider)) do
      %{adapter_module: adapter} ->
        {:ok, {:adapter, adapter}}

      nil ->
        available = ProviderCatalog.available() |> Enum.map(fn {name, _capabilities} -> name end)
        {:error, "unknown provider: #{provider}. Available: #{inspect(available)}"}
    end
  end

  defp run_complete(transport, request, config) do
    start_time = System.monotonic_time(:millisecond)
    deadline_ms = start_time + config.timeout

    result =
      run_owned_deadline(
        fn ->
          complete(transport, request,
            receive_timeout: max(deadline_ms - System.monotonic_time(:millisecond), 1),
            max_response_bytes: config.max_output_bytes
          )
        end,
        deadline_ms,
        {:request_deadline_exceeded, config.timeout}
      )

    case result do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        with :ok <- validate_response_term(response, @max_output_bytes),
             {:ok, text} <- extract_text(response, config.max_output_bytes) do
          if text == "" do
            log_empty_response(response, config.provider, config.model, duration_ms)
          end

          {:ok,
           %{
             text: text,
             duration_ms: duration_ms,
             ttft_ms: nil,
             tokens_generated: estimate_tokens(text, response),
             model: config.model,
             provider: config.provider
           }}
        end

      {:error, reason} ->
        {:error, bounded_external_reason(reason)}

      other ->
        {:error, {:invalid_transport_response, bounded_external_reason(other)}}
    end
  rescue
    exception -> {:error, {:transport_exception, exception_diagnostic(exception)}}
  catch
    kind, reason -> {:error, {:transport_exception, {kind, bounded_external_reason(reason)}}}
  end

  defp log_empty_response(response, provider, model, duration_ms) do
    usage = map_value(response, :usage, %{})
    content_parts = map_value(response, :content_parts, [])

    content_kinds = bounded_content_kinds(content_parts, @max_logged_content_parts, [])

    Logger.warning(
      "Eval LLM subject: empty text from #{provider}/#{model} " <>
        "after #{duration_ms}ms. " <>
        "finish_reason=#{inspect(bounded_external_reason(map_value(response, :finish_reason)))} " <>
        "output_tokens=#{inspect(bounded_external_reason(map_value(usage, :output_tokens)))} " <>
        "content_parts=#{inspect(content_kinds)}"
    )
  end

  defp run_streaming(transport, request, config) do
    start_time = System.monotonic_time(:millisecond)

    limits = %{
      timeout: config.timeout,
      deadline_ms: start_time + config.timeout,
      max_stream_events: config.max_stream_events,
      max_output_bytes: config.max_output_bytes
    }

    case collect_stream(transport, request, start_time, limits) do
      {:ok, text, ttft_ms} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        {:ok,
         %{
           text: text,
           duration_ms: duration_ms,
           ttft_ms: ttft_ms,
           tokens_generated: estimate_tokens(text, nil),
           model: config.model,
           provider: config.provider
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp collect_stream(transport, request, start_time, limits) do
    ref = make_ref()
    parent = self()
    callers = Process.get(:"$callers", [])

    {producer_pid, monitor_ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent | List.wrap(callers)])
        watch_stream_owner(parent, self())

        produce_stream(
          parent,
          ref,
          transport,
          request,
          limits,
          @max_stream_event_bytes
        )
      end)

    state = %{
      ref: ref,
      producer_pid: producer_pid,
      monitor_ref: monitor_ref,
      deadline_ms: limits.deadline_ms,
      timeout: limits.timeout,
      max_stream_events: limits.max_stream_events,
      max_output_bytes: limits.max_output_bytes,
      event_count: 0,
      output_bytes: 0,
      chunks: [],
      ttft_ms: nil,
      start_time: start_time
    }

    result = await_stream(state)
    stop_stream_producer(state)
    result
  end

  defp watch_stream_owner(owner, producer) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      producer_ref = Process.monitor(producer)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(producer, :kill)
        {:DOWN, ^producer_ref, :process, ^producer, _reason} -> :ok
      end
    end)
  end

  defp produce_stream(parent, ref, transport, request, limits, max_event_bytes) do
    case stream(transport, request,
           receive_timeout: max(limits.deadline_ms - System.monotonic_time(:millisecond), 1),
           max_response_bytes: limits.max_output_bytes,
           max_stream_events: limits.max_stream_events,
           max_stream_event_bytes: min(max_event_bytes, limits.max_output_bytes)
         ) do
      {:ok, events} ->
        Enum.reduce_while(events, :ok, fn event, :ok ->
          case validate_stream_event_term(event, max_event_bytes) do
            :ok ->
              send(parent, {ref, :event, event})

              receive do
                {^ref, :continue} -> {:cont, :ok}
                {^ref, :stop} -> {:halt, :ok}
              end

            {:error, reason} ->
              send(parent, {ref, :producer_error, reason})
              {:halt, :error}
          end
        end)

        send(parent, {ref, :done})

      {:error, reason} ->
        send(parent, {ref, :stream_error, bounded_external_reason(reason)})
    end
  rescue
    exception ->
      send(parent, {ref, :producer_error, exception_diagnostic(exception)})
  catch
    kind, reason ->
      send(parent, {ref, :producer_error, {kind, bounded_external_reason(reason)}})
  end

  defp await_stream(state) do
    remaining_ms = state.deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, {:stream_deadline_exceeded, state.timeout}}
    else
      receive do
        {ref, :event, event} when ref == state.ref ->
          handle_stream_event(event, state)

        {ref, :done} when ref == state.ref ->
          finalize_stream(state)

        {ref, :stream_error, reason} when ref == state.ref ->
          {:error, reason}

        {ref, :producer_error, reason} when ref == state.ref ->
          {:error, {:stream_collection_failed, reason}}

        {:DOWN, monitor_ref, :process, producer_pid, :normal}
        when monitor_ref == state.monitor_ref and producer_pid == state.producer_pid ->
          finalize_stream(state)

        {:DOWN, monitor_ref, :process, producer_pid, reason}
        when monitor_ref == state.monitor_ref and producer_pid == state.producer_pid ->
          {:error, {:stream_collection_failed, {:producer_exit, bounded_external_reason(reason)}}}
      after
        remaining_ms -> {:error, {:stream_deadline_exceeded, state.timeout}}
      end
    end
  end

  defp handle_stream_event(event, state) do
    event_count = state.event_count + 1

    cond do
      event_count > state.max_stream_events ->
        {:error, {:stream_limit_exceeded, :events, state.max_stream_events}}

      error_event?(event) ->
        {:error, {:stream_error, bounded_external_reason(stream_error_reason(event))}}

      terminal_event?(event) ->
        finalize_stream(%{state | event_count: event_count})

      true ->
        append_stream_chunk(event, %{state | event_count: event_count})
    end
  end

  defp append_stream_chunk(event, state) do
    case stream_text(event) do
      {:ok, ""} ->
        send(state.producer_pid, {state.ref, :continue})
        await_stream(state)

      {:ok, chunk} ->
        chunk_bytes = byte_size(chunk)

        if chunk_bytes > state.max_output_bytes - state.output_bytes do
          {:error, {:stream_limit_exceeded, :output_bytes, state.max_output_bytes}}
        else
          append_valid_stream_chunk(chunk, chunk_bytes, state)
        end

      {:error, reason} ->
        {:error, {:invalid_stream_event, reason}}
    end
  end

  defp append_valid_stream_chunk(chunk, chunk_bytes, state) do
    if String.valid?(chunk) do
      ttft_ms = state.ttft_ms || System.monotonic_time(:millisecond) - state.start_time

      send(state.producer_pid, {state.ref, :continue})

      await_stream(%{
        state
        | output_bytes: state.output_bytes + chunk_bytes,
          chunks: [chunk | state.chunks],
          ttft_ms: ttft_ms
      })
    else
      {:error, {:invalid_stream_event, :valid_utf8_text_required}}
    end
  end

  defp finalize_stream(state) do
    {:ok, state.chunks |> Enum.reverse() |> IO.iodata_to_binary(), state.ttft_ms}
  end

  defp stop_stream_producer(state) do
    send(state.producer_pid, {state.ref, :stop})

    if Process.alive?(state.producer_pid) do
      receive do
        {:DOWN, monitor_ref, :process, producer_pid, _reason}
        when monitor_ref == state.monitor_ref and producer_pid == state.producer_pid ->
          :ok
      after
        @producer_cleanup_grace_ms ->
          if Process.alive?(state.producer_pid), do: Process.exit(state.producer_pid, :kill)

          receive do
            {:DOWN, monitor_ref, :process, producer_pid, _reason}
            when monitor_ref == state.monitor_ref and producer_pid == state.producer_pid ->
              :ok
          after
            @producer_cleanup_kill_wait_ms -> :ok
          end
      end
    end

    Process.demonitor(state.monitor_ref, [:flush])
    flush_stream_messages(state.ref)
  end

  defp run_owned_deadline(fun, deadline_ms, timeout_error) when is_function(fun, 0) do
    reply_alias = :erlang.alias()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            exception -> {:error, {:transport_exception, exception_diagnostic(exception)}}
          catch
            kind, reason ->
              {:error, {:transport_exception, {kind, bounded_external_reason(reason)}}}
          end

        send(reply_alias, {reply_alias, result})
      end)

    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^reply_alias, {:ok, result}} ->
        :erlang.unalias(reply_alias)
        Process.demonitor(monitor_ref, [:flush])
        result

      {^reply_alias, {:error, reason}} ->
        :erlang.unalias(reply_alias)
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        :erlang.unalias(reply_alias)
        {:error, {:transport_exception, {:producer_exit, bounded_external_reason(reason)}}}
    after
      remaining_ms ->
        :erlang.unalias(reply_alias)
        Process.exit(pid, :kill)
        await_owned_down(pid, monitor_ref)
        {:error, timeout_error}
    end
  end

  defp await_owned_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      @producer_cleanup_kill_wait_ms -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp flush_stream_messages(ref) do
    receive do
      {^ref, _kind} -> flush_stream_messages(ref)
      {^ref, _kind, _value} -> flush_stream_messages(ref)
    after
      0 -> :ok
    end
  end

  defp error_event?(event), do: event_type(event) in [:error, "error"]

  defp terminal_event?(event) do
    event_type(event) in [
      :finish,
      :done,
      :stop,
      :step_finish,
      "finish",
      "done",
      "stop",
      "step_finish"
    ]
  end

  defp event_type(%StreamEvent{type: type}), do: type
  defp event_type(%{type: type}), do: type
  defp event_type(%{"type" => type}), do: type
  defp event_type(_event), do: nil

  defp stream_error_reason(%StreamEvent{data: data}), do: reason_from_data(data)
  defp stream_error_reason(%{data: data}), do: reason_from_data(data)
  defp stream_error_reason(%{"data" => data}), do: reason_from_data(data)
  defp stream_error_reason(event), do: event

  defp reason_from_data(data) when is_map(data) do
    Map.get(data, :reason, Map.get(data, "reason", data))
  end

  defp reason_from_data(data), do: data

  defp stream_text(%StreamEvent{type: :delta, data: data}), do: delta_text(data)
  defp stream_text(%{delta: %{text: text}}), do: stream_binary(text)
  defp stream_text(%{delta: text}), do: stream_binary(text)
  defp stream_text(%{text: text}), do: stream_binary(text)
  defp stream_text(text) when is_binary(text), do: {:ok, text}
  defp stream_text(_event), do: {:ok, ""}

  defp delta_text(%{"text" => text}), do: stream_binary(text)
  defp delta_text(%{text: text}), do: stream_binary(text)
  defp delta_text(_data), do: {:ok, ""}

  defp stream_binary(text) when is_binary(text), do: {:ok, text}
  defp stream_binary(_text), do: {:error, :binary_text_required}

  defp complete({:client, client}, request, opts), do: Client.complete(client, request, opts)
  defp complete({:adapter, adapter}, request, opts), do: adapter.complete(request, opts)

  defp stream({:client, client}, request, opts), do: Client.stream(client, request, opts)

  defp stream({:adapter, adapter}, request, opts) do
    case adapter.stream(request, opts) do
      {:ok, _events} = result -> result
      {:error, _reason} = error -> error
      events -> {:ok, events}
    end
  end

  defp build_messages(prompt, nil), do: [%Message{role: :user, content: prompt}]

  defp build_messages(prompt, system) do
    [
      %Message{role: :system, content: system},
      %Message{role: :user, content: prompt}
    ]
  end

  defp parse_input(%{"prompt" => prompt} = input),
    do: validate_input(prompt, Map.get(input, "system"))

  defp parse_input(%{prompt: prompt} = input), do: validate_input(prompt, Map.get(input, :system))
  defp parse_input(prompt) when is_binary(prompt), do: validate_input(prompt, nil)
  defp parse_input(_input), do: {:error, {:invalid_input, :prompt_required}}

  defp validate_input(prompt, system) do
    cond do
      not is_binary(prompt) ->
        {:error, {:invalid_input, :prompt_required}}

      byte_size(prompt) > @max_prompt_bytes ->
        {:error, {:invalid_input, {:prompt_bytes_exceeded, @max_prompt_bytes}}}

      not String.valid?(prompt) ->
        {:error, {:invalid_input, :valid_utf8_prompt_required}}

      not (is_nil(system) or is_binary(system)) ->
        {:error, {:invalid_input, :system_must_be_string}}

      is_binary(system) and byte_size(system) > @max_system_bytes ->
        {:error, {:invalid_input, {:system_bytes_exceeded, @max_system_bytes}}}

      is_binary(system) and not String.valid?(system) ->
        {:error, {:invalid_input, :valid_utf8_system_required}}

      true ->
        {:ok, {prompt, system}}
    end
  end

  defp build_provider_options(_provider), do: %{}

  defp default_model(_provider), do: ""

  defp extract_text(response, max_output_bytes) do
    response
    |> response_text()
    |> validate_complete_text(max_output_bytes)
  end

  defp response_text(%{text: text}) when is_binary(text), do: text

  defp response_text(%{message: %{content: content}}) when is_binary(content), do: content

  defp response_text(%{"text" => text}) when is_binary(text), do: text
  defp response_text(text) when is_binary(text), do: text
  defp response_text(_response), do: ""

  defp validate_complete_text(text, max_output_bytes) do
    cond do
      byte_size(text) > max_output_bytes ->
        {:error, {:output_limit_exceeded, :output_bytes, max_output_bytes}}

      String.valid?(text) ->
        {:ok, text}

      true ->
        {:error, {:invalid_output, :valid_utf8_required}}
    end
  end

  defp validate_response_term(response, maximum) do
    ResponseBudget.validate(response,
      max_bytes: maximum,
      max_nodes: @max_response_nodes,
      max_depth: @max_response_depth,
      max_map_keys: @max_response_map_keys,
      max_list_items: @max_response_list_items
    )
  end

  defp validate_stream_event_term(event, maximum) do
    case ResponseBudget.validate(event,
           max_bytes: maximum,
           max_nodes: @max_response_nodes,
           max_depth: @max_response_depth,
           max_map_keys: @max_response_map_keys,
           max_list_items: @max_response_list_items
         ) do
      {:error, {:decoded_term_limit_exceeded, :bytes, ^maximum}} ->
        {:error, {:stream_limit_exceeded, :event_bytes, maximum}}

      {:error, reason} ->
        {:error, {:invalid_stream_event, reason}}

      :ok ->
        :ok
    end
  end

  defp estimate_tokens(text, response) do
    usage_tokens =
      case response do
        %{usage: %{output_tokens: count}} when count in 0..@max_protocol_integer -> count
        %{usage: %{completion_tokens: count}} when count in 0..@max_protocol_integer -> count
        %{usage: %{"completion_tokens" => count}} when count in 0..@max_protocol_integer -> count
        _other -> nil
      end

    usage_tokens || div(String.length(text), 4)
  end

  defp map_value(map, key, default \\ nil)
  defp map_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_value(_value, _key, default), do: default

  defp bounded_content_kinds(_parts, 0, acc), do: Enum.reverse([:truncated | acc])
  defp bounded_content_kinds([], _remaining, acc), do: Enum.reverse(acc)

  defp bounded_content_kinds([part | rest], remaining, acc) do
    kind = part |> map_value(:kind) |> bounded_external_reason()
    bounded_content_kinds(rest, remaining - 1, [kind | acc])
  end

  defp bounded_content_kinds(_parts, _remaining, acc), do: Enum.reverse([:invalid_tail | acc])

  defp bounded_external_reason(value),
    do: bound_term(value, @max_diagnostic_depth)

  defp bound_term(_value, 0), do: :max_depth

  defp bound_term(value, _depth) when is_atom(value) or is_boolean(value) or is_nil(value),
    do: value

  defp bound_term(value, _depth) when is_integer(value) do
    if value >= -@max_protocol_integer - 1 and value <= @max_protocol_integer,
      do: value,
      else: :integer_out_of_range
  end

  defp bound_term(value, _depth) when is_float(value) do
    if ResponseBudget.finite_number?(value),
      do: value,
      else: :float_out_of_range
  end

  defp bound_term(value, _depth) when is_binary(value) do
    if byte_size(value) <= @max_diagnostic_bytes do
      String.replace_invalid(value, "")
    else
      {:truncated_binary, bounded_utf8_prefix(value, @max_diagnostic_bytes), byte_size(value)}
    end
  end

  defp bound_term(value, depth) when is_tuple(value) do
    count = min(tuple_size(value), @max_diagnostic_items)

    items =
      if count == 0 do
        []
      else
        Enum.map(0..(count - 1), &bound_term(elem(value, &1), depth - 1))
      end

    items = if tuple_size(value) > count, do: items ++ [:truncated], else: items
    List.to_tuple(items)
  end

  defp bound_term(value, depth) when is_list(value),
    do: bound_list(value, depth - 1, @max_diagnostic_items, [])

  defp bound_term(value, depth) when is_map(value),
    do: bound_map(:maps.iterator(value), depth - 1, @max_diagnostic_items, %{})

  defp bound_term(value, _depth) when is_pid(value), do: :pid
  defp bound_term(value, _depth) when is_reference(value), do: :reference
  defp bound_term(value, _depth) when is_function(value), do: :function
  defp bound_term(value, _depth) when is_port(value), do: :port
  defp bound_term(_value, _depth), do: :external_term

  defp bound_list([], _depth, _remaining, acc), do: Enum.reverse(acc)
  defp bound_list(_list, _depth, 0, acc), do: Enum.reverse([:truncated | acc])

  defp bound_list([head | tail], depth, remaining, acc),
    do: bound_list(tail, depth, remaining - 1, [bound_term(head, depth) | acc])

  defp bound_list(_tail, _depth, _remaining, acc), do: Enum.reverse([:improper_tail | acc])

  defp bound_map(iterator, depth, remaining, acc) do
    case :maps.next(iterator) do
      :none ->
        acc

      {_key, _value, _next} when remaining == 0 ->
        Map.put(acc, :__truncated__, true)

      {key, value, next} ->
        bounded_key = bound_term(key, depth)

        bound_map(
          next,
          depth,
          remaining - 1,
          Map.put(acc, bounded_key, bound_term(value, depth))
        )
    end
  end

  defp exception_diagnostic(%{__struct__: _module, message: message}) when is_binary(message),
    do: {:exception, bound_term(message, 1)}

  defp exception_diagnostic(%{__struct__: module}), do: {:exception, module}
  defp exception_diagnostic(_exception), do: :exception

  defp bounded_utf8_prefix(value, maximum) do
    value
    |> binary_part(0, min(byte_size(value), maximum))
    |> String.replace_invalid("")
  end
end
