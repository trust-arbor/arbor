defmodule Arbor.LLM.Eval.Subject do
  @moduledoc """
  Evaluation subject that sends prompts through an Arbor LLM provider.

  Input can be a prompt string or a map with `"prompt"` and optional
  `"system"` keys. Atom-keyed maps are accepted for compatibility.

  A concrete `Arbor.LLM.Client` may be supplied with `:client` to select an
  explicitly configured transport for a single eval run. Without one, the
  provider adapter is selected from `Arbor.LLM.ProviderCatalog`.
  """

  @behaviour Arbor.Eval.Subject

  require Logger

  alias Arbor.LLM.{Client, Message, ProviderCatalog, Request, StreamEvent}

  @impl true
  def run(input, opts \\ []) do
    {prompt, system} = parse_input(input)
    provider = Keyword.get(opts, :provider, "lm_studio")
    model = Keyword.get(opts, :model, default_model(provider))
    temperature = Keyword.get(opts, :temperature)
    max_tokens = Keyword.get(opts, :max_tokens, 32_768)
    timeout = Keyword.get(opts, :timeout, 60_000)
    use_streaming = Keyword.get(opts, :stream, false)

    with {:ok, transport} <- resolve_transport(provider, opts) do
      request = %Request{
        provider: provider,
        model: model,
        messages: build_messages(prompt, system),
        max_tokens: max_tokens,
        temperature: temperature,
        provider_options: build_provider_options(provider)
      }

      if use_streaming do
        run_streaming(transport, request, model, provider, timeout)
      else
        run_complete(transport, request, model, provider, timeout)
      end
    end
  end

  defp resolve_transport(provider, opts) do
    case Keyword.get(opts, :client) do
      nil -> resolve_catalog_transport(provider)
      %Client{} = client -> {:ok, {:client, client}}
      _other -> {:error, "invalid client: expected an Arbor.LLM.Client struct"}
    end
  end

  defp resolve_catalog_transport(provider) do
    case Enum.find(ProviderCatalog.all(), &(&1.provider == provider)) do
      %{adapter_module: adapter} ->
        {:ok, {:adapter, adapter}}

      nil ->
        available = ProviderCatalog.available() |> Enum.map(fn {name, _capabilities} -> name end)
        {:error, "unknown provider: #{provider}. Available: #{inspect(available)}"}
    end
  end

  defp run_complete(transport, request, model, provider, timeout) do
    start_time = System.monotonic_time(:millisecond)

    case complete(transport, request, receive_timeout: timeout) do
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

  defp run_streaming(transport, request, model, provider, timeout) do
    start_time = System.monotonic_time(:millisecond)

    case stream(transport, request, receive_timeout: timeout) do
      {:ok, events} ->
        {text, ttft_ms} = collect_stream(events, start_time)
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

  defp complete({:client, client}, request, opts), do: Client.complete(client, request, opts)
  defp complete({:adapter, adapter}, request, opts), do: adapter.complete(request, opts)

  defp stream({:client, client}, request, opts), do: Client.stream(client, request, opts)

  defp stream({:adapter, adapter}, request, opts) do
    case adapter.stream(request, opts) do
      {:ok, _events} = result -> result
      {:error, _reason} = error -> error
      events -> {:ok, events}
    end
  end

  defp collect_stream(events, start_time) do
    Enum.reduce(events, {"", nil}, fn event, {text_acc, ttft_ms} ->
      chunk_text = stream_text(event)

      ttft_ms =
        if is_nil(ttft_ms) and chunk_text != "" do
          System.monotonic_time(:millisecond) - start_time
        else
          ttft_ms
        end

      {text_acc <> chunk_text, ttft_ms}
    end)
  end

  defp stream_text(%StreamEvent{type: :delta, data: %{"text" => text}}) when is_binary(text),
    do: text

  defp stream_text(%StreamEvent{type: :delta, data: %{text: text}}) when is_binary(text),
    do: text

  defp stream_text(%{text: text}) when is_binary(text), do: text
  defp stream_text(%{delta: %{text: text}}) when is_binary(text), do: text
  defp stream_text(%{delta: text}) when is_binary(text), do: text
  defp stream_text(text) when is_binary(text), do: text
  defp stream_text(_event), do: ""

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

  defp default_model(_provider), do: ""

  defp extract_text(%{text: text}), do: text
  defp extract_text(%{message: %{content: content}}), do: content
  defp extract_text(%{"text" => text}), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_response), do: ""

  defp estimate_tokens(text, response) do
    usage_tokens =
      case response do
        %{usage: %{output_tokens: count}} when is_integer(count) -> count
        %{usage: %{completion_tokens: count}} when is_integer(count) -> count
        %{usage: %{"completion_tokens" => count}} when is_integer(count) -> count
        _other -> nil
      end

    usage_tokens || div(String.length(text || ""), 4)
  end
end
