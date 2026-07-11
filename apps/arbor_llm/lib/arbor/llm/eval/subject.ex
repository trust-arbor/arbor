defmodule Arbor.LLM.Eval.Subject do
  @moduledoc """
  Evaluation subject that sends prompts through an Arbor LLM provider.

  Input can be a prompt string or a map with `"prompt"` and optional
  `"system"` keys. Atom-keyed maps are accepted for compatibility.

  A concrete `Arbor.LLM.Client` may be supplied with `:client` to select an
  explicitly configured transport for a single eval run. Without one, the
  provider adapter is selected from `Arbor.LLM.ProviderCatalog`.

  `:max_tokens` is forwarded only when the caller supplies a positive integer.
  All runs have a 16 MiB output ceiling. Streaming runs additionally have an
  absolute `:timeout` and a 100,000-event ceiling. Callers can lower the output
  and event ceilings with `:max_output_bytes` and `:max_stream_events`.
  """

  @behaviour Arbor.Eval.Subject

  require Logger

  alias Arbor.LLM.{Client, Message, ProviderCatalog, Request, StreamEvent}

  @default_provider "lm_studio"
  @default_timeout 60_000
  @max_timeout 900_000
  @max_stream_events 100_000
  @max_output_bytes 16_777_216

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
    with {:ok, provider} <- string_option(opts, :provider, @default_provider, false),
         {:ok, model} <- string_option(opts, :model, default_model(provider), true),
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

  defp string_option(opts, key, default, allow_empty?) do
    value = Keyword.get(opts, key, default)

    cond do
      not is_binary(value) ->
        {:error, {:invalid_option, key, :string_required}}

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
      nil -> {:ok, nil}
      value when is_number(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_option, :temperature, :non_negative_number_required}}
    end
  end

  defp optional_positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key, :positive_integer_required}}
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

    case complete(transport, request, receive_timeout: config.timeout) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        with {:ok, text} <- extract_text(response, config.max_output_bytes) do
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
        {:error, reason}

      other ->
        {:error, {:invalid_transport_response, other}}
    end
  rescue
    exception -> {:error, {:transport_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:transport_exception, {kind, inspect(reason)}}}
  end

  defp log_empty_response(response, provider, model, duration_ms) do
    usage = map_value(response, :usage, %{})
    content_parts = map_value(response, :content_parts, [])

    content_kinds =
      if is_list(content_parts) do
        Enum.map(content_parts, fn part -> map_value(part, :kind) end)
      else
        []
      end

    Logger.warning(
      "Eval LLM subject: empty text from #{provider}/#{model} " <>
        "after #{duration_ms}ms. " <>
        "finish_reason=#{inspect(map_value(response, :finish_reason))} " <>
        "output_tokens=#{inspect(map_value(usage, :output_tokens))} " <>
        "content_parts=#{inspect(content_kinds)}"
    )
  end

  defp run_streaming(transport, request, config) do
    start_time = System.monotonic_time(:millisecond)

    limits = %{
      timeout: config.timeout,
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
        produce_stream(parent, ref, transport, request, limits.timeout)
      end)

    state = %{
      ref: ref,
      producer_pid: producer_pid,
      monitor_ref: monitor_ref,
      deadline_ms: start_time + limits.timeout,
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

  defp produce_stream(parent, ref, transport, request, timeout) do
    case stream(transport, request, receive_timeout: timeout) do
      {:ok, events} ->
        Enum.reduce_while(events, :ok, fn event, :ok ->
          send(parent, {ref, :event, event})

          receive do
            {^ref, :continue} -> {:cont, :ok}
            {^ref, :stop} -> {:halt, :ok}
          end
        end)

        send(parent, {ref, :done})

      {:error, reason} ->
        send(parent, {ref, :stream_error, reason})
    end
  rescue
    exception ->
      send(parent, {ref, :producer_error, {:exception, Exception.message(exception)}})
  catch
    kind, reason ->
      send(parent, {ref, :producer_error, {kind, inspect(reason)}})
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
          {:error, {:stream_collection_failed, {:producer_exit, inspect(reason)}}}
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
        {:error, {:stream_error, stream_error_reason(event)}}

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
      Process.exit(state.producer_pid, :kill)
    end

    Process.demonitor(state.monitor_ref, [:flush])
    flush_stream_messages(state.ref)
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

      not String.valid?(prompt) ->
        {:error, {:invalid_input, :valid_utf8_prompt_required}}

      not (is_nil(system) or is_binary(system)) ->
        {:error, {:invalid_input, :system_must_be_string}}

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
        {:ok, ""}
    end
  end

  defp estimate_tokens(text, response) do
    usage_tokens =
      case response do
        %{usage: %{output_tokens: count}} when is_integer(count) -> count
        %{usage: %{completion_tokens: count}} when is_integer(count) -> count
        %{usage: %{"completion_tokens" => count}} when is_integer(count) -> count
        _other -> nil
      end

    usage_tokens || div(String.length(text), 4)
  end

  defp map_value(map, key, default \\ nil)
  defp map_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_value(_value, _key, default), do: default
end
