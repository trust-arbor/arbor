defmodule Arbor.Comms.ChatLoggerTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.ChatLogger
  alias Arbor.Contracts.Comms.Message

  @moduletag :fast

  setup do
    test_log_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_chat_logger_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(test_log_dir)
    File.mkdir_p!(test_log_dir)

    on_exit(fn ->
      File.rm_rf(test_log_dir)
    end)

    {:ok, log_dir: test_log_dir}
  end

  describe "log_message/1" do
    test "logs inbound message to dated file", %{log_dir: log_dir} do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, log_dir: log_dir)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      msg =
        Message.new(
          channel: channel,
          from: "+1234567890",
          content: "Hello Arbor",
          direction: :inbound
        )

      assert :ok = ChatLogger.log_message(msg)

      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")
      log_file = Path.join(log_dir, "#{today}.log")

      assert {:ok, content} = File.read(log_file)
      assert content =~ "<<<"
      assert content =~ "+1234567890"
      assert content =~ "Hello Arbor"
    end

    test "logs outbound message to dated file", %{log_dir: log_dir} do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, log_dir: log_dir)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      msg = Message.outbound(channel, "+1234567890", "Hi there")

      assert :ok = ChatLogger.log_message(msg)

      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")
      log_file = Path.join(log_dir, "#{today}.log")

      assert {:ok, content} = File.read(log_file)
      assert content =~ ">>>"
      assert content =~ "+1234567890"
      assert content =~ "Hi there"
    end
  end

  describe "recent/2" do
    test "returns empty list when no log exists" do
      assert {:ok, []} = ChatLogger.recent(:nonexistent_channel)
    end

    test "returns recent log lines from today", %{log_dir: log_dir} do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, log_dir: log_dir)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      for i <- 1..5 do
        msg =
          Message.new(
            channel: channel,
            from: "+1234567890",
            content: "Message #{i}"
          )

        ChatLogger.log_message(msg)
      end

      assert {:ok, lines} = ChatLogger.recent(channel, 3)
      assert length(lines) == 3
      assert List.last(lines) =~ "Message 5"
    end
  end

  describe "cleanup/1" do
    test "removes log files older than retention period", %{log_dir: log_dir} do
      channel = unique_channel()

      Application.put_env(:arbor_comms, channel,
        log_dir: log_dir,
        log_retention_days: 7
      )

      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      # Create some old log files
      old_date = Date.utc_today() |> Date.add(-10)
      old_file = Path.join(log_dir, "#{Date.to_iso8601(old_date)}.log")
      File.write!(old_file, "old data\n")

      # Create a recent log file
      recent_date = Date.utc_today() |> Date.add(-3)
      recent_file = Path.join(log_dir, "#{Date.to_iso8601(recent_date)}.log")
      File.write!(recent_file, "recent data\n")

      # Create today's log
      today_file = Path.join(log_dir, "#{Date.to_iso8601(Date.utc_today())}.log")
      File.write!(today_file, "today data\n")

      assert {:ok, 1} = ChatLogger.cleanup(channel)

      # Old file should be gone
      refute File.exists?(old_file)
      # Recent and today files should remain
      assert File.exists?(recent_file)
      assert File.exists?(today_file)
    end

    test "ignores non-log files in directory", %{log_dir: log_dir} do
      channel = unique_channel()

      Application.put_env(:arbor_comms, channel,
        log_dir: log_dir,
        log_retention_days: 1
      )

      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      # Create a non-log file
      File.write!(Path.join(log_dir, "notes.txt"), "keep me\n")

      assert {:ok, 0} = ChatLogger.cleanup(channel)
      assert File.exists?(Path.join(log_dir, "notes.txt"))
    end

    test "returns 0 when directory does not exist" do
      assert {:ok, 0} = ChatLogger.cleanup(:nonexistent_channel)
    end
  end

  describe "log_path_for_date/2" do
    test "returns path with today's date by default", %{log_dir: log_dir} do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, log_dir: log_dir)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")

      assert ChatLogger.log_path_for_date(channel) ==
               Path.join(log_dir, "#{today}.log")
    end

    test "returns path with specific date", %{log_dir: log_dir} do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, log_dir: log_dir)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      dt = ~U[2026-01-15 12:00:00Z]

      assert ChatLogger.log_path_for_date(channel, dt) ==
               Path.join(log_dir, "2026-01-15.log")
    end
  end

  # Generate unique channel atom for test isolation
  defp unique_channel do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"test_logger_#{System.unique_integer([:positive])}"
  end
end
