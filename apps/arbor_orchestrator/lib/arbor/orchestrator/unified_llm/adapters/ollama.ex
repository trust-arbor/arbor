defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.Ollama do
  @moduledoc """
  Provider adapter for Ollama's local inference server.

  Uses the OpenAI-compatible endpoint at http://localhost:11434/v1
  by default. No API key required (local server).

  The base URL can be overridden via application config:

      config :arbor_orchestrator, :ollama,
        base_url: "http://192.168.1.100:11434/v1"

  Models are whatever you have pulled with `ollama pull`, passed through
  as-is (e.g. "llama3.2", "qwen2.5-coder", "deepseek-r1").

  Provider-specific options can be passed via `provider_options`:

      %Request{
        model: "llama3.2",
        provider_options: %{
          "ollama" => %{
            "num_ctx" => 8192,
            "num_predict" => 1024
          }
        }
      }
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.Request

  @default_base_url "http://localhost:11434/v1"

  @impl true
  def provider, do: "ollama"

  @impl true
  def runtime_contract do
    alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

    {:ok, contract} =
      RuntimeContract.new(
        provider: "ollama",
        display_name: "Ollama",
        type: :local,
        probes: [%{type: :http, url: base_url() <> "/models", timeout_ms: 2_000}],
        capabilities:
          Capabilities.new(
            streaming: true,
            tool_calls: true,
            embeddings: true
          )
      )

    contract
  end

  @impl true
  def complete(%Request{} = request, opts) do
    OpenAICompatible.complete(request, opts, config())
  end

  @impl true
  def stream(%Request{} = request, opts) do
    OpenAICompatible.stream(request, opts, config())
  end

  @impl true
  def embed(texts, model, opts) do
    OpenAICompatible.embed(texts, model, opts, config())
  end

  @doc """
  Returns true if Ollama appears to be running at the configured URL.

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
      provider: "ollama",
      base_url: base_url(),
      api_key_env: nil,
      chat_path: "/chat/completions",
      extra_headers: nil,
      # Cloud models need longer timeouts than local inference
      receive_timeout: 180_000
    }
  end

  defp base_url do
    config = Application.get_env(:arbor_orchestrator, :ollama, [])
    Keyword.get(config, :base_url, @default_base_url)
  end
end
