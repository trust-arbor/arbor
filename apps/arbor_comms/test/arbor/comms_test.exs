defmodule Arbor.CommsTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms

  describe "channels/0" do
    test "returns list of enabled channels" do
      channels = Comms.channels()
      assert is_list(channels)
    end
  end

  describe "channel_info/1" do
    test "returns info for known channel" do
      info = Comms.channel_info(:signal)
      assert info.name == :signal
      assert is_integer(info.max_message_length)
    end

    test "returns error for unknown channel" do
      assert {:error, :unknown_channel} = Comms.channel_info(:nonexistent)
    end
  end

  describe "healthy?/0" do
    test "returns true" do
      assert Comms.healthy?()
    end
  end

  describe "send/4" do
    test "returns error for unknown channel" do
      assert {:error, {:unknown_channel, :nonexistent}} =
               Comms.send(:nonexistent, "+1234", "hello")
    end
  end

  describe "poll/1" do
    test "returns error for unknown channel" do
      assert {:error, {:unknown_channel, :nonexistent}} =
               Comms.poll(:nonexistent)
    end
  end

  describe "recent_messages/2" do
    test "returns empty list for channel with no history" do
      assert {:ok, []} = Comms.recent_messages(:nonexistent_channel)
    end
  end
end
