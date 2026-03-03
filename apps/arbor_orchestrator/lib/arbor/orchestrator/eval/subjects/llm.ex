defmodule Arbor.Orchestrator.Eval.Subjects.LLM do
  @moduledoc """
  Unified eval subject that routes prompts to any LLM provider.

  Supports API providers (OpenRouter, Ollama, LM Studio, Anthropic, etc.)
  through the UnifiedLLM adapter layer. Coding agents are available via
  the ACP adapter (`provider: "acp"` with `provider_options`).

  Input can be:
    - A string (used as the user message)
    - A map with `"prompt"` and optional `"system"` keys

  Options:
    - `:provider` — provider name (see @adapters for full list)
    - `:model` — model name (default: provider-specific)
    - `:temperature` — sampling temperature
    - `:max_tokens` — max response tokens (default: 32_768)
    - `:timeout` — adapter timeout in ms (default: 60_000)
    - `:stream` — if true, uses streaming to capture TTFT (default: false)

  Returns:
    `{:ok, %{text: str, duration_ms: int, ttft_ms: int | nil, tokens_generated: int | nil, model: str, provider: str}}`
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  require Logger

  alias Arbor.Orchestrator.UnifiedLLM.{Message, ProviderCatalog, Request}

  @impl true
  def run(input, opts \\ []) do
    {prompt, system} = parse_input(input)
    provider = Keyword.get(opts, :provider, "lm_studio")
    model = Keyword.get(opts, :model, default_model(provider))
    temperature = Keyword.get(opts, :temperature)
    max_tokens = Keyword.get(opts, :max_tokens, 32_768)
    timeout = Keyword.get(opts, :timeout, 60_000)
    use_streaming = Keyword.get(opts, :stream, false)

    adapter = resolve_adapter(provider)

    if adapter do
      messages = build_messages(prompt, system)

      request = %Request{
        provider: provider,
        model: model,
        messages: messages,
        max_tokens: max_tokens,
        temperature: temperature,
        provider_options: build_provider_options(provider)
      }

      if use_streaming do
        run_streaming(adapter, request, model, provider, timeout)
      else
        run_complete(adapter, request, model, provider, timeout)
      end
    else
      available = ProviderCatalog.available() |> Enum.map(fn {p, _} -> p end)
      {:error, "unknown provider: #{provider}. Available: #{inspect(available)}"}
    end
  end

  defp run_complete(adapter, request, model, provider, timeout) do
    start_time = System.monotonic_time(:millisecond)

    case adapter.complete(request, receive_timeout: timeout) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        text = extract_text(response)
        tokens = estimate_tokens(text, response)

        if text == "" do
          usage = Map.get(response, :usage, %{})

          Logger.warning(
            "Eval LLM subject: empty text from #{provider}/#{model} " <>
              "after #{duration_ms}ms. " <>
              "finish_reason=#{inspect(Map.get(response, :finish_reason))} " <>
              "output_tokens=#{inspect(Map.get(usage, :output_tokens))} " <>
              "content_parts=#{inspect(Enum.map(Map.get(response, :content_parts, []), & &1.kind))}"
          )
        end

        {:ok,
         %{
           text: text,
           duration_ms: duration_ms,
           ttft_ms: nil,
           tokens_generated: tokens,
           model: model,
           provider: provider
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_streaming(adapter, request, model, provider, timeout) do
    start_time = System.monotonic_time(:millisecond)

    case adapter.stream(request, receive_timeout: timeout) do
      {:ok, stream} ->
        {text, ttft_ms} = collect_stream(stream, start_time)
        duration_ms = System.monotonic_time(:millisecond) - start_time
        tokens = estimate_tokens(text, nil)

        {:ok,
         %{
           text: text,
           duration_ms: duration_ms,
           ttft_ms: ttft_ms,
           tokens_generated: tokens,
           model: model,
           provider: provider
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_stream(stream, start_time) do
    Enum.reduce(stream, {"", nil}, fn event, {text_acc, ttft} ->
      ttft = ttft || System.monotonic_time(:millisecond) - start_time

      chunk_text =
        case event do
          %{text: t} when is_binary(t) -> t
          %{delta: %{text: t}} when is_binary(t) -> t
          %{delta: t} when is_binary(t) -> t
          t when is_binary(t) -> t
          _ -> ""
        end

      {text_acc <> chunk_text, ttft}
    end)
  end

  defp build_messages(prompt, nil), do: [%Message{role: :user, content: prompt}]

  defp build_messages(prompt, system) do
    [
      %Message{role: :system, content: system},
      %Message{role: :user, content: prompt}
    ]
  end

  defp parse_input(%{"prompt" => prompt} = input), do: {prompt, input["system"]}
  defp parse_input(%{prompt: prompt} = input), do: {prompt, input[:system]}
  defp parse_input(prompt) when is_binary(prompt), do: {prompt, nil}

  defp build_provider_options(_provider), do: %{}

  # Resolve adapter module from ProviderCatalog — single source of truth
  defp resolve_adapter(provider) do
    catalog = ProviderCatalog.all()

    case Enum.find(catalog, fn entry -> entry.provider == provider end) do
      %{adapter_module: mod} -> mod
      _ -> nil
    end
  end

  defp default_model(_provider), do: ""

  defp extract_text(%{text: text}), do: text
  defp extract_text(%{message: %{content: content}}), do: content
  defp extract_text(%{"text" => text}), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp estimate_tokens(text, response) do
    # Try to get from response usage stats first
    # usage_from_body/1 normalizes to :output_tokens (atom key)
    usage_tokens =
      case response do
        %{usage: %{output_tokens: n}} when is_integer(n) -> n
        %{usage: %{completion_tokens: n}} when is_integer(n) -> n
        %{usage: %{"completion_tokens" => n}} when is_integer(n) -> n
        _ -> nil
      end

    # Fallback: rough estimate (~4 chars per token for English)
    usage_tokens || div(String.length(text || ""), 4)
  end
end
