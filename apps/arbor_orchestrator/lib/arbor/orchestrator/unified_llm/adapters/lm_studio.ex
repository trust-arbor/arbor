defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.LMStudio do
  @moduledoc """
  Provider adapter for LM Studio's local inference server.

  Uses the OpenAI-compatible endpoint at http://localhost:1234/v1
  by default. No API key required (local server).

  The base URL can be overridden via application config:

      config :arbor_orchestrator, :lm_studio,
        base_url: "http://192.168.1.100:1234/v1"

  Models are whatever you have loaded in LM Studio, passed through
  as-is (e.g. "llama-3.2-3b-instruct", "qwen2.5-coder-7b").

  Provider-specific options can be passed via `provider_options`:

      %Request{
        model: "llama-3.2-3b-instruct",
        provider_options: %{
          "lm_studio" => %{
            "repeat_penalty" => 1.1
          }
        }
      }
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.Request

  @default_base_url "http://localhost:1234/v1"

  @impl true
  def provider, do: "lm_studio"

  @impl true
  def complete(%Request{} = request, opts) do
    OpenAICompatible.complete(request, opts, config())
  end

  @impl true
  def stream(%Request{} = request, opts) do
    OpenAICompatible.stream(request, opts, config())
  end

  @doc """
  Returns true if LM Studio appears to be running at the configured URL.

  Checks by attempting a lightweight request. Used by Client auto-discovery.
  """
  @spec available?() :: boolean()
  def available? do
    url = base_url() <> "/models"

    case Req.get(url, receive_timeout: 2_000) do
      {:ok, %Req.Response{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp config do
    %{
      provider: "lm_studio",
      base_url: base_url(),
      api_key_env: nil,
      chat_path: "/chat/completions",
      extra_headers: nil
    }
  end

  defp base_url do
    config = Application.get_env(:arbor_orchestrator, :lm_studio, [])
    Keyword.get(config, :base_url, @default_base_url)
  end
end
