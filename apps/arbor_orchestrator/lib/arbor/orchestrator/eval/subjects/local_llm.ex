defmodule Arbor.Orchestrator.Eval.Subjects.LocalLLM do
  @moduledoc """
  Subject that sends prompts to LLM providers via UnifiedLLM adapters.

  Input can be:
    - A string (used as the user message)
    - A map with `"prompt"` and optional `"system"` keys

  Options:
    - `:provider` — provider name (default: `"lm_studio"`)
    - `:model` — model name (default: provider-specific)
    - `:temperature` — sampling temperature
    - `:max_tokens` — max response tokens (default: 4096)
    - `:timeout` — adapter timeout in ms (default: 60_000)
    - `:stream` — if true, uses streaming to capture TTFT (default: false)

  Returns:
    `{:ok, %{text: str, duration_ms: int, ttft_ms: int | nil, tokens_generated: int | nil, model: str, provider: str}}`
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request}

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{
    Anthropic,
    Gemini,
    LMStudio,
    Ollama,
    OpenAI,
    OpenRouter,
    Xai,
    Zai
  }

  @adapters %{
    "lm_studio" => LMStudio,
    "ollama" => Ollama,
    "anthropic" => Anthropic,
    "openai" => OpenAI,
    "openrouter" => OpenRouter,
    "zai" => Zai,
    "xai" => Xai,
    "gemini" => Gemini
  }

  @impl true
  def run(input, opts \\ []) do
    {prompt, system} = parse_input(input)
    provider = Keyword.get(opts, :provider, "lm_studio")
    model = Keyword.get(opts, :model, default_model(provider))
    temperature = Keyword.get(opts, :temperature)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    timeout = Keyword.get(opts, :timeout, 60_000)
    use_streaming = Keyword.get(opts, :stream, false)

    adapter = Map.get(@adapters, provider)

    unless adapter do
      {:error, "unknown provider: #{provider}. Available: #{inspect(Map.keys(@adapters))}"}
    else
      messages = build_messages(prompt, system)

      request = %Request{
        provider: provider,
        model: model,
        messages: messages,
        max_tokens: max_tokens,
        temperature: temperature
      }

      if use_streaming do
        run_streaming(adapter, request, model, provider, timeout)
      else
        run_complete(adapter, request, model, provider, timeout)
      end
    end
  end

  defp run_complete(adapter, request, model, provider, timeout) do
    start_time = System.monotonic_time(:millisecond)

    case adapter.complete(request, receive_timeout: timeout) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        text = extract_text(response)
        tokens = estimate_tokens(text, response)

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

  defp default_model("lm_studio"), do: "qwen/qwen3-coder-next"
  defp default_model("ollama"), do: "llama3.2:latest"
  defp default_model("anthropic"), do: "claude-sonnet-4-5-20250929"
  defp default_model("openai"), do: "gpt-4o"
  defp default_model("openrouter"), do: "anthropic/claude-sonnet-4-5-20250929"
  defp default_model("zai"), do: "aurora-alpha"
  defp default_model("xai"), do: "grok-4-1-fast"
  defp default_model("gemini"), do: "gemini-2.5-flash"
  defp default_model(_), do: ""

  defp extract_text(%{text: text}), do: text
  defp extract_text(%{message: %{content: content}}), do: content
  defp extract_text(%{"text" => text}), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp estimate_tokens(text, response) do
    # Try to get from response usage stats first
    usage_tokens =
      case response do
        %{usage: %{completion_tokens: n}} when is_integer(n) -> n
        %{usage: %{"completion_tokens" => n}} when is_integer(n) -> n
        _ -> nil
      end

    # Fallback: rough estimate (~4 chars per token for English)
    usage_tokens || div(String.length(text), 4)
  end
end
