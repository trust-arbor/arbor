defmodule Arbor.Common.Sanitizers.XSS do
  @moduledoc """
  Sanitizer for Cross-Site Scripting (XSS) attacks.

  Uses a **decode-first pipeline**: iteratively URL-decode all encoding
  layers, normalize Unicode escapes, then validate and entity-encode
  the fully-decoded result. This prevents double-encoding bypass attacks
  where `%3Cscript%3E` passes through entity encoding untouched and
  gets decoded downstream.

  Sets bit 0 on the taint sanitizations bitmask.

  ## Pipeline

  1. Iterative URL decode (max 3 rounds until stable)
  2. Unicode escape normalization (`\\u003C` → `<`)
  3. HTML entity encoding of 5 critical characters (`& < > " '`)
  4. Script tag stripping
  5. `javascript:` URI blocking
  6. Event handler attribute blocking

  ## Implementation Note

  HTML entity encoding is implemented inline (5 `String.replace` calls)
  rather than using `Phoenix.HTML.html_escape/1` because arbor_common
  (Level 0.5) cannot depend on arbor_web (Level 1).
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b00000001
  @max_decode_rounds 3

  # Event handler attribute names
  @event_handler_names ~w(
    onclick ondblclick onmousedown onmouseup onmouseover onmousemove
    onmouseout onkeypress onkeydown onkeyup onfocus onblur onchange
    onsubmit onreset onselect onload onunload onerror onabort
    onscroll onresize oninput onanimationstart onanimationend
    ontransitionend onpointerdown onpointerup
  )

  # Precompile regex patterns at compile time — handler names are compile-time
  # literals, not user input, so ReDoS is not a concern here.
  # credo:disable-for-lines:3 Credo.Check.Security.UnsafeRegexCompile
  @event_handler_patterns Enum.map(@event_handler_names, fn handler ->
                            {handler, Regex.compile!("\\b#{handler}\\s*=", "i")}
                          end)

  @impl true
  @spec sanitize(term(), Taint.t(), keyword()) ::
          {:ok, String.t(), Taint.t()} | {:error, term()}
  def sanitize(value, %Taint{} = taint, _opts \\ []) when is_binary(value) do
    # Decode-first: resolve all encoding layers before sanitizing
    decoded = decode_value(value)

    sanitized =
      decoded
      |> html_entity_encode()
      |> strip_script_tags()
      |> block_javascript_uris()
      |> block_event_handlers()
      |> block_css_expressions()

    updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
    {:ok, sanitized, updated_taint}
  end

  @impl true
  @spec detect(term()) :: {:safe, float()} | {:unsafe, [String.t()]}
  def detect(value) when is_binary(value) do
    # Decode first, then check for patterns
    decoded = decode_value(value)
    raw_patterns = detect_in(decoded)

    # Also flag encoded sequences in the raw value as suspicious
    encoding_patterns = detect_encoding_evasion(value)

    all_patterns = Enum.uniq(raw_patterns ++ encoding_patterns)

    case all_patterns do
      [] -> {:safe, 1.0}
      patterns -> {:unsafe, patterns}
    end
  end

  def detect(_), do: {:safe, 1.0}

  @doc """
  Iteratively URL-decode a value until stable or max rounds reached.

  Catches multi-layer encoding: `%253Cscript%253E` → `%3Cscript%3E` → `<script>`.
  Also normalizes Unicode escapes like `\\u003C` → `<`.
  """
  @spec decode_value(String.t()) :: String.t()
  def decode_value(value) do
    value
    |> normalize_unicode_escapes()
    |> iterative_url_decode(@max_decode_rounds)
  end

  @doc """
  HTML entity encode the 5 critical characters.

  Order matters: `&` must be encoded first to avoid double-encoding
  of the `&` in other entities.
  """
  @spec html_entity_encode(String.t()) :: String.t()
  def html_entity_encode(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # -- Private ---------------------------------------------------------------

  defp iterative_url_decode(value, 0), do: value

  defp iterative_url_decode(value, rounds_left) do
    decoded = URI.decode(value)

    if decoded == value do
      # Stable — no more decoding needed
      value
    else
      iterative_url_decode(decoded, rounds_left - 1)
    end
  end

  defp normalize_unicode_escapes(value) do
    # Handle \u00XX style escapes (JavaScript Unicode escapes)
    Regex.replace(~r/\\u([0-9a-fA-F]{4})/, value, fn _, hex ->
      {codepoint, ""} = Integer.parse(hex, 16)
      <<codepoint::utf8>>
    end)
  end

  defp strip_script_tags(value) do
    value
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<script\b[^>]*>/i, "")
    |> String.replace(~r/<\/script>/i, "")
  end

  defp block_javascript_uris(value) do
    String.replace(value, ~r/javascript\s*:/i, "blocked:")
  end

  defp block_event_handlers(value) do
    Enum.reduce(@event_handler_patterns, value, fn {handler, pattern}, acc ->
      String.replace(acc, pattern, "data-blocked-#{handler}=")
    end)
  end

  defp block_css_expressions(value) do
    String.replace(value, ~r/expression\s*\(/i, "blocked-expression(")
  end

  defp detect_in(value) do
    checks = [
      {Regex.match?(~r/<script\b/i, value), "script_tag"},
      {Regex.match?(~r/<\/script>/i, value), "script_close_tag"},
      {Regex.match?(~r/javascript\s*:/i, value), "javascript_uri"},
      {Regex.match?(~r/vbscript\s*:/i, value), "vbscript_uri"},
      {Regex.match?(~r/data\s*:\s*text\/html/i, value), "data_uri_html"},
      {has_event_handler?(value), "event_handler"},
      {Regex.match?(~r/expression\s*\(/i, value), "css_expression"},
      {Regex.match?(~r/<iframe\b/i, value), "iframe_tag"},
      {Regex.match?(~r/<object\b/i, value), "object_tag"},
      {Regex.match?(~r/<embed\b/i, value), "embed_tag"},
      {Regex.match?(~r/<svg\b.*\bonload\b/is, value), "svg_onload"},
      {Regex.match?(~r/<img\b.*\bonerror\b/is, value), "img_onerror"}
    ]

    for {true, name} <- checks, do: name
  end

  defp detect_encoding_evasion(value) do
    lowered = String.downcase(value)

    checks = [
      {String.contains?(lowered, "%3c"), "encoded_lt"},
      {String.contains?(lowered, "%3e"), "encoded_gt"},
      {String.contains?(lowered, "%26"), "encoded_amp"},
      {String.contains?(lowered, "&#x3c"), "html_hex_encoded_lt"},
      {String.contains?(lowered, "&#60"), "html_decimal_encoded_lt"},
      {String.contains?(lowered, "\\u003c"), "unicode_escape_lt"}
    ]

    for {true, name} <- checks, do: name
  end

  defp has_event_handler?(value) do
    lowered = String.downcase(value)
    Enum.any?(@event_handler_names, fn handler -> String.contains?(lowered, handler) end)
  end
end
