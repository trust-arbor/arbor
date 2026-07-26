defmodule Arbor.CommsTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms
  alias Arbor.Comms.PresenceTracker

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

  describe "interaction presence facade" do
    test "tracks and untracks a caller without exposing PresenceTracker" do
      user_id = "user_comms_facade_#{System.unique_integer([:positive])}"
      metadata = %{session_id: "session-facade"}

      assert {:ok, _ref} = Comms.track_presence(self(), user_id, :dashboard, metadata)

      assert_eventually(fn ->
        match?(
          [{:dashboard, %{session_id: "session-facade", joined_at: joined_at}}]
          when is_integer(joined_at),
          PresenceTracker.active_channels(user_id)
        )
      end)

      assert :ok = Comms.untrack_presence(self(), user_id, :dashboard)
      assert_eventually(fn -> PresenceTracker.active_channels(user_id) == [] end)
    end
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        receive do
        after
          10 -> do_assert_eventually(fun, deadline)
        end
    end
  end
end
