defmodule Arbor.AI do
  @moduledoc """
  Unified LLM interface for Arbor.

  Provides a simple facade for text generation with automatic routing
  between API backends (ReqLLM, paid) and CLI backends (Claude Code, etc., "free").

  ## Quick Start

      # Generate text with default settings (uses routing strategy)
      {:ok, result} = Arbor.AI.generate_text("What is 2+2?")
      result.text
      #=> "2+2 equals 4."

      # Explicitly use CLI backend (free via subscriptions)
      {:ok, result} = Arbor.AI.generate_text("Hello", backend: :cli)

      # Explicitly use API backend (paid)
      {:ok, result} = Arbor.AI.generate_text("Hello", backend: :api)

      # With custom options
      {:ok, result} = Arbor.AI.generate_text(
        "Analyze this code for security issues.",
        system_prompt: "You are a security reviewer.",
        max_tokens: 2048,
        temperature: 0.3
      )

  ## Backend Options

  - `:backend` - Backend selection:
    - `:api` - Use ReqLLM (paid API calls)
    - `:cli` - Use CLI agents (Claude Code, Codex, Gemini CLI, etc.)
    - `:auto` - Use routing strategy to decide (default)

  ## Configuration

  Configure defaults in your config:

      config :arbor_ai,
        # API settings
        default_provider: :anthropic,
        default_model: "claude-sonnet-4-5-20250514",
        timeout: 60_000,

        # Routing
        default_backend: :auto,
        routing_strategy: :cost_optimized,  # Try CLI first

        # CLI fallback chain
        cli_fallback_chain: [:anthropic, :openai, :gemini, :lmstudio]

  API keys are loaded from environment variables:

      ANTHROPIC_API_KEY=sk-ant-...
      OPENAI_API_KEY=sk-...
  """

  @behaviour Arbor.Contracts.API.AI

  alias Arbor.AI.{BackendRegistry, CliImpl, Config, Response, Router}

  require Logger

  @impl true
  @spec generate_text(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.AI.result()} | {:error, term()}
  def generate_text(prompt, opts \\ []) do
    backend = Router.select_backend(opts)

    Logger.debug("Arbor.AI routing to #{backend} backend")

    case backend do
      :cli ->
        generate_text_via_cli(prompt, opts)

      :api ->
        generate_text_via_api(prompt, opts)
    end
  end

  @doc """
  Generate text using the CLI backend directly.

  Bypasses routing and uses CLI agents (Claude Code, Codex, etc.).
  """
  @spec generate_text_via_cli(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_text_via_cli(prompt, opts \\ []) do
    case CliImpl.generate_text(prompt, opts) do
      {:ok, response} ->
        {:ok, normalize_response(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate text using the API backend directly.

  Bypasses routing and uses ReqLLM (paid API calls).
  """
  @spec generate_text_via_api(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_text_via_api(prompt, opts \\ []) do
    provider = Keyword.get(opts, :provider, Config.default_provider())
    model = Keyword.get(opts, :model, Config.default_model())
    system_prompt = Keyword.get(opts, :system_prompt)
    max_tokens = Keyword.get(opts, :max_tokens, 1024)
    temperature = Keyword.get(opts, :temperature, 0.7)

    messages = build_messages(prompt, system_prompt)
    model_spec = build_model_spec(provider, model)

    req_opts =
      [
        max_tokens: max_tokens,
        temperature: temperature
      ]
      |> maybe_add_system_prompt(system_prompt)

    Logger.debug("Arbor.AI API generating with #{provider}:#{model}")

    case ReqLLM.generate_text(model_spec, messages, req_opts) do
      {:ok, response} ->
        {:ok, format_api_response(response, provider, model)}

      {:error, reason} ->
        Logger.warning("Arbor.AI API generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Check available backends.

  Returns a list of available backends with their status.
  """
  @spec available_backends() :: [atom()]
  def available_backends do
    BackendRegistry.available_backends()
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Normalize CLI response to contract format
  defp normalize_response(%Response{} = response) do
    %{
      text: response.text || "",
      usage: response.usage || %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      model: response.model,
      provider: response.provider
    }
  end

  defp normalize_response(response) when is_map(response) do
    %{
      text: response[:text] || response["text"] || "",
      usage: response[:usage] || response["usage"] || %{},
      model: response[:model] || response["model"],
      provider: response[:provider] || response["provider"]
    }
  end

  defp build_messages(prompt, nil) do
    [%{role: "user", content: prompt}]
  end

  defp build_messages(prompt, _system_prompt) do
    # System prompt is passed via opts, not messages for ReqLLM
    [%{role: "user", content: prompt}]
  end

  defp maybe_add_system_prompt(opts, nil), do: opts
  defp maybe_add_system_prompt(opts, system), do: Keyword.put(opts, :system_prompt, system)

  defp build_model_spec(provider, model) do
    "#{provider}:#{model}"
  end

  defp format_api_response(response, provider, model) do
    %{
      text: extract_text(response),
      usage: extract_usage(response),
      model: model,
      provider: provider
    }
  end

  defp extract_text(response) when is_binary(response), do: response

  defp extract_text(response) when is_struct(response) do
    extract_text(Map.from_struct(response))
  end

  defp extract_text(response) when is_map(response) do
    extract_text_from_map(response)
  end

  defp extract_text(_response), do: ""

  defp extract_text_from_map(%{text: text}) when is_binary(text), do: text
  defp extract_text_from_map(%{content: content}) when is_binary(content), do: content

  defp extract_text_from_map(%{message: %{content: content}}) when is_binary(content),
    do: content

  defp extract_text_from_map(_), do: ""

  defp extract_usage(response) when is_map(response) do
    usage = Map.get(response, :usage) || %{}

    %{
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      total_tokens:
        Map.get(usage, :total_tokens) ||
          Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
    }
  end

  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
end
