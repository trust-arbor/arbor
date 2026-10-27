defmodule Arbor.Signals.ChannelTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Signals.Channel

  describe "new/4" do
    test "creates a channel with creator as first member" do
      channel = Channel.new("chan_123", "Test Channel", "agent_alice")

      assert channel.id == "chan_123"
      assert channel.name == "Test Channel"
      assert channel.creator_id == "agent_alice"
      assert MapSet.member?(channel.members, "agent_alice")
      assert MapSet.size(channel.members) == 1
      assert channel.key_version == 1
      assert %DateTime{} = channel.created_at
    end

    test "accepts metadata option" do
      channel = Channel.new("chan_456", "Private", "agent_bob", metadata: %{purpose: "testing"})

      assert channel.metadata == %{purpose: "testing"}
    end
  end

  describe "add_member/2" do
    test "adds a new member" do
      channel =
        Channel.new("chan_789", "Team", "agent_alice")
        |> Channel.add_member("agent_bob")

      assert MapSet.member?(channel.members, "agent_bob")
      assert MapSet.size(channel.members) == 2
    end

    test "adding same member twice is idempotent" do
      channel =
        Channel.new("chan_abc", "Team", "agent_alice")
        |> Channel.add_member("agent_bob")
        |> Channel.add_member("agent_bob")

      assert MapSet.size(channel.members) == 2
    end
  end

  describe "remove_member/2" do
    test "removes a member" do
      channel =
        Channel.new("chan_def", "Team", "agent_alice")
        |> Channel.add_member("agent_bob")
        |> Channel.remove_member("agent_bob")

      refute MapSet.member?(channel.members, "agent_bob")
      assert MapSet.size(channel.members) == 1
    end

    test "removing non-member is no-op" do
      channel =
        Channel.new("chan_ghi", "Team", "agent_alice")
        |> Channel.remove_member("agent_nonexistent")

      assert MapSet.size(channel.members) == 1
    end
  end

  describe "member?/2" do
    test "returns true for members" do
      channel = Channel.new("chan_jkl", "Team", "agent_alice")

      assert Channel.member?(channel, "agent_alice")
    end

    test "returns false for non-members" do
      channel = Channel.new("chan_mno", "Team", "agent_alice")

      refute Channel.member?(channel, "agent_bob")
    end
  end

  describe "increment_key_version/1" do
    test "increments the key version" do
      channel =
        Channel.new("chan_pqr", "Team", "agent_alice")
        |> Channel.increment_key_version()

      assert channel.key_version == 2
    end

    test "can increment multiple times" do
      channel =
        Channel.new("chan_stu", "Team", "agent_alice")
        |> Channel.increment_key_version()
        |> Channel.increment_key_version()

      assert channel.key_version == 3
    end
  end

  describe "topic_pattern/1" do
    test "returns the subscription pattern for the channel" do
      channel = Channel.new("chan_vwx", "Team", "agent_alice")

      assert Channel.topic_pattern(channel) == "channel.chan_vwx.*"
    end
  end

  describe "base_topic/1" do
    test "returns the base topic for publishing" do
      channel = Channel.new("chan_yza", "Team", "agent_alice")

      assert Channel.base_topic(channel) == "channel.chan_yza"
    end
  end
end
