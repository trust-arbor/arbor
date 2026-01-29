defmodule Arbor.Comms.Channels.LimitlessTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Channels.Limitless
  alias Arbor.Contracts.Comms.Message

  describe "channel_info/0" do
    test "returns limitless channel metadata" do
      info = Limitless.channel_info()
      assert info.name == :limitless
      assert info.max_message_length == :unlimited
      assert info.supports_media == false
      assert info.supports_threads == false
      assert info.latency == :polling
    end
  end

  describe "send_message/3" do
    test "returns not_supported error" do
      assert {:error, :not_supported} = Limitless.send_message("+1234567890", "Test", [])
    end
  end

  describe "format_response/1" do
    test "delegates to Signal format" do
      # Should truncate at Signal's 2000 char limit
      long = String.duplicate("a", 3000)
      result = Limitless.format_response(long)
      assert String.length(result) == 2000
      assert String.ends_with?(result, "...")
    end

    test "preserves short messages" do
      assert Limitless.format_response("hello") == "hello"
    end

    test "trims whitespace" do
      assert Limitless.format_response("  hello  ") == "hello"
    end
  end

  describe "send_response/2" do
    test "returns error when no response_recipient configured" do
      original_config = Application.get_env(:arbor_comms, :limitless, [])

      Application.put_env(
        :arbor_comms,
        :limitless,
        Keyword.drop(original_config, [:response_recipient])
      )

      msg =
        Message.new(
          channel: :limitless,
          from: "pendant",
          content: "test content",
          metadata: %{}
        )

      result = Limitless.send_response(msg, "response text")
      assert {:error, :no_response_recipient} = result

      Application.put_env(:arbor_comms, :limitless, original_config)
    end
  end

  describe "poll/0" do
    @describetag :integration

    test "polls Limitless API" do
      result = Limitless.poll()
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
