defmodule Arbor.LLM.Adapter.OAuthResponses do
  @moduledoc """
  `Arbor.LLM.ProviderAdapter` that lets an Arbor agent's turn run on a SUBSCRIPTION OAuth token
  (ChatGPT/Codex, xAI/Grok) instead of a metered API key — by translating the `%Request{}` into an
  `Arbor.LLM.OAuth.Responses` call (OpenAI Responses API against the subscription backend).

  Registered under the `"openai_oauth"` / `"xai_oauth"` provider names (see
  `Client.discover_env_adapters/1`). Anthropic is impossible here — `OAuth.access_token/1` refuses
  it, and there is no `*_oauth` alias mapping to Anthropic.

  Streaming/embeddings aren't supported on this path (the eval + non-streaming turns use `complete`).
  """

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.LLM.{OAuth, Request, Response}

  @impl true
  def provider, do: "openai_oauth"

  @impl true
  def complete(%Request{} = request, _opts \\ []) do
    messages =
      Enum.map(request.messages, fn m -> %{role: m.role, content: text_of(m.content)} end)

    opts = if model = model_id(request.model), do: [model: model], else: []

    case OAuth.Responses.complete(oauth_provider(request.provider), messages, opts) do
      {:ok, text} -> {:ok, %Response{text: text, finish_reason: :stop}}
      {:error, reason} -> {:error, reason}
    end
  end

  # "xai_oauth" -> :xai ; everything else (openai_oauth) -> :openai. access_token/1 does the
  # Anthropic refusal, so a hostile provider string can't reach a Claude token.
  defp oauth_provider(p) when is_binary(p) do
    if String.contains?(String.downcase(p), "xai"), do: :xai, else: :openai
  end

  defp oauth_provider(_), do: :openai

  # Strip any "provider/model" prefix; nil/blank -> let Responses pick its default.
  defp model_id(nil), do: nil
  defp model_id(""), do: nil
  defp model_id(model) when is_binary(model), do: model |> String.split("/") |> List.last()

  defp text_of(content) when is_binary(content), do: content
  defp text_of(parts) when is_list(parts), do: parts |> Enum.map_join(" ", &part_text/1)
  defp text_of(_), do: ""

  defp part_text(%{text: t}) when is_binary(t), do: t
  defp part_text(%{"text" => t}) when is_binary(t), do: t
  defp part_text(t) when is_binary(t), do: t
  defp part_text(_), do: ""
end
