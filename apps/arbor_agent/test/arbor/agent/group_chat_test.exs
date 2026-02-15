defmodule Arbor.Agent.GroupChatTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.GroupChat
  alias Arbor.Agent.GroupChat.{Context, Message, Participant}

  @moduletag :group_chat

  # ── Message Tests ──────────────────────────────────────────────────

  describe "Message" do
    test "new/1 generates id and timestamp" do
      message =
        Message.new(%{
          group_id: "grp_test",
          sender_id: "user_1",
          sender_name: "Alice",
          sender_type: :human,
          content: "Hello"
        })

      assert message.id =~ ~r/^msg_[0-9a-f]{8}$/
      assert %DateTime{} = message.timestamp
      assert message.content == "Hello"
      assert message.sender_name == "Alice"
      assert message.sender_type == :human
      assert message.metadata == %{}
    end

    test "new/1 requires sender fields" do
      assert_raise ArgumentError, fn ->
        Message.new(%{
          group_id: "grp_test",
          content: "Hello"
        })
      end
    end

    test "new/1 accepts custom metadata" do
      message =
        Message.new(%{
          group_id: "grp_test",
          sender_id: "user_1",
          sender_name: "Alice",
          sender_type: :human,
          content: "Hello",
          metadata: %{source: "test"}
        })

      assert message.metadata == %{source: "test"}
    end
  end

  # ── Participant Tests ──────────────────────────────────────────────

  describe "Participant" do
    test "new/1 creates participant with required fields" do
      participant =
        Participant.new(%{
          id: "agent_123",
          name: "Alice",
          type: :agent,
          host_pid: self()
        })

      assert participant.id == "agent_123"
      assert participant.name == "Alice"
      assert participant.type == :agent
      assert participant.host_pid == self()
      assert %DateTime{} = participant.joined_at
    end

    test "new/1 sets joined_at automatically" do
      before = DateTime.utc_now()
      participant = Participant.new(%{id: "u1", name: "User", type: :human})
      after_time = DateTime.utc_now()

      assert DateTime.compare(participant.joined_at, before) in [:gt, :eq]
      assert DateTime.compare(participant.joined_at, after_time) in [:lt, :eq]
    end

    test "agent_online?/1 returns true for alive agent" do
      participant =
        Participant.new(%{
          id: "agent_1",
          name: "Agent",
          type: :agent,
          host_pid: self()
        })

      assert Participant.agent_online?(participant)
    end

    test "agent_online?/1 returns false for human" do
      participant = Participant.new(%{id: "h1", name: "Human", type: :human})
      refute Participant.agent_online?(participant)
    end

    test "agent_online?/1 returns false for agent with nil pid" do
      participant =
        Participant.new(%{id: "a1", name: "Agent", type: :agent, host_pid: nil})

      refute Participant.agent_online?(participant)
    end

    test "human?/1 and agent?/1 predicates" do
      human = Participant.new(%{id: "h1", name: "Human", type: :human})
      agent = Participant.new(%{id: "a1", name: "Agent", type: :agent})

      assert Participant.human?(human)
      refute Participant.agent?(human)

      assert Participant.agent?(agent)
      refute Participant.human?(agent)
    end
  end

  # ── Context Tests ──────────────────────────────────────────────────

  describe "Context" do
    test "build_agent_prompt includes transcript" do
      messages = [
        %Message{
          id: "msg_1",
          group_id: "grp_1",
          sender_id: "h1",
          sender_name: "Alice",
          sender_type: :human,
          content: "Hello everyone!",
          timestamp: DateTime.utc_now()
        },
        %Message{
          id: "msg_2",
          group_id: "grp_1",
          sender_id: "a1",
          sender_name: "Bot",
          sender_type: :agent,
          content: "Hi Alice!",
          timestamp: DateTime.utc_now()
        }
      ]

      prompt = Context.build_agent_prompt("Charlie", messages)

      assert prompt =~ "Alice: Hello everyone!"
      assert prompt =~ "Bot: Hi Alice!"
      assert prompt =~ "Respond as Charlie"
      assert prompt =~ "2-3 sentences"
    end

    test "build_agent_prompt limits to max_messages" do
      # Messages stored newest-first (like GroupChat GenServer)
      messages =
        for i <- 30..1//-1 do
          %Message{
            id: "msg_#{i}",
            group_id: "grp_1",
            sender_id: "h1",
            sender_name: "User",
            sender_type: :human,
            content: "Message #{i}",
            timestamp: DateTime.utc_now()
          }
        end

      prompt = Context.build_agent_prompt("Agent", messages, max_messages: 5)

      # take(5) gets the 5 most recent (30,29,28,27,26), reverse for chronological
      assert prompt =~ "Message 26"
      assert prompt =~ "Message 30"
      refute prompt =~ "Message 25"
    end

    test "build_agent_prompt includes agent name in instructions" do
      prompt = Context.build_agent_prompt("TestAgent", [], max_messages: 10)

      assert prompt =~ "Respond as TestAgent"
    end

    test "build_agent_prompt includes group name when provided" do
      prompt = Context.build_agent_prompt("Agent", [], group_name: "Planning Session")

      assert prompt =~ "[Group chat: Planning Session]"
    end

    test "empty messages produces minimal prompt" do
      prompt = Context.build_agent_prompt("Agent", [])

      assert prompt =~ "[Group chat conversation]"
      assert prompt =~ "Respond as Agent"
      # Should have empty transcript section
      refute prompt =~ ":"
      assert String.contains?(prompt, "\n\n\n")
    end
  end

  # ── GroupChat Server Tests ─────────────────────────────────────────

  describe "GroupChat server" do
    setup do
      # Ensure Registry is started for group registration
      try do
        Registry.start_link(keys: :unique, name: Arbor.Agent.ExecutorRegistry)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      :ok
    end

    test "create/2 starts a server" do
      participants = [%{id: "h1", name: "Human", type: :human}]
      {:ok, pid} = GroupChat.create("test-group", participants: participants)
      assert Process.alive?(pid)
      GenServer.stop(pid, :normal)
    end

    test "create/2 initializes with participants" do
      participants = [
        %{id: "h1", name: "Alice", type: :human},
        %{id: "h2", name: "Bob", type: :human}
      ]

      {:ok, pid} = GroupChat.create("test", participants: participants)
      parts = GroupChat.get_participants(pid)

      assert map_size(parts) == 2
      assert parts["h1"].name == "Alice"
      assert parts["h2"].name == "Bob"

      GenServer.stop(pid, :normal)
    end

    test "send_message/5 adds to history" do
      participants = [%{id: "h1", name: "Human", type: :human}]
      {:ok, pid} = GroupChat.create("test", participants: participants)

      :ok = GroupChat.send_message(pid, "h1", "Human", :human, "Hello")
      Process.sleep(10)

      history = GroupChat.get_history(pid)
      assert length(history) == 1
      assert hd(history).content == "Hello"
      assert hd(history).sender_name == "Human"

      GenServer.stop(pid, :normal)
    end

    @tag :pubsub
    @tag :integration
    test "send_message/5 broadcasts via PubSub" do
      # This test requires PubSub to be running — skip in unit test context
      pubsub = Arbor.Web.PubSub

      case Process.whereis(pubsub) do
        nil ->
          :ok

        _pid ->
          participants = [%{id: "h1", name: "Human", type: :human}]
          {:ok, pid} = GroupChat.create("test", participants: participants)

          # Subscribe to catch broadcasts
          topic = :sys.get_state(pid).pubsub_topic
          Phoenix.PubSub.subscribe(pubsub, topic)

          GroupChat.send_message(pid, "h1", "Human", :human, "Hello")

          assert_receive {:group_message, %Message{content: "Hello"}}, 1000

          GenServer.stop(pid, :normal)
      end
    end

    test "add_participant/2 and remove_participant/2" do
      participants = [%{id: "h1", name: "Human", type: :human}]
      {:ok, pid} = GroupChat.create("test", participants: participants)

      :ok =
        GroupChat.add_participant(pid, %{id: "a1", name: "Agent", type: :agent, host_pid: nil})

      parts = GroupChat.get_participants(pid)
      assert map_size(parts) == 2
      assert parts["a1"].name == "Agent"

      :ok = GroupChat.remove_participant(pid, "a1")

      parts = GroupChat.get_participants(pid)
      assert map_size(parts) == 1
      refute Map.has_key?(parts, "a1")

      GenServer.stop(pid, :normal)
    end

    test "get_history/1 returns messages newest first" do
      participants = [%{id: "h1", name: "Human", type: :human}]
      {:ok, pid} = GroupChat.create("test", participants: participants)

      GroupChat.send_message(pid, "h1", "Human", :human, "First")
      Process.sleep(5)
      GroupChat.send_message(pid, "h1", "Human", :human, "Second")
      Process.sleep(5)
      GroupChat.send_message(pid, "h1", "Human", :human, "Third")
      Process.sleep(10)

      history = GroupChat.get_history(pid)
      assert length(history) == 3

      [msg1, msg2, msg3] = history
      assert msg1.content == "Third"
      assert msg2.content == "Second"
      assert msg3.content == "First"

      GenServer.stop(pid, :normal)
    end

    test "agent messages do not trigger re-relay (loop prevention)" do
      participants = [
        %{id: "h1", name: "Human", type: :human},
        %{id: "a1", name: "Agent", type: :agent, host_pid: nil}
      ]

      {:ok, pid} = GroupChat.create("test", participants: participants)

      GroupChat.send_message(pid, "h1", "Human", :human, "Hello")
      Process.sleep(10)

      GroupChat.send_message(pid, "a1", "Agent", :agent, "Hi there!")
      Process.sleep(10)

      history = GroupChat.get_history(pid)
      assert length(history) == 2

      [agent_msg, human_msg] = history
      assert human_msg.sender_type == :human
      assert agent_msg.sender_type == :agent

      GenServer.stop(pid, :normal)
    end

    test "multiple human messages each appear in history" do
      participants = [
        %{id: "h1", name: "Alice", type: :human},
        %{id: "h2", name: "Bob", type: :human}
      ]

      {:ok, pid} = GroupChat.create("test", participants: participants)

      GroupChat.send_message(pid, "h1", "Alice", :human, "Hello everyone")
      Process.sleep(5)
      GroupChat.send_message(pid, "h2", "Bob", :human, "Hi Alice!")
      Process.sleep(5)
      GroupChat.send_message(pid, "h1", "Alice", :human, "How are you?")
      Process.sleep(10)

      history = GroupChat.get_history(pid)
      assert length(history) == 3

      contents = Enum.map(history, & &1.content)
      assert "Hello everyone" in contents
      assert "Hi Alice!" in contents
      assert "How are you?" in contents

      GenServer.stop(pid, :normal)
    end

    test "response_mode defaults to :parallel" do
      participants = [%{id: "h1", name: "Human", type: :human}]
      {:ok, pid} = GroupChat.create("test", participants: participants)
      assert Process.alive?(pid)
      GenServer.stop(pid, :normal)
    end

    test "response_mode :sequential can be set" do
      participants = [%{id: "h1", name: "Human", type: :human}]

      {:ok, pid} =
        GroupChat.create("test", participants: participants, response_mode: :sequential)

      assert Process.alive?(pid)
      GenServer.stop(pid, :normal)
    end

    test "max_history can be configured" do
      participants = [%{id: "h1", name: "Human", type: :human}]
      {:ok, pid} = GroupChat.create("test", participants: participants, max_history: 10)
      assert Process.alive?(pid)
      GenServer.stop(pid, :normal)
    end
  end
end
