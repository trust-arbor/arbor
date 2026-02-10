defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.Anthropic do
  @moduledoc false

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.ErrorMapper
  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Message, Request, Response}

  @endpoint "https://api.anthropic.com/v1/messages"
  @default_version "2023-06-01"

  @impl true
  def provider, do: "anthropic"

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
  def build_request(%Request{} = request, api_key, opts) do
    beta_headers = anthropic_beta_headers(request, opts)
    {system_text, non_system_messages} = split_system_messages(request.messages)
    provider_options = provider_options(request)

    base_body = %{
      "model" => request.model,
      "system" => system_text,
      "messages" => Enum.map(non_system_messages, &message_to_input/1),
      "max_tokens" => request.max_tokens || 1024
    }

    %{
      method: :post,
      url: @endpoint,
      headers:
        [
          {"x-api-key", api_key},
          {"anthropic-version", @default_version},
          {"content-type", "application/json"}
        ] ++ beta_headers,
      body: deep_merge(base_body, provider_options)
    }
  end

  @spec build_stream_request(Request.t(), String.t(), keyword()) :: map()
  def build_stream_request(%Request{} = request, api_key, opts) do
    req = build_request(request, api_key, opts)
    %{req | body: Map.put(req.body, "stream", true)}
  end

  defp anthropic_beta_headers(request, opts) do
    beta =
      get_in(request.provider_options, ["anthropic", "beta_headers"]) ||
        get_in(request.provider_options, [:anthropic, :beta_headers]) ||
        get_in(request.provider_options, ["anthropic", "beta_features"]) ||
        get_in(request.provider_options, [:anthropic, :beta_features]) ||
        get_in(request.provider_options, ["anthropic", "beta"]) ||
        get_in(request.provider_options, [:anthropic, :beta]) ||
        Keyword.get(opts, :anthropic_beta, [])

    beta
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> []
      values -> [{"anthropic-beta", Enum.join(values, ",")}]
    end
  end

  defp message_to_input(%Message{} = msg) do
    %{"role" => normalize_role(msg.role), "content" => normalize_content(msg)}
  end

  defp split_system_messages(messages) do
    {system, rest} =
      Enum.split_with(messages, fn msg ->
        msg.role in [:system, :developer]
      end)

    system_text =
      system
      |> Enum.map(&ContentPart.text_content(&1.content))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    {system_text, rest}
  end

  defp normalize_role(:assistant), do: "assistant"
  defp normalize_role(_), do: "user"

  defp normalize_content(%Message{role: :tool, metadata: metadata, content: content}) do
    meta = metadata || %{}
    tool_use_id = Map.get(meta, "tool_call_id") || Map.get(meta, :tool_call_id)
    parsed = decode_tool_message_content(content)

    if tool_use_id in [nil, ""] do
      name = Map.get(meta, "name") || Map.get(meta, :name) || "tool"
      [%{"type" => "text", "text" => "[tool #{name}] " <> ContentPart.text_content(content)}]
    else
      [
        %{
          "type" => "tool_result",
          "tool_use_id" => to_string(tool_use_id),
          "is_error" => tool_payload_error?(parsed),
          "content" => normalize_content_text(parsed)
        }
      ]
    end
  end

  defp normalize_content(%Message{content: content}) do
    content
    |> ContentPart.normalize()
    |> Enum.map(&to_anthropic_part/1)
  end

  defp to_anthropic_part(%{kind: :text, text: text}), do: %{"type" => "text", "text" => text}

  defp to_anthropic_part(%{kind: :image, url: url}) when is_binary(url) and url != "" do
    %{
      "type" => "image",
      "source" => %{"type" => "url", "url" => url}
    }
  end

  defp to_anthropic_part(%{kind: :image, data: data, media_type: media_type})
       when is_binary(data) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => media_type || "image/png",
        "data" => Base.encode64(data)
      }
    }
  end

  defp to_anthropic_part(%{kind: :tool_call, id: id, name: name, arguments: args}) do
    %{
      "type" => "tool_use",
      "id" => id,
      "name" => name,
      "input" => normalize_args(args)
    }
  end

  defp to_anthropic_part(%{
         kind: :tool_result,
         tool_call_id: id,
         content: content,
         is_error: is_error
       }) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "is_error" => !!is_error,
      "content" => normalize_content_text(content)
    }
  end

  defp to_anthropic_part(%{kind: :thinking, text: text, signature: signature, redacted: redacted}) do
    %{
      "type" => if(redacted, do: "redacted_thinking", else: "thinking"),
      "text" => text,
      "signature" => signature
    }
  end

  defp to_anthropic_part(%{kind: kind}) do
    %{"type" => "text", "text" => "[unsupported part #{kind}]"}
  end

  defp to_response(%{status: status, body: body, headers: _headers})
       when status >= 200 and status < 300 do
    content_parts = parse_content_parts(Map.get(body, "content", []))
    text = ContentPart.text_content(content_parts)

    {:ok,
     %Response{
       text: to_string(text),
       finish_reason: finish_reason(body, content_parts),
       content_parts: content_parts,
       raw: body,
       warnings: [],
       usage: usage_from_body(body, content_parts)
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
    key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

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

  defp parse_content_parts(parts) do
    parts
    |> List.wrap()
    |> Enum.flat_map(fn part ->
      case Map.get(part, "type") do
        "text" ->
          [ContentPart.text(Map.get(part, "text", ""))]

        "image" ->
          source = Map.get(part, "source", %{})

          case Map.get(source, "type") do
            "url" ->
              [ContentPart.image_url(Map.get(source, "url", ""))]

            "base64" ->
              data =
                source
                |> Map.get("data", "")
                |> decode_base64()

              [ContentPart.image_base64(data, Map.get(source, "media_type", "image/png"))]

            _ ->
              []
          end

        "tool_use" ->
          [
            ContentPart.tool_call(
              Map.get(part, "id", "call"),
              Map.get(part, "name", "tool"),
              Map.get(part, "input", %{})
            )
          ]

        "tool_result" ->
          [
            ContentPart.tool_result(
              Map.get(part, "tool_use_id", "call"),
              Map.get(part, "content", ""),
              is_error: Map.get(part, "is_error", false)
            )
          ]

        "thinking" ->
          [
            ContentPart.thinking(Map.get(part, "text", ""),
              signature: Map.get(part, "signature"),
              redacted: false
            )
          ]

        "redacted_thinking" ->
          [
            ContentPart.thinking(Map.get(part, "text", ""),
              signature: Map.get(part, "signature"),
              redacted: true
            )
          ]

        _ ->
          []
      end
    end)
  end

  defp normalize_args(args) when is_map(args), do: args

  defp normalize_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp normalize_args(_), do: %{}

  defp normalize_content_text(content) when is_binary(content), do: content
  defp normalize_content_text(content) when is_map(content), do: Jason.encode!(content)
  defp normalize_content_text(other), do: inspect(other)

  defp decode_base64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp decode_base64(other), do: other

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
    initial = %{warnings: warnings, finish_reason: :stop, usage: %{}}

    Stream.transform(events, initial, fn event, acc ->
      case translate_anthropic_event(event, acc) do
        {nil, next_acc} -> {[], next_acc}
        {evt, next_acc} -> {[evt], next_acc}
      end
    end)
  end

  defp translate_anthropic_event(%{"type" => "message_start"} = raw, acc) do
    {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
       type: :start,
       data: %{"provider" => provider(), "warnings" => Map.get(acc, :warnings, []), "raw" => raw}
     }, acc}
  end

  defp translate_anthropic_event(%{"type" => "content_block_delta"} = raw, acc) do
    delta = get_in(raw, ["delta", "text"]) || ""
    kind = get_in(raw, ["delta", "type"]) || get_in(raw, ["content_block", "type"])

    cond do
      kind in ["text_delta", "text"] and delta != "" ->
        {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
           type: :delta,
           data: %{"text" => delta, "raw" => raw}
         }, acc}

      kind in ["input_json_delta", "tool_use"] ->
        {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
           type: :tool_call,
           data: %{"arguments_delta" => get_in(raw, ["delta", "partial_json"]), "raw" => raw}
         }, acc}

      true ->
        {nil, acc}
    end
  end

  defp translate_anthropic_event(%{"type" => "content_block_start"} = raw, acc) do
    block = Map.get(raw, "content_block", %{})

    if Map.get(block, "type") == "tool_use" do
      {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
         type: :tool_call,
         data: %{
           "id" => Map.get(block, "id"),
           "name" => Map.get(block, "name"),
           "arguments" => Map.get(block, "input"),
           "raw" => raw
         }
       }, acc}
    else
      {nil, acc}
    end
  end

  defp translate_anthropic_event(%{"type" => "message_delta"} = raw, acc) do
    finish_reason =
      raw
      |> get_in(["delta", "stop_reason"])
      |> normalize_finish_reason()

    usage =
      usage_from_body(
        %{
          "usage" => %{
            "input_tokens" => get_in(raw, ["usage", "input_tokens"]),
            "output_tokens" => get_in(raw, ["usage", "output_tokens"]),
            "cache_read_input_tokens" => get_in(raw, ["usage", "cache_read_input_tokens"]),
            "cache_creation_input_tokens" => get_in(raw, ["usage", "cache_creation_input_tokens"])
          },
          "content" => []
        },
        []
      )

    {nil, %{acc | finish_reason: finish_reason, usage: usage}}
  end

  defp translate_anthropic_event(%{"type" => "message_stop"} = raw, acc) do
    {%Arbor.Orchestrator.UnifiedLLM.StreamEvent{
       type: :finish,
       data: %{"reason" => acc.finish_reason, "usage" => acc.usage, "raw" => raw}
     }, acc}
  end

  defp translate_anthropic_event(_raw, acc), do: {nil, acc}

  defp usage_from_body(body, content_parts) when is_map(body) do
    usage = Map.get(body, "usage", %{})
    input_tokens = int_or_nil(Map.get(usage, "input_tokens"))
    output_tokens = int_or_nil(Map.get(usage, "output_tokens"))

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: sum_tokens(input_tokens, output_tokens),
      reasoning_tokens: estimate_reasoning_tokens(content_parts),
      cache_read_tokens: int_or_nil(Map.get(usage, "cache_read_input_tokens")),
      cache_write_tokens: int_or_nil(Map.get(usage, "cache_creation_input_tokens")),
      raw: usage
    }
  end

  defp usage_from_body(_, _), do: %{}

  defp estimate_reasoning_tokens(content_parts) do
    thinking_text =
      content_parts
      |> Enum.filter(&(&1.kind == :thinking))
      |> Enum.map(&to_string(Map.get(&1, :text, "")))
      |> Enum.join(" ")
      |> String.trim()

    if thinking_text == "" do
      nil
    else
      thinking_text
      |> String.split(~r/\s+/, trim: true)
      |> length()
    end
  end

  defp finish_reason(body, content_parts) do
    body_reason =
      body
      |> Map.get("stop_reason")
      |> normalize_finish_reason()

    cond do
      body_reason in [:stop, :length, :tool_calls] ->
        body_reason

      Enum.any?(content_parts, &(&1.kind == :tool_call)) ->
        :tool_calls

      true ->
        :stop
    end
  end

  defp normalize_finish_reason("end_turn"), do: :stop
  defp normalize_finish_reason("stop_sequence"), do: :stop
  defp normalize_finish_reason("max_tokens"), do: :length
  defp normalize_finish_reason("tool_use"), do: :tool_calls
  defp normalize_finish_reason(_), do: :other

  defp sum_tokens(input, output) when is_integer(input) and is_integer(output), do: input + output
  defp sum_tokens(_, _), do: nil

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_), do: nil

  defp provider_options(%Request{provider_options: options}) when is_map(options) do
    case Map.get(options, "anthropic") || Map.get(options, :anthropic) || %{} do
      map when is_map(map) ->
        map
        |> Map.delete("beta")
        |> Map.delete(:beta)
        |> Map.delete("beta_headers")
        |> Map.delete(:beta_headers)
        |> Map.delete("beta_features")
        |> Map.delete(:beta_features)

      _ ->
        %{}
    end
  end

  defp provider_options(_), do: %{}

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right
end
