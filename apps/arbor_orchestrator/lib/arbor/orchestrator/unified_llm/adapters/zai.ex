defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.Zai do
  @moduledoc """
  Provider adapter for Z.ai general API.

  Uses the standard endpoint at https://api.z.ai/api/paas/v4
  for general chat and reasoning tasks. Requires ZAI_API_KEY.

  For coding-specific workloads with a coding plan subscription,
  use the ZaiCodingPlan adapter instead.

  Supports GLM models (4.5 through 4.7) with OpenAI-compatible
  Chat Completions format. Includes thinking mode support via
  the reasoning_content response field.
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.Request

  @config %{
    provider: "zai",
    base_url: "https://api.z.ai/api/paas/v4",
    api_key_env: "ZAI_API_KEY",
    chat_path: "/chat/completions",
    extra_headers: nil
  }

  @impl true
  def provider, do: "zai"

  @impl true
  def complete(%Request{} = request, opts) do
    OpenAICompatible.complete(request, opts, @config)
  end

  @impl true
  def stream(%Request{} = request, opts) do
    OpenAICompatible.stream(request, opts, @config)
  end
end
