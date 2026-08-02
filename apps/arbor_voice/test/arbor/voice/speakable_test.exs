defmodule Arbor.Voice.SpeakableTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.Speakable

  @moduletag :fast

  @sensitive_pointer "That's sensitive. I've put it on your screen."
  @default_escalation_phrase "the rest is on your screen"

  # VOICE-14: strip/compact and budget behavior
  @tag spec: "VOICE-14"
  test "strips non-verbal content and compacts long lists" do
    long_blob = String.duplicate("Q", 44)

    table = """
    | Name | Value |
    | --- | --- |
    | a | b |
    """

    cases = [
      %{
        name: "shape stripping",
        input:
          """
          Here is code:
          ```elixir
          secret = "key"
          ```
          #{table}
          See [docs](https://example.com/guide) and https://example.com/help.
          Raw blob #{long_blob} should disappear.
          """
          |> String.trim(),
        banned_fragments: [
          "```",
          "https://example.com",
          long_blob,
          "secret",
          "Name",
          "Value",
          "| --- |",
          "a | b"
        ],
        required_fragments: ["See docs and"]
      },
      %{
        name: "multiple fenced blocks retain surrounding prose",
        input: "Before. ```elixir\nSECRET_ONE\n``` Middle. ```elixir\nSECRET_TWO\n``` After.",
        banned_fragments: ["SECRET_ONE", "SECRET_TWO", "```"],
        required_fragments: ["Before. Middle. After."]
      },
      %{
        name: "sentence-boundary budgeting",
        input:
          "This is a safe opener. This sentence is intentionally too long to fit and should be dropped.",
        opts: [max_words: 8, escalation_phrase: "more"],
        banned_fragments: ["should be dropped", "This sentence is intentionally too long"]
      },
      %{
        name: "long list compaction before budget",
        input:
          """
          1. first
          2. second
          3. third
          4. fourth
          5. fifth
          6. sixth
          """
          |> String.trim(),
        required_fragments: ["6 items. First three: first, second, third."]
      }
    ]

    for case_spec <- cases do
      phrase = Keyword.get(case_spec[:opts] || [], :escalation_phrase, @default_escalation_phrase)
      max_words = Keyword.get(case_spec[:opts] || [], :max_words, 40)

      opts =
        Keyword.merge(
          [max_words: max_words, escalation_phrase: phrase, classifier: &allow_classifier/1],
          case_spec[:opts] || []
        )

      {tag, spoken} =
        Speakable.render(
          case_spec.input,
          opts
        )

      assert tag == :speak_truncated
      assert String.ends_with?(spoken, phrase)
      assert String.contains?(spoken, phrase)

      spoken = String.trim(spoken)

      for fragment <- case_spec[:banned_fragments] || [] do
        refute spoken =~ fragment, "#{case_spec.name}: found banned fragment #{inspect(fragment)}"
      end

      for fragment <- case_spec[:required_fragments] || [] do
        assert spoken =~ fragment,
               "#{case_spec.name}: missing expected fragment #{inspect(fragment)}"
      end

      assert word_count(spoken) <= max_words
    end
  end

  @tag spec: "VOICE-14"
  test "preserves the order of short lists and enforces the default 60-word budget" do
    short_list = "- first\n- second\n- third"

    assert {:speak, spoken_list} =
             Speakable.render(short_list, classifier: &allow_classifier/1)

    assert spoken_list == "- first - second - third"

    long_text = 1..70 |> Enum.map_join(" ", &"word#{&1}")

    assert {:speak_truncated, budgeted} =
             Speakable.render(long_text, classifier: &allow_classifier/1)

    assert word_count(budgeted) <= 60
    assert String.ends_with?(budgeted, @default_escalation_phrase)
  end

  # VOICE-15: sentence/word boundary + escalation behavior and invalid option handling
  @tag spec: "VOICE-15"
  test "truncation ends with escalation phrase and respects budget" do
    spoken =
      "This sentence should stay. This second sentence is much longer and should be dropped."
      |> Speakable.render(
        max_words: 9,
        escalation_phrase: "more",
        classifier: &allow_classifier/1
      )

    assert {:speak_truncated, output} = spoken
    assert String.ends_with?(output, "more")
    assert word_count(output) <= 9
    assert output =~ "This sentence should stay."
    refute output =~ "This second sentence"
  end

  @tag spec: "VOICE-15"
  test "falls back to a word boundary when no sentence fits" do
    assert {:speak_truncated, output} =
             Speakable.render(
               "One two three four five six seven eight nine ten.",
               max_words: 8,
               escalation_phrase: "more",
               classifier: &allow_classifier/1
             )

    assert output == "One two three four five six seven more"
    assert word_count(output) == 8
  end

  @tag spec: "VOICE-15"
  test "validates impossible phrase-to-budget combinations up front" do
    assert_raise ArgumentError, fn ->
      Speakable.render("abc", max_words: 1, escalation_phrase: "too many words")
    end

    assert_raise ArgumentError, fn ->
      Speakable.render("abc", max_words: 7, escalation_phrase: "more")
    end
  end

  # VOICE-16: classifier fail-closed and tts_guard contract
  @tag spec: "VOICE-16"
  test "restricts sensitive content and fail-closed classifier outcomes" do
    failure_classifiers = [
      {:restricted, fn _text -> :restricted end},
      {:confidential, fn _text -> :confidential end},
      {:error, fn _text -> {:error, :boom} end},
      {:raise, fn _text -> raise "boom" end},
      {:throw, fn _text -> throw(:boom) end},
      {:exit, fn _text -> exit(:boom) end},
      {:invalid, fn _text -> :invalid end},
      {:tuple, fn _text -> {:other, :public} end}
    ]

    for {name, classifier} <- failure_classifiers do
      assert {:screen_only, @sensitive_pointer} =
               Speakable.render("private token sk-ant-foo", classifier: classifier),
             "failed for #{inspect(name)}"
    end
  end

  @tag spec: "VOICE-16"
  test "production default uses the common sensitivity classifier" do
    prompt = ~s(use key sk-ant-api1234567890abcdefghij to call the API)

    assert {:screen_only, @sensitive_pointer} = Speakable.render(prompt)
    assert {:speak, "ordinary public response"} = Speakable.render("ordinary public response")
  end

  @tag spec: "VOICE-16"
  test "tts_guard!/1 unwraps verdict tuples and rejects malformed values" do
    assert Speakable.tts_guard!({:speak, "safe words"}) == "safe words"
    assert Speakable.tts_guard!({:speak_truncated, "clipped words"}) == "clipped words"
    assert Speakable.tts_guard!({:screen_only, @sensitive_pointer}) == @sensitive_pointer

    assert_raise ArgumentError, fn -> Speakable.tts_guard!("safe words") end
    assert_raise ArgumentError, fn -> Speakable.tts_guard!({:bad, "safe words"}) end
    assert_raise ArgumentError, fn -> Speakable.tts_guard!({:speak, 123}) end
  end

  @tag spec: "VOICE-16"
  test "render is deterministic for printable inputs and produces verdicts" do
    corpus = [
      "Hello, world.",
      "  spaced   text with\tnewlines\nand punctuation!  ",
      "Symbols:  !\"#$%&'()*+,-./:;=?",
      "alpha\n1) first\n2) second\n3) third",
      "long text " <> String.duplicate("x", 80)
    ]

    for input <- corpus do
      first = Speakable.render(input, classifier: &allow_classifier/1, max_words: 10)
      second = Speakable.render(input, classifier: &allow_classifier/1, max_words: 10)
      assert first == second
      assert match?({tag, text} when is_atom(tag) and is_binary(text), first)
    end
  end

  defp allow_classifier(_text), do: :public

  defp word_count(text), do: length(String.split(text, ~r/\s+/, trim: true))
end
