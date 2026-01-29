defmodule Arbor.Comms.ChatLoggerTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.ChatLogger
  alias Arbor.Contracts.Comms.Message

  @test_log_path "/tmp/arbor/test_chat_logger.log"

  setup do
    # Use a test-specific log path
    Application.put_env(:arbor_comms, :test_logger, log_path: @test_log_path)
    File.rm(@test_log_path)

    on_exit(fn ->
      File.rm(@test_log_path)
      Application.delete_env(:arbor_comms, :test_logger)
    end)

    :ok
  end

  describe "log_message/1" do
    test "logs inbound message to file" do
      # Configure test channel log path
      Application.put_env(:arbor_comms, :test_log, log_path: @test_log_path)

      msg =
        Message.new(
          channel: :test_log,
          from: "+1234567890",
          content: "Hello Arbor",
          direction: :inbound
        )

      assert :ok = ChatLogger.log_message(msg)
      assert {:ok, content} = File.read(@test_log_path)
      assert content =~ "<<<"
      assert content =~ "+1234567890"
      assert content =~ "Hello Arbor"
    after
      Application.delete_env(:arbor_comms, :test_log)
    end

    test "logs outbound message to file" do
      Application.put_env(:arbor_comms, :test_log, log_path: @test_log_path)

      msg = Message.outbound(:test_log, "+1234567890", "Hi there")

      assert :ok = ChatLogger.log_message(msg)
      assert {:ok, content} = File.read(@test_log_path)
      assert content =~ ">>>"
      assert content =~ "+1234567890"
      assert content =~ "Hi there"
    after
      Application.delete_env(:arbor_comms, :test_log)
    end
  end

  describe "recent/2" do
    test "returns empty list when no log exists" do
      assert {:ok, []} = ChatLogger.recent(:nonexistent_channel)
    end

    test "returns recent log lines" do
      Application.put_env(:arbor_comms, :test_log, log_path: @test_log_path)

      # Write some messages
      for i <- 1..5 do
        msg =
          Message.new(
            channel: :test_log,
            from: "+1234567890",
            content: "Message #{i}"
          )

        ChatLogger.log_message(msg)
      end

      assert {:ok, lines} = ChatLogger.recent(:test_log, 3)
      assert length(lines) == 3
      assert List.last(lines) =~ "Message 5"
    after
      Application.delete_env(:arbor_comms, :test_log)
    end
  end
end
