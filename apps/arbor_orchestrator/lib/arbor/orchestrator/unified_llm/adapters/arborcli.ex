defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.Arborcli do
  @moduledoc """
  Provider adapter that bridges to Arbor.AI CLI backends at runtime.

  Uses the runtime bridge pattern (Code.ensure_loaded? + apply/3) to call
  Arbor.AI.generate_text_via_cli/2 without a compile-time dependency.
  This allows the orchestrator to use Claude Code, Codex, Gemini CLI, etc.
  when running within the Arbor umbrella, while remaining standalone-capable.
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  @provider_map %{
    "anthropic" => :anthropic,
    "openai" => :openai,
    "gemini" => :gemini,
    "qwen" => :qwen,
    "opencode" => :opencode,
    "lmstudio" => :lmstudio
  }

  @impl true
  def provider, do: "arborcli"

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    with {:ok, prompt, ai_opts} <- build_ai_opts(request, opts),
         {:ok, response} <- call_arbor_ai(prompt, ai_opts) do
      {:ok, translate_response(response)}
    end
  end

  @doc """
  Returns true if Arbor.AI is available at runtime.
  """
  def available? do
    Code.ensure_loaded?(Arbor.AI)
  end

  # --- Private ---

  defp build_ai_opts(%Request{} = request, opts) do
    {system_messages, user_messages} = split_messages(request.messages)

    prompt = extract_prompt(user_messages)
    system_prompt = extract_system_prompt(system_messages)

    cli_provider = resolve_cli_provider(request)

    ai_opts =
      [
        system_prompt: system_prompt,
        max_tokens: request.max_tokens,
        temperature: request.temperature
      ]
      |> maybe_add(:provider, cli_provider)
      |> maybe_add(:model, translate_model(request.model))
      |> maybe_add(:session_context, Keyword.get(opts, :session_context))
      |> maybe_add(:timeout, Keyword.get(opts, :timeout))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    {:ok, prompt, ai_opts}
  end

  defp split_messages(messages) do
    Enum.split_with(messages, fn msg ->
      msg.role in [:system, :developer]
    end)
  end

  defp extract_prompt(user_messages) do
    user_messages
    |> Enum.filter(fn msg -> msg.role == :user end)
    |> List.last()
    |> case do
      nil -> ""
      msg -> extract_text(msg.content)
    end
  end

  defp extract_system_prompt(system_messages) do
    system_messages
    |> Enum.map(fn msg -> extract_text(msg.content) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %{type: :text} -> true
      %{type: "text"} -> true
      _ -> false
    end)
    |> Enum.map(fn part -> Map.get(part, :text, Map.get(part, "text", "")) end)
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  defp resolve_cli_provider(%Request{} = request) do
    explicit = Map.get(request.provider_options, "cli_provider")

    cond do
      explicit != nil ->
        if is_atom(explicit), do: explicit, else: Map.get(@provider_map, explicit)

      request.provider != nil and request.provider != "arborcli" ->
        Map.get(@provider_map, request.provider)

      is_binary(request.model) ->
        infer_provider_from_model(request.model)

      true ->
        nil
    end
  end

  defp infer_provider_from_model(model) do
    cond do
      String.contains?(model, "claude") or model in ~w(opus sonnet haiku) -> :anthropic
      String.contains?(model, "gpt") or String.contains?(model, "codex") -> :openai
      String.contains?(model, "gemini") -> :gemini
      true -> nil
    end
  end

  defp translate_model(model) when is_binary(model) do
    case model do
      "opus" -> :opus
      "sonnet" -> :sonnet
      "haiku" -> :haiku
      other -> other
    end
  end

  defp translate_model(model), do: model

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp call_arbor_ai(prompt, opts) do
    if Code.ensure_loaded?(Arbor.AI) do
      apply(Arbor.AI, :generate_text_via_cli, [prompt, opts])
    else
      {:error, :arbor_ai_not_available}
    end
  end

  defp translate_response(response) when is_map(response) do
    text = Map.get(response, :text, Map.get(response, "text", ""))
    usage = Map.get(response, :usage, Map.get(response, "usage", %{}))
    thinking = Map.get(response, :thinking, Map.get(response, "thinking"))

    %Response{
      text: text || "",
      finish_reason: :stop,
      content_parts: [],
      usage: normalize_usage(usage),
      warnings: [],
      raw: if(thinking, do: %{"thinking" => thinking}, else: nil)
    }
  end

  defp translate_response(_), do: %Response{text: "", finish_reason: :error}

  defp normalize_usage(usage) when is_map(usage) do
    %{
      "input_tokens" => Map.get(usage, :input_tokens, Map.get(usage, "input_tokens", 0)),
      "output_tokens" => Map.get(usage, :output_tokens, Map.get(usage, "output_tokens", 0))
    }
  end

  defp normalize_usage(_), do: %{}
end
