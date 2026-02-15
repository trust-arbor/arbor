defmodule Arbor.AI.UnifiedBridge do
  @moduledoc """
  Runtime bridge to Arbor.Orchestrator.UnifiedLLM.Client.

  Provides a thin wrapper that translates between arbor_ai's option format
  and the unified Client's request format. Falls back gracefully when the
  orchestrator is not available.
  """

  require Logger

  @client_module Arbor.Orchestrator.UnifiedLLM.Client
  @base_module Arbor.Orchestrator.UnifiedLLM

  @doc """
  Check if the unified LLM client is available.
  """
  def available? do
    Code.ensure_loaded?(@client_module)
  end

  @doc """
  Generate text using the unified LLM client.

  Translates arbor_ai opts format to unified Client format and back.

  ## Options (arbor_ai format)
  - :provider - atom like :anthropic, :openai, :openrouter
  - :model - string like "claude-sonnet-4-5-20250514"
  - :system_prompt - optional string
  - :max_tokens - integer (default 1024)
  - :temperature - float (default 0.7)
  - :thinking - boolean for extended thinking
  - :thinking_budget - integer token budget for thinking

  Returns {:ok, response_map} | {:error, reason} | :unavailable
  """
  def generate_text(prompt, opts) do
    if available?() do
      do_generate(prompt, opts)
    else
      :unavailable
    end
  end

  defp do_generate(prompt, opts) do
    provider = to_string(Keyword.fetch!(opts, :provider))
    model = Keyword.fetch!(opts, :model)
    system_prompt = Keyword.get(opts, :system_prompt)
    max_tokens = Keyword.get(opts, :max_tokens, 1024)
    temperature = Keyword.get(opts, :temperature, 0.7)
    thinking_enabled = Keyword.get(opts, :thinking, false)
    _thinking_budget = Keyword.get(opts, :thinking_budget, 4096)

    # Get or create a client instance
    client = get_client()

    # Build messages using the Message module
    message_mod = Module.concat(@base_module, Message)
    request_mod = Module.concat(@base_module, Request)

    messages =
      if system_prompt do
        [
          apply(message_mod, :new, [:system, system_prompt]),
          apply(message_mod, :new, [:user, prompt])
        ]
      else
        [apply(message_mod, :new, [:user, prompt])]
      end

    # Build the Request struct
    request = %{
      __struct__: request_mod,
      provider: provider,
      model: model,
      messages: messages,
      tools: [],
      tool_choice: nil,
      max_tokens: max_tokens,
      temperature: temperature,
      reasoning_effort: nil,
      provider_options: %{}
    }

    # Add thinking/reasoning effort if enabled
    request =
      if thinking_enabled do
        # Map thinking to reasoning_effort for OpenAI-style providers
        # Extended thinking is provider-specific
        Map.put(request, :reasoning_effort, "high")
      else
        request
      end

    # Call Client.complete/3
    case apply(@client_module, :complete, [client, request, []]) do
      {:ok, response} ->
        {:ok, format_response(response, opts)}

      {:error, reason} ->
        Logger.warning("UnifiedBridge generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("UnifiedBridge exception: #{inspect(e)}")
      {:error, {:bridge_exception, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("UnifiedBridge exit: #{inspect(reason)}")
      {:error, {:bridge_exit, reason}}
  end

  # Format unified Client response back to arbor_ai's expected format
  defp format_response(response, opts) do
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    # The unified Client returns a Response struct with fields:
    # text, content, usage, thinking, model, provider, etc.
    # We need to map to arbor_ai's format: %{text, thinking, usage, model, provider}
    %{
      text: extract_text(response),
      thinking: extract_thinking(response),
      usage: extract_usage(response),
      model: model,
      provider: provider
    }
  end

  defp extract_text(response) do
    cond do
      is_map(response) and Map.has_key?(response, :text) -> response.text || ""
      is_map(response) and Map.has_key?(response, :content) -> response.content || ""
      is_binary(response) -> response
      true -> ""
    end
  end

  defp extract_thinking(response) do
    case response do
      %{thinking: blocks} when is_list(blocks) and blocks != [] ->
        Enum.map(blocks, fn block ->
          %{
            text: Map.get(block, :text) || Map.get(block, "text", ""),
            signature: Map.get(block, :signature) || Map.get(block, "signature")
          }
        end)

      _ ->
        nil
    end
  end

  defp extract_usage(response) do
    usage =
      case response do
        %{usage: u} when is_map(u) -> u
        _ -> %{}
      end

    %{
      input_tokens: Map.get(usage, :input_tokens) || Map.get(usage, :prompt_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens) || Map.get(usage, :completion_tokens, 0),
      cache_read_input_tokens: Map.get(usage, :cache_read_input_tokens, 0),
      total_tokens:
        Map.get(usage, :total_tokens) ||
          Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
    }
  end

  # Get or create a default client using from_env
  defp get_client do
    # Check persistent_term cache first for performance
    case :persistent_term.get({__MODULE__, :client}, nil) do
      nil ->
        client = apply(@client_module, :from_env, [[]])
        :persistent_term.put({__MODULE__, :client}, client)
        client

      client ->
        client
    end
  rescue
    _ -> apply(@client_module, :from_env, [[]])
  end
end
