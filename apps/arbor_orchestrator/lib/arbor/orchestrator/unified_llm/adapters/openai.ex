defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAI do
  @moduledoc false

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.ErrorMapper
  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Message, Request, Response}

  @endpoint "https://api.openai.com/v1/responses"

  @impl true
  def provider, do: "openai"

  @impl true
  def complete(%Request{} = request, opts) do
    translation_warnings = unsupported_content_warnings(request)

    with {:ok, api_key} <- fetch_api_key(opts),
         {:ok, response} <- call_http(build_request(request, api_key, opts), opts) do
      case to_response(response) do
        {:ok, %Response{} = parsed} ->
          {:ok, %{parsed | warnings: parsed.warnings ++ translation_warnings}}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def stream(%Request{} = request, opts) do
    translation_warnings = unsupported_content_warnings(request)

    with {:ok, api_key} <- fetch_api_key(opts),
         {:ok, events} <- call_http_stream(build_stream_request(request, api_key, opts), opts) do
      {:ok, translate_stream(events, translation_warnings)}
    end
  end

  @spec build_request(Request.t(), String.t(), keyword()) :: map()
  def build_request(%Request{} = request, api_key, _opts) do
    provider_options = provider_options(request)
    {instructions, non_system_messages} = split_system_messages(request.messages)

    base_body =
      %{
        "model" => request.model,
        "instructions" => instructions,
        "input" => Enum.map(non_system_messages, &message_to_input/1),
        "tools" => request.tools,
        "tool_choice" => request.tool_choice,
        "reasoning" => reasoning_body(request)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    %{
      method: :post,
      url: @endpoint,
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ],
      body: deep_merge(base_body, provider_options)
    }
  end

  @spec build_stream_request(Request.t(), String.t(), keyword()) :: map()
  def build_stream_request(%Request{} = request, api_key, opts) do
    req = build_request(request, api_key, opts)
    %{req | body: Map.put(req.body, "stream", true)}
  end

  defp message_to_input(%Message{role: :tool} = msg) do
    metadata = msg.metadata || %{}
    call_id = Map.get(metadata, "tool_call_id") || Map.get(metadata, :tool_call_id) || "call"
    parsed = decode_tool_message_content(msg.content)
    is_error = tool_payload_error?(parsed)

    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "function_call_output",
          "call_id" => to_string(call_id),
          "output" => encode_content(parsed),
          "is_error" => is_error
        }
      ]
    }
  end

  defp message_to_input(%Message{} = msg) do
    %{
      "role" => to_string(msg.role),
      "content" => Enum.map(ContentPart.normalize(msg.content), &to_input_part/1)
    }
  end

  defp split_system_messages(messages) do
    {system, rest} = Enum.split_with(messages, &(&1.role in [:system, :developer]))

    instructions =
      system
      |> Enum.map(&ContentPart.text_content(&1.content))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> case do
        "" -> nil
        text -> text
      end

    {instructions, rest}
  end

  defp to_input_part(%{kind: :text, text: text}) do
    %{"type" => "input_text", "text" => text}
  end

  defp to_input_part(%{kind: :tool_call, id: id, name: name, arguments: args}) do
    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => encode_args(args)
    }
  end

  defp to_input_part(%{
         kind: :tool_result,
         tool_call_id: id,
         content: content,
         is_error: is_error
       }) do
    %{
      "type" => "function_call_output",
      "call_id" => id,
      "output" => encode_content(content),
      "is_error" => !!is_error
    }
  end

  defp to_input_part(%{kind: :thinking, text: text, signature: signature, redacted: redacted}) do
    %{"type" => "reasoning", "text" => text, "signature" => signature, "redacted" => !!redacted}
  end

  defp to_input_part(%{kind: :image, url: url, detail: detail})
       when is_binary(url) and url != "" do
    part = %{"type" => "input_image", "image_url" => url}
    if detail in [nil, ""], do: part, else: Map.put(part, "detail", detail)
  end

  defp to_input_part(%{kind: :image, data: data, media_type: media_type, detail: detail})
       when is_binary(data) do
    uri = "data:#{media_type || "image/png"};base64,#{Base.encode64(data)}"
    part = %{"type" => "input_image", "image_url" => uri}
    if detail in [nil, ""], do: part, else: Map.put(part, "detail", detail)
  end

  defp to_input_part(%{kind: kind} = part) do
    %{
      "type" => "input_text",
      "text" => "[unsupported part #{kind}] #{ContentPart.text_content([part])}"
    }
  end

  defp to_response(%{status: status, body: body, headers: _headers})
       when status >= 200 and status < 300 do
    content_parts = parse_output_parts(body)

    text =
      case ContentPart.text_content(content_parts) do
        "" ->
          Map.get(body, "output_text") ||
            get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ||
            ""

        value ->
          value
      end

    {:ok,
     %Response{
       text: to_string(text),
       finish_reason: finish_reason(body, content_parts),
       content_parts: content_parts,
       raw: body,
       warnings: [],
       usage: usage_from_body(body)
     }}
  end

  defp to_response(%{status: status, body: body, headers: headers}) do
    {:error, ErrorMapper.from_http(provider(), status, body, headers)}
  end

  defp call_http(req, opts) do
    case Keyword.get(opts, :http_client) do
      http_client when is_function(http_client, 1) ->
        case http_client.(req) do
          {:ok, response} -> {:ok, normalize_response(response)}
          {:error, reason} -> {:error, ErrorMapper.from_transport(provider(), reason)}
        end

      _ ->
        {:error, ErrorMapper.from_transport(provider(), :no_http_client_configured)}
    end
  end

  defp call_http_stream(req, opts) do
    case Keyword.get(opts, :stream_client) do
      stream_client when is_function(stream_client, 1) ->
        case stream_client.(req) do
          {:ok, enumerable} -> {:ok, enumerable}
          {:error, reason} -> {:error, ErrorMapper.from_transport(provider(), reason)}
        end

      _ ->
        {:error, ErrorMapper.from_transport(provider(), :no_stream_client_configured)}
    end
  end

  defp normalize_response(%{status: status} = response) do
    %{
      status: status,
      body: Map.get(response, :body, %{}),
      headers: Map.get(response, :headers, [])
    }
  end

  defp fetch_api_key(opts) do
    key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    if is_binary(key) and key != "" do
      {:ok, key}
    else
      {:error,
       ErrorMapper.from_http(
         provider(),
         401,
         %{"error" => %{"message" => "missing api key", "code" => "auth_missing"}},
         []
       )}
    end
  end

  defp parse_output_parts(body) when is_map(body) do
    output = Map.get(body, "output", [])

    output
    |> List.wrap()
    |> Enum.flat_map(fn item ->
      type = Map.get(item, "type")

      cond do
        type == "message" ->
          item
          |> Map.get("content", [])
          |> List.wrap()
          |> Enum.flat_map(&parse_message_content_part/1)

        type == "function_call" ->
          [
            ContentPart.tool_call(
              Map.get(item, "call_id") || Map.get(item, "id") || "call",
              Map.get(item, "name") || "tool",
              decode_args(Map.get(item, "arguments"))
            )
          ]

        type == "function_call_output" ->
          [
            ContentPart.tool_result(
              Map.get(item, "call_id") || "call",
              decode_content(Map.get(item, "output")),
              is_error: Map.get(item, "is_error", false)
            )
          ]

        type == "reasoning" ->
          redacted = Map.get(item, "redacted", false) || Map.has_key?(item, "encrypted_content")

          thinking_text =
            Map.get(item, "text") ||
              Map.get(item, "encrypted_content") ||
              extract_reasoning_text(item)

          [
            ContentPart.thinking(thinking_text,
              signature: Map.get(item, "signature"),
              redacted: redacted
            )
          ]

        true ->
          []
      end
    end)
  end

  defp parse_output_parts(_), do: []

  defp parse_message_content_part(%{"type" => "output_text", "text" => text}),
    do: [ContentPart.text(text)]

  defp parse_message_content_part(%{"type" => "text", "text" => text}),
    do: [ContentPart.text(text)]

  defp parse_message_content_part(%{"type" => "input_image", "image_url" => url}),
    do: [ContentPart.image_url(url)]

  defp parse_message_content_part(_), do: []

  defp extract_reasoning_text(item) do
    item
    |> Map.get("summary", [])
    |> List.wrap()
    |> Enum.map_join("\n", &to_string(Map.get(&1, "text", "")))
  end

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
  defp encode_content(content) when is_map(content), do: Jason.encode!(content)
  defp encode_content(other), do: inspect(other)

  defp decode_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> decoded
      _ -> content
    end
  end

  defp decode_content(other), do: other

  defp decode_tool_message_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> decoded
      _ -> content
    end
  end

  defp decode_tool_message_content(other), do: other

  defp tool_payload_error?(%{"status" => "error"}), do: true
  defp tool_payload_error?(%{status: "error"}), do: true
  defp tool_payload_error?(_), do: false

  defp unsupported_content_warnings(%Request{messages: messages}) do
    supported = MapSet.new([:text, :image, :tool_call, :tool_result, :thinking])

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

  defp translate_stream(events, warnings) do
    initial = %{warnings: warnings}

    Stream.transform(events, initial, fn event, acc ->
      case translate_openai_event(event, acc) do
        {nil, next_acc} -> {[], next_acc}
        {evt, next_acc} -> {[evt], next_acc}
      end
    end)
  end

  defp translate_openai_event(%{"type" => "response.created"} = raw, acc) do
    {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
       type: :start,
       data: %{"provider" => provider(), "warnings" => Map.get(acc, :warnings, []), "raw" => raw}
     }, acc}
  end

  defp translate_openai_event(%{"type" => "response.output_text.delta"} = raw, acc) do
    delta = Map.get(raw, "delta", "")

    {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
       type: :delta,
       data: %{"text" => to_string(delta), "raw" => raw}
     }, acc}
  end

  defp translate_openai_event(%{"type" => "response.function_call_arguments.delta"} = raw, acc) do
    data = %{
      "id" => Map.get(raw, "call_id") || Map.get(raw, "item_id"),
      "name" => Map.get(raw, "name"),
      "arguments_delta" => Map.get(raw, "delta"),
      "raw" => raw
    }

    {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :tool_call, data: data}, acc}
  end

  defp translate_openai_event(%{"type" => "response.output_item.done"} = raw, acc) do
    item = Map.get(raw, "item", %{})

    if Map.get(item, "type") == "function_call" do
      data = %{
        "id" => Map.get(item, "call_id") || Map.get(item, "id"),
        "name" => Map.get(item, "name"),
        "arguments" => Map.get(item, "arguments"),
        "raw" => raw
      }

      {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{type: :tool_call, data: data}, acc}
    else
      {nil, acc}
    end
  end

  defp translate_openai_event(%{"type" => "response.completed"} = raw, acc) do
    usage = usage_from_body(%{"usage" => Map.get(raw, "usage", %{})})
    finish_reason = normalize_finish_reason(Map.get(raw, "finish_reason", "stop"))

    {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
       type: :finish,
       data: %{"reason" => finish_reason, "usage" => usage, "raw" => raw}
     }, acc}
  end

  defp translate_openai_event(_raw, acc), do: {nil, acc}

  defp usage_from_body(body) when is_map(body) do
    usage = Map.get(body, "usage", %{})
    prompt_tokens = int_or_nil(Map.get(usage, "input_tokens") || Map.get(usage, "prompt_tokens"))

    output_tokens =
      int_or_nil(Map.get(usage, "output_tokens") || Map.get(usage, "completion_tokens"))

    total_tokens = int_or_nil(Map.get(usage, "total_tokens"))

    %{
      input_tokens: prompt_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      reasoning_tokens:
        int_or_nil(
          get_in(usage, ["output_tokens_details", "reasoning_tokens"]) ||
            get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
        ),
      cache_read_tokens:
        int_or_nil(
          get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
            get_in(usage, ["prompt_tokens_details", "cached_tokens"])
        ),
      cache_write_tokens: nil,
      raw: usage
    }
  end

  defp usage_from_body(_), do: %{}

  defp finish_reason(body, content_parts) do
    body_reason =
      body
      |> Map.get("finish_reason")
      |> normalize_finish_reason()

    cond do
      body_reason in [:stop, :length, :tool_calls, :content_filter, :error] ->
        body_reason

      Enum.any?(content_parts, &(&1.kind == :tool_call)) ->
        :tool_calls

      true ->
        :stop
    end
  end

  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("length"), do: :length
  defp normalize_finish_reason("tool_calls"), do: :tool_calls
  defp normalize_finish_reason("content_filter"), do: :content_filter
  defp normalize_finish_reason("error"), do: :error
  defp normalize_finish_reason(_), do: :other

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_), do: nil

  defp reasoning_body(%Request{reasoning_effort: effort})
       when is_binary(effort) and effort != "" do
    %{"effort" => effort}
  end

  defp reasoning_body(_), do: nil

  defp provider_options(%Request{provider_options: options}) when is_map(options) do
    Map.get(options, "openai") || Map.get(options, :openai) || %{}
  end

  defp provider_options(_), do: %{}

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right
end
