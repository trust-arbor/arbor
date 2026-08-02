defmodule Arbor.Voice.Speakable do
  @moduledoc """
  Speakability shaping and the voice-speech gate.

  VP-04/07/08 route every TTS string through `render/2` and then
  `tts_guard!/1`. No TTS call site may bypass this module; that call-site proof
  lands in follow-up phases for VOICE-13.
  """

  alias Arbor.Common.SensitivityClassifier

  @type verdict ::
          {:speak, String.t()}
          | {:speak_truncated, String.t()}
          | {:screen_only, String.t()}

  @default_max_words 60
  @default_escalation_phrase "the rest is on your screen"
  @sensitive_pointer "That's sensitive. I've put it on your screen."

  @code_fence_re ~r/```[\s\S]*?```/
  @table_row_re ~r/^\s*\|?.+\|.+\|?\s*$/
  @table_separator_re ~r/^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/
  @list_item_re ~r/^\s*(?:[-*+]\s+|\d+\.\s+)/
  @link_with_url_re ~r/\[([^\]]+)\]\(([^)\s]+(?:\s+"[^"]+")?)\)/
  @link_with_ref_re ~r/\[([^\]]+)\]\[[^\]]*\]/
  @url_re ~r/\bhttps?:\/\/[^\s\]\)\>]+/i
  @blob_re ~r/[A-Za-z0-9+\/=]{41,}/

  @doc """
  Deterministically convert text into a safe voice output verdict.

  ## Options

  * `:max_words` — maximum words in the final spoken string; it must fit the
    escalation phrase and sensitive-content pointer
  * `:classifier` — arity-1 fun that returns:
    `:public`, `:internal`, `:confidential`, `:restricted`, or `{:error, term()}`
  * `:escalation_phrase` — phrase appended to truncated output
  """
  @spec render(String.t(), keyword()) :: verdict()
  def render(text, opts \\ []) when is_binary(text) do
    max_words = Keyword.get(opts, :max_words, @default_max_words)
    classifier = Keyword.get(opts, :classifier, &default_classifier/1)
    escalation_phrase = Keyword.get(opts, :escalation_phrase, @default_escalation_phrase)

    validate_opts!(max_words, escalation_phrase)

    case safe_classification(classifier, text) do
      :screen_only ->
        {:screen_only, @sensitive_pointer}

      :allow ->
        cleaned = normalize_and_shape(text)
        enforce_budget(cleaned, max_words, escalation_phrase)

      :invalid ->
        {:screen_only, @sensitive_pointer}
    end
  end

  @doc """
  Unwrap a validated verdict into the string that may be spoken.

  This never accepts raw strings and never accepts malformed tuples.
  """
  @spec tts_guard!(verdict()) :: String.t()
  def tts_guard!({tag, text})
      when tag in [:speak, :speak_truncated, :screen_only] and is_binary(text) do
    text
  end

  def tts_guard!(_value) do
    raise ArgumentError, "expected a valid Speakable verdict tuple"
  end

  defp validate_opts!(max_words, escalation_phrase) do
    unless is_integer(max_words) and max_words > 0 do
      raise ArgumentError, "max_words must be a positive integer"
    end

    unless is_binary(escalation_phrase) and String.trim(escalation_phrase) != "" do
      raise ArgumentError, "escalation_phrase must be a non-empty string"
    end

    phrase_words = count_words(escalation_phrase)
    minimum_words = max(phrase_words, count_words(@sensitive_pointer))

    if minimum_words > max_words do
      raise ArgumentError,
            "max_words must be at least #{minimum_words} to fit required voice pointers"
    end
  end

  defp safe_classification(classifier, text) do
    case classifier.(text) do
      level when level in [:public, :internal] -> :allow
      :confidential -> :screen_only
      :restricted -> :screen_only
      {:error, _reason} -> :invalid
      _ -> :invalid
    end
  rescue
    _ -> :invalid
  catch
    :exit, _ -> :invalid
    _, _ -> :invalid
  end

  defp default_classifier(text) do
    text
    |> SensitivityClassifier.classify()
    |> Map.fetch!(:overall_sensitivity)
  end

  defp normalize_and_shape(text) do
    {code_sanitized, code_removed} = strip_fenced_code_blocks(text)
    {tables_sanitized, table_removed} = strip_markdown_tables(code_sanitized)
    {list_sanitized, list_removed} = compact_long_lists(tables_sanitized)
    {link_sanitized, links_removed} = strip_markdown_links(list_sanitized)
    {url_sanitized, urls_removed} = strip_urls(link_sanitized)
    {blob_sanitized, blobs_removed} = strip_long_blobs(url_sanitized)

    %{
      text: normalize_whitespace(blob_sanitized),
      structure_removed:
        code_removed || table_removed || list_removed || links_removed || urls_removed ||
          blobs_removed
    }
  end

  defp strip_fenced_code_blocks(text) do
    sanitized = String.replace(text, @code_fence_re, "", global: true)
    {sanitized, sanitized != text}
  end

  defp strip_markdown_tables(text) do
    lines = String.split(text, "\n", trim: false)
    {out_lines, removed} = do_strip_markdown_tables(lines, [], false)
    {Enum.join(Enum.reverse(out_lines), "\n"), removed}
  end

  defp do_strip_markdown_tables([], acc, removed), do: {acc, removed}

  defp do_strip_markdown_tables([line | rest], acc, removed) do
    if table_row_candidate?(line) do
      {table_block, remaining} = take_table_block(rest, [line])

      if table_block_valid?(table_block) do
        do_strip_markdown_tables(remaining, acc, true)
      else
        do_strip_markdown_tables(remaining, Enum.reverse(table_block) ++ acc, removed)
      end
    else
      do_strip_markdown_tables(rest, [line | acc], removed)
    end
  end

  defp take_table_block([], block), do: {Enum.reverse(block), []}

  defp take_table_block([line | rest], block) do
    if table_row_candidate?(line) do
      take_table_block(rest, [line | block])
    else
      {Enum.reverse(block), [line | rest]}
    end
  end

  defp table_block_valid?(table_block) do
    length(table_block) >= 2 and Enum.any?(table_block, &table_separator_row?/1)
  end

  defp table_row_candidate?(line) do
    trimmed = String.trim(line)
    trimmed != "" and String.match?(trimmed, @table_row_re)
  end

  defp table_separator_row?(line) do
    trimmed = String.trim(line)
    String.match?(trimmed, @table_separator_re)
  end

  defp compact_long_lists(text) do
    lines = String.split(text, "\n", trim: false)
    {out_lines, changed} = do_compact_lists(lines, [], false)
    {Enum.join(Enum.reverse(out_lines), "\n"), changed}
  end

  defp do_compact_lists([], acc, changed), do: {acc, changed}

  defp do_compact_lists([line | rest], acc, changed) do
    if list_item_line?(line) do
      {run, remaining} = take_list_run(rest, [line])

      if length(run) > 5 do
        do_compact_lists(remaining, [summarize_list(run) | acc], true)
      else
        do_compact_lists(remaining, Enum.reverse(run) ++ acc, changed)
      end
    else
      do_compact_lists(rest, [line | acc], changed)
    end
  end

  defp take_list_run([], run), do: {Enum.reverse(run), []}

  defp take_list_run([line | rest], run) do
    if list_item_line?(line) do
      take_list_run(rest, [line | run])
    else
      {Enum.reverse(run), [line | rest]}
    end
  end

  defp summarize_list(items) do
    names =
      items
      |> Enum.take(3)
      |> Enum.map(&extract_list_text/1)

    "#{length(items)} items. First three: #{Enum.join(names, ", ")}."
  end

  defp extract_list_text(line) do
    line
    |> String.replace(@list_item_re, "", global: false)
    |> String.trim()
  end

  defp list_item_line?(line), do: String.match?(line, @list_item_re)

  defp strip_markdown_links(text) do
    with_url = Regex.replace(@link_with_url_re, text, "\\1")
    with_ref = Regex.replace(@link_with_ref_re, with_url, "\\1")
    {with_ref, with_ref != text}
  end

  defp strip_urls(text) do
    stripped = String.replace(text, @url_re, "", global: true)
    {stripped, stripped != text}
  end

  defp strip_long_blobs(text) do
    stripped = String.replace(text, @blob_re, "", global: true)
    {stripped, stripped != text}
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp enforce_budget(
         %{text: text, structure_removed: structure_removed},
         max_words,
         escalation_phrase
       ) do
    words = count_words(text)

    if not structure_removed and words <= max_words do
      {:speak, text}
    else
      budget = max_words - count_words(escalation_phrase)

      {:speak_truncated,
       append_escalation(truncate_by_sentence_or_words(text, budget), escalation_phrase)}
    end
  end

  defp truncate_by_sentence_or_words(_text, available) when available <= 0, do: ""

  defp truncate_by_sentence_or_words(text, available) do
    sentences = split_sentences(text)

    {kept, _used} =
      Enum.reduce_while(
        sentences,
        {[], 0},
        fn sentence, {acc, used} ->
          words = count_words(sentence)

          if used + words <= available do
            {:cont, {[sentence | acc], used + words}}
          else
            {:halt, {acc, used}}
          end
        end
      )

    kept = Enum.reverse(kept) |> Enum.join(" ") |> String.trim()

    if kept == "" do
      truncate_by_word_count(text, available)
    else
      kept
    end
  end

  defp truncate_by_word_count(text, available) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(available)
    |> Enum.join(" ")
  end

  defp split_sentences(text) do
    text
    |> String.trim()
    |> case do
      "" ->
        []

      trimmed ->
        Regex.scan(~r/[^.!?]+(?:[.!?]|$)/u, trimmed)
        |> Enum.map(&List.first/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp append_escalation("", phrase), do: phrase
  defp append_escalation(text, phrase), do: text <> " " <> phrase

  defp count_words(text), do: length(String.split(text, ~r/\s+/, trim: true))
end
