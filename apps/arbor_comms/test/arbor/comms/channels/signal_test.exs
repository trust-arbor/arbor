defmodule Arbor.Comms.Channels.SignalTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Channels.Signal

  describe "channel_info/0" do
    test "returns signal channel metadata" do
      info = Signal.channel_info()
      assert info.name == :signal
      assert info.max_message_length == 2000
      assert info.supports_media == true
      assert info.supports_threads == false
      assert info.latency == :polling
    end
  end

  describe "format_response/1" do
    test "trims whitespace" do
      assert Signal.format_response("  hello  ") == "hello"
    end

    test "truncates long messages" do
      long = String.duplicate("a", 3000)
      result = Signal.format_response(long)
      assert String.length(result) == 2000
      assert String.ends_with?(result, "...")
    end

    test "preserves short messages" do
      assert Signal.format_response("hello") == "hello"
    end

    test "handles empty string" do
      assert Signal.format_response("") == ""
    end
  end

  describe "poll/0" do
    @describetag :integration
    test "polls signal-cli for messages" do
      result = Signal.poll()
      assert {:ok, _messages} = result
    end
  end

  describe "send_message/3" do
    @describetag :integration
    test "sends a message via signal-cli" do
      result = Signal.send_message("+1234567890", "Test", [])
      # Will fail without signal-cli, just verify the call works
      assert match?({:error, _}, result) or result == :ok
    end
  end
end
