defmodule Arbor.LLM.ProviderErrorCore do
  @moduledoc """
  Pure classification of a failed provider request into one
  `%Arbor.LLM.ProviderError{}`.

  Ports Imp's rule (deepfates/imp `decisions.md`): a failed LM request is one
  typed error with `status`, `retryable`, `retry_after_ms` and
  `context_window_exceeded`, so every consumer decides on fields instead of on
  which of several raw shapes arrived or on error text.

  Context-window detection reads the provider's structured error fields
  (`code`, `type`, `message`, `detail`) and, for a body that is not JSON, a
  bounded prefix of the body text — never the `inspect/1` of a whole term. It
  covers structured codes (OpenAI/Groq/Azure `context_length_exceeded`,
  llama.cpp `exceed_context_size_error`) and the phrasings of Anthropic,
  OpenAI-compatible servers (vLLM, LM Studio, DeepSeek, OpenRouter, Mistral),
  xAI, Gemini, Bedrock, and llama.cpp. A 429 is never a context-window failure.
  """

  alias Arbor.LLM.ExternalTerm
  alias Arbor.LLM.ProviderError

  # 408/429 plus the 5xx family that signals a transient upstream condition:
  # 529 is Anthropic "overloaded"; 520-524 are Cloudflare origin failures in
  # front of provider APIs. 501/505 are permanent and stay non-retryable.
  @retryable_statuses [408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529]

  @max_retry_after_ms 86_400_000
  @max_scan_bytes 4_096
  @max_message_bytes 256
  @max_body_items 4

  @context_codes ~w(
    context_length_exceeded
    context_window_exceeded
    model_context_window_exceeded
    exceed_context_size_error
  )

  @context_phrases [
    # Anthropic: "prompt is too long: 208310 tokens > 200000 maximum"
    "prompt is too long",
    # Anthropic: "input length and `max_tokens` exceed context limit: ..."
    "context limit",
    # OpenAI & compatible servers: "maximum context length is 8192 tokens";
    # LM Studio: "loaded with context length of only 4096 tokens"
    "context length",
    "context window",
    # llama.cpp: "the request exceeds the available context size"
    "context size",
    # xAI: "This model's maximum prompt length is 131072 but ..."
    "maximum prompt length",
    # Bedrock: "Input is too long for requested model."
    "input is too long",
    # Gemini: "The input token count (N) exceeds the maximum number of tokens allowed"
    "exceeds the maximum number of tokens",
    "reduce the length of the messages"
  ]

  @transport_exceptions [Req.TransportError, Mint.TransportError]
  @req_llm_http_exceptions [ReqLLM.Error.API.Request, ReqLLM.Error.API.Response]

  @doc """
  Classify a provider HTTP response that did not succeed.

  `body` is the decoded JSON body when the provider sent JSON, otherwise the
  raw body text. Options: `:original` (the untranslated failure term),
  `:provider`, and `:source` (recorded under `details.source`).
  """
  @spec from_http(integer(), term(), term(), keyword()) :: ProviderError.t()
  def from_http(status, headers, body, opts \\ []) when is_integer(status) do
    context? = status != 429 and context_window_exceeded?(body)

    ProviderError.exception(
      message: http_message(status, body),
      provider: Keyword.get(opts, :provider),
      status: status,
      retryable: not context? and retryable_status?(status),
      retry_after_ms: retry_after_ms(headers),
      context_window_exceeded: context?,
      details: details(opts),
      original: Keyword.get(opts, :original)
    )
  end

  @doc """
  Classify any other failure term: a transport exception (retryable), an
  exception raised by the provider library, a caught `{:exit | :throw, term}`,
  or a local refusal of the provider's response (`{:response_bytes_exceeded,
  max}`, `{:invalid_response_body, _}`, an embedding-association violation).
  The term itself becomes `original`; `:message` overrides the default text.
  A `%ProviderError{}` passes through.
  """
  @spec from_failure(term(), keyword()) :: ProviderError.t()
  def from_failure(reason, opts \\ [])

  def from_failure(%ProviderError{} = error, _opts), do: error

  # ReqLLM wraps a transport failure as `%ReqLLM.Error.API.Request{status: nil,
  # cause: %Req.TransportError{}}` together with the request body; the
  # transport exception is the untranslated failure.
  def from_failure(
        %{__struct__: module, status: nil, cause: %{__struct__: cause_module} = cause},
        opts
      )
      when module in @req_llm_http_exceptions and cause_module in @transport_exceptions,
      do: from_failure(cause, opts)

  def from_failure(%{__struct__: module, status: status} = error, opts)
      when module in @req_llm_http_exceptions and is_integer(status) do
    from_http(status, [], Map.get(error, :response_body), Keyword.put(opts, :original, error))
  end

  def from_failure(%{__struct__: module} = error, opts) when module in @transport_exceptions do
    failure(error, "transport error: " <> transport_reason(error), true, opts)
  end

  def from_failure({:response_bytes_exceeded, maximum} = reason, opts) do
    failure(reason, "provider response exceeded #{inspect(maximum)} bytes", false, opts)
  end

  def from_failure({:invalid_response_body, _reason} = reason, opts) do
    failure(reason, "invalid provider response body", false, opts)
  end

  def from_failure(%{__exception__: true} = error, opts) do
    failure(error, ExternalTerm.exception_message(error), false, opts)
  end

  def from_failure({:exit, _reason} = caught, opts),
    do: failure(caught, "provider request exited", false, opts)

  def from_failure({:throw, _value} = caught, opts),
    do: failure(caught, "provider request threw", false, opts)

  def from_failure(reason, opts) do
    failure(reason, "provider request failed", false, opts)
  end

  @doc "Whether an HTTP status signals a transient failure worth retrying."
  @spec retryable_status?(term()) :: boolean()
  def retryable_status?(status), do: status in @retryable_statuses

  @doc """
  The provider's requested retry delay in milliseconds, from `retry-after-ms`
  (OpenAI) or `retry-after` delta-seconds (RFC 9110; integer or decimal).
  HTTP-date values are ignored — resolving them would need the current time.
  Values are capped at 24 hours.
  """
  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms(headers) do
    case header_delay(headers, "retry-after-ms", 1) do
      nil -> header_delay(headers, "retry-after", 1_000)
      ms -> ms
    end
  end

  @doc "Whether a provider error body says the request exceeded the context window."
  @spec context_window_exceeded?(term()) :: boolean()
  def context_window_exceeded?(body) do
    {codes, texts} = error_fields(body)

    Enum.any?(codes, &(normalize(&1) in @context_codes)) or
      Enum.any?(texts, &context_text?/1)
  end

  # ── Construction ────────────────────────────────────────────────────

  defp failure(original, message, retryable, opts) do
    ProviderError.exception(
      message: Keyword.get(opts, :message, message),
      provider: Keyword.get(opts, :provider),
      retryable: retryable,
      details: details(opts),
      original: original
    )
  end

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_reason(error), do: ExternalTerm.exception_message(error)

  defp details(opts) do
    case Keyword.get(opts, :source) do
      nil -> nil
      source -> %{source: source}
    end
  end

  defp http_message(status, body) do
    case provider_message(body) do
      nil -> "HTTP #{status}"
      text -> "HTTP #{status}: " <> text
    end
  end

  defp provider_message(body) do
    case error_fields(body) do
      {_codes, [text | _]} -> bounded(text, @max_message_bytes)
      {_codes, []} -> nil
    end
  end

  # ── Retry-After ─────────────────────────────────────────────────────

  defp header_delay(headers, name, unit_ms) do
    headers
    |> header_values(name)
    |> Enum.find_value(&parse_delay(&1, unit_ms))
  end

  defp header_values(%{} = headers, name) do
    case Map.get(headers, name) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp header_values(headers, name) when is_list(headers) do
    for {key, value} when is_binary(key) and is_binary(value) <- headers,
        String.downcase(key) == name,
        do: value
  end

  defp header_values(_headers, _name), do: []

  defp parse_delay(value, unit_ms) do
    value = String.trim(value)

    number =
      case Integer.parse(value) do
        {integer, ""} ->
          integer

        _ ->
          case Float.parse(value) do
            {float, ""} -> float
            _ -> nil
          end
      end

    if is_number(number) and number >= 0,
      do: min(ceil(number * unit_ms), @max_retry_after_ms),
      else: nil
  end

  # ── Context-window detection ────────────────────────────────────────

  defp context_text?(text) do
    text = text |> bounded(@max_scan_bytes) |> String.downcase()

    Enum.any?(@context_phrases, &String.contains?(text, &1)) or
      Enum.any?(@context_codes, &String.contains?(text, &1))
  end

  # {codes, texts} from the places providers put their error: the OpenAI /
  # Anthropic `error` object, Gemini's list-wrapped error, top-level
  # `message`/`detail`, or a non-JSON body string.
  defp error_fields(body) when is_binary(body), do: {[], [body]}

  defp error_fields(body) when is_list(body) do
    body
    |> Enum.take(@max_body_items)
    |> Enum.reduce({[], []}, fn item, {codes, texts} ->
      {item_codes, item_texts} = error_fields(item)
      {codes ++ item_codes, texts ++ item_texts}
    end)
  end

  defp error_fields(%{} = body) do
    {nested_codes, nested_texts} =
      case Map.get(body, "error") do
        %{} = error -> object_fields(error)
        [_ | _] = errors -> error_fields(errors)
        text when is_binary(text) -> {[], [text]}
        _ -> {[], []}
      end

    {codes, texts} = object_fields(body)
    {nested_codes ++ codes, nested_texts ++ texts}
  end

  defp error_fields(_body), do: {[], []}

  defp object_fields(object) do
    codes = strings(object, ["code", "type", "status"])
    texts = strings(object, ["message", "detail"])
    {codes, texts}
  end

  defp strings(object, keys) do
    keys
    |> Enum.map(&Map.get(object, &1))
    |> Enum.filter(&is_binary/1)
  end

  defp normalize(code), do: code |> bounded(@max_message_bytes) |> String.downcase()

  defp bounded(text, maximum) do
    text
    |> binary_part(0, min(byte_size(text), maximum))
    |> String.replace_invalid("")
  end
end
