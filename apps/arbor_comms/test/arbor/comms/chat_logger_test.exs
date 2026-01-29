defmodule Arbor.Comms.ChatLoggerTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.ChatLogger
  alias Arbor.Contracts.Comms.Message

  @test_log_dir "/tmp/arbor/test_chat_logger"

  setup do
    Application.put_env(:arbor_comms, :test_logger, log_dir: @test_log_dir)
    File.rm_rf(@test_log_dir)

    on_exit(fn ->
      File.rm_rf(@test_log_dir)
      Application.delete_env(:arbor_comms, :test_logger)
    end)

    :ok
  end

  describe "log_message/1" do
    test "logs inbound message to dated file" do
      Application.put_env(:arbor_comms, :test_log, log_dir: @test_log_dir)

      msg =
        Message.new(
          channel: :test_log,
          from: "+1234567890",
          content: "Hello Arbor",
          direction: :inbound
        )

      assert :ok = ChatLogger.log_message(msg)

      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")
      log_file = Path.join(@test_log_dir, "#{today}.log")

      assert {:ok, content} = File.read(log_file)
      assert content =~ "<<<"
      assert content =~ "+1234567890"
      assert content =~ "Hello Arbor"
    after
      Application.delete_env(:arbor_comms, :test_log)
    end

    test "logs outbound message to dated file" do
      Application.put_env(:arbor_comms, :test_log, log_dir: @test_log_dir)

      msg = Message.outbound(:test_log, "+1234567890", "Hi there")

      assert :ok = ChatLogger.log_message(msg)

      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")
      log_file = Path.join(@test_log_dir, "#{today}.log")

      assert {:ok, content} = File.read(log_file)
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

    test "returns recent log lines from today" do
      Application.put_env(:arbor_comms, :test_log, log_dir: @test_log_dir)

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

  describe "cleanup/1" do
    test "removes log files older than retention period" do
      Application.put_env(:arbor_comms, :test_cleanup,
        log_dir: @test_log_dir,
        log_retention_days: 7
      )

      File.mkdir_p!(@test_log_dir)

      # Create some old log files
      old_date = Date.utc_today() |> Date.add(-10)
      old_file = Path.join(@test_log_dir, "#{Date.to_iso8601(old_date)}.log")
      File.write!(old_file, "old data\n")

      # Create a recent log file
      recent_date = Date.utc_today() |> Date.add(-3)
      recent_file = Path.join(@test_log_dir, "#{Date.to_iso8601(recent_date)}.log")
      File.write!(recent_file, "recent data\n")

      # Create today's log
      today_file = Path.join(@test_log_dir, "#{Date.to_iso8601(Date.utc_today())}.log")
      File.write!(today_file, "today data\n")

      assert {:ok, 1} = ChatLogger.cleanup(:test_cleanup)

      # Old file should be gone
      refute File.exists?(old_file)
      # Recent and today files should remain
      assert File.exists?(recent_file)
      assert File.exists?(today_file)
    after
      Application.delete_env(:arbor_comms, :test_cleanup)
    end

    test "ignores non-log files in directory" do
      Application.put_env(:arbor_comms, :test_cleanup,
        log_dir: @test_log_dir,
        log_retention_days: 1
      )

      File.mkdir_p!(@test_log_dir)

      # Create a non-log file
      File.write!(Path.join(@test_log_dir, "notes.txt"), "keep me\n")

      assert {:ok, 0} = ChatLogger.cleanup(:test_cleanup)
      assert File.exists?(Path.join(@test_log_dir, "notes.txt"))
    after
      Application.delete_env(:arbor_comms, :test_cleanup)
    end

    test "returns 0 when directory does not exist" do
      assert {:ok, 0} = ChatLogger.cleanup(:nonexistent_channel)
    end
  end

  describe "log_path_for_date/2" do
    test "returns path with today's date by default" do
      Application.put_env(:arbor_comms, :test_log, log_dir: @test_log_dir)
      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")

      assert ChatLogger.log_path_for_date(:test_log) ==
               Path.join(@test_log_dir, "#{today}.log")
    after
      Application.delete_env(:arbor_comms, :test_log)
    end

    test "returns path with specific date" do
      Application.put_env(:arbor_comms, :test_log, log_dir: @test_log_dir)
      dt = ~U[2026-01-15 12:00:00Z]

      assert ChatLogger.log_path_for_date(:test_log, dt) ==
               Path.join(@test_log_dir, "2026-01-15.log")
    after
      Application.delete_env(:arbor_comms, :test_log)
    end
  end
end
