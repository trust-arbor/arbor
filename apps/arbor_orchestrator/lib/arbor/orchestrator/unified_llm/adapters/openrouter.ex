defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.OpenRouter do
  @moduledoc """
  Provider adapter for OpenRouter API.

  Uses the standard endpoint at https://openrouter.ai/api/v1.
  Requires OPENROUTER_API_KEY.

  OpenRouter routes requests to many providers (Anthropic, OpenAI, Meta, etc.)
  using provider/model naming: "anthropic/claude-3.5-sonnet", "openai/gpt-4o",
  "arcee-ai/trinity-large-preview:free".

  Provider-specific options can be passed via `provider_options`:

      %Request{
        model: "anthropic/claude-3.5-sonnet",
        provider_options: %{
          "openrouter" => %{
            "route" => "fallback",
            "transforms" => ["middle-out"]
          }
        }
      }

  Optional attribution headers (HTTP-Referer, X-Title) can be configured
  via application config:

      config :arbor_orchestrator, :openrouter,
        app_referer: "https://your-app.com",
        app_title: "Your App"
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.Request

  @config %{
    provider: "openrouter",
    base_url: "https://openrouter.ai/api/v1",
    api_key_env: "OPENROUTER_API_KEY",
    chat_path: "/chat/completions",
    extra_headers: &__MODULE__.attribution_headers/1
  }

  @impl true
  def provider, do: "openrouter"

  @impl true
  def complete(%Request{} = request, opts) do
    OpenAICompatible.complete(request, opts, @config)
  end

  @impl true
  def stream(%Request{} = request, opts) do
    OpenAICompatible.stream(request, opts, @config)
  end

  @doc false
  def attribution_headers(_request) do
    config = Application.get_env(:arbor_orchestrator, :openrouter, [])

    []
    |> maybe_header("HTTP-Referer", Keyword.get(config, :app_referer))
    |> maybe_header("X-Title", Keyword.get(config, :app_title))
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, _name, ""), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]
end
