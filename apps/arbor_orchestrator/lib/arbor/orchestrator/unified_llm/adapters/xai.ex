defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.XAI do
  @moduledoc """
  Provider adapter for x.ai (Grok) API.

  Uses the standard endpoint at https://api.x.ai/v1.
  Requires XAI_API_KEY.

  Supports Grok models (3, 3-mini, 4, 4-fast, code-fast) with
  OpenAI-compatible Chat Completions format.

  Provider-specific options can be passed via `provider_options`:

      %Request{
        model: "grok-4-1-fast",
        provider_options: %{
          "xai" => %{
            "reasoning_effort" => "high",      # grok-3-mini only
            "tools" => [%{"type" => "web_search"}]
          }
        }
      }

  Notable model capabilities:
  - grok-4-1-fast: 2M context, $0.20/M input, reasoning + web search
  - grok-4: 256K context, vision support, reasoning
  - grok-3-mini-fast: 131K context, configurable reasoning_effort
  - grok-code-fast-1: 256K context, code-focused
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.Request

  @config %{
    provider: "xai",
    base_url: "https://api.x.ai/v1",
    api_key_env: "XAI_API_KEY",
    chat_path: "/chat/completions",
    extra_headers: nil
  }

  @impl true
  def provider, do: "xai"

  @impl true
  def complete(%Request{} = request, opts) do
    OpenAICompatible.complete(request, opts, @config)
  end

  @impl true
  def stream(%Request{} = request, opts) do
    OpenAICompatible.stream(request, opts, @config)
  end
end
