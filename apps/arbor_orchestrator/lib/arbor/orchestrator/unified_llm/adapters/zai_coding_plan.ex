defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.ZaiCodingPlan do
  @moduledoc """
  Provider adapter for Z.ai Coding Plan API.

  Uses the dedicated coding endpoint at https://api.z.ai/api/coding/paas/v4
  which provides separate quota for code generation tasks.
  Requires ZAI_CODING_PLAN_API_KEY (distinct from the general ZAI_API_KEY).

  Same GLM models and OpenAI-compatible format as the general Zai adapter,
  but billed against the coding plan subscription.
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{OpenAICompatible, Zai}
  alias Arbor.Orchestrator.UnifiedLLM.Request

  @config %{
    provider: "zai_coding_plan",
    base_url: "https://api.z.ai/api/coding/paas/v4",
    api_key_env: "ZAI_CODING_PLAN_API_KEY",
    chat_path: "/chat/completions",
    extra_headers: nil,
    parse_message: &Zai.parse_reasoning_message/1,
    parse_delta: &Zai.parse_reasoning_delta/2
  }

  @impl true
  def provider, do: "zai_coding_plan"

  @impl true
  def complete(%Request{} = request, opts) do
    OpenAICompatible.complete(request, opts, @config)
  end

  @impl true
  def stream(%Request{} = request, opts) do
    OpenAICompatible.stream(request, opts, @config)
  end
end
