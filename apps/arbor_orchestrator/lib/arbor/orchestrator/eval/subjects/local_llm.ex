defmodule Arbor.Orchestrator.Eval.Subjects.LocalLLM do
  @moduledoc """
  Subject that sends prompts to local LLM providers via UnifiedLLM adapters.

  Input can be:
    - A string (used as the user message)
    - A map with `"prompt"` and optional `"system"` keys

  Options:
    - `:provider` — `"lm_studio"` | `"ollama"` (default: `"lm_studio"`)
    - `:model` — model name (default: provider-specific)
    - `:temperature` — sampling temperature
    - `:max_tokens` — max response tokens (default: 4096)
    - `:timeout` — adapter timeout in ms (default: 60_000)
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request}
  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{LMStudio, Ollama}

  @adapters %{
    "lm_studio" => LMStudio,
    "ollama" => Ollama
  }

  @impl true
  def run(input, opts \\ []) do
    {prompt, system} = parse_input(input)
    provider = Keyword.get(opts, :provider, "lm_studio")
    model = Keyword.get(opts, :model, default_model(provider))
    temperature = Keyword.get(opts, :temperature)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    timeout = Keyword.get(opts, :timeout, 60_000)

    adapter = Map.get(@adapters, provider)

    unless adapter do
      {:error, "unknown provider: #{provider}. Available: #{inspect(Map.keys(@adapters))}"}
    else
      messages =
        if system do
          [
            %Message{role: :system, content: system},
            %Message{role: :user, content: prompt}
          ]
        else
          [%Message{role: :user, content: prompt}]
        end

      request = %Request{
        provider: provider,
        model: model,
        messages: messages,
        max_tokens: max_tokens,
        temperature: temperature
      }

      start_time = System.monotonic_time(:millisecond)

      case adapter.complete(request, receive_timeout: timeout) do
        {:ok, response} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          text = extract_text(response)
          {:ok, %{text: text, duration_ms: duration_ms, model: model, provider: provider}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_input(%{"prompt" => prompt} = input) do
    {prompt, input["system"]}
  end

  defp parse_input(%{prompt: prompt} = input) do
    {prompt, input[:system]}
  end

  defp parse_input(prompt) when is_binary(prompt) do
    {prompt, nil}
  end

  defp default_model("lm_studio"), do: "qwen/qwen3-coder-next"
  defp default_model("ollama"), do: "llama3.2:latest"
  defp default_model(_), do: ""

  defp extract_text(%{text: text}), do: text
  defp extract_text(%{message: %{content: content}}), do: content
  defp extract_text(%{"text" => text}), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""
end
