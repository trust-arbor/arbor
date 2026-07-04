defmodule Arbor.LLM.OAuth.Responses do
  @moduledoc """
  Chat completion against the ChatGPT/Codex + xAI/Grok SUBSCRIPTION backends via the OpenAI
  **Responses API** (streaming SSE), authenticated with a subscription OAuth token from
  `Arbor.LLM.OAuth` (which hard-refuses Anthropic). This is how an Arbor agent uses a flat
  subscription instead of a metered API key.

  Verified live 2026-07-03: `gpt-5.4-mini` via ChatGPT-sub returns a completion (STATUS 200, no
  Cloudflare challenge) using the Codex `originator`/`User-Agent`/`ChatGPT-Account-ID` headers.

  The subscription backends REQUIRE `stream: true`; we buffer the SSE and accumulate
  `response.output_text.delta` events.
  """

  alias Arbor.LLM.OAuth
  require Logger

  @endpoints %{
    openai: "https://chatgpt.com/backend-api/codex/responses",
    xai: "https://api.x.ai/v1/responses"
  }

  @default_models %{openai: "gpt-5.4-mini", xai: "grok-4"}

  @doc """
  `complete(provider, messages, opts)` → `{:ok, text}` | `{:error, reason}`.

  `messages` is a list of `%{role: :system|:user|:assistant, content: binary}`. Options: `:model`,
  `:receive_timeout`. Anthropic providers are refused upstream by `OAuth.access_token/1`.
  """
  @spec complete(atom() | String.t(), [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(provider, messages, opts \\ []) do
    with {:ok, key} <- provider_key(provider),
         {:ok, token} <- OAuth.access_token(provider) do
      sid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      url = @endpoints[key]
      model = opts[:model] || @default_models[key]
      body = build_body(key, model, messages)

      case Req.post(url,
             headers: headers(key, token, provider, sid),
             json: body,
             receive_timeout: opts[:receive_timeout] || 120_000
           ) do
        {:ok, %{status: 200, body: raw}} -> {:ok, parse_sse(raw)}
        {:ok, %{status: status, body: raw}} -> {:error, {:responses_http, status, detail(raw)}}
        {:error, reason} -> {:error, {:responses_request_failed, reason}}
      end
    end
  end

  # openai/codex/chatgpt -> :openai ; xai/grok -> :xai (Anthropic refused later by access_token).
  defp provider_key(provider) do
    case provider |> to_string() |> String.downcase() do
      p when p in ~w(openai codex chatgpt gpt) -> {:ok, :openai}
      p when p in ~w(xai grok x-ai) -> {:ok, :xai}
      p -> {:error, {:no_responses_provider, p}}
    end
  end

  # Responses body: system message -> `instructions`, the rest -> `input` items. `store: false`,
  # `stream: true` (required by the subscription backends).
  defp build_body(_key, model, messages) do
    instructions =
      messages |> Enum.filter(&(&1.role == :system)) |> Enum.map_join("\n\n", & &1.content)

    input =
      messages
      |> Enum.reject(&(&1.role == :system))
      |> Enum.map(fn m ->
        %{"role" => to_string(m.role), "content" => [%{"type" => "input_text", "text" => m.content}]}
      end)

    %{"model" => model, "instructions" => instructions, "input" => input, "store" => false, "stream" => true}
  end

  # Codex backend needs the Cloudflare-whitelisting headers + the account-id (else 403); xAI just
  # needs a conversation-id header. Both take the Bearer OAuth token.
  defp headers(:openai, token, _provider, sid) do
    [
      {"authorization", "Bearer " <> token},
      {"user-agent", "codex_cli_rs/0.0.0 (Arbor)"},
      {"originator", "codex_cli_rs"},
      {"chatgpt-account-id", OAuth.account_id(:openai) || ""},
      {"session_id", sid},
      {"x-client-request-id", sid}
    ]
  end

  defp headers(:xai, token, _provider, sid) do
    [{"authorization", "Bearer " <> token}, {"x-grok-conv-id", sid}]
  end

  # Buffered SSE: accumulate the text deltas across `response.output_text.delta` events.
  defp parse_sse(raw) do
    raw
    |> to_string()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.reduce("", fn line, acc ->
      data = line |> String.replace_prefix("data:", "") |> String.trim()

      case Jason.decode(data) do
        {:ok, %{"type" => "response.output_text.delta", "delta" => d}} when is_binary(d) -> acc <> d
        _ -> acc
      end
    end)
  end

  defp detail(%{"detail" => d}), do: d
  defp detail(body), do: inspect(body) |> String.slice(0, 200)
end
