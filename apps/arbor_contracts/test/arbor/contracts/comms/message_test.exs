defmodule Arbor.Contracts.Comms.MessageTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Comms.Message

  describe "new/1" do
    test "creates inbound message with defaults" do
      msg = Message.new(channel: :signal, from: "+1234", content: "Hello")
      assert %Message{} = msg
      assert msg.channel == :signal
      assert msg.from == "+1234"
      assert msg.content == "Hello"
      assert msg.direction == :inbound
      assert String.starts_with?(msg.id, "msg_")
      assert %DateTime{} = msg.received_at
      assert msg.content_type == :text
      assert msg.metadata == %{}
    end

    test "accepts all optional fields" do
      msg =
        Message.new(
          channel: :email,
          from: "user@example.com",
          content: "Report",
          to: "admin@example.com",
          direction: :outbound,
          content_type: :markdown,
          reply_to: "msg_123",
          conversation_id: "conv_456",
          metadata: %{subject: "Weekly Report"}
        )

      assert msg.to == "admin@example.com"
      assert msg.direction == :outbound
      assert msg.content_type == :markdown
      assert msg.reply_to == "msg_123"
      assert msg.conversation_id == "conv_456"
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        Message.new(channel: :signal, from: "+1234")
      end
    end
  end

  describe "outbound/4" do
    test "creates outbound message" do
      msg = Message.outbound(:signal, "+1234", "Hello there")
      assert msg.channel == :signal
      assert msg.direction == :outbound
      assert msg.from == "arbor"
      assert msg.to == "+1234"
      assert msg.content == "Hello there"
    end

    test "accepts additional opts" do
      msg = Message.outbound(:email, "user@ex.com", "Report", content_type: :markdown)
      assert msg.content_type == :markdown
    end
  end
end
