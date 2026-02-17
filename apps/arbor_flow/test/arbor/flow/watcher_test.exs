defmodule Arbor.Flow.WatcherTest do
  use ExUnit.Case, async: true

  alias Arbor.Flow.FileTracker.ETS
  alias Arbor.Flow.Watcher

  @moduletag :fast

  setup do
    # Create a unique temp directory for each test
    test_id = :rand.uniform(100_000_000)
    tmp_dir = Path.join(System.tmp_dir!(), "watcher_test_#{test_id}")
    File.mkdir_p!(tmp_dir)

    # Start a tracker using pid-based reference (avoids atom creation)
    {:ok, tracker_pid} = ETS.start_link(name: nil)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, tracker: tracker_pid, test_id: test_id}
  end

  # Helper: start a watcher with sensible test defaults.
  # Uses pid-based reference (name: nil would fail since name is required),
  # so we generate a unique atom from test_id to avoid collisions.
  defp start_test_watcher(ctx, overrides \\ []) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = Keyword.get(overrides, :name, :"watcher_#{ctx.test_id}")

    defaults = [
      name: name,
      directories: [ctx.tmp_dir],
      tracker: ctx.tracker,
      processor_id: "test_processor",
      poll_interval: 60_000,
      debounce_ms: 10
    ]

    opts = Keyword.merge(defaults, overrides)
    {:ok, pid} = Watcher.start_link(opts)

    # Wait for initial scan to complete
    Process.sleep(50)

    {name, pid}
  end

  # Helper to drain all matching messages from the mailbox
  defp drain_messages(acc \\ []) do
    receive do
      {:file_notification, path, content} ->
        drain_messages([{:file_notification, path, content} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # ============================================================================
  # Initialization & Configuration
  # ============================================================================

  describe "start_link/1" do
    test "starts the watcher and it is alive", ctx do
      {name, pid} = start_test_watcher(ctx)

      assert Process.alive?(pid)
      Watcher.stop(name)
    end

    test "creates directories if they don't exist", %{tracker: tracker, test_id: test_id} do
      new_dir = Path.join(System.tmp_dir!(), "new_watcher_dir_#{test_id}")

      on_exit(fn ->
        File.rm_rf!(new_dir)
      end)

      {:ok, _pid} =
        Watcher.start_link(
          # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
          name: :"watcher_create_dir_#{test_id}",
          directories: [new_dir],
          tracker: tracker,
          processor_id: "test_processor",
          poll_interval: 60_000
        )

      assert File.dir?(new_dir)
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      Watcher.stop(:"watcher_create_dir_#{test_id}")
    end

    test "raises when required :name option is missing", ctx do
      assert_raise KeyError, ~r/key :name not found/, fn ->
        Watcher.start_link(
          directories: [ctx.tmp_dir],
          tracker: ctx.tracker
        )
      end
    end

    test "fails when required :directories option is missing", ctx do
      Process.flag(:trap_exit, true)

      result =
        Watcher.start_link(
          # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
          name: :"watcher_no_dirs_#{ctx.test_id}",
          tracker: ctx.tracker
        )

      # GenServer.start_link propagates the init crash as an EXIT
      case result do
        {:error, {%KeyError{key: :directories}, _}} ->
          :ok

        {:error, _} ->
          :ok

        _ ->
          # If it somehow started, clean up and trap the exit
          receive do
            {:EXIT, _pid, {%KeyError{key: :directories}, _}} -> :ok
          after
            500 -> flunk("Expected KeyError for missing :directories")
          end
      end
    end

    test "applies default patterns when none specified", ctx do
      {name, _pid} = start_test_watcher(ctx)

      {:ok, status} = Watcher.status(name)
      assert status.patterns == ["*.md"]

      Watcher.stop(name)
    end

    test "applies default poll_interval", ctx do
      {name, _pid} = start_test_watcher(ctx, poll_interval: 30_000)

      {:ok, status} = Watcher.status(name)
      assert status.poll_interval == 30_000

      Watcher.stop(name)
    end

    test "works without a tracker (tracker: nil)", ctx do
      {name, pid} = start_test_watcher(ctx, tracker: nil)

      assert Process.alive?(pid)
      {:ok, status} = Watcher.status(name)
      assert status.known_files_count == 0

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # Status
  # ============================================================================

  describe "status/1" do
    test "returns watcher status with all expected fields", ctx do
      {name, _pid} = start_test_watcher(ctx)

      {:ok, status} = Watcher.status(name)

      assert status.name == name
      assert status.directories == [ctx.tmp_dir]
      assert status.processor_id == "test_processor"
      assert is_integer(status.known_files_count)
      assert status.known_files_count >= 0
      assert is_integer(status.pending_changes_count)
      assert is_list(status.patterns)
      assert is_integer(status.poll_interval)

      Watcher.stop(name)
    end

    test "reports known files count after initial scan", ctx do
      # Create files before starting watcher
      File.write!(Path.join(ctx.tmp_dir, "one.md"), "# One")
      File.write!(Path.join(ctx.tmp_dir, "two.md"), "# Two")

      {name, _pid} = start_test_watcher(ctx)

      # Allow debounce to clear
      Process.sleep(100)

      {:ok, status} = Watcher.status(name)
      assert status.known_files_count == 2

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # File Lifecycle: New Files
  # ============================================================================

  describe "file lifecycle - new files" do
    test "invokes on_new callback for new files detected after rescan", ctx do
      test_pid = self()

      callbacks = %{
        on_new: fn path, content, hash ->
          send(test_pid, {:new_file, path, content, hash})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Create a new file after watcher started
      file_path = Path.join(ctx.tmp_dir, "new_file.md")
      File.write!(file_path, "# New File\n\nContent here.")

      Watcher.rescan(name)

      assert_receive {:new_file, ^file_path, "# New File\n\nContent here.", hash}, 1000
      assert is_binary(hash)
      assert byte_size(hash) == 16

      Watcher.stop(name)
    end

    test "invokes on_new for pre-existing files on initial scan", ctx do
      test_pid = self()

      # Create file before watcher starts
      file_path = Path.join(ctx.tmp_dir, "preexisting.md")
      File.write!(file_path, "# Pre-existing")

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      assert_receive {:new_file, ^file_path}, 1000

      Watcher.stop(name)
    end

    test "detects new files across multiple directories", ctx do
      test_pid = self()
      dir2 = Path.join(ctx.tmp_dir, "subdir")
      File.mkdir_p!(dir2)

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, directories: [ctx.tmp_dir, dir2], callbacks: callbacks)

      file1 = Path.join(ctx.tmp_dir, "file1.md")
      file2 = Path.join(dir2, "file2.md")
      File.write!(file1, "# File 1")
      File.write!(file2, "# File 2")

      Watcher.rescan(name)

      assert_receive {:new_file, ^file1}, 1000
      assert_receive {:new_file, ^file2}, 1000

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # File Lifecycle: Changed Files
  # ============================================================================

  describe "file lifecycle - changed files" do
    test "invokes on_changed callback when file content changes", ctx do
      test_pid = self()

      # Create initial file
      file_path = Path.join(ctx.tmp_dir, "changing.md")
      File.write!(file_path, "# Version 1")

      callbacks = %{
        on_new: fn _path, _content, _hash -> :ok end,
        on_changed: fn path, content, _hash ->
          send(test_pid, {:changed_file, path, content})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Wait for initial scan + debounce
      Process.sleep(100)

      # Modify the file
      File.write!(file_path, "# Version 2")

      Watcher.rescan(name)

      assert_receive {:changed_file, ^file_path, "# Version 2"}, 1000

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # File Lifecycle: Deleted Files
  # ============================================================================

  describe "file lifecycle - deleted files" do
    test "invokes on_deleted when file removed", ctx do
      test_pid = self()

      # Create initial file
      file_path = Path.join(ctx.tmp_dir, "to_delete.md")
      File.write!(file_path, "# To Delete")

      callbacks = %{
        on_new: fn _path, _content, _hash -> :ok end,
        on_deleted: fn path ->
          send(test_pid, {:deleted_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Wait for initial scan
      Process.sleep(150)

      # Delete the file
      File.rm!(file_path)

      Watcher.rescan(name)

      assert_receive {:deleted_file, ^file_path}, 1000

      Watcher.stop(name)
    end

    test "removes deleted file from known_files", ctx do
      # Create initial file
      file_path = Path.join(ctx.tmp_dir, "to_remove.md")
      File.write!(file_path, "# Remove Me")

      {name, _pid} = start_test_watcher(ctx)

      # Wait for initial scan
      Process.sleep(100)

      {:ok, status_before} = Watcher.status(name)
      assert status_before.known_files_count == 1

      # Delete the file
      File.rm!(file_path)
      Watcher.rescan(name)
      Process.sleep(100)

      {:ok, status_after} = Watcher.status(name)
      assert status_after.known_files_count == 0

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # Callback Edge Cases & Error Handling (Crash Recovery)
  # ============================================================================

  describe "callback error handling / crash recovery" do
    test "watcher survives when on_new callback raises", ctx do
      test_pid = self()

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:callback_called, path})
          raise "intentional callback explosion"
        end
      }

      {name, pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Create a file to trigger the crashing callback
      file_path = Path.join(ctx.tmp_dir, "crash_new.md")
      File.write!(file_path, "# Crash Test")

      Watcher.rescan(name)

      assert_receive {:callback_called, ^file_path}, 1000

      # Watcher must still be alive after the callback crash
      Process.sleep(50)
      assert Process.alive?(pid)

      # And it should still respond to status calls
      assert {:ok, _status} = Watcher.status(name)

      Watcher.stop(name)
    end

    test "watcher survives when on_changed callback raises", ctx do
      test_pid = self()

      # Create initial file
      file_path = Path.join(ctx.tmp_dir, "crash_change.md")
      File.write!(file_path, "# Version 1")

      callbacks = %{
        on_new: fn _path, _content, _hash -> :ok end,
        on_changed: fn path, _content, _hash ->
          send(test_pid, {:changed_callback, path})
          raise "intentional changed explosion"
        end
      }

      {name, pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Wait for initial scan
      Process.sleep(100)

      # Modify file to trigger on_changed
      File.write!(file_path, "# Version 2")
      Watcher.rescan(name)

      assert_receive {:changed_callback, ^file_path}, 1000

      Process.sleep(50)
      assert Process.alive?(pid)

      Watcher.stop(name)
    end

    test "watcher survives when on_deleted callback raises", ctx do
      test_pid = self()

      # Create initial file
      file_path = Path.join(ctx.tmp_dir, "crash_delete.md")
      File.write!(file_path, "# Delete Crash")

      callbacks = %{
        on_new: fn _path, _content, _hash -> :ok end,
        on_deleted: fn path ->
          send(test_pid, {:delete_callback, path})
          raise "intentional delete explosion"
        end
      }

      {name, pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Wait for initial scan
      Process.sleep(150)

      # Delete the file
      File.rm!(file_path)
      Watcher.rescan(name)

      assert_receive {:delete_callback, ^file_path}, 1000

      Process.sleep(50)
      assert Process.alive?(pid)

      Watcher.stop(name)
    end

    test "watcher continues scanning after callback error", ctx do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      callbacks = %{
        on_new: fn path, _content, _hash ->
          :counters.add(call_count, 1, 1)

          if String.ends_with?(path, "first.md") do
            send(test_pid, {:crashed, path})
            raise "first file explosion"
          end

          send(test_pid, {:processed, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Create first file (will crash) and second file (should succeed)
      File.write!(Path.join(ctx.tmp_dir, "first.md"), "# First")
      File.write!(Path.join(ctx.tmp_dir, "second.md"), "# Second")

      Watcher.rescan(name)

      # Both files are debounced independently, so wait for both to fire
      # The second file should still be processed despite the first one crashing
      assert_receive {:processed, _path}, 2000

      Watcher.stop(name)
    end

    test "nil callbacks are handled gracefully (no crash)", ctx do
      # Start with no callbacks at all
      {name, pid} = start_test_watcher(ctx, callbacks: %{})

      # Create, modify, and delete a file - none should crash
      file_path = Path.join(ctx.tmp_dir, "nil_callback.md")
      File.write!(file_path, "# Test")
      Watcher.rescan(name)
      Process.sleep(100)

      File.write!(file_path, "# Changed")
      Watcher.rescan(name)
      Process.sleep(100)

      File.rm!(file_path)
      Watcher.rescan(name)
      Process.sleep(100)

      assert Process.alive?(pid)

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # File Pattern Filtering
  # ============================================================================

  describe "file filtering" do
    test "only processes matching *.md patterns", ctx do
      test_pid = self()

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, patterns: ["*.md"], callbacks: callbacks)

      md_path = Path.join(ctx.tmp_dir, "test.md")
      txt_path = Path.join(ctx.tmp_dir, "test.txt")
      File.write!(md_path, "# Markdown")
      File.write!(txt_path, "Plain text")

      Watcher.rescan(name)

      assert_receive {:new_file, ^md_path}, 1000
      refute_receive {:new_file, ^txt_path}, 200

      Watcher.stop(name)
    end

    test "supports wildcard * pattern to match all files", ctx do
      test_pid = self()

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, patterns: ["*"], callbacks: callbacks)

      md_path = Path.join(ctx.tmp_dir, "test.md")
      txt_path = Path.join(ctx.tmp_dir, "test.txt")
      File.write!(md_path, "# Markdown")
      File.write!(txt_path, "Plain text")

      Watcher.rescan(name)

      assert_receive {:new_file, ^md_path}, 1000
      assert_receive {:new_file, ^txt_path}, 1000

      Watcher.stop(name)
    end

    test "supports exact filename patterns", ctx do
      test_pid = self()

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, patterns: ["INDEX.md"], callbacks: callbacks)

      index_path = Path.join(ctx.tmp_dir, "INDEX.md")
      other_path = Path.join(ctx.tmp_dir, "other.md")
      File.write!(index_path, "# Index")
      File.write!(other_path, "# Other")

      Watcher.rescan(name)

      assert_receive {:new_file, ^index_path}, 1000
      refute_receive {:new_file, ^other_path}, 200

      Watcher.stop(name)
    end

    test "supports multiple patterns", ctx do
      test_pid = self()

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, patterns: ["*.md", "*.txt"], callbacks: callbacks)

      md_path = Path.join(ctx.tmp_dir, "test.md")
      txt_path = Path.join(ctx.tmp_dir, "test.txt")
      json_path = Path.join(ctx.tmp_dir, "test.json")
      File.write!(md_path, "# Markdown")
      File.write!(txt_path, "Plain text")
      File.write!(json_path, "{}")

      Watcher.rescan(name)

      assert_receive {:new_file, ^md_path}, 1000
      assert_receive {:new_file, ^txt_path}, 1000
      refute_receive {:new_file, ^json_path}, 200

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # Hash-Based Change Detection
  # ============================================================================

  describe "hash-based change detection" do
    test "doesn't reprocess unchanged files", ctx do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      callbacks = %{
        on_new: fn path, _content, _hash ->
          :counters.add(call_count, 1, 1)
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      # Create initial file
      file_path = Path.join(ctx.tmp_dir, "existing.md")
      File.write!(file_path, "# Existing File")

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      assert_receive {:new_file, ^file_path}, 1000

      # Rescan without changes
      Watcher.rescan(name)
      Process.sleep(200)

      assert :counters.get(call_count, 1) == 1

      Watcher.stop(name)
    end

    test "hash is consistent for same content", _ctx do
      content = "# Test Content"
      hash1 = Arbor.Flow.compute_hash(content)
      hash2 = Arbor.Flow.compute_hash(content)
      assert hash1 == hash2
    end

    test "hash differs for different content", _ctx do
      hash1 = Arbor.Flow.compute_hash("# Version 1")
      hash2 = Arbor.Flow.compute_hash("# Version 2")
      refute hash1 == hash2
    end
  end

  # ============================================================================
  # Debouncing
  # ============================================================================

  describe "debouncing" do
    test "debounces rapid changes to deliver final content", ctx do
      test_pid = self()

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

      {name, _pid} = start_test_watcher(ctx, debounce_ms: 100, callbacks: callbacks)

      # Create a file and trigger scan
      file_path = Path.join(ctx.tmp_dir, "rapid.md")
      File.write!(file_path, "# Version 1")
      Watcher.rescan(name)

      # Rapid modification before debounce expires
      Process.sleep(30)
      File.write!(file_path, "# Version 2")
      Watcher.rescan(name)

      # Wait for debounce to complete
      Process.sleep(300)

      messages = drain_messages()
      assert messages != [], "Expected at least one file notification"

      # The last message should have the final content
      {_type, _path, last_content} = List.last(messages)

      assert last_content == "# Version 2",
             "Expected final content to be Version 2, got #{inspect(last_content)}"

      Watcher.stop(name)
    end

    test "debounce_expired for unknown path is a no-op", ctx do
      {name, pid} = start_test_watcher(ctx)

      # Send a debounce_expired for a path not in pending_changes
      send(pid, {:debounce_expired, "/nonexistent/path.md"})
      Process.sleep(50)

      assert Process.alive?(pid)
      assert {:ok, _status} = Watcher.status(name)

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # Rescan
  # ============================================================================

  describe "rescan/1" do
    test "rescan triggers immediate scan and finds new files", ctx do
      test_pid = self()

      callbacks = %{
        on_new: fn path, _content, _hash ->
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      file_path = Path.join(ctx.tmp_dir, "rescan_file.md")
      File.write!(file_path, "# Rescan Test")

      Watcher.rescan(name)

      assert_receive {:new_file, ^file_path}, 1000

      Watcher.stop(name)
    end

    test "rescan cancels pending scheduled scan and reschedules", ctx do
      {name, pid} = start_test_watcher(ctx, poll_interval: 60_000)

      # Rescan should not crash, even when called rapidly
      Watcher.rescan(name)
      Watcher.rescan(name)
      Watcher.rescan(name)

      Process.sleep(50)
      assert Process.alive?(pid)

      Watcher.stop(name)
    end
  end

  # ============================================================================
  # Stop / Terminate
  # ============================================================================

  describe "stop/1" do
    test "stops the watcher cleanly", ctx do
      {name, pid} = start_test_watcher(ctx)

      assert Process.alive?(pid)

      :ok = Watcher.stop(name)

      refute Process.alive?(pid)
    end

    test "watcher can be stopped even with pending changes", ctx do
      {name, pid} = start_test_watcher(ctx, debounce_ms: 5_000)

      # Create a file to create a pending debounced change
      File.write!(Path.join(ctx.tmp_dir, "pending.md"), "# Pending")
      Watcher.rescan(name)

      # Stop before debounce expires
      Process.sleep(50)
      :ok = Watcher.stop(name)

      refute Process.alive?(pid)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles empty directories gracefully", ctx do
      {name, pid} = start_test_watcher(ctx)

      {:ok, status} = Watcher.status(name)
      assert status.known_files_count == 0
      assert Process.alive?(pid)

      Watcher.stop(name)
    end

    test "handles directory scan failure gracefully", ctx do
      # Watch a directory, then remove it to cause scan failure
      disappearing_dir = Path.join(ctx.tmp_dir, "disappearing")
      File.mkdir_p!(disappearing_dir)

      {name, pid} = start_test_watcher(ctx, directories: [disappearing_dir])

      # Remove the directory
      File.rm_rf!(disappearing_dir)

      # Rescan should not crash
      Watcher.rescan(name)
      Process.sleep(100)

      assert Process.alive?(pid)

      Watcher.stop(name)
    end

    test "scheduled_scan message triggers scan cycle", ctx do
      {name, pid} = start_test_watcher(ctx)

      # Manually send the scheduled_scan message
      send(pid, :scheduled_scan)
      Process.sleep(50)

      assert Process.alive?(pid)
      assert {:ok, _status} = Watcher.status(name)

      Watcher.stop(name)
    end

    test "processes multiple files in a single scan", ctx do
      test_pid = self()
      file_count = :counters.new(1, [:atomics])

      callbacks = %{
        on_new: fn path, _content, _hash ->
          :counters.add(file_count, 1, 1)
          send(test_pid, {:new_file, path})
          :ok
        end
      }

      {name, _pid} = start_test_watcher(ctx, callbacks: callbacks)

      # Create multiple files
      for i <- 1..5 do
        File.write!(Path.join(ctx.tmp_dir, "file_#{i}.md"), "# File #{i}")
      end

      Watcher.rescan(name)

      # Wait for all debounces
      Process.sleep(500)

      assert :counters.get(file_count, 1) == 5

      Watcher.stop(name)
    end

    test "marks files as processed in tracker", ctx do
      # Create initial file
      file_path = Path.join(ctx.tmp_dir, "tracked.md")
      File.write!(file_path, "# Tracked File")

      {name, _pid} = start_test_watcher(ctx)

      # Wait for initial scan + debounce + processing
      Process.sleep(200)

      # Verify tracker has the record
      {:ok, record} = ETS.get_record(ctx.tracker, file_path, "test_processor")
      assert record.status == :processed
      assert is_binary(record.content_hash)

      Watcher.stop(name)
    end
  end
end
