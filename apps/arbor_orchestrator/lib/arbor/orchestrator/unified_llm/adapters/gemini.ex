defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.Gemini do
  @moduledoc false

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.ErrorMapper
  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Message, Request, Response}

  @endpoint_base "https://generativelanguage.googleapis.com/v1beta/models"

  @impl true
  def provider, do: "gemini"

  @impl true
  def runtime_contract do
    alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

    {:ok, contract} =
      RuntimeContract.new(
        provider: "gemini",
        display_name: "Google Gemini API",
        type: :api,
        env_vars: [%{name: "GEMINI_API_KEY", required: true}],
        capabilities:
          Capabilities.new(
            streaming: true,
            tool_calls: true,
            thinking: true,
            vision: true,
            structured_output: true
          )
      )

    contract
  end

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
    {system_instruction, non_system_messages} = split_system_messages(request.messages)

    base_body =
      %{
        "contents" => Enum.map(non_system_messages, &message_to_input/1),
        "systemInstruction" => system_instruction
      }
      |> maybe_put_tools(request.tools)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    %{
      method: :post,
      url: "#{@endpoint_base}/#{request.model}:generateContent?key=#{api_key}",
      headers: [{"content-type", "application/json"}],
      body: deep_merge(base_body, provider_options)
    }
  end

  @spec build_stream_request(Request.t(), String.t(), keyword()) :: map()
  def build_stream_request(%Request{} = request, api_key, opts) do
    req = build_request(request, api_key, opts)

    stream_url =
      req.url
      |> String.replace(":generateContent", ":streamGenerateContent")
      |> append_alt_sse()

    %{req | url: stream_url}
  end

  defp message_to_input(%Message{role: :tool} = msg) do
    meta = msg.metadata || %{}
    tool_call_id = Map.get(meta, "tool_call_id") || Map.get(meta, :tool_call_id) || "call"
    name = Map.get(meta, "name") || Map.get(meta, :name) || "tool"
    parsed = decode_tool_message_content(msg.content)

    %{
      "role" => "user",
      "parts" => [
        %{
          "functionResponse" => %{
            "id" => to_string(tool_call_id),
            "name" => to_string(name),
            "response" => %{
              "content" => normalize_content(parsed),
              "is_error" => tool_payload_error?(parsed)
            }
          }
        }
      ]
    }
  end

  defp message_to_input(%Message{} = msg) do
    %{
      "role" => normalize_role(msg.role),
      "parts" => Enum.map(ContentPart.normalize(msg.content), &to_gemini_part/1)
    }
  end

  defp split_system_messages(messages) do
    {system, rest} = Enum.split_with(messages, &(&1.role in [:system, :developer]))

    instruction_text =
      system
      |> Enum.map(&ContentPart.text_content(&1.content))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    instruction =
      if instruction_text == "" do
        nil
      else
        %{"parts" => [%{"text" => instruction_text}]}
      end

    {instruction, rest}
  end

  defp normalize_role(:assistant), do: "model"
  defp normalize_role(:tool), do: "user"
  defp normalize_role(_), do: "user"

  defp to_gemini_part(%{kind: :text, text: text}), do: %{"text" => text}

  defp to_gemini_part(%{kind: :image, url: url}) when is_binary(url) and url != "" do
    %{"fileData" => %{"fileUri" => url}}
  end

  defp to_gemini_part(%{kind: :image, data: data, media_type: media_type}) when is_binary(data) do
    %{
      "inlineData" => %{
        "mimeType" => media_type || "image/png",
        "data" => Base.encode64(data)
      }
    }
  end

  defp to_gemini_part(%{kind: :tool_call, id: id, name: name, arguments: arguments}) do
    %{
      "functionCall" => %{
        "id" => id,
        "name" => name,
        "args" => normalize_args(arguments)
      }
    }
  end

  defp to_gemini_part(%{
         kind: :tool_result,
         tool_call_id: id,
         content: content,
         is_error: is_error,
         name: name
       }) do
    %{
      "functionResponse" => %{
        "id" => id,
        "name" => if(is_binary(name) and name != "", do: name, else: "tool"),
        "response" => %{"content" => normalize_content(content), "is_error" => !!is_error}
      }
    }
  end

  defp to_gemini_part(%{kind: :thinking, text: text, signature: signature, redacted: redacted}) do
    %{
      "text" => "[thinking] " <> text,
      "thought" => true,
      "signature" => signature,
      "redacted" => !!redacted
    }
  end

  defp to_gemini_part(%{kind: kind}) do
    %{"text" => "[unsupported part #{kind}]"}
  end

  defp to_response(%{status: status, body: body, headers: _headers})
       when status >= 200 and status < 300 do
    content_parts =
      body
      |> get_in(["candidates", Access.at(0), "content", "parts"])
      |> parse_response_parts()

    text = ContentPart.text_content(content_parts)

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
    key = Keyword.get(opts, :api_key) || System.get_env("GEMINI_API_KEY")

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

  defp parse_response_parts(parts) do
    parts
    |> List.wrap()
    |> Enum.flat_map(fn part ->
      cond do
        Map.has_key?(part, "text") and Map.get(part, "thought", false) ->
          [
            ContentPart.thinking(Map.get(part, "text", ""),
              signature: Map.get(part, "signature"),
              redacted: Map.get(part, "redacted", false)
            )
          ]

        Map.has_key?(part, "text") ->
          [ContentPart.text(Map.get(part, "text", ""))]

        Map.has_key?(part, "functionCall") ->
          fc = Map.get(part, "functionCall", %{})

          [
            ContentPart.tool_call(
              Map.get(fc, "id", "call"),
              Map.get(fc, "name", "tool"),
              Map.get(fc, "args", %{})
            )
          ]

        Map.has_key?(part, "functionResponse") ->
          fr = Map.get(part, "functionResponse", %{})
          response = Map.get(fr, "response", %{})

          [
            ContentPart.tool_result(
              Map.get(fr, "id", "call"),
              Map.get(response, "content", ""),
              is_error: Map.get(response, "is_error", false),
              name: Map.get(fr, "name")
            )
          ]

        true ->
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

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_map(content), do: content
  defp normalize_content(other), do: %{"value" => inspect(other)}

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
    initial = %{warnings: warnings, usage: %{}, started: false}

    Stream.transform(events, initial, fn event, acc ->
      {translated, next_acc} = translate_gemini_event(event, acc)
      {translated, next_acc}
    end)
  end

  defp translate_gemini_event(%{"candidates" => _} = raw, acc) do
    parts = get_in(raw, ["candidates", Access.at(0), "content", "parts"]) |> List.wrap()

    deltas =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map(fn part ->
        %Arbor.Orchestrator.UnifiedLLM.StreamEvent{
          type: :delta,
          data: %{"text" => Map.get(part, "text", ""), "raw" => raw}
        }
      end)

    tool_calls =
      parts
      |> Enum.filter(&Map.has_key?(&1, "functionCall"))
      |> Enum.map(fn part ->
        fc = Map.get(part, "functionCall", %{})

        %Arbor.Orchestrator.UnifiedLLM.StreamEvent{
          type: :tool_call,
          data: %{
            "id" => Map.get(fc, "id"),
            "name" => Map.get(fc, "name"),
            "arguments" => Map.get(fc, "args"),
            "raw" => raw
          }
        }
      end)

    usage =
      case Map.get(raw, "usageMetadata") do
        usage when is_map(usage) -> usage_from_body(%{"usageMetadata" => usage})
        _ -> acc.usage
      end

    finish_reason = get_in(raw, ["candidates", Access.at(0), "finishReason"])

    finish =
      if is_binary(finish_reason) do
        [
          %Arbor.Orchestrator.UnifiedLLM.StreamEvent{
            type: :finish,
            data: %{
              "reason" => normalize_finish_reason(finish_reason),
              "usage" => usage,
              "raw" => raw
            }
          }
        ]
      else
        []
      end

    start =
      if Map.get(acc, :started, false) do
        []
      else
        [
          %Arbor.Orchestrator.UnifiedLLM.StreamEvent{
            type: :start,
            data: %{
              "provider" => provider(),
              "warnings" => Map.get(acc, :warnings, []),
              "raw" => raw
            }
          }
        ]
      end

    {start ++ deltas ++ tool_calls ++ finish, %{acc | started: true, usage: usage}}
  end

  defp translate_gemini_event(_raw, acc), do: {[], acc}

  defp append_alt_sse(url) do
    if String.contains?(url, "?") do
      url <> "&alt=sse"
    else
      url <> "?alt=sse"
    end
  end

  defp usage_from_body(body) when is_map(body) do
    usage = Map.get(body, "usageMetadata", %{})

    %{
      input_tokens: int_or_nil(Map.get(usage, "promptTokenCount")),
      output_tokens: int_or_nil(Map.get(usage, "candidatesTokenCount")),
      total_tokens: int_or_nil(Map.get(usage, "totalTokenCount")),
      reasoning_tokens: int_or_nil(Map.get(usage, "thoughtsTokenCount")),
      cache_read_tokens: int_or_nil(Map.get(usage, "cachedContentTokenCount")),
      cache_write_tokens: nil,
      raw: usage
    }
  end

  defp usage_from_body(_), do: %{}

  defp finish_reason(body, content_parts) do
    raw_reason = get_in(body, ["candidates", Access.at(0), "finishReason"])
    normalized = normalize_finish_reason(raw_reason)

    cond do
      normalized in [:stop, :length, :content_filter] ->
        normalized

      Enum.any?(content_parts, &(&1.kind == :tool_call)) ->
        :tool_calls

      true ->
        :stop
    end
  end

  defp normalize_finish_reason("STOP"), do: :stop
  defp normalize_finish_reason("MAX_TOKENS"), do: :length
  defp normalize_finish_reason("SAFETY"), do: :content_filter
  defp normalize_finish_reason("RECITATION"), do: :content_filter
  defp normalize_finish_reason("IMAGE_SAFETY"), do: :content_filter
  defp normalize_finish_reason("IMAGE_RECITATION"), do: :content_filter
  defp normalize_finish_reason(_), do: :other

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_), do: nil

  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) when is_list(tools) do
    declarations =
      Enum.map(tools, fn tool ->
        name = Map.get(tool, :name) || Map.get(tool, "name") || ""
        description = Map.get(tool, :description) || Map.get(tool, "description")

        parameters =
          Map.get(tool, :input_schema) || Map.get(tool, :parameters) ||
            Map.get(tool, "input_schema") || Map.get(tool, "parameters") || %{}

        base = %{"name" => to_string(name), "parameters" => parameters}
        if description, do: Map.put(base, "description", to_string(description)), else: base
      end)

    Map.put(body, "tools", [%{"functionDeclarations" => declarations}])
  end

  defp provider_options(%Request{provider_options: options}) when is_map(options) do
    case Map.get(options, "gemini") || Map.get(options, :gemini) || %{} do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp provider_options(_), do: %{}

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right
end
