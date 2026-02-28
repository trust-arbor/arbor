defmodule Arbor.Comms.ChannelTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.Channel

  @moduletag :fast

  setup do
    # Registry is started by Arbor.Comms.Supervisor at app boot.
    # If not running (e.g., isolated test), start it.
    unless Process.whereis(Arbor.Comms.ChannelRegistry) do
      start_supervised!({Registry, keys: :unique, name: Arbor.Comms.ChannelRegistry})
    end

    :ok
  end

  defp start_channel(opts \\ []) do
    channel_id = Keyword.get(opts, :channel_id, "chan_test_#{System.unique_integer([:positive])}")

    defaults = [
      channel_id: channel_id,
      name: "Test Channel",
      type: :group,
      members: [%{id: "user_1", name: "User One", type: :human}],
      rate_limit_ms: 0
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, pid} = start_supervised({Channel, merged}, id: channel_id)
    {pid, channel_id}
  end

  describe "start_link/1" do
    test "starts a channel with default options" do
      {pid, channel_id} = start_channel()
      assert Process.alive?(pid)

      info = Channel.channel_info(pid)
      assert info.channel_id == channel_id
      assert info.name == "Test Channel"
      assert info.type == :group
      assert info.member_count == 1
    end

    test "starts with custom type and owner" do
      {pid, _} = start_channel(type: :ops_room, owner_id: "admin_1")

      info = Channel.channel_info(pid)
      assert info.type == :ops_room
      assert info.owner_id == "admin_1"
    end

    test "registers via ChannelRegistry" do
      {_pid, channel_id} = start_channel()

      assert [{pid, _}] = Registry.lookup(Arbor.Comms.ChannelRegistry, channel_id)
      assert Process.alive?(pid)
    end

    test "auto-generates channel_id if not provided" do
      {:ok, pid} =
        start_supervised(
          {Channel, name: "Auto ID", type: :group, members: []},
          id: :auto_id_test
        )

      info = Channel.channel_info(pid)
      assert String.starts_with?(info.channel_id, "chan_")
    end
  end

  describe "send_message/6" do
    test "sends a message from a member" do
      {pid, _} = start_channel()

      assert {:ok, message} =
               Channel.send_message(pid, "user_1", "User One", :human, "Hello!")

      assert message.content == "Hello!"
      assert message.sender_id == "user_1"
      assert message.sender_name == "User One"
      assert message.sender_type == :human
      assert String.starts_with?(message.id, "msg_")
      assert %DateTime{} = message.timestamp
    end

    test "rejects message from non-member" do
      {pid, _} = start_channel()

      assert {:error, :not_member} =
               Channel.send_message(pid, "unknown", "Nobody", :human, "Hi")
    end

    test "rate limits rapid messages" do
      {pid, _} = start_channel(rate_limit_ms: 5000)

      assert {:ok, _} = Channel.send_message(pid, "user_1", "User One", :human, "First")
      assert {:error, :rate_limited} = Channel.send_message(pid, "user_1", "User One", :human, "Second")
    end

    test "allows messages after rate limit expires" do
      {pid, _} = start_channel(rate_limit_ms: 50)

      assert {:ok, _} = Channel.send_message(pid, "user_1", "User One", :human, "First")
      Process.sleep(60)
      assert {:ok, _} = Channel.send_message(pid, "user_1", "User One", :human, "Second")
    end

    test "includes metadata in message" do
      {pid, _} = start_channel()

      assert {:ok, message} =
               Channel.send_message(pid, "user_1", "User One", :human, "Hello!", %{priority: "high"})

      assert message.metadata == %{priority: "high"}
    end
  end

  describe "add_member/2" do
    test "adds a new member" do
      {pid, _} = start_channel()

      assert :ok = Channel.add_member(pid, %{id: "user_2", name: "User Two", type: :human})

      members = Channel.get_members(pid)
      assert length(members) == 2
      assert Enum.any?(members, &(&1.id == "user_2"))
    end

    test "rejects duplicate member" do
      {pid, _} = start_channel()

      assert {:error, :already_member} =
               Channel.add_member(pid, %{id: "user_1", name: "User One", type: :human})
    end

    test "added member can send messages" do
      {pid, _} = start_channel()

      Channel.add_member(pid, %{id: "agent_1", name: "Agent", type: :agent})
      assert {:ok, _} = Channel.send_message(pid, "agent_1", "Agent", :agent, "Hello from agent")
    end
  end

  describe "remove_member/2" do
    test "removes an existing member" do
      {pid, _} = start_channel(members: [
        %{id: "user_1", name: "User One", type: :human},
        %{id: "user_2", name: "User Two", type: :human}
      ])

      assert :ok = Channel.remove_member(pid, "user_2")

      members = Channel.get_members(pid)
      assert length(members) == 1
      refute Enum.any?(members, &(&1.id == "user_2"))
    end

    test "rejects removal of non-member" do
      {pid, _} = start_channel()

      assert {:error, :not_member} = Channel.remove_member(pid, "nobody")
    end

    test "removed member cannot send messages" do
      {pid, _} = start_channel(members: [
        %{id: "user_1", name: "User One", type: :human},
        %{id: "user_2", name: "User Two", type: :human}
      ])

      Channel.remove_member(pid, "user_2")
      assert {:error, :not_member} = Channel.send_message(pid, "user_2", "User Two", :human, "Hi")
    end
  end

  describe "get_members/1" do
    test "returns member list with joined_at" do
      {pid, _} = start_channel()

      members = Channel.get_members(pid)
      assert length(members) == 1
      [member] = members
      assert member.id == "user_1"
      assert member.name == "User One"
      assert member.type == :human
      assert %DateTime{} = member.joined_at
    end
  end

  describe "get_history/2" do
    test "returns empty history for new channel" do
      {pid, _} = start_channel()
      assert [] = Channel.get_history(pid)
    end

    test "returns messages in oldest-first order" do
      {pid, _} = start_channel()

      Channel.send_message(pid, "user_1", "User One", :human, "First")
      Channel.send_message(pid, "user_1", "User One", :human, "Second")
      Channel.send_message(pid, "user_1", "User One", :human, "Third")

      history = Channel.get_history(pid)
      assert length(history) == 3
      assert Enum.at(history, 0).content == "First"
      assert Enum.at(history, 1).content == "Second"
      assert Enum.at(history, 2).content == "Third"
    end

    test "respects limit option" do
      {pid, _} = start_channel()

      for i <- 1..10 do
        Channel.send_message(pid, "user_1", "User One", :human, "Message #{i}")
      end

      history = Channel.get_history(pid, limit: 3)
      assert length(history) == 3
    end

    test "respects max_history buffer size" do
      {pid, _} = start_channel(max_history: 5)

      for i <- 1..10 do
        Channel.send_message(pid, "user_1", "User One", :human, "Message #{i}")
      end

      history = Channel.get_history(pid, limit: 100)
      assert length(history) == 5
      # Should have the 5 most recent messages
      assert Enum.at(history, 0).content == "Message 6"
      assert Enum.at(history, 4).content == "Message 10"
    end
  end

  describe "channel_info/1" do
    test "returns channel metadata" do
      {pid, _} = start_channel(
        name: "Ops Room",
        type: :ops_room,
        owner_id: "admin_1"
      )

      info = Channel.channel_info(pid)
      assert info.name == "Ops Room"
      assert info.type == :ops_room
      assert info.owner_id == "admin_1"
      assert info.member_count == 1
      assert info.message_count == 0
      assert String.starts_with?(info.pubsub_topic, "channel:")
    end

    test "message_count reflects sent messages" do
      {pid, _} = start_channel()

      Channel.send_message(pid, "user_1", "User One", :human, "Hello")
      Channel.send_message(pid, "user_1", "User One", :human, "World")

      info = Channel.channel_info(pid)
      assert info.message_count == 2
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts channel_message on send" do
      {pid, channel_id} = start_channel()

      # Subscribe to channel topic
      pubsub = get_pubsub()

      if pubsub do
        Phoenix.PubSub.subscribe(pubsub, "channel:#{channel_id}")
        Channel.send_message(pid, "user_1", "User One", :human, "Hello PubSub!")

        assert_receive {:channel_message, message}, 1000
        assert message.content == "Hello PubSub!"
      end
    end

    test "broadcasts channel_member_joined on add" do
      {pid, channel_id} = start_channel()

      pubsub = get_pubsub()

      if pubsub do
        Phoenix.PubSub.subscribe(pubsub, "channel:#{channel_id}")
        Channel.add_member(pid, %{id: "user_2", name: "User Two", type: :human})

        assert_receive {:channel_member_joined, member}, 1000
        assert member.id == "user_2"
      end
    end

    test "broadcasts channel_member_left on remove" do
      {pid, channel_id} = start_channel(members: [
        %{id: "user_1", name: "User One", type: :human},
        %{id: "user_2", name: "User Two", type: :human}
      ])

      pubsub = get_pubsub()

      if pubsub do
        Phoenix.PubSub.subscribe(pubsub, "channel:#{channel_id}")
        Channel.remove_member(pid, "user_2")

        assert_receive {:channel_member_left, "user_2"}, 1000
      end
    end
  end

  describe "member type normalization" do
    test "accepts string types" do
      {pid, _} = start_channel(members: [
        %{"id" => "user_1", "name" => "User One", "type" => "human"}
      ])

      members = Channel.get_members(pid)
      assert length(members) == 1
      assert hd(members).type == :human
    end

    test "accepts atom types" do
      {pid, _} = start_channel(members: [
        %{id: "agent_1", name: "Agent", type: :agent}
      ])

      members = Channel.get_members(pid)
      assert hd(members).type == :agent
    end
  end

  # Helper to find PubSub module (may not be running in unit tests)
  defp get_pubsub do
    cond do
      Process.whereis(Arbor.Dashboard.PubSub) -> Arbor.Dashboard.PubSub
      Process.whereis(Arbor.Web.PubSub) -> Arbor.Web.PubSub
      true -> nil
    end
  end
end
