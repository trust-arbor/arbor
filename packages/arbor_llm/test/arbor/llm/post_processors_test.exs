defmodule Arbor.LLM.PostProcessorsTest do
  @moduledoc """
  Behavioral tests for the content post-processors lifted from
  `Arbor.Orchestrator.UnifiedLLM.Adapters.LMStudio.parse_structured_message/1`
  during the Session 3 arbor_llm extract.

  The lift is meant to be a strict behavior preservation. These tests
  exercise each of the three extraction layers (Jason → regex →
  prefix-strip) plus the `reasoning_content` short-circuit, so a
  future refactor that breaks one layer fails loudly here rather
  than silently degrading LM Studio compatibility.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.PostProcessors

  describe "parse_structured/1 — fallthrough" do
    test "plain content with no reasoning returns nil (caller uses content as-is)" do
      assert PostProcessors.parse_structured(%{"content" => "Hello, world!"}) == nil
    end

    test "empty content with no reasoning returns nil" do
      assert PostProcessors.parse_structured(%{"content" => ""}) == nil
    end

    test "non-map input returns nil" do
      assert PostProcessors.parse_structured(nil) == nil
      assert PostProcessors.parse_structured("just a string") == nil
      assert PostProcessors.parse_structured(%{}) == nil
    end
  end

  describe "parse_structured/1 — reasoning_content extraction (DeepSeek-R1, OpenRouter, Heretic)" do
    test "DeepSeek-R1 style: reasoning_content alongside plain content" do
      msg = %{
        "content" => "The answer is 42.",
        "reasoning_content" => "Let me think about this step by step..."
      }

      assert [
               %{kind: :thinking, text: "Let me think about this step by step..."},
               %{kind: :text, text: "The answer is 42."}
             ] = PostProcessors.parse_structured(msg)
    end

    test "OpenRouter style: reasoning (not reasoning_content) is the field" do
      msg = %{
        "content" => "The answer is 42.",
        "reasoning" => "Step-by-step reasoning here."
      }

      parts = PostProcessors.parse_structured(msg)

      assert Enum.any?(
               parts,
               &(&1.kind == :thinking and &1.text == "Step-by-step reasoning here.")
             )

      assert Enum.any?(parts, &(&1.kind == :text and &1.text == "The answer is 42."))
    end

    test "reasoning_content takes precedence over reasoning when both present" do
      msg = %{
        "content" => "Final.",
        "reasoning_content" => "Primary reasoning.",
        "reasoning" => "Secondary reasoning."
      }

      [thinking | _] = PostProcessors.parse_structured(msg)
      assert thinking.text == "Primary reasoning."
    end

    test "empty reasoning fields fall through" do
      msg = %{"content" => "Hello.", "reasoning_content" => "", "reasoning" => nil}
      assert PostProcessors.parse_structured(msg) == nil
    end
  end

  describe "parse_structured/1 — wrapped-JSON envelopes (gpt-oss-heretic et al)" do
    test "Layer 1: well-formed JSON with output + thinking" do
      msg = %{
        "content" => ~s({"thinking":"I should be polite.","output":"Hello, friend!"})
      }

      assert [
               %{kind: :thinking, text: "I should be polite."},
               %{kind: :text, text: "Hello, friend!"}
             ] = PostProcessors.parse_structured(msg)
    end

    test "Layer 1: JSON with only output" do
      msg = %{"content" => ~s({"output":"Just the output."})}

      assert [%{kind: :text, text: "Just the output."}] =
               PostProcessors.parse_structured(msg)
    end

    test "Layer 2: malformed JSON with embedded unescaped quote falls to regex" do
      # Jason would reject this (the inner quote in "I said \"hi\""), but the
      # regex layer pulls the fields out.
      msg = %{
        "content" => ~s({"thinking":"thought here","output":"answer here"})
      }

      result = PostProcessors.parse_structured(msg)
      assert is_list(result)
      assert Enum.any?(result, &(&1.kind == :text and &1.text == "answer here"))
    end

    test "Layer 3: prefix-stripped for unbounded freeform after envelope" do
      # Models sometimes start `{"thinking":"..."<|message|>...` and keep
      # generating freeform text without ever closing the JSON.
      content =
        ~s({"thinking":"a short thought","output":") <> String.duplicate("answer text ", 5)

      msg = %{"content" => content}
      result = PostProcessors.parse_structured(msg)
      assert is_list(result)
      text_part = Enum.find(result, &(&1.kind == :text))
      assert text_part != nil
      assert String.contains?(text_part.text, "answer text")
    end

    test "wrapped-JSON extraction precedes API reasoning_content when both present" do
      msg = %{
        "content" => ~s({"thinking":"envelope thinking","output":"envelope output"}),
        "reasoning_content" => "api reasoning"
      }

      [thinking | _] = PostProcessors.parse_structured(msg)
      # The envelope's thinking wins; api_reasoning is only the fallback.
      assert thinking.text == "envelope thinking"
    end

    test "content not starting with { is not treated as wrapped JSON" do
      msg = %{"content" => "Looks like JSON but doesn't start with brace"}
      assert PostProcessors.parse_structured(msg) == nil
    end
  end

  describe "parse_wrapped_json/1 — direct layer access for tests" do
    test "returns map shape on Layer 1 success" do
      assert %{thinking: "t", text: "o"} =
               PostProcessors.parse_wrapped_json(~s({"thinking":"t","output":"o"}))
    end

    test "returns nil when no layer matches" do
      assert PostProcessors.parse_wrapped_json("plain text") == nil
      assert PostProcessors.parse_wrapped_json("{not valid json}") == nil
    end
  end
end
