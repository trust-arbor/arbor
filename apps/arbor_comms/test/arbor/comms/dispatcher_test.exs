defmodule Arbor.Comms.DispatcherTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Dispatcher
  alias Arbor.Contracts.Comms.Message

  describe "channel_module/1" do
    test "returns Signal module for :signal" do
      assert Dispatcher.channel_module(:signal) == Arbor.Comms.Channels.Signal
    end

    test "returns nil for unknown channel" do
      assert Dispatcher.channel_module(:nonexistent) == nil
    end
  end

  describe "send/4" do
    test "returns error for unknown channel" do
      assert {:error, {:unknown_channel, :nonexistent}} =
               Dispatcher.send(:nonexistent, "+1234", "hi")
    end
  end

  describe "reply/2" do
    test "returns error for unknown channel" do
      msg =
        Message.new(
          channel: :nonexistent,
          from: "+1234567890",
          content: "Hello"
        )

      assert {:error, {:unknown_channel, :nonexistent}} =
               Dispatcher.reply(msg, "response")
    end
  end
end
