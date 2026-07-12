defmodule Arbor.LLM.OAuth.Responses do
  @moduledoc """
  The OpenAI **Responses API** wire layer (streaming SSE) against the ChatGPT/Codex + xAI/Grok
  SUBSCRIPTION backends, authenticated with a subscription OAuth token from `Arbor.LLM.OAuth`
  (which hard-refuses Anthropic). Used by `Arbor.LLM.Adapter.OAuthResponses` so an Arbor agent can
  run on a flat subscription instead of a metered API key.

  Supports **tool calling**: the caller supplies pre-built Responses `input` items + `tools`, and
  `complete/3` returns `{:ok, %{text, tool_calls}}` where each tool call is `%{id, name, arguments}`
  (arguments decoded to a map). The subscription backends REQUIRE `stream: true`; we buffer the SSE
  and read text from `response.output_text.delta` deltas and tool calls from the final
  `response.completed` event's `response.output`.
  """

  alias Arbor.LLM.{Deadline, Endpoint, OAuth, ResponseBudget}

  @max_response_bytes 16_777_216
  @max_events 100_000
  @max_event_bytes 1_048_576
  @max_work 1_600_000
  @max_nodes 100_000
  @max_depth 32
  @max_map_keys 10_000
  @max_list_items 100_000
  @max_timeout 900_000

  @endpoints %{
    openai: "https://chatgpt.com/backend-api/codex/responses",
    xai: "https://api.x.ai/v1/responses"
  }

  @default_models %{openai: "gpt-5.5", xai: "grok-4.3"}

  @doc """
  `complete(provider, %{instructions, input, tools}, opts)` → `{:ok, %{text, tool_calls}}`.

  `input` is a fully-built Responses input list, `tools` a Responses tools list (or nil). Options:
  `:model`, `:receive_timeout`. Anthropic is refused upstream by `OAuth.access_token/1`.
  """
  @spec complete(atom() | String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(provider, req, opts \\ [])

  def complete(provider, %{} = req, opts) do
    with {:ok, limits} <- build_limits(opts),
         {:ok, receipt} <- Deadline.receipt(timeout_ms: limits.timeout) do
      Deadline.run(
        fn -> do_complete(provider, req, opts, limits) end,
        receipt,
        {:responses_deadline_exceeded, limits.timeout}
      )
    end
  end

  def complete(_provider, _req, _opts), do: {:error, :invalid_responses_request}

  defp do_complete(provider, req, opts, limits) do
    with :ok <- ResponseBudget.validate(req, request_limits()),
         {:ok, key} <- provider_key(provider),
         {:ok, token} <- OAuth.access_token(provider) do
      sid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      body = build_body(Keyword.get(opts, :model) || @default_models[key], req)

      request_sse(@endpoints[key], headers(key, token, sid), body, limits)
    end
  end

  @doc false
  def request_sse(url, headers, body, opts_or_limits) do
    with {:ok, limits} <- normalize_limits(opts_or_limits),
         {:ok, receipt} <- Deadline.receipt(timeout_ms: limits.timeout),
         {:ok, canonical_url} <- Endpoint.validate(url, :oauth_responses) do
      limits = Map.put(limits, :deadline_ms, receipt.deadline_ms)

      Deadline.run(
        fn -> do_request_sse(canonical_url, headers, body, limits) end,
        receipt,
        {:responses_deadline_exceeded, limits.timeout}
      )
    end
  end

  @doc """
  Convenience for the simple text path (no tools): `messages` is `[%{role, content}]`.
  Returns `{:ok, text}`.
  """
  @spec complete_text(atom() | String.t(), [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def complete_text(provider, messages, opts \\ []) do
    with :ok <- validate_text_messages(messages) do
      instructions =
        messages |> Enum.filter(&(&1.role == :system)) |> Enum.map_join("\n\n", & &1.content)

      input =
        messages
        |> Enum.reject(&(&1.role == :system))
        |> Enum.map(fn m ->
          %{
            "role" => to_string(m.role),
            "content" => [%{"type" => "input_text", "text" => m.content}]
          }
        end)

      case complete(provider, %{instructions: instructions, input: input, tools: nil}, opts) do
        {:ok, %{text: text}} -> {:ok, text}
        err -> err
      end
    end
  end

  defp provider_key(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> provider_key()

  defp provider_key(provider)
       when is_binary(provider) and byte_size(provider) > 0 and byte_size(provider) <= 256 do
    case String.downcase(provider) do
      p when p in ~w(openai codex chatgpt gpt) -> {:ok, :openai}
      p when p in ~w(xai grok x-ai) -> {:ok, :xai}
      p -> {:error, {:no_responses_provider, p}}
    end
  end

  defp provider_key(_provider), do: {:error, :invalid_responses_provider}

  defp validate_text_messages(messages) do
    with :ok <- ResponseBudget.validate(messages, request_limits()) do
      validate_text_message_list(messages)
    end
  end

  defp validate_text_message_list([]), do: :ok

  defp validate_text_message_list([%{role: role, content: content} | rest])
       when (is_atom(role) or is_binary(role)) and is_binary(content),
       do: validate_text_message_list(rest)

  defp validate_text_message_list(_improper_or_invalid),
    do: {:error, :bounded_text_messages_required}

  defp request_limits do
    [
      max_bytes: @max_response_bytes,
      max_nodes: @max_nodes,
      max_depth: @max_depth,
      max_map_keys: @max_map_keys,
      max_list_items: @max_list_items
    ]
  end

  # store:false, stream:true (required by the subscription backends). tools only when present.
  defp build_body(model, req) do
    base = %{
      "model" => model,
      "instructions" => req[:instructions] || "",
      "input" => req[:input] || [],
      "store" => false,
      "stream" => true
    }

    case req[:tools] do
      tools when is_list(tools) and tools != [] ->
        Map.merge(base, %{
          "tools" => tools,
          "tool_choice" => "auto",
          "parallel_tool_calls" => true
        })

      _ ->
        base
    end
  end

  # Codex backend needs the Cloudflare-whitelisting headers + account-id (else 403); xAI a conv-id.
  defp headers(:openai, token, sid) do
    [
      {"authorization", "Bearer " <> token},
      {"user-agent", "codex_cli_rs/0.0.0 (Arbor)"},
      {"originator", "codex_cli_rs"},
      {"chatgpt-account-id", OAuth.account_id(:openai) || ""},
      {"session_id", sid},
      {"x-client-request-id", sid}
    ]
  end

  defp headers(:xai, token, sid) do
    [{"authorization", "Bearer " <> token}, {"x-grok-conv-id", sid}]
  end

  @doc false
  def parse_sse(raw, opts_or_limits \\ [])

  def parse_sse(raw, opts_or_limits) when is_binary(raw) do
    with {:ok, limits} <- normalize_limits(opts_or_limits),
         true <-
           byte_size(raw) <= limits.max_response_bytes or
             {:error, {:response_bytes_exceeded, limits.max_response_bytes}},
         true <- String.valid?(raw) or {:error, :valid_utf8_sse_required},
         {:ok, state} <- parse_sse_lines(raw, new_parser_state(limits)),
         {:ok, state} <- finish_sse_event(state) do
      {:ok,
       %{
         text: state.text_chunks |> Enum.reverse() |> IO.iodata_to_binary(),
         tool_calls: Enum.reverse(state.tool_calls)
       }}
    end
  end

  def parse_sse(_raw, _opts_or_limits), do: {:error, :binary_sse_required}

  defp do_request_sse(url, headers, body, limits) do
    into = bounded_sse_receipt(limits)

    case Req.post(url,
           headers: headers,
           json: body,
           receive_timeout: max(limits.deadline_ms - System.monotonic_time(:millisecond), 1),
           redirect: false,
           compressed: false,
           decode_body: false,
           into: into
         ) do
      {:ok, %Req.Response{private: %{arbor_oauth_response_error: reason}}} ->
        {:error, reason}

      {:ok, %Req.Response{status: 200} = response} ->
        with :ok <- identity_content_encoding(response),
             :ok <- event_stream_content_type(response),
             {:ok, raw} <- collected_body(response, limits.max_response_bytes),
             {:ok, parsed} <- parse_sse(raw, limits) do
          {:ok, parsed}
        end

      {:ok, %Req.Response{status: status} = response} ->
        with {:ok, raw} <- collected_body(response, limits.max_response_bytes) do
          {:error, {:responses_http, status, detail(raw)}}
        end

      {:error, reason} ->
        {:error, {:responses_request_failed, Arbor.LLM.ExternalTerm.sanitize(reason)}}
    end
  rescue
    exception ->
      {:error, {:responses_request_failed, Arbor.LLM.ExternalTerm.exception(exception)}}
  catch
    kind, reason ->
      {:error, {:responses_request_failed, {kind, Arbor.LLM.ExternalTerm.sanitize(reason)}}}
  end

  defp bounded_sse_receipt(limits) do
    fn {:data, data}, {request, response} when is_binary(data) ->
      retained = Map.get(response.private, :arbor_oauth_response_bytes, 0)

      cond do
        System.monotonic_time(:millisecond) >= limits.deadline_ms ->
          halt_receipt(request, response, {:responses_deadline_exceeded, limits.timeout})

        byte_size(data) > limits.max_response_bytes - retained ->
          halt_receipt(
            request,
            response,
            {:response_bytes_exceeded, limits.max_response_bytes}
          )

        true ->
          private =
            response.private
            |> Map.update(:arbor_oauth_response_chunks, [data], &[data | &1])
            |> Map.put(:arbor_oauth_response_bytes, retained + byte_size(data))

          {:cont, {request, %{response | body: "", private: private}}}
      end
    end
  end

  defp halt_receipt(request, response, reason) do
    private = Map.put(response.private, :arbor_oauth_response_error, reason)
    {:halt, {%{request | halted: true}, %{response | body: "", private: private}}}
  end

  defp collected_body(%Req.Response{private: %{arbor_oauth_response_chunks: chunks}}, maximum)
       when is_list(chunks) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    if byte_size(body) <= maximum,
      do: {:ok, body},
      else: {:error, {:response_bytes_exceeded, maximum}}
  end

  defp collected_body(%Req.Response{body: body}, maximum) when is_binary(body) do
    if byte_size(body) <= maximum,
      do: {:ok, body},
      else: {:error, {:response_bytes_exceeded, maximum}}
  end

  defp collected_body(_response, _maximum), do: {:error, :binary_response_body_required}

  defp new_parser_state(limits) do
    %{
      limits: limits,
      data_parts: [],
      event_bytes: 0,
      event_count: 0,
      work: 0,
      decoded_nodes: 0,
      decoded_bytes: 0,
      decoded_map_keys: 0,
      decoded_list_items: 0,
      text_chunks: [],
      text_bytes: 0,
      tool_calls: []
    }
  end

  defp parse_sse_lines("", state), do: {:ok, state}

  defp parse_sse_lines(body, state) do
    case :binary.match(body, "\n") do
      :nomatch ->
        process_sse_line(strip_cr(body), state)

      {index, 1} ->
        line = body |> binary_part(0, index) |> strip_cr()
        rest = binary_part(body, index + 1, byte_size(body) - index - 1)

        with {:ok, state} <- process_sse_line(line, state) do
          parse_sse_lines(rest, state)
        end
    end
  end

  defp process_sse_line(line, state) do
    with {:ok, state} <- add_work(state, 1) do
      cond do
        line == "" -> finish_sse_event(state)
        String.starts_with?(line, ":") -> {:ok, state}
        String.starts_with?(line, "data:") -> append_sse_data(line, state)
        String.starts_with?(line, "event:") -> {:ok, state}
        String.starts_with?(line, "id:") -> {:ok, state}
        String.starts_with?(line, "retry:") -> {:ok, state}
        true -> {:error, :invalid_sse_field}
      end
    end
  end

  defp append_sse_data("data:" <> value, state) do
    value =
      if String.starts_with?(value, " "),
        do: binary_part(value, 1, byte_size(value) - 1),
        else: value

    bytes = state.event_bytes + byte_size(value) + if(state.data_parts == [], do: 0, else: 1)

    if bytes <= state.limits.max_event_bytes do
      {:ok, %{state | data_parts: [value | state.data_parts], event_bytes: bytes}}
    else
      {:error, {:stream_limit_exceeded, :event_bytes, state.limits.max_event_bytes}}
    end
  end

  defp finish_sse_event(%{data_parts: []} = state), do: {:ok, state}

  defp finish_sse_event(state) do
    event_count = state.event_count + 1

    if event_count > state.limits.max_events do
      {:error, {:stream_limit_exceeded, :events, state.limits.max_events}}
    else
      data = state.data_parts |> Enum.reverse() |> Enum.intersperse("\n") |> IO.iodata_to_binary()
      state = %{state | data_parts: [], event_bytes: 0, event_count: event_count}

      if data == "[DONE]" do
        {:ok, state}
      else
        decode_sse_event(data, state)
      end
    end
  end

  defp decode_sse_event(data, state) do
    limits = json_limits(state.limits, state.limits.max_event_bytes)

    with {:ok, preflight} <- ResponseBudget.preflight_json(data, limits),
         {:ok, state} <- charge_measurements(state, preflight),
         {:ok, decoded, retained} <- ResponseBudget.decode_json_with_measurements(data, limits),
         {:ok, state} <- charge_measurements(state, measurement_delta(retained, preflight)),
         {:ok, state} <- retain_response_event(decoded, state) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:invalid_responses_event, reason}}
    end
  end

  defp retain_response_event(
         %{"type" => "response.output_text.delta", "delta" => delta},
         state
       )
       when is_binary(delta) do
    bytes = state.text_bytes + byte_size(delta)

    cond do
      not String.valid?(delta) ->
        {:error, :valid_utf8_delta_required}

      bytes > state.limits.max_response_bytes ->
        {:error, {:stream_limit_exceeded, :output_bytes, state.limits.max_response_bytes}}

      true ->
        {:ok, %{state | text_chunks: [delta | state.text_chunks], text_bytes: bytes}}
    end
  end

  defp retain_response_event(
         %{
           "type" => "response.output_item.done",
           "item" => %{"type" => "function_call"} = item
         },
         state
       ) do
    with {:ok, tool_call} <- tool_call_from_item(item) do
      {:ok, %{state | tool_calls: [tool_call | state.tool_calls]}}
    end
  end

  defp retain_response_event(_event, state), do: {:ok, state}

  defp tool_call_from_item(item) do
    id = item["call_id"] || item["id"]
    name = item["name"]

    with :ok <- bounded_tool_field(id, :id),
         :ok <- bounded_tool_field(name, :name),
         {:ok, arguments} <- decode_args(item["arguments"]) do
      {:ok, %{id: id, name: name, arguments: arguments}}
    end
  end

  defp bounded_tool_field(value, _field)
       when is_binary(value) and byte_size(value) in 1..512 do
    if String.valid?(value), do: :ok, else: {:error, :valid_utf8_tool_field_required}
  end

  defp bounded_tool_field(_value, field), do: {:error, {:invalid_tool_field, field}}

  defp decode_args(args) when is_binary(args) do
    case ResponseBudget.decode_json(args, tool_argument_limits()) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :tool_arguments_must_be_map}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp decode_args(map) when is_map(map) do
    case ResponseBudget.validate(map, tool_argument_limits()) do
      :ok -> {:ok, map}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp decode_args(_args), do: {:error, :tool_arguments_must_be_map_or_json}

  defp charge_measurements(state, measurements) do
    nodes = state.decoded_nodes + Map.get(measurements, :nodes, 0)
    bytes = state.decoded_bytes + Map.get(measurements, :bytes, 0)
    map_keys = state.decoded_map_keys + Map.get(measurements, :map_keys, 0)
    list_items = state.decoded_list_items + Map.get(measurements, :list_items, 0)
    work = state.work + Map.get(measurements, :nodes, 0)

    cond do
      nodes > state.limits.max_nodes ->
        {:error, {:stream_limit_exceeded, :decoded_nodes, state.limits.max_nodes}}

      bytes > state.limits.max_response_bytes ->
        {:error, {:stream_limit_exceeded, :decoded_bytes, state.limits.max_response_bytes}}

      map_keys > state.limits.max_map_keys ->
        {:error, {:stream_limit_exceeded, :decoded_map_keys, state.limits.max_map_keys}}

      list_items > state.limits.max_list_items ->
        {:error, {:stream_limit_exceeded, :decoded_list_items, state.limits.max_list_items}}

      work > state.limits.max_work ->
        {:error, {:stream_limit_exceeded, :work, state.limits.max_work}}

      true ->
        {:ok,
         %{
           state
           | decoded_nodes: nodes,
             decoded_bytes: bytes,
             decoded_map_keys: map_keys,
             decoded_list_items: list_items,
             work: work
         }}
    end
  end

  defp add_work(state, amount) do
    if state.work <= state.limits.max_work - amount,
      do: {:ok, %{state | work: state.work + amount}},
      else: {:error, {:stream_limit_exceeded, :work, state.limits.max_work}}
  end

  defp measurement_delta(retained, preflight) do
    %{
      nodes: max(Map.get(retained, :nodes, 0) - Map.get(preflight, :nodes, 0), 0),
      bytes: max(Map.get(retained, :bytes, 0) - Map.get(preflight, :bytes, 0), 0),
      map_keys: max(Map.get(retained, :map_keys, 0) - Map.get(preflight, :map_keys, 0), 0),
      list_items: max(Map.get(retained, :list_items, 0) - Map.get(preflight, :list_items, 0), 0)
    }
  end

  defp json_limits(limits, maximum) do
    [
      max_bytes: maximum,
      max_nodes: limits.max_nodes,
      max_depth: limits.max_depth,
      max_map_keys: limits.max_map_keys,
      max_list_items: limits.max_list_items
    ]
  end

  defp tool_argument_limits do
    [
      max_bytes: 1_048_576,
      max_nodes: 10_000,
      max_depth: 32,
      max_map_keys: 2_000,
      max_list_items: 10_000
    ]
  end

  defp normalize_limits(%{timeout: _timeout} = limits), do: validate_limits(limits)
  defp normalize_limits(opts) when is_list(opts), do: build_limits(opts)
  defp normalize_limits(_opts), do: {:error, :invalid_responses_limits}

  defp build_limits(opts) do
    with {:ok, supplied} <- collect_limit_options(opts, %{}, 0),
         {:ok, timeout} <-
           Deadline.select(opts, Deadline.timeout_keys(), 180_000, @max_timeout),
         {:ok, max_response_bytes} <-
           positive_clamped(
             supplied,
             :max_response_bytes,
             @max_response_bytes,
             @max_response_bytes
           ),
         {:ok, max_events} <- positive_clamped(supplied, :max_events, @max_events, @max_events),
         {:ok, max_event_bytes} <-
           positive_clamped(
             supplied,
             :max_event_bytes,
             @max_event_bytes,
             min(max_response_bytes, @max_event_bytes)
           ),
         {:ok, max_work} <- positive_clamped(supplied, :max_work, @max_work, @max_work),
         {:ok, max_nodes} <- positive_clamped(supplied, :max_nodes, @max_nodes, @max_nodes),
         {:ok, max_depth} <- positive_clamped(supplied, :max_depth, @max_depth, @max_depth),
         {:ok, max_map_keys} <-
           positive_clamped(supplied, :max_map_keys, @max_map_keys, @max_map_keys),
         {:ok, max_list_items} <-
           positive_clamped(supplied, :max_list_items, @max_list_items, @max_list_items) do
      {:ok,
       %{
         timeout: timeout,
         max_response_bytes: max_response_bytes,
         max_events: max_events,
         max_event_bytes: max_event_bytes,
         max_work: max_work,
         max_nodes: max_nodes,
         max_depth: max_depth,
         max_map_keys: max_map_keys,
         max_list_items: max_list_items
       }}
    end
  end

  defp collect_limit_options([], options, _count), do: {:ok, options}

  defp collect_limit_options(_opts, _options, count) when count >= 64,
    do: {:error, :invalid_responses_limits}

  defp collect_limit_options([{key, value} | rest], options, count) when is_atom(key),
    do: collect_limit_options(rest, Map.put(options, key, value), count + 1)

  defp collect_limit_options(_improper, _options, _count),
    do: {:error, :invalid_responses_limits}

  defp positive_clamped(options, key, default, maximum) do
    value = Map.get(options, key, default)

    if is_integer(value) and value > 0,
      do: {:ok, min(value, maximum)},
      else: {:error, :invalid_responses_limits}
  end

  defp validate_limits(
         %{
           timeout: timeout,
           max_response_bytes: max_response_bytes,
           max_events: max_events,
           max_event_bytes: max_event_bytes,
           max_work: max_work,
           max_nodes: max_nodes,
           max_depth: max_depth,
           max_map_keys: max_map_keys,
           max_list_items: max_list_items
         } = limits
       ) do
    valid? =
      is_integer(timeout) and timeout > 0 and timeout <= @max_timeout and
        is_integer(max_response_bytes) and max_response_bytes > 0 and
        max_response_bytes <= @max_response_bytes and
        is_integer(max_events) and max_events > 0 and max_events <= @max_events and
        is_integer(max_event_bytes) and max_event_bytes > 0 and
        max_event_bytes <= min(max_response_bytes, @max_event_bytes) and
        is_integer(max_work) and max_work > 0 and max_work <= @max_work and
        is_integer(max_nodes) and max_nodes > 0 and max_nodes <= @max_nodes and
        is_integer(max_depth) and max_depth > 0 and max_depth <= @max_depth and
        is_integer(max_map_keys) and max_map_keys > 0 and max_map_keys <= @max_map_keys and
        is_integer(max_list_items) and max_list_items > 0 and
        max_list_items <= @max_list_items

    if valid?, do: {:ok, limits}, else: {:error, :invalid_responses_limits}
  end

  defp validate_limits(_limits), do: {:error, :invalid_responses_limits}

  defp identity_content_encoding(response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] ->
        :ok

      values ->
        if Enum.all?(values, &(String.downcase(String.trim(&1)) in ["", "identity"])),
          do: :ok,
          else: {:error, :identity_content_encoding_required}
    end
  end

  defp event_stream_content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value] ->
        media_type =
          value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

        if media_type == "text/event-stream",
          do: :ok,
          else: {:error, :event_stream_content_type_required}

      _ ->
        {:error, :event_stream_content_type_required}
    end
  end

  defp strip_cr(line) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  defp detail(body) when is_binary(body),
    do: body |> String.replace_invalid("") |> String.slice(0, 200)

  defp detail(%{"detail" => detail}) when is_binary(detail), do: String.slice(detail, 0, 200)
  defp detail(_body), do: :unavailable
end
