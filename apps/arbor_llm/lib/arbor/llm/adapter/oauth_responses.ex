defmodule Arbor.LLM.Adapter.OAuthResponses do
  @moduledoc """
  `Arbor.LLM.ProviderAdapter` that lets an Arbor agent's turn run on a SUBSCRIPTION OAuth token
  (ChatGPT/Codex, xAI/Grok) instead of a metered API key — by translating the `%Request{}` into an
  `Arbor.LLM.OAuth.Responses` call (OpenAI Responses API against the subscription backend).

  Registered under `"openai_oauth"` / `"xai_oauth"` (see `Client.discover_env_adapters/1`).
  Anthropic is impossible here — `OAuth.access_token/1` refuses it and no `*_oauth` alias maps to it.

  **Tool calling** is supported (needed for coding-recon + the security evals): `request.tools`
  (OpenAI-nested) → Responses flat function tools; returned `function_call`s → `%Response{}` with
  `:tool_call` content parts + `finish_reason: :tool_calls`, which Arbor's `ToolLoop` executes; on
  the next turn the loop's `:assistant` (list content) + `:tool` (metadata `tool_call_id`) messages
  are translated back into Responses `function_call` / `function_call_output` input items.

  Streaming (`stream/2`) + embeddings (`embed/3`) are not supported on this path.
  """

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.LLM.{ContentPart, OAuth, Request, Response}

  @impl true
  def provider, do: "openai_oauth"

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    {instructions, input} = build_input(request.messages)
    req = %{instructions: instructions, input: input, tools: build_tools(request.tools)}

    response_opts =
      opts
      |> Keyword.take([:max_response_bytes, :max_events, :max_event_bytes, :max_work])
      |> maybe_put_opt(:receive_timeout, opts[:receive_timeout] || request.receive_timeout)
      |> maybe_put_opt(:model, model_id(request.model))

    case OAuth.Responses.complete(oauth_provider(request.provider), req, response_opts) do
      {:ok, %{text: text, tool_calls: tool_calls}} ->
        {:ok, build_response(text, tool_calls)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Response: tool_call parts FIRST, then text; finish_reason gates the ToolLoop ──

  defp build_response(text, tool_calls) do
    tc_parts =
      Enum.map(tool_calls, fn tc -> ContentPart.tool_call(tc.id, tc.name, tc.arguments) end)

    text_parts = if is_binary(text) and text != "", do: [ContentPart.text(text)], else: []
    finish = if tool_calls == [], do: :stop, else: :tool_calls
    %Response{text: text || "", content_parts: tc_parts ++ text_parts, finish_reason: finish}
  end

  # ── messages → Responses input items (+ hoisted system instructions) ──

  defp build_input(messages) do
    {sys, items} =
      Enum.reduce(messages, {[], []}, fn m, {sys, items} ->
        case m.role do
          :system -> {[text_of(m.content) | sys], items}
          :tool -> {sys, items ++ [tool_result_item(m)]}
          :assistant -> {sys, items ++ assistant_items(m)}
          # :user, :developer
          _ -> {sys, items ++ [role_text_item(m)]}
        end
      end)

    {sys |> Enum.reverse() |> Enum.join("\n\n"), items}
  end

  defp role_text_item(m) do
    %{"role" => to_string(m.role), "content" => content_items(m.content)}
  end

  # Multimodal user/developer content → Responses input items: text → input_text, image →
  # input_image (a data: URI or URL). This is what lets the frontier models SEE a seed screenshot
  # (e.g. phishing-screenshot's image-embedded injection).
  defp content_items(content) when is_binary(content),
    do: [%{"type" => "input_text", "text" => content}]

  defp content_items(parts) when is_list(parts),
    do: parts |> Enum.map(&content_item/1) |> Enum.reject(&is_nil/1)

  defp content_items(_), do: []

  defp content_item(%{kind: :text, text: t}) when is_binary(t),
    do: %{"type" => "input_text", "text" => t}

  defp content_item(t) when is_binary(t), do: %{"type" => "input_text", "text" => t}

  defp content_item(%{kind: :image, data: data, media_type: mt}) when is_binary(data),
    do: %{"type" => "input_image", "image_url" => "data:#{mt || "image/png"};base64,#{data}"}

  defp content_item(%{kind: :image, url: url}) when is_binary(url),
    do: %{"type" => "input_image", "image_url" => url}

  defp content_item(_), do: nil

  # The ToolLoop's :tool message carries the call id in metadata (string or atom key).
  defp tool_result_item(m) do
    call_id = m.metadata["tool_call_id"] || m.metadata[:tool_call_id]
    %{"type" => "function_call_output", "call_id" => call_id, "output" => text_of(m.content)}
  end

  # The ToolLoop's :assistant turn is a list of ContentParts (tool_call parts + text). Emit a
  # function_call item per tool call, plus an assistant message for any text.
  defp assistant_items(m) do
    parts = List.wrap(m.content)

    fc_items =
      parts
      |> Enum.filter(&(is_map(&1) and Map.get(&1, :kind) == :tool_call))
      |> Enum.map(fn tc ->
        %{
          "type" => "function_call",
          "call_id" => tc.id,
          "name" => tc.name,
          "arguments" => encode_args(tc.arguments)
        }
      end)

    text = assistant_text(m.content)

    text_item =
      if text == "",
        do: [],
        else: [
          %{"role" => "assistant", "content" => [%{"type" => "output_text", "text" => text}]}
        ]

    fc_items ++ text_item
  end

  # ── tools: OpenAI-nested (%{"function" => %{...}}) → Responses flat function tool ──

  defp build_tools(tools) when is_list(tools) and tools != [] do
    Enum.map(tools, fn
      %{"function" => f} when is_map(f) ->
        %{
          "type" => "function",
          "name" => f["name"],
          "description" => f["description"] || "",
          "parameters" => f["parameters"] || %{"type" => "object", "properties" => %{}}
        }

      other ->
        other
    end)
  end

  defp build_tools(_), do: nil

  # ── helpers ──

  defp oauth_provider(p) when is_binary(p) do
    if String.contains?(String.downcase(p), "xai"), do: :xai, else: :openai
  end

  defp oauth_provider(_), do: :openai

  defp model_id(nil), do: nil
  defp model_id(""), do: nil
  defp model_id(model) when is_binary(model), do: model |> String.split("/") |> List.last()

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Responses function_call arguments must be a JSON string.
  defp encode_args(args) when is_binary(args), do: args
  defp encode_args(args) when is_map(args), do: Jason.encode!(args)
  defp encode_args(_), do: "{}"

  defp text_of(content) when is_binary(content), do: content
  defp text_of(parts) when is_list(parts), do: parts |> Enum.map_join(" ", &part_text/1)
  defp text_of(_), do: ""

  defp assistant_text(content) when is_binary(content), do: content

  defp assistant_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(is_map(&1) and Map.get(&1, :kind) == :text))
    |> Enum.map_join(" ", & &1.text)
  end

  defp assistant_text(_), do: ""

  defp part_text(%{kind: :text, text: t}) when is_binary(t), do: t
  defp part_text(%{text: t}) when is_binary(t), do: t
  defp part_text(%{"text" => t}) when is_binary(t), do: t
  defp part_text(t) when is_binary(t), do: t
  defp part_text(_), do: ""
end
