defmodule Arbor.AI.CommsResponderTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.CommsResponder

  describe "extract_channel_hint/1" do
    test "parses [CHANNEL:email] prefix" do
      assert {:email, "Here is your report."} =
               CommsResponder.extract_channel_hint("[CHANNEL:email] Here is your report.")
    end

    test "parses [CHANNEL:signal] prefix" do
      assert {:signal, "Got it!"} =
               CommsResponder.extract_channel_hint("[CHANNEL:signal] Got it!")
    end

    test "case-insensitive parsing" do
      assert {:email, "Report"} =
               CommsResponder.extract_channel_hint("[CHANNEL:EMAIL] Report")

      assert {:signal, "Hi"} =
               CommsResponder.extract_channel_hint("[channel:Signal] Hi")
    end

    test "no prefix returns :auto with body unchanged" do
      text = "Just a normal response"
      assert {:auto, ^text} = CommsResponder.extract_channel_hint(text)
    end

    test "unknown channel name returns :auto" do
      text = "[CHANNEL:voice] Hello"
      assert {:auto, ^text} = CommsResponder.extract_channel_hint(text)
    end

    test "prefix must be at start of string" do
      text = "Some text [CHANNEL:email] more text"
      assert {:auto, ^text} = CommsResponder.extract_channel_hint(text)
    end

    test "handles prefix with no trailing space" do
      assert {:email, "Report"} =
               CommsResponder.extract_channel_hint("[CHANNEL:email]Report")
    end

    test "handles empty body after prefix" do
      assert {:email, ""} =
               CommsResponder.extract_channel_hint("[CHANNEL:email] ")
    end
  end
end
