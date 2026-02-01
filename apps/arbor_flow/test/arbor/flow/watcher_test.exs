defmodule Arbor.Flow.WatcherTest do
  use ExUnit.Case, async: true

  alias Arbor.Flow.Watcher
  alias Arbor.Flow.FileTracker.ETS

  @moduletag :fast

  setup do
    # Create a unique temp directory for each test
    test_id = :rand.uniform(100_000)
    tmp_dir = Path.join(System.tmp_dir!(), "watcher_test_#{test_id}")
    File.mkdir_p!(tmp_dir)

    # Start a tracker
    tracker_name = :"tracker_#{test_id}"
    {:ok, _pid} = ETS.start_link(name: tracker_name)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, tracker: tracker_name, test_id: test_id}
  end

  describe "start_link/1" do
    test "starts the watcher", %{tmp_dir: tmp_dir, tracker: tracker, test_id: test_id} do
      watcher_name = :"watcher_#{test_id}"

      {:ok, pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [tmp_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000
        )

      assert Process.alive?(pid)
      Watcher.stop(watcher_name)
    end

    test "creates directories if they don't exist", %{tracker: tracker, test_id: test_id} do
      new_dir = Path.join(System.tmp_dir!(), "new_watcher_dir_#{test_id}")
      watcher_name = :"watcher_#{test_id}"

      on_exit(fn ->
        File.rm_rf!(new_dir)
      end)

      {:ok, _pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [new_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000
        )

      assert File.dir?(new_dir)
      Watcher.stop(watcher_name)
    end
  end

  describe "status/1" do
    test "returns watcher status", %{tmp_dir: tmp_dir, tracker: tracker, test_id: test_id} do
      watcher_name = :"watcher_#{test_id}"

      {:ok, _pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [tmp_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000
        )

      # Wait for initial scan to complete
      Process.sleep(100)

      {:ok, status} = Watcher.status(watcher_name)

      assert status.name == watcher_name
      assert status.directories == [tmp_dir]
      assert status.processor_id == "test_processor"
      assert status.known_files_count >= 0

      Watcher.stop(watcher_name)
    end
  end

  describe "callback invocation" do
    test "invokes on_new for new files", %{tmp_dir: tmp_dir, tracker: tracker, test_id: test_id} do
      test_pid = self()
      watcher_name = :"watcher_#{test_id}"

      callbacks = %{
        on_new: fn path, content, hash ->
          send(test_pid, {:new_file, path, content, hash})
          :ok
        end
      }

      {:ok, _pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [tmp_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000,
          debounce_ms: 10,
          callbacks: callbacks
        )

      # Wait for initial scan to complete
      Process.sleep(100)

      # Create a new file
      file_path = Path.join(tmp_dir, "new_file.md")
      File.write!(file_path, "# New File\n\nContent here.")

      # Trigger rescan
      Watcher.rescan(watcher_name)

      # Wait for scan + debounce + processing (generous timeout)
      assert_receive {:new_file, ^file_path, "# New File\n\nContent here.", _hash}, 1000

      Watcher.stop(watcher_name)
    end

    test "invokes on_deleted when file removed",
         %{tmp_dir: tmp_dir, tracker: tracker, test_id: test_id} do
      test_pid = self()
      watcher_name = :"watcher_#{test_id}"

      # Create initial file
      file_path = Path.join(tmp_dir, "to_delete.md")
      File.write!(file_path, "# To Delete")

      callbacks = %{
        on_new: fn _path, _content, _hash -> :ok end,
        on_deleted: fn path ->
          send(test_pid, {:deleted_file, path})
          :ok
        end
      }

      {:ok, _pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [tmp_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000,
          debounce_ms: 10,
          callbacks: callbacks
        )

      # Wait for initial scan to complete (file should be detected)
      Process.sleep(150)

      # Delete the file
      File.rm!(file_path)

      # Trigger rescan
      Watcher.rescan(watcher_name)

      # Wait for processing
      assert_receive {:deleted_file, ^file_path}, 1000

      Watcher.stop(watcher_name)
    end
  end

  describe "file filtering" do
    test "only processes matching patterns", %{tmp_dir: tmp_dir, tracker: tracker, test_id: test_id} do
      test_pid = self()
      watcher_name = :"watcher_#{test_id}"

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {:ok, _pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [tmp_dir],
          patterns: ["*.md"],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000,
          debounce_ms: 10,
          callbacks: callbacks
        )

      # Wait for initial scan to complete
      Process.sleep(100)

      # Create files
      md_path = Path.join(tmp_dir, "test.md")
      txt_path = Path.join(tmp_dir, "test.txt")
      File.write!(md_path, "# Markdown")
      File.write!(txt_path, "Plain text")

      # Trigger rescan
      Watcher.rescan(watcher_name)

      # Should receive md file
      assert_receive {:new_file, ^md_path}, 1000

      # Should not receive txt file
      refute_receive {:new_file, ^txt_path}, 200

      Watcher.stop(watcher_name)
    end
  end

  describe "hash-based change detection" do
    test "doesn't reprocess unchanged files",
         %{tmp_dir: tmp_dir, tracker: tracker, test_id: test_id} do
      test_pid = self()
      watcher_name = :"watcher_#{test_id}"
      call_count = :counters.new(1, [:atomics])

      callbacks = %{
        on_new: fn path, _content, _hash ->
          :counters.add(call_count, 1, 1)
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      # Create initial file
      file_path = Path.join(tmp_dir, "existing.md")
      File.write!(file_path, "# Existing File")

      {:ok, _pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [tmp_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000,
          debounce_ms: 10,
          callbacks: callbacks
        )

      # Wait for initial scan (should process the file)
      assert_receive {:new_file, ^file_path}, 1000

      # Rescan - should not invoke callback again
      Watcher.rescan(watcher_name)
      Process.sleep(200)

      # Should only have been called once
      assert :counters.get(call_count, 1) == 1

      Watcher.stop(watcher_name)
    end
  end

  describe "debouncing" do
    test "debounces rapid changes", %{tmp_dir: tmp_dir, tracker: tracker, test_id: test_id} do
      test_pid = self()
      watcher_name = :"watcher_#{test_id}"

      # Track all notifications (both new and changed)
      callbacks = %{
        on_new: fn path, content, _hash ->
          send(test_pid, {:file_notification, path, content})
          :ok
        end,
        on_changed: fn path, content, _hash ->
          send(test_pid, {:file_notification, path, content})
          :ok
        end
      }

      {:ok, _pid} =
        Watcher.start_link(
          name: watcher_name,
          directories: [tmp_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000,
          debounce_ms: 100,
          callbacks: callbacks
        )

      # Wait for initial scan
      Process.sleep(100)

      # Create a file and trigger scan
      file_path = Path.join(tmp_dir, "rapid.md")
      File.write!(file_path, "# Version 1")
      Watcher.rescan(watcher_name)

      # Rapid modification before debounce expires
      Process.sleep(30)
      File.write!(file_path, "# Version 2")
      Watcher.rescan(watcher_name)

      # Wait for debounce to complete
      Process.sleep(250)

      # Drain all messages and check that we eventually see Version 2
      messages = drain_messages({:file_notification, file_path, :_})
      assert length(messages) >= 1, "Expected at least one file notification"

      # The last message should have the final content
      {_type, _path, last_content} = List.last(messages)
      assert last_content == "# Version 2", "Expected final content to be Version 2, got #{inspect(last_content)}"

      Watcher.stop(watcher_name)
    end
  end

  # Helper to drain all matching messages from the mailbox
  defp drain_messages(pattern, acc \\ []) do
    receive do
      msg when elem(msg, 0) == :file_notification ->
        drain_messages(pattern, [msg | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
