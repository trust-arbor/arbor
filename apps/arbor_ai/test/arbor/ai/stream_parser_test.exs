defmodule Arbor.AI.StreamParserTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.StreamParser

  describe "parse_line/1" do
    test "parses valid JSON" do
      line = ~s({"type":"stream_event","event":{"type":"content_block_start"}})
      assert {:ok, %{"type" => "stream_event"}} = StreamParser.parse_line(line)
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = StreamParser.parse_line("not json")
    end
  end

  describe "process_line/2" do
    test "accumulates text from text_delta events" do
      state = StreamParser.new()

      events = [
        ~s({"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"world!"}}})
      ]

      state = Enum.reduce(events, state, &StreamParser.process_line(&2, &1))
      result = StreamParser.finalize(state)

      assert result.text == "Hello world!"
    end

    test "captures thinking from thinking_delta events" do
      state = StreamParser.new()

      events = [
        ~s({"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Let me "}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"think..."}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_stop"}})
      ]

      state = Enum.reduce(events, state, &StreamParser.process_line(&2, &1))
      result = StreamParser.finalize(state)

      assert length(result.thinking) == 1
      assert hd(result.thinking).text == "Let me think..."
    end

    test "extracts session_id from result event" do
      state = StreamParser.new()

      event =
        ~s({"type":"result","session_id":"abc-123","usage":{"input_tokens":10,"output_tokens":20}})

      state = StreamParser.process_line(state, event)
      result = StreamParser.finalize(state)

      assert result.session_id == "abc-123"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 20
    end

    test "ignores system and hook events" do
      state = StreamParser.new()

      events = [
        ~s({"type":"system","subtype":"init"}),
        ~s({"type":"system","subtype":"hook_started"}),
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}})
      ]

      state = Enum.reduce(events, state, &StreamParser.process_line(&2, &1))
      result = StreamParser.finalize(state)

      assert result.text == "Hello"
    end
  end

  describe "process_lines/2" do
    test "processes multiple lines at once" do
      output = """
      {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"2 + 2 = "}}}
      {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"4"}}}
      {"type":"result","session_id":"test-session"}
      """

      state = StreamParser.new()
      state = StreamParser.process_lines(state, output)
      result = StreamParser.finalize(state)

      assert result.text == "2 + 2 = 4"
      assert result.session_id == "test-session"
    end
  end

  describe "assistant message with thinking" do
    test "extracts thinking blocks with signatures from assistant message" do
      state = StreamParser.new()

      # Simulated assistant message with thinking content block
      event =
        ~s({"type":"assistant","message":{"id":"msg-123","model":"claude-sonnet-4","content":[{"type":"thinking","thinking":"Deep analysis here","signature":"sig_abc"},{"type":"text","text":"Final answer"}]}})

      state = StreamParser.process_line(state, event)
      result = StreamParser.finalize(state)

      assert result.model == "claude-sonnet-4"
      assert length(result.thinking) == 1

      thinking = hd(result.thinking)
      assert thinking.text == "Deep analysis here"
      assert thinking.signature == "sig_abc"
    end
  end

  describe "mixed content" do
    test "handles text and thinking interleaved" do
      state = StreamParser.new()

      events = [
        # Thinking starts
        ~s({"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Analyzing..."}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_stop"}}),
        # Text starts
        ~s({"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The answer is 42."}}}),
        ~s({"type":"stream_event","event":{"type":"content_block_stop"}}),
        # Result
        ~s({"type":"result","session_id":"mixed-session"})
      ]

      state = Enum.reduce(events, state, &StreamParser.process_line(&2, &1))
      result = StreamParser.finalize(state)

      assert result.text == "The answer is 42."
      assert length(result.thinking) == 1
      assert hd(result.thinking).text == "Analyzing..."
      assert result.session_id == "mixed-session"
    end
  end
end
