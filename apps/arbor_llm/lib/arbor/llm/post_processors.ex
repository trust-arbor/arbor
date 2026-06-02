defmodule Arbor.LLM.PostProcessors do
  @moduledoc """
  Pure content post-processors for LLM assistant messages.

  Lifted from `Arbor.Orchestrator.UnifiedLLM.Adapters.LMStudio.parse_structured_message/1`
  during the Session 3 arbor_llm extract — previously these ran only
  against LM Studio responses because that's where the hook was wired.
  At the generic-adapter layer they run against every provider's
  response, so models that emit wrapped-JSON envelopes or
  `reasoning_content` fields are handled uniformly regardless of which
  cloud or local server served them.

  ## What we handle

    1. **`reasoning_content` extraction** — DeepSeek-R1 / Heretic /
       similar reasoning models return a separate `reasoning_content`
       (or `reasoning`) field in the message body alongside `content`.
       req_llm's openai chat_api does not extract this; we promote it
       to an `Arbor.LLM.ContentPart.thinking/1` part so the orchestrator
       and dashboard see the reasoning explicitly.

    2. **Wrapped-JSON envelopes** — some local models (notably
       `gpt-oss-120b-heretic`) emit content shaped like
       `{"thinking":"...","output":"..."}` instead of plain text, often
       with malformed JSON (unescaped quotes, unterminated strings).
       Three-layer extraction:

       - **Layer 1 (`try_json_decode`)** — strict Jason parse; works
         for well-formed short responses.
       - **Layer 2 (`try_regex_extract`)** — field-by-field regex for
         malformed JSON where Jason rejects but the structure is
         regular enough to match.
       - **Layer 3 (`try_strip_prefix`)** — strip a `{"thinking":"`-style
         prefix when the model produces unbounded freeform after the
         envelope opens, never closing the JSON.

  ## Return shape

  `parse_structured/1` returns either `nil` (no special structure
  detected — caller should use the plain `content` string as-is) or a
  list of `Arbor.LLM.ContentPart.part/0` values. Callers compose this
  into `Arbor.LLM.Response.content_parts` in the generic adapter.

  All functions are pure — no IO, no GenServer calls, no side effects.
  """

  alias Arbor.LLM.ContentPart

  @typedoc """
  A response-message map as commonly returned by chat-completions APIs.
  Both `"reasoning_content"` (DeepSeek-R1 style) and `"reasoning"`
  (OpenRouter pass-through) keys are recognized for the reasoning
  field.
  """
  @type message_map :: %{
          optional(String.t()) => term(),
          required(String.t()) => String.t()
        }

  @doc """
  Run all post-processors against a chat-completion message.

  Returns `nil` when no special structure is detected (caller should
  fall back to the plain content). Returns a list of content parts
  when extraction succeeds.
  """
  @spec parse_structured(message_map() | term()) :: [ContentPart.part()] | nil
  def parse_structured(%{"content" => content} = msg) when is_binary(content) do
    api_reasoning = non_empty(msg["reasoning_content"]) || non_empty(msg["reasoning"])
    trimmed = String.trim(content)

    extracted = if String.starts_with?(trimmed, "{"), do: parse_wrapped_json(trimmed)

    cond do
      # Layered JSON extraction succeeded; reasoning from extracted wins
      # over the API-level reasoning field if both are present.
      extracted != nil ->
        thinking = extracted[:thinking] || api_reasoning
        build_parts(thinking, extracted[:text])

      # No wrapped envelope but the API surfaced a reasoning block.
      api_reasoning != nil ->
        [ContentPart.thinking(api_reasoning), ContentPart.text(content)]

      true ->
        nil
    end
  end

  def parse_structured(_), do: nil

  @doc """
  Attempt wrapped-JSON envelope extraction on a content string.

  Tries the three layers (strict Jason → regex field → prefix strip)
  in order and returns the first non-nil result, or `nil` if none
  succeed. Public so callers can exercise the layers directly in
  tests; in production it's invoked by `parse_structured/1`.

  Returns `%{thinking: nil | String.t(), text: String.t()}` on
  success.
  """
  @spec parse_wrapped_json(String.t()) ::
          %{thinking: String.t() | nil, text: String.t()} | nil
  def parse_wrapped_json(content) when is_binary(content) do
    try_json_decode(content) || try_regex_extract(content) || try_strip_prefix(content)
  end

  # ── Layer 1 — strict Jason ───────────────────────────────────────────

  defp try_json_decode(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) and map_size(map) > 0 ->
        output = non_empty(map["output"])
        reasoning = non_empty(map["reasoning"])
        thinking = non_empty(map["thinking"])
        text = output || reasoning || thinking
        if text, do: %{thinking: thinking, text: text}, else: nil

      _ ->
        nil
    end
  end

  # ── Layer 2 — regex field extraction for malformed JSON ──────────────

  defp try_regex_extract(text) do
    output = extract_field(text, "output")

    if output do
      thinking = extract_field(text, "thinking")
      %{thinking: non_empty(thinking), text: output}
    end
  end

  # Matches "field":"value" where value continues until the next
  # unescaped quote followed by a comma, brace, or end of string.
  defp extract_field(text, field) do
    pattern = ~r/"#{Regex.escape(field)}"\s*:\s*"(.*?)"\s*[,}]/s

    case Regex.run(pattern, text) do
      [_, ""] -> nil
      [_, val] -> unescape_json(val)
      nil -> nil
    end
  end

  defp unescape_json(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  # ── Layer 3 — prefix strip for unbounded freeform after envelope open ──

  defp try_strip_prefix(text) do
    case Regex.run(
           ~r/^\{"thinking":"[^"]{0,50}[^"]*?"?[,}]\s*"?(?:output|action)"?:?"?(.+)/s,
           text
         ) do
      [_, rest] ->
        cleaned = rest |> String.trim_trailing() |> String.trim_trailing("\"}")
        if String.length(cleaned) > 10, do: %{thinking: nil, text: cleaned}

      nil ->
        prefix = "{\"thinking\":\""

        if String.starts_with?(text, prefix) do
          rest = String.slice(text, String.length(prefix), String.length(text))
          cleaned = rest |> String.trim_trailing() |> String.trim_trailing("\"}")
          if String.length(cleaned) > 10, do: %{thinking: nil, text: cleaned}
        end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp build_parts(thinking, text) do
    parts =
      if(thinking, do: [ContentPart.thinking(thinking)], else: []) ++
        if(text && text != "", do: [ContentPart.text(text)], else: [])

    if parts != [], do: parts
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(s) when is_binary(s), do: s
  defp non_empty(_), do: nil
end
