defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible do
  @moduledoc """
  Shared adapter for providers exposing OpenAI-compatible Chat Completions API.

  Not a ProviderAdapter itself — used by thin provider wrappers that supply
  a config map with provider-specific details:

      %{
        provider: "openrouter",
        base_url: "https://openrouter.ai/api/v1",
        api_key_env: "OPENROUTER_API_KEY",
        chat_path: "/chat/completions",     # default
        extra_headers: fn _request -> [] end # optional
      }

  Handles the standard `/v1/chat/completions` format: messages, tool calls,
  streaming, and error mapping. Provider-specific extensions (e.g. thinking
  mode) are injected via optional hooks:

  - `parse_message` — `(message_map -> [ContentPart.t()] | nil)` for custom
    response message parsing (return nil to use default)
  - `parse_delta` — `(delta_map, raw -> StreamEvent.t() | nil)` for custom
    streaming delta parsing (return nil to use default)
  """

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.ErrorMapper
  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Message, Request, Response, StreamEvent}

  @type config :: %{
          provider: String.t(),
          base_url: String.t(),
          api_key_env: String.t() | nil,
          chat_path: String.t(),
          extra_headers: (Request.t() -> [{String.t(), String.t()}]) | nil
        }

  @default_chat_path "/chat/completions"

  @spec complete(Request.t(), keyword(), config()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request, opts, config) do
    translation_warnings = unsupported_content_warnings(request)

    with {:ok, api_key} <- fetch_api_key(opts, config),
         {:ok, response} <- call_http(build_request(request, api_key, config), opts, config) do
      case to_response(response, config) do
        {:ok, %Response{} = parsed} ->
          {:ok, %{parsed | warnings: parsed.warnings ++ translation_warnings}}

        {:error, _} = error ->
          error
      end
    end
  end

  @spec stream(Request.t(), keyword(), config()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(%Request{} = request, opts, config) do
    translation_warnings = unsupported_content_warnings(request)

    with {:ok, api_key} <- fetch_api_key(opts, config),
         {:ok, events} <-
           call_http_stream(build_stream_request(request, api_key, config), opts, config) do
      {:ok, translate_stream(events, translation_warnings, config)}
    end
  end

  # --- Request Building ---

  @spec build_request(Request.t(), String.t() | nil, config()) :: map()
  def build_request(%Request{} = request, api_key, config) do
    provider_opts = provider_options(request, config)

    body =
      %{
        "model" => request.model,
        "messages" => Enum.map(request.messages, &message_to_chat/1)
      }
      |> maybe_put("tools", build_tools(request.tools))
      |> maybe_put("tool_choice", request.tool_choice)
      |> maybe_put("max_tokens", request.max_tokens)
      |> maybe_put("temperature", request.temperature)
      |> deep_merge(provider_opts)

    url = String.trim_trailing(config.base_url, "/") <> chat_path(config)
    headers = build_headers(api_key, config, request)

    %{method: :post, url: url, headers: headers, body: body}
  end

  @spec build_stream_request(Request.t(), String.t() | nil, config()) :: map()
  def build_stream_request(%Request{} = request, api_key, config) do
    req = build_request(request, api_key, config)
    %{req | body: Map.put(req.body, "stream", true)}
  end

  defp message_to_chat(%Message{role: :tool} = msg) do
    metadata = msg.metadata || %{}
    call_id = Map.get(metadata, "tool_call_id") || Map.get(metadata, :tool_call_id) || "call"

    %{
      "role" => "tool",
      "tool_call_id" => to_string(call_id),
      "content" => encode_content(msg.content)
    }
  end

  defp message_to_chat(%Message{role: :assistant} = msg) do
    parts = ContentPart.normalize(msg.content)
    tool_calls = Enum.filter(parts, &(&1.kind == :tool_call))
    text = ContentPart.text_content(msg.content)

    base = %{"role" => "assistant"}

    base =
      if text != "" do
        Map.put(base, "content", text)
      else
        Map.put(base, "content", nil)
      end

    if tool_calls != [] do
      Map.put(base, "tool_calls", Enum.map(tool_calls, &tool_call_to_chat/1))
    else
      base
    end
  end

  defp message_to_chat(%Message{role: role} = msg) when role in [:system, :developer] do
    %{"role" => "system", "content" => ContentPart.text_content(msg.content)}
  end

  defp message_to_chat(%Message{} = msg) do
    parts = ContentPart.normalize(msg.content)

    content =
      if Enum.all?(parts, &(&1.kind == :text)) do
        ContentPart.text_content(msg.content)
      else
        Enum.map(parts, &content_part_to_chat/1)
      end

    %{"role" => to_string(msg.role), "content" => content}
  end

  defp content_part_to_chat(%{kind: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp content_part_to_chat(%{kind: :image, url: url}) when is_binary(url) and url != "" do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp content_part_to_chat(%{kind: :image, data: data, media_type: media_type})
       when is_binary(data) do
    uri = "data:#{media_type || "image/png"};base64,#{Base.encode64(data)}"
    %{"type" => "image_url", "image_url" => %{"url" => uri}}
  end

  defp content_part_to_chat(%{kind: kind} = part) do
    %{"type" => "text", "text" => "[unsupported #{kind}] #{ContentPart.text_content([part])}"}
  end

  defp tool_call_to_chat(%{kind: :tool_call, id: id, name: name, arguments: args}) do
    %{
      "id" => to_string(id),
      "type" => "function",
      "function" => %{
        "name" => to_string(name),
        "arguments" => encode_args(args)
      }
    }
  end

  defp build_tools([]), do: nil
  defp build_tools(nil), do: nil

  defp build_tools(tools) do
    Enum.map(tools, &tool_to_chat_format/1)
  end

  defp tool_to_chat_format(%{"type" => "function"} = tool), do: tool

  defp tool_to_chat_format(tool) when is_map(tool) do
    name = Map.get(tool, :name) || Map.get(tool, "name") || ""
    description = Map.get(tool, :description) || Map.get(tool, "description")

    parameters =
      Map.get(tool, :input_schema) || Map.get(tool, :parameters) ||
        Map.get(tool, "input_schema") || Map.get(tool, "parameters") || %{}

    # Ensure parameters has "type": "object" — required by OpenAI Chat Completions spec.
    # Actions with no params (schema: []) produce %{} which strict providers reject.
    parameters =
      if parameters == %{} or not Map.has_key?(parameters, "type") do
        Map.merge(%{"type" => "object", "properties" => %{}}, parameters)
      else
        parameters
      end

    function =
      %{"name" => to_string(name), "parameters" => parameters}
      |> maybe_put("description", if(description, do: to_string(description)))

    %{"type" => "function", "function" => function}
  end

  # --- Response Parsing ---

  defp to_response(%{status: status, body: body}, config)
       when status >= 200 and status < 300 do
    choice = get_first_choice(body)
    message = Map.get(choice, "message", %{})
    content_parts = parse_message_parts(message, config)

    text =
      case ContentPart.text_content(content_parts) do
        "" -> Map.get(message, "content") || ""
        value -> value
      end

    {:ok,
     %Response{
       text: to_string(text),
       finish_reason: finish_reason(choice, content_parts),
       content_parts: content_parts,
       raw: body,
       warnings: [],
       usage: usage_from_body(body)
     }}
  rescue
    e -> {:error, ErrorMapper.from_transport(config.provider, Exception.message(e))}
  end

  defp to_response(%{status: status, body: body, headers: headers}, config) do
    {:error, ErrorMapper.from_http(config.provider, status, body, headers)}
  end

  defp get_first_choice(%{"choices" => [choice | _]}), do: choice
  defp get_first_choice(_), do: %{}

  defp parse_message_parts(message, config) do
    # Let provider-specific hook parse first; fall back to generic
    case Map.get(config, :parse_message) do
      hook when is_function(hook, 1) ->
        case hook.(message) do
          parts when is_list(parts) and parts != [] -> parts
          _ -> default_parse_message(message)
        end

      _ ->
        default_parse_message(message)
    end
  end

  defp default_parse_message(%{"content" => content, "tool_calls" => tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    text_parts =
      if is_binary(content) and content != "", do: [ContentPart.text(content)], else: []

    tool_parts = Enum.map(tool_calls, &parse_tool_call/1)
    text_parts ++ tool_parts
  end

  defp default_parse_message(%{"content" => content}) when is_binary(content) do
    [ContentPart.text(content)]
  end

  defp default_parse_message(_), do: []

  defp parse_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    ContentPart.tool_call(id, name, decode_args(args))
  end

  defp parse_tool_call(%{"id" => id, "function" => %{"name" => name}}) do
    ContentPart.tool_call(id, name, %{})
  end

  defp parse_tool_call(tc) do
    ContentPart.tool_call(
      Map.get(tc, "id", "call"),
      get_in(tc, ["function", "name"]) || "unknown",
      decode_args(get_in(tc, ["function", "arguments"]) || %{})
    )
  end

  # --- Streaming ---

  defp translate_stream(events, warnings, config) do
    initial = %{warnings: warnings, tool_calls: %{}}

    Stream.transform(events, initial, fn event, acc ->
      case translate_sse_event(event, acc, config) do
        {nil, next_acc} -> {[], next_acc}
        {evts, next_acc} when is_list(evts) -> {evts, next_acc}
        {evt, next_acc} -> {[evt], next_acc}
      end
    end)
  end

  defp translate_sse_event(%{"choices" => [choice | _]} = raw, acc, config) do
    delta = Map.get(choice, "delta", %{})
    finish_reason = Map.get(choice, "finish_reason")

    # Let provider-specific hook handle the delta first
    hook_result =
      case Map.get(config, :parse_delta) do
        hook when is_function(hook, 2) -> hook.(delta, raw)
        _ -> nil
      end

    cond do
      # Provider-specific hook handled it
      hook_result != nil ->
        {hook_result, acc}

      # Text delta
      is_binary(Map.get(delta, "content")) and Map.get(delta, "content") != "" ->
        evt = %StreamEvent{
          type: :delta,
          data: %{"text" => delta["content"], "raw" => raw}
        }

        {evt, acc}

      # Tool call delta (streamed incrementally)
      is_list(Map.get(delta, "tool_calls")) ->
        {events, new_acc} = accumulate_tool_call_deltas(delta["tool_calls"], acc, raw)
        {events, new_acc}

      # Finish
      finish_reason != nil ->
        usage = usage_from_body(raw)
        reason = normalize_finish_reason(finish_reason)

        # Emit any accumulated tool calls before finish
        tool_events = flush_tool_calls(acc)

        finish_evt = %StreamEvent{
          type: :finish,
          data: %{"reason" => reason, "usage" => usage, "raw" => raw}
        }

        {tool_events ++ [finish_evt], %{acc | tool_calls: %{}}}

      true ->
        {nil, acc}
    end
  end

  # SSE start event (some providers send model info)
  defp translate_sse_event(%{"model" => _model} = raw, acc, config) do
    evt = %StreamEvent{
      type: :start,
      data: %{
        "provider" => config.provider,
        "warnings" => Map.get(acc, :warnings, []),
        "raw" => raw
      }
    }

    {evt, acc}
  end

  # Usage-only chunk (some providers send usage separately)
  defp translate_sse_event(%{"usage" => usage}, acc, _config) when is_map(usage) do
    {nil, acc}
  end

  defp translate_sse_event(_raw, acc, _config), do: {nil, acc}

  defp accumulate_tool_call_deltas(deltas, acc, _raw) do
    new_tc =
      Enum.reduce(deltas, acc.tool_calls, fn delta, tcs ->
        index = Map.get(delta, "index", 0)
        existing = Map.get(tcs, index, %{"id" => nil, "name" => "", "arguments" => ""})

        updated =
          existing
          |> maybe_update("id", get_in(delta, ["id"]))
          |> maybe_update("name", get_in(delta, ["function", "name"]))
          |> append_field("arguments", get_in(delta, ["function", "arguments"]))

        Map.put(tcs, index, updated)
      end)

    {[], %{acc | tool_calls: new_tc}}
  end

  defp flush_tool_calls(%{tool_calls: tcs}) when map_size(tcs) == 0, do: []

  defp flush_tool_calls(%{tool_calls: tcs}) do
    tcs
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, tc} ->
      %StreamEvent{
        type: :tool_call,
        data: %{
          "id" => tc["id"],
          "name" => tc["name"],
          "arguments" => tc["arguments"],
          "raw" => tc
        }
      }
    end)
  end

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  defp append_field(map, _key, nil), do: map
  defp append_field(map, key, value), do: Map.update(map, key, value, &(&1 <> value))

  # --- HTTP ---

  defp call_http(req, opts, config) do
    case Keyword.get(opts, :http_client) do
      http_client when is_function(http_client, 1) ->
        case http_client.(req) do
          {:ok, response} -> {:ok, normalize_response(response)}
          {:error, reason} -> {:error, ErrorMapper.from_transport(config.provider, reason)}
        end

      _ ->
        default_http_call(req, config)
    end
  end

  defp call_http_stream(req, opts, config) do
    case Keyword.get(opts, :stream_client) do
      stream_client when is_function(stream_client, 1) ->
        case stream_client.(req) do
          {:ok, enumerable} -> {:ok, enumerable}
          {:error, reason} -> {:error, ErrorMapper.from_transport(config.provider, reason)}
        end

      _ ->
        default_stream_call(req, config)
    end
  end

  defp default_http_call(req, config) do
    timeout = Map.get(config, :receive_timeout, 60_000)

    Req.post(req.url,
      headers: req.headers,
      json: req.body,
      receive_timeout: timeout
    )
    |> case do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok,
         normalize_response(%{status: status, body: body, headers: flatten_headers(headers)})}

      {:error, reason} ->
        {:error, ErrorMapper.from_transport(config.provider, reason)}
    end
  end

  defp default_stream_call(req, config) do
    # For streaming, use Req's async response which implements Enumerable
    case Req.post(req.url,
           headers: req.headers,
           json: req.body,
           into: :self,
           receive_timeout: 120_000
         ) do
      {:ok, resp} ->
        stream =
          resp.body
          |> Stream.flat_map(fn chunk ->
            chunk
            |> String.split("\n")
            |> Enum.filter(&String.starts_with?(&1, "data: "))
            |> Enum.flat_map(&parse_sse_line/1)
          end)

        {:ok, stream}

      {:error, reason} ->
        {:error, ErrorMapper.from_transport(config.provider, reason)}
    end
  end

  defp parse_sse_line(line) do
    payload = String.trim_leading(line, "data: ")

    if payload == "[DONE]" do
      []
    else
      case Jason.decode(payload) do
        {:ok, parsed} -> [parsed]
        _ -> []
      end
    end
  end

  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {k, vs} -> Enum.map(List.wrap(vs), &{k, &1}) end)
  end

  defp flatten_headers(headers) when is_list(headers), do: headers

  defp normalize_response(%{status: status} = response) do
    %{
      status: status,
      body: Map.get(response, :body, %{}),
      headers: Map.get(response, :headers, [])
    }
  end

  # --- Auth ---

  defp fetch_api_key(_opts, %{api_key_env: nil}), do: {:ok, nil}

  defp fetch_api_key(opts, config) do
    key = Keyword.get(opts, :api_key) || System.get_env(config.api_key_env || "")

    if is_binary(key) and key != "" do
      {:ok, key}
    else
      {:error,
       ErrorMapper.from_http(
         config.provider,
         401,
         %{
           "error" => %{
             "message" => "missing api key (#{config.api_key_env})",
             "code" => "auth_missing"
           }
         },
         []
       )}
    end
  end

  defp build_headers(nil, config, request) do
    base = [{"content-type", "application/json"}]
    base ++ extra_headers(config, request)
  end

  defp build_headers(api_key, config, request) do
    base = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    base ++ extra_headers(config, request)
  end

  defp extra_headers(%{extra_headers: fun}, request) when is_function(fun, 1), do: fun.(request)
  defp extra_headers(_, _), do: []

  defp chat_path(%{chat_path: path}) when is_binary(path), do: path
  defp chat_path(_), do: @default_chat_path

  # --- Shared Helpers ---

  defp usage_from_body(body) when is_map(body) do
    usage = Map.get(body, "usage", %{})
    prompt_tokens = int_or_nil(Map.get(usage, "prompt_tokens"))
    completion_tokens = int_or_nil(Map.get(usage, "completion_tokens"))
    total_tokens = int_or_nil(Map.get(usage, "total_tokens"))

    %{
      input_tokens: prompt_tokens,
      output_tokens: completion_tokens,
      total_tokens: total_tokens || sum_tokens(prompt_tokens, completion_tokens),
      reasoning_tokens:
        int_or_nil(get_in(usage, ["completion_tokens_details", "reasoning_tokens"])),
      cache_read_tokens: int_or_nil(get_in(usage, ["prompt_tokens_details", "cached_tokens"])),
      cache_write_tokens: nil,
      # OpenRouter returns cost inside the usage object
      cost: float_or_nil(Map.get(usage, "cost")),
      raw: usage
    }
  end

  defp usage_from_body(_), do: %{}

  defp sum_tokens(a, b) when is_integer(a) and is_integer(b), do: a + b
  defp sum_tokens(_, _), do: nil

  defp finish_reason(choice, content_parts) do
    raw_reason =
      choice
      |> Map.get("finish_reason")
      |> normalize_finish_reason()

    cond do
      raw_reason in [:stop, :length, :tool_calls, :content_filter, :error] -> raw_reason
      Enum.any?(content_parts, &(&1.kind == :tool_call)) -> :tool_calls
      true -> :stop
    end
  end

  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("length"), do: :length
  defp normalize_finish_reason("tool_calls"), do: :tool_calls
  defp normalize_finish_reason("content_filter"), do: :content_filter
  defp normalize_finish_reason("error"), do: :error
  defp normalize_finish_reason(_), do: :other

  defp encode_args(args) when is_binary(args), do: args
  defp encode_args(args) when is_map(args), do: Jason.encode!(args)
  defp encode_args(other), do: inspect(other)

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> args
    end
  end

  defp decode_args(other), do: other

  defp encode_content(content) when is_binary(content), do: content

  defp encode_content(content) when is_list(content) do
    ContentPart.text_content(content)
  end

  defp encode_content(content) when is_map(content), do: Jason.encode!(content)
  defp encode_content(other), do: inspect(other)

  defp provider_options(%Request{provider_options: options}, config) when is_map(options) do
    provider_key = config.provider

    Map.get(options, provider_key) || Map.get(options, String.to_existing_atom(provider_key)) ||
      %{}
  rescue
    ArgumentError -> %{}
  end

  defp provider_options(_, _), do: %{}

  defp unsupported_content_warnings(%Request{messages: messages}) do
    supported = MapSet.new([:text, :image, :tool_call, :tool_result])

    messages
    |> Enum.flat_map(fn msg ->
      msg.content
      |> ContentPart.normalize()
      |> Enum.map(& &1.kind)
      |> Enum.reject(&MapSet.member?(supported, &1))
    end)
    |> Enum.uniq()
    |> Enum.map(&"Unsupported content kind downgraded to text marker: #{&1}")
  end

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_), do: nil

  defp float_or_nil(value) when is_float(value), do: value
  defp float_or_nil(value) when is_integer(value), do: value / 1
  defp float_or_nil(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right
end
