defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.LMStudio do
  @moduledoc """
  Provider adapter for LM Studio's local inference server.

  Uses the OpenAI-compatible endpoint at http://localhost:1234/v1
  by default. No API key required (local server).

  The base URL can be overridden via application config:

      config :arbor_orchestrator, :lm_studio,
        base_url: "http://192.168.1.100:1234/v1"

  Models are whatever you have loaded in LM Studio, passed through
  as-is (e.g. "llama-3.2-3b-instruct", "qwen2.5-coder-7b").

  Provider-specific options can be passed via `provider_options`:

      %Request{
        model: "llama-3.2-3b-instruct",
        provider_options: %{
          "lm_studio" => %{
            "repeat_penalty" => 1.1
          }
        }
      }
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Request}

  @default_base_url "http://localhost:1234/v1"

  @impl true
  def provider, do: "lm_studio"

  @impl true
  def runtime_contract do
    alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

    {:ok, contract} =
      RuntimeContract.new(
        provider: "lm_studio",
        display_name: "LM Studio",
        type: :local,
        probes: [%{type: :http, url: base_url() <> "/models", timeout_ms: 2_000}],
        capabilities:
          Capabilities.new(
            streaming: true,
            tool_calls: true,
            structured_output: true
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

  @doc """
  Returns true if LM Studio appears to be running at the configured URL.

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

  # --- JSON-wrapped response parsing ---
  # Some LM Studio models (e.g. gpt-oss-120b-heretic) wrap their output in
  # structured JSON like {"thinking":"...","output":"...","action":"..."}
  # instead of returning plain text. The model's JSON is often malformed
  # (improper quote escaping, unterminated strings for long responses).
  #
  # Additionally, some models return a top-level "reasoning" field in the
  # API message (separate from content), similar to DeepSeek-R1.
  #
  # Three extraction layers:
  #   1. Jason.decode — works for well-formed short responses
  #   2. Regex field extraction — handles slightly malformed JSON
  #   3. JSON prefix stripping — handles completely broken long responses

  @doc false
  def parse_structured_message(%{"content" => content} = msg)
      when is_binary(content) do
    api_reasoning = non_empty(msg["reasoning"])
    trimmed = String.trim(content)

    extracted =
      if String.starts_with?(trimmed, "{") do
        try_json_decode(trimmed) || try_regex_extract(trimmed) || try_strip_prefix(trimmed)
      end

    cond do
      # Got structured content from JSON wrapper
      extracted != nil ->
        thinking = extracted[:thinking] || api_reasoning
        build_parts(thinking, extracted[:text])

      # API-level reasoning but content isn't JSON-wrapped
      api_reasoning != nil ->
        [ContentPart.thinking(api_reasoning), ContentPart.text(content)]

      # Nothing special — fall through to default parsing
      true ->
        nil
    end
  end

  def parse_structured_message(_), do: nil

  # Layer 1: Valid JSON parse
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

  # Layer 2: Regex extraction for malformed JSON
  # The model often produces {"thinking":"...","output":"..."} with improperly
  # escaped quotes inside values. Jason rejects it but the structure is regular
  # enough for regex.
  defp try_regex_extract(text) do
    output = extract_field(text, "output")

    if output do
      thinking = extract_field(text, "thinking")
      %{thinking: non_empty(thinking), text: output}
    end
  end

  # Layer 3: Strip JSON prefix for completely broken long responses
  # When the model starts {"thinking":"analysis<|message|>..." and then just
  # generates freeform text without ever closing the JSON structure.
  defp try_strip_prefix(text) do
    case Regex.run(
           ~r/^\{"thinking":"[^"]{0,50}[^"]*?"?[,}]\s*"?(?:output|action)"?:?"?(.+)/s,
           text
         ) do
      [_, rest] ->
        cleaned = rest |> String.trim_trailing() |> String.trim_trailing("\"}")
        if String.length(cleaned) > 10, do: %{thinking: nil, text: cleaned}

      nil ->
        # Simplest case: just strip {"thinking":" prefix
        prefix = "{\"thinking\":\""

        if String.starts_with?(text, prefix) do
          rest = String.slice(text, String.length(prefix), String.length(text))
          cleaned = rest |> String.trim_trailing() |> String.trim_trailing("\"}")
          if String.length(cleaned) > 10, do: %{thinking: nil, text: cleaned}
        end
    end
  end

  # Extract a field value from malformed JSON using regex.
  # Matches "field":"value" where value continues until the next unescaped
  # quote followed by a comma, brace, or end of string.
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

  defp config do
    %{
      provider: "lm_studio",
      base_url: base_url(),
      api_key_env: nil,
      chat_path: "/chat/completions",
      extra_headers: nil,
      parse_message: &parse_structured_message/1
    }
  end

  defp base_url do
    config = Application.get_env(:arbor_orchestrator, :lm_studio, [])
    Keyword.get(config, :base_url, @default_base_url)
  end
end
