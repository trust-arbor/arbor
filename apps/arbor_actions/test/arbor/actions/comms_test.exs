defmodule Arbor.Actions.CommsTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Comms.PollMessages
  alias Arbor.Actions.Comms.SendMessage
  alias Arbor.Actions.Support.MockChannelReceiver
  alias Arbor.Actions.Support.MockChannelSender
  alias Arbor.Contracts.Comms.Message

  setup do
    original_senders = Application.get_env(:arbor_actions, :channel_senders)
    original_receivers = Application.get_env(:arbor_actions, :channel_receivers)

    Application.put_env(:arbor_actions, :channel_senders, %{
      mock: MockChannelSender
    })

    Application.put_env(:arbor_actions, :channel_receivers, %{
      mock: MockChannelReceiver
    })

    on_exit(fn ->
      if original_senders do
        Application.put_env(:arbor_actions, :channel_senders, original_senders)
      else
        Application.delete_env(:arbor_actions, :channel_senders)
      end

      if original_receivers do
        Application.put_env(:arbor_actions, :channel_receivers, original_receivers)
      else
        Application.delete_env(:arbor_actions, :channel_receivers)
      end
    end)

    :ok
  end

  # ============================================================================
  # SendMessage
  # ============================================================================

  describe "SendMessage metadata" do
    test "has correct action metadata" do
      assert SendMessage.name() == "comms_send_message"
      assert SendMessage.category() == "comms"
    end

    test "generates tool schema" do
      tool = SendMessage.to_tool()
      assert is_map(tool)
      assert tool[:name] == "comms_send_message"
    end
  end

  describe "SendMessage.run/2" do
    test "sends message through resolved channel" do
      params = %{channel: :mock, to: "+15551234567", message: "Hello!"}
      assert {:ok, result} = SendMessage.run(params, %{})
      assert result.channel == :mock
      assert result.to == "+15551234567"
      assert result.status == :sent

      assert_received {:mock_send, "+15551234567", "Hello!", []}
    end

    test "passes opts through to channel" do
      params = %{
        channel: :mock,
        to: "user@example.com",
        message: "Report ready",
        subject: "Daily Report",
        from: "arbor@example.com",
        attachments: ["/tmp/report.pdf"]
      }

      assert {:ok, _result} = SendMessage.run(params, %{})

      assert_received {:mock_send, "user@example.com", "Report ready", opts}
      assert opts[:subject] == "Daily Report"
      assert opts[:from] == "arbor@example.com"
      assert opts[:attachments] == ["/tmp/report.pdf"]
    end

    test "formats message by default" do
      long = String.duplicate("a", 200)
      params = %{channel: :mock, to: "someone", message: long}

      assert {:ok, _result} = SendMessage.run(params, %{})

      assert_received {:mock_send, "someone", formatted, []}
      assert String.length(formatted) == 100
      assert String.ends_with?(formatted, "...")
    end

    test "skips formatting when format: false" do
      long = String.duplicate("a", 200)
      params = %{channel: :mock, to: "someone", message: long, format: false}

      assert {:ok, _result} = SendMessage.run(params, %{})

      assert_received {:mock_send, "someone", ^long, []}
    end

    test "returns error for unknown channel" do
      params = %{channel: :nonexistent, to: "someone", message: "Hi"}
      assert {:error, msg} = SendMessage.run(params, %{})
      assert msg =~ "Unknown channel :nonexistent"
      assert msg =~ "mock"
    end

    test "returns error when send fails" do
      Process.put(:mock_send_result, {:error, :connection_failed})
      params = %{channel: :mock, to: "someone", message: "Hi"}

      assert {:error, msg} = SendMessage.run(params, %{})
      assert msg =~ "Send failed on mock"
      assert msg =~ "connection_failed"
    end

    test "omits nil opts" do
      params = %{channel: :mock, to: "someone", message: "Hi", subject: nil, from: nil}
      assert {:ok, _} = SendMessage.run(params, %{})

      assert_received {:mock_send, "someone", "Hi", opts}
      refute Keyword.has_key?(opts, :subject)
      refute Keyword.has_key?(opts, :from)
    end

    test "omits empty attachments" do
      params = %{channel: :mock, to: "someone", message: "Hi", attachments: []}
      assert {:ok, _} = SendMessage.run(params, %{})

      assert_received {:mock_send, "someone", "Hi", opts}
      refute Keyword.has_key?(opts, :attachments)
    end
  end

  # ============================================================================
  # PollMessages
  # ============================================================================

  describe "PollMessages metadata" do
    test "has correct action metadata" do
      assert PollMessages.name() == "comms_poll_messages"
      assert PollMessages.category() == "comms"
    end

    test "generates tool schema" do
      tool = PollMessages.to_tool()
      assert is_map(tool)
      assert tool[:name] == "comms_poll_messages"
    end
  end

  describe "PollMessages.run/2" do
    test "polls channel and returns messages" do
      messages = [
        Message.new(channel: :mock, from: "sender1", content: "Hello"),
        Message.new(channel: :mock, from: "sender2", content: "World")
      ]

      Process.put(:mock_poll_result, {:ok, messages})

      params = %{channel: :mock}
      assert {:ok, result} = PollMessages.run(params, %{})
      assert result.channel == :mock
      assert result.message_count == 2
      assert length(result.messages) == 2
    end

    test "respects max_messages limit" do
      messages =
        for i <- 1..15 do
          Message.new(channel: :mock, from: "sender#{i}", content: "msg #{i}")
        end

      Process.put(:mock_poll_result, {:ok, messages})

      params = %{channel: :mock, max_messages: 5}
      assert {:ok, result} = PollMessages.run(params, %{})
      assert result.message_count == 5
      assert length(result.messages) == 5
    end

    test "returns error for unknown channel" do
      params = %{channel: :nonexistent}
      assert {:error, msg} = PollMessages.run(params, %{})
      assert msg =~ "Unknown channel :nonexistent"
      assert msg =~ "mock"
    end

    test "returns error when poll fails" do
      Process.put(:mock_poll_result, {:error, :api_unavailable})

      params = %{channel: :mock}
      assert {:error, msg} = PollMessages.run(params, %{})
      assert msg =~ "Poll failed on mock"
      assert msg =~ "api_unavailable"
    end

    test "returns empty list when no messages" do
      Process.put(:mock_poll_result, {:ok, []})

      params = %{channel: :mock}
      assert {:ok, result} = PollMessages.run(params, %{})
      assert result.message_count == 0
      assert result.messages == []
    end
  end
end
