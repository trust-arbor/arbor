defmodule Arbor.Comms.ConversationBufferTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.ConversationBuffer
  alias Arbor.Contracts.Comms.Message

  @test_log_dir "/tmp/arbor/test_conv_buffer"
  @contact "+1234567890"

  setup do
    Application.put_env(:arbor_comms, :test_conv, log_dir: @test_log_dir)
    File.rm_rf(@test_log_dir)

    on_exit(fn ->
      File.rm_rf(@test_log_dir)
      Application.delete_env(:arbor_comms, :test_conv)
    end)

    :ok
  end

  describe "recent_turns/3" do
    test "returns empty list when no log exists" do
      assert ConversationBuffer.recent_turns(:test_conv, @contact) == []
    end

    test "parses inbound messages as :user turns" do
      msg =
        Message.new(
          channel: :test_conv,
          from: @contact,
          content: "Hello there",
          direction: :inbound
        )

      ChatLogger.log_message(msg)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)
      assert [{:user, "Hello there"}] = turns
    end

    test "parses outbound messages as :assistant turns" do
      msg = Message.outbound(:test_conv, @contact, "Hi back")
      ChatLogger.log_message(msg)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)
      assert [{:assistant, "Hi back"}] = turns
    end

    test "returns conversation in order" do
      inbound =
        Message.new(
          channel: :test_conv,
          from: @contact,
          content: "What is Arbor?",
          direction: :inbound
        )

      outbound = Message.outbound(:test_conv, @contact, "A distributed AI system")

      ChatLogger.log_message(inbound)
      ChatLogger.log_message(outbound)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)

      assert [
               {:user, "What is Arbor?"},
               {:assistant, "A distributed AI system"}
             ] = turns
    end

    test "respects window size" do
      for i <- 1..10 do
        msg =
          Message.new(
            channel: :test_conv,
            from: @contact,
            content: "Message #{i}",
            direction: :inbound
          )

        ChatLogger.log_message(msg)
      end

      turns = ConversationBuffer.recent_turns(:test_conv, @contact, 3)
      assert length(turns) == 3
      assert {:user, "Message 10"} = List.last(turns)
    end

    test "filters by contact" do
      msg1 =
        Message.new(
          channel: :test_conv,
          from: @contact,
          content: "From target",
          direction: :inbound
        )

      msg2 =
        Message.new(
          channel: :test_conv,
          from: "+9999999999",
          content: "From other",
          direction: :inbound
        )

      ChatLogger.log_message(msg1)
      ChatLogger.log_message(msg2)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)
      assert [{:user, "From target"}] = turns
    end
  end
end
