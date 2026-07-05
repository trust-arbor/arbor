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

  alias Arbor.LLM.OAuth

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
  def complete(provider, %{} = req, opts \\ []) do
    with {:ok, key} <- provider_key(provider),
         {:ok, token} <- OAuth.access_token(provider) do
      sid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      body = build_body(opts[:model] || @default_models[key], req)

      case Req.post(@endpoints[key],
             headers: headers(key, token, sid),
             json: body,
             receive_timeout: opts[:receive_timeout] || 180_000
           ) do
        {:ok, %{status: 200, body: raw}} -> {:ok, parse_sse(raw)}
        {:ok, %{status: status, body: raw}} -> {:error, {:responses_http, status, detail(raw)}}
        {:error, reason} -> {:error, {:responses_request_failed, reason}}
      end
    end
  end

  @doc """
  Convenience for the simple text path (no tools): `messages` is `[%{role, content}]`.
  Returns `{:ok, text}`.
  """
  @spec complete_text(atom() | String.t(), [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def complete_text(provider, messages, opts \\ []) do
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

  defp provider_key(provider) do
    case provider |> to_string() |> String.downcase() do
      p when p in ~w(openai codex chatgpt gpt) -> {:ok, :openai}
      p when p in ~w(xai grok x-ai) -> {:ok, :xai}
      p -> {:error, {:no_responses_provider, p}}
    end
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

  # Buffered SSE: text from output_text.delta events; tool calls from output_item.done events (each
  # carries a COMPLETE function_call item with full arguments — the streamed function_call is only
  # whole here, not in response.completed, whose output the ChatGPT backend omits in streaming).
  defp parse_sse(raw) do
    raw
    |> to_string()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.reduce(%{text: "", tool_calls: []}, fn line, acc ->
      data = line |> String.replace_prefix("data:", "") |> String.trim()

      case Jason.decode(data) do
        {:ok, %{"type" => "response.output_text.delta", "delta" => d}} when is_binary(d) ->
          %{acc | text: acc.text <> d}

        {:ok,
         %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item}} ->
          %{acc | tool_calls: acc.tool_calls ++ [tool_call_from_item(item)]}

        _ ->
          acc
      end
    end)
  end

  defp tool_call_from_item(item) do
    %{
      id: item["call_id"] || item["id"],
      name: item["name"],
      arguments: decode_args(item["arguments"])
    }
  end

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp decode_args(m) when is_map(m), do: m
  defp decode_args(_), do: %{}

  defp detail(%{"detail" => d}), do: d
  defp detail(body), do: inspect(body) |> String.slice(0, 200)
end
