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
