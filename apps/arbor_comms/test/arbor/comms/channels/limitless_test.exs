defmodule Arbor.Comms.Channels.LimitlessTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Channels.Limitless

  describe "channel_info/0" do
    test "returns limitless channel metadata" do
      info = Limitless.channel_info()
      assert info.name == :limitless
      assert info.max_message_length == :unlimited
      assert info.supports_media == false
      assert info.supports_threads == false
      assert info.supports_outbound == false
      assert info.latency == :polling
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
