defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.Zai do
  @moduledoc """
  Provider adapter for Z.ai general API.

  Uses the standard endpoint at https://api.z.ai/api/paas/v4
  for general chat and reasoning tasks. Requires ZAI_API_KEY.

  For coding-specific workloads with a coding plan subscription,
  use the ZaiCodingPlan adapter instead.

  Supports GLM models (4.5 through 5) with OpenAI-compatible
  Chat Completions format. Includes thinking mode support via
  the reasoning_content response field.
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Request, StreamEvent}

  @config %{
    provider: "zai",
    base_url: "https://api.z.ai/api/paas/v4",
    api_key_env: "ZAI_API_KEY",
    chat_path: "/chat/completions",
    extra_headers: nil,
    parse_message: &__MODULE__.parse_reasoning_message/1,
    parse_delta: &__MODULE__.parse_reasoning_delta/2
  }

  @impl true
  def provider, do: "zai"

  @impl true
  def runtime_contract do
    alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

    {:ok, contract} =
      RuntimeContract.new(
        provider: "zai",
        display_name: "Z.ai",
        type: :api,
        env_vars: [%{name: "ZAI_API_KEY", required: true}],
        capabilities:
          Capabilities.new(
            streaming: true,
            tool_calls: true,
            thinking: true,
            structured_output: true
          )
      )

    contract
  end

  @impl true
  def complete(%Request{} = request, opts) do
    OpenAICompatible.complete(request, opts, @config)
  end

  @impl true
  def stream(%Request{} = request, opts) do
    OpenAICompatible.stream(request, opts, @config)
  end

  # --- Z.ai-specific: reasoning_content support ---

  @doc false
  def parse_reasoning_message(%{"reasoning_content" => reasoning} = msg)
      when is_binary(reasoning) and reasoning != "" do
    content = Map.get(msg, "content")
    parts = [ContentPart.thinking(reasoning)]
    if is_binary(content) and content != "", do: parts ++ [ContentPart.text(content)], else: parts
  end

  def parse_reasoning_message(_), do: nil

  @doc false
  def parse_reasoning_delta(%{"reasoning_content" => text}, raw)
      when is_binary(text) and text != "" do
    %StreamEvent{
      type: :thinking_delta,
      data: %{"text" => text, "raw" => raw}
    }
  end

  def parse_reasoning_delta(_, _), do: nil
end
