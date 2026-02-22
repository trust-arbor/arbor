defmodule Arbor.Memory.ChatHistoryTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.ChatHistory

  setup do
    # Clean up any existing data
    ChatHistory.clear("test_agent")
    :ok
  end

  describe "append/2" do
    test "appends a message with auto-generated id" do
      msg = %{role: "user", content: "Hello", timestamp: DateTime.utc_now()}
      assert :ok = ChatHistory.append("test_agent", msg)

      messages = ChatHistory.load("test_agent")
      assert length(messages) == 1
      assert hd(messages).role == "user"
      assert hd(messages).content == "Hello"
      assert is_binary(hd(messages).id)
    end

    test "preserves existing message id" do
      msg = %{id: "msg_123", role: "assistant", content: "Hi", timestamp: DateTime.utc_now()}
      assert :ok = ChatHistory.append("test_agent", msg)

      messages = ChatHistory.load("test_agent")
      assert length(messages) == 1
      assert hd(messages).id == "msg_123"
    end

    test "appends multiple messages" do
      msg1 = %{role: "user", content: "Hello", timestamp: DateTime.utc_now()}
      msg2 = %{role: "assistant", content: "Hi there", timestamp: DateTime.utc_now()}

      ChatHistory.append("test_agent", msg1)
      ChatHistory.append("test_agent", msg2)

      messages = ChatHistory.load("test_agent")
      assert length(messages) == 2
    end
  end

  describe "load/1" do
    test "returns empty list for unknown agent" do
      assert [] = ChatHistory.load("unknown_agent")
    end

    test "returns messages sorted by timestamp" do
      t1 = DateTime.utc_now()
      t2 = DateTime.add(t1, 1, :second)
      t3 = DateTime.add(t1, 2, :second)

      # Add out of order
      ChatHistory.append("test_agent", %{role: "user", content: "Second", timestamp: t2})
      ChatHistory.append("test_agent", %{role: "user", content: "Third", timestamp: t3})
      ChatHistory.append("test_agent", %{role: "user", content: "First", timestamp: t1})

      messages = ChatHistory.load("test_agent")
      assert length(messages) == 3
      assert Enum.at(messages, 0).content == "First"
      assert Enum.at(messages, 1).content == "Second"
      assert Enum.at(messages, 2).content == "Third"
    end
  end

  describe "clear/1" do
    test "removes all messages for agent" do
      msg = %{role: "user", content: "Hello", timestamp: DateTime.utc_now()}
      ChatHistory.append("test_agent", msg)
      ChatHistory.append("test_agent", msg)

      assert length(ChatHistory.load("test_agent")) == 2

      ChatHistory.clear("test_agent")
      assert [] = ChatHistory.load("test_agent")
    end

    test "does not affect other agents" do
      msg1 = %{role: "user", content: "Agent 1", timestamp: DateTime.utc_now()}
      msg2 = %{role: "user", content: "Agent 2", timestamp: DateTime.utc_now()}

      ChatHistory.append("agent_1", msg1)
      ChatHistory.append("agent_2", msg2)

      ChatHistory.clear("agent_1")

      assert [] = ChatHistory.load("agent_1")
      assert length(ChatHistory.load("agent_2")) == 1
    end
  end

  describe "load_recent/2" do
    setup do
      agent_id = "test_agent_recent"
      ChatHistory.clear(agent_id)
      t0 = DateTime.utc_now()

      # Insert 10 messages with 1-second gaps
      ids =
        for i <- 1..10 do
          id = "msg_#{i}"

          ChatHistory.append(agent_id, %{
            id: id,
            role: "user",
            content: "Message #{i}",
            timestamp: DateTime.add(t0, i, :second)
          })

          id
        end

      on_exit(fn -> ChatHistory.clear(agent_id) end)
      %{agent_id: agent_id, ids: ids}
    end

    test "returns the most recent N messages with default limit", %{agent_id: agent_id} do
      messages = ChatHistory.load_recent(agent_id)
      # Default limit is 50, we only have 10
      assert length(messages) == 10
    end

    test "respects custom limit", %{agent_id: agent_id} do
      messages = ChatHistory.load_recent(agent_id, limit: 3)
      assert length(messages) == 3
      # Should be the last 3 messages (8, 9, 10)
      assert Enum.at(messages, 0).content == "Message 8"
      assert Enum.at(messages, 1).content == "Message 9"
      assert Enum.at(messages, 2).content == "Message 10"
    end

    test "returns messages in ascending order (oldest first)", %{agent_id: agent_id} do
      messages = ChatHistory.load_recent(agent_id, limit: 5)
      contents = Enum.map(messages, & &1.content)
      assert contents == ["Message 6", "Message 7", "Message 8", "Message 9", "Message 10"]
    end

    test "with :before cursor returns messages older than cursor", %{agent_id: agent_id} do
      # Cursor = msg_8, so we should get messages before msg_8's timestamp
      messages = ChatHistory.load_recent(agent_id, limit: 3, before: "msg_8")
      assert length(messages) == 3
      # Should be messages 5, 6, 7 (last 3 before msg_8)
      assert Enum.at(messages, 0).content == "Message 5"
      assert Enum.at(messages, 1).content == "Message 6"
      assert Enum.at(messages, 2).content == "Message 7"
    end

    test "with :before cursor and small limit", %{agent_id: agent_id} do
      messages = ChatHistory.load_recent(agent_id, limit: 2, before: "msg_5")
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "Message 3"
      assert Enum.at(messages, 1).content == "Message 4"
    end

    test "with :before cursor pointing to first message returns empty", %{agent_id: agent_id} do
      messages = ChatHistory.load_recent(agent_id, limit: 5, before: "msg_1")
      assert messages == []
    end

    test "with :before cursor for unknown id ignores the filter", %{agent_id: agent_id} do
      messages = ChatHistory.load_recent(agent_id, limit: 3, before: "nonexistent")
      assert length(messages) == 3
    end

    test "returns empty for unknown agent" do
      assert [] = ChatHistory.load_recent("unknown_agent_recent")
    end
  end

  describe "count/1" do
    test "returns 0 for unknown agent" do
      assert ChatHistory.count("unknown_agent_count") == 0
    end

    test "returns correct count after appending" do
      agent_id = "test_agent_count"
      ChatHistory.clear(agent_id)

      assert ChatHistory.count(agent_id) == 0

      for i <- 1..5 do
        ChatHistory.append(agent_id, %{
          role: "user",
          content: "Msg #{i}",
          timestamp: DateTime.utc_now()
        })
      end

      assert ChatHistory.count(agent_id) == 5
      ChatHistory.clear(agent_id)
    end
  end

  describe "message cap" do
    test "trims messages when exceeding 500" do
      agent_id = "test_agent_cap"

      # Add 510 messages
      for i <- 1..510 do
        msg = %{
          role: "user",
          content: "Message #{i}",
          timestamp: DateTime.add(DateTime.utc_now(), i, :second)
        }

        ChatHistory.append(agent_id, msg)
      end

      messages = ChatHistory.load(agent_id)
      assert length(messages) == 500

      # Should have kept the most recent 500
      first_msg = hd(messages)
      assert first_msg.content == "Message 11"

      ChatHistory.clear(agent_id)
    end
  end
end
